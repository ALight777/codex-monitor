import Foundation
import Testing
@testable import CodexNotch

private struct UsageFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-index-\(UUID())")
    let index = CodexPeriodUsageIndex()
    let now = ISO8601DateFormatter().date(from: "2026-11-04T04:00:00Z")!
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    func file(_ name: String, lines: [String], archive: Bool = false) throws -> URL {
        let dir = root.appendingPathComponent(archive ? "archived_sessions" : "sessions/2026/11/04")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name + ".jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        return path
    }
    func load(at date: Date? = nil, threads: [ThreadRecord] = []) throws -> PeriodUsage {
        let result = index.load(directory: root, threads: threads, databaseAvailable: true,
                                calendar: calendar, now: date ?? now, isCancelled: { false })
        return try #require(result)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func usageMeta(_ id: String, extra: String = "", date: String = "2026-11-04T01:00:00Z") -> String {
    #"{"timestamp":"\#(date)","type":"session_meta","payload":{"id":"\#(id)"\#(extra)}}"#
}
private let usageModel = #"{"type":"turn_context","payload":{"model":"gpt-5.4"}}"#
private func usageEvent(_ tokens: Int, cumulative: Int? = nil, date: String = "2026-11-04T02:00:00Z") -> String {
    let total = cumulative.map { #", "total_token_usage":{"total_tokens":\#($0)}"# } ?? ""
    return #"{"timestamp":"\#(date)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(tokens),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(tokens)}\#(total)}}}"#
}
private func appendUsage(_ text: String, to path: URL) throws {
    let handle = try FileHandle(forWritingTo: path)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

private func compressedFixture(_ name: String = "compressed-usage") throws -> Data {
    let url = try #require(Bundle.module.resourceURL)
        .appendingPathComponent("Fixtures/\(name).jsonl.zst")
    return try Data(contentsOf: url)
}

@Test func periodIndexReadsCompressedMigratedLogsAndDeduplicatesRawCopies() throws {
    let f = UsageFixture()
    defer { f.remove() }
    let raw = try f.file("migrated", lines: [usageMeta("compressed-thread"), usageModel,
        usageEvent(100, cumulative: 100), usageEvent(200, cumulative: 300, date: "2026-11-04T03:00:00Z")])
    let compressed = raw.appendingPathExtension("zst")
    try compressedFixture().write(to: compressed)
    let thread = ThreadRecord(id: "compressed-thread", title: "", tokensUsed: 999_999,
                              model: "gpt-5.4", reasoningEffort: nil, rolloutPath: raw.path,
                              updatedAt: Int(f.now.timeIntervalSince1970))
    #expect(try f.load(threads: [thread]).today == 300)
    try FileManager.default.removeItem(at: raw)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                         ofItemAtPath: compressed.path)
    let usage = try f.load(threads: [thread])
    #expect(usage.today == 300)
    #expect(!usage.coverage.isIncomplete)
    #expect(usage.todaySummary.unpricedTokens == 0)
    #expect(try f.load(threads: [thread]).today == 300)
    #expect(f.index.bytesScanned == 0)

    // Archives can move while the database still points at the former raw path.
    let archive = f.root.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: compressed, to: archive.appendingPathComponent(compressed.lastPathComponent))
    #expect(try f.load(threads: [thread]).today == 300)
    #expect(try f.load(threads: [thread]).coverage.missingRolloutCount == 0)
}

@Test func periodIndexRejectsTruncatedAndCorruptCompressedFilesWithoutPartialUsage() throws {
    let f = UsageFixture()
    defer { f.remove() }
    let raw = try f.file("broken", lines: [])
    try FileManager.default.removeItem(at: raw)
    let path = raw.appendingPathExtension("zst")
    let data = try compressedFixture()
    try data.dropLast(2).write(to: path)
    let truncated = try f.load()
    #expect(truncated.today == 0)
    #expect(truncated.coverage.unreadableRolloutCount == 1)
    var corrupt = data
    corrupt[corrupt.count - 1] ^= 1 // checksum failure after valid events were decoded
    try corrupt.write(to: path)
    #expect(try f.load().today == 0)
    #expect(try f.load().coverage.unreadableRolloutCount == 1)
    try data.write(to: path)
    #expect(try f.load().today == 300)
    #expect(!((try f.load()).coverage.isIncomplete))
    try compressedFixture("compressed-updated").write(to: path, options: .atomic)
    #expect(try f.load().today == 400)
}

@Test func compressedReaderCancelsWithoutRequiringAnExternalExecutable() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("zstd-cancel-\(UUID()).zst")
    defer { try? FileManager.default.removeItem(at: path) }
    try compressedFixture().write(to: path)
    #expect(throws: CancellationError.self) {
        try CodexZstdReader.read(path: path.path, isCancelled: { true }) { _ in }
    }
    var decoded = 0
    try CodexZstdReader.read(path: path.path, isCancelled: { false }) { decoded += $0.count }
    #expect(decoded > 6_000_000)
}

