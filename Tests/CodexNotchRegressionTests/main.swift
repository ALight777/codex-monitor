import Foundation
import CoreGraphics
import Darwin

final class TestRunner {
    private(set) var failures = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else {
            return
        }
        failures += 1
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    }

    func require<T>(_ value: T?, _ message: String) -> T {
        guard let value else {
            failures += 1
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            fatalError(message)
        }
        return value
    }
}

let runner = TestRunner()

var detailTransition = DetailTransitionState()
runner.check(detailTransition.phase == .hidden, "detail transition should start hidden")

let firstShow = detailTransition.begin(expanded: true)
runner.check(detailTransition.phase == .revealing, "show should enter revealing phase")

let interruptedHide = detailTransition.begin(expanded: false)
runner.check(interruptedHide != firstShow, "every transition should receive a new generation")
runner.check(detailTransition.phase == .hiding, "reverse transition should enter hiding phase")
runner.check(!detailTransition.completeShow(generation: firstShow), "stale show completion should be ignored")
runner.check(detailTransition.phase == .hiding, "stale show completion should not replace hiding phase")
runner.check(detailTransition.completeHide(generation: interruptedHide), "current hide completion should succeed")
runner.check(detailTransition.phase == .hidden, "hide completion should end hidden")

let finalShow = detailTransition.begin(expanded: true)
runner.check(detailTransition.completeShow(generation: finalShow), "current show completion should succeed")
runner.check(detailTransition.phase == .visible, "show completion should end visible")

var rapidDetailTransition = DetailTransitionState()
let rapidFirstShow = rapidDetailTransition.begin(expanded: true)
let rapidHide = rapidDetailTransition.begin(expanded: false)
let rapidFinalShow = rapidDetailTransition.begin(expanded: true)
runner.check(
    !rapidDetailTransition.completeShow(generation: rapidFirstShow),
    "rapid transition should ignore the first show completion"
)
runner.check(
    !rapidDetailTransition.completeHide(generation: rapidHide),
    "rapid transition should ignore the interrupted hide completion"
)
runner.check(
    rapidDetailTransition.phase == .revealing,
    "stale rapid completions should preserve the final revealing phase"
)
runner.check(
    rapidDetailTransition.completeShow(generation: rapidFinalShow),
    "rapid transition should accept the final show completion"
)
runner.check(
    rapidDetailTransition.phase == .visible,
    "rapid show-hide-show should end visible"
)

let detailFrames = DetailWindowFrameCalculator.calculate(
    screenFrame: CGRect(x: 100, y: 50, width: 1_440, height: 900),
    layoutWidth: 720,
    collapsedHeight: 38,
    detailHeight: 620,
    overlap: 4
)
let expectedDetailMaxY: CGFloat = 50 + 900 - 38 + 4
runner.check(
    detailFrames.collapsed.maxY == expectedDetailMaxY,
    "collapsed detail frame should preserve the shared top anchor"
)
runner.check(
    detailFrames.expanded.maxY == expectedDetailMaxY,
    "expanded detail frame should preserve the shared top anchor"
)
runner.check(
    detailFrames.collapsed.maxY == detailFrames.expanded.maxY,
    "detail frames should share the same maxY"
)
runner.check(
    detailFrames.collapsed.height == 4,
    "collapsed detail frame height should equal overlap"
)
runner.check(
    detailFrames.expanded.height == 620,
    "expanded detail frame height should equal detail height"
)

runner.check(AppInfo.version == "0.1.8", "app info should expose version 0.1.8")
runner.check(AppInfo.displayVersion == "0.1.8", "app info should fall back to source version when bundle version is unavailable")

