import Foundation
import Testing
@testable import CodexNotch

@Test
func usageEventLineScannerDecodesRelevantEventsAndTheRequestedSuffix() {
    let text = [
        #"{"type":"ignored"}"#,
        #"{"timestamp":"2026-08-28T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":11,"cached_input_tokens":3,"output_tokens":5,"reasoning_output_tokens":2,"total_tokens":16}}}}"#,
        #"{"type":"turn_context","payload":{"model":"gpt-5.6"}}"#,
        #"{"type":"world_state"}"#,
        #"{"timestamp":"2026-08-28T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":2,"output_tokens":4,"reasoning_output_tokens":1,"total_tokens":11}}}}"#
    ].joined(separator: "\n")

    let events = CodexUsageEventLineScanner.events(
        in: Data(text.utf8),
        lineLimit: 2,
        dropLeadingPartialLine: false
    )

    #expect(events == [
        .worldState,
        .tokenCount(
            timestampPrefix: "2026-08-28T00:00:02",
            usage: TokenUsageBreakdown(
                inputTokens: 7,
                cachedInputTokens: 2,
                outputTokens: 4,
                reasoningOutputTokens: 1,
                totalTokens: 11
            )
        )
    ])
}

@Test
func usageEventLineScannerDropsAPartialLeadingTailLine() {
    let text = [
        #"partial "token_count" payload"#,
        #"{"timestamp":"2026-08-28T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1}}}}"#
    ].joined(separator: "\n")

    let events = CodexUsageEventLineScanner.events(
        in: Data(text.utf8),
        lineLimit: 10,
        dropLeadingPartialLine: true
    )

    #expect(events == [
        .tokenCount(
            timestampPrefix: "2026-08-28T00:00:01",
            usage: TokenUsageBreakdown(totalTokens: 1)
        )
    ])
}

@Test
func usageEventLineScannerCanStartAfterTheLastWorldState() {
    let text = [
        #"{"timestamp":"2026-08-28T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10}}}}"#,
        #"{"type":"world_state","payload":{"full":true}}"#,
        #"{"timestamp":"2026-08-28T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":20}}}}"#
    ].joined(separator: "\n")

    let events = CodexUsageEventLineScanner.events(
        in: Data(text.utf8),
        lineLimit: 10,
        dropLeadingPartialLine: false,
        resetAfterLastWorldState: true
    )

    #expect(events == [
        .worldState,
        .tokenCount(
            timestampPrefix: "2026-08-28T00:00:02",
            usage: TokenUsageBreakdown(totalTokens: 20)
        )
    ])
}