@Test func compressedReaderAcceptsAFrameEndingExactlyAtAnOutputBlockBoundary() throws {
    let path = try #require(Bundle.module.resourceURL)
        .appendingPathComponent("Fixtures/compressed-block-boundary.zst")
    var decoded = 0
    try CodexZstdReader.read(path: path.path, isCancelled: { false }) { decoded += $0.count }
    #expect(decoded == 131_072)
}

@Test func periodIndexCountsEventsBeforeLargeToolResultsAndKeepsModelPrices() throws {
    let f = UsageFixture()
    defer { f.remove() }
    _ = try f.file("large", lines: [usageMeta("large"), usageModel,
        usageEvent(100, cumulative: 100),
        #"{"type":"response_item","payload":{"text":"\#(String(repeating: "x", count: 6_000_000))"}}"#,
        usageEvent(200, cumulative: 300, date: "2026-11-04T03:00:00Z")])
    let usage = try f.load()
    #expect(usage.today == 300)
    #expect(usage.monthSummary.unpricedTokens == 0)
    #expect(abs(usage.monthSummary.estimatedCostUSD - 0.00075) < 0.0000001)
    #expect(f.index.bytesScanned > 6_000_000)
    #expect(try f.load().today == 300)
    #expect(f.index.bytesScanned == 0)
}

@Test func periodIndexMergesRestoredRolloutsAndDeduplicatesOnlyMatchingEvents() throws {
    let f = UsageFixture()
    defer { f.remove() }
    let first = usageEvent(100, cumulative: 100)
    _ = try f.file("old", lines: [usageMeta("thread"), usageModel, first])
    _ = try f.file("restored", lines: [usageMeta("thread"), usageModel, first,
        usageEvent(100, cumulative: 100, date: "2026-11-04T02:00:10Z"), // quota replay
        usageEvent(100, cumulative: 200, date: "2026-11-04T03:00:00Z")])
    _ = try f.file("unrelated", lines: [usageMeta("another-thread"), first])
    #expect(try f.load().today == 300)
}

@Test func periodIndexCountsCounterResetsAndEqualRequestsWithoutCumulativeData() throws {
    let f = UsageFixture()
    defer { f.remove() }
    _ = try f.file("reset", lines: [usageMeta("reset"),
        usageEvent(100, cumulative: 900), usageEvent(10, cumulative: 10),
        usageEvent(20, cumulative: 30), usageEvent(20, cumulative: 30),
        usageEvent(5), usageEvent(5)])
    #expect(try f.load().today == 140)
}

@Test func periodIndexAppendsPartialUTF8LinesAndInvalidatesReplacedOrTruncatedFiles() throws {
    let f = UsageFixture()
    defer { f.remove() }
    let path = try f.file("append", lines: [usageMeta("append"), usageEvent(100, cumulative: 100)])
    #expect(try f.load().today == 100)
    let next = usageEvent(20, cumulative: 120, date: "2026-11-04T03:00:00+00:00")
    try appendUsage(String(next.prefix(12)), to: path)
    #expect(try f.load().today == 100)
    try appendUsage(String(next.dropFirst(12)) + "\n", to: path)
    #expect(try f.load().today == 120)
    #expect(f.index.bytesScanned < 1_000)
    try appendUsage(usageEvent(20, cumulative: 120, date: "2026-11-04T03:00:01Z") + "\n", to: path)
    #expect(try f.load().today == 120)

    // An atomic replacement can have the same size and mtime but a different inode.
    let oldDate = try #require(FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date)
    try (usageMeta("append") + "\n" + usageEvent(7) + "\n").write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path.path)
    #expect(try f.load().today == 7)
    let sameSizeReplacement = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: ":7", with: ":8")
    try sameSizeReplacement.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path.path)
    #expect(try f.load().today == 8)
    let handle = try FileHandle(forWritingTo: path)
    try handle.truncate(atOffset: 0)
    try handle.close()
    #expect(try f.load().today == 0)
}

@Test func periodIndexDropsDeletedFilesAndCancelledScansDoNotPublishPartialTotals() throws {
    let f = UsageFixture()
    defer { f.remove() }
    let path = try f.file("cancel", lines: [usageMeta("cancel")] + (0..<100).map { usageEvent(1, cumulative: $0 + 1) })
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func cancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return calls > 30
        }
    }
    let probe = Probe()
    let result = f.index.load(directory: f.root, threads: [], databaseAvailable: true,
                              calendar: f.calendar, now: f.now, isCancelled: { probe.cancelled() })
    #expect(result == nil)
    #expect(try f.load().today == 100)
    try FileManager.default.removeItem(at: path)
    #expect(try f.load().today == 0)
}

