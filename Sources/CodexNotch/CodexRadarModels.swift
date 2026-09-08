import Foundation

enum CodexRadarDataSource: String, Codable, Equatable, Sendable {
    case authorizedAPI
    case publicSummary
    case publicMetrics
    case publicVisual
    case publicComposite

    var label: String {
        switch self {
        case .authorizedAPI: "授权 API"
        case .publicSummary: "旧版摘要"
        case .publicMetrics, .publicVisual, .publicComposite: "官网众测"
        }
    }

    var usesAverages: Bool { self == .publicMetrics || self == .publicVisual || self == .publicComposite }
}

enum CodexRadarDimension: String, CaseIterable, Sendable {
    case comprehensive, software, visual

    var title: String {
        switch self {
        case .comprehensive: "综合智能"
        case .software: "软件工程能力"
        case .visual: "视觉空间推理"
        }
    }

    var shortTitle: String {
        switch self {
        case .comprehensive: "综合智能"
        case .software: "软件工程"
        case .visual: "视觉空间"
        }
    }
}

enum CodexRadarPanelState: Equatable, Sendable {
    case disabled
    case loading
    case ready
    case stale
    case error
}

struct CodexRadarModelScore: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let score: Double?
    let status: String?
    let passed: Int?
    let tasks: Int?
    let costUSD: Double?
    let wallTime: String?
    var validTasks: Double? = nil
    var averageMinutes: Double? = nil
    var sampleLabel: String? = nil
}

struct CodexRadarQuotaRow: Identifiable, Equatable, Sendable {
    var id: String { tier }
    let tier: String
    let fiveHour: Double?
    let sevenDay: Double?
    let basis: String?
}

struct CodexRadarSnapshot: Equatable, Sendable {
    static let siteURL = URL(string: "https://codexradar.com")!
    static let attribution = "数据来自 Codex 雷达 codexradar.com"

    var state: CodexRadarPanelState
    var models: [CodexRadarModelScore]
    var quotaRows: [CodexRadarQuotaRow]
    var monitoredAt: Date?
    var quotaUpdatedAt: Date?
    var fetchedAt: Date?
    var status: String?
    var recommendation: String?
    var prediction: String?
    var dataSource: CodexRadarDataSource
    var attributionText: String
    var siteURL: URL
    var message: String?

    static let disabled = CodexRadarSnapshot(
        state: .disabled,
        models: [],
        quotaRows: [],
        monitoredAt: nil,
        quotaUpdatedAt: nil,
        fetchedAt: nil,
        status: nil,
        recommendation: nil,
        prediction: nil,
        dataSource: .publicSummary,
        attributionText: attribution,
        siteURL: siteURL,
        message: "CodexRadar 未启用"
    )

    static let loading = CodexRadarSnapshot(
        state: .loading,
        models: [],
        quotaRows: [],
        monitoredAt: nil,
        quotaUpdatedAt: nil,
        fetchedAt: nil,
        status: nil,
        recommendation: nil,
        prediction: nil,
        dataSource: .publicSummary,
        attributionText: attribution,
        siteURL: siteURL,
        message: "正在读取 CodexRadar"
    )

    var hasData: Bool {
        !models.isEmpty || !quotaRows.isEmpty || status != nil || prediction != nil
    }

    var displayUpdatedAt: Date? {
        // Fetching an unchanged response must not make the source data look newer.
        monitoredAt ?? quotaUpdatedAt
    }

    func withState(_ state: CodexRadarPanelState, message: String? = nil) -> CodexRadarSnapshot {
        var copy = self
        copy.state = state
        copy.message = message
        return copy
    }

    static func decode(
        data: Data,
        fetchedAt: Date,
        source: CodexRadarDataSource
    ) throws -> CodexRadarSnapshot {
        if source == .publicMetrics || source == .publicVisual {
            return try decodeMetrics(data: data, fetchedAt: fetchedAt, source: source)
        }
        let summary = try JSONDecoder().decode(CodexRadarSummaryDTO.self, from: data)
        let modelIQ = summary.modelIQ
        let modelCards = modelIQ?.modelCards ?? []
        let quotaRows = modelIQ?.quotaRadar?.rows?.map {
            CodexRadarQuotaRow(
                tier: $0.tier.nonBlank ?? "Unknown",
                fiveHour: $0.fiveHour,
                sevenDay: $0.sevenDay,
                basis: $0.basis?.nonBlank
            )
        } ?? []
        let requirements = summary.apiAccess?.requirements

        return CodexRadarSnapshot(
            state: .ready,
            models: modelCards,
            quotaRows: quotaRows,
            monitoredAt: (modelIQ?.updatedAt ?? summary.monitoredAt).flatMap(CodexRadarDateParser.parse),
            quotaUpdatedAt: modelIQ?.quotaRadar?.updatedAt.flatMap(CodexRadarDateParser.parse),
            fetchedAt: fetchedAt,
            status: summary.status?.nonBlank,
            recommendation: summary.recommendedAction?.nonBlank,
            prediction: summary.prediction?.summary?.nonBlank,
            dataSource: source,
            attributionText: requirements?.attributionText?.nonBlank ?? attribution,
            siteURL: requirements?.site.flatMap(URL.init(string:)) ?? siteURL,
            message: nil
        )
    }

