import Foundation

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

runner.check(AppInfo.version == "0.1.2", "app info should expose version 0.1.2")
runner.check(AppInfo.displayVersion == "0.1.2", "app info should fall back to source version when bundle version is unavailable")
runner.check(TaskStatus.running.hudLabel == "RUNNING", "HUD running status should display RUNNING")
runner.check(TaskStatus.recent.hudLabel == "IDLE", "HUD recent status should display as IDLE")
runner.check(TaskStatus.idle.hudLabel == "IDLE", "HUD idle status should display as IDLE")

let snapshotFormatterTask = CodexTask(
    id: "snapshot-task",
    title: "父任务",
    status: .running,
    detail: "gpt-5.5 · 高推理",
    tokenCount: 12345,
    updatedAt: Date(timeIntervalSince1970: 0),
    activeSubagentCount: 3,
    delta10mTokens: 1200,
    delta1hTokens: 3456,
    contextInputTokens: 58609,
    contextWindowTokens: 258400,
    contextPercent: 22.681501547987615,
    contextUpdatedAt: Date(timeIntervalSince1970: 10)
)
let snapshotFormatterSnapshot = UsageSnapshot(
    primaryPercent: 88,
    secondaryPercent: 66,
    usage1h: 444,
    usage24h: 111,
    usage7d: 222,
    usage30d: 333,
    sparkQuotaWindows: [
        SparkQuotaWindow(
            id: "spark-5h",
            label: "5h",
            remainingPercent: 12,
            usedPercent: 88,
            resetAt: 1_783_000_000,
            resetText: "2h"
        )
    ],
    tasks: [snapshotFormatterTask],
    isRunning: true,
    lastUpdated: Date(timeIntervalSince1970: 0),
    errorMessage: nil,
    monitorStats: MonitorPerformanceStats(
        lastSnapshotDurationMs: 42,
        lastUsageDurationMs: 84,
        lastDeltaDurationMs: 5,
        lastRateLimitSource: "local-jsonl",
        watchedPathCount: 7,
        jsonlContextScans: 2,
        monitorModelTokens: 0
    )
)
let humanSnapshotLines = SnapshotOutputFormatter.humanLines(for: snapshotFormatterSnapshot)
runner.check(
    humanSnapshotLines.contains("usage1h=444 usage24h=111 usage7d=222 usage30d=333"),
    "human snapshot output should expose aggregate 1 hour usage"
)
runner.check(
    humanSnapshotLines.contains("spark=5h=12%"),
    "human snapshot output should expose Spark quota windows"
)
runner.check(
    humanSnapshotLines.contains("monitor snapshot_ms=42 usage_ms=84 delta_ms=5 rate=local-jsonl watched=7 context_scans=2 model_tokens=0"),
    "human snapshot output should expose monitor self cost"
)
runner.check(
    humanSnapshotLines.contains("task=运行中 父任务 12345 delta10m=+1.2千 delta1h=+3.5千 ctx=6万/26万"),
    "human snapshot task line should expose token deltas and context ratio"
)
runner.check(
    !humanSnapshotLines.contains { $0.contains("subagents=") },
    "human snapshot output should not append subagent fields to task lines"
)
let jsonSnapshot = try JSONSerialization.jsonObject(
    with: SnapshotOutputFormatter.jsonData(for: snapshotFormatterSnapshot)
) as? [String: Any]
let jsonMonitor = jsonSnapshot?["monitor"] as? [String: Any]
runner.check(
    jsonSnapshot?["usage_1h"] as? Int == 444,
    "JSON snapshot output should expose aggregate 1 hour usage"
)
let jsonSparkWindows = jsonSnapshot?["spark_quota_windows"] as? [[String: Any]]
runner.check(
    jsonSparkWindows?.first?["label"] as? String == "5h",
    "JSON snapshot output should expose Spark quota labels"
)
runner.check(
    jsonSparkWindows?.first?["remaining_percent"] as? Int == 12,
    "JSON snapshot output should expose Spark quota remaining percent"
)
runner.check(
    jsonMonitor?["last_snapshot_duration_ms"] as? Int == 42,
    "JSON snapshot output should expose snapshot duration"
)
runner.check(
    jsonMonitor?["last_usage_duration_ms"] as? Int == 84,
    "JSON snapshot output should expose usage duration"
)
runner.check(
    jsonMonitor?["last_delta_duration_ms"] as? Int == 5,
    "JSON snapshot output should expose delta duration"
)
runner.check(
    jsonMonitor?["last_rate_limit_source"] as? String == "local-jsonl",
    "JSON snapshot output should expose rate limit source"
)
runner.check(
    jsonMonitor?["watched_path_count"] as? Int == 7,
    "JSON snapshot output should expose watched path count"
)
runner.check(
    jsonMonitor?["jsonl_context_scans"] as? Int == 2,
    "JSON snapshot output should expose context scan count"
)
runner.check(
    jsonMonitor?["monitor_model_tokens"] as? Int == 0,
    "JSON snapshot output should report zero monitor model tokens"
)
let jsonSnapshotTasks = jsonSnapshot?["tasks"] as? [[String: Any]]
runner.check(
    jsonSnapshotTasks?.first?["subagents"] as? Int == 3,
    "JSON snapshot output should expose active subagent counts"
)
runner.check(
    jsonSnapshotTasks?.first?["delta_10m_tokens"] as? Int == 1200,
    "JSON snapshot output should expose 10 minute token deltas"
)
runner.check(
    jsonSnapshotTasks?.first?["delta_1h_tokens"] as? Int == 3456,
    "JSON snapshot output should expose 1 hour token deltas"
)
runner.check(
    jsonSnapshotTasks?.first?["context_input_tokens"] as? Int == 58609,
    "JSON snapshot output should expose context input tokens"
)
runner.check(
    jsonSnapshotTasks?.first?["context_window_tokens"] as? Int == 258400,
    "JSON snapshot output should expose model context window tokens"
)
runner.check(
    (jsonSnapshotTasks?.first?["context_percent"] as? Double).map { abs($0 - 22.681501547987615) < 0.000001 } == true,
    "JSON snapshot output should expose context percentage"
)
let tokenContextLine = #"{"timestamp":"2026-06-29T15:01:43.961Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":39217907,"cached_input_tokens":35158912,"output_tokens":176936,"reasoning_output_tokens":60714,"total_tokens":39394843},"last_token_usage":{"input_tokens":57907,"cached_input_tokens":55168,"output_tokens":644,"reasoning_output_tokens":230,"total_tokens":58551},"model_context_window":258400},"rate_limits":{"limit_id":"codex"}}}"#
let parsedContext = runner.require(
    TokenContextUsageParser.parse(line: tokenContextLine),
    "token context parser should read token_count context payloads"
)
runner.check(parsedContext.inputTokens == 57907, "token context parser should use last_token_usage input tokens")
runner.check(parsedContext.windowTokens == 258400, "token context parser should read model_context_window")
runner.check(abs(parsedContext.percent - 22.40982972136223) < 0.000001, "token context parser should calculate context percentage")
runner.check(
    TaskBadgeFormatter.subagentBadgeText(for: 3) == "子代理 3",
    "task row subagent badge should use compact text"
)
runner.check(
    TaskBadgeFormatter.subagentBadgeText(for: 0) == nil,
    "task row subagent badge should stay hidden for zero active subagents"
)

