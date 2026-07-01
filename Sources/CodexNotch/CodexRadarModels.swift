import Foundation

enum CodexRadarDataSource: String, Codable, Equatable, Sendable {
    case authorizedAPI
    case publicSummary

    var displayLabel: String {
        switch self {
        case .authorizedAPI:
            "API"
        case .publicSummary:
            "Public summary"
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
    let wallTimeHuman: String?
}

struct CodexRadarQuotaRow: Identifiable, Equatable, Sendable {
    var id: String { tier }

    let tier: String
    let fiveH: Double?
    let sevenD: Double?
    let basis: String?
}

struct CodexRadarSnapshot: Equatable, Sendable {
    static let defaultAttributionText = "数据来自 Codex 雷达 codexradar.com"
    static let siteURL = URL(string: "https://codexradar.com")!

    var panelState: CodexRadarPanelState
    var models: [CodexRadarModelScore]
    var quotaRows: [CodexRadarQuotaRow]
    var monitoredAt: Date?
    var quotaUpdatedAt: Date?
    var lastFetchAt: Date?
    var status: String?
    var recommendedAction: String?
    var windowMessage: String?
    var predictionSummary: String?
    var costUSD: Double?
    var dataSource: CodexRadarDataSource
    var attributionText: String
    var attributionRequired: Bool
    var siteURL: URL
    var message: String?

    static let disabled = CodexRadarSnapshot(
        panelState: .disabled,
        models: [],
        quotaRows: [],
        monitoredAt: nil,
        quotaUpdatedAt: nil,
        lastFetchAt: nil,
        status: nil,
        recommendedAction: nil,
        windowMessage: nil,
        predictionSummary: nil,
        costUSD: nil,
        dataSource: .authorizedAPI,
        attributionText: defaultAttributionText,
        attributionRequired: true,
        siteURL: siteURL,
        message: "Codex Radar 未启用"
    )

    static let loading = CodexRadarSnapshot(
        panelState: .loading,
        models: [],
        quotaRows: [],
        monitoredAt: nil,
        quotaUpdatedAt: nil,
        lastFetchAt: nil,
        status: nil,
        recommendedAction: nil,
        windowMessage: nil,
        predictionSummary: nil,
        costUSD: nil,
        dataSource: .authorizedAPI,
        attributionText: defaultAttributionText,
        attributionRequired: true,
        siteURL: siteURL,
        message: "正在读取 Codex Radar"
    )

    var hasDisplayData: Bool {
        !models.isEmpty || !quotaRows.isEmpty
    }

    var displayUpdatedAt: Date? {
        let sourceDates = [monitoredAt, quotaUpdatedAt].compactMap { $0 }
        return sourceDates.max() ?? lastFetchAt
    }

    func withState(_ state: CodexRadarPanelState, message: String? = nil) -> CodexRadarSnapshot {
        var copy = self
        copy.panelState = state
        copy.message = message
        return copy
    }

    static func decodePublicSummary(
        from data: Data,
        fetchedAt: Date? = nil,
        dataSource: CodexRadarDataSource = .publicSummary
    ) throws -> CodexRadarSnapshot {
        let summary = try JSONDecoder().decode(CodexRadarPublicSummary.self, from: data)
        let attribution = summary.apiAccess?.requirements
        let attributionText = attribution?.attributionText?.nilIfBlank ?? defaultAttributionText
        let siteURL = attribution?.site.flatMap(URL.init(string:)) ?? Self.siteURL
        let modelIQ = summary.modelIQ
        let models = modelIQ?.modelCards ?? []
        let quotaRows = modelIQ?.quotaRadar?.rows?.map {
            CodexRadarQuotaRow(
                tier: $0.tier.nilIfBlank ?? "Unknown",
                fiveH: $0.fiveH,
                sevenD: $0.sevenD,
                basis: $0.basis?.nilIfBlank
            )
        } ?? []
        let summedModelCost = models.compactMap(\.costUSD).reduce(0, +)
        let costUSD = modelIQ?.quotaRadar?.costUSD
            ?? (summedModelCost > 0 ? summedModelCost : nil)

        return CodexRadarSnapshot(
            panelState: .ready,
            models: models,
            quotaRows: quotaRows,
            monitoredAt: summary.monitoredAt.flatMap(CodexRadarDateParser.parse),
            quotaUpdatedAt: modelIQ?.quotaRadar?.updatedAt.flatMap(CodexRadarDateParser.parse),
            lastFetchAt: fetchedAt,
            status: summary.status?.nilIfBlank,
            recommendedAction: summary.recommendedAction?.nilIfBlank,
            windowMessage: summary.window?.message?.nilIfBlank,
            predictionSummary: summary.prediction?.summary?.nilIfBlank,
            costUSD: costUSD,
            dataSource: dataSource,
            attributionText: attributionText,
            attributionRequired: attribution?.attributionRequired ?? true,
            siteURL: siteURL,
            message: nil
        )
    }
}

enum CodexRadarRefreshPolicy {
    static let automaticRefreshHours: [(hour: Int, minute: Int)] = [
        (8, 20),
        (14, 20)
    ]

    static var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    static func shouldRefresh(lastFetchAt: Date?, now: Date = Date(), calendar: Calendar = beijingCalendar) -> Bool {
        guard let lastFetchAt else {
            return true
        }
        return lastFetchAt < lastScheduledRefresh(before: now, calendar: calendar)
    }

    static func canManualRefresh(lastManualRefreshAt: Date?, now: Date = Date(), minimumGap: TimeInterval = 300) -> Bool {
        guard let lastManualRefreshAt else {
            return true
        }
        return now.timeIntervalSince(lastManualRefreshAt) >= minimumGap
    }

    static func lastScheduledRefresh(before now: Date, calendar: Calendar = beijingCalendar) -> Date {
        let todayStart = calendar.startOfDay(for: now)
        let todayCandidates = automaticRefreshHours.compactMap { time in
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: todayStart)
        }
        if let latestToday = todayCandidates.filter({ $0 <= now }).max() {
            return latestToday
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        return automaticRefreshHours.compactMap { time in
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: yesterday)
        }.max() ?? yesterday
    }

    static func nextScheduledRefresh(after now: Date, calendar: Calendar = beijingCalendar) -> Date {
        let todayStart = calendar.startOfDay(for: now)
        let todayCandidates = automaticRefreshHours.compactMap { time in
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: todayStart)
        }
        if let nextToday = todayCandidates.filter({ $0 > now }).min() {
            return nextToday
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(86_400)
        return automaticRefreshHours.compactMap { time in
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: tomorrow)
        }.min() ?? tomorrow
    }
}

