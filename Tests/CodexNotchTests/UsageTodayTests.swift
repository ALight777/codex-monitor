import Foundation
import Testing
@testable import CodexNotch

@Test
func todayUsageUsesComputerCalendarAndIncludesArchivedThreads() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 27, hour: 10
    )))
    let previousDay = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 26, hour: 23, minute: 30
    )))
    let todayEarly = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 27, hour: 0, minute: 30
    )))
    let todayLate = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 27, hour: 9
    )))

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexNotchToday-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionDirectory = root.appendingPathComponent("sessions/2026/08/27", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

    let stateDatabase = root.appendingPathComponent("state_5.sqlite").path
    let logsDatabase = root.appendingPathComponent("logs_2.sqlite").path
    _ = try Shell.run("/usr/bin/sqlite3", [
        stateDatabase,
        """
        create table threads(
          id text, title text, tokens_used integer, model text, reasoning_effort text,
          rollout_path text, updated_at integer, archived integer default 0,
          thread_source text
        );
        """
    ])
    _ = try Shell.run("/usr/bin/sqlite3", [
        logsDatabase,
        "create table logs(thread_id text, ts integer, target text, feedback_log_body text);"
    ])

    let sessionID = "019c0000-0000-7000-8000-000000000001"
    let rollout = sessionDirectory.appendingPathComponent("rollout-2026-08-27T00-00-00-\(sessionID).jsonl")
    let iso = ISO8601DateFormatter()
    let contents = [
        (previousDay, 10),
        (todayEarly, 20),
        (todayLate, 30)
    ].map { date, tokens in
        #"{"timestamp":"\#(iso.string(from: date))","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":\#(tokens)}}}}"#
    }.joined(separator: "\n")
    try contents.write(to: rollout, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: rollout.path)
    _ = try Shell.run("/usr/bin/sqlite3", [
        stateDatabase,
        """
        insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived, thread_source)
        values('\(sessionID)', '已归档任务', 60, 'gpt-5.6-sol', 'high', '\(rollout.path)', \(Int(now.timeIntervalSince1970)), 1, 'cli');
        """
    ])

    let store = CodexUsageStore(
        codexDirectory: root,
        ripgrepCandidates: [],
        calendar: calendar
    )
    let usage = try #require(store.loadUsageTotals(now: now))
    #expect(usage.today == 50)
    #expect(usage.day == 60)
    #expect(usage.week == 60)
    #expect(usage.month == 60)
}

@Test
func subagentUsageIgnoresInheritedDatabaseTotalsAndInvalidatesOnlyChangedTailData() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 28, hour: 10
    )))
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexNotchSubagentUsage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionDirectory = root.appendingPathComponent("sessions/2026/08/28", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

    let stateDatabase = root.appendingPathComponent("state_5.sqlite").path
    let logsDatabase = root.appendingPathComponent("logs_2.sqlite").path
    _ = try Shell.run("/usr/bin/sqlite3", [
        stateDatabase,
        """
        create table threads(
          id text, title text, tokens_used integer, model text, reasoning_effort text,
          rollout_path text, updated_at integer, archived integer default 0,
          thread_source text
        );
        """
    ])
    _ = try Shell.run("/usr/bin/sqlite3", [
        logsDatabase,
        "create table logs(thread_id text, ts integer, target text, feedback_log_body text);"
    ])

    let mainID = "019c0000-0000-7000-8000-000000000101"
    let subagentID = "019c0000-0000-7000-8000-000000000102"
    let mainRollout = sessionDirectory.appendingPathComponent("rollout-main-\(mainID).jsonl")
    let subagentRollout = sessionDirectory.appendingPathComponent("rollout-subagent-\(subagentID).jsonl")
    let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))

    let mainLines = [
        #"{"type":"session_meta","payload":{"thread_source":"user"}}"#,
        #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        tokenCountLine(timestamp: timestamp, total: 100)
    ]
    try mainLines.joined(separator: "\n").write(to: mainRollout, atomically: true, encoding: .utf8)

    let subagentLines = [
        #"{"type":"session_meta","payload":{"source":{"subagent":{}},"thread_source":"subagent"}}"#,
        tokenCountLine(timestamp: timestamp, total: 10),
        #"{"type":"world_state","payload":{"full":true}}"#,
        #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        tokenCountLine(timestamp: timestamp, total: 20)
    ]
    try subagentLines.joined(separator: "\n").write(to: subagentRollout, atomically: true, encoding: .utf8)

    _ = try Shell.run("/usr/bin/sqlite3", [
        stateDatabase,
        """
        insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived, thread_source)
        values
          ('\(mainID)', '主任务', 100, 'gpt-5.6-sol', 'high', '\(mainRollout.path)', \(Int(now.timeIntervalSince1970)), 0, 'user'),
          ('\(subagentID)', '子代理', 999999, 'gpt-5.6-sol', 'high', '\(subagentRollout.path)', \(Int(now.timeIntervalSince1970)), 0, 'subagent');
        """
    ])

    let store = CodexUsageStore(
        codexDirectory: root,
        ripgrepCandidates: [],
        calendar: calendar
    )
    #expect(store.loadUsageTotals(now: now)?.today == 120)
    #expect(store.loadUsageTotals(now: now)?.today == 120)

    let handle = try FileHandle(forWritingTo: subagentRollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(("\n" + tokenCountLine(timestamp: timestamp, total: 30)).utf8))
    try handle.close()

    #expect(store.loadUsageTotals(now: now.addingTimeInterval(1))?.today == 150)
    #expect(store.loadUsageTotals(now: now, isCancelled: { true }) == nil)
}

private func tokenCountLine(timestamp: String, total: Int) -> String {
    #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)}}}}"#
}
