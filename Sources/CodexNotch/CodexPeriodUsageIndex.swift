import Foundation
import Darwin

/// A per-file, append-aware index. Activity/task lists may be bounded; accounting may not.
/// Only token events and their model context are retained, never conversation text.
final class CodexPeriodUsageIndex: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder = CodexSessionEventDecoder()
    private var files: [String: IndexedFile] = [:]
    private(set) var bytesScanned: UInt64 = 0

    func load(
        directory: URL,
        threads: [ThreadRecord],
        databaseAvailable: Bool,
        calendar: Calendar,
        now: Date,
        isCancelled: @Sendable () -> Bool
    ) -> PeriodUsage? {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled() else { return nil }
        bytesScanned = 0

        var coverage = UsageCoverage(databaseUnavailable: !databaseAvailable)
        var paths = Set<String>()
        for name in ["sessions", "archived_sessions"] {
            let root = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    coverage.discoveryIncomplete = true
                    return true
                }
            )
            guard let enumerator else {
                coverage.discoveryIncomplete = true
                continue
            }
            for case let url as URL in enumerator
                where url.pathExtension == "jsonl" || url.lastPathComponent.hasSuffix(".jsonl.zst") {
                guard !isCancelled() else { return nil }
                paths.insert(url.resolvingSymlinksInPath().path)
            }
        }

        let discoveredNames = Set(paths.map { Self.rolloutName($0) })
        var threadIDsByPath: [String: String] = [:]
        for thread in threads {
            guard !thread.rolloutPath.isEmpty else {
                coverage.missingRolloutCount += 1
                continue
            }
            let url = URL(fileURLWithPath: thread.rolloutPath).resolvingSymlinksInPath()
            threadIDsByPath[url.path] = thread.id.lowercased()
            let compressedPath = url.path + ".zst"
            threadIDsByPath[compressedPath] = thread.id.lowercased()
            if FileManager.default.fileExists(atPath: url.path) {
                paths.insert(url.path)
            } else if FileManager.default.fileExists(atPath: compressedPath) {
                paths.insert(compressedPath)
            } else if !discoveredNames.contains(Self.rolloutName(url.path)) {
                coverage.missingRolloutCount += 1
            }
        }

        // Removed files must not leave ghost usage behind. Archives are rediscovered above.
        files = files.filter { paths.contains($0.key) }
        var grouped: [String: [LocatedEvent]] = [:]
        for path in paths.sorted() {
            guard !isCancelled() else { return nil }
            do {
                let indexed = try autoreleasepool {
                    try scan(path: path, fallbackID: threadIDsByPath[path], isCancelled: isCancelled)
                }
                files[path] = indexed
                coverage.invalidUsageRecordCount += indexed.invalidUsageRecordCount
                for (ordinal, event) in indexed.events.enumerated() where event.date <= now {
                    grouped[indexed.threadID, default: []].append(
                        LocatedEvent(path: path, ordinal: ordinal, event: event)
                    )
                }
            } catch is CancellationError {
                return nil
            } catch {
                // A failed/partial scan is never published as a successful cache entry.
                coverage.unreadableRolloutCount += 1
            }
        }

        let monthStart = now.addingTimeInterval(-30 * 86_400)
        let weekStart = now.addingTimeInterval(-7 * 86_400)
        let dayStart = now.addingTimeInterval(-86_400)
        let todayStart = calendar.startOfDay(for: now)
        var usage = PeriodUsage.zero
        usage.coverage = coverage

        for events in grouped.values {
            var previous: CounterSnapshot?
            var seen: [EventIdentity: String] = [:]
            for located in events.sorted(by: LocatedEvent.ordered) {
                guard !isCancelled() else { return nil }
                let event = located.event
                let identity = EventIdentity(date: event.date, usage: event.usage, cumulative: event.cumulative)
                // A restored rollout can replay an exact prefix. Do not merge unrelated threads,
                // or discard equal-sized requests without an authoritative cumulative counter.
                if let firstPath = seen[identity], firstPath != located.path { continue }
                seen[identity] = located.path
                if let cumulative = event.cumulative {
                    let counter = CounterSnapshot(cumulative: cumulative, last: event.usage)
                    if previous == counter { continue }
                    previous = counter
                } else {
                    previous = nil
                }
                guard event.date >= monthStart else { continue }
                usage.monthSummary.add(event.usage, model: event.model)
                if event.date >= weekStart { usage.weekSummary.add(event.usage, model: event.model) }
                if event.date >= dayStart { usage.daySummary.add(event.usage, model: event.model) }
                if event.date >= todayStart { usage.todaySummary.add(event.usage, model: event.model) }
            }
        }
        usage.today = usage.todaySummary.totalTokens
        usage.day = usage.daySummary.totalTokens
        usage.week = usage.weekSummary.totalTokens
        usage.month = usage.monthSummary.totalTokens
        return usage
    }

    private func scan(
        path: String,
        fallbackID: String?,
        isCancelled: @Sendable () -> Bool
    ) throws -> IndexedFile {
        let signature = try Signature(path: path)
        if let cached = files[path], cached.signature == signature { return cached }
        if path.hasSuffix(".jsonl.zst") {
            return try scanCompressed(path: path, signature: signature,
                                      fallbackID: fallbackID, isCancelled: isCancelled)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        var indexed = IndexedFile(signature: signature, threadID: fallbackID ?? Self.threadID(from: path))
        if let cached = files[path],
           cached.signature.fileID == signature.fileID,
           signature.size > cached.signature.size,
           cached.offset <= data.count,
           cached.prefix == data.prefix(cached.prefix.count),
           cached.anchor == data[max(0, cached.offset - cached.anchor.count)..<cached.offset] {
            indexed = cached
            indexed.signature = signature
        }
        let start = indexed.offset
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var lineStart = start
            while lineStart < bytes.count {
                guard !isCancelled() else { throw CancellationError() }
                let newline = memchr(base.advanced(by: lineStart), 0x0A, bytes.count - lineStart)
                let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                // Route on a small envelope prefix so large tool results / world states
                // need not be copied or deserialized just to find the next token event.
                let prefix = String(decoding: bytes[lineStart..<min(end, lineStart + 512)], as: UTF8.self)
                let kind = Self.envelopeType(in: prefix)
                let isRelevant = ["session_meta", "turn_context", "event_msg", "token_count"].contains(kind)
                // Even the envelope may still be being written. Keep its start offset until
                // the newline arrives, unless a complete relevant JSON object is available.
                if newline == nil, !isRelevant { break }
                var complete = true
                if isRelevant {
                    let line = Data(bytes: base.advanced(by: lineStart), count: end - lineStart)
                    if !consumeLine(line, indexed: &indexed) {
                        complete = false
                        if newline != nil { indexed.invalidUsageRecordCount += 1 }
                    }
                } else if kind == "world_state", indexed.isDerived, !indexed.ownActivityStarted {
                    // Legacy spawned rollouts contain copied history before their live context.
                    indexed.events.removeAll(keepingCapacity: true)
                    indexed.model = nil
                }
                if newline == nil, !complete { break } // Writer has not finished this JSON line.
                lineStart = newline == nil ? end : end + 1
                indexed.offset = lineStart
            }
        }
        bytesScanned += UInt64(data.count - start)
        // Reject replacement/truncation during the scan. Appends are picked up next time.
        let after = try Signature(path: path)
        guard signature.fileID == after.fileID, after.size >= signature.size,
              after.size != signature.size || after.modifiedAt == signature.modifiedAt else {
            throw CocoaError(.fileReadUnknown)
        }
        indexed.prefix = Data(data.prefix(min(512, indexed.offset)))
        indexed.anchor = Data(data[max(0, indexed.offset - 512)..<indexed.offset])
        return indexed
    }

    private func scanCompressed(
        path: String, signature: Signature, fallbackID: String?,
        isCancelled: @Sendable () -> Bool
    ) throws -> IndexedFile {
        var indexed = IndexedFile(signature: signature, threadID: fallbackID ?? Self.threadID(from: path))
        var line = Data()
        var kind: String?
        var retain = true
        func finishLine() {
            let type = kind ?? Self.envelopeType(in: String(decoding: line.prefix(512), as: UTF8.self))
            if Self.isUsageEnvelope(type) {
                if !consumeLine(line, indexed: &indexed) {
                    indexed.invalidUsageRecordCount += 1
                }
            } else if type == "world_state", indexed.isDerived, !indexed.ownActivityStarted {
                indexed.events.removeAll(keepingCapacity: true)
                indexed.model = nil
            }
            line.removeAll(keepingCapacity: false)
            kind = nil
            retain = true
        }
        try CodexZstdReader.read(path: path, isCancelled: isCancelled) { bytes in
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                guard !isCancelled() else { throw CancellationError() }
                let newline = memchr(base.advanced(by: start), 0x0A, bytes.count - start)
                let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                var cursor = start
                if kind == nil {
                    let count = min(512 - line.count, end - cursor)
                    line.append(base.advanced(by: cursor).assumingMemoryBound(to: UInt8.self), count: count)
                    cursor += count
                    if line.count == 512 || newline != nil {
                        kind = Self.envelopeType(in: String(decoding: line, as: UTF8.self))
                        retain = Self.isUsageEnvelope(kind ?? "")
                    }
                }
                if retain, cursor < end {
                    line.append(base.advanced(by: cursor).assumingMemoryBound(to: UInt8.self), count: end - cursor)
                }
                if newline != nil { finishLine() }
                start = newline == nil ? end : end + 1
            }
        }
        if !line.isEmpty { finishLine() }
        guard try Signature(path: path) == signature else { throw CocoaError(.fileReadUnknown) }
        bytesScanned += signature.size
        return indexed
    }

    private static func isUsageEnvelope(_ type: String) -> Bool {
        ["session_meta", "turn_context", "event_msg", "token_count"].contains(type)
    }

    private static func rolloutName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasSuffix(".jsonl.zst") ? String(name.dropLast(4)) : name
    }

    private func consumeLine(_ line: Data, indexed: inout IndexedFile) -> Bool {
        // Foundation's decoded dictionaries must not accumulate until the entire
        // multi-GB history scan returns to the background task's autorelease pool.
        autoreleasepool {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                return false
            }
            consume(object, indexed: &indexed)
            return true
        }
    }

    private func consume(_ object: [String: Any], indexed: inout IndexedFile) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        let kind = object["type"] as? String
        let date = (object["timestamp"] as? String).flatMap(decoder.parseTimestamp)
        if kind == "session_meta" {
            if let id = payload["id"] as? String { indexed.threadID = id.lowercased() }
            let source = payload["source"] as? [String: Any]
            indexed.isDerived = payload["thread_source"] as? String == "subagent"
                || source?["subagent"] as? [String: Any] != nil
                || payload["forked_from_id"] as? String != nil
            indexed.createdAt = date
            indexed.model = payload["model"] as? String
            return
        }
        // Copied parent events retain their original timestamps. They belong to the parent.
        if indexed.isDerived, let createdAt = indexed.createdAt, let date, date < createdAt { return }
        if kind == "turn_context" {
            indexed.model = payload["model"] as? String ?? indexed.model
            indexed.ownActivityStarted = true
            return
        }
        guard kind == "event_msg" || kind == nil else { return }
        if payload["type"] as? String == "task_started" {
            indexed.ownActivityStarted = true
            return
        }
        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else { return }
        guard let date,
              let last = info["last_token_usage"] as? [String: Any],
              let usage = Self.breakdown(last) else {
            indexed.invalidUsageRecordCount += 1
            return
        }
        if let createdAt = indexed.createdAt, date > createdAt { indexed.ownActivityStarted = true }
        indexed.events.append(Event(
            date: date, usage: usage,
            cumulative: (info["total_token_usage"] as? [String: Any]).flatMap(Self.breakdown),
            model: indexed.model
        ))
    }

    private static func breakdown(_ value: [String: Any]) -> TokenUsageBreakdown? {
        let input = max(0, value["input_tokens"] as? Int ?? 0)
        let output = max(0, value["output_tokens"] as? Int ?? 0)
        guard let total = value["total_tokens"] as? Int ?? (value["input_tokens"] != nil ? input + output : nil),
              total >= 0 else { return nil }
        return TokenUsageBreakdown(
            inputTokens: input,
            cachedInputTokens: min(input, max(0, value["cached_input_tokens"] as? Int ?? 0)),
            outputTokens: output,
            reasoningOutputTokens: min(output, max(0, value["reasoning_output_tokens"] as? Int ?? 0)),
            totalTokens: total
        )
    }

    private static let typePattern = try! NSRegularExpression(pattern: #""type"\s*:\s*"([^"]+)""#)
    private static func envelopeType(in prefix: String) -> String {
        autoreleasepool {
            guard let match = typePattern.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
                  let range = Range(match.range(at: 1), in: prefix) else { return "" }
            return String(prefix[range])
        }
    }

    private static func threadID(from path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if let range = name.range(of: #"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"#, options: .regularExpression) {
            return name[range].lowercased()
        }
        return path
    }

    private struct Signature: Equatable {
        let fileID: UInt64
        let size: UInt64
        let modifiedAt: Date
        init(path: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
        }
    }
    private struct IndexedFile {
        var signature: Signature
        var threadID: String
        var offset = 0
        var prefix = Data()
        var anchor = Data()
        var model: String?
        var isDerived = false
        var createdAt: Date?
        var ownActivityStarted = false
        var invalidUsageRecordCount = 0
        var events: [Event] = []
    }
    private struct Event {
        let date: Date
        let usage: TokenUsageBreakdown
        let cumulative: TokenUsageBreakdown?
        let model: String?
    }
    private struct EventIdentity: Hashable {
        let date: Date
        let usage: TokenUsageBreakdown
        let cumulative: TokenUsageBreakdown?
    }
    private struct CounterSnapshot: Equatable {
        let cumulative: TokenUsageBreakdown
        let last: TokenUsageBreakdown
    }
    private struct LocatedEvent {
        let path: String
        let ordinal: Int
        let event: Event
        static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.event.date != rhs.event.date { return lhs.event.date < rhs.event.date }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return lhs.ordinal < rhs.ordinal
        }
    }
}
