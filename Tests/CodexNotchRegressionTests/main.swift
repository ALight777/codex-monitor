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

runner.check(RefreshCadence.pendingSnapshotDelay(for: 2) == 1, "coalesced snapshot refresh should wait at least one second")
runner.check(RefreshCadence.pendingSnapshotDelay(for: 6) == 3, "coalesced snapshot refresh should cap short follow-up waits")
runner.check(RefreshCadence.pendingUsageDelay(for: 30) == 8, "coalesced usage refresh should wait instead of immediately restarting")
runner.check(RefreshCadence.pendingUsageDelay(for: 300) == 15, "coalesced usage refresh should cap long follow-up waits")

let settingsSuiteName = "CodexNotchRegressionTests-\(UUID().uuidString)"
let settingsDefaults = runner.require(
    UserDefaults(suiteName: settingsSuiteName),
    "settings regression defaults should be available"
)
settingsDefaults.removePersistentDomain(forName: settingsSuiteName)
let settings = CodexNotchSettings(
    defaults: settingsDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
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

runner.check(settings.remoteCodexDataSource == .cpaManagerPlus, "remote Codex monitor should default to CPA Manager Plus data")
runner.check(settings.notchDisplaySource == .codex, "collapsed notch display should default to local Codex")
settings.remoteCodexDataSource = .cliProxyAPI
settings.notchDisplaySource = .remoteCodex
settings.newAPIMonitorEnabled = true
settings.newAPIPanelURL = "https://newapi.example.com"
settings.newAPIUsername = "owner"
settings.newAPIRefreshInterval = 180
settings.subAPIMonitorEnabled = true
settings.subAPIPanelURL = "https://subapi.example.com"
settings.subAPIRefreshInterval = 240
let reloadedSettings = CodexNotchSettings(
    defaults: settingsDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(reloadedSettings.remoteCodexDataSource == .cliProxyAPI, "remote Codex data source should persist")
runner.check(reloadedSettings.notchDisplaySource == .remoteCodex, "collapsed notch display source should persist")
runner.check(reloadedSettings.newAPIMonitorEnabled, "NewAPI monitor enablement should persist")
runner.check(reloadedSettings.newAPIPanelURL == "https://newapi.example.com", "NewAPI panel URL should persist")
runner.check(reloadedSettings.newAPIUsername == "owner", "NewAPI username should persist")
runner.check(reloadedSettings.subAPIMonitorEnabled, "SubAPI monitor enablement should persist")
runner.check(reloadedSettings.subAPIPanelURL == "https://subapi.example.com", "SubAPI panel URL should persist")
settingsDefaults.removePersistentDomain(forName: settingsSuiteName)

let shellTimeoutStart = Date()
do {
    _ = try Shell.run("/bin/sh", ["-c", "sleep 2"], timeout: 0.2)
    runner.check(false, "shell timeout should stop a stuck command")
} catch {
    runner.check(Date().timeIntervalSince(shellTimeoutStart) < 1.5, "shell timeout should return promptly")
}

let resistantShellTimeoutStart = Date()
do {
    _ = try Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
    runner.check(false, "shell timeout should stop a SIGTERM-resistant command")
} catch {
    runner.check(Date().timeIntervalSince(resistantShellTimeoutStart) < 1.0, "shell timeout should not wait indefinitely after SIGTERM fails")
}

runner.check(CLIProxyAPIClient.managementBaseURL(from: "http://example.com:8317/management.html") == nil, "external plain HTTP panel URL must be rejected")

let newAPIBaseURL = runner.require(
    BalanceAPIClient.apiBaseURL(from: "https://newapi.example.com/admin"),
    "NewAPI-compatible panel URL should normalize"
)
runner.check(newAPIBaseURL.absoluteString == "https://newapi.example.com", "NewAPI-compatible base URL should use the origin")

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
try BalanceAPIClient.validateNewAPILoginResponse(newAPILoginResponse)

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

let subAPIHeaders = try BalanceAPIClient.authenticationHeaders(
    for: BalanceAPIConfiguration(
        panelURL: "https://subapi.example.com",
        username: "",
        secret: "admin-token",
        timeout: 6,
        allowInsecureTLS: false
    ),
    source: .subAPI
)
runner.check(subAPIHeaders["x-api-key"] == "admin-token", "SubAPI should use x-api-key admin authentication")
runner.check(subAPIHeaders["Authorization"] == nil, "SubAPI admin API key should not be sent as bearer authorization")
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
    "quota": 1234567,
    "used_quota": 34567,
    "request_count": 42,
    "status": 1
  }
}
""".data(using: .utf8)!
let userBalanceAccount = try BalanceAPIClient.decodeUserAccount(
    newAPIUserPayload,
    source: .newAPI
)
runner.check(userBalanceAccount.displayName == "Owner", "NewAPI self account should prefer display_name")
runner.check(userBalanceAccount.amountText == Formatters.compactTokens(1_234_567), "NewAPI self account quota should decode as balance text")
runner.check(userBalanceAccount.detailText.contains("请求 42"), "NewAPI self account should include request count")

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

let subAPIUsersPayload = """
{
  "code": 0,
  "message": "success",
  "data": {
    "items": [
      {
        "id": 101,
        "email": "active@example.com",
        "username": "active",
        "role": "user",
        "balance": 12.5,
        "concurrency": 3,
        "status": "active"
      },
      {
        "id": 102,
        "email": "disabled@example.com",
        "username": "disabled",
        "role": "user",
        "balance": "0.25",
        "concurrency": 1,
        "status": "disabled"
      }
    ],
    "total": 2,
    "page": 1,
    "page_size": 100,
    "pages": 1
  }
}
""".data(using: .utf8)!
let subAPIAccounts = try BalanceAPIClient.decodeSubAPIUserAccounts(subAPIUsersPayload)
runner.check(subAPIAccounts.count == 2, "SubAPI user list should decode user balances")
runner.check(subAPIAccounts[0].displayName == "active@example.com", "SubAPI user balance should prefer email")
runner.check(subAPIAccounts[0].amountText == "$12.50", "SubAPI user balance should format as currency")
runner.check(subAPIAccounts[1].state == .warning, "disabled SubAPI user should become a warning balance account")

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
          "used_percent": 0,
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
runner.check(localSnapshot.tasks.first { $0.id == parentOnlySessionID }?.tokenCount == 80245, "parent running through subagent activity should include subagent token usage")
runner.check(localSnapshot.tasks.first { $0.id == longMetaParentSessionID }?.tokenCount == 33333, "parent running through long metadata subagent activity should include subagent token usage")
runner.check(localSnapshot.tasks.first { $0.id == staleDBTokenSessionID }?.tokenCount == 120000000, "recent task token count should prefer fresher rollout totals over stale database tokens")
runner.check(localSnapshot.tasks.first { $0.id == completedSessionID }?.status == .recent, "fresh completed session rollout should not be treated as running")
runner.check(localSnapshot.tasks.first { $0.id == completedFinalAnswerSessionID }?.status == .recent, "fresh final_answer/task_complete rollout should not be treated as running")
runner.check(localSnapshot.tasks.first { $0.id == dbBackedSessionID }?.tokenCount == 777, "recent rollout fallback should reuse database tokens even when the database updated_at is outside the task range")

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
