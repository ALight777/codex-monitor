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
    nonisolated static let cliproxyKeychainService = "com.alight.codexnotch.cliproxy.management-key"
    nonisolated static let cliproxyKeychainAccount = "default"
    nonisolated static let newAPIKeychainService = "com.alight.codexnotch.newapi.password"
    nonisolated static let subAPIKeychainService = "com.alight.codexnotch.subapi.password"

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
    private var isApplyingSecretVault = false
    private var secretConfigurationRevision = 0

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
            markSecretConfigurationEdited()
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
            if oldValue != cliproxyAllowInsecureTLS {
                markSecretConfigurationEdited()
            }
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
            markSecretConfigurationEdited()
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
            markSecretConfigurationEdited()
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
            if oldValue != newAPIAllowInsecureTLS {
                markSecretConfigurationEdited()
            }
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
            markSecretConfigurationEdited()
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
            markSecretConfigurationEdited()
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
            if oldValue != subAPIAllowInsecureTLS {
                markSecretConfigurationEdited()
            }
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
        launchAtLoginManager: LaunchAtLoginManaging = SMAppServiceLaunchAtLoginManager(),
        loadSecretsSynchronously: Bool = true
    ) {
        self.defaults = defaults
        self.launchAtLoginManager = launchAtLoginManager
        self.secretStores = secretStores
        let loadedSecretStorageMode = SecretStorageMode(rawValue: defaults.string(forKey: Keys.secretStorageMode) ?? "") ?? .keychain
        self.secretStorageMode = loadedSecretStorageMode
        let secretLoad = Self.loadSecrets(
            defaults: defaults,
            mode: loadedSecretStorageMode,
            secretStores: secretStores,
            initialManagementKey: initialManagementKey,
            initialNewAPIKey: initialNewAPIKey,
            initialSubAPIKey: initialSubAPIKey,
            includeLegacyKeychain: loadSecretsSynchronously
        )
        let loadedVault = secretLoad.vault
        let migratedSecretVault = secretLoad.migratedSecretVault
        self.secretVault = loadedVault
        self.activeRefreshInterval = Self.clamped(defaults.object(forKey: Keys.activeRefreshInterval) as? TimeInterval ?? 3, min: 2, max: 30)
        self.idleRefreshInterval = Self.clamped(defaults.object(forKey: Keys.idleRefreshInterval) as? TimeInterval ?? 6, min: 4, max: 120)
        self.usageRefreshInterval = Self.clamped(defaults.object(forKey: Keys.usageRefreshInterval) as? TimeInterval ?? 300, min: 120, max: 1_800)
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
        self.newAPIAccounts = secretLoad.newAPIAccounts.accounts
        self.newAPIKeychainError = secretLoad.newAPIAccounts.keychainError
        self.subAPIAccounts = secretLoad.subAPIAccounts.accounts
        self.subAPIKeychainError = secretLoad.subAPIAccounts.keychainError
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
        if !loadSecretsSynchronously {
            loadSecretsInBackground(
                initialManagementKey: initialManagementKey,
                initialNewAPIKey: initialNewAPIKey,
                initialSubAPIKey: initialSubAPIKey
            )
        }
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
        activeRefreshInterval = 3
        idleRefreshInterval = 6
        usageRefreshInterval = 300
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

    nonisolated private static func loadSecrets(
        defaults: UserDefaults,
        mode: SecretStorageMode,
        secretStores: SecretStoreFactory,
        initialManagementKey: String?,
        initialNewAPIKey: String?,
        initialSubAPIKey: String?,
        includeLegacyKeychain: Bool
    ) -> SecretLoadResult {
        var loadedVault = (try? secretStores.store(for: mode).loadVault()) ?? SecretVault()
        var migratedSecretVault = false
        migratedSecretVault = applyInitialOrLegacySecret(
            initialValue: initialManagementKey,
            key: .cliproxyManagement,
            legacyLocations: [(cliproxyKeychainService, cliproxyKeychainAccount)],
            vault: &loadedVault,
            includeLegacyKeychain: includeLegacyKeychain
        ) || migratedSecretVault
        migratedSecretVault = applyInitialOrLegacySecret(
            initialValue: initialNewAPIKey,
            key: .newAPIManagement,
            legacyLocations: [
                (newAPIKeychainService, cliproxyKeychainAccount),
                ("com.alight.codexnotch.newapi.management-key", cliproxyKeychainAccount)
            ],
            vault: &loadedVault,
            includeLegacyKeychain: includeLegacyKeychain
        ) || migratedSecretVault
        migratedSecretVault = applyInitialOrLegacySecret(
            initialValue: initialSubAPIKey,
            key: .subAPIManagement,
            legacyLocations: [(subAPIKeychainService, cliproxyKeychainAccount)],
            vault: &loadedVault,
            includeLegacyKeychain: includeLegacyKeychain
        ) || migratedSecretVault

        let newAPIEnabled = defaults.object(forKey: Keys.newAPIMonitorEnabled) as? Bool ?? false
        let newAPIPanelURL = defaults.string(forKey: Keys.newAPIPanelURL) ?? ""
        let newAPIUsername = defaults.string(forKey: Keys.newAPIUsername)
            ?? defaults.string(forKey: Keys.newAPIUserID)
            ?? ""
        let newAPIManagementKey = loadedVault.value(for: .newAPIManagement)
        let newAPIAllowInsecureTLS = defaults.object(forKey: Keys.newAPIAllowInsecureTLS) as? Bool ?? false
        let newAPIRequestTimeout = clamped(defaults.object(forKey: Keys.newAPIRequestTimeout) as? TimeInterval ?? 6, min: 3, max: 30)
        let loadedNewAPIAccounts = loadBalanceAccounts(
            defaults: defaults,
            key: Keys.newAPIAccounts,
            source: .newAPI,
            vault: &loadedVault,
            legacy: BalanceAccountConfiguration(
                id: "legacy-newapi",
                source: .newAPI,
                enabled: newAPIEnabled,
                label: "NewAPI",
                panelURL: newAPIPanelURL,
                username: newAPIUsername,
                secret: newAPIManagementKey,
                allowInsecureTLS: newAPIAllowInsecureTLS,
                requestTimeout: newAPIRequestTimeout
            ),
            includeLegacyKeychain: includeLegacyKeychain
        )
        migratedSecretVault = loadedNewAPIAccounts.migratedSecrets || migratedSecretVault

        let subAPIEnabled = defaults.object(forKey: Keys.subAPIMonitorEnabled) as? Bool ?? false
        let subAPIPanelURL = defaults.string(forKey: Keys.subAPIPanelURL) ?? ""
        let subAPIUsername = defaults.string(forKey: Keys.subAPIUsername) ?? ""
        let subAPIManagementKey = loadedVault.value(for: .subAPIManagement)
        let subAPIAllowInsecureTLS = defaults.object(forKey: Keys.subAPIAllowInsecureTLS) as? Bool ?? false
        let subAPIRequestTimeout = clamped(defaults.object(forKey: Keys.subAPIRequestTimeout) as? TimeInterval ?? 6, min: 3, max: 30)
        let loadedSubAPIAccounts = loadBalanceAccounts(
            defaults: defaults,
            key: Keys.subAPIAccounts,
            source: .subAPI,
            vault: &loadedVault,
            legacy: BalanceAccountConfiguration(
                id: "legacy-subapi",
                source: .subAPI,
                enabled: subAPIEnabled,
                label: "Sub2API",
                panelURL: subAPIPanelURL,
                username: subAPIUsername,
                secret: subAPIManagementKey,
                allowInsecureTLS: subAPIAllowInsecureTLS,
                requestTimeout: subAPIRequestTimeout
            ),
            includeLegacyKeychain: includeLegacyKeychain
        )
        migratedSecretVault = loadedSubAPIAccounts.migratedSecrets || migratedSecretVault

        return SecretLoadResult(
            vault: loadedVault,
            migratedSecretVault: migratedSecretVault,
            newAPIAccounts: loadedNewAPIAccounts,
            subAPIAccounts: loadedSubAPIAccounts
        )
    }

    private func loadSecretsInBackground(
        initialManagementKey: String?,
        initialNewAPIKey: String?,
        initialSubAPIKey: String?
    ) {
        let defaults = SendableUserDefaults(self.defaults)
        let mode = secretStorageMode
        let revision = secretConfigurationRevision
        let secretStores = self.secretStores
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.loadSecrets(
                defaults: defaults.value,
                mode: mode,
                secretStores: secretStores,
                initialManagementKey: initialManagementKey,
                initialNewAPIKey: initialNewAPIKey,
                initialSubAPIKey: initialSubAPIKey,
                includeLegacyKeychain: true
            )
            DispatchQueue.main.async {
                self?.applySecretLoadResult(result, mode: mode, revision: revision)
            }
        }
    }

    private func applySecretLoadResult(_ result: SecretLoadResult, mode: SecretStorageMode, revision: Int) {
        guard mode == secretStorageMode,
              revision == secretConfigurationRevision else {
            return
        }

        isApplyingSecretVault = true
        secretVault = result.vault
        cliproxyManagementKey = result.vault.value(for: .cliproxyManagement)
        newAPIManagementKey = result.vault.value(for: .newAPIManagement)
        subAPIManagementKey = result.vault.value(for: .subAPIManagement)
        newAPIAccounts = result.newAPIAccounts.accounts
        newAPIKeychainError = result.newAPIAccounts.keychainError
        subAPIAccounts = result.subAPIAccounts.accounts
        subAPIKeychainError = result.subAPIAccounts.keychainError
        isApplyingSecretVault = false

        guard result.migratedSecretVault else {
            return
        }
        do {
            try secretStores.store(for: secretStorageMode).saveVault(result.vault)
            secretStorageError = nil
        } catch {
            secretStorageError = error.localizedDescription
        }
    }

    nonisolated private static func applyInitialOrLegacySecret(
        initialValue: String?,
        key: SecretKey,
        legacyLocations: [(service: String, account: String)],
        vault: inout SecretVault,
        includeLegacyKeychain: Bool = true
    ) -> Bool {
        if let initialValue {
            vault.set(initialValue, for: key)
            return !initialValue.isEmpty
        }
        if !vault.value(for: key).isEmpty {
            return false
        }
        guard includeLegacyKeychain else {
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

    nonisolated private static func loadBalanceAccounts(
        defaults: UserDefaults,
        key: String,
        source: BalanceMonitorSource,
        vault: inout SecretVault,
        legacy: BalanceAccountConfiguration,
        includeLegacyKeychain: Bool = true
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
                guard includeLegacyKeychain else {
                    copy.secret = ""
                    copy.secretReadFailed = false
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

    nonisolated private static func balanceAccountKeychainService(for source: BalanceMonitorSource) -> String {
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

    private func markSecretConfigurationEdited() {
        guard !isInitializing && !isApplyingSecretVault else {
            return
        }
        secretConfigurationRevision += 1
    }

    private func persistCliproxyManagementKey() {
        guard !isInitializing && !isApplyingSecretVault else {
            return
        }
        markSecretConfigurationEdited()
        secretVault.set(cliproxyManagementKey, for: .cliproxyManagement)
        do {
            try persistSecretVault()
            cliproxyKeychainError = nil
        } catch {
            cliproxyKeychainError = error.localizedDescription
        }
    }

    private func persistBalanceManagementKey(_ value: String, key: SecretKey, source: BalanceMonitorSource) {
        guard !isInitializing && !isApplyingSecretVault else {
            return
        }
        markSecretConfigurationEdited()
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
        guard !isInitializing && !isApplyingSecretVault else {
            return
        }
        markSecretConfigurationEdited()
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
            min: 120,
            max: 1_800,
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

    nonisolated private static func clamped(_ value: TimeInterval, min: TimeInterval, max: TimeInterval) -> TimeInterval {
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

private struct SecretLoadResult {
    let vault: SecretVault
    let migratedSecretVault: Bool
    let newAPIAccounts: BalanceAccountsLoadResult
    let subAPIAccounts: BalanceAccountsLoadResult
}

private struct SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}
