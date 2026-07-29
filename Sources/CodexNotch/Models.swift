import Foundation

typealias NotchPointAdjustment = Double

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
    var primaryResetsAt: Date? = nil
    var secondaryResetsAt: Date? = nil
    var rateLimitWindows: [UsageQuotaWindow] = []
    var resetCredits: RateLimitResetCredits? = nil
    var usage24h: Int
    var usage7d: Int
    var usage30d: Int
    var tasks: [CodexTask]
    var isRunning: Bool
    var lastUpdated: Date
    var errorMessage: String?

    static let empty = UsageSnapshot(
        primaryPercent: nil,
        secondaryPercent: nil,
        primaryResetsAt: nil,
        secondaryResetsAt: nil,
        usage24h: 0,
        usage7d: 0,
        usage30d: 0,
        tasks: [],
        isRunning: false,
        lastUpdated: Date(),
        errorMessage: nil
    )

    func stabilizedRateLimits(against previous: UsageSnapshot) -> UsageSnapshot {
        var copy = self
        if copy.resetCredits == nil {
            copy.resetCredits = previous.resetCredits
        }

        if !copy.rateLimitWindows.isEmpty {
            return copy
        }

        if previous.rateLimitWindows.isEmpty {
            if copy.primaryPercent == nil {
                copy.primaryPercent = previous.primaryPercent
                copy.primaryResetsAt = previous.primaryResetsAt
            }
            if copy.secondaryPercent == nil {
                copy.secondaryPercent = previous.secondaryPercent
                copy.secondaryResetsAt = previous.secondaryResetsAt
            }
            return copy
        }

        if copy.primaryPercent == nil && copy.secondaryPercent == nil {
            copy.rateLimitWindows = previous.rateLimitWindows
            copy.primaryPercent = previous.primaryPercent
            copy.primaryResetsAt = previous.primaryResetsAt
            copy.secondaryPercent = previous.secondaryPercent
            copy.secondaryResetsAt = previous.secondaryResetsAt
        }
        return copy
    }

    var displayRateLimitWindows: [UsageQuotaWindow] {
        if !rateLimitWindows.isEmpty {
            return rateLimitWindows
        }

        var windows: [UsageQuotaWindow] = []
        if primaryPercent != nil || primaryResetsAt != nil {
            windows.append(
                UsageQuotaWindow(
                    id: "legacy-primary",
                    shortLabel: "5h",
                    remainingPercent: primaryPercent,
                    resetsAt: primaryResetsAt
                )
            )
        }
        if secondaryPercent != nil || secondaryResetsAt != nil {
            windows.append(
                UsageQuotaWindow(
                    id: "legacy-secondary",
                    shortLabel: "7d",
                    remainingPercent: secondaryPercent,
                    resetsAt: secondaryResetsAt
                )
            )
        }
        if windows.isEmpty {
            windows.append(
                UsageQuotaWindow(
                    id: "weekly-placeholder",
                    shortLabel: "7d",
                    remainingPercent: nil,
                    resetsAt: nil
                )
            )
        }
        return windows
    }
}

struct UsageQuotaWindow: Equatable, Identifiable {
    let id: String
    let shortLabel: String
    let remainingPercent: Int?
    let resetsAt: Date?
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

    init(
        id: String,
        title: String,
        status: TaskStatus,
        detail: String,
        tokenCount: Int,
        updatedAt: Date,
        activeSubagentCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.tokenCount = tokenCount
        self.updatedAt = updatedAt
        self.activeSubagentCount = activeSubagentCount
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
        clamped((interval * 0.25).rounded(), min: 15, max: 60)
    }

    private static func clamped(_ value: TimeInterval, min: TimeInterval, max: TimeInterval) -> TimeInterval {
        Swift.min(max, Swift.max(min, value))
    }
}

enum UsageRefreshCadence {
    private static let fileChangeMinimumInterval: TimeInterval = 60
    private static let fileChangeSettleDelay: TimeInterval = 4