let appServerRateLimitOutput = """
{"jsonrpc":"2.0","id":2,"result":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":20,"resets_at":1783000000},"secondary":{"used_percent":30,"resets_at":1783400000}},"rate_limits_by_limit_id":{"codex":{"limit_id":"codex","primary":{"used_percent":20,"resets_at":1783000000},"secondary":{"used_percent":30,"resets_at":1783400000}},"GPT-5.3-Codex-Spark":{"limit_id":"gpt-5.3-codex-spark","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":100,"resets_at":1783000000},"secondary":{"used_percent":25,"resets_at":1783400000}}}}}
"""
let appServerSnapshot = runner.require(
    CodexUsageStore().parseAppServerRateLimits(
        output: appServerRateLimitOutput,
        now: Date(timeIntervalSince1970: 1_782_900_000)
    ),
    "app-server rate limit fixture should parse"
)
runner.check(appServerSnapshot.primaryPercent == 80, "app-server codex primary quota should remain the main 5h quota")
runner.check(appServerSnapshot.secondaryPercent == 70, "app-server codex secondary quota should remain the main 7d quota")
runner.check(appServerSnapshot.sparkQuotaWindows.map(\.label) == ["5h", "7d"], "app-server Spark quota windows should decode")
runner.check(appServerSnapshot.sparkQuotaWindows.first?.remainingPercent == 0, "app-server Spark 5h remaining percent should decode")
runner.check(appServerSnapshot.sparkQuotaWindows.last?.remainingPercent == 75, "app-server Spark 7d remaining percent should decode")

