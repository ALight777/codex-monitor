import Foundation

enum SettingsShortcutFilter {
    static func shouldSuppressTextInputKey(
        characters: String?,
        hasCommand: Bool,
        hasControl: Bool,
        hasOption: Bool,
        hasShift: Bool
    ) -> Bool {
        guard hasCommand || hasControl else {
            return false
        }

        let text = characters ?? ""
        guard !text.isEmpty else {
            return false
        }

        if hasCommand,
           !hasControl,
           !hasOption,
           isAllowedCommandShortcut(text, hasShift: hasShift) {
            return false
        }

        return hasCommand || text.contains("⌘") || text.contains("⌃") || text.contains("⌥")
    }

    private static func isAllowedCommandShortcut(_ characters: String, hasShift: Bool) -> Bool {
        let key = characters.lowercased()
        if hasShift {
            return key == "z"
        }
        return ["a", "c", "q", "r", "v", "x", "z"].contains(key)
    }
}

struct UsageSnapshot: Equatable {
    var primaryPercent: Int?
    var secondaryPercent: Int?
    var primaryResetsAt: Int?
    var secondaryResetsAt: Int?
    var usage1h: Int?
    var usage24h: Int
    var usage7d: Int
    var usage30d: Int
    var sparkQuotaWindows: [SparkQuotaWindow]
    var tasks: [CodexTask]
    var isRunning: Bool
    var lastUpdated: Date
    var errorMessage: String?
    var monitorStats: MonitorPerformanceStats = .empty

    static let empty = UsageSnapshot(
        primaryPercent: nil,
        secondaryPercent: nil,
        primaryResetsAt: nil,
        secondaryResetsAt: nil,
        usage1h: nil,
        usage24h: 0,
        usage7d: 0,
        usage30d: 0,
        sparkQuotaWindows: [],
        tasks: [],
        isRunning: false,
        lastUpdated: Date(),
        errorMessage: nil
    )
}

struct MonitorPerformanceStats: Equatable, Sendable {
    var lastSnapshotDurationMs: Int?
    var lastUsageDurationMs: Int?
    var lastDeltaDurationMs: Int?
    var lastRateLimitSource: String
    var watchedPathCount: Int
    var jsonlContextScans: Int
    var monitorModelTokens: Int

    static let empty = MonitorPerformanceStats(
        lastSnapshotDurationMs: nil,
        lastUsageDurationMs: nil,
        lastDeltaDurationMs: nil,
        lastRateLimitSource: "none",
        watchedPathCount: 0,
        jsonlContextScans: 0,
        monitorModelTokens: 0
    )
}

struct PeriodUsage: Equatable, Sendable {
    var day: Int
    var week: Int
    var month: Int

    static let zero = PeriodUsage(day: 0, week: 0, month: 0)
}

struct CodexTask: Identifiable, Equatable {
    let id: String
    let title: String
    let status: TaskStatus
    let detail: String
    let tokenCount: Int
    let updatedAt: Date
    let activeSubagentCount: Int
    let delta10mTokens: Int?
    let delta1hTokens: Int?
    let todayTokens: Int?
    let todaySharePercent: Double?
    let contextInputTokens: Int?
    let contextWindowTokens: Int?
    let contextPercent: Double?
    let contextUpdatedAt: Date?

    init(
        id: String,
        title: String,
        status: TaskStatus,
        detail: String,
        tokenCount: Int,
        updatedAt: Date,
        activeSubagentCount: Int = 0,
        delta10mTokens: Int? = nil,
        delta1hTokens: Int? = nil,
        todayTokens: Int? = nil,
        todaySharePercent: Double? = nil,
        contextInputTokens: Int? = nil,
        contextWindowTokens: Int? = nil,
        contextPercent: Double? = nil,
        contextUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.tokenCount = tokenCount
        self.updatedAt = updatedAt
        self.activeSubagentCount = activeSubagentCount
        self.delta10mTokens = delta10mTokens
        self.delta1hTokens = delta1hTokens
        self.todayTokens = todayTokens
        self.todaySharePercent = todaySharePercent
        self.contextInputTokens = contextInputTokens
        self.contextWindowTokens = contextWindowTokens
        self.contextPercent = contextPercent
        self.contextUpdatedAt = contextUpdatedAt
    }

