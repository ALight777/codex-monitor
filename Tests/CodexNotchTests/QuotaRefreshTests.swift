import Foundation
import Testing
@testable import CodexNotch

private struct QuotaRefreshFixture {
    let root: URL
    let now = Date()
    var executable: URL { root.appendingPathComponent("mock-codex") }
    var response: URL { root.appendingPathComponent("response.json") }
    var calls: URL { root.appendingPathComponent("calls") }
    var database: URL { root.appendingPathComponent("state_5.sqlite") }
    var rollout: URL { root.appendingPathComponent("sessions/quota.jsonl") }
    init(database: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaAudit-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
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
        if database { try createDatabase() }
    }
    func createDatabase() throws {
        _ = try Shell.run("/usr/bin/sqlite3", [database.path, """
        create table threads(id text, title text, tokens_used integer, model text,
        reasoning_effort text, rollout_path text, updated_at integer, archived integer default 0, thread_source text);
        insert into threads values('quota-audit', 'quota', 0, '', '', '\(rollout.path)', \(Int(now.timeIntervalSince1970)), 0, 'cli');
        """])
    }
    func writeResponse(_ remaining: Int?, reset: Int? = nil) throws {
        let text: String
        if let remaining {
            text = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":\#(100 - remaining),"windowDurationMins":10080,"resetsAt":\#(reset ?? (Int(now.timeIntervalSince1970) + 604800))}}}}"# + "\n"
        } else { text = "" }
        try text.write(to: response, atomically: true, encoding: .utf8)
    }
    func writeLocal(_ remaining: Int) throws {
        let iso = ISO8601DateFormatter().string(from: now)
        let text = #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","plan_type":"pro","primary":{"used_percent":\#(100 - remaining),"window_minutes":10080,"resets_at":\#(Int(now.timeIntervalSince1970) + 604800)}}}}"# + "\n"
        try text.write(to: rollout, atomically: true, encoding: .utf8)
    }
    func store() -> CodexUsageStore { CodexUsageStore(codexDirectory: root, appServerExecutable: executable.path) }
    func count() -> Int { ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").count }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private func quotaFixtureData(_ name: String = "quota-history") throws -> Data {
    let url = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/\(name).jsonl.zst")
    return try Data(contentsOf: url)
}

@Test func expiredQuotaWaitsForConfirmedResetIncludingUnknownValues() {
    let now = Date(timeIntervalSince1970: 2000)
    for remaining in [nil, 0, 42, 99] as [Int?] {
        let quota = RateLimitSnapshot(primaryPercent: remaining, secondaryPercent: remaining,
            primaryResetsAt: 2000, secondaryResetsAt: 2000, capturedAt: now,
            isPrimaryCodexLimit: true)
        #expect(quota.primaryDisplayPercent(now: now) == nil)
        #expect(quota.secondaryDisplayPercent(now: now) == nil)
        #expect(quota.displayWindows(now: now).allSatisfy { $0.remainingPercent == nil })
        #expect(quota.status(now: now).awaitingReset)
    }
    let healthy = RateLimitSnapshot(primaryPercent: 0, secondaryPercent: 98,
        primaryResetsAt: 1900, secondaryResetsAt: 3000, capturedAt: now,
        isPrimaryCodexLimit: true, planType: "pro", source: .live)
    #expect(!healthy.status(now: now).awaitingReset)
    #expect(healthy.displayWindows(now: now).map(\.remainingPercent) == [98])
}

@Test func manualQuotaRefreshBypassesSuccessAndFailureCaches() throws {
    let f = try QuotaRefreshFixture(); defer { f.clean() }
    let store = f.store()
    func read(_ offset: Double, force: Bool = false) -> UsageSnapshot {
        store.loadSnapshot(includePeriodUsage: false, bypassFastCache: true,
            forceRateLimitRefresh: force, now: f.now.addingTimeInterval(offset))
    }
    try f.writeResponse(80)
    #expect(read(0).secondaryPercent == 80)
    try f.writeResponse(70)
    #expect(read(10).secondaryPercent == 80)
    #expect(f.count() == 1)
    let manual = read(11, force: true)
    #expect(manual.secondaryPercent == 70)
    #expect(f.count() == 2)
    #expect(manual.rateLimitStatus.lastSuccessfulAt == f.now.addingTimeInterval(11))
    try f.writeResponse(nil)
    let failed = read(42)
    #expect(failed.secondaryPercent == 70)
    #expect(failed.rateLimitStatus.refreshFailed)
    #expect(failed.rateLimitStatus.lastSuccessfulAt == manual.rateLimitStatus.lastSuccessfulAt)
    try f.writeResponse(60)
    #expect(read(43).secondaryPercent == 70)
    #expect(f.count() == 3)
    let recovered = read(44, force: true)
    #expect(recovered.secondaryPercent == 60)
    #expect(!recovered.rateLimitStatus.needsAttention)
    #expect(f.count() == 4)
}

@Test func quotaRefreshCrossesResetWithoutWaitingForSuccessCacheExpiry() throws {
    let f = try QuotaRefreshFixture(); defer { f.clean() }
    let store = f.store()
    try f.writeResponse(0, reset: Int(f.now.timeIntervalSince1970) + 5)
    #expect(store.loadSnapshot(includePeriodUsage: false, now: f.now).secondaryPercent == 0)
    try f.writeResponse(99)
    let refreshed = store.loadSnapshot(includePeriodUsage: false, now: f.now.addingTimeInterval(6))
    #expect(refreshed.secondaryPercent == 99)
    #expect(!refreshed.rateLimitStatus.awaitingReset)
    #expect(f.count() == 2)
}

@Test func failedQuotaPreservesOriginalTimestampAndWarnsUntilRecovery() throws {
    let f = try QuotaRefreshFixture(); defer { f.clean() }
    let store = f.store()
    try f.writeResponse(80)
    let original = store.loadSnapshot(includePeriodUsage: false, now: f.now)
    try f.writeResponse(nil)
    try f.writeLocal(70)
    for offset in [31.0, 60, 3600, 86400] {
        let at = f.now.addingTimeInterval(offset)
        let snapshot = store.loadSnapshot(includePeriodUsage: false, now: at)
        #expect(snapshot.secondaryPercent == 80)
        #expect(snapshot.rateLimitStatus.refreshFailed)
        #expect(snapshot.rateLimitStatus.needsAttention)
        #expect(snapshot.rateLimitStatus.lastSuccessfulAt == original.rateLimitStatus.lastSuccessfulAt)
        #expect(snapshot.rateLimitStatus.detail.contains("旧值"))
        let json = try #require(JSONSerialization.jsonObject(with: SnapshotOutputFormatter.jsonData(for: snapshot)) as? [String: Any])
        let status = try #require(json["quota_status"] as? [String: Any])
        #expect(status["refresh_failed"] as? Bool == true)
        #expect(status["source"] as? String == "live")
    }
    let expired = store.loadSnapshot(includePeriodUsage: false, now: f.now.addingTimeInterval(604801))
    #expect(expired.secondaryPercent == nil)
    #expect(expired.rateLimitStatus.awaitingReset)
    #expect(expired.stabilizedRateLimits(against: original).secondaryPercent == nil)
}

@Test func initialQuotaFailureLabelsLocalFallbackOrUnavailable() throws {
    let f = try QuotaRefreshFixture(); defer { f.clean() }
    try f.writeResponse(nil)
    let empty = f.store().loadSnapshot(includePeriodUsage: false, now: f.now)
    #expect(empty.rateLimitStatus.source == .unavailable)
    #expect(empty.rateLimitStatus.refreshFailed)
    try f.writeLocal(70)
    let local = f.store().loadSnapshot(includePeriodUsage: false, now: f.now)
    #expect(local.secondaryPercent == 70)
    #expect(local.rateLimitStatus.source == .local)
    #expect(local.rateLimitStatus.refreshFailed)
    let localOnly = f.store().loadSnapshot(includePeriodUsage: false, rateLimitSource: .localFilesOnly, now: f.now)
    #expect(localOnly.secondaryPercent == 70)
    #expect(!localOnly.rateLimitStatus.refreshFailed)
    #expect(localOnly.rateLimitStatus.summary == "额度来自本地记录")
}

@Test func quotaQuerySurvivesMissingOrBrokenTaskDatabase() throws {
    let f = try QuotaRefreshFixture(database: false); defer { f.clean() }
    try f.writeResponse(70)
    let store = f.store()
    let missing = store.loadSnapshot(includePeriodUsage: false, now: f.now)
    #expect(missing.secondaryPercent == 70)
    #expect(missing.errorMessage != nil)
    #expect(missing.rateLimitStatus.source == .live)
    #expect(!missing.rateLimitStatus.needsAttention)
    try "not a database".write(to: f.database, atomically: true, encoding: .utf8)
    try f.writeResponse(69)
    let corrupt = store.loadSnapshot(includePeriodUsage: false, forceRateLimitRefresh: true, now: f.now.addingTimeInterval(1))
    #expect(corrupt.secondaryPercent == 69)
    #expect(corrupt.errorMessage != nil)
    try FileManager.default.removeItem(at: f.database)
    try f.createDatabase()
    let recovered = store.loadSnapshot(includePeriodUsage: false, now: f.now.addingTimeInterval(2))
    #expect(recovered.secondaryPercent == 69)
    #expect(recovered.errorMessage == nil)
}

@Test func quotaReadsCompressedLogsAndInvalidatesReplacedCache() throws {
    let f = try QuotaRefreshFixture(); defer { f.clean() }
    try f.writeLocal(61)
    let store = f.store()
    #expect(store.loadSnapshot(includePeriodUsage: false, rateLimitSource: .localFilesOnly, now: f.now).secondaryPercent == 61)
    let compressed = f.rollout.appendingPathExtension("zst")
    try quotaFixtureData().write(to: compressed)
    try FileManager.default.removeItem(at: f.rollout)
    let migrated = store.loadSnapshot(includePeriodUsage: false, rateLimitSource: .localFilesOnly, now: f.now.addingTimeInterval(1))
    #expect(migrated.secondaryPercent == 61)
    #expect(migrated.rateLimitStatus.source == .local)
    #expect(migrated.rateLimitStatus.lastSuccessfulAt == ISO8601DateFormatter().date(from: "2026-11-04T02:00:00Z"))
    #expect(store.loadSnapshot(includePeriodUsage: false, rateLimitSource: .localFilesOnly, now: f.now.addingTimeInterval(2)).secondaryPercent == 61)
    try quotaFixtureData("quota-updated").write(to: compressed, options: .atomic)
    #expect(store.loadSnapshot(includePeriodUsage: false, rateLimitSource: .localFilesOnly, now: f.now.addingTimeInterval(3)).secondaryPercent == 55)
    // Discovery also works without a database path pointing at the archive.
    let archived = f.root.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: compressed, to: archived.appendingPathComponent("quota.jsonl.zst"))
    #expect(f.store().loadSnapshot(includePeriodUsage: false, rateLimitSource: .localFilesOnly, now: f.now).secondaryPercent == 55)
}

