import Foundation
import ServiceManagement

protocol LaunchAtLoginManaging {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

private struct SMAppServiceLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class CodexNotchSettings: ObservableObject {
    static let cliproxyKeychainService = "com.alight.codexnotch.cliproxy.management-key"
    static let cliproxyKeychainAccount = "default"
    static let newAPIKeychainService = "com.alight.codexnotch.newapi.password"
    static let subAPIKeychainService = "com.alight.codexnotch.subapi.password"

    private enum Keys {
        static let activeRefreshInterval = "activeRefreshInterval"
        static let idleRefreshInterval = "idleRefreshInterval"
        static let usageRefreshInterval = "usageRefreshInterval"
        static let watcherRefreshInterval = "watcherRefreshInterval"
        static let fileChangeRefreshMinimumGap = "fileChangeRefreshMinimumGap"
        static let rateLimitSource = "rateLimitSource"
        static let showPeriodUsage = "showPeriodUsage"
        static let enablePulse = "enablePulse"
        static let taskHistoryRange = "taskHistoryRange"
        static let notchDisplaySource = "notchDisplaySource"
        static let remoteMonitorEnabled = "remoteMonitorEnabled"
        static let remoteCodexDataSource = "remoteCodexDataSource"
        static let cliproxyPanelURL = "cliproxyPanelURL"
        static let cliproxyRefreshInterval = "cliproxyRefreshInterval"
        static let cliproxyRequestTimeout = "cliproxyRequestTimeout"
        static let cliproxyAllowInsecureTLS = "cliproxyAllowInsecureTLS"
        static let newAPIMonitorEnabled = "newAPIMonitorEnabled"
        static let newAPIPanelURL = "newAPIPanelURL"
        static let newAPIUsername = "newAPIUsername"
        static let newAPIUserID = "newAPIUserID"
        static let newAPIRefreshInterval = "newAPIRefreshInterval"
        static let newAPIRequestTimeout = "newAPIRequestTimeout"
        static let newAPIAllowInsecureTLS = "newAPIAllowInsecureTLS"
        static let subAPIMonitorEnabled = "subAPIMonitorEnabled"
        static let subAPIPanelURL = "subAPIPanelURL"
        static let subAPIUsername = "subAPIUsername"
        static let subAPIRefreshInterval = "subAPIRefreshInterval"
        static let subAPIRequestTimeout = "subAPIRequestTimeout"
        static let subAPIAllowInsecureTLS = "subAPIAllowInsecureTLS"
    }

    private let defaults: UserDefaults
    private let launchAtLoginManager: LaunchAtLoginManaging

    @Published var activeRefreshInterval: TimeInterval {
        didSet {
            normalizeActiveRefreshInterval()
        }
    }

    @Published var idleRefreshInterval: TimeInterval {
        didSet {
            normalizeIdleRefreshInterval()
        }
    }

    @Published var usageRefreshInterval: TimeInterval {
        didSet {
            normalizeUsageRefreshInterval()
        }
    }

    @Published var watcherRefreshInterval: TimeInterval {
        didSet {
            normalizeWatcherRefreshInterval()
        }
    }

    @Published var fileChangeRefreshMinimumGap: TimeInterval {
        didSet {
            normalizeFileChangeRefreshMinimumGap()
        }
    }

    @Published var rateLimitSource: RateLimitSourcePreference {
        didSet {
            defaults.set(rateLimitSource.rawValue, forKey: Keys.rateLimitSource)
        }
    }

    @Published var showPeriodUsage: Bool {
        didSet {
            defaults.set(showPeriodUsage, forKey: Keys.showPeriodUsage)
        }
    }

    @Published var enablePulse: Bool {
        didSet {
            defaults.set(enablePulse, forKey: Keys.enablePulse)
        }
    }

    @Published var taskHistoryRange: TaskHistoryRange {
        didSet {
            defaults.set(taskHistoryRange.rawValue, forKey: Keys.taskHistoryRange)
        }
    }

    @Published var notchDisplaySource: NotchDisplaySource {
        didSet {
            defaults.set(notchDisplaySource.rawValue, forKey: Keys.notchDisplaySource)
        }
    }