@MainActor
func dateFromISO8601(_ value: String, message: String) -> Date {
    runner.require(CodexRadarDateParser.parse(value), message)
}

let codexRadarFixture = """
{
  "monitored_at": "2026-07-01T06:27:00+08:00",
  "status": "community_confirmed",
  "recommended_action": "reset_completed",
  "window": {
    "message": "社区反馈已完成重置"
  },
  "prediction": {
    "summary": "官方重置已经完成。"
  },
  "api_access": {
    "requirements": {
      "attribution_required": true,
      "attribution_text": "数据来自 Codex 雷达 codexradar.com",
      "site": "https://codexradar.com"
    }
  },
  "model_iq": {
    "latest": {
      "score": 62.5,
      "status": "red",
      "passed": 5,
      "tasks": 12,
      "wall_time_human": "37分钟",
      "model": "gpt-5.5",
      "reasoning_effort": "xhigh",
      "cost_usd": 46.348455
    },
    "comparisons": {
      "gpt_55_high": {
        "label": "GPT-5.5 high",
        "latest": {
          "score": 75.0,
          "status": "red",
          "passed": 6,
          "tasks": 12,
          "wall_time_human": "36分钟",
          "cost_usd": 24.929204
        }
      },
      "gpt_55_medium": {
        "label": "GPT-5.5 medium",
        "latest": {
          "score": 87.5,
          "status": "yellow",
          "passed": 7,
          "tasks": 12,
          "wall_time_human": "32分钟",
          "cost_usd": 20.98977
        }
      },
      "gpt_54_xhigh": {
        "label": "GPT-5.4 xhigh",
        "latest": {
          "score": 50.0,
          "status": "red",
          "passed": 4,
          "tasks": 12,
          "wall_time_human": "35分钟",
          "cost_usd": 22.651593
        }
      },
      "gpt_54_high": {
        "label": "GPT-5.4 high",
        "latest": {
          "score": 87.5,
          "status": "yellow",
          "passed": 7,
          "tasks": 12,
          "wall_time_human": "36分钟",
          "cost_usd": 17.771049
        }
      }
    },
    "quota_radar": {
      "updated_at": "2026-06-30T22:27:57Z",
      "cost_usd": 132.690071,
      "rows": [
        {"tier": "20x Pro", "basis": "measured 7d", "five_h": 276.44, "seven_d": 1658.63},
        {"tier": "5x Pro", "basis": "model /4", "five_h": 69.11, "seven_d": 414.66},
        {"tier": "Plus", "basis": "model /20", "five_h": 13.82, "seven_d": 82.93}
      ]
    }
  }
}
""".data(using: .utf8)!
let radarFetchedAt = dateFromISO8601("2026-07-01T06:28:00+08:00", message: "Codex Radar fetched timestamp should parse")
let radarSnapshot = try CodexRadarSnapshot.decodePublicSummary(from: codexRadarFixture, fetchedAt: radarFetchedAt)
runner.check(radarSnapshot.models.count == 5, "Codex Radar summary should expose five model cards")
runner.check(radarSnapshot.models.map(\.label) == [
    "GPT-5.5 xhigh",
    "GPT-5.5 high",
    "GPT-5.5 medium",
    "GPT-5.4 xhigh",
    "GPT-5.4 high"
], "Codex Radar model cards should preserve the expected display order")
runner.check(radarSnapshot.models.first?.score == 62.5, "Codex Radar latest model should decode score")
runner.check(radarSnapshot.models.first?.passed == 5, "Codex Radar latest model should decode passed tasks")
runner.check(radarSnapshot.models.first?.tasks == 12, "Codex Radar latest model should decode task count")
runner.check(radarSnapshot.quotaRows.count == 3, "Codex Radar quota radar should expose three plan rows")
runner.check(radarSnapshot.quotaRows.first?.tier == "20x Pro", "Codex Radar quota row should preserve tier")
runner.check(radarSnapshot.quotaRows.first?.fiveH == 276.44, "Codex Radar quota row should decode 5h estimate")
runner.check(radarSnapshot.quotaRows.first?.sevenD == 1658.63, "Codex Radar quota row should decode 7d estimate")
runner.check(radarSnapshot.costUSD == 132.690071, "Codex Radar cost should prefer quota_radar cost")
runner.check(
    radarSnapshot.displayUpdatedAt == dateFromISO8601("2026-06-30T22:27:57Z", message: "Codex Radar display timestamp should parse"),
    "Codex Radar display timestamp should prefer the freshest source data timestamp"
)
runner.check(radarSnapshot.attributionRequired, "Codex Radar should preserve required attribution flag")
runner.check(radarSnapshot.attributionText == "数据来自 Codex 雷达 codexradar.com", "Codex Radar should preserve attribution text")
runner.check(radarSnapshot.siteURL.absoluteString == "https://codexradar.com", "Codex Radar should preserve source site")

