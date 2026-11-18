import Foundation
import Testing
@testable import CodexNotch

private func priceData(input: Double = 0.000002, model: String = "gpt-price-test") -> Data {
    Data("""
    {"\(model)":{"litellm_provider":"openai","mode":"responses",
    "input_cost_per_token":\(input),"cache_read_input_token_cost":0.0000002,"output_cost_per_token":0.00001,
    "input_cost_per_token_above_272k_tokens":0.000007,
    "cache_read_input_token_cost_above_272k_tokens":0.0000009,
    "output_cost_per_token_above_272k_tokens":0.00002}}
    """.utf8)
}

@Test func remotePricesPreserveCacheAndExplicitLongContextRates() throws {
    let prices = try TokenPricingParser.parse(priceData())
    let price = try #require(prices["gpt-price-test"])
    #expect(price.inputPerMillionUSD == 2)
    #expect(abs(price.cachedInputPerMillionUSD - 0.2) < 1e-9)
    let usage = TokenUsageBreakdown(inputTokens: 300_000, cachedInputTokens: 200_000, outputTokens: 1_000, totalTokens: 301_000)
    #expect(abs(price.cost(for: usage, longContext: true) - 0.90) < 1e-9)
    #expect(TokenCostCatalog.price(for: "openai/gpt-price-test-2026-09-07", remote: prices) == price)
    #expect(TokenCostCatalog.price(for: "gpt-price-test-fast", remote: prices) == nil)
}

@Test func malformedIncompleteOrWrongProviderPricesAreRejected() {
    for json in [
        "{}", "<html>502</html>",
        #"{"x":{"litellm_provider":"openai","mode":"chat","input_cost_per_token":-1,"cache_read_input_token_cost":0,"output_cost_per_token":0}}"#,
        #"{"x":{"litellm_provider":"openai","mode":"chat","input_cost_per_token":true,"cache_read_input_token_cost":0,"output_cost_per_token":0}}"#,
        #"{"x":{"litellm_provider":"openai","mode":"chat","input_cost_per_token":0.01,"output_cost_per_token":0.01}}"#,
        #"{"x":{"litellm_provider":"azure","mode":"chat","input_cost_per_token":0.01,"cache_read_input_token_cost":0,"output_cost_per_token":0.01}}"#
    ] {
        #expect(throws: (any Error).self) { try TokenPricingParser.parse(Data(json.utf8)) }
    }
}

@Suite(.serialized)
@MainActor
struct PricingUpdateLifecycleTests {
    @Test func existingSummariesRepriceWithoutRescanningOrChangingContextTier() throws {
        let original = TokenCostCatalog.remoteSnapshot
        let version = TokenCostCatalog.priceVersion
        defer { TokenCostCatalog.install(original, version: version) }
        var summary = TokenUsageSummary.zero
        let usage = TokenUsageBreakdown(inputTokens: 200_000, cachedInputTokens: 100_000, outputTokens: 1_000, totalTokens: 201_000)
        summary.add(usage, model: "gpt-price-test")
        summary.add(usage, model: "gpt-price-test")
        #expect(summary.costUSD == nil)
        TokenCostCatalog.install(try TokenPricingParser.parse(priceData()), version: "test")
        #expect(abs((summary.costUSD ?? 0) - 0.46) < 1e-9)
        #expect(summary.unpricedTokens == 0)
        TokenCostCatalog.install(try TokenPricingParser.parse(priceData(input: 0.000004)), version: "test2")
        #expect(abs((summary.costUSD ?? 0) - 0.86) < 1e-9)
        #expect(summary.totalTokens == 402_000)
    }