    @Published var remoteMonitorEnabled: Bool {
        didSet {
            defaults.set(remoteMonitorEnabled, forKey: Keys.remoteMonitorEnabled)
        }
    }

    @Published var remoteCodexDataSource: RemoteCodexDataSource {
        didSet {
            defaults.set(remoteCodexDataSource.rawValue, forKey: Keys.remoteCodexDataSource)
        }
    }

    @Published var cliproxyPanelURL: String {
        didSet {
            let trimmed = cliproxyPanelURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if cliproxyPanelURL != trimmed {
                cliproxyPanelURL = trimmed
                return
            }
            if Self.managementOrigin(from: oldValue) != Self.managementOrigin(from: trimmed),
               !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !cliproxyManagementKey.isEmpty {
                cliproxyManagementKey = ""
            }
            defaults.set(trimmed, forKey: Keys.cliproxyPanelURL)
        }
    }

    @Published var cliproxyManagementKey: String {
        didSet {
            persistCliproxyManagementKey()
        }
    }

    @Published var cliproxyRefreshInterval: TimeInterval {
        didSet {
            normalizeCliproxyRefreshInterval()
        }
    }

    @Published var cliproxyRequestTimeout: TimeInterval {
        didSet {
            normalizeCliproxyRequestTimeout()
        }
    }

    @Published var cliproxyAllowInsecureTLS: Bool {
        didSet {
            if oldValue != cliproxyAllowInsecureTLS, !cliproxyManagementKey.isEmpty {
                cliproxyManagementKey = ""
            }
            defaults.set(cliproxyAllowInsecureTLS, forKey: Keys.cliproxyAllowInsecureTLS)
        }
    }

    @Published var newAPIMonitorEnabled: Bool {
        didSet {
            defaults.set(newAPIMonitorEnabled, forKey: Keys.newAPIMonitorEnabled)
        }
    }

    @Published var newAPIPanelURL: String {
        didSet {
            let trimmed = newAPIPanelURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if newAPIPanelURL != trimmed {
                newAPIPanelURL = trimmed
                return
            }
            if Self.apiOrigin(from: oldValue) != Self.apiOrigin(from: trimmed),
               !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !newAPIManagementKey.isEmpty {
                newAPIManagementKey = ""
            }
            defaults.set(trimmed, forKey: Keys.newAPIPanelURL)
        }
    }

    @Published var newAPIManagementKey: String {
        didSet {
            persistBalanceManagementKey(newAPIManagementKey, service: Self.newAPIKeychainService)
        }
    }

    @Published var newAPIUsername: String {
        didSet {
            let trimmed = newAPIUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            if newAPIUsername != trimmed {
                newAPIUsername = trimmed
                return
            }
            defaults.set(trimmed, forKey: Keys.newAPIUsername)
        }
    }

    @Published var newAPIRefreshInterval: TimeInterval {
        didSet {
            normalizeNewAPIRefreshInterval()
        }
    }

    @Published var newAPIRequestTimeout: TimeInterval {
        didSet {
            normalizeNewAPIRequestTimeout()
        }
    }

    @Published var newAPIAllowInsecureTLS: Bool {
        didSet {
            if oldValue != newAPIAllowInsecureTLS, !newAPIManagementKey.isEmpty {
                newAPIManagementKey = ""
            }
            defaults.set(newAPIAllowInsecureTLS, forKey: Keys.newAPIAllowInsecureTLS)
        }
    }

    @Published var subAPIMonitorEnabled: Bool {
        didSet {
            defaults.set(subAPIMonitorEnabled, forKey: Keys.subAPIMonitorEnabled)
        }
    }

    @Published var subAPIPanelURL: String {
        didSet {
            let trimmed = subAPIPanelURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if subAPIPanelURL != trimmed {
                subAPIPanelURL = trimmed
                return
            }
            if Self.apiOrigin(from: oldValue) != Self.apiOrigin(from: trimmed),
               !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !subAPIManagementKey.isEmpty {
                subAPIManagementKey = ""
            }
            defaults.set(trimmed, forKey: Keys.subAPIPanelURL)
        }
    }