@Test func periodIndexUsesEventTimezoneAndRecalculatesWindowsWithoutFileChanges() throws {
    let f = UsageFixture()
    defer { f.remove() }
    _ = try f.file("dates", lines: [usageMeta("dates"),
        usageEvent(1, date: "2026-10-05T03:59:59Z"), // outside 30d
        usageEvent(2, date: "2026-10-05T04:00:00Z"), // exactly 30d
        usageEvent(4, date: "2026-10-28T04:00:00Z"), // exactly 7d
        usageEvent(8, date: "2026-11-03T23:59:59+08:00"),
        usageEvent(16, date: "2026-11-04T00:00:00+08:00"),
        usageEvent(32, date: "2026-11-04T12:00:01+08:00")]) // future
    let usage = try f.load()
    #expect(usage.month == 30)
    #expect(usage.week == 28)
    #expect(usage.day == 24)
    #expect(usage.today == 16)
    let later = try f.load(at: f.now.addingTimeInterval(2))
    #expect(later.today == 48)
    #expect(later.week == 56)
    #expect(f.index.bytesScanned == 0)
    #expect(try f.load(at: f.calendar.startOfDay(for: f.now).addingTimeInterval(86_400)).today == 0)
}

@Test func periodIndexIncludesArchivedAndOldModifiedFilesBeyondTaskCandidateLimits() throws {
    let f = UsageFixture()
    defer { f.remove() }
    for n in 0..<365 {
        let path = try f.file("file-\(n)", lines: [usageMeta("thread-\(n)"), usageEvent(1)], archive: n.isMultiple(of: 2))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: path.path)
    }
    #expect(try f.load().today == 365)
}

@Test func periodIndexSkipsInheritedEventsButKeepsSubagentUsageAcrossLaterWorldStates() throws {
    let f = UsageFixture()
    defer { f.remove() }
    _ = try f.file("parent", lines: [usageMeta("parent", date: "2026-11-04T00:00:00Z"),
        usageEvent(100, date: "2026-11-04T00:30:00Z")])
    _ = try f.file("child", lines: [usageMeta("child", extra: #", "thread_source":"subagent""#),
        usageEvent(100, date: "2026-11-04T00:30:00Z"),
        #"{"type":"world_state","payload":{"full":true}}"#,
        usageModel, usageEvent(10, cumulative: 110),
        #"{"type":"world_state","payload":{"full":true}}"#,
        usageModel, usageEvent(20, cumulative: 130, date: "2026-11-04T03:00:00Z")])
    _ = try f.file("fork", lines: [usageMeta("fork", extra: #", "forked_from_id":"parent""#),
        usageEvent(100, date: "2026-11-04T00:30:00Z"), usageModel, usageEvent(5)])
    #expect(try f.load().today == 135)
}

@Test func periodIndexReportsMissingLogsWithoutChargingLifetimeTotalsToToday() throws {
    let f = UsageFixture()
    defer { f.remove() }
    _ = try f.file("present", lines: [usageMeta("present"), usageEvent(25)])
    let missing = ThreadRecord(id: "missing", title: "", tokensUsed: 999_999,
                               model: "gpt-5.4", reasoningEffort: nil,
                               rolloutPath: f.root.appendingPathComponent("missing.jsonl").path,
                               updatedAt: Int(f.now.timeIntervalSince1970))
    let usage = try f.load(threads: [missing])
    #expect(usage.today == 25)
    #expect(usage.coverage.missingRolloutCount == 1)
    #expect(usage.coverage.isIncomplete)
    #expect(usage.coverage.detail.contains("1 个对话日志缺失"))
}

@Test func periodIndexIgnoresEmbeddedCountersAndMarksMalformedUsageAsIncomplete() throws {
    let f = UsageFixture()
    defer { f.remove() }
    let nested = String(data: try JSONSerialization.data(withJSONObject: [
        "type": "response_item", "payload": ["type": "token_count", "text": usageEvent(999)]
    ], options: [.sortedKeys]), encoding: .utf8)!
    _ = try f.file("malformed", lines: [usageMeta("malformed"), usageEvent(25), nested,
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":3}}}}"#])
    let usage = try f.load()
    #expect(usage.today == 25)
    #expect(usage.coverage.invalidUsageRecordCount == 1)
    let cancelled = f.index.load(directory: f.root, threads: [], databaseAvailable: true,
                                 calendar: f.calendar, now: f.now, isCancelled: { true })
    #expect(cancelled == nil)
    #expect(try f.load().today == 25)
}