let resetCreditsNow = Date(timeIntervalSince1970: 1_784_500_000)
let appServerResetCreditsJSON = Data(#"""
{
  "availableCount": 3,
  "credits": [
    {"id":"late","resetType":"codexRateLimits","status":"available","expiresAt":1786557546000},
    {"id":"early","resetType":"codexRateLimits","status":"available","expiresAt":1785110188},
    {"id":"used","resetType":"codexRateLimits","status":"consumed","expiresAt":1785525156},
    {"id":"other","resetType":"otherRateLimits","status":"available","expiresAt":1785525156},
    {"id":"expired","resetType":"codexRateLimits","status":"available","expiresAt":1784499999}
  ]
}
"""#.utf8)
let decodedAppServerResetCredits = try RateLimitResetCreditsDecoder.decode(
    appServerResetCreditsJSON,
    now: resetCreditsNow
)
runner.check(
    decodedAppServerResetCredits?.availableCount == 3,
    "reset credit count should prefer the service value"
)
runner.check(
    decodedAppServerResetCredits?.credits.map(\.id) == ["early", "late"],
    "reset credits should filter invalid entries and sort Unix second/millisecond expiries"
)
runner.check(
    decodedAppServerResetCredits?.fetchedAt == resetCreditsNow,
    "reset credit fetch time should use the supplied now value"
)
runner.check(
    decodedAppServerResetCredits?.hasExpiryDetails == true,
    "reset credits should report available expiry details"
)

let cpaResetCreditsJSON = Data(#"""
{
  "available_count": "1",
  "credits": [
    {"id":"cpa","reset_type":"codex_rate_limits","status":"available","expires_at":"2026-08-01T03:12:00.000Z"}
  ]
}
"""#.utf8)
let decodedCPAResetCredits = try RateLimitResetCreditsDecoder.decode(
    cpaResetCreditsJSON,
    now: resetCreditsNow
)
runner.check(
    decodedCPAResetCredits?.availableCount == 1,
    "CPA reset credit count should decode numeric strings"
)
runner.check(
    decodedCPAResetCredits?.credits.count == 1,
    "CPA reset credit expiry should decode snake-case ISO-8601 values"
)
let decodedCPAExpiry = runner.require(
    decodedCPAResetCredits?.credits.first?.expiresAt,
    "CPA reset credit should include an expiry date"
)
runner.check(
    RateLimitResetCreditsFormatter.expiryText(
        decodedCPAExpiry,
        timeZone: TimeZone(secondsFromGMT: 0)!
    ) == "2026/08/01 03:12",
    "reset credit expiry should use the agreed full date format"
)
runner.check(
    RateLimitResetCreditsFormatter.expiryText(
        decodedCPAExpiry,
        timeZone: TimeZone(secondsFromGMT: 8 * 60 * 60)!
    ) == "2026/08/01 11:12",
    "reset credit expiry should honor an injected GMT+8 time zone"
)

let plainISOResetCreditsJSON = Data(#"""
{
  "availableCount": 1,
  "credits": [
    {"id":"plain-iso","resetType":"codexRateLimits","status":"available","expiresAt":"2026-08-01T03:12:00Z"}
  ]
}
"""#.utf8)
let decodedPlainISOResetCredits = try RateLimitResetCreditsDecoder.decode(
    plainISOResetCreditsJSON,
    now: resetCreditsNow
)
runner.check(
    decodedPlainISOResetCredits?.credits.first?.expiresAt == decodedCPAExpiry,
    "reset credit expiry should decode ISO-8601 values without fractional seconds"
)

let fallbackResetCreditsJSON = Data(#"""
{
  "credits": [
    {"id":"z","reset_type":"codex_rate_limits","status":"available","expires_at":"1786557546"},
    {"id":"a","reset_type":"codex_rate_limits","status":"available","expires_at":1786557546},
    {"id":"expired","reset_type":"codex_rate_limits","status":"available","expires_at":1784499999}
  ]
}
"""#.utf8)
let fallbackResetCredits = try RateLimitResetCreditsDecoder.decode(
    fallbackResetCreditsJSON,
    now: resetCreditsNow
)
runner.check(
    fallbackResetCredits?.availableCount == 2,
    "reset credit count should fall back to the valid credit count when omitted"
)
runner.check(
    fallbackResetCredits?.credits.map(\.id) == ["a", "z"],
    "reset credits with equal expiries should sort by identifier"
)

let zeroResetCredits = try RateLimitResetCreditsDecoder.decode(
    Data(#"{"available_count":-2,"credits":[]}"#.utf8),
    now: resetCreditsNow
)
runner.check(zeroResetCredits?.availableCount == 0, "negative service counts should clamp to zero")
let unrelatedResetCredits = try RateLimitResetCreditsDecoder.decode(
    Data(#"{"unrelated":true}"#.utf8),
    now: resetCreditsNow
)
runner.check(
    unrelatedResetCredits == nil,
    "payloads without a count or credits field should not create reset-credit data"
)

runner.check(
    ResetCreditsDisplay(resetCredits: nil) == nil,
    "missing reset-credit data should hide the entire indicator"
)
let zeroResetCreditsDisplay = runner.require(
    ResetCreditsDisplay(
        resetCredits: RateLimitResetCredits(
            availableCount: 0,
            credits: [],
            fetchedAt: resetCreditsNow
        )
    ),
    "zero reset credits should still produce display text"
)
runner.check(
    zeroResetCreditsDisplay.countText == "剩余重置次数：0",
    "zero reset credits should use the exact agreed count copy"
)
runner.check(
    !zeroResetCreditsDisplay.showsInfoButton,
    "zero reset credits should not show an information button"
)
let zeroCountWithStaleDetailsDisplay = runner.require(
    ResetCreditsDisplay(
        resetCredits: RateLimitResetCredits(
            availableCount: 0,
            credits: [
                RateLimitResetCredit(
                    id: "stale",
                    expiresAt: Date(timeIntervalSince1970: 1_786_557_546)
                )
            ],
            fetchedAt: resetCreditsNow
        )
    ),
    "an authoritative zero count should remain visible despite stale details"
)
runner.check(
    !zeroCountWithStaleDetailsDisplay.showsInfoButton,
    "an authoritative zero count should hide the information button"
)
runner.check(
    zeroCountWithStaleDetailsDisplay.expiryRows().isEmpty,
    "an authoritative zero count should not expose stale expiry rows"
)

let countOnlyResetCreditsDisplay = runner.require(
    ResetCreditsDisplay(
        resetCredits: RateLimitResetCredits(
            availableCount: 3,
            credits: [],
            fetchedAt: resetCreditsNow
        )
    ),
    "a service count without expiry details should remain visible"
)
runner.check(
    countOnlyResetCreditsDisplay.countText == "剩余重置次数：3",
    "reset-credit display should use the exact agreed copy"
)
runner.check(
    !countOnlyResetCreditsDisplay.showsInfoButton,
    "a service count without expiry details should not show an information button"
)

let detailedResetCreditsDisplay = runner.require(
    ResetCreditsDisplay(
        resetCredits: RateLimitResetCredits(
            availableCount: 2,
            credits: [
                RateLimitResetCredit(
                    id: "later",
                    expiresAt: Date(timeIntervalSince1970: 1_786_557_546)
                ),
                RateLimitResetCredit(
                    id: "earlier",
                    expiresAt: Date(timeIntervalSince1970: 1_785_110_188)
                )
            ],
            fetchedAt: resetCreditsNow
        )
    ),
    "expiry details should produce an information button"
)
runner.check(
    detailedResetCreditsDisplay.showsInfoButton,
    "available expiry details should show an information button"
)
runner.check(
    detailedResetCreditsDisplay.expiryRows(timeZone: TimeZone(secondsFromGMT: 8 * 60 * 60)!) == [
        ResetCreditExpiryRow(ordinalText: "第 1 次", expiryText: "2026/07/27 07:56"),
        ResetCreditExpiryRow(ordinalText: "第 2 次", expiryText: "2026/08/13 01:59")
    ],
    "popover rows should sort expiries and use the agreed labels and date format"
)

let truncatedResetCreditsDisplay = runner.require(
    ResetCreditsDisplay(
        resetCredits: RateLimitResetCredits(
            availableCount: 1,
            credits: [
                RateLimitResetCredit(id: "later", expiresAt: Date(timeIntervalSince1970: 1_786_557_546)),
                RateLimitResetCredit(id: "earlier", expiresAt: Date(timeIntervalSince1970: 1_785_110_188))
            ],
            fetchedAt: resetCreditsNow
        )
    ),
    "service count should cap stale expiry details"
)
runner.check(
    truncatedResetCreditsDisplay.expiryDates.count == 1,
    "expiry rows should never exceed the authoritative available count"
)

runner.check(ResetCreditsPlacement.showsInLocalQuotaRow(label: "7d"), "local weekly quota row should show reset credits")
runner.check(!ResetCreditsPlacement.showsInLocalQuotaRow(label: "5h"), "local 5h quota row should not show reset credits")
runner.check(!ResetCreditsPlacement.showsInLocalQuotaRow(label: "周额度"), "local reset credits should only attach to the canonical 7d row")

let defaultRemoteRowWidth = IslandMetrics.width - 28
let minimumRemoteRowWidth = IslandMetrics.shoulderWidth * 2 + IslandMetrics.minimumNotchWidth - 28
runner.check(
    ResetCreditsLayout.mode(availableWidth: defaultRemoteRowWidth, hasResetCredits: true) == .full,
    "the default island width should use the full reset-credit layout"
)
runner.check(
    ResetCreditsLayout.mode(availableWidth: minimumRemoteRowWidth, hasResetCredits: true) == .compact,
    "the minimum notch width should use the compact reset-credit layout"
)
runner.check(
    ResetCreditsLayout.mode(availableWidth: defaultRemoteRowWidth, hasResetCredits: false) == .compact,
    "rows without reset-credit data should preserve the original compact allocation"
)
runner.check(
    ResetCreditsLayout.estimatedLeadingWidth(availableWidth: defaultRemoteRowWidth, mode: .full)
        >= ResetCreditsLayout.fullMinimumLeadingWidth,
    "the full layout should preserve readable account information at the default island width"
)
runner.check(
    ResetCreditsLayout.estimatedLeadingWidth(availableWidth: minimumRemoteRowWidth, mode: .compact)
        >= ResetCreditsLayout.minimumReadableLeadingWidth,
    "the compact layout should preserve readable account information at the minimum notch width"
)
runner.check(
    ResetCreditsLayout.inlineLayoutHeight == IslandMetrics.quotaResetTextHeight,
    "the local quota layout should reserve the full information-button hit target height"
)
runner.check(
    ResetCreditsLayout.remoteRequiredContentHeight <= ResetCreditsLayout.remoteCardHeight,
    "the remote state and 20-point quota lines should fit inside the fixed account card"
)

let snapshotFormatterTask = CodexTask(
    id: "snapshot-task",
    title: "父任务",
    status: .running,
    detail: "gpt-5.5 · 高推理",
    tokenCount: 12345,
    updatedAt: Date(timeIntervalSince1970: 0),
    activeSubagentCount: 3
)
let liveAgeTask = CodexTask(
    id: "live-age",
    title: "时间更新",
    status: .recent,
    detail: "gpt-5.6 · 超高推理 · 1分钟前",
    detailPrefix: "gpt-5.6 · 超高推理",
    tokenCount: 1,
    updatedAt: Date(timeIntervalSince1970: 1_000)
)
runner.check(
    liveAgeTask.displayDetail(now: Date(timeIntervalSince1970: 8_200)) == "gpt-5.6 · 超高推理 · 2小时前",
    "task detail should recalculate its relative age from the current UI clock"
)
let snapshotFormatterSnapshot = UsageSnapshot(
    primaryPercent: 88,
    secondaryPercent: 66,
    resetCredits: RateLimitResetCredits(
        availableCount: 2,
        credits: [
            RateLimitResetCredit(id: "later", expiresAt: Date(timeIntervalSince1970: 4_100)),
            RateLimitResetCredit(id: "earlier", expiresAt: Date(timeIntervalSince1970: 4_000))
        ],
        fetchedAt: Date(timeIntervalSince1970: 3_900)
    ),
    usage24h: 111,
    usage7d: 222,
    usage30d: 333,
    tasks: [snapshotFormatterTask],
    isRunning: true,
    lastUpdated: Date(timeIntervalSince1970: 0),
    errorMessage: nil
)
let humanSnapshotLines = SnapshotOutputFormatter.humanLines(for: snapshotFormatterSnapshot)
runner.check(
    humanSnapshotLines.contains("task=运行中 父任务 12345"),
    "human snapshot task line should preserve the token count as the final field"
)
runner.check(
    !humanSnapshotLines.contains { $0.contains("subagents=") },
    "human snapshot output should not append subagent fields to task lines"
)
let jsonSnapshot = try JSONSerialization.jsonObject(
    with: SnapshotOutputFormatter.jsonData(for: snapshotFormatterSnapshot)
) as? [String: Any]
let jsonSnapshotTasks = jsonSnapshot?["tasks"] as? [[String: Any]]
runner.check(
    jsonSnapshotTasks?.first?["subagents"] as? Int == 3,
    "JSON snapshot output should expose active subagent counts"
)
let jsonResetCredits = jsonSnapshot?["reset_credits"] as? [String: Any]
runner.check(
    jsonResetCredits?["available_count"] as? Int == 2,
    "JSON snapshot output should expose the available reset-credit count"
)
runner.check(
    jsonResetCredits?["expires_at"] as? [Int64] == [4_000, 4_100],
    "JSON snapshot output should expose sorted reset-credit expiry epoch seconds"
)
let snapshotWithoutResetCredits = UsageSnapshot(
    primaryPercent: nil,
    secondaryPercent: nil,
    usage24h: 0,
    usage7d: 0,
    usage30d: 0,
    tasks: [],
    isRunning: false,
    lastUpdated: Date(timeIntervalSince1970: 0),
    errorMessage: nil
)
let jsonWithoutResetCredits = try JSONSerialization.jsonObject(
    with: SnapshotOutputFormatter.jsonData(for: snapshotWithoutResetCredits)
) as? [String: Any]
runner.check(
    jsonWithoutResetCredits?["reset_credits"] == nil,
    "JSON snapshot output should omit reset_credits when data is unavailable"
)
runner.check(
    TaskBadgeFormatter.subagentBadgeText(for: 3) == "子代理 3",
    "task row subagent badge should use compact text"
)
runner.check(
    TaskBadgeFormatter.subagentBadgeText(for: 0) == nil,
    "task row subagent badge should stay hidden for zero active subagents"
)
let previousRateLimitSnapshot = UsageSnapshot(
    primaryPercent: 88,
    secondaryPercent: 66,
    primaryResetsAt: Date(timeIntervalSince1970: 2_000),
    secondaryResetsAt: Date(timeIntervalSince1970: 3_000),
    resetCredits: RateLimitResetCredits(
        availableCount: 3,
        credits: [RateLimitResetCredit(id: "previous", expiresAt: Date(timeIntervalSince1970: 4_000))],
        fetchedAt: Date(timeIntervalSince1970: 900)
    ),
    usage24h: 1,
    usage7d: 2,
    usage30d: 3,
    tasks: [],
    isRunning: false,
    lastUpdated: Date(timeIntervalSince1970: 1_000),
    errorMessage: nil
)
let missingRateLimitSnapshot = UsageSnapshot(
    primaryPercent: nil,
    secondaryPercent: nil,
    primaryResetsAt: nil,
    secondaryResetsAt: nil,
    usage24h: 4,
    usage7d: 5,
    usage30d: 6,
    tasks: [],
    isRunning: false,
    lastUpdated: Date(timeIntervalSince1970: 1_100),
    errorMessage: nil
)
let stabilizedRateLimitSnapshot = missingRateLimitSnapshot.stabilizedRateLimits(against: previousRateLimitSnapshot)
runner.check(stabilizedRateLimitSnapshot.primaryPercent == 88, "stabilized snapshot should preserve missing 5h percent")
runner.check(stabilizedRateLimitSnapshot.primaryResetsAt == previousRateLimitSnapshot.primaryResetsAt, "stabilized snapshot should preserve missing 5h reset time")
runner.check(stabilizedRateLimitSnapshot.secondaryPercent == 66, "stabilized snapshot should preserve missing 7d percent")
runner.check(stabilizedRateLimitSnapshot.secondaryResetsAt == previousRateLimitSnapshot.secondaryResetsAt, "stabilized snapshot should preserve missing 7d reset time")
runner.check(
    stabilizedRateLimitSnapshot.resetCredits == previousRateLimitSnapshot.resetCredits,
    "stabilized snapshot should preserve reset credits when the current refresh omits them"
)
let zeroCreditRateLimitSnapshot = UsageSnapshot(
    primaryPercent: nil,
    secondaryPercent: nil,
    resetCredits: RateLimitResetCredits(
        availableCount: 0,
        credits: [],
        fetchedAt: Date(timeIntervalSince1970: 1_100)
    ),
    usage24h: 4,
    usage7d: 5,
    usage30d: 6,
    tasks: [],
    isRunning: false,
    lastUpdated: Date(timeIntervalSince1970: 1_100),
    errorMessage: nil
)
let stabilizedZeroCreditSnapshot = zeroCreditRateLimitSnapshot.stabilizedRateLimits(against: previousRateLimitSnapshot)
runner.check(
    stabilizedZeroCreditSnapshot.resetCredits?.availableCount == 0,
    "an explicit zero reset-credit count should replace stale nonzero data"
)
let rateLimitNow = Date(timeIntervalSince1970: 2_000)
let expiredRateLimitSnapshot = RateLimitSnapshot(
    primaryPercent: 42,
    secondaryPercent: 58,
    primaryResetsAt: 1_900,
    secondaryResetsAt: 2_500,
    capturedAt: rateLimitNow,
    isPrimaryCodexLimit: true
)
runner.check(expiredRateLimitSnapshot.primaryDisplayPercent(now: rateLimitNow) == 100, "expired 5h quota should display as restored")
runner.check(expiredRateLimitSnapshot.primaryDisplayResetDate(now: rateLimitNow) == nil, "expired 5h reset time should be hidden")
runner.check(expiredRateLimitSnapshot.secondaryDisplayResetDate(now: rateLimitNow) == Date(timeIntervalSince1970: 2_500), "future 7d reset time should be preserved")
let cachedAppServerRateLimits = RateLimitSnapshot(
    primaryPercent: nil,
    secondaryPercent: 97,
    primaryResetsAt: nil,
    secondaryResetsAt: 3_000,
    capturedAt: Date(timeIntervalSince1970: 2_000),
    isPrimaryCodexLimit: true,
    resetCredits: RateLimitResetCredits(
        availableCount: 2,
        credits: [],
        fetchedAt: Date(timeIntervalSince1970: 2_000)
    )
)
let newerLocalRateLimits = RateLimitSnapshot(
    primaryPercent: nil,
    secondaryPercent: 87,
    primaryResetsAt: nil,
    secondaryResetsAt: 3_000,
    capturedAt: Date(timeIntervalSince1970: 2_030),
    isPrimaryCodexLimit: true
)
let freshestLocalRateLimits = RateLimitSnapshot.freshest(
    appServer: cachedAppServerRateLimits,
    localFiles: newerLocalRateLimits
)
runner.check(
    freshestLocalRateLimits.secondaryPercent == 87,
    "a newer local rate-limit event should replace the cached app-server percentage"
)
runner.check(
    freshestLocalRateLimits.resetCredits == cachedAppServerRateLimits.resetCredits,
    "a newer local rate-limit event should preserve app-server reset-credit details"
)
let refreshedAppServerRateLimits = RateLimitSnapshot(
    primaryPercent: nil,
    secondaryPercent: 85,
    primaryResetsAt: nil,
    secondaryResetsAt: 3_000,
    capturedAt: Date(timeIntervalSince1970: 2_040),
    isPrimaryCodexLimit: true
)
runner.check(
    RateLimitSnapshot.freshest(
        appServer: refreshedAppServerRateLimits,
        localFiles: newerLocalRateLimits
    ).secondaryPercent == 85,
    "a freshly queried app-server percentage should remain authoritative"
)
let weeklyOnlyQuotaWindow = UsageQuotaWindow(
    id: "codex-weekly",
    shortLabel: "7d",
    remainingPercent: 93,
    resetsAt: Date(timeIntervalSince1970: 1784488110)
)
let weeklyOnlyRateLimitSnapshot = UsageSnapshot(
    primaryPercent: nil,
    secondaryPercent: 93,
    primaryResetsAt: nil,
    secondaryResetsAt: Date(timeIntervalSince1970: 1784488110),
    rateLimitWindows: [weeklyOnlyQuotaWindow],
    usage24h: 4,
    usage7d: 5,
    usage30d: 6,
    tasks: [],
    isRunning: false,
    lastUpdated: Date(timeIntervalSince1970: 1_200),
    errorMessage: nil
)
let stabilizedWeeklyOnlySnapshot = weeklyOnlyRateLimitSnapshot.stabilizedRateLimits(against: previousRateLimitSnapshot)
runner.check(stabilizedWeeklyOnlySnapshot.primaryPercent == nil, "weekly-only Codex quota should not preserve stale 5h percent")
runner.check(stabilizedWeeklyOnlySnapshot.displayRateLimitWindows.map(\.shortLabel) == ["7d"], "weekly-only Codex quota should only display the weekly window")
let appServerParserStore = CodexUsageStore(
    codexDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("codex-notch-reset-credit-parser"),
    ripgrepCandidates: [],
    appServerExecutable: "/missing/codex"
)
let appServerParserNow = Date(timeIntervalSince1970: 1_784_500_000)
let appServerRateLimitOutput = #"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"resetsAt":1786557546,"windowDurationMins":10080}},"rateLimitResetCredits":{"available_count":"2","credits":[{"id":"later","reset_type":"codex_rate_limits","status":"available","expires_at":1786557546000},{"id":"earlier","reset_type":"codex_rate_limits","status":"available","expires_at":1785110188}]}}}"#
let parsedAppServerRateLimits = appServerParserStore.parseAppServerRateLimits(
    output: appServerRateLimitOutput,
    now: appServerParserNow
)
runner.check(
    parsedAppServerRateLimits?.displayWindows(now: appServerParserNow).map(\.shortLabel) == ["7d"],
    "app-server parsing should preserve a weekly-only Codex quota response"
)
runner.check(
    parsedAppServerRateLimits?.resetCredits?.availableCount == 2,
    "app-server parsing should attach reset credits from account/rateLimits/read"
)
runner.check(
    parsedAppServerRateLimits?.resetCredits?.credits.map(\.id) == ["earlier", "later"],
    "app-server parsing should use the shared reset-credit decoder and expiry ordering"
)
var fixedCalendar = Calendar(identifier: .gregorian)
fixedCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
let formatterNow = fixedCalendar.date(from: DateComponents(year: 2030, month: 1, day: 1, hour: 23, minute: 0))!
let formatterTomorrow = fixedCalendar.date(from: DateComponents(year: 2030, month: 1, day: 2, hour: 1, minute: 30))!
let formatterLater = fixedCalendar.date(from: DateComponents(year: 2030, month: 1, day: 3, hour: 9, minute: 0))!
runner.check(Formatters.quotaResetTime(nil, now: formatterNow, calendar: fixedCalendar) == "--", "nil reset time should render as placeholder")
runner.check(Formatters.quotaResetTime(formatterTomorrow, now: formatterNow, calendar: fixedCalendar) == "明天 01:30", "reset formatter should calculate tomorrow relative to the supplied now")
runner.check(Formatters.quotaResetTime(formatterLater, now: formatterNow, calendar: fixedCalendar) == "1月3日", "reset formatter should show date for later reset times")
runner.check(
    ScreenNotchGeometry.inferredNotchWidth(
        leftArea: CGRect(x: 0, y: 1291, width: 918, height: 38),
        rightArea: CGRect(x: 1138, y: 1291, width: 918, height: 38),
        fallback: IslandMetrics.notchWidth
    ) == 220,
    "notch width should be inferred from the gap between macOS auxiliary menu bar areas"
)
runner.check(
    ScreenNotchGeometry.adjustedNotchWidth(base: 220, adjustment: 12) == 232,
    "manual notch adjustment should be applied after system inference"
)
runner.check(
    ScreenNotchGeometry.adjustedNotchWidth(base: 300, adjustment: 200) == IslandMetrics.maximumNotchWidth,
    "manual notch adjustment should clamp to the supported maximum"
)
runner.check(
    ScreenNotchGeometry.inferredNotchWidth(leftArea: .zero, rightArea: .zero, fallback: IslandMetrics.notchWidth) == IslandMetrics.notchWidth,
    "notch width inference should fall back when auxiliary areas are unavailable"
)
runner.check(
    IslandMetrics.detailObscuredTopHeight(safeAreaTop: 38) == 18,
    "detail panel should know how much of its top overlaps the physical notch area"
)
runner.check(
    IslandMetrics.quotaResetTopPadding(safeAreaTop: 38) >= 25,
    "quota reset text should start below the overlapped physical notch area"
)
let tallNotchLayout = ScreenNotchGeometry.layout(
    leftArea: CGRect(x: 0, y: 1291, width: 900, height: 60),
    rightArea: CGRect(x: 1_120, y: 1291, width: 900, height: 60),
    safeAreaTop: 60,
    adjustment: 0
)
runner.check(tallNotchLayout.notchWidth == 220, "pure notch layout should infer width from auxiliary areas")
runner.check(tallNotchLayout.collapsedHeight == 60, "notch layout should grow collapsed height for taller physical notches")
runner.check(
    IslandMetrics.detailObscuredTopHeight(safeAreaTop: 60, collapsedHeight: tallNotchLayout.collapsedHeight) == 18,
    "taller collapsed islands should keep reset text below the physical notch without growing top content unnecessarily"
)
runner.check(
    IslandMetrics.detailContentTopPadding(
        safeAreaTop: 60,
        collapsedHeight: tallNotchLayout.collapsedHeight
    ) == IslandMetrics.quotaResetTopPadding(
        safeAreaTop: 60,
        collapsedHeight: tallNotchLayout.collapsedHeight
    ) + IslandMetrics.quotaResetTextHeight + IslandMetrics.quotaResetHeaderGap,
    "detail content should start below the full 20-point reset-credit hit target and header gap"
)
runner.check(
    IslandMetrics.combinedDetailHeight(
        accountRows: 4,
        showsPeriodUsage: true,
        usesTallRemoteRows: true,
        topPadding: IslandMetrics.detailTopPadding
    ) == IslandMetrics.remoteDetailHeight(accountRows: 4, usesTallRows: true, topPadding: IslandMetrics.detailTopPadding),
    "shared detail height should preserve tall remote account rows"
)

final class FakeLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled: Bool

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}

final class SequencedSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var vaults: [SecretVault]
    private(set) var loadCount = 0
    private(set) var savedVaults: [SecretVault] = []
    let secondLoadStarted = DispatchSemaphore(value: 0)
    let releaseSecondLoad = DispatchSemaphore(value: 0)

    init(vaults: [SecretVault]) {
        self.vaults = vaults
    }

    func loadVault() throws -> SecretVault {
        lock.lock()
        loadCount += 1
        let index = min(loadCount - 1, max(vaults.count - 1, 0))
        let vault = vaults.isEmpty ? SecretVault() : vaults[index]
        let shouldWait = loadCount == 2
        lock.unlock()

        if shouldWait {
            secondLoadStarted.signal()
            _ = releaseSecondLoad.wait(timeout: .now() + 2)
        }
        return vault
    }

    func saveVault(_ vault: SecretVault) throws {
        lock.lock()
        savedVaults.append(vault)
        if vaults.isEmpty {
            vaults = [vault]
        } else {
            vaults[vaults.count - 1] = vault
        }
        lock.unlock()
    }
}

func pumpMainRunLoop(until deadline: Date, condition: () -> Bool) -> Bool {
    while Date() < deadline {
        if condition() {
            return true
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
}

func remoteAccount(
    id: String,
    state: RemoteAccountState,
    quotaWindows: [RemoteQuotaWindow] = [],
    quotaError: String? = nil,
    unavailable: Bool = false
) -> RemoteCodexAccount {
    RemoteCodexAccount(
        id: id,
        name: id,
        email: nil,
        label: nil,
        provider: "codex",
        accountType: nil,
        authIndex: id,
        chatgptAccountID: nil,
        status: state == .abnormal ? "error" : "active",
        statusMessage: state == .abnormal ? "auth failed" : nil,
        successCount: 1,
        failureCount: state == .abnormal ? 1 : 0,
        recentFailures: state == .abnormal ? 1 : 0,
        state: state,
        lastRefresh: nil,
        planType: "plus",
        quotaWindows: quotaWindows,
        quotaError: quotaError,
        unavailable: unavailable
    )
}

final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

final class AsyncResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func waitForAsync<Value: Sendable>(
    _ operation: @escaping @Sendable () async -> Value
) -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<Value>()
    Task.detached {
        box.store(await operation())
        semaphore.signal()
    }
    semaphore.wait()
    guard let value = box.load() else {
        fatalError("Async test operation completed without a value")
    }
    return value
}

actor ResetCreditsFetchProbe {
    private var activeRequests = 0
    private var maximumActiveRequests = 0
    private var callsByAuthIndex: [String: Int] = [:]

    func begin(_ authIndex: String) {
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        callsByAuthIndex[authIndex, default: 0] += 1
    }

    func end() {
        activeRequests -= 1
    }

    func snapshot() -> (maximumActiveRequests: Int, totalCalls: Int, authIndexes: Set<String>) {
        (
            maximumActiveRequests,
            callsByAuthIndex.values.reduce(0, +),
            Set(callsByAuthIndex.keys)
        )
    }
}

final class ResetCreditsWorkerProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var slowWorkerFinished = false
    private var laterCandidateStartedWhileSlow = false

    func markLaterCandidateStarted() {
        lock.lock()
        if !slowWorkerFinished {
            laterCandidateStartedWhileSlow = true
        }
        lock.unlock()
    }

    func markSlowWorkerFinished() {
        lock.lock()
        slowWorkerFinished = true
        lock.unlock()
    }

    func didDynamicallyRefill() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return laterCandidateStartedWhileSlow
    }
}

struct ResetCreditsFetchTestError: Error {}

let remoteResetCreditsClock = LockedTestClock(Date(timeIntervalSince1970: 1_800_000_000))
let cacheBoundaryCredits = RateLimitResetCredits(
    availableCount: 2,
    credits: [
        RateLimitResetCredit(
            id: "cache-boundary",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
    ],
    fetchedAt: remoteResetCreditsClock.now()
)
let cacheBoundary = RemoteResetCreditsCache(ttl: 3_600, now: remoteResetCreditsClock.now)
let cacheBoundaryRevision = cacheBoundary.beginRevision(
    panelURL: " HTTPS://Panel.Example.com:443/management.html?tab=quota "
)
cacheBoundary.store(
    cacheBoundaryCredits,
    panelURL: " HTTPS://Panel.Example.com:443/management.html?tab=quota ",
    authIndex: " Auth-A ",
    revision: cacheBoundaryRevision
)
runner.check(
    cacheBoundary.fresh(panelURL: "https://panel.example.com", authIndex: "Auth-A") == cacheBoundaryCredits,
    "reset-credit cache should normalize panel identity and authIndex"
)
runner.check(
    cacheBoundary.fresh(panelURL: "https://other.example.com", authIndex: "Auth-A") == nil,
    "reset-credit cache should isolate panel identities"
)
runner.check(
    cacheBoundary.fresh(panelURL: "https://panel.example.com", authIndex: "Auth-B") == nil,
    "reset-credit cache should isolate auth indexes"
)
remoteResetCreditsClock.advance(by: 3_599)
runner.check(
    cacheBoundary.fresh(panelURL: "https://panel.example.com", authIndex: "Auth-A") != nil,
    "reset-credit cache should remain fresh immediately before the TTL boundary"
)
remoteResetCreditsClock.advance(by: 1)
runner.check(
    cacheBoundary.fresh(panelURL: "https://panel.example.com", authIndex: "Auth-A") == nil,
    "reset-credit cache should expire at the TTL boundary"
)
runner.check(
    cacheBoundary.stale(panelURL: "https://panel.example.com", authIndex: "Auth-A") == cacheBoundaryCredits,
    "reset-credit cache should retain stale data for failure fallback"
)

let revisionCache = RemoteResetCreditsCache(ttl: 3_600, now: remoteResetCreditsClock.now)
let oldRevision = revisionCache.beginRevision(panelURL: "https://revision.example.com")
let newRevision = revisionCache.beginRevision(panelURL: "https://revision.example.com/management.html")
let oldRevisionCredits = RateLimitResetCredits(
    availableCount: 1,
    credits: [],
    fetchedAt: remoteResetCreditsClock.now()
)
let newRevisionCredits = RateLimitResetCredits(
    availableCount: 9,
    credits: [],
    fetchedAt: remoteResetCreditsClock.now()
)
runner.check(
    !revisionCache.invalidate(oldRevision),
    "a late cancellation from an old revision should not invalidate a newer revision"
)
runner.check(
    !revisionCache.store(
        oldRevisionCredits,
        panelURL: "https://revision.example.com",
        authIndex: "revision-auth",
        revision: oldRevision
    ),
    "an older reset-credit revision should be rejected after a newer refresh begins"
)
runner.check(
    revisionCache.store(
        newRevisionCredits,
        panelURL: "https://revision.example.com",
        authIndex: "revision-auth",
        revision: newRevision
    ),
    "the latest reset-credit revision should be allowed to write"
)
runner.check(
    revisionCache.fresh(
        panelURL: "https://revision.example.com",
        authIndex: "revision-auth"
    ) == newRevisionCredits,
    "the newer revision should remain fresh after a late old cancellation"
)
let panelScopedRevisionCache = RemoteResetCreditsCache(ttl: 3_600, now: remoteResetCreditsClock.now)
let panelARevision = panelScopedRevisionCache.beginRevision(panelURL: "https://panel-a.example.com")
_ = panelScopedRevisionCache.beginRevision(panelURL: "https://panel-b.example.com")
runner.check(
    panelScopedRevisionCache.store(
        oldRevisionCredits,
        panelURL: "https://panel-a.example.com",
        authIndex: "shared-auth",
        revision: panelARevision
    ),
    "a new revision on another panel should not invalidate the current panel revision"
)

let loaderClock = LockedTestClock(Date(timeIntervalSince1970: 1_810_000_000))
let loaderCache = RemoteResetCreditsCache(ttl: 3_600, now: loaderClock.now)
let loader = RemoteResetCreditsLoader(cache: loaderCache)
let loaderAccounts = (1...5).map { index in
    remoteAccount(id: "loader-\(index)", state: .healthy)
}
let fetchProbe = ResetCreditsFetchProbe()
let workerProgress = ResetCreditsWorkerProgress()
let loadedAccounts = waitForAsync {
    await loader.load(
        accounts: loaderAccounts,
        dataSource: .cpaManagerPlus,
        panelURL: "https://panel.example.com/management.html"
    ) { authIndex, _ in
        await fetchProbe.begin(authIndex)
        if authIndex == "loader-1" {
            try? await Task.sleep(nanoseconds: 150_000_000)
            workerProgress.markSlowWorkerFinished()
        } else {
            if authIndex == "loader-3" || authIndex == "loader-4" {
                workerProgress.markLaterCandidateStarted()
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await fetchProbe.end()
        return RateLimitResetCredits(
            availableCount: Int(authIndex.split(separator: "-").last ?? "0") ?? 0,
            credits: [],
            fetchedAt: loaderClock.now()
        )
    }
}
let initialFetchProbeSnapshot = waitForAsync { await fetchProbe.snapshot() }
runner.check(
    initialFetchProbeSnapshot.maximumActiveRequests == 2,
    "remote reset-credit loader should cap concurrent requests at two"
)
runner.check(
    workerProgress.didDynamicallyRefill(),
    "a slow reset-credit account should not block the other worker from taking later accounts"
)
runner.check(
    initialFetchProbeSnapshot.totalCalls == loaderAccounts.count,
    "remote reset-credit loader should request each eligible account once"
)
runner.check(
    loadedAccounts.map(\.id) == loaderAccounts.map(\.id),
    "remote reset-credit loader should preserve account order"
)
runner.check(
    loadedAccounts.map { $0.resetCredits?.availableCount } == [1, 2, 3, 4, 5],
    "remote reset-credit loader should attach results to the matching accounts"
)

let cacheHitProbe = ResetCreditsFetchProbe()
let automaticallyCachedAccounts = waitForAsync {
    await loader.load(
        accounts: loaderAccounts,
        dataSource: .cpaManagerPlus,
        panelURL: "https://panel.example.com"
    ) { authIndex, _ in
        await cacheHitProbe.begin(authIndex)
        await cacheHitProbe.end()
        throw ResetCreditsFetchTestError()
    }
}
let automaticFetchProbeSnapshot = waitForAsync { await cacheHitProbe.snapshot() }
runner.check(
    automaticFetchProbeSnapshot.totalCalls == 0,
    "automatic reset-credit refresh should not invoke fetch for fresh cache entries"
)
runner.check(
    automaticallyCachedAccounts.map { $0.resetCredits?.availableCount } == [1, 2, 3, 4, 5],
    "automatic reset-credit refresh should return cached values"
)

let forcedProbe = ResetCreditsFetchProbe()
let forceRefreshedAccounts = waitForAsync {
    await loader.load(
        accounts: loaderAccounts,
        dataSource: .cpaManagerPlus,
        panelURL: "https://panel.example.com",
        forceRefresh: true
    ) { authIndex, _ in
        await forcedProbe.begin(authIndex)
        await forcedProbe.end()
        return RateLimitResetCredits(
            availableCount: 10 + (Int(authIndex.split(separator: "-").last ?? "0") ?? 0),
            credits: [],
            fetchedAt: loaderClock.now()
        )
    }
}
let forcedFetchProbeSnapshot = waitForAsync { await forcedProbe.snapshot() }
runner.check(
    forcedFetchProbeSnapshot.totalCalls == loaderAccounts.count,
    "manual reset-credit refresh should bypass fresh cache entries"
)
runner.check(
    forceRefreshedAccounts.map { $0.resetCredits?.availableCount } == [11, 12, 13, 14, 15],
    "manual reset-credit refresh should replace cached values"
)

loaderClock.advance(by: 3_600)
let staleFallbackAccounts = waitForAsync {
    await loader.load(
        accounts: loaderAccounts,
        dataSource: .cpaManagerPlus,
        panelURL: "https://panel.example.com"
    ) { _, _ in
        throw ResetCreditsFetchTestError()
    }
}
runner.check(
    staleFallbackAccounts.map { $0.resetCredits?.availableCount } == [11, 12, 13, 14, 15],
    "failed reset-credit refresh should fall back to stale values"
)

let cancellationCache = RemoteResetCreditsCache(ttl: 3_600, now: loaderClock.now)
let cancellationProbe = ResetCreditsFetchProbe()
let cancellationAccounts = [
    remoteAccount(id: "cancel-fast", state: .healthy),
    remoteAccount(id: "cancel-signal", state: .healthy),
    remoteAccount(id: "cancel-never-started", state: .healthy)
]
let cancelledAccounts = waitForAsync {
    await RemoteResetCreditsLoader(
        cache: cancellationCache,
        maxConcurrentRequests: 1
    ).load(
        accounts: cancellationAccounts,
        dataSource: .cpaManagerPlus,
        panelURL: "https://cancel.example.com",
        forceRefresh: true
    ) { authIndex, _ in
        await cancellationProbe.begin(authIndex)
        await cancellationProbe.end()
        if authIndex == "cancel-signal" {
            throw CancellationError()
        }
        return RateLimitResetCredits(
            availableCount: 4,
            credits: [],
            fetchedAt: loaderClock.now()
        )
    }
}
let cancellationProbeSnapshot = waitForAsync { await cancellationProbe.snapshot() }
runner.check(
    cancelledAccounts.first?.resetCredits?.availableCount == 4,
    "a valid reset-credit success before cancellation should be retained"
)
runner.check(
    cancellationProbeSnapshot.totalCalls == 2,
    "cancellation should stop workers from scheduling later reset-credit requests"
)
runner.check(
    cancellationProbeSnapshot.authIndexes == ["cancel-fast", "cancel-signal"],
    "cancellation should not start an account after the cancellation signal"
)
runner.check(
    cancellationCache.stale(
        panelURL: "https://cancel.example.com",
        authIndex: "cancel-fast"
    )?.availableCount == 4,
    "a cache write completed before cancellation should be preserved"
)
runner.check(
    cancellationCache.stale(
        panelURL: "https://cancel.example.com",
        authIndex: "cancel-never-started"
    ) == nil,
    "an account not scheduled after cancellation should not write cache data"
)

runner.check(
    RemoteResetCreditsEnrichmentCoordinator.timeoutBudget(forRequestTimeout: 1) == 5,
    "reset-credit best-effort timeout should enforce its five-second minimum"
)
runner.check(
    RemoteResetCreditsEnrichmentCoordinator.timeoutBudget(forRequestTimeout: 6) == 12,
    "reset-credit best-effort timeout should use twice the single-request timeout"
)
runner.check(
    RemoteResetCreditsEnrichmentCoordinator.timeoutBudget(forRequestTimeout: 30) == 20,
    "reset-credit best-effort timeout should enforce its twenty-second maximum"
)
let pipelineSuccessProbe = ResetCreditsFetchProbe()
let pipelineSuccess = waitForAsync {
    await RemoteCoreThenEnrichmentPipeline.run(
        core: { 21 },
        enrichment: { value in
            await pipelineSuccessProbe.begin("enrichment")
            await pipelineSuccessProbe.end()
            return value * 2
        }
    )
}
let pipelineSuccessProbeSnapshot = waitForAsync { await pipelineSuccessProbe.snapshot() }
runner.check(
    pipelineSuccess == 42 && pipelineSuccessProbeSnapshot.totalCalls == 1,
    "a successful core refresh should run the non-throwing enrichment exactly once"
)
let pipelineFailureProbe = ResetCreditsFetchProbe()
let pipelineFailure = waitForAsync { () -> Int? in
    try? await RemoteCoreThenEnrichmentPipeline.run(
        core: { () async throws -> Int in
            throw ResetCreditsFetchTestError()
        },
        enrichment: { value in
            await pipelineFailureProbe.begin("enrichment")
            await pipelineFailureProbe.end()
            return value * 2
        }
    )
}
let pipelineFailureProbeSnapshot = waitForAsync { await pipelineFailureProbe.snapshot() }
runner.check(
    pipelineFailure == nil && pipelineFailureProbeSnapshot.totalCalls == 0,
    "a failed core refresh should propagate failure without starting enrichment"
)
let bestEffortCache = RemoteResetCreditsCache(ttl: 3_600, now: loaderClock.now)
let coreAccounts = [
    remoteAccount(
        id: "core-survives-timeout",
        state: .healthy,
        quotaWindows: [
            RemoteQuotaWindow(
                id: "core-weekly",
                shortLabel: "7d",
                remainingPercent: 80,
                usedPercent: 20,
                resetText: nil
            )
        ]
    )
]
let timeoutStart = Date()
let timeoutEnrichmentResult = waitForAsync {
    await RemoteResetCreditsEnrichmentCoordinator(
        loader: RemoteResetCreditsLoader(cache: bestEffortCache),
        timeoutBudget: 0.05
    ).enrich(
        accounts: coreAccounts,
        dataSource: .cpaManagerPlus,
        panelURL: "https://timeout.example.com",
        forceRefresh: true
    ) { _, _ in
        usleep(500_000)
        return RateLimitResetCredits(
            availableCount: 7,
            credits: [],
            fetchedAt: loaderClock.now()
        )
    }
}
let timeoutElapsed = Date().timeIntervalSince(timeoutStart)
runner.check(
    timeoutEnrichmentResult == coreAccounts,
    "reset-credit best-effort timeout should return the successful core account result"
)
runner.check(
    timeoutElapsed < 0.30,
    "a 50ms reset-credit budget should return without waiting for a 500ms non-cooperative fetch"
)
Thread.sleep(forTimeInterval: 0.55)
runner.check(
    bestEffortCache.stale(
        panelURL: "https://timeout.example.com",
        authIndex: "core-survives-timeout"
    ) == nil,
    "timed-out reset-credit enrichment should not write cache data"
)

let partialCache = RemoteResetCreditsCache(ttl: 3_600, now: loaderClock.now)
let partialPanelURL = "https://partial.example.com"
let partialSeedRevision = partialCache.beginRevision(panelURL: partialPanelURL)
let slowStaleCredits = RateLimitResetCredits(
    availableCount: 2,
    credits: [],
    fetchedAt: loaderClock.now()
)
partialCache.store(
    slowStaleCredits,
    panelURL: partialPanelURL,
    authIndex: "partial-slow",
    revision: partialSeedRevision
)
let partialAccounts = [
    remoteAccount(id: "partial-fast", state: .healthy),
    remoteAccount(id: "partial-slow", state: .healthy)
]
let partialResult = waitForAsync {
    await RemoteResetCreditsEnrichmentCoordinator(
        loader: RemoteResetCreditsLoader(cache: partialCache),
        timeoutBudget: 0.10
    ).enrich(
        accounts: partialAccounts,
        dataSource: .cpaManagerPlus,
        panelURL: partialPanelURL,
        forceRefresh: true
    ) { authIndex, _ in
        if authIndex == "partial-slow" {
            usleep(500_000)
            return RateLimitResetCredits(
                availableCount: 99,
                credits: [],
                fetchedAt: loaderClock.now()
            )
        }
        return RateLimitResetCredits(
            availableCount: 8,
            credits: [],
            fetchedAt: loaderClock.now()
        )
    }
}
runner.check(
    partialResult.map { $0.resetCredits?.availableCount } == [8, 2],
    "best-effort timeout should merge a fast new value and the slow account stale value"
)
runner.check(
    partialCache.stale(
        panelURL: partialPanelURL,
        authIndex: "partial-fast"
    )?.availableCount == 8,
    "a fast account should write cache immediately before another account times out"
)
Thread.sleep(forTimeInterval: 0.55)
runner.check(
    partialCache.stale(
        panelURL: partialPanelURL,
        authIndex: "partial-slow"
    ) == slowStaleCredits,
    "a slow account completing after timeout cancellation should not overwrite stale cache"
)

let callerCancellationCache = RemoteResetCreditsCache(ttl: 3_600, now: loaderClock.now)
let callerCancellationElapsed = waitForAsync { () -> TimeInterval in
    let task = Task {
        await RemoteResetCreditsEnrichmentCoordinator(
            loader: RemoteResetCreditsLoader(cache: callerCancellationCache),
            timeoutBudget: 10
        ).enrich(
            accounts: [remoteAccount(id: "caller-cancelled", state: .healthy)],
            dataSource: .cpaManagerPlus,
            panelURL: "https://caller-cancel.example.com",
            forceRefresh: true
        ) { _, _ in
            usleep(500_000)
            return RateLimitResetCredits(
                availableCount: 6,
                credits: [],
                fetchedAt: loaderClock.now()
            )
        }
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    let startedAt = Date()
    task.cancel()
    _ = await task.value
    return Date().timeIntervalSince(startedAt)
}
runner.check(
    callerCancellationElapsed < 0.30,
    "caller cancellation should resolve the one-shot coordinator gate immediately"
)
Thread.sleep(forTimeInterval: 0.55)
runner.check(
    callerCancellationCache.stale(
        panelURL: "https://caller-cancel.example.com",
        authIndex: "caller-cancelled"
    ) == nil,
    "a fetch completing after caller cancellation should not write cache"
)

let neverLoadedAccount = remoteAccount(id: "never-loaded", state: .healthy)
let neverLoadedResult = waitForAsync {
    await RemoteResetCreditsLoader(
        cache: RemoteResetCreditsCache(ttl: 3_600, now: loaderClock.now)
    ).load(
        accounts: [neverLoadedAccount],
        dataSource: .cpaManagerPlus,
        panelURL: "https://new-panel.example.com"
    ) { _, _ in
        throw ResetCreditsFetchTestError()
    }
}
runner.check(
    neverLoadedResult == [neverLoadedAccount],
    "first reset-credit failure should not alter account data, state, or reason"
)

let skippedProbe = ResetCreditsFetchProbe()
let skippedDataSourceResult = waitForAsync {
    await loader.load(
        accounts: loaderAccounts,
        dataSource: .cliProxyAPI,
        panelURL: "https://panel.example.com",
        forceRefresh: true
    ) { authIndex, _ in
        await skippedProbe.begin(authIndex)
        await skippedProbe.end()
        return cacheBoundaryCredits
    }
}
let skippedFetchProbeSnapshot = waitForAsync { await skippedProbe.snapshot() }
runner.check(
    skippedDataSourceResult == loaderAccounts,
    "CLIProxyAPI data source should skip reset-credit loading"
)
runner.check(
    skippedFetchProbeSnapshot.totalCalls == 0,
    "CLIProxyAPI data source should not issue reset-credit requests"
)

let missingAuthAccount = RemoteCodexAccount(
    id: "missing-auth",
    name: "missing-auth",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "   ",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [],
    quotaError: nil
)
let missingAuthResult = waitForAsync {
    await loader.load(
        accounts: [missingAuthAccount],
        dataSource: .cpaManagerPlus,
        panelURL: "https://panel.example.com",
        forceRefresh: true
    ) { _, _ in
        return cacheBoundaryCredits
    }
}
runner.check(
    missingAuthResult == [missingAuthAccount],
    "accounts without authIndex should be skipped without changing state"
)

let exhaustedFiveHourWindow = RemoteQuotaWindow(
    id: "code-primary",
    shortLabel: "5h",
    remainingPercent: 0,
    usedPercent: 100,
    resetText: nil
)
let exhaustedWeeklyWindow = RemoteQuotaWindow(
    id: "code-secondary",
    shortLabel: "7d",
    remainingPercent: 0,
    usedPercent: 100,
    resetText: nil
)
let proQuotaAccount = remoteAccount(
    id: "pro-four-windows",
    state: .healthy,
    quotaWindows: [
        RemoteQuotaWindow(id: "primary", shortLabel: "5h", remainingPercent: 98, usedPercent: 2, resetText: nil),
        RemoteQuotaWindow(id: "secondary", shortLabel: "7d", remainingPercent: 60, usedPercent: 40, resetText: nil),
        RemoteQuotaWindow(id: "pro-20x", shortLabel: "Pro 20x", remainingPercent: 100, usedPercent: 0, resetText: nil),
        RemoteQuotaWindow(id: "pro-5x", shortLabel: "Pro 5x", remainingPercent: 80, usedPercent: 20, resetText: nil),
        RemoteQuotaWindow(id: "spark-5h", shortLabel: "GPT-5.3-Codex-Spark 5h", remainingPercent: 100, usedPercent: 0, resetText: nil),
        RemoteQuotaWindow(id: "spark-7d", shortLabel: "GPT-5.3-Codex-Spark 7d", remainingPercent: 100, usedPercent: 0, resetText: nil)
    ]
)
runner.check(proQuotaAccount.displayQuotaWindows.map(\.shortLabel) == ["5h", "7d"], "CLIProxyAPI Pro account detail should only display bare 5h and 7d quota windows")
runner.check(proQuotaAccount.quotaSummaryText == "5h 98%  7d 60%", "CLIProxyAPI Pro account quota summary should hide extra Pro quota windows")
let duplicateAliasQuotaAccount = remoteAccount(
    id: "duplicate-primary-aliases",
    state: .healthy,
    quotaWindows: [
        RemoteQuotaWindow(id: "alias-5h", shortLabel: "5小时", remainingPercent: 81, usedPercent: 19, resetText: nil),
        RemoteQuotaWindow(id: "canonical-5h", shortLabel: "5h", remainingPercent: 81, usedPercent: 19, resetText: nil),
        RemoteQuotaWindow(id: "alias-7d", shortLabel: "1周", remainingPercent: 61, usedPercent: 39, resetText: nil),
        RemoteQuotaWindow(id: "canonical-7d", shortLabel: "7d", remainingPercent: 61, usedPercent: 39, resetText: nil),
        RemoteQuotaWindow(id: "monthly", shortLabel: "30d", remainingPercent: 50, usedPercent: 50, resetText: nil)
    ]
)
runner.check(
    duplicateAliasQuotaAccount.displayQuotaWindows.map(\.id) == ["canonical-5h", "canonical-7d"],
    "primary quota display should canonically deduplicate aliases and keep 5h/7d order"
)
runner.check(
    duplicateAliasQuotaAccount.alertQuotaWindows.map(\.id) == ["canonical-5h", "canonical-7d", "monthly"],
    "account alerts should reuse authoritative primary windows while preserving non-primary windows"
)
let conflictingAliasQuotaAccount = remoteAccount(
    id: "conflicting-primary-aliases",
    state: .healthy,
    quotaWindows: [
        RemoteQuotaWindow(id: "canonical-healthy", shortLabel: "5h", remainingPercent: 81, usedPercent: 19, resetText: nil),
        RemoteQuotaWindow(id: "alias-exhausted", shortLabel: "5小时", remainingPercent: 0, usedPercent: 100, resetText: nil),
        RemoteQuotaWindow(id: "weekly", shortLabel: "7d", remainingPercent: 60, usedPercent: 40, resetText: nil),
        RemoteQuotaWindow(id: "monthly", shortLabel: "30d", remainingPercent: 50, usedPercent: 50, resetText: nil)
    ]
)
runner.check(
    conflictingAliasQuotaAccount.displayQuotaWindows.map(\.id) == ["alias-exhausted", "weekly"],
    "display should select the most constrained authoritative primary window"
)
runner.check(
    conflictingAliasQuotaAccount.alertQuotaWindows.map(\.id) == ["alias-exhausted", "weekly", "monthly"],
    "alerts should reuse the same constrained primary window and retain 30d"
)
runner.check(
    conflictingAliasQuotaAccount.withQuotaExhaustion.state == .quotaExhausted,
    "the authoritative exhausted alias should drive the account alert state"
)
let modelOnlyQuotaAccount = remoteAccount(
    id: "model-only-windows",
    state: .healthy,
    quotaWindows: [
        RemoteQuotaWindow(id: "spark-5h", shortLabel: "GPT-5.3-Codex-Spark 5h", remainingPercent: 100, usedPercent: 0, resetText: nil),
        RemoteQuotaWindow(id: "spark-7d", shortLabel: "GPT-5.3-Codex-Spark 7d", remainingPercent: 100, usedPercent: 0, resetText: nil)
    ]
)
runner.check(modelOnlyQuotaAccount.displayQuotaWindows.isEmpty, "CLIProxyAPI detail should not fall back to displaying model quota windows when bare 5h/7d are missing")
runner.check(modelOnlyQuotaAccount.quotaSummaryText == "额度 --", "CLIProxyAPI quota summary should stay empty when only hidden model windows are available")

runner.check(RefreshCadence.pendingSnapshotDelay(for: 2) == 1, "coalesced snapshot refresh should wait at least one second")
runner.check(RefreshCadence.pendingSnapshotDelay(for: 6) == 3, "coalesced snapshot refresh should cap short follow-up waits")
runner.check(RefreshCadence.pendingUsageDelay(for: 30) == 15, "coalesced usage refresh should avoid tight restart loops")
runner.check(RefreshCadence.pendingUsageDelay(for: 300) == 60, "coalesced usage refresh should cap long follow-up waits")
runner.check(UsageRefreshCadence.refreshInterval(configured: 30, lastDuration: nil) == 120, "period usage refresh should not run more often than the power-safe floor")
runner.check(UsageRefreshCadence.refreshInterval(configured: 300, lastDuration: nil) == 300, "period usage refresh should respect larger configured intervals")
runner.check(UsageRefreshCadence.refreshInterval(configured: 120, lastDuration: 6) == 180, "slow usage scans should push the next refresh farther out")
runner.check(UsageRefreshCadence.refreshInterval(configured: 600, lastDuration: 40) == 1_200, "very slow usage scans should adapt without exceeding the cap")
let usageFileChangeNow = Date(timeIntervalSince1970: 1_000)
runner.check(
    UsageRefreshCadence.fileChangeDelay(now: usageFileChangeNow, lastCompletedAt: nil) == 4,
    "the first watched session change should settle briefly before refreshing usage"
)
runner.check(
    UsageRefreshCadence.fileChangeDelay(
        now: usageFileChangeNow,
        lastCompletedAt: usageFileChangeNow.addingTimeInterval(-30)
    ) == 30,
    "watched session changes should respect the one-minute usage refresh throttle"
)
runner.check(
    UsageRefreshCadence.fileChangeDelay(
        now: usageFileChangeNow,
        lastCompletedAt: usageFileChangeNow.addingTimeInterval(-90)
    ) == 4,
    "stale period usage should refresh promptly after a watched session change"
)
runner.check(BalanceRefreshCadence.refreshInterval(base: 300, consecutiveFailures: 0) == 300, "healthy balance refresh should use the configured interval")
runner.check(BalanceRefreshCadence.refreshInterval(base: 300, consecutiveFailures: 1) == 30, "failed balance refresh should retry quickly instead of leaving stale timeout state")
runner.check(BalanceRefreshCadence.refreshInterval(base: 60, consecutiveFailures: 3) == 30, "repeated balance failures should cap retry interval")

let decoder = CodexSessionEventDecoder()
let decoderNow = Date(timeIntervalSince1970: 1_800_000_000)
let decoderFormatter = ISO8601DateFormatter()
let decoderTimestamp = decoderFormatter.string(from: decoderNow)
let decoderText = """
{"timestamp":"\(decoderTimestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"xhigh"}}
{"timestamp":"\(decoderTimestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"## My request for Codex:\\n集中解析 JSONL"}]}}
{"timestamp":"\(decoderTimestamp)","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}
{"timestamp":"\(decoderFormatter.string(from: decoderNow.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"task_complete"}}
"""
runner.check(decoder.title(from: decoderText) == "集中解析 JSONL", "session decoder should normalize Codex request titles")
runner.check(decoder.runtimeInfo(from: decoderText)?.model == "gpt-5.5", "session decoder should read turn context model")
runner.check(decoder.runtimeInfo(from: decoderText)?.reasoningEffort == "xhigh", "session decoder should read turn context effort")
runner.check(decoder.activityInfo(from: decoderText)?.latestDone != nil, "session decoder should detect task completion events")
runner.check(
    decoder.tokenCountTokens(from: #"{"timestamp":"\#(decoderTimestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":123}}}}"#) == 123,
    "session decoder should extract token_count totals"
)

let settingsSuiteName = "CodexNotchRegressionTests-\(UUID().uuidString)"
let settingsDefaults = runner.require(
    UserDefaults(suiteName: settingsSuiteName),
    "settings regression defaults should be available"
)
settingsDefaults.removePersistentDomain(forName: settingsSuiteName)
var secretVault = SecretVault()
secretVault.set("clip-secret", for: .cliproxyManagement)
secretVault.set("newapi-legacy", for: .newAPIManagement)
secretVault.set("subapi-legacy", for: .subAPIManagement)
secretVault.set("account-secret", for: .balanceAccount(source: .newAPI, id: "account-1"))
runner.check(secretVault.value(for: .cliproxyManagement) == "clip-secret", "secret vault should store CLIProxyAPI key")
runner.check(secretVault.value(for: .balanceAccount(source: .newAPI, id: "account-1")) == "account-secret", "secret vault should store account secret")
secretVault.set("", for: .balanceAccount(source: .newAPI, id: "account-1"))
runner.check(secretVault.value(for: .balanceAccount(source: .newAPI, id: "account-1")).isEmpty, "empty secret should remove vault entry")
let memorySecretStore = MemorySecretStore()
try memorySecretStore.saveVault(secretVault)
let loadedMemoryVault = try memorySecretStore.loadVault()
runner.check(loadedMemoryVault == secretVault, "memory secret store should persist one vault")
let secretDatabaseURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexNotchSecretStore-\(UUID().uuidString)")
    .appendingPathComponent("secrets.sqlite3")
let databaseSecretStore = DatabaseSecretStore(databaseURL: secretDatabaseURL)
try databaseSecretStore.saveVault(secretVault)
let loadedDatabaseVault = try databaseSecretStore.loadVault()
runner.check(loadedDatabaseVault == secretVault, "database secret store should persist one vault")
try? FileManager.default.removeItem(at: secretDatabaseURL.deletingLastPathComponent())

let asyncSecretSuiteName = "CodexNotchAsyncSecretLoad-\(UUID().uuidString)"
let asyncSecretDefaults = runner.require(
    UserDefaults(suiteName: asyncSecretSuiteName),
    "async secret defaults should be available"
)
asyncSecretDefaults.removePersistentDomain(forName: asyncSecretSuiteName)
var staleAsyncVault = SecretVault()
staleAsyncVault.set("old-clip-secret", for: .cliproxyManagement)
staleAsyncVault.set("old-newapi-secret", for: .balanceAccount(source: .newAPI, id: "async-account"))
let sequencedSecretStore = SequencedSecretStore(vaults: [SecretVault(), staleAsyncVault])
let asyncSettings = CodexNotchSettings(
    defaults: asyncSecretDefaults,
    secretStores: SecretStoreFactory(keychain: sequencedSecretStore, database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager(),
    loadSecretsSynchronously: false
)
runner.check(
    sequencedSecretStore.secondLoadStarted.wait(timeout: .now() + 2) == .success,
    "async secret load should start in the background"
)
asyncSettings.remoteMonitorEnabled = true
asyncSettings.cliproxyPanelURL = "https://new.example.com/management.html"
asyncSettings.cliproxyManagementKey = "new-clip-secret"
asyncSettings.setBalanceAccounts([
    BalanceAccountConfiguration(
        id: "async-account",
        source: .newAPI,
        enabled: true,
        label: "Async",
        panelURL: "https://newapi.example.com",
        username: "owner",
        secret: "new-account-secret",
        requestTimeout: 6
    )
], for: .newAPI)
sequencedSecretStore.releaseSecondLoad.signal()
_ = pumpMainRunLoop(until: Date().addingTimeInterval(1)) {
    sequencedSecretStore.loadCount >= 2
}
RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
runner.check(asyncSettings.cliproxyManagementKey == "new-clip-secret", "late async secret load should not overwrite a user-saved CLIProxyAPI key")
runner.check(
    asyncSettings.balanceAccounts(for: .newAPI).first?.secret == "new-account-secret",
    "late async secret load should not overwrite a user-saved balance account password"
)
asyncSecretDefaults.removePersistentDomain(forName: asyncSecretSuiteName)

let settings = CodexNotchSettings(
    defaults: settingsDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
settings.activeRefreshInterval = settings.activeRefreshInterval
settings.idleRefreshInterval = settings.idleRefreshInterval
settings.usageRefreshInterval = settings.usageRefreshInterval
settings.watcherRefreshInterval = settings.watcherRefreshInterval
settings.fileChangeRefreshMinimumGap = settings.fileChangeRefreshMinimumGap
settings.cliproxyRefreshInterval = settings.cliproxyRefreshInterval
settings.cliproxyRequestTimeout = settings.cliproxyRequestTimeout
runner.check(settings.activeRefreshInterval == 3, "saving unchanged refresh intervals should not recurse or change values")
settings.usageRefreshInterval = 900
runner.check(settings.usageRefreshInterval == 900, "low-power usage refresh intervals above five minutes should persist")

runner.check(settings.remoteCodexDataSource == .cpaManagerPlus, "remote Codex monitor should default to CPA Manager Plus data")
runner.check(settings.notchDisplaySource == .codex, "collapsed notch display should default to local Codex")
settings.remoteCodexDataSource = .cliProxyAPI
settings.notchDisplaySource = .remoteCodex
settings.notchWidthAdjustment = 8
settings.newAPIMonitorEnabled = true
settings.newAPIPanelURL = "https://newapi.example.com"
settings.newAPIUsername = "owner"
settings.newAPIRefreshInterval = 180
settings.subAPIMonitorEnabled = true
settings.subAPIPanelURL = "https://subapi.example.com"
settings.subAPIUsername = "user@example.com"
settings.subAPIRefreshInterval = 240
let reloadedSettings = CodexNotchSettings(
    defaults: settingsDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(reloadedSettings.remoteCodexDataSource == .cliProxyAPI, "remote Codex data source should persist")
runner.check(reloadedSettings.notchDisplaySource == .remoteCodex, "collapsed notch display source should persist")
runner.check(reloadedSettings.notchWidthAdjustment == 8, "manual notch width adjustment should persist")
reloadedSettings.notchWidthAdjustment = 200
runner.check(reloadedSettings.notchWidthAdjustment == 40, "manual notch width adjustment should clamp high values")
reloadedSettings.notchWidthAdjustment = -200
runner.check(reloadedSettings.notchWidthAdjustment == -40, "manual notch width adjustment should clamp low values")
runner.check(reloadedSettings.newAPIMonitorEnabled, "NewAPI monitor enablement should persist")
runner.check(reloadedSettings.newAPIPanelURL == "https://newapi.example.com", "NewAPI panel URL should persist")
runner.check(reloadedSettings.newAPIUsername == "owner", "NewAPI username should persist")
let migratedNewAPIAccounts = reloadedSettings.balanceAccounts(for: .newAPI)
runner.check(migratedNewAPIAccounts.count == 1, "legacy NewAPI settings should migrate to one balance account")
runner.check(migratedNewAPIAccounts.first?.panelURL == "https://newapi.example.com", "migrated NewAPI account should preserve panel URL")
runner.check(migratedNewAPIAccounts.first?.username == "owner", "migrated NewAPI account should preserve username")
runner.check(migratedNewAPIAccounts.first?.usesDefaultThresholds == true, "migrated NewAPI account should use default thresholds")
runner.check(reloadedSettings.subAPIMonitorEnabled, "SubAPI monitor enablement should persist")
runner.check(reloadedSettings.subAPIPanelURL == "https://subapi.example.com", "SubAPI panel URL should persist")
runner.check(reloadedSettings.subAPIUsername == "user@example.com", "SubAPI login name should persist")
let migratedSubAPIAccounts = reloadedSettings.balanceAccounts(for: .subAPI)
runner.check(migratedSubAPIAccounts.count == 1, "legacy Sub2API settings should migrate to one balance account")
runner.check(migratedSubAPIAccounts.first?.panelURL == "https://subapi.example.com", "migrated Sub2API account should preserve panel URL")
runner.check(migratedSubAPIAccounts.first?.username == "user@example.com", "migrated Sub2API account should preserve login name")
reloadedSettings.setBalanceAccounts([], for: .newAPI)
let emptiedSettings = CodexNotchSettings(
    defaults: settingsDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(emptiedSettings.balanceAccounts(for: .newAPI).isEmpty, "explicitly saved empty NewAPI account list should not revive legacy settings")
settingsDefaults.removePersistentDomain(forName: settingsSuiteName)

let databaseModeSuiteName = "CodexNotchDatabaseSecretMode-\(UUID().uuidString)"
let databaseModeDefaults = runner.require(
    UserDefaults(suiteName: databaseModeSuiteName),
    "database secret mode defaults should be available"
)
databaseModeDefaults.removePersistentDomain(forName: databaseModeSuiteName)
let keychainStoreForDatabaseMode = MemorySecretStore()
let databaseStoreForDatabaseMode = MemorySecretStore()
let databaseModeSettings = CodexNotchSettings(
    defaults: databaseModeDefaults,
    initialManagementKey: "clip-secret",
    initialNewAPIKey: "newapi-secret",
    initialSubAPIKey: "subapi-secret",
    secretStores: SecretStoreFactory(keychain: keychainStoreForDatabaseMode, database: databaseStoreForDatabaseMode),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
databaseModeSettings.setSecretStorageMode(.database)
databaseModeSettings.setBalanceAccounts([
    BalanceAccountConfiguration(
        id: "db-account",
        source: .newAPI,
        enabled: true,
        label: "DB Account",
        panelURL: "https://newapi.example.com",
        username: "owner",
        secret: "db-account-secret",
        requestTimeout: 6
    )
], for: .newAPI)
let reloadedDatabaseModeSettings = CodexNotchSettings(
    defaults: databaseModeDefaults,
    secretStores: SecretStoreFactory(keychain: keychainStoreForDatabaseMode, database: databaseStoreForDatabaseMode),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(reloadedDatabaseModeSettings.secretStorageMode == .database, "secret storage mode should persist")
runner.check(reloadedDatabaseModeSettings.cliproxyManagementKey == "clip-secret", "database mode should reload CLIProxyAPI key")
runner.check(reloadedDatabaseModeSettings.newAPIManagementKey == "newapi-secret", "database mode should reload NewAPI key")
runner.check(reloadedDatabaseModeSettings.subAPIManagementKey == "subapi-secret", "database mode should reload Sub2API key")
runner.check(
    reloadedDatabaseModeSettings.balanceAccounts(for: .newAPI).first?.secret == "db-account-secret",
    "database mode should reload account secret"
)
databaseModeDefaults.removePersistentDomain(forName: databaseModeSuiteName)

let oldBalanceAccount = BalanceAccountConfiguration(
    id: "account-1",
    source: .newAPI,
    panelURL: "https://old.example.com",
    username: "owner",
    secret: "same-password",
    allowInsecureTLS: false
)
var changedOriginAccount = oldBalanceAccount
changedOriginAccount.panelURL = "https://new.example.com"
let sanitizedChangedOrigin = CodexNotchSettings.sanitizedBalanceAccountForSave(
    changedOriginAccount,
    oldAccount: oldBalanceAccount
)
runner.check(sanitizedChangedOrigin.secret.isEmpty, "changing a balance account origin should clear an unchanged password")
var changedTLSAccount = oldBalanceAccount
changedTLSAccount.allowInsecureTLS = true
let sanitizedChangedTLS = CodexNotchSettings.sanitizedBalanceAccountForSave(
    changedTLSAccount,
    oldAccount: oldBalanceAccount
)
runner.check(sanitizedChangedTLS.secret.isEmpty, "changing a balance account TLS mode should clear an unchanged password")
var retypedChangedOrigin = changedOriginAccount
retypedChangedOrigin.secret = "retyped-password"
let sanitizedRetypedOrigin = CodexNotchSettings.sanitizedBalanceAccountForSave(
    retypedChangedOrigin,
    oldAccount: oldBalanceAccount
)
runner.check(sanitizedRetypedOrigin.secret == "retyped-password", "retyped password should be kept after origin change")

let shellTimeoutStart = Date()
do {
    _ = try Shell.run("/bin/sh", ["-c", "sleep 2"], timeout: 0.2)
    runner.check(false, "shell timeout should stop a stuck command")
} catch {
    runner.check(Date().timeIntervalSince(shellTimeoutStart) < 3.0, "shell timeout should return promptly")
}

let resistantShellTimeoutStart = Date()
do {
    _ = try Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
    runner.check(false, "shell timeout should stop a SIGTERM-resistant command")
} catch {
    runner.check(Date().timeIntervalSince(resistantShellTimeoutStart) < 3.0, "shell timeout should not wait indefinitely after SIGTERM fails")
}

runner.check(CLIProxyAPIClient.managementBaseURL(from: "http://example.com:8317/management.html") == nil, "external plain HTTP panel URL must be rejected")
runner.check(CLIProxyAPIClient.managementBaseURL(from: "https://panel.example.com@evil.example.com/management.html") == nil, "CLIProxyAPI panel URL must reject userinfo")

let newAPIBaseURL = runner.require(
    BalanceAPIClient.apiBaseURL(from: "https://newapi.example.com/admin"),
    "NewAPI-compatible panel URL should normalize"
)
runner.check(newAPIBaseURL.absoluteString == "https://newapi.example.com", "NewAPI-compatible base URL should use the origin")
runner.check(BalanceAPIClient.apiBaseURL(from: "https://newapi.example.com@evil.example.com/admin") == nil, "NewAPI-compatible panel URL must reject userinfo")

let newAPILoginBody = try BalanceAPIClient.newAPILoginBody(
    for: BalanceAPIConfiguration(
        panelURL: "https://newapi.example.com",
        username: "owner",
        secret: "newapi-password",
        timeout: 6,
        allowInsecureTLS: false
    )
)
let newAPILoginJSON = runner.require(
    try? JSONSerialization.jsonObject(with: newAPILoginBody) as? [String: String],
    "NewAPI login body should be JSON"
)
runner.check(newAPILoginJSON["username"] == "owner", "NewAPI login should send username")
runner.check(newAPILoginJSON["password"] == "newapi-password", "NewAPI login should send password")

let newAPILoginResponse = """
{
  "success": true,
  "message": "",
  "data": {
    "id": 42,
    "username": "owner",
    "require_2fa": false
  }
}
""".data(using: .utf8)!
let newAPIUserID = try BalanceAPIClient.validateNewAPILoginResponse(newAPILoginResponse)
runner.check(newAPIUserID == "42", "NewAPI login should return the user id required by management endpoints")
let newAPIManagementHeaders = BalanceAPIClient.newAPIManagementHeaders(userID: newAPIUserID)
runner.check(newAPIManagementHeaders["New-Api-User"] == "42", "NewAPI management requests should include the logged-in user id")
runner.check(newAPIManagementHeaders["Accept"] == "application/json", "NewAPI management requests should accept JSON")

let defaultThresholds = BalanceThresholdConfiguration(warningThreshold: 100, alertThreshold: 30)
runner.check(defaultThresholds.state(for: 150) == .healthy, "balance above warning threshold should be healthy")
runner.check(defaultThresholds.state(for: 99.99) == .warning, "balance below warning threshold should warn")
runner.check(defaultThresholds.state(for: 29.99) == .error, "balance below alert threshold should be an error")
runner.check(defaultThresholds.normalized.alertThreshold == 30, "already ordered thresholds should stay unchanged")
let swappedThresholds = BalanceThresholdConfiguration(warningThreshold: 25, alertThreshold: 50).normalized
runner.check(swappedThresholds.warningThreshold == 50, "normalized thresholds should keep warning at the larger value")
runner.check(swappedThresholds.alertThreshold == 25, "normalized thresholds should keep alert at the smaller value")
runner.check(defaultThresholds.hasValidOrder, "warning threshold above alert threshold should be valid")
runner.check(
    !BalanceThresholdConfiguration(warningThreshold: 25, alertThreshold: 50).hasValidOrder,
    "warning threshold below alert threshold should be invalid for editing"
)
runner.check(
    !BalanceThresholdConfiguration(warningThreshold: 50, alertThreshold: 50).hasValidOrder,
    "warning threshold equal to alert threshold should be invalid for editing"
)
runner.check(BalanceThresholdConfiguration().summaryText == "不提醒", "empty threshold summary should be explicit")
runner.check(defaultThresholds.summaryText == "提醒 100.00 · 告警 30.00", "threshold summary should show warning and alert values")
let defaultThresholdAccount = BalanceAccountConfiguration(
    source: .newAPI,
    username: "owner",
    usesDefaultThresholds: true
)
runner.check(
    defaultThresholdAccount.thresholdSummary(defaults: defaultThresholds) == "默认：提醒 100.00 · 告警 30.00",
    "default threshold account summary should reference default thresholds"
)
let customThresholdAccount = BalanceAccountConfiguration(
    source: .newAPI,
    username: "owner",
    usesDefaultThresholds: false,
    warningThreshold: 20,
    alertThreshold: 5
)
runner.check(
    customThresholdAccount.thresholdSummary(defaults: defaultThresholds) == "自定义：提醒 20.00 · 告警 5.00",
    "custom threshold account summary should show account thresholds"
)
let invalidCustomThresholdAccount = BalanceAccountConfiguration(
    source: .newAPI,
    username: "owner",
    usesDefaultThresholds: false,
    warningThreshold: 5,
    alertThreshold: 20
)
runner.check(
    !invalidCustomThresholdAccount.hasValidThresholdOrder,
    "custom account thresholds should require warning threshold above alert threshold"
)
let defaultThresholdAccountWithStaleInvalidCustomValues = BalanceAccountConfiguration(
    source: .newAPI,
    username: "owner",
    usesDefaultThresholds: true,
    warningThreshold: 5,
    alertThreshold: 20
)
runner.check(
    defaultThresholdAccountWithStaleInvalidCustomValues.hasValidThresholdOrder,
    "default-threshold accounts should ignore stale custom threshold ordering"
)

let newAPI2FAResponse = """
{
  "success": true,
  "message": "需要二次验证",
  "data": {
    "require_2fa": true
  }
}
""".data(using: .utf8)!
do {
    try BalanceAPIClient.validateNewAPILoginResponse(newAPI2FAResponse)
    runner.check(false, "NewAPI login should report unsupported two-factor login")
} catch {
    runner.check(error.localizedDescription.contains("二次验证"), "NewAPI 2FA login should show a clear message")
}

let subAPILoginBody = try BalanceAPIClient.subAPILoginBody(
    for: BalanceAPIConfiguration(
        panelURL: "https://subapi.example.com",
        username: "user@example.com",
        secret: "subapi-password",
        timeout: 6,
        allowInsecureTLS: false
    )
)
let subAPILoginJSON = runner.require(
    try? JSONSerialization.jsonObject(with: subAPILoginBody) as? [String: String],
    "Sub2API login body should be JSON"
)
runner.check(subAPILoginJSON["email"] == "user@example.com", "Sub2API login should send the login name as email")
runner.check(subAPILoginJSON["password"] == "subapi-password", "Sub2API login should send password")
do {
    _ = try BalanceAPIClient.subAPILoginBody(
        for: BalanceAPIConfiguration(
            panelURL: "https://subapi.example.com",
            username: "test",
            secret: "subapi-password",
            timeout: 6,
            allowInsecureTLS: false
        )
    )
    runner.check(false, "Sub2API login should reject non-email login names before sending a request")
} catch {
    runner.check(error.localizedDescription.contains("邮箱"), "Sub2API non-email login names should show a clear email error")
}

let subAPILoginResponse = """
{
  "code": 0,
  "message": "success",
  "data": {
    "access_token": "subapi-access-token",
    "token_type": "Bearer",
    "user": {
      "id": 101,
      "email": "user@example.com",
      "username": "user",
      "role": "user",
      "balance": 12.5,
      "concurrency": 3,
      "status": "active"
    }
  }
}
""".data(using: .utf8)!
let subAPIToken = try BalanceAPIClient.validateSubAPILoginResponse(subAPILoginResponse)
runner.check(subAPIToken == "subapi-access-token", "Sub2API login should return an access token")
let subAPIUserHeaders = BalanceAPIClient.bearerHeaders(token: subAPIToken)
runner.check(subAPIUserHeaders["Authorization"] == "Bearer subapi-access-token", "Sub2API user requests should use bearer token auth")
let subAPIHTTP400 = """
{
  "code": 400,
  "message": "Invalid request: Key: 'LoginRequest.Email' Error:Field validation for 'Email' failed on the 'email' tag"
}
""".data(using: .utf8)!
runner.check(
    BalanceAPIClient.httpFailureMessage(statusCode: 400, data: subAPIHTTP400).contains("邮箱格式不正确"),
    "Sub2API HTTP 400 validation payload should become an actionable email-format message"
)
runner.check(SettingsShortcutFilter.shouldSuppressTextInputKey(
    characters: "⌃⌥⌘V",
    hasCommand: true,
    hasControl: true,
    hasOption: true,
    hasShift: false
), "non-standard command shortcuts should not be inserted into settings text fields")
runner.check(!SettingsShortcutFilter.shouldSuppressTextInputKey(
    characters: "v",
    hasCommand: true,
    hasControl: false,
    hasOption: false,
    hasShift: false
), "standard paste shortcut should still reach the text field")
runner.check(!SettingsShortcutFilter.shouldSuppressTextInputKey(
    characters: "a",
    hasCommand: false,
    hasControl: false,
    hasOption: false,
    hasShift: false
), "plain text input should not be suppressed")

let newAPIUserPayload = """
{
  "success": true,
  "message": "",
  "data": {
    "username": "owner",
    "display_name": "Owner",
    "quota": 73454877,
    "used_quota": 0,
    "request_count": 42,
    "status": 1
  }
}
""".data(using: .utf8)!
let newAPIStatusPayload = """
{
  "success": true,
  "message": "",
  "data": {
    "quota_per_unit": 500000,
    "quota_display_type": "CNY",
    "usd_exchange_rate": 6.8069
  }
}
""".data(using: .utf8)!
let newAPIQuotaDisplay = try BalanceAPIClient.decodeNewAPIQuotaDisplay(newAPIStatusPayload)
let userBalanceAccount = try BalanceAPIClient.decodeUserAccount(
    newAPIUserPayload,
    source: .newAPI,
    quotaDisplay: newAPIQuotaDisplay
)
runner.check(userBalanceAccount.displayName == "Owner", "NewAPI self account should prefer display_name")
runner.check(userBalanceAccount.amountText == "¥1000.00", "NewAPI self account quota should display the same CNY balance as the console")
runner.check(userBalanceAccount.detailText.contains("已用 ¥0.00"), "NewAPI used quota should display as currency usage")
runner.check(userBalanceAccount.detailText.contains("请求 42"), "NewAPI self account should include request count")
let warningThresholdBalanceAccount = try BalanceAPIClient.decodeUserAccount(
    newAPIUserPayload,
    source: .newAPI,
    quotaDisplay: newAPIQuotaDisplay,
    thresholds: BalanceThresholdConfiguration(warningThreshold: 1200, alertThreshold: 500)
)
runner.check(warningThresholdBalanceAccount.state == .warning, "NewAPI balance below reminder threshold should become warning")
runner.check(warningThresholdBalanceAccount.stateText == "余额低于提醒阈值", "NewAPI warning status should explain the balance threshold reason")

let newAPIChannelPayload = """
{
  "success": true,
  "message": "",
  "data": {
    "items": [
      {
        "id": 11,
        "name": "OpenAI Primary",
        "status": 1,
        "balance": 12.3456,
        "used_quota": 987654
      },
      {
        "id": 12,
        "name": "Disabled Channel",
        "status": 2,
        "balance": "0.5",
        "used_quota": "123"
      }
    ],
    "total": 2
  }
}
""".data(using: .utf8)!
let channelBalanceAccounts = try BalanceAPIClient.decodeChannelAccounts(
    newAPIChannelPayload,
    source: .newAPI
)
runner.check(channelBalanceAccounts.count == 2, "NewAPI channel list should decode channel balances")
runner.check(channelBalanceAccounts[0].amountText == "$12.35", "NewAPI channel balance should format to dollars")
runner.check(channelBalanceAccounts[1].state == .warning, "disabled NewAPI channel should become a warning balance account")

let sameCurrencySnapshot = BalanceMonitorSnapshot(
    source: .newAPI,
    panelState: .healthy,
    accounts: [
        BalanceAccount(
            id: "cny-1",
            source: .newAPI,
            name: "CNY 1",
            kind: "用户额度",
            statusCode: nil,
            amountText: "¥100.00",
            usedText: nil,
            requestCount: nil,
            updatedAt: nil,
            state: .healthy,
            balanceAmount: 100,
            balanceUnitKey: "CNY",
            balanceUnitSymbol: "¥"
        ),
        BalanceAccount(
            id: "cny-2",
            source: .newAPI,
            name: "CNY 2",
            kind: "用户额度",
            statusCode: nil,
            amountText: "¥30.50",
            usedText: nil,
            requestCount: nil,
            updatedAt: nil,
            state: .healthy,
            balanceAmount: 30.5,
            balanceUnitKey: "CNY",
            balanceUnitSymbol: "¥"
        )
    ],
    message: nil,
    lastUpdated: nil
)
runner.check(sameCurrencySnapshot.totalAmountText == "¥130.50", "same-currency balances should be summed")
let mixedCurrencySnapshot = BalanceMonitorSnapshot(
    source: .newAPI,
    panelState: .healthy,
    accounts: [
        BalanceAccount(
            id: "cny",
            source: .newAPI,
            name: "CNY",
            kind: "用户额度",
            statusCode: nil,
            amountText: "¥100.00",
            usedText: nil,
            requestCount: nil,
            updatedAt: nil,
            state: .healthy,
            balanceAmount: 100,
            balanceUnitKey: "CNY",
            balanceUnitSymbol: "¥"
        ),
        BalanceAccount(
            id: "usd",
            source: .newAPI,
            name: "USD",
            kind: "用户额度",
            statusCode: nil,
            amountText: "$10.00",
            usedText: nil,
            requestCount: nil,
            updatedAt: nil,
            state: .healthy,
            balanceAmount: 10,
            balanceUnitKey: "USD",
            balanceUnitSymbol: "$"
        )
    ],
    message: nil,
    lastUpdated: nil
)
runner.check(mixedCurrencySnapshot.totalAmountText == "¥100.00 + $10.00", "two-currency totals should be grouped instead of converted")

let subAPIProfilePayload = """
{
  "code": 0,
  "message": "success",
  "data": {
    "id": 101,
    "email": "active@example.com",
    "username": "active",
    "role": "user",
    "balance": 12.5,
    "concurrency": 3,
    "status": "active"
  }
}
""".data(using: .utf8)!
let subAPIProfileAccount = try BalanceAPIClient.decodeSubAPIProfileAccount(subAPIProfilePayload)
runner.check(subAPIProfileAccount.displayName == "active@example.com", "Sub2API profile balance should prefer email")
runner.check(subAPIProfileAccount.amountText == "$12.50", "Sub2API profile balance should format as currency")
runner.check(subAPIProfileAccount.detailText.contains("并发 3"), "Sub2API profile should include concurrency")
let subAPISensitiveStatusPayload = """
{
  "code": 0,
  "message": "success",
  "data": {
    "id": 102,
    "email": "sensitive@example.com",
    "role": "user",
    "balance": 8,
    "status": "Bearer sk-sensitive-token"
  }
}
""".data(using: .utf8)!
let subAPISensitiveStatusAccount = try BalanceAPIClient.decodeSubAPIProfileAccount(subAPISensitiveStatusPayload)
runner.check(subAPISensitiveStatusAccount.state == .warning, "Sub2API unknown status should still mark the account as warning")
runner.check(subAPISensitiveStatusAccount.stateText == "状态异常", "Sub2API status reason should not display remote status values verbatim")
runner.check(!subAPISensitiveStatusAccount.detailText.lowercased().contains("sk-"), "Sub2API detail text should redact token-like status values")
let alertThresholdSubAPIProfileAccount = try BalanceAPIClient.decodeSubAPIProfileAccount(
    subAPIProfilePayload,
    thresholds: BalanceThresholdConfiguration(warningThreshold: 20, alertThreshold: 15)
)
runner.check(alertThresholdSubAPIProfileAccount.state == .error, "Sub2API balance below alert threshold should become error")
runner.check(alertThresholdSubAPIProfileAccount.stateText == "余额低于告警阈值", "Sub2API error status should explain the balance threshold reason")

let subAPIPlatformQuotaPayload = """
{
  "code": 0,
  "message": "success",
  "data": {
    "platform_quotas": [
      {
        "platform": "openai",
        "daily_usage_usd": 1.5,
        "daily_limit_usd": 5,
        "weekly_usage_usd": 4,
        "weekly_limit_usd": 20,
        "monthly_usage_usd": 8,
        "monthly_limit_usd": 30
      }
    ]
  }
}
""".data(using: .utf8)!
let subAPIQuotaAccounts = try BalanceAPIClient.decodeSubAPIPlatformQuotaAccounts(subAPIPlatformQuotaPayload)
runner.check(subAPIQuotaAccounts.count == 1, "Sub2API platform quota list should decode")
runner.check(subAPIQuotaAccounts[0].displayName == "openai", "Sub2API platform quota should use platform name")
runner.check(subAPIQuotaAccounts[0].amountText == "$3.50", "Sub2API platform quota should display the most constrained remaining quota")
let subAPIQuotaAccountsForA = try BalanceAPIClient.decodeSubAPIPlatformQuotaAccounts(
    subAPIPlatformQuotaPayload,
    accountID: "account-a",
    accountLabel: "A"
)
let subAPIQuotaAccountsForB = try BalanceAPIClient.decodeSubAPIPlatformQuotaAccounts(
    subAPIPlatformQuotaPayload,
    accountID: "account-b",
    accountLabel: "B"
)
runner.check(subAPIQuotaAccountsForA[0].id != subAPIQuotaAccountsForB[0].id, "Sub2API platform quota row ids should include the parent account id")
runner.check(subAPIQuotaAccountsForA[0].displayName == "A · openai", "Sub2API platform quota display name should include account label when available")

let failedBalanceEnvelope = """
{
  "success": false,
  "message": "authorization Bearer sk-sensitive-token should not be displayed"
}
""".data(using: .utf8)!
do {
    _ = try BalanceAPIClient.decodeUserAccount(failedBalanceEnvelope, source: .newAPI)
    runner.check(false, "failed NewAPI envelope should throw")
} catch {
    runner.check(!error.localizedDescription.lowercased().contains("sk-sensitive"), "NewAPI-compatible error messages should redact token-like secrets")
}
let redactedJSONError = DisplayRedactor.redact(#"{"password":"secret-password","access_token":"sensitive-access-token","message":"bad"}"#)
runner.check(!redactedJSONError.contains("secret-password"), "redaction should hide JSON password values")
runner.check(!redactedJSONError.contains("sensitive-access-token"), "redaction should hide JSON access tokens")

let localURL = runner.require(
    CLIProxyAPIClient.managementBaseURL(from: "http://127.0.0.1:8317/management.html"),
    "localhost plain HTTP panel URL should be accepted"
)
runner.check(localURL.absoluteString == "http://127.0.0.1:8317/v0/management", "localhost HTTP URL should normalize to management API base")

let previous = RemoteCodexAccount(
    id: "1",
    name: "previous",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "team",
    quotaWindows: [
        RemoteQuotaWindow(
            id: "code-primary",
            shortLabel: "5h",
            remainingPercent: 88,
            usedPercent: 12,
            resetText: nil
        )
    ],
    quotaError: nil
)

let current = RemoteCodexAccount(
    id: "1",
    name: "current",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "team",
    quotaWindows: [],
    quotaError: "HTTP 401"
)

let preserved = current.preservingFailedQuota(from: previous)
runner.check(preserved.state == .abnormal, "authentication quota failure should mark the account abnormal")
runner.check(preserved.quotaError == "HTTP 401", "preserved quota should keep the current error")
runner.check(preserved.stateReasonText == "登录已过期", "authentication quota failure should explain login expiry")

let timeoutQuotaFailure = RemoteCodexAccount(
    id: "1",
    name: "current timeout",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "team",
    quotaWindows: [],
    quotaError: "额度查询超时"
)
let timeoutPreserved = timeoutQuotaFailure.preservingFailedQuota(from: previous)
runner.check(timeoutPreserved.state == .healthy, "non-auth quota refresh failure should preserve the account state when old quota is available")
runner.check(timeoutPreserved.quotaSummaryText == "5h 88%", "preserved quota should keep displaying the old quota numbers")

let previousQuotaFailure = RemoteCodexAccount(
    id: "1",
    name: "previous failure",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "team",
    quotaWindows: [],
    quotaError: "额度查询超时"
)
let statusOnlyAccount = RemoteCodexAccount(
    id: "1",
    name: "status only",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "team",
    quotaWindows: [],
    quotaError: nil
)
let statusOnlyPreserved = statusOnlyAccount.preservingQuota(from: previousQuotaFailure)
runner.check(statusOnlyPreserved.quotaError == nil, "status-only refresh should not preserve stale quota errors without quota windows")

let unavailableDueToQuota = RemoteCodexAccount(
    id: "quota-unavailable",
    name: "quota unavailable",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "error",
    statusMessage: #"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached"}}"#,
    successCount: 419,
    failureCount: 7,
    recentFailures: 0,
    state: .abnormal,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [
        RemoteQuotaWindow(
            id: "code-primary",
            shortLabel: "5h",
            remainingPercent: 0,
            usedPercent: 100,
            resetText: "6-14 19:43"
        ),
        RemoteQuotaWindow(
            id: "code-secondary",
            shortLabel: "7d",
            remainingPercent: 56,
            usedPercent: 44,
            resetText: nil
        )
    ],
    quotaError: nil,
    unavailable: true
).withQuotaExhaustion
runner.check(unavailableDueToQuota.state == .quotaExhausted, "unavailable account with exhausted quota should be classified as quota exhausted")
runner.check(unavailableDueToQuota.stateReasonText == "5小时额度已满", "exhausted 5h quota should explain that the 5h quota is full")

let staleQuotaMarkerAccount = RemoteCodexAccount(
    id: "stale-quota-marker",
    name: "stale quota marker",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "error",
    statusMessage: #"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached"}}"#,
    successCount: 633,
    failureCount: 12,
    recentFailures: 0,
    state: .quotaExhausted,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [],
    quotaError: nil,
    unavailable: true
)
let freshAvailableQuotaWindows = [
    RemoteQuotaWindow(
        id: "code-primary",
        shortLabel: "5h",
        remainingPercent: 99,
        usedPercent: 1,
        resetText: nil
    ),
    RemoteQuotaWindow(
        id: "code-secondary",
        shortLabel: "7d",
        remainingPercent: 40,
        usedPercent: 60,
        resetText: nil
    )
]
runner.check(
    staleQuotaMarkerAccount.stateAfterMergingFreshQuota(
        windows: freshAvailableQuotaWindows,
        error: nil
    ) == .healthy,
    "fresh available quota should clear stale quota-exhausted status markers"
)
let previousAvailableQuotaAccount = remoteAccount(
    id: "stale-quota-marker",
    state: .healthy,
    quotaWindows: freshAvailableQuotaWindows
)
let preservedAvailableQuotaAccount = staleQuotaMarkerAccount.preservingQuota(
    from: previousAvailableQuotaAccount
)
runner.check(
    preservedAvailableQuotaAccount.state == .healthy,
    "status-only refresh should clear stale quota-exhausted status when preserving available quota"
)
runner.check(
    preservedAvailableQuotaAccount.stateReasonText == "正常",
    "status-only refresh with preserved available quota should display a healthy reason"
)

let poolWithOneShortQuota = [
    remoteAccount(id: "quota-1", state: .quotaExhausted, quotaWindows: [exhaustedFiveHourWindow]),
    remoteAccount(id: "healthy-1", state: .healthy),
    remoteAccount(id: "healthy-2", state: .healthy)
]
runner.check(RemoteMonitorSnapshot.poolAlertSeverity(for: poolWithOneShortQuota) == .none, "single 5h exhausted account should not alert when the remote pool has healthy accounts")

let poolWithThinCapacity = [
    remoteAccount(id: "quota-1", state: .quotaExhausted, quotaWindows: [exhaustedFiveHourWindow]),
    remoteAccount(id: "quota-2", state: .quotaExhausted, quotaWindows: [exhaustedFiveHourWindow]),
    remoteAccount(id: "healthy-1", state: .healthy)
]
runner.check(RemoteMonitorSnapshot.poolAlertSeverity(for: poolWithThinCapacity) == .warning, "remote pool should warn when only one account remains available")

let poolWithAbnormalAccount = [
    remoteAccount(id: "abnormal-1", state: .abnormal),
    remoteAccount(id: "healthy-1", state: .healthy)
]
runner.check(RemoteMonitorSnapshot.poolAlertSeverity(for: poolWithAbnormalAccount) == .error, "non-quota account abnormality should still alert as error")

let poolWithOneWeeklyQuota = [
    remoteAccount(id: "quota-1", state: .quotaExhausted, quotaWindows: [exhaustedWeeklyWindow]),
    remoteAccount(id: "healthy-1", state: .healthy)
]
runner.check(RemoteMonitorSnapshot.poolAlertSeverity(for: poolWithOneWeeklyQuota) == .warning, "long-term quota exhaustion should warn when the remote pool has limited reserve")

let poolWithMissingInspectionQuota = [
    remoteAccount(id: "quota-error-1", state: .healthy, quotaError: "巡检额度缺失"),
    remoteAccount(id: "quota-error-2", state: .healthy, quotaError: "巡检额度缺失")
]
runner.check(RemoteMonitorSnapshot.poolAlertSeverity(for: poolWithMissingInspectionQuota) == .warning, "missing quota data for the whole remote pool should warn")

let bothQuotasExhausted = RemoteCodexAccount(
    id: "both-quotas",
    name: "both quotas",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "error",
    statusMessage: #"{"error":{"type":"usage_limit_reached"}}"#,
    successCount: 10,
    failureCount: 1,
    recentFailures: 0,
    state: .abnormal,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [
        RemoteQuotaWindow(
            id: "code-primary",
            shortLabel: "5h",
            remainingPercent: 0,
            usedPercent: 100,
            resetText: nil
        ),
        RemoteQuotaWindow(
            id: "code-secondary",
            shortLabel: "7d",
            remainingPercent: 0,
            usedPercent: 100,
            resetText: nil
        )
    ],
    quotaError: nil,
    unavailable: true
).withQuotaExhaustion
runner.check(bothQuotasExhausted.stateReasonText == "5小时额度已满", "5h quota should be preferred when both 5h and weekly quota are exhausted")

let whamPayload = """
{
  "plan_type": "team",
  "rate_limits": {
    "primary": {
      "used_percent": 65,
      "window_minutes": 300
    },
    "secondary": {
      "used_percent": "12",
      "window_minutes": 10080
    }
  }
}
""".data(using: .utf8)!
let whamQuota = try CLIProxyAPIClient.decodeQuotaBody(whamPayload, fallbackPlanType: nil)
runner.check(whamQuota.planType == "team", "quota payload should preserve plan type")
runner.check(whamQuota.windows.count == 2, "rate_limits primary and secondary windows should decode")
runner.check(whamQuota.windows.first?.shortLabel == "5h", "window_minutes 300 should label as 5h")
runner.check(whamQuota.windows.first?.remainingPercent == 35, "remaining percent should be derived from used_percent")
runner.check(whamQuota.windows.last?.shortLabel == "7d", "window_minutes 10080 should label as 7d")
runner.check(whamQuota.windows.last?.remainingPercent == 88, "string used_percent should decode")

let reachedPayload = """
{
  "rate_limit": {
    "allowed": false,
    "limit_reached": true,
    "primary_window": {
      "limit_window_seconds": 18000
    }
  }
}
""".data(using: .utf8)!
let reachedQuota = try CLIProxyAPIClient.decodeQuotaBody(reachedPayload, fallbackPlanType: nil)
runner.check(reachedQuota.windows.first?.reachesThreshold == true, "limit_reached or allowed=false should mark quota threshold reached when the window lacks percent data")

let weeklyReachedPayload = """
{
  "rate_limit": {
    "allowed": false,
    "limit_reached": true,
    "primary_window": {
      "used_percent": 31,
      "limit_window_seconds": 18000
    },
    "secondary_window": {
      "used_percent": 100,
      "limit_window_seconds": 604800
    }
  }
}
""".data(using: .utf8)!
let weeklyReachedQuota = try CLIProxyAPIClient.decodeQuotaBody(weeklyReachedPayload, fallbackPlanType: nil)
runner.check(weeklyReachedQuota.windows.count == 2, "weekly reached payload should decode both quota windows")
runner.check(weeklyReachedQuota.windows[0].reachesThreshold == false, "global limit marker should not mark 5h reached when 5h still has quota")
runner.check(weeklyReachedQuota.windows[1].reachesThreshold == true, "weekly window with 0 remaining quota should be reached")
let weeklyReachedAccount = remoteAccount(
    id: "weekly-reached",
    state: .healthy,
    quotaWindows: weeklyReachedQuota.windows
).withQuotaExhaustion
runner.check(weeklyReachedAccount.stateReasonText == "周额度已满", "weekly quota exhaustion should not be reported as 5h exhaustion")

let codexInspectionAuthFilesPayload = """
{
  "files": [
    {
      "provider": "codex",
      "type": "codex",
      "name": "codex-healthy-pro.json",
      "email": "healthy@example.com",
      "auth_index": "auth-healthy",
      "success": 6,
      "failed": 1,
      "id_token": {
        "plan_type": "pro"
      }
    },
    {
      "provider": "codex",
      "type": "codex",
      "name": "codex-limited-plus.json",
      "email": "limited@example.com",
      "auth_index": "auth-limited",
      "success": 2,
      "failed": 0,
      "id_token": {
        "plan_type": "plus"
      }
    },
    {
      "provider": "codex",
      "type": "codex",
      "name": "codex-disabled-plus.json",
      "email": "disabled@example.com",
      "auth_index": "auth-disabled",
      "disabled": true,
      "id_token": {
        "plan_type": "plus"
      }
    }
  ]
}
""".data(using: .utf8)!
let codexInspectionRunPayload = """
{
  "run": {
    "id": 263,
    "status": "completed",
    "finishedAtMs": 1781693102243
  },
  "results": [
    {
      "fileName": "codex-healthy-pro.json",
      "displayAccount": "healthy@example.com",
      "authIndex": "auth-healthy",
      "provider": "codex",
      "disabled": false,
      "status": "error",
      "action": "keep",
      "actionReason": "周额度仍可用，无需处理",
      "statusCode": 200,
      "usedPercent": 67,
      "quotaWindows": [
        {
          "id": "five-hour",
          "labelKey": "codex_quota.primary_window",
          "usedPercent": 1,
          "resetLabel": "06/20 11:30",
          "limitWindowSeconds": 18000
        },
        {
          "id": "weekly",
          "labelKey": "codex_quota.secondary_window",
          "usedPercent": 67,
          "resetLabel": "06/24 21:36",
          "limitWindowSeconds": 604800
        }
      ],
      "isQuota": false,
      "createdAtMs": 1781693102234
    },
    {
      "fileName": "codex-limited-plus.json",
      "displayAccount": "limited@example.com",
      "authIndex": "auth-limited",
      "provider": "codex",
      "disabled": false,
      "status": "error",
      "action": "keep",
      "actionReason": "周额度达到阈值，保留待恢复",
      "statusCode": 200,
      "usedPercent": 100,
      "quotaWindows": [
        {
          "id": "five-hour",
          "labelKey": "codex_quota.primary_window",
          "usedPercent": 69,
          "resetLabel": "06/20 11:30",
          "limitWindowSeconds": 18000
        },
        {
          "id": "weekly",
          "labelKey": "codex_quota.secondary_window",
          "usedPercent": 100,
          "resetLabel": "06/24 21:36",
          "limitWindowSeconds": 604800
        }
      ],
      "isQuota": true,
      "createdAtMs": 1781693102235
    },
    {
      "fileName": "codex-disabled-plus.json",
      "displayAccount": "disabled@example.com",
      "authIndex": "auth-disabled",
      "provider": "codex",
      "disabled": true,
      "status": "disabled",
      "action": "keep",
      "actionReason": "账号已禁用",
      "statusCode": 200,
      "usedPercent": 100,
      "isQuota": true,
      "createdAtMs": 1781693102236
    }
  ],
  "logs": []
}
""".data(using: .utf8)!
let inspectionAccounts = try CLIProxyAPIClient.decodeCodexInspectionAccounts(
    authFilesData: codexInspectionAuthFilesPayload,
    inspectionRunData: codexInspectionRunPayload
)
runner.check(inspectionAccounts.count == 2, "server inspection accounts should ignore disabled Codex auth files")
let healthyInspection = runner.require(
    inspectionAccounts.first { $0.authIndex == "auth-healthy" },
    "server inspection should include the healthy account"
)
runner.check(healthyInspection.state == .healthy, "action keep with status 200 and non-quota inspection should be healthy even if raw status is error")
runner.check(healthyInspection.planLabel == "Pro 20x", "server inspection merge should preserve auth-file plan type")
runner.check(healthyInspection.quotaSummaryText == "5h 99%  7d 33%", "server inspection quota windows should display 5h and weekly remaining quota")
let limitedInspection = runner.require(
    inspectionAccounts.first { $0.authIndex == "auth-limited" },
    "server inspection should include the limited account"
)
runner.check(limitedInspection.state == .quotaExhausted, "server inspection quota flag should mark quota exhausted")
runner.check(limitedInspection.stateReasonText == "周额度已满", "server inspection weekly quota should explain the exhausted window")
runner.check(limitedInspection.quotaSummaryText == "5h 31%  7d 0%", "server inspection quota windows should display 5h and weekly remaining percent")

let hiddenModelInspectionRunPayload = """
{
  "run": {
    "id": 264,
    "status": "completed",
    "finishedAtMs": 1781693102244
  },
  "results": [
    {
      "fileName": "codex-hidden-model-pro.json",
      "displayAccount": "hidden-model@example.com",
      "authIndex": "auth-hidden-model",
      "provider": "codex",
      "disabled": false,
      "status": "error",
      "action": "keep",
      "actionReason": "账号级额度仍可用",
      "statusCode": 200,
      "quotaWindows": [
        {
          "id": "spark-five-hour",
          "labelParams": { "name": "GPT-5.3-Codex-Spark" },
          "usedPercent": 100,
          "limitWindowSeconds": 18000
        },
        {
          "id": "spark-weekly",
          "labelParams": { "name": "GPT-5.3-Codex-Spark" },
          "usedPercent": 100,
          "limitWindowSeconds": 604800
        }
      ],
      "isQuota": false,
      "createdAtMs": 1781693102237
    }
  ],
  "logs": []
}
""".data(using: .utf8)!
let hiddenModelInspectionAccounts = try CLIProxyAPIClient.decodeCodexInspectionAccounts(
    authFilesData: Data(#"{"files":[]}"#.utf8),
    inspectionRunData: hiddenModelInspectionRunPayload
)
let hiddenModelInspection = runner.require(
    hiddenModelInspectionAccounts.first,
    "server inspection should decode the hidden model account"
)
runner.check(hiddenModelInspection.state == .healthy, "hidden model quota windows should not mark a CLIProxyAPI account as quota exhausted")
runner.check(hiddenModelInspection.quotaSummaryText == "额度 --", "hidden model quota windows should not be displayed in CLIProxyAPI detail")

let currentWhamPayload = """
{
  "user_id": "user-1",
  "account_id": "user-1",
  "email": "codex@example.com",
  "plan_type": "pro",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 21,
      "limit_window_seconds": 18000,
      "reset_after_seconds": 13996,
      "reset_at": 1781390042
    },
    "secondary_window": {
      "used_percent": 38,
      "limit_window_seconds": 604800,
      "reset_after_seconds": 431880,
      "reset_at": 1781807925
    }
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    {
      "limit_name": "GPT-5.3-Codex-Spark",
      "metered_feature": "codex_bengalfox",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 100,
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "used_percent": 0,
          "limit_window_seconds": 604800
        }
      }
    }
  ]
}
""".data(using: .utf8)!
let currentWhamQuota = try CLIProxyAPIClient.decodeQuotaBody(currentWhamPayload, fallbackPlanType: nil)
runner.check(currentWhamQuota.planType == "pro", "current wham payload should preserve plan type")
runner.check(currentWhamQuota.windows.count == 4, "current wham payload should decode primary, secondary, and additional windows")
runner.check(currentWhamQuota.windows[0].remainingPercent == 79, "current wham primary remaining percent should decode")
runner.check(currentWhamQuota.windows[1].remainingPercent == 62, "current wham weekly remaining percent should decode")
let currentWhamAccount = remoteAccount(
    id: "current-wham",
    state: .healthy,
    quotaWindows: currentWhamQuota.windows
).withQuotaExhaustion
runner.check(currentWhamAccount.displayQuotaWindows.map(\.shortLabel) == ["5h", "7d"], "decoded additional model quotas should be hidden from CLIProxyAPI detail")
runner.check(currentWhamAccount.quotaSummaryText == "5h 79%  7d 62%", "decoded quota summary should only include bare 5h and 7d windows")
runner.check(currentWhamAccount.state == .healthy, "hidden decoded model quota should not mark the account as quota exhausted")

let proxyStringBodyPayload = """
{
  "status_code": 200,
  "body": "{\\"plan_type\\":\\"plus\\",\\"rate_limit\\":{\\"allowed\\":true,\\"limit_reached\\":false,\\"primary_window\\":{\\"used_percent\\":12,\\"limit_window_seconds\\":18000},\\"secondary_window\\":{\\"used_percent\\":34,\\"limit_window_seconds\\":604800}}}"
}
""".data(using: .utf8)!
let proxyStringBodyQuota = try CLIProxyAPIClient.decodeQuotaProxyResponse(proxyStringBodyPayload, fallbackPlanType: nil)
runner.check(proxyStringBodyQuota.planType == "plus", "proxy string body should preserve quota plan type")
runner.check(proxyStringBodyQuota.windows.count == 2, "proxy string body should decode quota windows")
runner.check(proxyStringBodyQuota.windows[0].remainingPercent == 88, "proxy string body should decode primary remaining percent")
runner.check(proxyStringBodyQuota.windows[1].remainingPercent == 66, "proxy string body should decode secondary remaining percent")

let resetCreditsManagementBaseURL = URL(string: "https://panel.example.com/v0/management")!
let resetCreditsRequestWithoutAccount = try CLIProxyAPIClient.resetCreditsProxyRequest(
    managementBaseURL: resetCreditsManagementBaseURL,
    managementKey: "management-secret",
    authIndex: "auth-7",
    accountID: nil,
    timeout: 8
)
runner.check(
    resetCreditsRequestWithoutAccount.url?.absoluteString == "https://panel.example.com/v0/management/api-call",
    "reset-credit request should target the CPA Manager Plus api-call endpoint"
)
runner.check(resetCreditsRequestWithoutAccount.httpMethod == "POST", "reset-credit proxy request should use POST")
runner.check(
    resetCreditsRequestWithoutAccount.value(forHTTPHeaderField: "Authorization") == "Bearer management-secret",
    "reset-credit proxy request should authenticate with the management key"
)
runner.check(
    resetCreditsRequestWithoutAccount.value(forHTTPHeaderField: "Content-Type") == "application/json",
    "reset-credit proxy request should send JSON"
)
runner.check(
    resetCreditsRequestWithoutAccount.value(forHTTPHeaderField: "Accept") == "application/json",
    "reset-credit proxy request should accept JSON"
)
runner.check(
    resetCreditsRequestWithoutAccount.timeoutInterval == 8,
    "reset-credit proxy request should use the configured timeout"
)
let resetCreditsRequestBodyWithoutAccount = runner.require(
    resetCreditsRequestWithoutAccount.httpBody,
    "reset-credit proxy request should include a request body"
)
let resetCreditsRequestJSONWithoutAccount = runner.require(
    try JSONSerialization.jsonObject(with: resetCreditsRequestBodyWithoutAccount) as? [String: Any],
    "reset-credit proxy request body should be a JSON object"
)
let resetCreditsHeadersWithoutAccount = runner.require(
    resetCreditsRequestJSONWithoutAccount["header"] as? [String: Any],
    "reset-credit proxy request should include upstream headers"
)
runner.check(resetCreditsRequestJSONWithoutAccount["authIndex"] as? String == "auth-7", "reset-credit request should preserve authIndex")
runner.check(resetCreditsRequestJSONWithoutAccount["method"] as? String == "GET", "reset-credit upstream request should use GET")
runner.check(
    resetCreditsRequestJSONWithoutAccount["url"] as? String == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
    "reset-credit request should preserve the CPA Manager Plus upstream target"
)
runner.check(
    resetCreditsHeadersWithoutAccount["Authorization"] as? String == "Bearer $TOKEN$",
    "reset-credit upstream request should use the CPA token placeholder"
)
runner.check(resetCreditsHeadersWithoutAccount["Content-Type"] as? String == "application/json", "reset-credit upstream request should send JSON")
runner.check(resetCreditsHeadersWithoutAccount["Accept"] as? String == "application/json", "reset-credit upstream request should accept JSON")
runner.check(
    resetCreditsHeadersWithoutAccount["User-Agent"] as? String == "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
    "reset-credit upstream request should match the current CPA Manager Plus User-Agent"
)
runner.check(resetCreditsHeadersWithoutAccount["OpenAI-Beta"] as? String == "codex-1", "reset-credit upstream request should enable codex-1")
runner.check(resetCreditsHeadersWithoutAccount["Originator"] as? String == "Codex Desktop", "reset-credit upstream request should identify Codex Desktop")
runner.check(
    resetCreditsHeadersWithoutAccount["Chatgpt-Account-Id"] == nil,
    "reset-credit upstream request should omit an empty account ID"
)

let resetCreditsRequestWithAccount = try CLIProxyAPIClient.resetCreditsProxyRequest(
    managementBaseURL: resetCreditsManagementBaseURL,
    managementKey: "management-secret",
    authIndex: "auth-8",
    accountID: "  account-42  ",
    timeout: 8
)
let resetCreditsRequestBodyWithAccount = runner.require(
    resetCreditsRequestWithAccount.httpBody,
    "reset-credit proxy request with an account should include a body"
)
let resetCreditsRequestJSONWithAccount = runner.require(
    try JSONSerialization.jsonObject(with: resetCreditsRequestBodyWithAccount) as? [String: Any],
    "reset-credit proxy request with an account should be JSON"
)
let resetCreditsHeadersWithAccount = runner.require(
    resetCreditsRequestJSONWithAccount["header"] as? [String: Any],
    "reset-credit proxy request with an account should include upstream headers"
)
runner.check(
    resetCreditsHeadersWithAccount["Chatgpt-Account-Id"] as? String == "account-42",
    "reset-credit upstream request should include a trimmed account ID"
)

let resetCreditsObjectEnvelope = Data(#"""
{
  "status_code": 200,
  "body": {
    "available_count": 2,
    "credits": [
      {"id":"object","reset_type":"codex_rate_limits","status":"available","expires_at":1785110188}
    ]
  }
}
"""#.utf8)
let objectEnvelopeResetCredits = try CLIProxyAPIClient.decodeResetCreditsProxyResponse(
    resetCreditsObjectEnvelope,
    now: resetCreditsNow
)
runner.check(
    objectEnvelopeResetCredits?.availableCount == 2 && objectEnvelopeResetCredits?.credits.first?.id == "object",
    "reset-credit proxy should decode a snake-case status with an object body"
)
runner.check(
    objectEnvelopeResetCredits?.fetchedAt == resetCreditsNow,
    "reset-credit proxy should pass the supplied fetch time to the shared decoder"
)

let resetCreditsStringEnvelope = Data(#"""
{
  "statusCode": 200,
  "body": "{\"availableCount\":1,\"credits\":[{\"id\":\"string\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"expiresAt\":1785110188}]}"
}
"""#.utf8)
let stringEnvelopeResetCredits = try CLIProxyAPIClient.decodeResetCreditsProxyResponse(
    resetCreditsStringEnvelope,
    now: resetCreditsNow
)
runner.check(
    stringEnvelopeResetCredits?.credits.first?.id == "string",
    "reset-credit proxy should decode a camel-case status with a JSON string body"
)

let resetCreditsBodyTextSnakeEnvelope = Data(#"""
{
  "status_code": 200,
  "body_text": "{\"available_count\":1,\"credits\":[{\"id\":\"body-text-snake\",\"reset_type\":\"codex_rate_limits\",\"status\":\"available\",\"expires_at\":1785110188}]}"
}
"""#.utf8)
let bodyTextSnakeResetCredits = try CLIProxyAPIClient.decodeResetCreditsProxyResponse(
    resetCreditsBodyTextSnakeEnvelope,
    now: resetCreditsNow
)
runner.check(
    bodyTextSnakeResetCredits?.credits.first?.id == "body-text-snake",
    "reset-credit proxy should decode body_text"
)

let resetCreditsBodyTextCamelEnvelope = Data(#"""
{
  "statusCode": 200,
  "body": null,
  "bodyText": "{\"availableCount\":1,\"credits\":[{\"id\":\"body-text-camel\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"expiresAt\":1785110188}]}"
}
"""#.utf8)
let bodyTextCamelResetCredits = try CLIProxyAPIClient.decodeResetCreditsProxyResponse(
    resetCreditsBodyTextCamelEnvelope,
    now: resetCreditsNow
)
runner.check(
    bodyTextCamelResetCredits?.credits.first?.id == "body-text-camel",
    "reset-credit proxy should decode bodyText when body is absent"
)

let resetCreditsMissingPayload = try CLIProxyAPIClient.decodeResetCreditsProxyResponse(
    Data(#"{"status_code":200}"#.utf8),
    now: resetCreditsNow
)
runner.check(
    resetCreditsMissingPayload == nil,
    "reset-credit proxy should keep a missing payload unavailable instead of reporting zero"
)

do {
    _ = try CLIProxyAPIClient.decodeResetCreditsProxyResponse(
        Data(#"{"status_code":429,"body":{"error":{"type":"rate_limit","message":"Too many requests"}}}"#.utf8),
        now: resetCreditsNow
    )
    runner.check(false, "reset-credit proxy should reject non-2xx upstream responses")
} catch {
    runner.check(
        error.localizedDescription.contains("429") && error.localizedDescription.contains("Too many requests"),
        "reset-credit proxy should expose the upstream status and error message"
    )
}

let stringBoolLimitPayload = """
{
  "rate_limit": {
    "allowed": "false",
    "limit_reached": "true",
    "primary_window": {
      "limit_window_seconds": 18000
    }
  }
}
""".data(using: .utf8)!
let stringBoolLimitQuota = try CLIProxyAPIClient.decodeQuotaBody(stringBoolLimitPayload, fallbackPlanType: nil)
runner.check(stringBoolLimitQuota.windows.first?.reachesThreshold == true, "string boolean quota flags should mark threshold reached")

let proxyStringBodyErrorPayload = """
{
  "status_code": 200,
  "body": "{\\"error\\":{\\"type\\":\\"usage_limit_reached\\",\\"message\\":\\"The usage limit has been reached\\"}}"
}
""".data(using: .utf8)!
do {
    _ = try CLIProxyAPIClient.decodeQuotaProxyResponse(proxyStringBodyErrorPayload, fallbackPlanType: nil)
    runner.check(false, "proxy error body should not decode as an empty successful quota")
} catch {
    runner.check(error.localizedDescription.contains("usage limit") || error.localizedDescription.contains("额度"), "proxy error body should surface the upstream quota error")
}

let authFilesPayload = """
{
  "files": [
    {
      "authIndex": "7",
      "name": "codex-team",
      "provider": "Codex",
      "statusMessage": "ok",
      "recentRequests": [
        { "success": "2", "failed": "0" }
      ],
      "idToken": {
        "chatgptAccountId": "acct-1",
        "planType": "team"
      }
    }
  ]
}
""".data(using: .utf8)!
let authFiles = try JSONDecoder().decode(CLIProxyAuthFilesResponse.self, from: authFilesPayload)
let authFile = authFiles.files[0]
runner.check(authFile.authIndex == "7", "auth files should decode camelCase authIndex")
runner.check(authFile.statusMessage == "ok", "auth files should decode camelCase statusMessage")
runner.check(authFile.recentRequests?.first?.success == 2, "recent request success should decode string integers")
runner.check(authFile.idToken?.chatgptAccountID == "acct-1", "idToken should decode camelCase chatgpt account id")

let quotaAvailableInspectionPayload = """
{
  "results": [
    {
      "fileName": "codex-quota-available.json",
      "displayAccount": "available@example.com",
      "authIndex": "auth-available",
      "provider": "codex",
      "disabled": false,
      "status": "error",
      "action": "keep",
      "actionReason": "weekly quota still available",
      "statusCode": 200,
      "isQuota": false,
      "createdAtMs": 1781693102238
    }
  ],
  "logs": []
}
""".data(using: .utf8)!
let quotaAvailableAccounts = try CLIProxyAPIClient.decodeCodexInspectionAccounts(
    authFilesData: codexInspectionAuthFilesPayload,
    inspectionRunData: quotaAvailableInspectionPayload
)
runner.check(quotaAvailableAccounts.first?.state == .healthy, "available quota reason should not be treated as quota exhausted")

let preservedResetCredits = RateLimitResetCredits(
    availableCount: 3,
    credits: [],
    fetchedAt: Date(timeIntervalSince1970: 1_820_000_000)
)
let previousQuotaAccounts = [
    remoteAccount(
        id: "preserve-1",
        state: .healthy,
        quotaWindows: [
            RemoteQuotaWindow(
                id: "code-primary",
                shortLabel: "5h",
                remainingPercent: 77,
                usedPercent: 23,
                resetText: nil
            )
        ]
    ).withResetCredits(preservedResetCredits)
]
let currentQuotaMissingAccounts = [
    remoteAccount(id: "preserve-1", state: .healthy, quotaWindows: [])
]
let mergedQuotaAccounts = RemoteCodexAccount.preservingQuota(
    in: currentQuotaMissingAccounts,
    from: previousQuotaAccounts
)
runner.check(mergedQuotaAccounts.first?.quotaSummaryText == "5h 77%", "remote account list merge should preserve previous quota windows when current refresh has none")
runner.check(
    mergedQuotaAccounts.first?.resetCredits == preservedResetCredits,
    "remote account quota merge should preserve reset-credit data"
)
runner.check(
    previousQuotaAccounts[0].withQuotaExhaustion.resetCredits == preservedResetCredits,
    "remote account state replacement should preserve reset-credit data"
)

let sensitiveStatusAccount = RemoteCodexAccount(
    id: "secret-status-field",
    name: "secret-status-field",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "secret-status-field",
    chatgptAccountID: nil,
    status: "Bearer sk-sensitive-token",
    statusMessage: nil,
    successCount: 0,
    failureCount: 1,
    recentFailures: 0,
    state: .abnormal,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [],
    quotaError: nil
)
runner.check(sensitiveStatusAccount.stateReasonText == "状态异常", "remote status values should be mapped before display")
runner.check(!sensitiveStatusAccount.stateReasonText.lowercased().contains("sk-"), "remote status values should not leak token-like secrets")

let sensitiveReasonAccount = RemoteCodexAccount(
    id: "secret-status",
    name: "secret-status",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "secret-status",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: "token sk-1234567890abcdef should not appear",
    successCount: 0,
    failureCount: 1,
    recentFailures: 1,
    state: .abnormal,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [],
    quotaError: nil
)
runner.check(!sensitiveReasonAccount.stateReasonText.lowercased().contains("sk-"), "remote status reasons should redact token-like secrets before display")

runner.check(
    CodexNotchSettings.managementKeyForSave(
        draftKey: "old-secret",
        oldPanelURL: "https://old.example.com/management.html",
        newPanelURL: "https://new.example.com/management.html",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: false,
        remoteEnabled: true
    ).isEmpty,
    "changing remote panel origin should clear the old management key instead of saving it to the new origin"
)
runner.check(
    CodexNotchSettings.managementKeyForSave(
        draftKey: "old-secret",
        oldPanelURL: "https://old.example.com/management.html",
        newPanelURL: "https://old.example.com/management.html",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: true,
        remoteEnabled: true
    ).isEmpty,
    "changing insecure TLS mode should clear the old management key"
)
runner.check(
    CodexNotchSettings.managementKeyForSave(
        draftKey: "new-secret",
        oldPanelURL: "https://old.example.com/management.html",
        newPanelURL: "https://new.example.com/management.html",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: false,
        remoteEnabled: true,
        oldSavedKey: "old-secret"
    ) == "new-secret",
    "changing remote panel origin should save a newly entered management key"
)
runner.check(
    CodexNotchSettings.managementKeyForSave(
        draftKey: "old-secret",
        oldPanelURL: "not a url",
        newPanelURL: "https://new.example.com/management.html",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: false,
        remoteEnabled: true,
        oldSavedKey: "old-secret"
    ).isEmpty,
    "changing from an invalid remote panel URL to a valid origin should clear a reused management key"
)
runner.check(
    CodexNotchSettings.apiKeyForSave(
        draftKey: "old-api-token",
        oldPanelURL: "not a url",
        newPanelURL: "https://newapi.example.com",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: false,
        enabled: true,
        oldSavedKey: "old-api-token"
    ).isEmpty,
    "changing from an invalid API panel URL to a valid origin should clear a reused API key"
)
runner.check(
    CodexNotchSettings.apiKeyForSave(
        draftKey: "new-api-token",
        oldPanelURL: "not a url",
        newPanelURL: "https://newapi.example.com",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: false,
        enabled: true,
        oldSavedKey: "old-api-token"
    ) == "new-api-token",
    "changing API panel origin should save a newly entered API key"
)

let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchRegression-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: tempRoot)
}

let stateDatabase = tempRoot.appendingPathComponent("state_5.sqlite").path
let logsDatabase = tempRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    logsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])

let sessionID = "019e7169-d297-74c1-a61a-8e5a82acab34"
let subagentSessionID = "019ec23f-2f8e-7d50-a71d-b8a2ba679fd4"
let historicalSubagentSessionID = "019ec23f-7777-7d50-a71d-b8a2ba679fd4"
let parentOnlySessionID = "019e073a-c032-74e2-966e-b85ede0c9ccb"
let parentOnlySubagentID = "019ec23f-344a-7171-99d0-f1c2fe671252"
let staleParentSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd1"
let staleParentSubagentID = "019ec23f-5555-7171-99d0-f1c2fe671252"
let longMetaParentSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd0"
let longMetaSubagentID = "019ec23f-4444-7171-99d0-f1c2fe671252"
let completedSessionID = "019e073a-c032-74e2-966e-b85ede0c9ccd"
let completedFinalAnswerSessionID = "019e073a-c032-74e2-966e-b85ede0c9ccf"
let completedLogFinalSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd4"
let dbBackedSessionID = "019e073a-c032-74e2-966e-b85ede0c9cce"
let staleDBTokenSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd2"
let activeToolCallSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd3"
let sessionDirectory = tempRoot
    .appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
let rolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-00-\(sessionID).jsonl")
let now = Date()
let timestamp = ISO8601DateFormatter().string(from: now)
let primaryResetAt = Int(now.timeIntervalSince1970) + 3_600
let secondaryResetAt = Int(now.timeIntervalSince1970) + 3 * 24 * 60 * 60
let rolloutBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"xhigh","collaboration_mode":{"settings":{"reasoning_effort":"xhigh"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"正在运行的 Codex 任务"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":90000}}}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":12345}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":12,"resets_at":\(primaryResetAt)},"secondary":{"used_percent":34,"resets_at":\(secondaryResetAt)}}}}
"""
try rolloutBody.write(to: rolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: rolloutPath.path)

let subagentRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-01-\(subagentSessionID).jsonl")
let subagentRolloutBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(subagentSessionID)","parent_thread_id":"\(sessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(sessionID)","depth":1,"agent_nickname":"Test","agent_role":"explorer"}}},"thread_source":"subagent","agent_nickname":"Test","agent_role":"explorer"}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":9000000}}}}
{"timestamp":"\(timestamp)","type":"world_state","payload":{"kind":"inherited_parent_history"}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":8000000}}}}
{"timestamp":"\(timestamp)","type":"world_state","payload":{"kind":"child_start"}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"子代理任务不应该显示"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10000}}}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":23456}}}}
"""
try subagentRolloutBody.write(to: subagentRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: subagentRolloutPath.path)

let historicalSubagentRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-04-\(historicalSubagentSessionID).jsonl")
let historicalSubagentRolloutBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(historicalSubagentSessionID)","parent_thread_id":"\(sessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(sessionID)","depth":1,"agent_nickname":"Old","agent_role":"reviewer"}}},"thread_source":"subagent","agent_nickname":"Old","agent_role":"reviewer"}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"历史子代理不应该计入当前子代理数量"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":50000}}}}
"""
try historicalSubagentRolloutBody.write(to: historicalSubagentRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: historicalSubagentRolloutPath.path)

let parentOnlyRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-02-\(parentOnlySessionID).jsonl")
let parentOnlyBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"只有子代理活跃的父任务"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":34567}}}}
"""
try parentOnlyBody.write(to: parentOnlyRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: parentOnlyRolloutPath.path)

let parentOnlySubagentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-03-\(parentOnlySubagentID).jsonl")
let parentOnlySubagentBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(parentOnlySubagentID)","parent_thread_id":"\(parentOnlySessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(parentOnlySessionID)","depth":1,"agent_nickname":"Worker","agent_role":"reviewer"}}},"thread_source":"subagent","agent_nickname":"Worker","agent_role":"reviewer"}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"另一个子代理任务不应该显示"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":45678}}}}
"""
try parentOnlySubagentBody.write(to: parentOnlySubagentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: parentOnlySubagentPath.path)

let staleParentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-10-\(staleParentSessionID).jsonl")
let staleParentBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"父会话超出当前任务范围但子代理正在运行"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":123000}}}}
"""
try staleParentBody.write(to: staleParentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: staleParentPath.path)

let staleParentSubagentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-11-\(staleParentSubagentID).jsonl")
let staleParentSubagentBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(staleParentSubagentID)","parent_thread_id":"\(staleParentSessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(staleParentSessionID)","depth":1,"agent_nickname":"Worker","agent_role":"explorer"}}},"thread_source":"subagent","agent_nickname":"Worker","agent_role":"explorer"}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"子代理仍在输出"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":321000}}}}
"""
try staleParentSubagentBody.write(to: staleParentSubagentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: staleParentSubagentPath.path)

let longMetaParentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-08-\(longMetaParentSessionID).jsonl")
let longMetaParentBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"超长 session_meta 的父任务"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":22222}}}}
"""
try longMetaParentBody.write(to: longMetaParentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: longMetaParentPath.path)

let longSessionMetaPadding = String(repeating: "x", count: 80_000)
let longMetaSubagentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-09-\(longMetaSubagentID).jsonl")
let longMetaSubagentBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(longMetaSubagentID)","parent_thread_id":"\(longMetaParentSessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(longMetaParentSessionID)","depth":1,"agent_nickname":"Long","agent_role":"explorer"}}},"thread_source":"subagent","agent_nickname":"Long","agent_role":"explorer","base_instructions":{"text":"\(longSessionMetaPadding)"}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"超长子代理任务不应该显示"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":11111}}}}
"""
try longMetaSubagentBody.write(to: longMetaSubagentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: longMetaSubagentPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(longMetaSubagentID)', '数据库里的子代理不应该显示', 11111, 'gpt-5.5', 'xhigh', '\(longMetaSubagentPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])

let completedRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-05-\(completedSessionID).jsonl")
let completedBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"已经完成的任务"}]}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"完成"}],"phase":"final"}}
"""
try completedBody.write(to: completedRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: completedRolloutPath.path)

let completedFinalAnswerRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-07-\(completedFinalAnswerSessionID).jsonl")
let completedFinalAnswerBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"刚刚完成但还很新的任务"}]}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"完成"}],"phase":"final_answer"}}
{"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"019ed38c-b572-7140-a10f-e4c982c36066","completed_at":\(Int(now.timeIntervalSince1970)),"duration_ms":1200}}
"""
try completedFinalAnswerBody.write(to: completedFinalAnswerRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: completedFinalAnswerRolloutPath.path)

let completedLogFinalRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-14-\(completedLogFinalSessionID).jsonl")
let completedLogFinalBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"日志 final 完成的任务"}]}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"完成"}],"phase":"final"}}
"""
try completedLogFinalBody.write(to: completedLogFinalRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: completedLogFinalRolloutPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(completedLogFinalSessionID)', '日志 final 完成的任务', 888, 'gpt-5.5', 'high', '\(completedLogFinalRolloutPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    logsDatabase,
    """
    insert into logs(thread_id, ts, target, feedback_log_body)
    values
      ('\(completedLogFinalSessionID)', \(Int(now.timeIntervalSince1970) - 30), 'codex_otel.trace_safe', '{"type":"event_msg","payload":{"type":"response.output_text.delta"}}'),
      ('\(completedLogFinalSessionID)', \(Int(now.timeIntervalSince1970) - 20), 'codex_otel.trace_safe', '{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final"}}');
    """
])

let dbBackedRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-06-\(dbBackedSessionID).jsonl")
let dbBackedBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"数据库已有 token 的旧任务"}]}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"完成"}],"phase":"final"}}
"""
try dbBackedBody.write(to: dbBackedRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dbBackedRolloutPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(dbBackedSessionID)', '数据库已有 token 的旧任务', 777, 'gpt-5.5', 'high', '\(dbBackedRolloutPath.path)', \(Int(now.timeIntervalSince1970) - 7 * 24 * 60 * 60), 0);
    """
])

let staleDBTokenRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-12-\(staleDBTokenSessionID).jsonl")
let staleDBTokenBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"数据库 token 滞后的运行中任务"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120000000}}}}
"""
try staleDBTokenBody.write(to: staleDBTokenRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: staleDBTokenRolloutPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(staleDBTokenSessionID)', '数据库 token 滞后的运行中任务', 13, 'gpt-5.5', 'high', '\(staleDBTokenRolloutPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])

let activeToolCallPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-13-\(activeToolCallSessionID).jsonl")
let activeToolCallActivity = ISO8601DateFormatter().string(from: now.addingTimeInterval(-240))
let activeToolCallItemDone = ISO8601DateFormatter().string(from: now.addingTimeInterval(-230))
let activeToolCallBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"xhigh","collaboration_mode":{"settings":{"reasoning_effort":"xhigh"}}}}
{"timestamp":"\(activeToolCallActivity)","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}"}}
{"timestamp":"\(activeToolCallItemDone)","type":"event_msg","payload":{"type":"response.function_call_arguments.done"}}
{"timestamp":"\(activeToolCallItemDone)","type":"event_msg","payload":{"type":"response.output_item.done"}}
{"timestamp":"\(activeToolCallItemDone)","type":"event_msg","payload":{"type":"response.completed"}}
"""
try activeToolCallBody.write(to: activeToolCallPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: activeToolCallPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(activeToolCallSessionID)', '工具调用仍在运行', 21, 'gpt-5.5', 'xhigh', '\(activeToolCallPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])

let localStore = CodexUsageStore(codexDirectory: tempRoot)
let localSnapshot = localStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(localSnapshot.isRunning, "recent session rollout should mark local Codex as running")
runner.check(localSnapshot.tasks.contains { $0.id == sessionID && $0.status == .running }, "recent session rollout should appear in running task list")
runner.check(localSnapshot.tasks.first { $0.id == sessionID }?.title == "正在运行的 Codex 任务", "session rollout should use the user message as task title")
runner.check(localSnapshot.tasks.first { $0.id == sessionID }?.detail.contains("gpt-5.5 · 超高推理") == true, "session rollout should use turn context model and effort")
runner.check(!localSnapshot.tasks.contains { $0.id == subagentSessionID }, "subagent rollout should not appear as a separate local task")
runner.check(!localSnapshot.tasks.contains { $0.id == parentOnlySubagentID }, "subagent-only activity should still hide the child task")
runner.check(!localSnapshot.tasks.contains { $0.id == longMetaSubagentID }, "subagent rollout with long session metadata should still hide the child task")
runner.check(localSnapshot.tasks.contains { $0.id == parentOnlySessionID && $0.status == .running }, "recent subagent activity should mark the parent task running")
runner.check(localSnapshot.tasks.contains { $0.id == longMetaParentSessionID && $0.status == .running }, "long session metadata subagent activity should mark the parent task running")
runner.check(localSnapshot.tasks.first { $0.id == parentOnlySessionID }?.detail.contains("gpt-5.5 · 高推理") == true, "parent running through subagent activity should use turn context model and effort")
runner.check(localSnapshot.tasks.first { $0.id == sessionID }?.activeSubagentCount == 1, "parent task should only show currently active subagents")
runner.check(localSnapshot.tasks.first { $0.id == parentOnlySessionID }?.activeSubagentCount == 1, "parent running through subagent activity should show one subagent")
runner.check(localSnapshot.tasks.first { $0.id == longMetaParentSessionID }?.activeSubagentCount == 1, "parent running through long metadata subagent activity should show one subagent")
runner.check(localSnapshot.tasks.contains { $0.id == staleParentSessionID && $0.status == .running }, "active subagent should synthesize a running parent task even when the parent is outside the task range")
runner.check(localSnapshot.tasks.first { $0.id == sessionID }?.tokenCount == 185801, "parent task token count should include parent and all subagent session totals")
runner.check(localSnapshot.tasks.first { $0.id == sessionID }?.tokenCount != 17_185_801, "parent task token count should exclude history copied into spawned subagent rollouts")
runner.check(localSnapshot.tasks.first { $0.id == parentOnlySessionID }?.tokenCount == 80245, "parent running through subagent activity should include subagent token usage")
runner.check(localSnapshot.tasks.first { $0.id == longMetaParentSessionID }?.tokenCount == 33333, "parent running through long metadata subagent activity should include subagent token usage")
runner.check(localSnapshot.tasks.first { $0.id == staleDBTokenSessionID }?.tokenCount == 120000000, "recent task token count should prefer fresher rollout totals over stale database tokens")
runner.check(localSnapshot.tasks.contains { $0.id == activeToolCallSessionID && $0.status == .running }, "quiet tool calls should keep the running indicator on until a task-level completion event arrives")
runner.check(localSnapshot.tasks.first { $0.id == completedSessionID }?.status == .recent, "fresh completed session rollout should not be treated as running")
runner.check(localSnapshot.tasks.first { $0.id == completedFinalAnswerSessionID }?.status == .recent, "fresh final_answer/task_complete rollout should not be treated as running")
runner.check(localSnapshot.tasks.first { $0.id == completedLogFinalSessionID }?.status == .recent, "logs final-phase completion should clear stale running state")
runner.check(localSnapshot.tasks.first { $0.id == dbBackedSessionID }?.tokenCount == 777, "recent rollout fallback should reuse database tokens even when the database updated_at is outside the task range")
runner.check(localSnapshot.primaryPercent == 88, "local snapshot should expose the latest Codex 5h remaining quota")
runner.check(localSnapshot.secondaryPercent == 66, "local snapshot should expose the latest Codex 7d remaining quota")
runner.check(localSnapshot.primaryResetsAt == Date(timeIntervalSince1970: TimeInterval(primaryResetAt)), "local snapshot should expose the 5h reset time")
runner.check(localSnapshot.secondaryResetsAt == Date(timeIntervalSince1970: TimeInterval(secondaryResetAt)), "local snapshot should expose the 7d reset time")
let localWatchPaths = Set(localStore.rateLimitWatchPaths())
let normalizedSessionDirectory = sessionDirectory.resolvingSymlinksInPath().path
let normalizedRolloutPath = rolloutPath.resolvingSymlinksInPath().path
runner.check(localWatchPaths.contains(normalizedSessionDirectory), "local file watchers should include recent session directories so new subagents trigger refreshes")
runner.check(localWatchPaths.contains(normalizedRolloutPath), "local file watchers should keep watching recent session files for active task updates")

let mixedUsageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchMixedUsage-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: mixedUsageRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: mixedUsageRoot)
}
let mixedUsageStateDatabase = mixedUsageRoot.appendingPathComponent("state_5.sqlite").path
let mixedUsageLogsDatabase = mixedUsageRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedUsageStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedUsageLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let mixedUsageDirectory = mixedUsageRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: mixedUsageDirectory, withIntermediateDirectories: true)
let mixedUsageSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd5"
let mixedUsagePath = mixedUsageDirectory.appendingPathComponent("rollout-2026-06-14T02-20-15-\(mixedUsageSessionID).jsonl")
try #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
    .write(to: mixedUsagePath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: mixedUsagePath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedUsageStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(mixedUsageSessionID)', '日志更完整的任务', 0, 'gpt-5.5', 'high', '\(mixedUsagePath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedUsageLogsDatabase,
    """
    insert into logs(thread_id, ts, target, feedback_log_body)
    values('\(mixedUsageSessionID)', \(Int(now.timeIntervalSince1970)), 'codex_otel.trace_safe', 'event.kind=response.completed tool_token_count=10000');
    """
])
let mixedUsageStore = CodexUsageStore(codexDirectory: mixedUsageRoot, ripgrepCandidates: [])
runner.check(mixedUsageStore.loadUsageTotals(now: now)?.day == 10000, "local usage totals should merge logs when logs have more complete token counts than rollouts")

let logCacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchLogCache-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: logCacheRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: logCacheRoot)
}
let logCacheStateDatabase = logCacheRoot.appendingPathComponent("state_5.sqlite").path
let logCacheLogsDatabase = logCacheRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    logCacheStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    logCacheLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let logCacheDirectory = logCacheRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: logCacheDirectory, withIntermediateDirectories: true)
let logCacheSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd6"
let logCachePath = logCacheDirectory.appendingPathComponent("rollout-2026-06-14T02-20-16-\(logCacheSessionID).jsonl")
try #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"仅日志统计"}]}}"#
    .write(to: logCachePath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: logCachePath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    logCacheStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(logCacheSessionID)', '仅日志统计', 0, 'gpt-5.5', 'high', '\(logCachePath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    logCacheLogsDatabase,
    """
    insert into logs(thread_id, ts, target, feedback_log_body)
    values('\(logCacheSessionID)', \(Int(now.timeIntervalSince1970)), 'codex_otel.trace_safe', 'event.kind=response.completed tool_token_count=1000');
    """
])
let logCacheStore = CodexUsageStore(codexDirectory: logCacheRoot, ripgrepCandidates: [])
runner.check(logCacheStore.loadUsageTotals(now: now)?.day == 1000, "log fallback usage should be available when rollout usage is empty")
_ = try Shell.run("/usr/bin/sqlite3", [
    logCacheLogsDatabase,
    """
    insert into logs(thread_id, ts, target, feedback_log_body)
    values('\(logCacheSessionID)', \(Int(now.timeIntervalSince1970) + 1), 'codex_otel.trace_safe', 'event.kind=response.completed tool_token_count=2000');
    """
])
runner.check(logCacheStore.loadUsageTotals(now: now.addingTimeInterval(1))?.day == 3000, "log fallback usage cache should refresh when logs database changes")

let cachedLocalSnapshot = localStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: false,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(cachedLocalSnapshot.tasks.contains { $0.id == parentOnlySessionID && $0.status == .running }, "fast snapshot cache should preserve active parent task ids")
runner.check(cachedLocalSnapshot.tasks.first { $0.id == parentOnlySessionID }?.activeSubagentCount == 1, "fast snapshot cache should preserve active subagent counts")

let snapshotLogRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchSnapshotLogSignature-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: snapshotLogRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: snapshotLogRoot)
}
let snapshotLogStateDatabase = snapshotLogRoot.appendingPathComponent("state_5.sqlite").path
let snapshotLogLogsDatabase = snapshotLogRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    snapshotLogStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    snapshotLogLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let snapshotLogDirectory = snapshotLogRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: snapshotLogDirectory, withIntermediateDirectories: true)
let snapshotLogSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd7"
let snapshotLogPath = snapshotLogDirectory.appendingPathComponent("rollout-2026-06-14T02-20-17-\(snapshotLogSessionID).jsonl")
try """
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"日志触发运行状态"}]}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"完成"}],"phase":"final"}}
"""
    .write(to: snapshotLogPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: snapshotLogPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    snapshotLogStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(snapshotLogSessionID)', '日志触发运行状态', 0, 'gpt-5.5', 'high', '\(snapshotLogPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])
let snapshotLogStore = CodexUsageStore(codexDirectory: snapshotLogRoot, ripgrepCandidates: [])
let idleSnapshotBeforeLog = snapshotLogStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: false,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(idleSnapshotBeforeLog.tasks.first { $0.id == snapshotLogSessionID }?.status == .recent, "snapshot log fixture should start as a recent task")
_ = try Shell.run("/usr/bin/sqlite3", [
    snapshotLogLogsDatabase,
    """
    insert into logs(thread_id, ts, target, feedback_log_body)
    values('\(snapshotLogSessionID)', \(Int(now.timeIntervalSince1970) + 1), 'codex_otel.trace_safe', '{"type":"event_msg","payload":{"type":"response.output_item.added"}}');
    """
])
let runningSnapshotAfterLog = snapshotLogStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: false,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(1)
)
runner.check(
    runningSnapshotAfterLog.tasks.first { $0.id == snapshotLogSessionID }?.status == .running,
    "fast snapshot cache should invalidate when logs database activity changes"
)

runner.check(localStore.loadUsageTotals(now: now)?.day == 120743379, "session rollout token counts should contribute to local usage totals")
runner.check(localStore.loadUsageTotals(now: now.addingTimeInterval(1))?.day == 120743379, "unchanged local usage totals should remain stable across cached refreshes")

let largeUsageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchLargeUsage-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: largeUsageRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: largeUsageRoot)
}
let largeUsageStateDatabase = largeUsageRoot.appendingPathComponent("state_5.sqlite").path
let largeUsageLogsDatabase = largeUsageRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    largeUsageStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    largeUsageLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let largeUsageDirectory = largeUsageRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: largeUsageDirectory, withIntermediateDirectories: true)
let largeUsageSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd4"
let largeUsagePath = largeUsageDirectory.appendingPathComponent("rollout-2026-06-14T02-20-14-\(largeUsageSessionID).jsonl")
try Data(repeating: UInt8(ascii: " "), count: 21 * 1024 * 1024).write(to: largeUsagePath)
if let handle = try? FileHandle(forWritingTo: largeUsagePath) {
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(("\n" + #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1}}}}"# + "\n").utf8))
    try handle.close()
}
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: largeUsagePath.path)
let fakeRipgrepPath = largeUsageRoot.appendingPathComponent("fake-rg").path
try """
#!/bin/sh
/usr/bin/grep '"token_count"'
""".write(toFile: fakeRipgrepPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeRipgrepPath)
_ = try Shell.run("/usr/bin/sqlite3", [
    largeUsageStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(largeUsageSessionID)', '大文件统计任务', 777777, 'gpt-5.5', 'high', '\(largeUsagePath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])
let largeUsageStore = CodexUsageStore(codexDirectory: largeUsageRoot, ripgrepCandidates: [fakeRipgrepPath])
runner.check(largeUsageStore.loadUsageTotals(now: now)?.day == 1, "large rollout usage totals should use exact token events when fast search is available")
let largeUsageFallbackStore = CodexUsageStore(codexDirectory: largeUsageRoot, ripgrepCandidates: [])
runner.check(largeUsageFallbackStore.loadUsageTotals(now: now)?.day == 777777, "large rollout usage totals should fall back to database tokens when fast search is unavailable")

let tokenCacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchTokenCache-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tokenCacheRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: tokenCacheRoot)
}
let tokenCacheStateDatabase = tokenCacheRoot.appendingPathComponent("state_5.sqlite").path
let tokenCacheLogsDatabase = tokenCacheRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    tokenCacheStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    tokenCacheLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let tokenCacheSessionDirectory = tokenCacheRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: tokenCacheSessionDirectory, withIntermediateDirectories: true)
let tokenCacheSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd3"
let tokenCachePath = tokenCacheSessionDirectory.appendingPathComponent("rollout-2026-06-14T02-20-13-\(tokenCacheSessionID).jsonl")
let firstTokenLine = #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"无尾换行 token"}]}}"# + "\n" +
    #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
try firstTokenLine.write(to: tokenCachePath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: tokenCachePath.path)
let tokenCacheStore = CodexUsageStore(codexDirectory: tokenCacheRoot)
let firstTokenSnapshot = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(firstTokenSnapshot.tasks.first { $0.id == tokenCacheSessionID }?.tokenCount == 100, "initial no-newline token event should be counted once")
let secondTokenLine = "\n" + #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":50}}}}"# + "\n"
if let handle = try? FileHandle(forWritingTo: tokenCachePath) {
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(secondTokenLine.utf8))
    try handle.close()
}
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: tokenCachePath.path)
let secondTokenSnapshot = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(1)
)
runner.check(secondTokenSnapshot.tasks.first { $0.id == tokenCacheSessionID }?.tokenCount == 150, "appending after an initially unterminated token line should not double count the pending line")

if runner.failures > 0 {
    FileHandle.standardError.write(Data("\(runner.failures) regression test(s) failed\n".utf8))
    exit(1)
}

print("All regression tests passed")