let radarMissingModelIQ = """
{
  "monitored_at": "2026-07-01T06:27:00+08:00",
  "api_access": {
    "requirements": {
      "attribution_required": true,
      "attribution_text": "数据来自 Codex 雷达 codexradar.com",
      "site": "https://codexradar.com"
    }
  }
}
""".data(using: .utf8)!
let missingModelSnapshot = try CodexRadarSnapshot.decodePublicSummary(from: radarMissingModelIQ, fetchedAt: radarFetchedAt)
runner.check(missingModelSnapshot.models.isEmpty, "Codex Radar should degrade when model_iq is missing")
runner.check(missingModelSnapshot.quotaRows.isEmpty, "Codex Radar should degrade when quota radar is missing")
runner.check(missingModelSnapshot.attributionText == CodexRadarSnapshot.defaultAttributionText, "Codex Radar should keep attribution on partial data")

let radarMissingComparisons = """
{
  "monitored_at": "2026-07-01T06:27:00+08:00",
  "model_iq": {
    "latest": {
      "score": 62.5,
      "status": "red",
      "passed": 5,
      "tasks": 12
    },
    "quota_radar": {
      "rows": []
    }
  }
}
""".data(using: .utf8)!
let missingComparisonsSnapshot = try CodexRadarSnapshot.decodePublicSummary(from: radarMissingComparisons, fetchedAt: radarFetchedAt)
runner.check(missingComparisonsSnapshot.models.count == 1, "Codex Radar should still show latest model when comparisons are missing")
runner.check(missingComparisonsSnapshot.quotaRows.isEmpty, "Codex Radar should allow an empty quota radar row list")

runner.check(
    CodexRadarClient.isAllowedPublicSummaryURL(URL(string: "https://codexradar.com/current.json")!),
    "Codex Radar client should allow the public summary URL"
)
runner.check(
    !CodexRadarClient.isAllowedPublicSummaryURL(URL(string: "https://codexradar.com/api/v1/current")!),
    "Codex Radar client should reject the full API URL"
)
runner.check(
    !CodexRadarClient.isAllowedPublicSummaryURL(URL(string: "https://codexradar.com@evil.example.com/current.json")!),
    "Codex Radar client should reject userinfo spoofing"
)
runner.check(
    !CodexRadarClient.isAllowedPublicSummaryURL(URL(string: "http://codexradar.com/current.json")!),
    "Codex Radar client should require HTTPS"
)

