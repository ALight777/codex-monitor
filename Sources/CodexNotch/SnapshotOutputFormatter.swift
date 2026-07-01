import Foundation

enum TaskBadgeFormatter {
    static func subagentBadgeText(for count: Int) -> String? {
        count > 0 ? "子代理 \(count)" : nil
    }
}

enum SnapshotOutputFormatter {
    static func humanLines(for snapshot: UsageSnapshot, taskLimit: Int = 4) -> [String] {
        var lines = [
            "primary=\(Formatters.percent(snapshot.primaryPercent)) secondary=\(Formatters.percent(snapshot.secondaryPercent)) running=\(snapshot.isRunning)",
            "usage1h=\(optionalInt(snapshot.usage1h)) usage24h=\(snapshot.usage24h) usage7d=\(snapshot.usage7d) usage30d=\(snapshot.usage30d)",
            "spark=\(snapshot.sparkQuotaWindows.map { "\($0.label)=\($0.remainingText)" }.joined(separator: ","))",
            "monitor snapshot_ms=\(optionalInt(snapshot.monitorStats.lastSnapshotDurationMs)) usage_ms=\(optionalInt(snapshot.monitorStats.lastUsageDurationMs)) delta_ms=\(optionalInt(snapshot.monitorStats.lastDeltaDurationMs)) rate=\(snapshot.monitorStats.lastRateLimitSource) watched=\(snapshot.monitorStats.watchedPathCount) context_scans=\(snapshot.monitorStats.jsonlContextScans) model_tokens=\(snapshot.monitorStats.monitorModelTokens)"
        ]

        for task in snapshot.tasks.prefix(taskLimit) {
            lines.append(
                "task=\(task.status.label) \(task.title) \(task.tokenCount) "
                    + "delta10m=\(Formatters.signedCompactTokens(task.delta10mTokens)) "
                    + "today=\(Formatters.compactTokensWithShare(tokens: task.todayTokens, sharePercent: task.todaySharePercent)) "
                    + "ctx=\(Formatters.compactTokenRatio(task.contextInputTokens, task.contextWindowTokens))"
            )
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
            primaryResetsAt: snapshot.primaryResetsAt,
            secondaryResetsAt: snapshot.secondaryResetsAt,
            running: snapshot.isRunning,
            usage1h: snapshot.usage1h,
            usage24h: snapshot.usage24h,
            usage7d: snapshot.usage7d,
            usage30d: snapshot.usage30d,
            sparkQuotaWindows: snapshot.sparkQuotaWindows.map(SnapshotSparkQuotaWindowJSON.init(window:)),
            lastUpdated: ISO8601DateFormatter().string(from: snapshot.lastUpdated),
            error: snapshot.errorMessage,
            monitor: SnapshotMonitorJSON(stats: snapshot.monitorStats),
            tasks: snapshot.tasks.prefix(taskLimit).map(SnapshotTaskJSON.init(task:))
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data(#"{"error":"Unable to encode snapshot"}"#.utf8)
    }

    private static func optionalInt(_ value: Int?) -> String {
        value.map(String.init) ?? "--"
    }
}

private struct SnapshotJSON: Encodable {
    let primaryPercent: Int?
    let secondaryPercent: Int?
    let primaryResetsAt: Int?
    let secondaryResetsAt: Int?
    let running: Bool
    let usage1h: Int?
    let usage24h: Int
    let usage7d: Int
    let usage30d: Int
    let sparkQuotaWindows: [SnapshotSparkQuotaWindowJSON]
    let lastUpdated: String
    let error: String?
    let monitor: SnapshotMonitorJSON
    let tasks: [SnapshotTaskJSON]

    enum CodingKeys: String, CodingKey {
        case primaryPercent = "primary_percent"
        case secondaryPercent = "secondary_percent"
        case primaryResetsAt = "primary_reset_at"
        case secondaryResetsAt = "secondary_reset_at"
        case running
        case usage1h = "usage_1h"
        case usage24h = "usage_24h"
        case usage7d = "usage_7d"
        case usage30d = "usage_30d"
        case sparkQuotaWindows = "spark_quota_windows"
        case lastUpdated = "last_updated"
        case error
        case monitor
        case tasks
    }
}

private struct SnapshotMonitorJSON: Encodable {
    let lastSnapshotDurationMs: Int?
    let lastUsageDurationMs: Int?
    let lastDeltaDurationMs: Int?
    let lastRateLimitSource: String
    let watchedPathCount: Int
    let jsonlContextScans: Int
    let monitorModelTokens: Int

    init(stats: MonitorPerformanceStats) {
        self.lastSnapshotDurationMs = stats.lastSnapshotDurationMs
        self.lastUsageDurationMs = stats.lastUsageDurationMs
        self.lastDeltaDurationMs = stats.lastDeltaDurationMs
        self.lastRateLimitSource = stats.lastRateLimitSource
        self.watchedPathCount = stats.watchedPathCount
        self.jsonlContextScans = stats.jsonlContextScans
        self.monitorModelTokens = stats.monitorModelTokens
    }

    enum CodingKeys: String, CodingKey {
        case lastSnapshotDurationMs = "last_snapshot_duration_ms"
        case lastUsageDurationMs = "last_usage_duration_ms"
        case lastDeltaDurationMs = "last_delta_duration_ms"
        case lastRateLimitSource = "last_rate_limit_source"
        case watchedPathCount = "watched_path_count"
        case jsonlContextScans = "jsonl_context_scans"
        case monitorModelTokens = "monitor_model_tokens"
    }
}

private struct SnapshotSparkQuotaWindowJSON: Encodable {
    let id: String
    let label: String
    let remainingPercent: Int?
    let usedPercent: Double?
    let resetAt: Int?
    let resetText: String?

    init(window: SparkQuotaWindow) {
        self.id = window.id
        self.label = window.label
        self.remainingPercent = window.remainingPercent
        self.usedPercent = window.usedPercent
        self.resetAt = window.resetAt
        self.resetText = window.resetText
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case remainingPercent = "remaining_percent"
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case resetText = "reset_text"
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
    let delta10mTokens: Int?
    let delta1hTokens: Int?
    let todayTokens: Int?
    let todaySharePercent: Double?
    let contextInputTokens: Int?
    let contextWindowTokens: Int?
    let contextPercent: Double?
    let contextUpdatedAt: String?
    let updatedAt: String

    init(task: CodexTask) {
        self.id = task.id
        self.title = task.title
        self.status = task.status.rawValue
        self.statusLabel = task.status.label
        self.detail = task.detail
        self.tokens = task.tokenCount
        self.subagents = task.activeSubagentCount
        self.delta10mTokens = task.delta10mTokens
        self.delta1hTokens = task.delta1hTokens
        self.todayTokens = task.todayTokens
        self.todaySharePercent = task.todaySharePercent
        self.contextInputTokens = task.contextInputTokens
        self.contextWindowTokens = task.contextWindowTokens
        self.contextPercent = task.contextPercent
        self.contextUpdatedAt = task.contextUpdatedAt.map { ISO8601DateFormatter().string(from: $0) }
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
        case delta10mTokens = "delta_10m_tokens"
        case delta1hTokens = "delta_1h_tokens"
        case todayTokens = "today_tokens"
        case todaySharePercent = "today_share_percent"
        case contextInputTokens = "context_input_tokens"
        case contextWindowTokens = "context_window_tokens"
        case contextPercent = "context_percent"
        case contextUpdatedAt = "context_updated_at"
        case updatedAt = "updated_at"
    }
}