@Test func quotaRejectsCorruptCompressedLogWithoutPublishingPartialEvents() throws {
    let f = try QuotaRefreshFixture(); defer { f.clean() }
    let compressed = f.rollout.appendingPathExtension("zst")
    let bytes = try quotaFixtureData()
    var corrupt = bytes
    corrupt[corrupt.count - 1] ^= 1
    for data in [Data(bytes.dropLast(2)), corrupt] {
        try data.write(to: compressed, options: .atomic)
        let value = f.store().loadSnapshot(includePeriodUsage: false, rateLimitSource: .localFilesOnly, now: f.now)
        #expect(value.secondaryPercent == nil)
        #expect(value.rateLimitStatus.source == .unavailable)
        #expect(value.rateLimitStatus.needsAttention)
    }
}

@MainActor
@Test func manualQuotaRefreshSurvivesAnAlreadyRunningSnapshot() async throws {
    let f = try QuotaRefreshFixture(); defer { f.clean() }
    let suite = "quota-refresh-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "showPeriodUsage")
    let settings = CodexNotchSettings(
        defaults: defaults, initialManagementKey: "", initialNewAPIKey: "", initialSubAPIKey: "",
        secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore())
    )
    try f.writeResponse(80)
    let model = UsageViewModel(store: f.store(), settings: settings)
    func waitFor(_ remaining: Int) async throws {
        let deadline = Date().addingTimeInterval(8)
        while model.snapshot.secondaryPercent != remaining && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.snapshot.secondaryPercent == remaining)
    }
    try await waitFor(80)
    try f.writeResponse(70)
    model.refresh(bypassFastCache: true)
    model.refreshAll() // Must retain force-refresh intent while the cached read is in flight.
    try await waitFor(70)
    #expect(f.count() >= 2)
    #expect(!model.snapshot.rateLimitStatus.refreshFailed)
}