    @Test func automaticRefreshPersistsAndFailureKeepsLastGoodPrices() async throws {
        let suite = "pricing-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let cacheURL = directory.appendingPathComponent("current.json")
        let original = TokenCostCatalog.remoteSnapshot
        let version = TokenCostCatalog.priceVersion
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            TokenCostCatalog.install(original, version: version)
        }
        let transport = PricingTestTransport()
        let updater = TokenPricingUpdater(defaults: defaults, cacheURL: cacheURL) { _ in try await transport.fetch() }
        updater.start()
        try await waitForUpdate(updater)
        #expect(updater.modelCount == 1)
        let checked = try #require(updater.lastChecked)
        let diskBefore = try Data(contentsOf: cacheURL)
        updater.refreshIfDue(now: checked.addingTimeInterval(60))
        #expect(await transport.calls == 1)
        await transport.setFailure(true)
        updater.refreshNow()
        try await waitForUpdate(updater)
        #expect(updater.status.contains("失败"))
        #expect(updater.lastChecked == checked)
        #expect(try Data(contentsOf: cacheURL) == diskBefore)
        let retryAt = try #require(updater.nextCheckAt)
        #expect(retryAt < checked.addingTimeInterval(24 * 3_600))
        updater.refreshIfDue(now: retryAt.addingTimeInterval(-1))
        #expect(!updater.isRefreshing)
        await transport.setFailure(false)
        updater.refreshIfDue(now: retryAt)
        #expect(updater.isRefreshing)
        try await waitForUpdate(updater)
        let checkedAfterRetry = try #require(updater.lastChecked)
        #expect(checkedAfterRetry > checked)
        var settings = updater.settings
        settings.automatic = false
        settings.intervalHours = 6
        updater.save(settings)
        updater.refreshIfDue(now: checked.addingTimeInterval(90_000))
        #expect(updater.nextCheckAt == nil)
        #expect(await transport.calls == 3)
        let reloaded = TokenPricingUpdater(defaults: defaults, cacheURL: cacheURL) { _ in throw URLError(.notConnectedToInternet) }
        #expect(reloaded.lastChecked == checkedAfterRetry)
        #expect(reloaded.settings == settings)
        #expect(reloaded.modelCount == 1)
    }

    @Test func aMissingModelRefreshesBeforeTheDailyCheckAndRepricesExistingUsage() async throws {
        let suite = "pricing-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let cacheURL = directory.appendingPathComponent("current.json")
        let original = TokenCostCatalog.remoteSnapshot
        let version = TokenCostCatalog.priceVersion
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            TokenCostCatalog.install(original, version: version)
        }
        let now = Date()
        let lastCheck = now.addingTimeInterval(-600)
        try TokenPricingCache(sourceURL: TokenPricingSettings.defaultSource, checkedAt: lastCheck,
                              data: priceData(model: "gpt-old-price-test")).write(to: cacheURL)
        let transport = PricingTestTransport()
        let updater = TokenPricingUpdater(defaults: defaults, cacheURL: cacheURL) { _ in try await transport.fetch() }
        updater.start()
        #expect(updater.nextCheckAt == lastCheck.addingTimeInterval(24 * 3_600))

        let usage = TokenUsageBreakdown(inputTokens: 1_000, cachedInputTokens: 500, outputTokens: 100, totalTokens: 1_100)
        var missingDetails = TokenUsageSummary.unpriced(totalTokens: 1_100, model: "gpt-price-test")
        missingDetails.add(usage, model: nil)
        updater.refreshForMissingPrices(in: [missingDetails], now: now)
        #expect(!updater.isRefreshing)

        var newModel = TokenUsageSummary.zero
        newModel.add(usage, model: "openai/GPT-price-test")
        var unavailableModel = TokenUsageSummary.zero
        unavailableModel.add(usage, model: "gpt-unavailable-price-test")
        #expect(newModel.costUSD == nil)
        updater.refreshForMissingPrices(in: [newModel, unavailableModel], now: now)
        #expect(updater.isRefreshing)
        updater.refreshForMissingPrices(in: [newModel, unavailableModel], now: now)
        try await waitForUpdate(updater)
        #expect(abs((newModel.costUSD ?? 0) - 0.0021) < 1e-9)
        #expect(newModel.breakdown == usage)
        #expect(unavailableModel.costUSD == nil)

        let checked = try #require(updater.lastChecked)
        var anotherNewModel = TokenUsageSummary.zero
        anotherNewModel.add(usage, model: "gpt-another-price-test")
        updater.refreshForMissingPrices(in: [anotherNewModel], now: checked.addingTimeInterval(60))
        #expect(!updater.isRefreshing)
        updater.refreshForMissingPrices(in: [unavailableModel], now: checked.addingTimeInterval(600))
        #expect(!updater.isRefreshing)
        #expect(await transport.calls == 1)

        var settings = updater.settings
        settings.automatic = false
        updater.save(settings)
        updater.refreshForMissingPrices(in: [anotherNewModel], now: checked.addingTimeInterval(600))
        #expect(!updater.isRefreshing)
        #expect(await transport.calls == 1)
    }

    private func waitForUpdate(_ updater: TokenPricingUpdater) async throws {
        for _ in 0..<200 {
            if !updater.isRefreshing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Pricing update did not complete")
    }
}

private actor PricingTestTransport {
    var calls = 0
    var shouldFail = false
    func setFailure(_ failure: Bool) { shouldFail = failure }
    func fetch() throws -> Data {
        calls += 1
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return priceData()
    }
}