enum CodexRadarDateParser {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct CodexRadarPublicSummary: Decodable {
    let monitoredAt: String?
    let status: String?
    let recommendedAction: String?
    let window: CodexRadarWindowSummary?
    let prediction: CodexRadarPredictionSummary?
    let apiAccess: CodexRadarAPIAccess?
    let modelIQ: CodexRadarModelIQ?

    enum CodingKeys: String, CodingKey {
        case monitoredAt = "monitored_at"
        case status
        case recommendedAction = "recommended_action"
        case window
        case prediction
        case apiAccess = "api_access"
        case modelIQ = "model_iq"
    }
}

private struct CodexRadarWindowSummary: Decodable {
    let message: String?
}

private struct CodexRadarPredictionSummary: Decodable {
    let summary: String?
}

private struct CodexRadarAPIAccess: Decodable {
    let requirements: CodexRadarAttributionRequirements?
}

private struct CodexRadarAttributionRequirements: Decodable {
    let attributionRequired: Bool?
    let attributionText: String?
    let site: String?

    enum CodingKeys: String, CodingKey {
        case attributionRequired = "attribution_required"
        case attributionText = "attribution_text"
        case site
    }
}

private struct CodexRadarModelIQ: Decodable {
    let latest: CodexRadarModelResult?
    let comparisons: [String: CodexRadarComparison]?
    let quotaRadar: CodexRadarQuotaRadar?

    enum CodingKeys: String, CodingKey {
        case latest
        case comparisons
        case quotaRadar = "quota_radar"
    }

    var modelCards: [CodexRadarModelScore] {
        var cards: [CodexRadarModelScore] = []
        if let latest {
            cards.append(latest.modelScore(id: "gpt_55_xhigh", fallbackLabel: "GPT-5.5 xhigh"))
        }

        let order: [(key: String, label: String)] = [
            ("gpt_55_high", "GPT-5.5 high"),
            ("gpt_55_medium", "GPT-5.5 medium"),
            ("gpt_54_xhigh", "GPT-5.4 xhigh"),
            ("gpt_54_high", "GPT-5.4 high")
        ]
        for item in order {
            guard let comparison = comparisons?[item.key] else {
                continue
            }
            if let latest = comparison.latest {
                cards.append(latest.modelScore(id: item.key, fallbackLabel: comparison.label?.nilIfBlank ?? item.label))
            }
        }
        return cards
    }
}

private struct CodexRadarComparison: Decodable {
    let label: String?
    let latest: CodexRadarModelResult?
}

private struct CodexRadarModelResult: Decodable {
    let score: Double?
    let status: String?
    let passed: Int?
    let tasks: Int?
    let model: String?
    let reasoningEffort: String?
    let costUSD: Double?
    let wallTimeHuman: String?

    enum CodingKeys: String, CodingKey {
        case score
        case status
        case passed
        case tasks
        case model
        case reasoningEffort = "reasoning_effort"
        case costUSD = "cost_usd"
        case wallTimeHuman = "wall_time_human"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        score = container.decodeFlexibleDoubleIfPresent(forKey: .score)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        passed = container.decodeFlexibleIntIfPresent(forKey: .passed)
        tasks = container.decodeFlexibleIntIfPresent(forKey: .tasks)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        costUSD = container.decodeFlexibleDoubleIfPresent(forKey: .costUSD)
        wallTimeHuman = try container.decodeIfPresent(String.self, forKey: .wallTimeHuman)
    }

    func modelScore(id: String, fallbackLabel: String) -> CodexRadarModelScore {
        CodexRadarModelScore(
            id: id,
            label: fallbackLabel,
            score: score,
            status: status?.nilIfBlank,
            passed: passed,
            tasks: tasks,
            costUSD: costUSD,
            wallTimeHuman: wallTimeHuman?.nilIfBlank
        )
    }
}

private struct CodexRadarQuotaRadar: Decodable {
    let updatedAt: String?
    let costUSD: Double?
    let rows: [CodexRadarQuotaRowDTO]?

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case costUSD = "cost_usd"
        case rows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        costUSD = container.decodeFlexibleDoubleIfPresent(forKey: .costUSD)
        rows = try container.decodeIfPresent([CodexRadarQuotaRowDTO].self, forKey: .rows)
    }
}

private struct CodexRadarQuotaRowDTO: Decodable {
    let tier: String
    let basis: String?
    let fiveH: Double?
    let sevenD: Double?

    enum CodingKeys: String, CodingKey {
        case tier
        case basis
        case fiveH = "five_h"
        case sevenD = "seven_d"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = (try container.decodeIfPresent(String.self, forKey: .tier)) ?? "Unknown"
        basis = try container.decodeIfPresent(String.self, forKey: .basis)
        fiveH = container.decodeFlexibleDoubleIfPresent(forKey: .fiveH)
        sevenD = container.decodeFlexibleDoubleIfPresent(forKey: .sevenD)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