    func withTodaySharePercent(totalTokens: Int) -> CodexTask {
        CodexTask(
            id: id,
            title: title,
            status: status,
            detail: detail,
            tokenCount: tokenCount,
            updatedAt: updatedAt,
            activeSubagentCount: activeSubagentCount,
            delta10mTokens: delta10mTokens,
            delta1hTokens: delta1hTokens,
            todayTokens: todayTokens,
            todaySharePercent: Self.sharePercent(tokens: todayTokens, totalTokens: totalTokens),
            contextInputTokens: contextInputTokens,
            contextWindowTokens: contextWindowTokens,
            contextPercent: contextPercent,
            contextUpdatedAt: contextUpdatedAt
        )
    }

    static func sharePercent(tokens: Int?, totalTokens: Int) -> Double? {
        guard let tokens, totalTokens > 0 else {
            return nil
        }
        let percent = Double(max(0, tokens)) / Double(totalTokens) * 100
        guard percent.isFinite else {
            return nil
        }
        return min(100, max(0, percent))
    }
}

struct TokenContextUsage: Equatable {
    let inputTokens: Int
    let windowTokens: Int
    let percent: Double
    let updatedAt: Date
}

enum TokenContextUsageParser {
    static func parse(line: String) -> TokenContextUsage? {
        guard line.contains(#""token_count""#) else {
            return nil
        }

        if let timestamp = jsonStringValue(for: "timestamp", in: line),
           let updatedAt = parseTimestamp(timestamp),
           let inputTokens = lastTokenUsageIntValue(for: "input_tokens", in: line),
           let windowTokens = intValue(for: "model_context_window", in: line),
           inputTokens > 0,
           windowTokens > 0 {
            return TokenContextUsage(
                inputTokens: inputTokens,
                windowTokens: windowTokens,
                percent: Double(inputTokens) / Double(windowTokens) * 100.0,
                updatedAt: updatedAt
            )
        }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let updatedAt = parseTimestamp(timestamp),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let lastUsage = (info["last_token_usage"] ?? info["lastTokenUsage"]) as? [String: Any] else {
            return nil
        }

        let inputTokens = intValue(lastUsage["input_tokens"] ?? lastUsage["inputTokens"])
        let windowTokens = intValue(
            payload["model_context_window"]
                ?? payload["modelContextWindow"]
                ?? info["model_context_window"]
                ?? info["modelContextWindow"]
        )
        guard let inputTokens,
              let windowTokens,
              inputTokens > 0,
              windowTokens > 0 else {
            return nil
        }

        return TokenContextUsage(
            inputTokens: inputTokens,
            windowTokens: windowTokens,
            percent: Double(inputTokens) / Double(windowTokens) * 100.0,
            updatedAt: updatedAt
        )
    }

    private static func lastTokenUsageIntValue(for key: String, in line: String) -> Int? {
        guard let usageRange = line.range(of: #""last_token_usage""#) else {
            return nil
        }
        return intValue(for: key, in: line[usageRange.upperBound...])
    }

    private static func intValue(for key: String, in line: String) -> Int? {
        intValue(for: key, in: line[line.startIndex...])
    }

    private static func intValue(for key: String, in text: Substring) -> Int? {
        guard let keyRange = text.range(of: #"""# + key + #"""#),
              let colonRange = text[keyRange.upperBound...].range(of: ":") else {
            return nil
        }

        var index = colonRange.upperBound
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }

        let start = index
        while index < text.endIndex, text[index].isNumber {
            index = text.index(after: index)
        }

        guard start < index else {
            return nil
        }
        return Int(text[start..<index])
    }

    private static func jsonStringValue(for key: String, in line: String) -> String? {
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

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func intValue(_ value: Any?) -> Int? {
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
}

enum TaskStatus: String, Equatable {
    case running
    case recent
    case idle

    var label: String {
        switch self {
        case .running:
            "运行中"
        case .recent:
            "最近"
        case .idle:
            "空闲"
        }
    }

    var hudLabel: String {
        switch self {
        case .running:
            "RUNNING"
        case .recent, .idle:
            "IDLE"
        }
    }
}

enum RateLimitSourcePreference: String, CaseIterable, Identifiable {
    case appServerFirst
    case localFilesOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appServerFirst:
            "实时接口优先"
        case .localFilesOnly:
            "仅本地记录"
        }
    }
}

