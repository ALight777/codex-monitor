import Foundation

enum TaskBadgeFormatter {
    static func subagentBadgeText(for count: Int) -> String? {
        count > 0 ? "子代理 \(count)" : nil
    }
}

enum SnapshotOutputFormatter {
    static func humanLines(for snapshot: UsageSnapshot, taskLimit: Int = 4) -> [String] {
        let quotaText = snapshot.displayRateLimitWindows
            .map { "\($0.shortLabel)=\(Formatters.percent($0.remainingPercent))" }
            .joined(separator: " ")
        var lines = [
            "quotas=\(quotaText.isEmpty ? "--" : quotaText) running=\(snapshot.isRunning)",
            "usageToday=\(snapshot.usageToday) usage24h=\(snapshot.usage24h) usage7d=\(snapshot.usage7d) usage30d=\(snapshot.usage30d)"
        ]
        lines.append("quota_status=\(snapshot.rateLimitStatus.detail)")

        for task in snapshot.tasks.prefix(taskLimit) {
            lines.append("task=\(task.status.label) \(task.title) \(task.tokenCount)")
        }

        if let error = snapshot.errorMessage {
            lines.append("error=\(error)")
        }

        return lines
    }

    static func jsonData(for snapshot: UsageSnapshot, taskLimit: Int = 4) -> Data {
        let payload = SnapshotJSON(
            primaryPercent: snapshot.primaryPercent,
            secondaryPercent: snapshot.secondaryPercent,
            quotaWindows: snapshot.displayRateLimitWindows.map(SnapshotQuotaWindowJSON.init(window:)),
            quotaStatus: SnapshotQuotaStatusJSON(snapshot.rateLimitStatus),
            resetCredits: snapshot.resetCredits.map(SnapshotResetCreditsJSON.init(resetCredits:)),
            running: snapshot.isRunning,
            usageToday: snapshot.usageToday,
            usage24h: snapshot.usage24h,
            usage7d: snapshot.usage7d,
            usage30d: snapshot.usage30d,
            usageCoverage: snapshot.usageCoverage,
            lastUpdated: ISO8601DateFormatter().string(from: snapshot.lastUpdated),
            error: snapshot.errorMessage,
            tasks: snapshot.tasks.prefix(taskLimit).map(SnapshotTaskJSON.init(task:))
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data(#"{"error":"Unable to encode snapshot"}"#.utf8)
    }
}

private struct SnapshotJSON: Encodable {
    let primaryPercent: Int?
    let secondaryPercent: Int?
    let quotaWindows: [SnapshotQuotaWindowJSON]
    let quotaStatus: SnapshotQuotaStatusJSON
    let resetCredits: SnapshotResetCreditsJSON?
    let running: Bool
    let usageToday: Int
    let usage24h: Int
    let usage7d: Int
    let usage30d: Int
    let usageCoverage: UsageCoverage
    let lastUpdated: String
    let error: String?
    let tasks: [SnapshotTaskJSON]

    enum CodingKeys: String, CodingKey {
        case primaryPercent = "primary_percent"
        case secondaryPercent = "secondary_percent"
        case quotaWindows = "quota_windows"
        case quotaStatus = "quota_status"
        case resetCredits = "reset_credits"
        case running
        case usageToday = "usage_today"
        case usage24h = "usage_24h"
        case usage7d = "usage_7d"
        case usage30d = "usage_30d"
        case usageCoverage = "usage_coverage"
        case lastUpdated = "last_updated"
        case error
        case tasks
    }
}

private struct SnapshotQuotaStatusJSON: Encodable {
    let source: String
    let lastSuccessfulAt: String?
    let lastAttemptAt: String?
    let refreshFailed: Bool
    let awaitingReset: Bool
    let message: String

    init(_ status: RateLimitStatus) {
        source = status.source.rawValue
        lastSuccessfulAt = status.lastSuccessfulAt.map { ISO8601DateFormatter().string(from: $0) }
        lastAttemptAt = status.lastAttemptAt.map { ISO8601DateFormatter().string(from: $0) }
        refreshFailed = status.refreshFailed
        awaitingReset = status.awaitingReset
        message = status.detail
    }

    enum CodingKeys: String, CodingKey {
        case source, message
        case lastSuccessfulAt = "last_successful_at"
        case lastAttemptAt = "last_attempt_at"
        case refreshFailed = "refresh_failed"
        case awaitingReset = "awaiting_reset"
    }
}

private struct SnapshotResetCreditsJSON: Encodable {
    let availableCount: Int
    let expiresAt: [Int64]

    init(resetCredits: RateLimitResetCredits) {
        availableCount = resetCredits.availableCount
        expiresAt = resetCredits.credits
            .map { Int64($0.expiresAt.timeIntervalSince1970.rounded(.down)) }
            .sorted()
    }

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case expiresAt = "expires_at"
    }
}

private struct SnapshotQuotaWindowJSON: Encodable {
    let id: String
    let label: String
    let remainingPercent: Int?
    let resetsAt: String?

    init(window: UsageQuotaWindow) {
        id = window.id
        label = window.shortLabel
        remainingPercent = window.remainingPercent
        resetsAt = window.resetsAt.map { ISO8601DateFormatter().string(from: $0) }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case remainingPercent = "remaining_percent"
        case resetsAt = "resets_at"
    }
}

private struct SnapshotTaskJSON: Encodable {
    let id: String
    let title: String
    let status: String
    let statusLabel: String
    let detail: String
    let tokens: Int
    let subagents: Int
    let updatedAt: String

    init(task: CodexTask) {
        self.id = task.id
        self.title = task.title
        self.status = task.status.rawValue
        self.statusLabel = task.status.label
        self.detail = task.displayDetail()
        self.tokens = task.tokenCount
        self.subagents = task.activeSubagentCount
        self.updatedAt = ISO8601DateFormatter().string(from: task.updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case statusLabel = "status_label"
        case detail
        case tokens
        case subagents
        case updatedAt = "updated_at"
    }
}
