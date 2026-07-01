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
        static let codexRadarEnabled = "codexRadarEnabled"
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
        static let newAPIAccounts = "newAPIAccounts"
        static let newAPIWarningThreshold = "newAPIWarningThreshold"
        static let newAPIAlertThreshold = "newAPIAlertThreshold"
        static let subAPIMonitorEnabled = "subAPIMonitorEnabled"
        static let subAPIPanelURL = "subAPIPanelURL"
        static let subAPIUsername = "subAPIUsername"
        static let subAPIRefreshInterval = "subAPIRefreshInterval"
        static let subAPIRequestTimeout = "subAPIRequestTimeout"
        static let subAPIAllowInsecureTLS = "subAPIAllowInsecureTLS"
        static let subAPIAccounts = "subAPIAccounts"
        static let subAPIWarningThreshold = "subAPIWarningThreshold"
        static let subAPIAlertThreshold = "subAPIAlertThreshold"
        static let secretStorageMode = "secretStorageMode"
    }

    private let defaults: UserDefaults
    private let launchAtLoginManager: LaunchAtLoginManaging
    private let secretStores: SecretStoreFactory
    private var secretVault: SecretVault
    private var isInitializing = true

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

    @Published var codexRadarEnabled: Bool {
        didSet {
            defaults.set(codexRadarEnabled, forKey: Keys.codexRadarEnabled)
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
            persistBalanceManagementKey(newAPIManagementKey, key: .newAPIManagement, source: .newAPI)
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

    @Published var newAPIAccounts: [BalanceAccountConfiguration] {
        didSet {
            persistBalanceAccounts(newAPIAccounts, oldAccounts: oldValue, source: .newAPI)
        }
    }

    @Published var newAPIThresholds: BalanceThresholdConfiguration {
        didSet {
            persistBalanceThresholds(newAPIThresholds, warningKey: Keys.newAPIWarningThreshold, alertKey: Keys.newAPIAlertThreshold)
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
            persistBalanceManagementKey(subAPIManagementKey, key: .subAPIManagement, source: .subAPI)
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

    @Published var subAPIAccounts: [BalanceAccountConfiguration] {
        didSet {
            persistBalanceAccounts(subAPIAccounts, oldAccounts: oldValue, source: .subAPI)
        }
    }

    @Published var subAPIThresholds: BalanceThresholdConfiguration {
        didSet {
            persistBalanceThresholds(subAPIThresholds, warningKey: Keys.subAPIWarningThreshold, alertKey: Keys.subAPIAlertThreshold)
        }
    }

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var cliproxyKeychainError: String?
    @Published private(set) var newAPIKeychainError: String?
    @Published private(set) var subAPIKeychainError: String?
    @Published private(set) var secretStorageMode: SecretStorageMode
    @Published private(set) var secretStorageError: String?

    init(
        defaults: UserDefaults = .standard,
        initialManagementKey: String? = nil,
        initialNewAPIKey: String? = nil,
        initialSubAPIKey: String? = nil,
        secretStores: SecretStoreFactory = .live(),
        launchAtLoginManager: LaunchAtLoginManaging = SMAppServiceLaunchAtLoginManager()
    ) {
        self.defaults = defaults
        self.launchAtLoginManager = launchAtLoginManager
        self.secretStores = secretStores
        let loadedSecretStorageMode = SecretStorageMode(rawValue: defaults.string(forKey: Keys.secretStorageMode) ?? "") ?? .keychain
        self.secretStorageMode = loadedSecretStorageMode
        var loadedVault = (try? secretStores.store(for: loadedSecretStorageMode).loadVault()) ?? SecretVault()
        var migratedSecretVault = false
        migratedSecretVault = Self.applyInitialOrLegacySecret(
            initialValue: initialManagementKey,
            key: .cliproxyManagement,
            legacyLocations: [(Self.cliproxyKeychainService, Self.cliproxyKeychainAccount)],
            vault: &loadedVault
        ) || migratedSecretVault
        migratedSecretVault = Self.applyInitialOrLegacySecret(
            initialValue: initialNewAPIKey,
            key: .newAPIManagement,
            legacyLocations: [
                (Self.newAPIKeychainService, Self.cliproxyKeychainAccount),
                ("com.alight.codexnotch.newapi.management-key", Self.cliproxyKeychainAccount)
            ],
            vault: &loadedVault
        ) || migratedSecretVault
        migratedSecretVault = Self.applyInitialOrLegacySecret(
            initialValue: initialSubAPIKey,
            key: .subAPIManagement,
            legacyLocations: [(Self.subAPIKeychainService, Self.cliproxyKeychainAccount)],
            vault: &loadedVault
        ) || migratedSecretVault
        self.secretVault = loadedVault
        Self.migrateLegacyRefreshDefaultsIfNeeded(defaults: defaults)
        self.activeRefreshInterval = Self.clamped(defaults.object(forKey: Keys.activeRefreshInterval) as? TimeInterval ?? 30, min: 2, max: 30)
        self.idleRefreshInterval = Self.clamped(defaults.object(forKey: Keys.idleRefreshInterval) as? TimeInterval ?? 180, min: 4, max: 300)
        self.usageRefreshInterval = Self.clamped(defaults.object(forKey: Keys.usageRefreshInterval) as? TimeInterval ?? 300, min: 15, max: 300)
        self.watcherRefreshInterval = Self.clamped(defaults.object(forKey: Keys.watcherRefreshInterval) as? TimeInterval ?? 180, min: 8, max: 300)
        self.fileChangeRefreshMinimumGap = Self.clamped(defaults.object(forKey: Keys.fileChangeRefreshMinimumGap) as? TimeInterval ?? 15, min: 1, max: 30)
        self.rateLimitSource = RateLimitSourcePreference(rawValue: defaults.string(forKey: Keys.rateLimitSource) ?? "") ?? .appServerFirst
        self.showPeriodUsage = defaults.object(forKey: Keys.showPeriodUsage) as? Bool ?? true
        self.codexRadarEnabled = defaults.object(forKey: Keys.codexRadarEnabled) as? Bool ?? true
        self.enablePulse = defaults.object(forKey: Keys.enablePulse) as? Bool ?? true
        self.taskHistoryRange = TaskHistoryRange(rawValue: defaults.string(forKey: Keys.taskHistoryRange) ?? "") ?? .threeDays
        self.notchDisplaySource = NotchDisplaySource(rawValue: defaults.string(forKey: Keys.notchDisplaySource) ?? "") ?? .codex
        self.remoteMonitorEnabled = defaults.object(forKey: Keys.remoteMonitorEnabled) as? Bool ?? false
        self.remoteCodexDataSource = RemoteCodexDataSource(rawValue: defaults.string(forKey: Keys.remoteCodexDataSource) ?? "") ?? .cpaManagerPlus
        self.cliproxyPanelURL = defaults.string(forKey: Keys.cliproxyPanelURL) ?? ""
        self.cliproxyManagementKey = loadedVault.value(for: .cliproxyManagement)
        self.cliproxyRefreshInterval = Self.clamped(defaults.object(forKey: Keys.cliproxyRefreshInterval) as? TimeInterval ?? 60, min: 60, max: 3_600)
        self.cliproxyRequestTimeout = Self.clamped(defaults.object(forKey: Keys.cliproxyRequestTimeout) as? TimeInterval ?? 6, min: 3, max: 30)
        self.cliproxyAllowInsecureTLS = defaults.object(forKey: Keys.cliproxyAllowInsecureTLS) as? Bool ?? false
        self.newAPIMonitorEnabled = defaults.object(forKey: Keys.newAPIMonitorEnabled) as? Bool ?? false
        self.newAPIPanelURL = defaults.string(forKey: Keys.newAPIPanelURL) ?? ""
        self.newAPIManagementKey = loadedVault.value(for: .newAPIManagement)
        self.newAPIUsername = defaults.string(forKey: Keys.newAPIUsername)
            ?? defaults.string(forKey: Keys.newAPIUserID)
            ?? ""
        self.newAPIRefreshInterval = Self.clamped(defaults.object(forKey: Keys.newAPIRefreshInterval) as? TimeInterval ?? 300, min: 60, max: 3_600)
        self.newAPIRequestTimeout = Self.clamped(defaults.object(forKey: Keys.newAPIRequestTimeout) as? TimeInterval ?? 6, min: 3, max: 30)
        self.newAPIAllowInsecureTLS = defaults.object(forKey: Keys.newAPIAllowInsecureTLS) as? Bool ?? false
        self.newAPIAccounts = []
        self.newAPIThresholds = Self.loadBalanceThresholds(
            defaults: defaults,
            warningKey: Keys.newAPIWarningThreshold,
            alertKey: Keys.newAPIAlertThreshold
        )
        self.subAPIMonitorEnabled = defaults.object(forKey: Keys.subAPIMonitorEnabled) as? Bool ?? false
        self.subAPIPanelURL = defaults.string(forKey: Keys.subAPIPanelURL) ?? ""
        self.subAPIUsername = defaults.string(forKey: Keys.subAPIUsername) ?? ""
        self.subAPIManagementKey = loadedVault.value(for: .subAPIManagement)
        self.subAPIRefreshInterval = Self.clamped(defaults.object(forKey: Keys.subAPIRefreshInterval) as? TimeInterval ?? 300, min: 60, max: 3_600)
        self.subAPIRequestTimeout = Self.clamped(defaults.object(forKey: Keys.subAPIRequestTimeout) as? TimeInterval ?? 6, min: 3, max: 30)
        self.subAPIAllowInsecureTLS = defaults.object(forKey: Keys.subAPIAllowInsecureTLS) as? Bool ?? false
        self.subAPIAccounts = []
        self.subAPIThresholds = Self.loadBalanceThresholds(
            defaults: defaults,
            warningKey: Keys.subAPIWarningThreshold,
            alertKey: Keys.subAPIAlertThreshold
        )
        self.launchAtLoginEnabled = launchAtLoginManager.isEnabled
        let loadedNewAPIAccounts = Self.loadBalanceAccounts(
            defaults: defaults,
            key: Keys.newAPIAccounts,
            source: .newAPI,
            vault: &loadedVault,
            legacy: BalanceAccountConfiguration(
                id: "legacy-newapi",
                source: .newAPI,
                enabled: newAPIMonitorEnabled,
                label: "NewAPI",
                panelURL: newAPIPanelURL,
                username: newAPIUsername,
                secret: newAPIManagementKey,
                allowInsecureTLS: newAPIAllowInsecureTLS,
                requestTimeout: newAPIRequestTimeout
            )
        )
        migratedSecretVault = loadedNewAPIAccounts.migratedSecrets || migratedSecretVault
        self.newAPIAccounts = loadedNewAPIAccounts.accounts
        self.newAPIKeychainError = loadedNewAPIAccounts.keychainError
        let loadedSubAPIAccounts = Self.loadBalanceAccounts(
            defaults: defaults,
            key: Keys.subAPIAccounts,
            source: .subAPI,
            vault: &loadedVault,
            legacy: BalanceAccountConfiguration(
                id: "legacy-subapi",
                source: .subAPI,
                enabled: subAPIMonitorEnabled,
                label: "Sub2API",
                panelURL: subAPIPanelURL,
                username: subAPIUsername,
                secret: subAPIManagementKey,
                allowInsecureTLS: subAPIAllowInsecureTLS,
                requestTimeout: subAPIRequestTimeout
            )
        )
        migratedSecretVault = loadedSubAPIAccounts.migratedSecrets || migratedSecretVault
        self.subAPIAccounts = loadedSubAPIAccounts.accounts
        self.subAPIKeychainError = loadedSubAPIAccounts.keychainError
        self.secretVault = loadedVault
        if migratedSecretVault {
            do {
                try secretStores.store(for: secretStorageMode).saveVault(loadedVault)
                self.secretStorageError = nil
            } catch {
                self.secretStorageError = error.localizedDescription
            }
        }
        self.isInitializing = false
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

    func setSecretStorageMode(_ mode: SecretStorageMode) {
        guard mode != secretStorageMode else {
            return
        }
        do {
            try secretStores.store(for: mode).saveVault(secretVault)
            secretStorageMode = mode
            defaults.set(mode.rawValue, forKey: Keys.secretStorageMode)
            secretStorageError = nil
        } catch {
            secretStorageError = error.localizedDescription
        }
    }

    func resetRefreshDefaults() {
        activeRefreshInterval = 30
        idleRefreshInterval = 180
        usageRefreshInterval = 300
        watcherRefreshInterval = 180
        fileChangeRefreshMinimumGap = 15
    }

    private static func migrateLegacyRefreshDefaultsIfNeeded(defaults: UserDefaults) {
        let legacyProfiles: [[(key: String, value: TimeInterval)]] = [
            [
                (Keys.activeRefreshInterval, 3),
                (Keys.idleRefreshInterval, 6),
                (Keys.usageRefreshInterval, 30),
                (Keys.watcherRefreshInterval, 12),
                (Keys.fileChangeRefreshMinimumGap, 3)
            ],
            [
                (Keys.activeRefreshInterval, 15),
                (Keys.idleRefreshInterval, 90),
                (Keys.usageRefreshInterval, 300),
                (Keys.watcherRefreshInterval, 120),
                (Keys.fileChangeRefreshMinimumGap, 10)
            ]
        ]

        guard legacyProfiles.contains(where: { profile in
            profile.allSatisfy { storedTimeInterval(defaults: defaults, key: $0.key) == $0.value }
        }) else {
            return
        }

        defaults.set(30, forKey: Keys.activeRefreshInterval)
        defaults.set(180, forKey: Keys.idleRefreshInterval)
        defaults.set(300, forKey: Keys.usageRefreshInterval)
        defaults.set(180, forKey: Keys.watcherRefreshInterval)
        defaults.set(15, forKey: Keys.fileChangeRefreshMinimumGap)
    }

    private static func storedTimeInterval(defaults: UserDefaults, key: String) -> TimeInterval? {
        guard let number = defaults.object(forKey: key) as? NSNumber else {
            return nil
        }
        return number.doubleValue
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

    private static func loadBalanceThresholds(
        defaults: UserDefaults,
        warningKey: String,
        alertKey: String
    ) -> BalanceThresholdConfiguration {
        BalanceThresholdConfiguration(
            warningThreshold: defaults.object(forKey: warningKey) as? Double,
            alertThreshold: defaults.object(forKey: alertKey) as? Double
        ).normalized
    }

    private static func applyInitialOrLegacySecret(
        initialValue: String?,
        key: SecretKey,
        legacyLocations: [(service: String, account: String)],
        vault: inout SecretVault
    ) -> Bool {
        if let initialValue {
            vault.set(initialValue, for: key)
            return !initialValue.isEmpty
        }
        if !vault.value(for: key).isEmpty {
            return false
        }
        for location in legacyLocations {
            guard let legacyValue = try? KeychainStore.read(service: location.service, account: location.account),
                  !legacyValue.isEmpty else {
                continue
            }
            vault.set(legacyValue, for: key)
            return true
        }
        return false
    }

    private static func loadBalanceAccounts(
        defaults: UserDefaults,
        key: String,
        source: BalanceMonitorSource,
        vault: inout SecretVault,
        legacy: BalanceAccountConfiguration
    ) -> BalanceAccountsLoadResult {
        let hasLegacyConfiguration = legacy.enabled
            || !legacy.panelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !legacy.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !legacy.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let service = balanceAccountKeychainService(for: source)
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([BalanceAccountConfiguration].self, from: data) {
            var keychainErrors: [String] = []
            var migratedSecrets = false
            let accounts = decoded.map { account in
                var copy = account
                copy.source = source
                let secretKey = SecretKey.balanceAccount(source: source, id: copy.id)
                let vaultSecret = vault.value(for: secretKey)
                if !vaultSecret.isEmpty {
                    copy.secret = vaultSecret
                    return copy
                }
                do {
                    let legacySecret = try KeychainStore.read(service: service, account: copy.id)
                    copy.secret = legacySecret
                    if !legacySecret.isEmpty {
                        vault.set(legacySecret, for: secretKey)
                        migratedSecrets = true
                    }
                } catch {
                    copy.secret = ""
                    copy.secretReadFailed = true
                    keychainErrors.append("\(copy.displayLabel)：\(error.localizedDescription)")
                }
                return copy
            }
            return BalanceAccountsLoadResult(
                accounts: accounts,
                keychainError: keychainErrors.isEmpty ? nil : keychainErrors.joined(separator: "；"),
                migratedSecrets: migratedSecrets
            )
        }

        return BalanceAccountsLoadResult(
            accounts: hasLegacyConfiguration ? [legacy] : [],
            keychainError: nil,
            migratedSecrets: false
        )
    }

    private static func balanceAccountKeychainService(for source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            "com.alight.codexnotch.newapi.account-password"
        case .subAPI:
            "com.alight.codexnotch.subapi.account-password"
        }
    }

    func balanceMonitorEnabled(for source: BalanceMonitorSource) -> Bool {
        switch source {
        case .newAPI:
            newAPIMonitorEnabled
        case .subAPI:
            subAPIMonitorEnabled
        }
    }

    func balanceAccounts(for source: BalanceMonitorSource) -> [BalanceAccountConfiguration] {
        switch source {
        case .newAPI:
            newAPIAccounts
        case .subAPI:
            subAPIAccounts
        }
    }

    func setBalanceAccounts(_ accounts: [BalanceAccountConfiguration], for source: BalanceMonitorSource) {
        switch source {
        case .newAPI:
            let currentByID = Dictionary(newAPIAccounts.map { ($0.id, $0) }, uniquingKeysWith: { existing, _ in existing })
            newAPIAccounts = accounts.map { account in
                var copy = account
                copy.source = .newAPI
                return sanitizedBalanceAccount(copy, oldAccount: currentByID[copy.id])
            }
        case .subAPI:
            let currentByID = Dictionary(subAPIAccounts.map { ($0.id, $0) }, uniquingKeysWith: { existing, _ in existing })
            subAPIAccounts = accounts.map { account in
                var copy = account
                copy.source = .subAPI
                return sanitizedBalanceAccount(copy, oldAccount: currentByID[copy.id])
            }
        }
    }

    func balanceDefaultThresholds(for source: BalanceMonitorSource) -> BalanceThresholdConfiguration {
        switch source {
        case .newAPI:
            newAPIThresholds
        case .subAPI:
            subAPIThresholds
        }
    }

    func setBalanceDefaultThresholds(_ thresholds: BalanceThresholdConfiguration, for source: BalanceMonitorSource) {
        switch source {
        case .newAPI:
            newAPIThresholds = thresholds.normalized
        case .subAPI:
            subAPIThresholds = thresholds.normalized
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
        secretVault.set(cliproxyManagementKey, for: .cliproxyManagement)
        do {
            try persistSecretVault()
            cliproxyKeychainError = nil
        } catch {
            cliproxyKeychainError = error.localizedDescription
        }
    }

    private func persistBalanceManagementKey(_ value: String, key: SecretKey, source: BalanceMonitorSource) {
        secretVault.set(value, for: key)
        do {
            try persistSecretVault()
            if source == .newAPI {
                newAPIKeychainError = nil
            } else {
                subAPIKeychainError = nil
            }
        } catch {
            if source == .newAPI {
                newAPIKeychainError = error.localizedDescription
            } else {
                subAPIKeychainError = error.localizedDescription
            }
        }
    }

    private func persistSecretVault() throws {
        try secretStores.store(for: secretStorageMode).saveVault(secretVault)
        secretStorageError = nil
    }

    private func persistBalanceThresholds(
        _ thresholds: BalanceThresholdConfiguration,
        warningKey: String,
        alertKey: String
    ) {
        let normalized = thresholds.normalized
        if let warningThreshold = normalized.warningThreshold {
            defaults.set(warningThreshold, forKey: warningKey)
        } else {
            defaults.removeObject(forKey: warningKey)
        }
        if let alertThreshold = normalized.alertThreshold {
            defaults.set(alertThreshold, forKey: alertKey)
        } else {
            defaults.removeObject(forKey: alertKey)
        }
    }

    private func persistBalanceAccounts(
        _ accounts: [BalanceAccountConfiguration],
        oldAccounts: [BalanceAccountConfiguration],
        source: BalanceMonitorSource
    ) {
        guard !isInitializing else {
            return
        }
        var keychainError: String?
        do {
            for account in accounts {
                if account.secretReadFailed && account.secret.isEmpty {
                    continue
                }
                secretVault.set(account.secret, for: .balanceAccount(source: source, id: account.id))
            }
            let newIDs = Set(accounts.map(\.id))
            for oldAccount in oldAccounts where !newIDs.contains(oldAccount.id) {
                secretVault.removeValue(for: .balanceAccount(source: source, id: oldAccount.id))
            }
            try persistSecretVault()
        } catch {
            keychainError = error.localizedDescription
        }

        do {
            let data = try JSONEncoder().encode(accounts)
            switch source {
            case .newAPI:
                defaults.set(data, forKey: Keys.newAPIAccounts)
                newAPIKeychainError = keychainError
            case .subAPI:
                defaults.set(data, forKey: Keys.subAPIAccounts)
                subAPIKeychainError = keychainError
            }
        } catch {
            switch source {
            case .newAPI:
                newAPIKeychainError = error.localizedDescription
            case .subAPI:
                subAPIKeychainError = error.localizedDescription
            }
        }
    }

    private func sanitizedBalanceAccount(
        _ account: BalanceAccountConfiguration,
        oldAccount: BalanceAccountConfiguration?
    ) -> BalanceAccountConfiguration {
        Self.sanitizedBalanceAccountForSave(account, oldAccount: oldAccount)
    }

    static func sanitizedBalanceAccountForSave(
        _ account: BalanceAccountConfiguration,
        oldAccount: BalanceAccountConfiguration?
    ) -> BalanceAccountConfiguration {
        var copy = account
        copy.requestTimeout = Self.clamped(copy.requestTimeout, min: 3, max: 30)
        if !copy.secret.isEmpty {
            copy.secretReadFailed = false
        }
        guard let oldAccount else {
            return copy
        }
        let originChanged = Self.originChanged(
            oldURL: oldAccount.panelURL,
            newURL: copy.panelURL,
            oldOrigin: Self.apiOrigin(from: oldAccount.panelURL),
            newOrigin: Self.apiOrigin(from: copy.panelURL)
        )
        let tlsModeChanged = oldAccount.allowInsecureTLS != copy.allowInsecureTLS
        if (originChanged || tlsModeChanged), copy.secret == oldAccount.secret {
            copy.secret = ""
            copy.secretReadFailed = false
        }
        return copy
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
            max: 300,
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
            max: 300,
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

private struct BalanceAccountsLoadResult {
    let accounts: [BalanceAccountConfiguration]
    let keychainError: String?
    let migratedSecrets: Bool
}