enum TaskHistoryRange: String, CaseIterable, Identifiable {
    case day
    case threeDays
    case sevenDays
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day:
            "24小时"
        case .threeDays:
            "3天"
        case .sevenDays:
            "7天"
        case .month:
            "30天"
        }
    }

    var seconds: Int {
        switch self {
        case .day:
            24 * 60 * 60
        case .threeDays:
            3 * 24 * 60 * 60
        case .sevenDays:
            7 * 24 * 60 * 60
        case .month:
            30 * 24 * 60 * 60
        }
    }

    var queryLimit: Int {
        switch self {
        case .day:
            40
        case .threeDays:
            60
        case .sevenDays:
            80
        case .month:
            120
        }
    }
}

enum RemoteCodexDataSource: String, CaseIterable, Identifiable, Equatable {
    case cliProxyAPI
    case cpaManagerPlus

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cliProxyAPI:
            "CLIProxyAPI"
        case .cpaManagerPlus:
            "CPA Manager Plus"
        }
    }

    var detailLabel: String {
        switch self {
        case .cliProxyAPI:
            "直接从 CLIProxyAPI 读取账号状态"
        case .cpaManagerPlus:
            "从 CPA Manager Plus 读取巡检和用量"
        }
    }
}

enum NotchDisplaySource: String, CaseIterable, Identifiable, Equatable {
    case automatic
    case codex
    case remoteCodex
    case newAPI
    case subAPI

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic:
            "自动"
        case .codex:
            "Codex"
        case .remoteCodex:
            "CLIProxyAPI"
        case .newAPI:
            "NewAPI"
        case .subAPI:
            "Sub2API"
        }
    }
}

enum BalanceMonitorSource: String, CaseIterable, Identifiable, Equatable, Codable {
    case newAPI
    case subAPI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newAPI:
            "NewAPI"
        case .subAPI:
            "Sub2API"
        }
    }
}

enum RefreshCadence {
    static func pendingSnapshotDelay(for interval: TimeInterval) -> TimeInterval {
        clamped((interval * 0.5).rounded(), min: 1, max: 3)
    }

    static func pendingUsageDelay(for interval: TimeInterval) -> TimeInterval {
        clamped((interval * 0.25).rounded(), min: 5, max: 15)
    }

    private static func clamped(_ value: TimeInterval, min: TimeInterval, max: TimeInterval) -> TimeInterval {
        Swift.min(max, Swift.max(min, value))
    }
}

enum BalanceRefreshCadence {
    static func refreshInterval(base: TimeInterval, consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0 else {
            return base
        }
        return min(30, base)
    }
}

struct ThreadRecord: Decodable {
    let id: String
    let title: String
    let tokensUsed: Int
    let model: String?
    let reasoningEffort: String?
    let rolloutPath: String
    let updatedAt: Int
    let activeSubagentCount: Int

    init(
        id: String,
        title: String,
        tokensUsed: Int,
        model: String?,
        reasoningEffort: String?,
        rolloutPath: String,
        updatedAt: Int,
        activeSubagentCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.tokensUsed = tokensUsed
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.rolloutPath = rolloutPath
        self.updatedAt = updatedAt
        self.activeSubagentCount = activeSubagentCount
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case tokensUsed = "tokens_used"
        case model
        case reasoningEffort = "reasoning_effort"
        case rolloutPath = "rollout_path"
        case updatedAt = "updated_at"
        case activeSubagentCount = "subagent_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            tokensUsed: try container.decode(Int.self, forKey: .tokensUsed),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            reasoningEffort: try container.decodeIfPresent(String.self, forKey: .reasoningEffort),
            rolloutPath: try container.decode(String.self, forKey: .rolloutPath),
            updatedAt: try container.decode(Int.self, forKey: .updatedAt),
            activeSubagentCount: try container.decodeIfPresent(Int.self, forKey: .activeSubagentCount) ?? 0
        )
    }
}

struct SessionIndexRecord: Decodable {
    let id: String
    let threadName: String

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
    }
}

struct UsageLogRecord: Decodable {
    let ts: Int
    let feedbackLogBody: String