    static func refreshInterval(configured: TimeInterval, lastDuration: TimeInterval?) -> TimeInterval {
        let base = clamped(configured.rounded(), min: 120, max: 1_800)
        guard let lastDuration, lastDuration > 0 else {
            return base
        }

        let adaptive = (lastDuration * 30).rounded()
        return clamped(max(base, adaptive), min: 120, max: 1_800)
    }

    static func fileChangeDelay(now: Date, lastCompletedAt: Date?) -> TimeInterval {
        guard let lastCompletedAt else {
            return fileChangeSettleDelay
        }

        let elapsed = max(0, now.timeIntervalSince(lastCompletedAt))
        return max(fileChangeSettleDelay, fileChangeMinimumInterval - elapsed)
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

struct RateLimitSnapshot: Equatable {
    let primaryPercent: Int?
    let secondaryPercent: Int?
    let primaryResetsAt: Int?
    let secondaryResetsAt: Int?
    let capturedAt: Date?
    let isPrimaryCodexLimit: Bool
    var windows: [UsageQuotaWindow] = []
    var resetCredits: RateLimitResetCredits? = nil

    static func freshest(
        appServer: RateLimitSnapshot?,
        localFiles: RateLimitSnapshot
    ) -> RateLimitSnapshot {
        guard let appServer else {
            return localFiles
        }

        let appServerCapturedAt = appServer.capturedAt ?? .distantPast
        let localCapturedAt = localFiles.capturedAt ?? .distantPast
        guard localCapturedAt > appServerCapturedAt else {
            return appServer
        }

        var result = localFiles
        if result.resetCredits == nil {
            result.resetCredits = appServer.resetCredits
        }
        return result
    }

    var primaryResetDate: Date? {
        resetDate(from: primaryResetsAt)
    }

    var secondaryResetDate: Date? {
        resetDate(from: secondaryResetsAt)
    }

    func primaryDisplayPercent(now: Date = Date()) -> Int? {
        displayPercent(primaryPercent, resetsAt: primaryResetsAt, now: now)
    }

    func secondaryDisplayPercent(now: Date = Date()) -> Int? {
        displayPercent(secondaryPercent, resetsAt: secondaryResetsAt, now: now)
    }

    func primaryDisplayResetDate(now: Date = Date()) -> Date? {
        displayResetDate(primaryResetsAt, now: now)
    }

    func secondaryDisplayResetDate(now: Date = Date()) -> Date? {
        displayResetDate(secondaryResetsAt, now: now)
    }

    func displayWindows(now: Date = Date()) -> [UsageQuotaWindow] {
        let source = windows.isEmpty ? legacyWindows() : windows
        return source.map { window in
            UsageQuotaWindow(
                id: window.id,
                shortLabel: window.shortLabel,
                remainingPercent: displayPercent(window.remainingPercent, resetsAt: window.resetsAt, now: now),
                resetsAt: displayResetDate(window.resetsAt, now: now)
            )
        }
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

    private func displayPercent(_ percent: Int?, resetsAt: Date?, now: Date) -> Int? {
        if let resetsAt, now >= resetsAt {
            return 100
        }
        if let percent, percent >= 99 {
            return 100
        }
        return percent
    }

    private func resetDate(from timestamp: Int?) -> Date? {
        guard let timestamp else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private func displayResetDate(_ timestamp: Int?, now: Date) -> Date? {
        guard let timestamp,
              Int(now.timeIntervalSince1970) < timestamp else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private func displayResetDate(_ date: Date?, now: Date) -> Date? {
        guard let date, now < date else {
            return nil
        }
        return date
    }

    private func legacyWindows() -> [UsageQuotaWindow] {
        var result: [UsageQuotaWindow] = []
        if primaryPercent != nil || primaryResetsAt != nil {
            result.append(
                UsageQuotaWindow(
                    id: "legacy-primary",
                    shortLabel: "5h",
                    remainingPercent: primaryPercent,
                    resetsAt: primaryResetDate
                )
            )
        }
        if secondaryPercent != nil || secondaryResetsAt != nil {
            result.append(
                UsageQuotaWindow(
                    id: "legacy-secondary",
                    shortLabel: "7d",
                    remainingPercent: secondaryPercent,
                    resetsAt: secondaryResetDate
                )
            )
        }
        return result
    }
}