    @Published var subAPIManagementKey: String {
        didSet {
            persistBalanceManagementKey(subAPIManagementKey, service: Self.subAPIKeychainService)
        }
    }

    @Published var subAPIUsername: String {
        didSet {
            let trimmed = subAPIUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            if subAPIUsername != trimmed {
                subAPIUsername = trimmed
                return
            }
            defaults.set(trimmed, forKey: Keys.subAPIUsername)
        }
    }

    @Published var subAPIRefreshInterval: TimeInterval {
        didSet {
            normalizeSubAPIRefreshInterval()
        }
    }

    @Published var subAPIRequestTimeout: TimeInterval {
        didSet {
            normalizeSubAPIRequestTimeout()
        }
    }

    @Published var subAPIAllowInsecureTLS: Bool {
        didSet {
            if oldValue != subAPIAllowInsecureTLS, !subAPIManagementKey.isEmpty {
                subAPIManagementKey = ""
            }
            defaults.set(subAPIAllowInsecureTLS, forKey: Keys.subAPIAllowInsecureTLS)
        }
    }

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var cliproxyKeychainError: String?
    @Published private(set) var newAPIKeychainError: String?
    @Published private(set) var subAPIKeychainError: String?

    init(
        defaults: UserDefaults = .standard,
        initialManagementKey: String? = nil,
        initialNewAPIKey: String? = nil,
        initialSubAPIKey: String? = nil,
        launchAtLoginManager: LaunchAtLoginManaging = SMAppServiceLaunchAtLoginManager()
    ) {
        self.defaults = defaults
        self.launchAtLoginManager = launchAtLoginManager
        self.activeRefreshInterval = Self.clamped(defaults.object(forKey: Keys.activeRefreshInterval) as? TimeInterval ?? 3, min: 2, max: 30)
        self.idleRefreshInterval = Self.clamped(defaults.object(forKey: Keys.idleRefreshInterval) as? TimeInterval ?? 6, min: 4, max: 120)
        self.usageRefreshInterval = Self.clamped(defaults.object(forKey: Keys.usageRefreshInterval) as? TimeInterval ?? 30, min: 15, max: 300)
        self.watcherRefreshInterval = Self.clamped(defaults.object(forKey: Keys.watcherRefreshInterval) as? TimeInterval ?? 12, min: 8, max: 120)
        self.fileChangeRefreshMinimumGap = Self.clamped(defaults.object(forKey: Keys.fileChangeRefreshMinimumGap) as? TimeInterval ?? 3, min: 1, max: 30)
        self.rateLimitSource = RateLimitSourcePreference(rawValue: defaults.string(forKey: Keys.rateLimitSource) ?? "") ?? .appServerFirst
        self.showPeriodUsage = defaults.object(forKey: Keys.showPeriodUsage) as? Bool ?? true
        self.enablePulse = defaults.object(forKey: Keys.enablePulse) as? Bool ?? true
        self.taskHistoryRange = TaskHistoryRange(rawValue: defaults.string(forKey: Keys.taskHistoryRange) ?? "") ?? .threeDays
        self.notchDisplaySource = NotchDisplaySource(rawValue: defaults.string(forKey: Keys.notchDisplaySource) ?? "") ?? .codex
        self.remoteMonitorEnabled = defaults.object(forKey: Keys.remoteMonitorEnabled) as? Bool ?? false
        self.remoteCodexDataSource = RemoteCodexDataSource(rawValue: defaults.string(forKey: Keys.remoteCodexDataSource) ?? "") ?? .cpaManagerPlus
        self.cliproxyPanelURL = defaults.string(forKey: Keys.cliproxyPanelURL) ?? ""
        self.cliproxyManagementKey = initialManagementKey ?? ((try? KeychainStore.read(
            service: Self.cliproxyKeychainService,
            account: Self.cliproxyKeychainAccount
        )) ?? "")
        self.cliproxyRefreshInterval = Self.clamped(defaults.object(forKey: Keys.cliproxyRefreshInterval) as? TimeInterval ?? 60, min: 60, max: 3_600)
        self.cliproxyRequestTimeout = Self.clamped(defaults.object(forKey: Keys.cliproxyRequestTimeout) as? TimeInterval ?? 6, min: 3, max: 30)
        self.cliproxyAllowInsecureTLS = defaults.object(forKey: Keys.cliproxyAllowInsecureTLS) as? Bool ?? false
        self.newAPIMonitorEnabled = defaults.object(forKey: Keys.newAPIMonitorEnabled) as? Bool ?? false
        self.newAPIPanelURL = defaults.string(forKey: Keys.newAPIPanelURL) ?? ""
        self.newAPIManagementKey = initialNewAPIKey ?? ((try? KeychainStore.read(
            service: Self.newAPIKeychainService,
            account: Self.cliproxyKeychainAccount
        )) ?? ((try? KeychainStore.read(
            service: "com.alight.codexnotch.newapi.management-key",
            account: Self.cliproxyKeychainAccount
        )) ?? ""))
        self.newAPIUsername = defaults.string(forKey: Keys.newAPIUsername)
            ?? defaults.string(forKey: Keys.newAPIUserID)
            ?? ""
        self.newAPIRefreshInterval = Self.clamped(defaults.object(forKey: Keys.newAPIRefreshInterval) as? TimeInterval ?? 300, min: 60, max: 3_600)
        self.newAPIRequestTimeout = Self.clamped(defaults.object(forKey: Keys.newAPIRequestTimeout) as? TimeInterval ?? 6, min: 3, max: 30)
        self.newAPIAllowInsecureTLS = defaults.object(forKey: Keys.newAPIAllowInsecureTLS) as? Bool ?? false
        self.subAPIMonitorEnabled = defaults.object(forKey: Keys.subAPIMonitorEnabled) as? Bool ?? false
        self.subAPIPanelURL = defaults.string(forKey: Keys.subAPIPanelURL) ?? ""
        self.subAPIUsername = defaults.string(forKey: Keys.subAPIUsername) ?? ""
        self.subAPIManagementKey = initialSubAPIKey ?? ((try? KeychainStore.read(
            service: Self.subAPIKeychainService,
            account: Self.cliproxyKeychainAccount
        )) ?? "")
        self.subAPIRefreshInterval = Self.clamped(defaults.object(forKey: Keys.subAPIRefreshInterval) as? TimeInterval ?? 300, min: 60, max: 3_600)
        self.subAPIRequestTimeout = Self.clamped(defaults.object(forKey: Keys.subAPIRequestTimeout) as? TimeInterval ?? 6, min: 3, max: 30)
        self.subAPIAllowInsecureTLS = defaults.object(forKey: Keys.subAPIAllowInsecureTLS) as? Bool ?? false
        self.launchAtLoginEnabled = launchAtLoginManager.isEnabled
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLoginManager.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }

        launchAtLoginEnabled = launchAtLoginManager.isEnabled
    }

    func resetRefreshDefaults() {
        activeRefreshInterval = 3
        idleRefreshInterval = 6
        usageRefreshInterval = 30
        watcherRefreshInterval = 12
        fileChangeRefreshMinimumGap = 3
    }

    static func managementKeyForSave(
        draftKey: String,
        oldPanelURL: String,
        newPanelURL: String,
        oldAllowsInsecureTLS: Bool,
        newAllowsInsecureTLS: Bool,
        remoteEnabled: Bool,
        oldDataSource: RemoteCodexDataSource? = nil,
        newDataSource: RemoteCodexDataSource? = nil,
        oldSavedKey: String? = nil
    ) -> String {
        guard remoteEnabled else {
            return ""
        }

        let oldOrigin = managementOrigin(from: oldPanelURL)
        let newOrigin = managementOrigin(from: newPanelURL)
        let originChanged = originChanged(
            oldURL: oldPanelURL,
            newURL: newPanelURL,
            oldOrigin: oldOrigin,
            newOrigin: newOrigin
        )
        let tlsModeChanged = oldAllowsInsecureTLS != newAllowsInsecureTLS
        let sourceChanged = oldDataSource != nil && newDataSource != nil && oldDataSource != newDataSource
        guard !originChanged, !tlsModeChanged, !sourceChanged else {
            if let oldSavedKey,
               !draftKey.isEmpty,
               draftKey != oldSavedKey {
                return draftKey
            }
            return ""
        }

        return draftKey
    }