    enum CodingKeys: String, CodingKey {
        case ts
        case feedbackLogBody = "feedback_log_body"
    }
}

struct ActivityRecord: Decodable {
    let threadId: String?
    let latestActivity: Int?
    let latestDone: Int?

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case latestActivity = "latest_activity"
        case latestDone = "latest_done"
    }
}

struct ThreadTokenRecord: Decodable {
    let id: String
    let tokensUsed: Int

    enum CodingKeys: String, CodingKey {
        case id
        case tokensUsed = "tokens_used"
    }
}

struct ThreadIDRecord: Decodable {
    let id: String
}

struct RateLimitSnapshot: Equatable {
    let primaryPercent: Int?
    let secondaryPercent: Int?
    let primaryResetsAt: Int?
    let secondaryResetsAt: Int?
    let capturedAt: Date?
    let isPrimaryCodexLimit: Bool
    let sparkQuotaWindows: [SparkQuotaWindow]

    init(
        primaryPercent: Int?,
        secondaryPercent: Int?,
        primaryResetsAt: Int?,
        secondaryResetsAt: Int?,
        capturedAt: Date?,
        isPrimaryCodexLimit: Bool,
        sparkQuotaWindows: [SparkQuotaWindow] = []
    ) {
        self.primaryPercent = primaryPercent
        self.secondaryPercent = secondaryPercent
        self.primaryResetsAt = primaryResetsAt
        self.secondaryResetsAt = secondaryResetsAt
        self.capturedAt = capturedAt
        self.isPrimaryCodexLimit = isPrimaryCodexLimit
        self.sparkQuotaWindows = sparkQuotaWindows.sortedForSparkQuotaDisplay
    }

    func primaryDisplayPercent(now: Date = Date()) -> Int? {
        displayPercent(primaryPercent, resetsAt: primaryResetsAt, now: now)
    }

    func secondaryDisplayPercent(now: Date = Date()) -> Int? {
        displayPercent(secondaryPercent, resetsAt: secondaryResetsAt, now: now)
    }

    private func displayPercent(_ percent: Int?, resetsAt: Int?, now: Date) -> Int? {
        if let resetsAt, Int(now.timeIntervalSince1970) >= resetsAt {
            return 100
        }
        if let percent, percent >= 99 {
            return 100
        }
        return percent
    }

    func withSparkQuotaWindows(_ windows: [SparkQuotaWindow]) -> RateLimitSnapshot {
        RateLimitSnapshot(
            primaryPercent: primaryPercent,
            secondaryPercent: secondaryPercent,
            primaryResetsAt: primaryResetsAt,
            secondaryResetsAt: secondaryResetsAt,
            capturedAt: capturedAt,
            isPrimaryCodexLimit: isPrimaryCodexLimit,
            sparkQuotaWindows: windows
        )
    }

}

struct SparkQuotaWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let remainingPercent: Int?
    let usedPercent: Double?
    let resetAt: Int?
    let resetText: String?

    var remainingText: String {
        guard let remainingPercent else {
            return "--"
        }
        return "\(remainingPercent)%"
    }

    func displayRemainingPercent(now: Date = Date()) -> Int? {
        if let resetAt, Int(now.timeIntervalSince1970) >= resetAt {
            return 100
        }
        if let remainingPercent, remainingPercent >= 99 {
            return 100
        }
        return remainingPercent
    }
}

extension Array where Element == SparkQuotaWindow {
    var sortedForSparkQuotaDisplay: [SparkQuotaWindow] {
        sorted {
            if $0.sortPriority == $1.sortPriority {
                return $0.label < $1.label
            }
            return $0.sortPriority < $1.sortPriority
        }
    }

    var deduplicatedSparkQuotaWindows: [SparkQuotaWindow] {
        var seen: Set<String> = []
        var windows: [SparkQuotaWindow] = []
        for window in self {
            let key = window.label.lowercased()
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            windows.append(window)
        }
        return windows.sortedForSparkQuotaDisplay
    }
}

private extension SparkQuotaWindow {
    var sortPriority: Int {
        switch label.lowercased() {
        case "5h":
            return 0
        case "7d":
            return 1
        default:
            return 2
        }
    }
}
