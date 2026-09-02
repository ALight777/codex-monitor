import Foundation
import Testing
@testable import CodexNotch

@Test func cachedInputAndReasoningAreNotDoubleCounted() {
    let usage = TokenUsageBreakdown(
        inputTokens: 150_000,
        cachedInputTokens: 140_000,
        outputTokens: 10_000,
        reasoningOutputTokens: 8_000,
        totalTokens: 160_000
    )

    #expect(usage.uncachedInputTokens == 10_000)
    let cost = TokenCostCatalog.estimatedCostUSD(for: usage, model: "gpt-5.6-sol")
    #expect(abs((cost ?? 0) - 0.296) < 0.000_000_1)
}

@Test func longContextPricingIsAppliedPerRecordedRequest() {
    let usage = TokenUsageBreakdown(
        inputTokens: 300_000,
        cachedInputTokens: 250_000,
        outputTokens: 20_000,
        reasoningOutputTokens: 12_000,
        totalTokens: 320_000
    )

    let cost = TokenCostCatalog.estimatedCostUSD(for: usage, model: "gpt-5.6-sol")
    #expect(abs((cost ?? 0) - 1.2) < 0.000_000_1)
}

@Test func unknownModelsRemainExplicitlyUnpriced() {
    let usage = TokenUsageBreakdown(
        inputTokens: 1_000,
        cachedInputTokens: 0,
        outputTokens: 100,
        reasoningOutputTokens: 50,
        totalTokens: 1_100
    )
    var summary = TokenUsageSummary.zero
    summary.add(usage, model: "private-preview-model")

    #expect(summary.costUSD == nil)
    #expect(summary.unpricedTokens == 1_100)
    #expect(summary.unknownModels == ["private-preview-model"])
}

@Test func knownModelsRemainEstimatedWhenUnknownUsageIsPresent() {
    let knownUsage = TokenUsageBreakdown(
        inputTokens: 150_000,
        cachedInputTokens: 140_000,
        outputTokens: 10_000,
        reasoningOutputTokens: 8_000,
        totalTokens: 160_000
    )
    let unknownUsage = TokenUsageBreakdown(
        inputTokens: 1_000,
        outputTokens: 100,
        totalTokens: 1_100
    )
    var summary = TokenUsageSummary.zero
    summary.add(knownUsage, model: "gpt-5.6-sol")
    summary.add(unknownUsage, model: nil)

    #expect(abs((summary.costUSD ?? 0) - 0.296) < 0.000_000_1)
    #expect(summary.pricedTokens == 160_000)
    #expect(summary.unpricedTokens == 1_100)
    #expect(summary.unknownModels == ["模型未知"])
    #expect(!summary.isComplete)
}

@Test func decoderReadsLocalCodexTokenComposition() {
    let decoder = CodexSessionEventDecoder()
    let line = #"{"timestamp":"2026-08-27T12:00:00.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":149661,"cached_input_tokens":148352,"output_tokens":943,"reasoning_output_tokens":512,"total_tokens":150604}}}}"#

    let event = decoder.tokenCountEvent(from: line)
    #expect(event?.tokens == 150_604)
    #expect(event?.usage.uncachedInputTokens == 1_309)
    #expect(event?.usage.cachedInputTokens == 148_352)
    #expect(event?.usage.outputTokens == 943)
    #expect(event?.usage.reasoningOutputTokens == 512)
    #expect(event?.usage.totalTokens == 150_604)
}

@Test func modelAliasesWithDatedSuffixesUseTheSamePrice() {
    let usage = TokenUsageBreakdown(
        inputTokens: 1_000,
        cachedInputTokens: 500,
        outputTokens: 100,
        totalTokens: 1_100
    )
    let plain = TokenCostCatalog.estimatedCostUSD(for: usage, model: "gpt-5.4")
    let dated = TokenCostCatalog.estimatedCostUSD(for: usage, model: "openai/gpt-5.4-2026-08-01")
    #expect(plain == dated)
}

@Test func codexAutoReviewUsesGPT56SolPricing() {
    let usage = TokenUsageBreakdown(
        inputTokens: 300_000,
        cachedInputTokens: 250_000,
        outputTokens: 20_000,
        reasoningOutputTokens: 12_000,
        totalTokens: 320_000
    )
    let sol = TokenCostCatalog.estimatedCostUSD(for: usage, model: "gpt-5.6-sol")
    let autoReview = TokenCostCatalog.estimatedCostUSD(for: usage, model: "codex-auto-review")
    let prefixedAutoReview = TokenCostCatalog.estimatedCostUSD(
        for: usage,
        model: "openai/codex-auto-review"
    )

    #expect(autoReview == sol)
    #expect(prefixedAutoReview == sol)
}