    static func apiKeyForSave(
        draftKey: String,
        oldPanelURL: String,
        newPanelURL: String,
        oldAllowsInsecureTLS: Bool,
        newAllowsInsecureTLS: Bool,
        enabled: Bool,
        oldSavedKey: String? = nil
    ) -> String {
        guard enabled else {
            return ""
        }

        let oldOrigin = apiOrigin(from: oldPanelURL)
        let newOrigin = apiOrigin(from: newPanelURL)
        let originChanged = originChanged(
            oldURL: oldPanelURL,
            newURL: newPanelURL,
            oldOrigin: oldOrigin,
            newOrigin: newOrigin
        )
        let tlsModeChanged = oldAllowsInsecureTLS != newAllowsInsecureTLS
        guard !originChanged, !tlsModeChanged else {
            if let oldSavedKey,
               !draftKey.isEmpty,
               draftKey != oldSavedKey {
                return draftKey
            }
            return ""
        }

        return draftKey
    }

    func balanceMonitorEnabled(for source: BalanceMonitorSource) -> Bool {
        switch source {
        case .newAPI:
            newAPIMonitorEnabled
        case .subAPI:
            subAPIMonitorEnabled
        }
    }

    func balancePanelURL(for source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            newAPIPanelURL
        case .subAPI:
            subAPIPanelURL
        }
    }

    func balanceManagementKey(for source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            newAPIManagementKey
        case .subAPI:
            subAPIManagementKey
        }
    }

    func balanceUsername(for source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            newAPIUsername
        case .subAPI:
            subAPIUsername
        }
    }

    func balanceRefreshInterval(for source: BalanceMonitorSource) -> TimeInterval {
        switch source {
        case .newAPI:
            newAPIRefreshInterval
        case .subAPI:
            subAPIRefreshInterval
        }
    }

    func balanceRequestTimeout(for source: BalanceMonitorSource) -> TimeInterval {
        switch source {
        case .newAPI:
            newAPIRequestTimeout
        case .subAPI:
            subAPIRequestTimeout
        }
    }

    func balanceAllowInsecureTLS(for source: BalanceMonitorSource) -> Bool {
        switch source {
        case .newAPI:
            newAPIAllowInsecureTLS
        case .subAPI:
            subAPIAllowInsecureTLS
        }
    }

    private func persistCliproxyManagementKey() {
        do {
            try KeychainStore.write(
                cliproxyManagementKey,
                service: Self.cliproxyKeychainService,
                account: Self.cliproxyKeychainAccount
            )
            cliproxyKeychainError = nil
        } catch {
            cliproxyKeychainError = error.localizedDescription
        }
    }

    private func persistBalanceManagementKey(_ key: String, service: String) {
        do {
            try KeychainStore.write(
                key,
                service: service,
                account: Self.cliproxyKeychainAccount
            )
            if service == Self.newAPIKeychainService {
                newAPIKeychainError = nil
            } else {
                subAPIKeychainError = nil
            }
        } catch {
            if service == Self.newAPIKeychainService {
                newAPIKeychainError = error.localizedDescription
            } else {
                subAPIKeychainError = error.localizedDescription
            }
        }
    }

    private func normalizeActiveRefreshInterval() {
        let value = normalized(
            activeRefreshInterval,
            min: 2,
            max: 30,
            key: Keys.activeRefreshInterval
        )
        if activeRefreshInterval != value {
            activeRefreshInterval = value
        }
    }

    private func normalizeIdleRefreshInterval() {
        let value = normalized(
            idleRefreshInterval,
            min: 4,
            max: 120,
            key: Keys.idleRefreshInterval
        )
        if idleRefreshInterval != value {
            idleRefreshInterval = value
        }
    }

    private func normalizeUsageRefreshInterval() {
        let value = normalized(
            usageRefreshInterval,
            min: 15,
            max: 300,
            key: Keys.usageRefreshInterval
        )
        if usageRefreshInterval != value {
            usageRefreshInterval = value
        }
    }

    private func normalizeWatcherRefreshInterval() {
        let value = normalized(
            watcherRefreshInterval,
            min: 8,
            max: 120,
            key: Keys.watcherRefreshInterval
        )
        if watcherRefreshInterval != value {
            watcherRefreshInterval = value
        }
    }

    private func normalizeFileChangeRefreshMinimumGap() {
        let value = normalized(
            fileChangeRefreshMinimumGap,
            min: 1,
            max: 30,
            key: Keys.fileChangeRefreshMinimumGap
        )
        if fileChangeRefreshMinimumGap != value {
            fileChangeRefreshMinimumGap = value
        }
    }

    private func normalizeCliproxyRefreshInterval() {
        let value = normalized(
            cliproxyRefreshInterval,
            min: 60,
            max: 3_600,
            key: Keys.cliproxyRefreshInterval
        )
        if cliproxyRefreshInterval != value {
            cliproxyRefreshInterval = value
        }
    }

    private func normalizeCliproxyRequestTimeout() {
        let value = normalized(
            cliproxyRequestTimeout,
            min: 3,
            max: 30,
            key: Keys.cliproxyRequestTimeout
        )
        if cliproxyRequestTimeout != value {
            cliproxyRequestTimeout = value
        }
    }

    private func normalizeNewAPIRefreshInterval() {
        let value = normalized(
            newAPIRefreshInterval,
            min: 60,
            max: 3_600,
            key: Keys.newAPIRefreshInterval
        )
        if newAPIRefreshInterval != value {
            newAPIRefreshInterval = value
        }
    }

    private func normalizeNewAPIRequestTimeout() {
        let value = normalized(
            newAPIRequestTimeout,
            min: 3,
            max: 30,
            key: Keys.newAPIRequestTimeout
        )
        if newAPIRequestTimeout != value {
            newAPIRequestTimeout = value
        }
    }

    private func normalizeSubAPIRefreshInterval() {
        let value = normalized(
            subAPIRefreshInterval,
            min: 60,
            max: 3_600,
            key: Keys.subAPIRefreshInterval
        )
        if subAPIRefreshInterval != value {
            subAPIRefreshInterval = value
        }
    }

    private func normalizeSubAPIRequestTimeout() {
        let value = normalized(
            subAPIRequestTimeout,
            min: 3,
            max: 30,
            key: Keys.subAPIRequestTimeout
        )
        if subAPIRequestTimeout != value {
            subAPIRequestTimeout = value
        }
    }

    private func normalized(
        _ value: TimeInterval,
        min: TimeInterval,
        max: TimeInterval,
        key: String
    ) -> TimeInterval {
        let normalized = Self.clamped(value, min: min, max: max)
        defaults.set(normalized, forKey: key)
        return normalized
    }

    private static func clamped(_ value: TimeInterval, min: TimeInterval, max: TimeInterval) -> TimeInterval {
        Swift.min(max, Swift.max(min, value.rounded()))
    }

    private static func originChanged(
        oldURL: String,
        newURL: String,
        oldOrigin: String?,
        newOrigin: String?
    ) -> Bool {
        let oldText = oldURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldText != newText else {
            return false
        }
        guard !oldText.isEmpty else {
            return false
        }
        if let oldOrigin, let newOrigin {
            return oldOrigin != newOrigin
        }
        return true
    }

    private static func managementOrigin(from input: String) -> String? {
        guard let url = CLIProxyAPIClient.managementBaseURL(from: input),
              let scheme = url.scheme,
              let host = url.host else {
            return nil
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }

    private static func apiOrigin(from input: String) -> String? {
        guard let url = BalanceAPIClient.apiBaseURL(from: input),
              let scheme = url.scheme,
              let host = url.host else {
            return nil
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }
}
