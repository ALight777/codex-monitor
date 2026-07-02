import Foundation

struct SessionMetaInfo {
    let isSubagent: Bool
    let parentThreadID: String?
}

struct SessionRuntimeInfo {
    let model: String?
    let reasoningEffort: String?
}

struct SessionActivityInfo {
    let latestActivity: Date?
    let latestDone: Date?
}

struct CodexTokenCountEvent {
    let timestamp: String
    let date: Date
    let tokens: Int
}

struct CodexSessionEventDecoder {
    private struct SessionLineEvent {
        let timestamp: Date
        let topLevelType: String?
        let payloadType: String?
        let payloadPhase: String?
        let payloadStatus: String?
    }

    private let timestampParser = CodexTimestampParser()
    private let terminalEventTypes: Set<String> = [
        "task_complete",
        "task_completed",
        "task_stopped",
        "task_failed",
        "task_cancelled",
        "turn_complete",
        "turn_completed",
        "turn_aborted",
        "turn_failed",
        "turn_cancelled"
    ]

    func parseTimestamp(_ value: String) -> Date? {
        timestampParser.parse(value)
    }

    func timestampString(from date: Date) -> String {
        timestampParser.string(from: date)
    }

    func timestampSecondPrefix(for date: Date) -> String {
        String(timestampString(from: date).prefix(19))
    }

    func timestampSecondPrefix(from timestamp: String) -> String? {
        guard timestamp.count >= 19 else {
            return nil
        }
        let prefix = String(timestamp.prefix(19))
        guard prefix[prefix.index(prefix.startIndex, offsetBy: 4)] == "-",
              prefix[prefix.index(prefix.startIndex, offsetBy: 7)] == "-",
              prefix[prefix.index(prefix.startIndex, offsetBy: 10)] == "T",
              prefix[prefix.index(prefix.startIndex, offsetBy: 13)] == ":",
              prefix[prefix.index(prefix.startIndex, offsetBy: 16)] == ":" else {
            return nil
        }
        return prefix
    }

    func activityInfo(from text: String) -> SessionActivityInfo? {
        var latestActivity: Date?
        var latestDone: Date?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineText = String(line)
            let marksCompletion = lineMarksCompletion(lineText)
            let marksActivity = lineMarksActivity(lineText)
            guard marksCompletion || marksActivity,
                  let timestamp = fastJSONStringValue(for: "timestamp", in: lineText),
                  let date = parseTimestamp(timestamp) else {
                continue
            }

            if marksCompletion {
                latestDone = maxDate(latestDone, date)
            }
            if marksActivity {
                latestActivity = maxDate(latestActivity, date)
            }
        }

