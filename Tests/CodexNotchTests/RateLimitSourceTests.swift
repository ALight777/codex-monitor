import Foundation
import Testing
@testable import CodexNotch

private func weeklyQuota(_ remaining: Int, at: TimeInterval, reset: Int = 10_000) -> RateLimitSnapshot {
    RateLimitSnapshot(
        primaryPercent: nil,
        secondaryPercent: remaining,
        primaryResetsAt: nil,
        secondaryResetsAt: reset,
        capturedAt: Date(timeIntervalSince1970: at),
        isPrimaryCodexLimit: true,
        windows: [UsageQuotaWindow(
            id: "primary-7d", shortLabel: "7d", remainingPercent: remaining,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(reset))
        )],
        planType: "pro"
    )
}

@Test
func rateLimitSourceKeepsLiveQuotaAcrossLaterLogWrites() {
    let live = weeklyQuota(78, at: 2_000)
    for timestamp in [1_990.0, 2_005, 2_010, 2_029] {
        let result = RateLimitSnapshot.preferringAppServer(
            appServer: live, localFiles: weeklyQuota(80, at: timestamp)
        )
        #expect(result.secondaryPercent == 78)
        #expect(result.displayWindows(now: Date(timeIntervalSince1970: 2_030)).first?.remainingPercent == 78)
        #expect(result.capturedAt == live.capturedAt)
    }
}

@Test
func rateLimitSourceAcceptsConsumptionAndRealResets() {
    let local = weeklyQuota(78, at: 2_060)
    for live in [weeklyQuota(77, at: 2_030), weeklyQuota(100, at: 2_040, reset: 20_000)] {
        let result = RateLimitSnapshot.preferringAppServer(appServer: live, localFiles: local)
        #expect(result.secondaryPercent == live.secondaryPercent)
        #expect(result.secondaryResetsAt == live.secondaryResetsAt)
    }
    // Server corrections, including an increase in the same window, stay authoritative.
    #expect(RateLimitSnapshot.preferringAppServer(
        appServer: weeklyQuota(80, at: 2_040), localFiles: local
    ).secondaryPercent == 80)
}

@Test
func rateLimitSourceFallsBackLocallyBeforeFirstSuccessfulRead() {
    let local = weeklyQuota(80, at: 2_000)
    #expect(RateLimitSnapshot.preferringAppServer(appServer: nil, localFiles: local) == local)
}

@Test
func rateLimitSourceRejectsEmptyServerQuotaAndAcceptsSpacedJSON() {
    let store = CodexUsageStore(appServerExecutable: "/missing/codex")
    #expect(store.parseAppServerRateLimits(
        output: #"{"id":2,"result":{"rateLimits":{"limitId":"codex"}}}"#, now: Date()
    ) == nil)
    #expect(store.parseAppServerRateLimits(
        output: #"{"id": 2, "result": {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 22, "windowDurationMins": 10080}}}}"#,
        now: Date()
    )?.secondaryPercent == 78)
}

@Test
func rateLimitSourceWaitsForDelayedReplyWithoutClosingInput() throws {
    let script = """
    read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    sleep 2.4
    printf '%s\\n' '{"id": 2, "result": {"quota": 78}}'
    read -r still_open
    """
    let result = try Shell.runJSONRPC("/bin/sh", ["-c", script], input: "request\n", responseID: 2, timeout: 4)
    #expect(result.contains("78"))
}

@Test
func rateLimitSourceBoundsUnresponsiveServerAndCleansUpProcess() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchQuotaTimeout-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appendingPathComponent("pid")
    let start = ProcessInfo.processInfo.systemUptime
    do {
        _ = try Shell.runJSONRPC(
            "/bin/sh", ["-c", "echo $$ > \"$1\"; trap '' TERM; while :; do sleep 1; done", "sh", pidFile.path],
            input: "request\n", responseID: 2, timeout: 0.3
        )
        Issue.record("An unresponsive server should time out")
    } catch ShellError.timedOut {
        #expect(ProcessInfo.processInfo.systemUptime - start < 3)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}

@Test
func rateLimitSourceRetainsLastSuccessDuringFailedRefreshAndRetryBackoff() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchQuota-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("mock-codex")
    let response = root.appendingPathComponent("response.json")
    let calls = root.appendingPathComponent("calls")
    try """
    #!/bin/sh
    cd "$(dirname "$0")"
    read -r initialize
    read -r initialized
    read -r request
    printf 'call\\n' >> calls
    cat response.json
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let now = Date()
    let reset = Int(now.timeIntervalSince1970) + 604_800
    let rollout = root.appendingPathComponent("quota.jsonl")
    let iso = ISO8601DateFormatter()
    try #"{"timestamp":"\#(iso.string(from: now.addingTimeInterval(-60)))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","plan_type":"pro","primary":{"used_percent":20,"window_minutes":10080,"resets_at":\#(reset)}}}}"#
        .write(to: rollout, atomically: true, encoding: .utf8)
    _ = try Shell.run("/usr/bin/sqlite3", [root.appendingPathComponent("state_5.sqlite").path, """
        create table threads(id text, title text, tokens_used integer, model text,
          reasoning_effort text, rollout_path text, updated_at integer,
          archived integer default 0, thread_source text);
        insert into threads values('test-quota', 'quota', 0, '', '', '\(rollout.path)',
          \(Int(now.timeIntervalSince1970)), 0, 'cli');
        """])
    let store = CodexUsageStore(codexDirectory: root, ripgrepCandidates: [], appServerExecutable: executable.path)
    func writeResponse(remaining: Int, reset: Int) throws {
        try (#"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":\#(100 - remaining),"windowDurationMins":10080,"resetsAt":\#(reset)}}}}"# + "\n")
            .write(to: response, atomically: true, encoding: .utf8)
    }
    func read(at offset: TimeInterval, source: RateLimitSourcePreference = .appServerFirst) throws -> UsageSnapshot {
        let result = store.loadSnapshot(includePeriodUsage: false, bypassFastCache: true,
                                        rateLimitSource: source, now: now.addingTimeInterval(offset))
        #expect(result.errorMessage == nil)
        return result
    }

    try writeResponse(remaining: 78, reset: reset)
    #expect(try read(at: 0).secondaryPercent == 78)
    try "".write(to: response, atomically: true, encoding: .utf8)
    #expect(try read(at: 31).secondaryPercent == 78)
    #expect(try read(at: 40).secondaryPercent == 78)
    #expect(try read(at: 40, source: .localFilesOnly).secondaryPercent == 80)
    #expect(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count == 2)
    try writeResponse(remaining: 77, reset: reset)
    #expect(try read(at: 77).secondaryPercent == 77)
    try writeResponse(remaining: 100, reset: reset + 604_800)
    #expect(try read(at: 108).secondaryPercent == 100)
}