    private static func decodeMetrics(data: Data, fetchedAt: Date, source: CodexRadarDataSource) throws -> CodexRadarSnapshot {
        let metrics = try JSONDecoder().decode(CodexRadarMetricsDTO.self, from: data)
        let visual = source == .publicVisual
        let validBenchmark = visual
            ? metrics.schema == 1 && metrics.benchmarkID == "pompeii-adjacency"
            : [2, 3].contains(metrics.schema) && metrics.benchmarkID == "deep-swe"
        guard validBenchmark,
              let updatedAt = CodexRadarDateParser.parse(metrics.sourceUpdatedAt) else {
            throw CodexRadarClientError.invalidResponse
        }
        var seen = Set<String>()
        let cards = metrics.points.compactMap { point -> CodexRadarModelScore? in
            let id = "\(point.model)|\(point.effort)"
            let count = visual ? point.validTasks : (metrics.schema == 2 ? point.weightedTotal : point.total)
            guard point.model.hasPrefix("gpt-"), let score = point.iq, score.isFinite,
                  score >= 0, let count, count.isFinite, count > 0,
                  let taskCount = Int(exactly: count.rounded()),
                  seen.insert(id).inserted else { return nil }
            let passed = metrics.schema == 2 ? point.weightedPassed : point.passed
            let cost = point.averagePriceUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let minutes = point.averageMinutes.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let benchmarkCount = point.benchmarkTasks.flatMap { Int(exactly: $0.rounded()) } ?? taskCount
            return CodexRadarModelScore(
                id: id, label: "\(point.model) \(point.effort)", score: score, status: nil,
                passed: visual ? nil : passed.flatMap { $0 >= 0 ? Int(exactly: $0.rounded()) : nil }, tasks: taskCount,
                costUSD: cost,
                wallTime: minutes.map { String(format: "均时 %.1f 分钟", $0) },
                validTasks: count, averageMinutes: minutes,
                sampleLabel: visual ? "覆盖 \(taskCount)/\(max(taskCount, benchmarkCount)) 题" : nil
            )
        }.sorted {
            if $0.score == $1.score { return $0.id < $1.id }
            return ($0.score ?? 0) > ($1.score ?? 0)
        }
        guard !cards.isEmpty else { throw CodexRadarClientError.emptyResponse }
        return CodexRadarSnapshot(
            state: .ready, models: cards, quotaRows: [], monitoredAt: updatedAt,
            quotaUpdatedAt: nil, fetchedAt: fetchedAt, status: visual ? "视觉空间推理" : "软件工程能力",
            recommendation: nil,
            prediction: nil, dataSource: source, attributionText: attribution,
            siteURL: siteURL, message: nil
        )
    }