        return SessionActivityInfo(latestActivity: latestActivity, latestDone: latestDone)
    }

    func title(from text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""role":"user""#) || line.contains(#""role": "user""#),
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "user",
                  let content = payload["content"] as? [[String: Any]] else {
                continue
            }

            for item in content {
                guard let text = item["text"] as? String,
                      let title = normalizedTitle(from: text) else {
                    continue
                }
                return title
            }
        }

        return nil
    }

    func meta(from text: String) -> SessionMetaInfo? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""session_meta""#) else {
                continue
            }

            let lineText = String(line)
            guard let data = lineText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else {
                if let fallback = fallbackMeta(from: lineText) {
                    return fallback
                }
                continue
            }

            let source = payload["source"] as? [String: Any]
            let subagentSource = source?["subagent"] as? [String: Any]
            let hasSubagentSource = subagentSource != nil
            let threadSource = payload["thread_source"] as? String
            let threadSpawn = subagentSource?["thread_spawn"] as? [String: Any]
            let parentThreadID = (
                payload["parent_thread_id"] as? String
                    ?? payload["parentThreadId"] as? String
                    ?? threadSpawn?["parent_thread_id"] as? String
                    ?? threadSpawn?["parentThreadId"] as? String
            )?.lowercased()
            let isSubagent = threadSource == "subagent" || hasSubagentSource

            return SessionMetaInfo(
                isSubagent: isSubagent,
                parentThreadID: isSubagent ? parentThreadID : nil
            )
        }

        return nil
    }

    func runtimeInfo(from text: String) -> SessionRuntimeInfo? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""turn_context""#),
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            let settings = (payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
            let model = stringValue(payload["model"]) ?? stringValue(settings?["model"])
            let reasoningEffort = stringValue(payload["effort"])
                ?? stringValue(payload["reasoning_effort"])
                ?? stringValue(settings?["reasoning_effort"])

            if model != nil || reasoningEffort != nil {
                return SessionRuntimeInfo(model: model, reasoningEffort: reasoningEffort)
            }
        }

        return nil
    }

    func tokenCountTokens(from line: String) -> Int? {
        if let tokens = fastTokenCountLineInfo(line)?.tokens {
            return tokens
        }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let lastUsage = info["last_token_usage"] as? [String: Any] else {
            return nil
        }

        return intValue(lastUsage["total_tokens"])
    }

    func tokenCountEvent(from line: String) -> CodexTokenCountEvent? {
        if let event = fastTokenCountLineInfo(line),
           let date = parseTimestamp(event.timestamp) {
            return CodexTokenCountEvent(timestamp: event.timestamp, date: date, tokens: event.tokens)
        }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = parseTimestamp(timestamp),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let lastUsage = info["last_token_usage"] as? [String: Any],
              let tokens = intValue(lastUsage["total_tokens"]) else {
            return nil
        }

        return CodexTokenCountEvent(timestamp: timestamp, date: date, tokens: tokens)
    }

    func fastTokenCountLineInfo(_ line: String) -> (timestamp: String, tokens: Int)? {
        guard lineContainsTokenCountPayload(line),
              let timestamp = fastJSONStringValue(for: "timestamp", in: line),
              let tokens = fastLastTokenUsageTotal(in: line) else {
            return nil
        }

        return (timestamp, tokens)
    }

    private func fallbackMeta(from line: String) -> SessionMetaInfo? {
        guard line.range(of: #""type"\s*:\s*"session_meta""#, options: .regularExpression) != nil else {
            return nil
        }

        let threadSource = jsonStringValue(for: "thread_source", in: line)
        let hasSubagentSource = line.range(
            of: #""source"\s*:\s*\{\s*"subagent"\s*:"#,
            options: .regularExpression
        ) != nil
        let isSubagent = threadSource == "subagent" || hasSubagentSource
        guard isSubagent else {
            return SessionMetaInfo(isSubagent: false, parentThreadID: nil)
        }

        return SessionMetaInfo(
            isSubagent: true,
            parentThreadID: (
                jsonStringValue(for: "parent_thread_id", in: line)
                    ?? jsonStringValue(for: "parentThreadId", in: line)
            )?.lowercased()
        )
    }

    private func normalizedTitle(from text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestRange = candidate.range(of: "## My request for Codex:") {
            candidate = String(candidate[requestRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for line in candidate.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("<environment_context"),
                  !trimmed.hasPrefix("</environment_context"),
                  !trimmed.hasPrefix("<permissions instructions"),
                  !trimmed.hasPrefix("<app-context"),
                  !trimmed.hasPrefix("# Files mentioned"),
                  !trimmed.hasPrefix("# In app browser"),
                  !trimmed.hasPrefix("## My request for Codex:"),
                  !trimmed.hasPrefix("- ") else {
                continue
            }
            return trimmed
        }

        return nil
    }

    private func lineMarksCompletion(_ line: String) -> Bool {
        line.contains(#""phase":"final""#)
            || line.contains(#""phase": "final""#)
            || line.contains(#""phase":"final_answer""#)
            || line.contains(#""phase": "final_answer""#)
            || terminalEventTypes.contains { type in
                line.contains("\"type\":\"\(type)\"")
                    || line.contains("\"type\": \"\(type)\"")
            }
    }

    private func lineMarksActivity(_ line: String) -> Bool {
        line.contains(#""type":"response_item""#)
            || line.contains(#""type": "response_item""#)
            || line.contains("response.output_item.added")
            || line.contains("response.output_text.delta")
            || line.contains(#""status":"in_progress""#)
            || line.contains(#""status": "in_progress""#)
    }

    private func jsonStringValue(for key: String, in line: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"""# + escapedKey + #""\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[valueRange])
    }

    private func lineContainsTokenCountPayload(_ line: String) -> Bool {
        line.contains(#""type":"token_count""#)
            || line.contains(#""type": "token_count""#)
            || line.contains(#""type" : "token_count""#)
    }

    private func fastLastTokenUsageTotal(in line: String) -> Int? {
        guard let usageRange = line.range(of: #""last_token_usage""#),
              let tokenRange = line[usageRange.upperBound...].range(of: #""total_tokens""#),
              let colonRange = line[tokenRange.upperBound...].range(of: ":") else {
            return nil
        }

        var index = colonRange.upperBound
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }

        let start = index
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }

        guard start < index else {
            return nil
        }
        return Int(line[start..<index])
    }

    private func fastJSONStringValue(for key: String, in line: String) -> String? {
        guard let keyRange = line.range(of: #"""# + key + #"""#),
              let colonRange = line[keyRange.upperBound...].range(of: ":"),
              let quoteStart = line[colonRange.upperBound...].firstIndex(of: "\"") else {
            return nil
        }

        var index = line.index(after: quoteStart)
        var value = ""
        var isEscaped = false

        while index < line.endIndex {
            let character = line[index]
            if isEscaped {
                value.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
            index = line.index(after: index)
        }

        return nil
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else {
            return rhs
        }
        return max(lhs, rhs)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double.rounded())
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class CodexTimestampParser: @unchecked Sendable {
    private let lock = NSLock()
    private let fractionalFormatter: ISO8601DateFormatter
    private let plainFormatter: ISO8601DateFormatter

    init() {
        fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
    }

    func parse(_ value: String) -> Date? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer {
            lock.unlock()
        }

        return fractionalFormatter.string(from: date)
    }
}