let radarCalendar = CodexRadarRefreshPolicy.beijingCalendar
let beforeMorningSlot = dateFromISO8601("2026-07-01T07:00:00+08:00", message: "before morning slot date should parse")
let morningSlot = dateFromISO8601("2026-07-01T08:20:00+08:00", message: "morning slot date should parse")
let afternoonSlot = dateFromISO8601("2026-07-01T14:20:00+08:00", message: "afternoon slot date should parse")
let afterAfternoonSlot = dateFromISO8601("2026-07-01T14:30:00+08:00", message: "after afternoon slot date should parse")
runner.check(
    CodexRadarRefreshPolicy.nextScheduledRefresh(after: beforeMorningSlot, calendar: radarCalendar) == morningSlot,
    "Codex Radar scheduler should use the Beijing 08:20 refresh point"
)
runner.check(
    CodexRadarRefreshPolicy.nextScheduledRefresh(after: morningSlot, calendar: radarCalendar) == afternoonSlot,
    "Codex Radar scheduler should use the Beijing 14:20 refresh point"
)
runner.check(
    CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: nil, now: beforeMorningSlot, calendar: radarCalendar),
    "Codex Radar should refresh on first launch with no cache"
)
runner.check(
    !CodexRadarRefreshPolicy.shouldRefresh(
        lastFetchAt: dateFromISO8601("2026-07-01T08:21:00+08:00", message: "fresh cache date should parse"),
        now: dateFromISO8601("2026-07-01T09:00:00+08:00", message: "after morning date should parse"),
        calendar: radarCalendar
    ),
    "Codex Radar should not refresh when cache is fresh for the latest schedule point"
)
runner.check(
    CodexRadarRefreshPolicy.shouldRefresh(
        lastFetchAt: dateFromISO8601("2026-07-01T08:10:00+08:00", message: "stale morning cache date should parse"),
        now: dateFromISO8601("2026-07-01T09:00:00+08:00", message: "after morning stale date should parse"),
        calendar: radarCalendar
    ),
    "Codex Radar should refresh after crossing the 08:20 schedule point"
)
runner.check(
    CodexRadarRefreshPolicy.shouldRefresh(
        lastFetchAt: dateFromISO8601("2026-07-01T08:21:00+08:00", message: "morning cache date should parse"),
        now: afterAfternoonSlot,
        calendar: radarCalendar
    ),
    "Codex Radar should refresh after crossing the 14:20 schedule point"
)
runner.check(
    !CodexRadarRefreshPolicy.shouldRefresh(
        lastFetchAt: dateFromISO8601("2026-07-01T14:21:00+08:00", message: "fresh afternoon cache date should parse"),
        now: afterAfternoonSlot,
        calendar: radarCalendar
    ),
    "Codex Radar should only refresh once per schedule point"
)
runner.check(
    !CodexRadarRefreshPolicy.canManualRefresh(
        lastManualRefreshAt: beforeMorningSlot,
        now: beforeMorningSlot.addingTimeInterval(299)
    ),
    "Codex Radar manual refresh should enforce a 5 minute gap"
)
runner.check(
    CodexRadarRefreshPolicy.canManualRefresh(
        lastManualRefreshAt: beforeMorningSlot,
        now: beforeMorningSlot.addingTimeInterval(300)
    ),
    "Codex Radar manual refresh should be allowed after 5 minutes"
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
runner.check(RefreshCadence.pendingUsageDelay(for: 30) == 8, "coalesced usage refresh should wait instead of immediately restarting")
runner.check(RefreshCadence.pendingUsageDelay(for: 300) == 15, "coalesced usage refresh should cap long follow-up waits")
runner.check(BalanceRefreshCadence.refreshInterval(base: 300, consecutiveFailures: 0) == 300, "healthy balance refresh should use the configured interval")
runner.check(BalanceRefreshCadence.refreshInterval(base: 300, consecutiveFailures: 1) == 30, "failed balance refresh should retry quickly instead of leaving stale timeout state")
runner.check(BalanceRefreshCadence.refreshInterval(base: 60, consecutiveFailures: 3) == 30, "repeated balance failures should cap retry interval")

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
runner.check(settings.activeRefreshInterval == 30, "saving unchanged refresh intervals should keep the folded low-power active default")
runner.check(settings.idleRefreshInterval == 180, "saving unchanged refresh intervals should keep the folded low-power idle default")
runner.check(settings.usageRefreshInterval == 300, "saving unchanged refresh intervals should keep the low-power usage default")
runner.check(settings.watcherRefreshInterval == 180, "saving unchanged refresh intervals should keep the folded low-power watcher default")
runner.check(settings.fileChangeRefreshMinimumGap == 15, "saving unchanged refresh intervals should keep the folded low-power debounce default")
runner.check(settings.codexRadarEnabled, "Codex Radar should default to enabled")
runner.check(!settings.showSparkQuota, "Spark quota display should default to disabled")
settings.activeRefreshInterval = 2
settings.idleRefreshInterval = 4
settings.usageRefreshInterval = 15
settings.watcherRefreshInterval = 8
settings.fileChangeRefreshMinimumGap = 1
settings.resetRefreshDefaults()
runner.check(settings.activeRefreshInterval == 30, "reset refresh defaults should restore folded low-power active refresh")
runner.check(settings.idleRefreshInterval == 180, "reset refresh defaults should restore folded low-power idle refresh")
runner.check(settings.usageRefreshInterval == 300, "reset refresh defaults should restore low-power usage refresh")
runner.check(settings.watcherRefreshInterval == 180, "reset refresh defaults should restore folded low-power watcher refresh")
runner.check(settings.fileChangeRefreshMinimumGap == 15, "reset refresh defaults should restore folded low-power debounce")

let legacyRefreshSuiteName = "CodexNotchLegacyRefresh-\(UUID().uuidString)"
let legacyRefreshDefaults = runner.require(
    UserDefaults(suiteName: legacyRefreshSuiteName),
    "legacy refresh defaults should be available"
)
legacyRefreshDefaults.removePersistentDomain(forName: legacyRefreshSuiteName)
legacyRefreshDefaults.set(3, forKey: "activeRefreshInterval")
legacyRefreshDefaults.set(6, forKey: "idleRefreshInterval")
legacyRefreshDefaults.set(30, forKey: "usageRefreshInterval")
legacyRefreshDefaults.set(12, forKey: "watcherRefreshInterval")
legacyRefreshDefaults.set(3, forKey: "fileChangeRefreshMinimumGap")
let migratedLegacyRefreshSettings = CodexNotchSettings(
    defaults: legacyRefreshDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(migratedLegacyRefreshSettings.activeRefreshInterval == 30, "legacy refresh defaults should migrate to folded low-power active refresh")
runner.check(migratedLegacyRefreshSettings.idleRefreshInterval == 180, "legacy refresh defaults should migrate to folded low-power idle refresh")
runner.check(migratedLegacyRefreshSettings.usageRefreshInterval == 300, "legacy refresh defaults should migrate to low-power usage refresh")
runner.check(migratedLegacyRefreshSettings.watcherRefreshInterval == 180, "legacy refresh defaults should migrate to folded low-power watcher refresh")
runner.check(migratedLegacyRefreshSettings.fileChangeRefreshMinimumGap == 15, "legacy refresh defaults should migrate to folded low-power debounce")
legacyRefreshDefaults.removePersistentDomain(forName: legacyRefreshSuiteName)

let previousLowPowerSuiteName = "CodexNotchPreviousLowPower-\(UUID().uuidString)"
let previousLowPowerDefaults = runner.require(
    UserDefaults(suiteName: previousLowPowerSuiteName),
    "previous low-power defaults should be available"
)
previousLowPowerDefaults.removePersistentDomain(forName: previousLowPowerSuiteName)
previousLowPowerDefaults.set(15, forKey: "activeRefreshInterval")
previousLowPowerDefaults.set(90, forKey: "idleRefreshInterval")
previousLowPowerDefaults.set(300, forKey: "usageRefreshInterval")
previousLowPowerDefaults.set(120, forKey: "watcherRefreshInterval")
previousLowPowerDefaults.set(10, forKey: "fileChangeRefreshMinimumGap")
let migratedPreviousLowPowerSettings = CodexNotchSettings(
    defaults: previousLowPowerDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(migratedPreviousLowPowerSettings.activeRefreshInterval == 30, "previous low-power defaults should migrate to folded low-power active refresh")
runner.check(migratedPreviousLowPowerSettings.idleRefreshInterval == 180, "previous low-power defaults should migrate to folded low-power idle refresh")
runner.check(migratedPreviousLowPowerSettings.usageRefreshInterval == 300, "previous low-power defaults should migrate to low-power usage refresh")
runner.check(migratedPreviousLowPowerSettings.watcherRefreshInterval == 180, "previous low-power defaults should migrate to folded low-power watcher refresh")
runner.check(migratedPreviousLowPowerSettings.fileChangeRefreshMinimumGap == 15, "previous low-power defaults should migrate to folded low-power debounce")
previousLowPowerDefaults.removePersistentDomain(forName: previousLowPowerSuiteName)

runner.check(settings.remoteCodexDataSource == .cpaManagerPlus, "remote Codex monitor should default to CPA Manager Plus data")
runner.check(settings.notchDisplaySource == .codex, "collapsed notch display should default to local Codex")
settings.codexRadarEnabled = false
settings.showSparkQuota = true
settings.remoteCodexDataSource = .cliProxyAPI
settings.notchDisplaySource = .remoteCodex
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
runner.check(!reloadedSettings.codexRadarEnabled, "Codex Radar enablement should persist")
runner.check(reloadedSettings.showSparkQuota, "Spark quota display preference should persist")
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
    )
]
let currentQuotaMissingAccounts = [
    remoteAccount(id: "preserve-1", state: .healthy, quotaWindows: [])
]
let mergedQuotaAccounts = RemoteCodexAccount.preservingQuota(
    in: currentQuotaMissingAccounts,
    from: previousQuotaAccounts
)
runner.check(mergedQuotaAccounts.first?.quotaSummaryText == "5h 77%", "remote account list merge should preserve previous quota windows when current refresh has none")

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
let dbBackedSessionID = "019e073a-c032-74e2-966e-b85ede0c9cce"
let staleDBTokenSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd2"
let activeToolCallSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd3"
let sparkQuotaSessionID = "019e073a-c032-74e2-966e-b85ede0c9cda"
let sessionDirectory = tempRoot
    .appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
let rolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-00-\(sessionID).jsonl")
let now = Date()
let timestamp = ISO8601DateFormatter().string(from: now)
let rolloutBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"xhigh","collaboration_mode":{"settings":{"reasoning_effort":"xhigh"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"正在运行的 Codex 任务"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":90000}}}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":12345}}}}
"""
try rolloutBody.write(to: rolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: rolloutPath.path)

let subagentRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-01-\(subagentSessionID).jsonl")
let subagentRolloutBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(subagentSessionID)","parent_thread_id":"\(sessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(sessionID)","depth":1,"agent_nickname":"Test","agent_role":"explorer"}}},"thread_source":"subagent","agent_nickname":"Test","agent_role":"explorer"}}
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

let sparkQuotaPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-17-\(sparkQuotaSessionID).jsonl")
let sparkQuotaBody = """
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Spark 额度测试"}]}}
{"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0}},"rate_limits":{"limit_id":"gpt-5.3-codex-spark","primary":{"used_percent":40,"resets_at":1783000000},"secondary":{"used_percent":"10","resets_at":1783400000}}}}
"""
try sparkQuotaBody.write(to: sparkQuotaPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: sparkQuotaPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(sparkQuotaSessionID)', 'Spark 额度测试', 0, 'gpt-5.5', 'high', '\(sparkQuotaPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])

let deltaDirectory = tempRoot.appendingPathComponent("context-guard", isDirectory: true)
try FileManager.default.createDirectory(at: deltaDirectory, withIntermediateDirectories: true)
let deltaDatabase = deltaDirectory.appendingPathComponent("usage-deltas.sqlite").path
let observedNowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
let oneHourBaselineMs = observedNowMs - Int64(61 * 60 * 1_000)
let staleCurrentMs = observedNowMs - Int64(2 * 60 * 60 * 1_000)
let staleBaselineMs = observedNowMs - Int64(3 * 60 * 60 * 1_000)
let staleDeltaSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd8"
let missingBaselineDeltaSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd9"
_ = try Shell.run("/usr/bin/sqlite3", [
    deltaDatabase,
    """
    create table token_snapshots (
      thread_id text primary key,
      tokens_used integer not null,
      updated_at_ms integer not null,
      observed_at_ms integer not null
    );
    create table token_snapshot_history (
      thread_id text not null,
      tokens_used integer not null,
      updated_at_ms integer not null,
      observed_at_ms integer not null,
      primary key(thread_id, observed_at_ms)
    );
    create index idx_token_snapshot_history_lookup
      on token_snapshot_history(thread_id, observed_at_ms desc);
    insert into token_snapshots(thread_id, tokens_used, updated_at_ms, observed_at_ms)
    values
      ('\(sessionID)', 185801, \(observedNowMs), \(observedNowMs)),
      ('\(parentOnlySessionID)', 80245, \(observedNowMs), \(observedNowMs)),
      ('\(staleDeltaSessionID)', 10000, \(staleCurrentMs), \(staleCurrentMs)),
      ('\(missingBaselineDeltaSessionID)', 500, \(observedNowMs), \(observedNowMs));
    insert into token_snapshot_history(thread_id, tokens_used, updated_at_ms, observed_at_ms)
    values
      ('\(sessionID)', 180000, \(oneHourBaselineMs), \(oneHourBaselineMs)),
      ('\(parentOnlySessionID)', 80000, \(oneHourBaselineMs), \(oneHourBaselineMs)),
      ('\(staleDeltaSessionID)', 1000, \(staleBaselineMs), \(staleBaselineMs));
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
runner.check(localSnapshot.usage1h == 6046, "aggregate 1 hour usage should sum all recent delta snapshots")
runner.check(localSnapshot.tasks.first?.delta1hTokens != localSnapshot.usage1h, "aggregate 1 hour usage should not reuse the first visible task delta")
runner.check(localSnapshot.primaryPercent == nil, "local Spark-only JSONL quota should not replace the main 5h quota")
runner.check(localSnapshot.secondaryPercent == nil, "local Spark-only JSONL quota should not replace the main 7d quota")
runner.check(localSnapshot.sparkQuotaWindows.map(\.remainingPercent) == [60, 90], "local JSONL Spark quota windows should decode")
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
runner.check(localSnapshot.tasks.first { $0.id == parentOnlySessionID }?.tokenCount == 80245, "parent running through subagent activity should include subagent token usage")
runner.check(localSnapshot.tasks.first { $0.id == longMetaParentSessionID }?.tokenCount == 33333, "parent running through long metadata subagent activity should include subagent token usage")
runner.check(localSnapshot.tasks.first { $0.id == staleDBTokenSessionID }?.tokenCount == 120000000, "recent task token count should prefer fresher rollout totals over stale database tokens")
runner.check(localSnapshot.tasks.contains { $0.id == activeToolCallSessionID && $0.status == .running }, "quiet tool calls should keep the running indicator on until a task-level completion event arrives")
runner.check(localSnapshot.tasks.first { $0.id == completedSessionID }?.status == .recent, "fresh completed session rollout should not be treated as running")
runner.check(localSnapshot.tasks.first { $0.id == completedFinalAnswerSessionID }?.status == .recent, "fresh final_answer/task_complete rollout should not be treated as running")
runner.check(localSnapshot.tasks.first { $0.id == dbBackedSessionID }?.tokenCount == 777, "recent rollout fallback should reuse database tokens even when the database updated_at is outside the task range")
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