    static func comprehensive(software: CodexRadarSnapshot, visual: CodexRadarSnapshot) -> CodexRadarSnapshot {
        var result = CodexRadarSnapshot.loading
        result.dataSource = .publicComposite
        result.status = CodexRadarDimension.comprehensive.title
        guard software.dataSource == .publicMetrics, visual.dataSource == .publicVisual,
              software.hasData, visual.hasData else {
            return result.withState(.error, message: "综合智能需要软件工程和视觉空间两个维度的有效数据")
        }
        let visualByID = Dictionary(visual.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.models = software.models.compactMap { left in
            guard let right = visualByID[left.id], let leftIQ = left.score, let rightIQ = right.score,
                  let leftCount = left.validTasks, let rightCount = right.validTasks,
                  leftCount > 0, rightCount > 0 else { return nil }
            let total = leftCount + rightCount
            func weighted(_ a: Double?, _ b: Double?) -> Double? {
                guard let a, let b else { return nil }
                let leftWeight = max(1, leftCount), rightWeight = max(1, rightCount)
                let value = (a * leftWeight + b * rightWeight) / (leftWeight + rightWeight)
                return value.isFinite ? value : nil
            }
            let minutes = weighted(left.averageMinutes, right.averageMinutes)
            return CodexRadarModelScore(
                id: left.id, label: left.label, score: weighted(leftIQ, rightIQ), status: nil,
                passed: nil, tasks: nil, costUSD: weighted(left.costUSD, right.costUSD),
                wallTime: minutes.map { String(format: "均时 %.1f 分钟", $0) },
                validTasks: total, averageMinutes: minutes, sampleLabel: String(format: "有效题量 %.0f", total)
            )
        }.sorted {
            if $0.score == $1.score { return $0.id < $1.id }
            return ($0.score ?? 0) > ($1.score ?? 0)
        }
        result.monitoredAt = [software.monitoredAt, visual.monitoredAt].compactMap { $0 }.min()
        result.fetchedAt = [software.fetchedAt, visual.fetchedAt].compactMap { $0 }.min()
        let stale = software.state != .ready || visual.state != .ready
        if result.models.isEmpty { return result.withState(.error, message: "暂无同时完成两个维度评测的模型档位") }
        return result.withState(stale ? .stale : .ready, message: stale ? "部分维度未更新，综合智能沿用其最后有效数据" : nil)
    }
}

enum CodexRadarRefreshPolicy {
    static let refreshTimes = [(hour: 8, minute: 20), (hour: 14, minute: 20)]
    static let maximumAge: TimeInterval = 3600
    static let retryInterval: TimeInterval = 300

    static var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    static func shouldRefresh(lastFetchAt: Date?, now: Date = Date()) -> Bool {
        guard let lastFetchAt else { return true }
        return lastFetchAt > now || now.timeIntervalSince(lastFetchAt) >= maximumAge
            || lastFetchAt < lastScheduledRefresh(before: now)
    }

    static func nextRefresh(after now: Date, lastFetchAt: Date?, retryAt: Date? = nil) -> Date {
        if let retryAt { return max(now, retryAt) }
        return min(nextScheduledRefresh(after: now), (lastFetchAt ?? now).addingTimeInterval(maximumAge))
    }

    static func canManualRefresh(lastRefreshAt: Date?, now: Date = Date()) -> Bool {
        lastRefreshAt.map { now.timeIntervalSince($0) >= 300 } ?? true
    }

    static func lastScheduledRefresh(before now: Date) -> Date {
        let calendar = beijingCalendar
        let start = calendar.startOfDay(for: now)
        let today = refreshTimes.compactMap {
            calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: start)
        }
        if let latest = today.filter({ $0 <= now }).max() { return latest }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        return refreshTimes.compactMap {
            calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: yesterday)
        }.max() ?? yesterday
    }

    static func nextScheduledRefresh(after now: Date) -> Date {
        let calendar = beijingCalendar
        let start = calendar.startOfDay(for: now)
        let today = refreshTimes.compactMap {
            calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: start)
        }
        if let next = today.filter({ $0 > now }).min() { return next }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
        return refreshTimes.compactMap {
            calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: tomorrow)
        }.min() ?? tomorrow
    }
}

private enum CodexRadarDateParser {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct CodexRadarMetricsDTO: Decodable {
    let schema: Int
    let benchmarkID: String?
    let sourceUpdatedAt: String
    let points: [Point]

    enum CodingKeys: String, CodingKey {
        case schema, points
        case benchmarkID = "benchmark_id"
        case sourceUpdatedAt = "source_updated_at"
    }

    struct Point: Decodable {
        let model: String
        let effort: String
        let iq: Double?
        let passed: Double?
        let total: Double?
        let weightedPassed: Double?
        let weightedTotal: Double?
        let validTasks: Double?
        let benchmarkTasks: Double?
        let averagePriceUSD: Double?
        let averageMinutes: Double?

