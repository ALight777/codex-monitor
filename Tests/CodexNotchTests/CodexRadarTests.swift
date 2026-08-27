import Foundation
import Testing
@testable import CodexNotch

@Test
func codexRadarDecodesDynamicModelsAndQuotaRows() throws {
    let payload = #"""
    {
      "monitored_at": "2026-08-27T06:20:00Z",
      "status": "healthy",
      "recommended_action": "keep current model",
      "prediction": {"summary": "Stable for the next window"},
      "model_iq": {
        "latest": {
          "score": "91.5",
          "status": "pass",
          "passed": 11,
          "tasks": 12,
          "model": "gpt-5.6-sol",
          "reasoning_effort": "high",
          "cost_usd": "3.25",
          "wall_time_human": "8m"
        },
        "comparisons": {
          "future-model": {
            "label": "Future Model",
            "latest": {"score": 88, "model": "future-model", "tasks": 10}
          }
        },
        "quota_radar": {
          "updated_at": "2026-08-27T06:10:00Z",
          "rows": [{"tier": "Plus", "five_h": "72.5", "seven_d": 61, "basis": "sample"}]
        }
      },
      "api_access": {
        "requirements": {
          "attribution_text": "Data from Codex Radar",
          "site": "https://codexradar.com"
        }
      }
    }
    """#.data(using: .utf8)!

    let snapshot = try CodexRadarSnapshot.decode(
        data: payload,
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
        source: .publicSummary
    )

    #expect(snapshot.state == .ready)
    #expect(snapshot.models.map(\.label) == ["gpt-5.6-sol high", "Future Model"])
    #expect(snapshot.models.first?.score == 91.5)
    #expect(snapshot.models.first?.costUSD == 3.25)
    #expect(snapshot.models.first?.wallTime == "8m")
    #expect(snapshot.quotaRows.first?.fiveHour == 72.5)
    #expect(snapshot.quotaRows.first?.sevenDay == 61)
    #expect(snapshot.attributionText == "Data from Codex Radar")
}

@Test
func codexRadarScheduleUsesBeijingTime() throws {
    let calendar = CodexRadarRefreshPolicy.beijingCalendar
    let beforeMorning = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 27, hour: 8, minute: 10
    )))
    let afterMorning = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 27, hour: 8, minute: 21
    )))

    let next = CodexRadarRefreshPolicy.nextScheduledRefresh(after: beforeMorning)
    let nextComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
    #expect(nextComponents == DateComponents(year: 2026, month: 8, day: 27, hour: 8, minute: 20))

    let last = CodexRadarRefreshPolicy.lastScheduledRefresh(before: afterMorning)
    let lastComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: last)
    #expect(lastComponents == DateComponents(year: 2026, month: 8, day: 27, hour: 8, minute: 20))
}

@Test
func codexRadarClientOnlyAllowsDocumentedEndpoints() {
    #expect(CodexRadarClient.isAllowed(CodexRadarClient.publicURL, authorized: false))
    #expect(CodexRadarClient.isAllowed(CodexRadarClient.authorizedURL, authorized: true))
    #expect(!CodexRadarClient.isAllowed(URL(string: "http://codexradar.com/current.json")!, authorized: false))
    #expect(!CodexRadarClient.isAllowed(URL(string: "https://codexradar.com.evil.test/current.json")!, authorized: false))
    #expect(!CodexRadarClient.isAllowed(URL(string: "https://codexradar.com/api/v1/current")!, authorized: false))
}
