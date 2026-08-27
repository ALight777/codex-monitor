import Foundation

struct TokenUsageBreakdown: Equatable, Sendable {
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningOutputTokens: Int = 0
    var totalTokens: Int = 0

    static let zero = TokenUsageBreakdown()

    var uncachedInputTokens: Int {
        max(0, inputTokens - cachedInputTokens)
    }

    var hasComponentData: Bool {
        inputTokens > 0 || cachedInputTokens > 0 || outputTokens > 0 || reasoningOutputTokens > 0
    }

    mutating func add(_ other: TokenUsageBreakdown) {
        inputTokens = Self.saturatingAdd(inputTokens, other.inputTokens)
        cachedInputTokens = Self.saturatingAdd(cachedInputTokens, other.cachedInputTokens)
        outputTokens = Self.saturatingAdd(outputTokens, other.outputTokens)
        reasoningOutputTokens = Self.saturatingAdd(reasoningOutputTokens, other.reasoningOutputTokens)
        totalTokens = Self.saturatingAdd(totalTokens, other.totalTokens)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }
}

struct TokenUsageSummary: Equatable, Sendable {
    var breakdown: TokenUsageBreakdown = .zero
    var estimatedCostUSD: Double = 0
    var unpricedTokens: Int = 0
    var unknownModels: [String] = []
    var hasComponentData: Bool = false

    static let zero = TokenUsageSummary()

    static func unpriced(totalTokens: Int, model: String? = nil) -> TokenUsageSummary {
        let tokens = max(0, totalTokens)
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TokenUsageSummary(
            breakdown: TokenUsageBreakdown(totalTokens: tokens),
            estimatedCostUSD: 0,
            unpricedTokens: tokens,
            unknownModels: normalizedModel.flatMap { $0.isEmpty ? nil : [$0] } ?? [],
            hasComponentData: false
        )
    }

    var totalTokens: Int {
        breakdown.totalTokens
    }

    var costUSD: Double? {
        guard totalTokens > 0, unpricedTokens == 0 else {
            return nil
        }
        return estimatedCostUSD
    }

    var isComplete: Bool {
        totalTokens > 0 && unpricedTokens == 0
    }

    mutating func add(_ usage: TokenUsageBreakdown, model: String?) {
        breakdown.add(usage)
        hasComponentData = hasComponentData || usage.hasComponentData

        if let cost = TokenCostCatalog.estimatedCostUSD(for: usage, model: model) {
            estimatedCostUSD += cost
        } else {
            unpricedTokens = Self.saturatingAdd(unpricedTokens, usage.totalTokens)
            let label = model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let unknown = (label?.isEmpty == false ? label : nil) ?? "模型未知"
            if !unknownModels.contains(unknown) {
                unknownModels.append(unknown)
                unknownModels.sort()
            }
        }
    }

    mutating func add(_ other: TokenUsageSummary) {
        breakdown.add(other.breakdown)
        estimatedCostUSD += other.estimatedCostUSD
        unpricedTokens = Self.saturatingAdd(unpricedTokens, other.unpricedTokens)
        hasComponentData = hasComponentData || other.hasComponentData
        unknownModels = Array(Set(unknownModels + other.unknownModels)).sorted()
    }

    mutating func addUnpricedTokens(_ tokens: Int, model: String? = nil) {
        guard tokens > 0 else {
            return
        }
        breakdown.totalTokens = Self.saturatingAdd(breakdown.totalTokens, tokens)
        unpricedTokens = Self.saturatingAdd(unpricedTokens, tokens)
        let label = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let unknown = (label?.isEmpty == false ? label : nil) ?? "明细缺失"
        if !unknownModels.contains(unknown) {
            unknownModels.append(unknown)
            unknownModels.sort()
        }
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }
}

struct ModelTokenPrice: Equatable, Sendable {
    let inputPerMillionUSD: Double
    let cachedInputPerMillionUSD: Double
    let outputPerMillionUSD: Double
    let appliesLongContextSurcharge: Bool
}

