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

// Keep token components by model and per-request context tier. Cached summaries can
// then use a new price catalog without scanning the user's rollout files again.
struct TokenUsageSummary: Equatable, Sendable {
    var breakdown: TokenUsageBreakdown = .zero
    var hasComponentData = false
    private var components: [PriceBucket: TokenUsageBreakdown] = [:]
    private var missingTokens = 0
    private var missingModels: Set<String> = []

    private struct PriceBucket: Hashable, Sendable {
        let model: String
        let longContext: Bool
    }

    static let zero = TokenUsageSummary()

    static func unpriced(totalTokens: Int, model: String? = nil) -> TokenUsageSummary {
        var summary = Self.zero
        summary.addUnpricedTokens(totalTokens, model: model)
        return summary
    }

    var totalTokens: Int { breakdown.totalTokens }
    var estimatedCostUSD: Double { valuation().cost }
    var unpricedTokens: Int { valuation().unpriced }
    var unknownModels: [String] { valuation().unknown }
    var pricedTokens: Int { max(0, totalTokens - unpricedTokens) }
    var costUSD: Double? {
        let value = valuation()
        return totalTokens > value.unpriced ? value.cost : nil
    }
    var isComplete: Bool { totalTokens > 0 && unpricedTokens == 0 }

    mutating func add(_ usage: TokenUsageBreakdown, model: String?) {
        breakdown.add(usage)
        hasComponentData = hasComponentData || usage.hasComponentData
        let label = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bucket = PriceBucket(
            model: label.isEmpty ? "模型未知" : label,
            longContext: usage.inputTokens > TokenCostCatalog.longContextThreshold
        )
        components[bucket, default: .zero].add(usage)
    }

    mutating func add(_ other: TokenUsageSummary) {
        breakdown.add(other.breakdown)
        hasComponentData = hasComponentData || other.hasComponentData
        missingTokens = Self.saturatingAdd(missingTokens, other.missingTokens)
        missingModels.formUnion(other.missingModels)
        for (bucket, usage) in other.components {
            components[bucket, default: .zero].add(usage)
        }
    }

    mutating func addUnpricedTokens(_ tokens: Int, model: String? = nil) {
        guard tokens > 0 else { return }
        breakdown.totalTokens = Self.saturatingAdd(breakdown.totalTokens, tokens)
        missingTokens = Self.saturatingAdd(missingTokens, tokens)
        let label = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        missingModels.insert(label.isEmpty ? "明细缺失" : label)
    }

    private func valuation() -> (cost: Double, unpriced: Int, unknown: [String]) {
        let catalog = TokenCostCatalog.remoteSnapshot
        var cost = 0.0
        var unpriced = missingTokens
        var unknown = missingModels
        for (bucket, usage) in components {
            if usage.hasComponentData,
               let price = TokenCostCatalog.price(for: bucket.model, remote: catalog) {
                cost += price.cost(for: usage, longContext: bucket.longContext)
            } else {
                unpriced = Self.saturatingAdd(unpriced, usage.totalTokens)
                unknown.insert(bucket.model)
            }
        }
        return (cost, unpriced, unknown.sorted())
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }
}

struct ModelTokenPrice: Codable, Equatable, Sendable {
    let inputPerMillionUSD: Double
    let cachedInputPerMillionUSD: Double
    let outputPerMillionUSD: Double
    let appliesLongContextSurcharge: Bool
    var longContextInputPerMillionUSD: Double? = nil
    var longContextCachedInputPerMillionUSD: Double? = nil
    var longContextOutputPerMillionUSD: Double? = nil

    func cost(for usage: TokenUsageBreakdown, longContext: Bool) -> Double {
        let usesLong = longContext && appliesLongContextSurcharge
        let input = usesLong ? (longContextInputPerMillionUSD ?? inputPerMillionUSD * 2) : inputPerMillionUSD
        let cached = usesLong ? (longContextCachedInputPerMillionUSD ?? cachedInputPerMillionUSD * 2) : cachedInputPerMillionUSD
        let output = usesLong ? (longContextOutputPerMillionUSD ?? outputPerMillionUSD * 1.5) : outputPerMillionUSD
        return (Double(usage.uncachedInputTokens) * input
            + Double(usage.cachedInputTokens) * cached
            + Double(usage.outputTokens) * output) / 1_000_000
    }
}

enum TokenCostCatalog {
    static let bundledPriceVersion = "2026-08-28"
    private static let state = CatalogState()
    static var priceVersion: String { state.read().version }
    static var remoteSnapshot: [String: ModelTokenPrice] { state.read().prices }

    static func install(_ prices: [String: ModelTokenPrice], version: String) {
        state.set(prices, version: version)
    }

    private final class CatalogState: @unchecked Sendable {
        private let lock = NSLock()
        private var prices: [String: ModelTokenPrice] = [:]
        private var version = "内置 2026-08-28"
        func read() -> (prices: [String: ModelTokenPrice], version: String) {
            lock.lock()
            defer { lock.unlock() }
            return (prices, version)
        }
        func set(_ prices: [String: ModelTokenPrice], version: String) {
            lock.lock()
            defer { lock.unlock() }
            self.prices = prices
            self.version = version
        }
    }
    static let longContextThreshold = 272_000
    private static let modelAliases = [
        "codex-auto-review": "gpt-5.6-sol"
    ]

    static func price(for model: String?) -> ModelTokenPrice? {
        price(for: model, remote: remoteSnapshot)
    }

    static func price(for model: String?, remote: [String: ModelTokenPrice]) -> ModelTokenPrice? {
        guard let normalized = normalizedModel(model) else {
            return nil
        }

        if let price = remote[normalized] { return price }
        // Only strip an actual YYYY-MM-DD suffix; never match a different model family.
        if normalized.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
           let price = remote[String(normalized.dropLast(11))] { return price }

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

        guard usage.hasComponentData else { return nil }
        return price.cost(for: usage, longContext: usage.inputTokens > longContextThreshold)
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
        return modelAliases[value] ?? value
    }
}
