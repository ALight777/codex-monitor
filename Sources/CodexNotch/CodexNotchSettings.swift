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
        static let showSparkQuota = "showSparkQuota"
        static let codexRadarEnabled = "codexRadarEnabled"
        static let enablePulse = "enablePulse"
        static let taskHistoryRange = "taskHistoryRange"
        static let notchDisplaySource = "notchDisplaySource"
        static let notchDisplaySize = "notchDisplaySize"
        static let notchWidthAdjustment = "notchWidthAdjustment"
        static let remoteMonitorEnabled = "remoteMonitorEnabled"
        static let remoteCodexDataSource = "remoteCodexDataSource"
        static let cliproxyPanelURL = "cliproxyPanelURL"
        static let remoteAccountSources = "remoteAccountSources"
        static let remoteAccountSourcesMigrationVersion = "remoteAccountSourcesMigrationVersion"
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
        static let legacyKeychainMigrationVersion = "legacyKeychainMigrationVersion"
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

    @Published var showSparkQuota: Bool {
        didSet {
            defaults.set(showSparkQuota, forKey: Keys.showSparkQuota)
        }
    }

    @Published var codexRadarEnabled: Bool {
        didSet {
            defaults.set(codexRadarEnabled, forKey: Keys.codexRadarEnabled)
        }
    }

    @Published var codexRadarAPIToken: String {
        didSet {
            persistCodexRadarAPIToken(codexRadarAPIToken)
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

    @Published var notchDisplaySize: NotchDisplaySize {
        didSet {
            defaults.set(notchDisplaySize.rawValue, forKey: Keys.notchDisplaySize)
        }
    }

    @Published var notchWidthAdjustment: NotchPointAdjustment {
        didSet {
            normalizeNotchWidthAdjustment()
        }
    }

    @Published var remoteMonitorEnabled: Bool {
        didSet {
            defaults.set(remoteMonitorEnabled, forKey: Keys.remoteMonitorEnabled)
        }
    }

    @Published var remoteAccountSources: [RemoteAccountSourceConfiguration] {
        didSet {
            persistRemoteAccountSources(remoteAccountSources, oldSources: oldValue)
        }
    }

    @Published var cliproxyRefreshInterval: TimeInterval {
        didSet {
            normalizeCliproxyRefreshInterval()
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
    @Published private(set) var codexRadarTokenError: String?
    @Published private(set) var secretStorageMode: SecretStorageMode
    @Published private(set) var secretStorageError: String?
    @Published private(set) var secretStoreReady: Bool

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
        self.secretStoreReady = loadSecretsSynchronously
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
        self.showSparkQuota = defaults.object(forKey: Keys.showSparkQuota) as? Bool ?? false
        self.codexRadarEnabled = defaults.object(forKey: Keys.codexRadarEnabled) as? Bool ?? false
        self.codexRadarAPIToken = loadedVault.value(for: .codexRadarAPI)
        self.enablePulse = defaults.object(forKey: Keys.enablePulse) as? Bool ?? true
        self.taskHistoryRange = TaskHistoryRange(rawValue: defaults.string(forKey: Keys.taskHistoryRange) ?? "") ?? .threeDays
        self.notchDisplaySource = NotchDisplaySource(rawValue: defaults.string(forKey: Keys.notchDisplaySource) ?? "") ?? .codex
        self.notchDisplaySize = NotchDisplaySize(rawValue: defaults.string(forKey: Keys.notchDisplaySize) ?? "") ?? .standard
        self.notchWidthAdjustment = Self.clamped(
            defaults.object(forKey: Keys.notchWidthAdjustment) as? NotchPointAdjustment ?? 0,
            min: -NotchPointAdjustment(IslandMetrics.notchAdjustmentLimit),
            max: NotchPointAdjustment(IslandMetrics.notchAdjustmentLimit)
        )
        self.remoteMonitorEnabled = defaults.object(forKey: Keys.remoteMonitorEnabled) as? Bool ?? false
        self.remoteAccountSources = []
        self.cliproxyRefreshInterval = Self.clamped(defaults.object(forKey: Keys.cliproxyRefreshInterval) as? TimeInterval ?? 60, min: 60, max: 3_600)
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
        self.remoteAccountSources = secretLoad.remoteAccountSources.sources
        if let remoteError = secretLoad.remoteAccountSources.keychainError {
            self.cliproxyKeychainError = remoteError
        }
        self.secretVault = loadedVault
        if loadSecretsSynchronously,
           secretLoad.remoteAccountSources.needsConfigurationPersistence {
            Self.persistMigratedRemoteAccountSources(
                secretLoad.remoteAccountSources.sources,
                defaults: defaults
            )
        }
        var persistedLegacyMigration = !migratedSecretVault
        if migratedSecretVault {
            do {
                try secretStores.store(for: secretStorageMode).saveVault(loadedVault)
                self.secretStorageError = nil
                persistedLegacyMigration = true
            } catch {
                self.secretStorageError = error.localizedDescription
            }
        }
        if secretLoad.legacyKeychainMigrationAttempted, persistedLegacyMigration {
            defaults.set(1, forKey: Keys.legacyKeychainMigrationVersion)
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
        let shouldMigrateLegacyKeychain = includeLegacyKeychain
            && defaults.integer(forKey: Keys.legacyKeychainMigrationVersion) < 1
        let shouldReadLegacyRemoteKeychain = shouldMigrateLegacyKeychain
            && defaults.data(forKey: Keys.remoteAccountSources) == nil
            && defaults.integer(forKey: Keys.remoteAccountSourcesMigrationVersion) < 1
        let shouldReadLegacyNewAPIKeychain = shouldMigrateLegacyKeychain
            && defaults.data(forKey: Keys.newAPIAccounts) == nil
        let shouldReadLegacySubAPIKeychain = shouldMigrateLegacyKeychain
            && defaults.data(forKey: Keys.subAPIAccounts) == nil
        migratedSecretVault = applyInitialOrLegacySecret(
            initialValue: initialManagementKey,
            key: .cliproxyManagement,
            legacyLocations: [(cliproxyKeychainService, cliproxyKeychainAccount)],
            vault: &loadedVault,
            includeLegacyKeychain: shouldReadLegacyRemoteKeychain
        ) || migratedSecretVault
        migratedSecretVault = applyInitialOrLegacySecret(
            initialValue: initialNewAPIKey,
            key: .newAPIManagement,
            legacyLocations: [
                (newAPIKeychainService, cliproxyKeychainAccount),
                ("com.alight.codexnotch.newapi.management-key", cliproxyKeychainAccount)
            ],
            vault: &loadedVault,
            includeLegacyKeychain: shouldReadLegacyNewAPIKeychain
        ) || migratedSecretVault
        migratedSecretVault = applyInitialOrLegacySecret(
            initialValue: initialSubAPIKey,
            key: .subAPIManagement,
            legacyLocations: [(subAPIKeychainService, cliproxyKeychainAccount)],
            vault: &loadedVault,
            includeLegacyKeychain: shouldReadLegacySubAPIKeychain
        ) || migratedSecretVault

        let legacyRemoteSource = RemoteCodexDataSource(
            rawValue: defaults.string(forKey: Keys.remoteCodexDataSource) ?? ""
        ) ?? .cpaManagerPlus
        let compatibleLegacyRemoteSource: RemoteCodexDataSource =
            legacyRemoteSource == .cliProxyAPI ? .cliProxyAPI : .cpaManagerPlus
        let legacyRemote = RemoteAccountSourceConfiguration(
            id: "legacy-remote-account-source",
            source: compatibleLegacyRemoteSource,
            enabled: true,
            label: compatibleLegacyRemoteSource.label,
            panelURL: defaults.string(forKey: Keys.cliproxyPanelURL) ?? "",
            username: "",
            secret: loadedVault.value(for: .cliproxyManagement),
            allowInsecureTLS: defaults.object(forKey: Keys.cliproxyAllowInsecureTLS) as? Bool ?? false,
            requestTimeout: clamped(
                defaults.object(forKey: Keys.cliproxyRequestTimeout) as? TimeInterval ?? 6,
                min: 3,
                max: 30
            )
        )
        let loadedRemoteAccountSources = loadRemoteAccountSources(
            defaults: defaults,
            vault: &loadedVault,
            legacy: legacyRemote,
            includeLegacyKeychain: shouldMigrateLegacyKeychain
        )
        migratedSecretVault = loadedRemoteAccountSources.migratedSecrets || migratedSecretVault

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
            includeLegacyKeychain: shouldMigrateLegacyKeychain
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
            includeLegacyKeychain: shouldMigrateLegacyKeychain
        )
        migratedSecretVault = loadedSubAPIAccounts.migratedSecrets || migratedSecretVault

        return SecretLoadResult(
            vault: loadedVault,
            migratedSecretVault: migratedSecretVault,
            legacyKeychainMigrationAttempted: shouldMigrateLegacyKeychain,
            remoteAccountSources: loadedRemoteAccountSources,
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
        defer {
            secretStoreReady = true
        }
        guard mode == secretStorageMode,
              revision == secretConfigurationRevision else {
            return
        }

        isApplyingSecretVault = true
        secretVault = result.vault
        remoteAccountSources = result.remoteAccountSources.sources
        if let remoteError = result.remoteAccountSources.keychainError {
            cliproxyKeychainError = remoteError
        }
        newAPIManagementKey = result.vault.value(for: .newAPIManagement)
        subAPIManagementKey = result.vault.value(for: .subAPIManagement)
        codexRadarAPIToken = result.vault.value(for: .codexRadarAPI)
        newAPIAccounts = result.newAPIAccounts.accounts
        newAPIKeychainError = result.newAPIAccounts.keychainError
        subAPIAccounts = result.subAPIAccounts.accounts
        subAPIKeychainError = result.subAPIAccounts.keychainError
        isApplyingSecretVault = false

        if result.remoteAccountSources.needsConfigurationPersistence {
            Self.persistMigratedRemoteAccountSources(
                result.remoteAccountSources.sources,
                defaults: defaults
            )
        }

        var persistedLegacyMigration = !result.migratedSecretVault
        if result.migratedSecretVault {
            do {
                try secretStores.store(for: secretStorageMode).saveVault(result.vault)
                secretStorageError = nil
                persistedLegacyMigration = true
            } catch {
                secretStorageError = error.localizedDescription
            }
        }
        if result.legacyKeychainMigrationAttempted, persistedLegacyMigration {
            defaults.set(1, forKey: Keys.legacyKeychainMigrationVersion)
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

    nonisolated private static func loadRemoteAccountSources(
        defaults: UserDefaults,
        vault: inout SecretVault,
        legacy: RemoteAccountSourceConfiguration,
        includeLegacyKeychain: Bool
    ) -> RemoteAccountSourcesLoadResult {
        if let data = defaults.data(forKey: Keys.remoteAccountSources) {
            guard let decoded = try? JSONDecoder().decode(
                [RemoteAccountSourceConfiguration].self,
                from: data
            ) else {
                return RemoteAccountSourcesLoadResult(
                    sources: [],
                    keychainError: "远程账号配置损坏，已停止加载旧配置",
                    migratedSecrets: false,
                    needsConfigurationPersistence: false
                )
            }
            var errors: [String] = []
            var migratedSecrets = false
            let sources = decoded.map { source in
                var copy = source
                let secretKey = SecretKey.remoteAccountSource(id: copy.id)
                let bindingKey = SecretKey.remoteAccountSourceBinding(id: copy.id)
                let expectedBinding = copy.credentialBindingID
                let vaultSecret = vault.value(for: secretKey)
                if !vaultSecret.isEmpty {
                    guard let expectedBinding else {
                        copy.secret = ""
                        copy.secretReadFailed = true
                        errors.append("\(copy.displayLabel)：面板地址无效，已阻止读取认证信息")
                        return copy
                    }
                    let storedBinding = vault.value(for: bindingKey)
                    if storedBinding.isEmpty {
                        vault.set(expectedBinding, for: bindingKey)
                        migratedSecrets = true
                    } else if storedBinding != expectedBinding {
                        copy.secret = ""
                        copy.secretReadFailed = true
                        errors.append("\(copy.displayLabel)：服务器或账号已变更，请重新输入认证信息")
                        return copy
                    }
                    copy.secret = vaultSecret
                    return copy
                }
                guard includeLegacyKeychain else {
                    copy.secret = ""
                    copy.secretReadFailed = false
                    return copy
                }
                do {
                    let legacySecret = try KeychainStore.read(
                        service: "com.alight.codexnotch.remote-account-source",
                        account: copy.id
                    )
                    if !legacySecret.isEmpty, let expectedBinding {
                        copy.secret = legacySecret
                        vault.set(legacySecret, for: secretKey)
                        vault.set(expectedBinding, for: bindingKey)
                        migratedSecrets = true
                    } else if !legacySecret.isEmpty {
                        copy.secret = ""
                        copy.secretReadFailed = true
                        errors.append("\(copy.displayLabel)：面板地址无效，未迁移认证信息")
                    }
                } catch {
                    copy.secret = ""
                    copy.secretReadFailed = true
                    errors.append("\(copy.displayLabel)：\(error.localizedDescription)")
                }
                return copy
            }
            return RemoteAccountSourcesLoadResult(
                sources: sources,
                keychainError: errors.isEmpty ? nil : errors.joined(separator: "；"),
                migratedSecrets: migratedSecrets,
                needsConfigurationPersistence: false
            )
        }

        if defaults.integer(forKey: Keys.remoteAccountSourcesMigrationVersion) >= 1 {
            return RemoteAccountSourcesLoadResult(
                sources: [],
                keychainError: nil,
                migratedSecrets: false,
                needsConfigurationPersistence: false
            )
        }

        let hasLegacyConfiguration = !legacy.panelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !legacy.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !legacy.secret.isEmpty
        guard hasLegacyConfiguration else {
            return RemoteAccountSourcesLoadResult(
                sources: [],
                keychainError: nil,
                migratedSecrets: false,
                needsConfigurationPersistence: true
            )
        }

        var migrated = legacy
        if !migrated.secret.isEmpty, let binding = migrated.credentialBindingID {
            vault.set(migrated.secret, for: .remoteAccountSource(id: migrated.id))
            vault.set(binding, for: .remoteAccountSourceBinding(id: migrated.id))
            vault.removeValue(for: .cliproxyManagement)
        } else if !migrated.secret.isEmpty {
            migrated.secret = ""
            migrated.secretReadFailed = true
        }
        return RemoteAccountSourcesLoadResult(
            sources: [migrated],
            keychainError: nil,
            migratedSecrets: !migrated.secret.isEmpty,
            needsConfigurationPersistence: true
        )
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
                let bindingKey = SecretKey.balanceAccountBinding(source: source, id: copy.id)
                let expectedBinding = copy.credentialBindingID
                let vaultSecret = vault.value(for: secretKey)
                if !vaultSecret.isEmpty {
                    guard let expectedBinding else {
                        copy.secret = ""
                        copy.secretReadFailed = true
                        keychainErrors.append("\(copy.displayLabel)：面板地址无效，已阻止读取认证信息")
                        return copy
                    }
                    let storedBinding = vault.value(for: bindingKey)
                    if storedBinding.isEmpty {
                        vault.set(expectedBinding, for: bindingKey)
                        migratedSecrets = true
                    } else if storedBinding != expectedBinding {
                        copy.secret = ""
                        copy.secretReadFailed = true
                        keychainErrors.append("\(copy.displayLabel)：服务器或账号已变更，请重新输入认证信息")
                        return copy
                    }
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
                    if !legacySecret.isEmpty, let expectedBinding {
                        copy.secret = legacySecret
                        vault.set(legacySecret, for: secretKey)
                        vault.set(expectedBinding, for: bindingKey)
                        migratedSecrets = true
                    } else if !legacySecret.isEmpty {
                        copy.secret = ""
                        copy.secretReadFailed = true
                        keychainErrors.append("\(copy.displayLabel)：面板地址无效，未迁移认证信息")
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

        var migratedLegacy = legacy
        var migratedSecret = false
        if hasLegacyConfiguration,
           !migratedLegacy.secret.isEmpty,
           let binding = migratedLegacy.credentialBindingID {
            vault.set(
                migratedLegacy.secret,
                for: .balanceAccount(source: source, id: migratedLegacy.id)
            )
            vault.set(
                binding,
                for: .balanceAccountBinding(source: source, id: migratedLegacy.id)
            )
            migratedSecret = true
        } else if hasLegacyConfiguration, !migratedLegacy.secret.isEmpty {
            migratedLegacy.secret = ""
            migratedLegacy.secretReadFailed = true
        }
        return BalanceAccountsLoadResult(
            accounts: hasLegacyConfiguration ? [migratedLegacy] : [],
            keychainError: nil,
            migratedSecrets: migratedSecret
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

    func setRemoteAccountSources(_ sources: [RemoteAccountSourceConfiguration]) {
        let currentByID = Dictionary(
            remoteAccountSources.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        remoteAccountSources = sources.map { source in
            Self.sanitizedRemoteAccountSourceForSave(
                source,
                oldSource: currentByID[source.id]
            )
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

    private func persistCodexRadarAPIToken(_ value: String) {
        guard !isInitializing && !isApplyingSecretVault else {
            return
        }
        markSecretConfigurationEdited()
        secretVault.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: .codexRadarAPI)
        do {
            try persistSecretVault()
            codexRadarTokenError = nil
        } catch {
            codexRadarTokenError = error.localizedDescription
        }
    }

    private func persistSecretVault(_ vault: SecretVault? = nil) throws {
        try secretStores.store(for: secretStorageMode).saveVault(vault ?? secretVault)
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
        do {
            let data = try JSONEncoder().encode(accounts)
            var candidateVault = secretVault
            for account in accounts {
                if account.secretReadFailed && account.secret.isEmpty {
                    continue
                }
                let secretKey = SecretKey.balanceAccount(source: source, id: account.id)
                let bindingKey = SecretKey.balanceAccountBinding(source: source, id: account.id)
                if account.secret.isEmpty {
                    candidateVault.removeValue(for: secretKey)
                    candidateVault.removeValue(for: bindingKey)
                } else {
                    guard let binding = account.credentialBindingID else {
                        throw SecretConfigurationPersistenceError.invalidBinding(account.displayLabel)
                    }
                    candidateVault.set(account.secret, for: secretKey)
                    candidateVault.set(binding, for: bindingKey)
                }
            }
            let newIDs = Set(accounts.map(\.id))
            for oldAccount in oldAccounts where !newIDs.contains(oldAccount.id) {
                candidateVault.removeValue(for: .balanceAccount(source: source, id: oldAccount.id))
                candidateVault.removeValue(for: .balanceAccountBinding(source: source, id: oldAccount.id))
            }
            try persistSecretVault(candidateVault)
            secretVault = candidateVault
            switch source {
            case .newAPI:
                defaults.set(data, forKey: Keys.newAPIAccounts)
                newAPIKeychainError = nil
            case .subAPI:
                defaults.set(data, forKey: Keys.subAPIAccounts)
                subAPIKeychainError = nil
            }
        } catch {
            switch source {
            case .newAPI:
                newAPIKeychainError = error.localizedDescription
            case .subAPI:
                subAPIKeychainError = error.localizedDescription
            }
            isApplyingSecretVault = true
            switch source {
            case .newAPI:
                newAPIAccounts = oldAccounts
            case .subAPI:
                subAPIAccounts = oldAccounts
            }
            isApplyingSecretVault = false
        }
    }

    private func persistRemoteAccountSources(
        _ sources: [RemoteAccountSourceConfiguration],
        oldSources: [RemoteAccountSourceConfiguration]
    ) {
        guard !isInitializing && !isApplyingSecretVault else {
            return
        }
        markSecretConfigurationEdited()
        do {
            let data = try JSONEncoder().encode(sources)
            var candidateVault = secretVault
            for source in sources {
                if source.secretReadFailed && source.secret.isEmpty {
                    continue
                }
                let secretKey = SecretKey.remoteAccountSource(id: source.id)
                let bindingKey = SecretKey.remoteAccountSourceBinding(id: source.id)
                if source.secret.isEmpty {
                    candidateVault.removeValue(for: secretKey)
                    candidateVault.removeValue(for: bindingKey)
                } else {
                    guard let binding = source.credentialBindingID else {
                        throw SecretConfigurationPersistenceError.invalidBinding(source.displayLabel)
                    }
                    candidateVault.set(source.secret, for: secretKey)
                    candidateVault.set(binding, for: bindingKey)
                }
            }
            let newIDs = Set(sources.map(\.id))
            for oldSource in oldSources where !newIDs.contains(oldSource.id) {
                candidateVault.removeValue(for: .remoteAccountSource(id: oldSource.id))
                candidateVault.removeValue(for: .remoteAccountSourceBinding(id: oldSource.id))
            }
            if !sources.isEmpty {
                candidateVault.removeValue(for: .cliproxyManagement)
            }
            try persistSecretVault(candidateVault)
            secretVault = candidateVault
            defaults.set(data, forKey: Keys.remoteAccountSources)
            defaults.set(1, forKey: Keys.remoteAccountSourcesMigrationVersion)
            cliproxyKeychainError = nil
        } catch {
            cliproxyKeychainError = error.localizedDescription
            isApplyingSecretVault = true
            remoteAccountSources = oldSources
            isApplyingSecretVault = false
        }
    }

    nonisolated private static func persistMigratedRemoteAccountSources(
        _ sources: [RemoteAccountSourceConfiguration],
        defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(sources) else {
            return
        }
        defaults.set(data, forKey: Keys.remoteAccountSources)
        defaults.set(1, forKey: Keys.remoteAccountSourcesMigrationVersion)
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
        let principalChanged = oldAccount.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(
                copy.username.trimmingCharacters(in: .whitespacesAndNewlines)
            ) != .orderedSame
        if (originChanged || tlsModeChanged || principalChanged),
           copy.secret == oldAccount.secret {
            copy.secret = ""
            copy.secretReadFailed = false
        }
        return copy
    }

    static func sanitizedRemoteAccountSourceForSave(
        _ source: RemoteAccountSourceConfiguration,
        oldSource: RemoteAccountSourceConfiguration?
    ) -> RemoteAccountSourceConfiguration {
        var copy = source
        copy.requestTimeout = clamped(copy.requestTimeout, min: 3, max: 30)
        copy.panelURL = copy.panelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = copy.username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.label = copy.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !copy.secret.isEmpty {
            copy.secretReadFailed = false
        }
        guard let oldSource else {
            return copy
        }
        let originChanged = originChanged(
            oldURL: oldSource.panelURL,
            newURL: copy.panelURL,
            oldOrigin: apiOrigin(from: oldSource.panelURL),
            newOrigin: apiOrigin(from: copy.panelURL)
        )
        let tlsModeChanged = oldSource.allowInsecureTLS != copy.allowInsecureTLS
        let providerChanged = oldSource.source != copy.source
        let principalChanged = oldSource.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(copy.username) != .orderedSame
        if (originChanged || tlsModeChanged || providerChanged || principalChanged),
           copy.secret == oldSource.secret {
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

    private func normalizeNotchWidthAdjustment() {
        let value = normalized(
            notchWidthAdjustment,
            min: -NotchPointAdjustment(IslandMetrics.notchAdjustmentLimit),
            max: NotchPointAdjustment(IslandMetrics.notchAdjustmentLimit),
            key: Keys.notchWidthAdjustment
        )
        if notchWidthAdjustment != value {
            notchWidthAdjustment = value
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

private struct RemoteAccountSourcesLoadResult {
    let sources: [RemoteAccountSourceConfiguration]
    let keychainError: String?
    let migratedSecrets: Bool
    let needsConfigurationPersistence: Bool
}

private struct SecretLoadResult {
    let vault: SecretVault
    let migratedSecretVault: Bool
    let legacyKeychainMigrationAttempted: Bool
    let remoteAccountSources: RemoteAccountSourcesLoadResult
    let newAPIAccounts: BalanceAccountsLoadResult
    let subAPIAccounts: BalanceAccountsLoadResult
}

private enum SecretConfigurationPersistenceError: LocalizedError {
    case invalidBinding(String)

    var errorDescription: String? {
        switch self {
        case .invalidBinding(let label):
            "\(label) 的服务器地址无效，认证信息未保存"
        }
    }
}

private struct SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}