enum TokenCostCatalog {
    static let priceVersion = "2026-08-27"
    static let longContextThreshold = 272_000

    static func price(for model: String?) -> ModelTokenPrice? {
        guard let normalized = normalizedModel(model) else {
            return nil
        }

        let entries: [(String, ModelTokenPrice)] = [
            ("gpt-5.6-terra", .init(inputPerMillionUSD: 2, cachedInputPerMillionUSD: 0.2, outputPerMillionUSD: 12, appliesLongContextSurcharge: false)),
            ("gpt-5.6-luna", .init(inputPerMillionUSD: 0.2, cachedInputPerMillionUSD: 0.02, outputPerMillionUSD: 1.2, appliesLongContextSurcharge: false)),
            ("gpt-5.6-sol", .init(inputPerMillionUSD: 4, cachedInputPerMillionUSD: 0.4, outputPerMillionUSD: 20, appliesLongContextSurcharge: true)),
            ("gpt-5.5", .init(inputPerMillionUSD: 5, cachedInputPerMillionUSD: 0.5, outputPerMillionUSD: 30, appliesLongContextSurcharge: true)),
            ("gpt-5.4-mini", .init(inputPerMillionUSD: 0.75, cachedInputPerMillionUSD: 0.075, outputPerMillionUSD: 4.5, appliesLongContextSurcharge: false)),
            ("gpt-5.4", .init(inputPerMillionUSD: 2.5, cachedInputPerMillionUSD: 0.25, outputPerMillionUSD: 15, appliesLongContextSurcharge: true)),
            ("gpt-5.3-codex", .init(inputPerMillionUSD: 1.75, cachedInputPerMillionUSD: 0.175, outputPerMillionUSD: 14, appliesLongContextSurcharge: false)),
            ("gpt-5.2-codex", .init(inputPerMillionUSD: 1.75, cachedInputPerMillionUSD: 0.175, outputPerMillionUSD: 14, appliesLongContextSurcharge: false)),
            ("gpt-5.2", .init(inputPerMillionUSD: 1.75, cachedInputPerMillionUSD: 0.175, outputPerMillionUSD: 14, appliesLongContextSurcharge: false)),
            ("gpt-5.1-codex", .init(inputPerMillionUSD: 1.25, cachedInputPerMillionUSD: 0.125, outputPerMillionUSD: 10, appliesLongContextSurcharge: false)),
            ("gpt-5.1", .init(inputPerMillionUSD: 1.25, cachedInputPerMillionUSD: 0.125, outputPerMillionUSD: 10, appliesLongContextSurcharge: false)),
            ("gpt-5-codex", .init(inputPerMillionUSD: 1.25, cachedInputPerMillionUSD: 0.125, outputPerMillionUSD: 10, appliesLongContextSurcharge: false))
        ]

        for (name, price) in entries where normalized == name || normalized.hasPrefix("\(name)-20") {
            return price
        }
        return nil
    }

    static func estimatedCostUSD(for usage: TokenUsageBreakdown, model: String?) -> Double? {
        guard let price = price(for: model) else {
            return nil
        }

        let usesLongContextRates = price.appliesLongContextSurcharge
            && usage.inputTokens > longContextThreshold
        let inputMultiplier = usesLongContextRates ? 2.0 : 1.0
        let outputMultiplier = usesLongContextRates ? 1.5 : 1.0
        let million = 1_000_000.0

        let uncachedCost = Double(usage.uncachedInputTokens)
            * price.inputPerMillionUSD
            * inputMultiplier
            / million
        let cachedCost = Double(usage.cachedInputTokens)
            * price.cachedInputPerMillionUSD
            * inputMultiplier
            / million
        let outputCost = Double(usage.outputTokens)
            * price.outputPerMillionUSD
            * outputMultiplier
            / million
        return uncachedCost + cachedCost + outputCost
    }

    private static func normalizedModel(_ model: String?) -> String? {
        guard var value = model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("openai/") {
            value.removeFirst("openai/".count)
        }
        return value
    }
}