        enum CodingKeys: String, CodingKey {
            case model, effort, iq, passed, total
            case weightedPassed = "weighted_passed"
            case weightedTotal = "weighted_total"
            case validTasks = "valid_tasks"
            case benchmarkTasks = "benchmark_tasks"
            case averagePriceUSD = "average_price_usd"
            case averageMinutes = "average_minutes"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(String.self, forKey: .model)
            effort = try container.decode(String.self, forKey: .effort)
            iq = container.flexibleDouble(.iq)
            passed = container.flexibleDouble(.passed)
            total = container.flexibleDouble(.total)
            weightedPassed = container.flexibleDouble(.weightedPassed)
            weightedTotal = container.flexibleDouble(.weightedTotal)
            validTasks = container.flexibleDouble(.validTasks)
            benchmarkTasks = container.flexibleDouble(.benchmarkTasks)
            averagePriceUSD = container.flexibleDouble(.averagePriceUSD)
            averageMinutes = container.flexibleDouble(.averageMinutes)
        }
    }
}

private struct CodexRadarSummaryDTO: Decodable {
    let monitoredAt: String?
    let status: String?
    let recommendedAction: String?
    let prediction: PredictionDTO?
    let apiAccess: APIAccessDTO?
    let modelIQ: ModelIQDTO?

    enum CodingKeys: String, CodingKey {
        case monitoredAt = "monitored_at"
        case status
        case recommendedAction = "recommended_action"
        case prediction
        case apiAccess = "api_access"
        case modelIQ = "model_iq"
    }
}

private struct PredictionDTO: Decodable { let summary: String? }
private struct APIAccessDTO: Decodable { let requirements: RequirementsDTO? }
private struct RequirementsDTO: Decodable {
    let attributionText: String?
    let site: String?
    enum CodingKeys: String, CodingKey {
        case attributionText = "attribution_text"
        case site
    }
}

private struct ModelIQDTO: Decodable {
    let updatedAt: String?
    let latest: ModelResultDTO?
    let comparisons: [String: ComparisonDTO]?
    let quotaRadar: QuotaRadarDTO?

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case latest
        case comparisons
        case quotaRadar = "quota_radar"
    }

    var modelCards: [CodexRadarModelScore] {
        var cards: [CodexRadarModelScore] = []
        if let latest {
            cards.append(latest.card(id: "latest", fallback: latest.generatedLabel))
        }
        for (key, comparison) in (comparisons ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let result = comparison.latest else { continue }
            cards.append(result.card(id: key, fallback: comparison.label?.nonBlank ?? result.generatedLabel))
        }
        var seen = Set<String>()
        return cards.filter { seen.insert($0.label.lowercased()).inserted }
    }
}

private struct ComparisonDTO: Decodable {
    let label: String?
    let latest: ModelResultDTO?
}

private struct ModelResultDTO: Decodable {
    let score: Double?
    let status: String?
    let passed: Int?
    let tasks: Int?
    let model: String?
    let reasoningEffort: String?
    let costUSD: Double?
    let wallTime: String?

    enum CodingKeys: String, CodingKey {
        case score, status, passed, tasks, model
        case reasoningEffort = "reasoning_effort"
        case costUSD = "cost_usd"
        case wallTime = "wall_time_human"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        score = container.flexibleDouble(.score)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        passed = container.flexibleInt(.passed)
        tasks = container.flexibleInt(.tasks)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        costUSD = container.flexibleDouble(.costUSD)
        wallTime = try container.decodeIfPresent(String.self, forKey: .wallTime)
    }

    var generatedLabel: String {
        [model?.nonBlank, reasoningEffort?.nonBlank].compactMap { $0 }.joined(separator: " ").nonBlank ?? "最新模型"
    }

    func card(id: String, fallback: String) -> CodexRadarModelScore {
        CodexRadarModelScore(
            id: id,
            label: fallback,
            score: score,
            status: status?.nonBlank,
            passed: passed,
            tasks: tasks,
            costUSD: costUSD,
            wallTime: wallTime?.nonBlank
        )
    }
}

private struct QuotaRadarDTO: Decodable {
    let updatedAt: String?
    let rows: [QuotaRowDTO]?
    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case rows
    }
}

private struct QuotaRowDTO: Decodable {
    let tier: String
    let fiveHour: Double?
    let sevenDay: Double?
    let basis: String?
    enum CodingKeys: String, CodingKey {
        case tier, basis
        case fiveHour = "five_h"
        case sevenDay = "seven_d"
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = (try container.decodeIfPresent(String.self, forKey: .tier)) ?? "Unknown"
        fiveHour = container.flexibleDouble(.fiveHour)
        sevenDay = container.flexibleDouble(.sevenDay)
        basis = try container.decodeIfPresent(String.self, forKey: .basis)
    }
}

private extension KeyedDecodingContainer {
    func flexibleDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func flexibleInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value.rounded()) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
