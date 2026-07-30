import Foundation
import Testing
@testable import CodexNotch

@MainActor
@Test
func remoteSecretIsBoundToItsConfiguredServer() throws {
    let suiteName = "codex-monitor-secret-binding-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = MemorySecretStore()
    let factory = SecretStoreFactory(keychain: store, database: MemorySecretStore())
    let settings = CodexNotchSettings(
        defaults: defaults,
        initialManagementKey: "",
        initialNewAPIKey: "",
        initialSubAPIKey: "",
        secretStores: factory,
        launchAtLoginManager: TestLaunchAtLoginManager(),
        loadSecretsSynchronously: true
    )
    let saved = RemoteAccountSourceConfiguration(
        id: "remote-1",
        source: .sub2API,
        label: "Sub2",
        panelURL: "https://trusted.example.com",
        username: "admin@example.com",
        secret: "secret",
        requestTimeout: 6
    )
    settings.setRemoteAccountSources([saved])

    var tampered = saved
    tampered.panelURL = "https://attacker.example.com"
    defaults.set(try JSONEncoder().encode([tampered]), forKey: "remoteAccountSources")

    let reloaded = CodexNotchSettings(
        defaults: defaults,
        initialManagementKey: "",
        initialNewAPIKey: "",
        initialSubAPIKey: "",
        secretStores: factory,
        launchAtLoginManager: TestLaunchAtLoginManager(),
        loadSecretsSynchronously: true
    )

    #expect(reloaded.remoteAccountSources.first?.secret.isEmpty == true)
    #expect(reloaded.remoteAccountSources.first?.secretReadFailed == true)
    #expect(reloaded.cliproxyKeychainError?.contains("重新输入认证信息") == true)
}

@MainActor
@Test
func failedSecretSaveRollsBackRemoteSourceMetadata() throws {
    let suiteName = "codex-monitor-secret-atomic-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = ToggleFailingSecretStore()
    let settings = CodexNotchSettings(
        defaults: defaults,
        initialManagementKey: "",
        initialNewAPIKey: "",
        initialSubAPIKey: "",
        secretStores: SecretStoreFactory(keychain: store, database: MemorySecretStore()),
        launchAtLoginManager: TestLaunchAtLoginManager(),
        loadSecretsSynchronously: true
    )
    let original = RemoteAccountSourceConfiguration(
        id: "remote-1",
        source: .cpaManagerPlus,
        label: "Original",
        panelURL: "https://panel.example.com",
        secret: "first-secret",
        requestTimeout: 6
    )
    settings.setRemoteAccountSources([original])
    store.shouldFail = true

    var replacement = original
    replacement.label = "Replacement"
    replacement.secret = "second-secret"
    settings.setRemoteAccountSources([replacement])

    #expect(settings.remoteAccountSources == [original])
    #expect(settings.cliproxyKeychainError?.contains("test secret save failure") == true)
    let persisted = try #require(defaults.data(forKey: "remoteAccountSources"))
    let decoded = try JSONDecoder().decode([RemoteAccountSourceConfiguration].self, from: persisted)
    #expect(decoded.first?.label == "Original")
}

@MainActor
@Test
func changingCredentialPrincipalRequiresAReplacementSecret() {
    let balance = BalanceAccountConfiguration(
        id: "balance",
        source: .subAPI,
        panelURL: "https://sub2.example.com",
        username: "first@example.com",
        secret: "shared-secret"
    )
    var changedBalance = balance
    changedBalance.username = "second@example.com"

    let sanitizedBalance = CodexNotchSettings.sanitizedBalanceAccountForSave(
        changedBalance,
        oldAccount: balance
    )
    #expect(sanitizedBalance.secret.isEmpty)

    let remote = RemoteAccountSourceConfiguration(
        id: "remote",
        source: .sub2API,
        panelURL: "https://sub2.example.com",
        username: "first@example.com",
        secret: "shared-secret"
    )
    var changedRemote = remote
    changedRemote.username = "second@example.com"

    let sanitizedRemote = CodexNotchSettings.sanitizedRemoteAccountSourceForSave(
        changedRemote,
        oldSource: remote
    )
    #expect(sanitizedRemote.secret.isEmpty)
}

private final class ToggleFailingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var vault = SecretVault()
    var shouldFail = false

    func loadVault() throws -> SecretVault {
        lock.lock()
        defer {
            lock.unlock()
        }
        return vault
    }

    func saveVault(_ vault: SecretVault) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        if shouldFail {
            throw TestSecretStoreError.saveFailure
        }
        self.vault = vault
    }
}

private enum TestSecretStoreError: LocalizedError {
    case saveFailure

    var errorDescription: String? {
        "test secret save failure"
    }
}

private struct TestLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled = false

    func setEnabled(_ enabled: Bool) throws {}
}
