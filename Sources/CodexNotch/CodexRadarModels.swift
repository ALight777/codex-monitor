import Foundation

enum CodexRadarDataSource: String, Codable, Equatable, Sendable {
    case authorizedAPI
    case publicSummary

    var label: String {
        self == .authorizedAPI ? "授权 API" : "公开摘要"
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
        [monitoredAt, quotaUpdatedAt, fetchedAt].compactMap { $0 }.max()
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
            monitoredAt: summary.monitoredAt.flatMap(CodexRadarDateParser.parse),
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
}

enum CodexRadarRefreshPolicy {
    static let refreshTimes = [(hour: 8, minute: 20), (hour: 14, minute: 20)]

    static var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    static func shouldRefresh(lastFetchAt: Date?, now: Date = Date()) -> Bool {
        guard let lastFetchAt else { return true }
        return lastFetchAt < lastScheduledRefresh(before: now)
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
    let latest: ModelResultDTO?
    let comparisons: [String: ComparisonDTO]?
    let quotaRadar: QuotaRadarDTO?

    enum CodingKeys: String, CodingKey {
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
