import Foundation
import Darwin

enum SecretStorageMode: String, CaseIterable, Identifiable, Codable {
    case keychain
    case database

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keychain:
            "钥匙串"
        case .database:
            "本机数据库"
        }
    }
}

struct SecretKey: Hashable, Codable {
    let rawValue: String

    static let cliproxyManagement = SecretKey(rawValue: "cliproxy.management")
    static let newAPIManagement = SecretKey(rawValue: "newapi.management")
    static let subAPIManagement = SecretKey(rawValue: "subapi.management")

    static func balanceAccount(source: BalanceMonitorSource, id: String) -> SecretKey {
        SecretKey(rawValue: "\(source.rawValue).account.\(id)")
    }
}

struct SecretVault: Codable, Equatable {
    private var values: [String: String] = [:]

    var isEmpty: Bool {
        values.isEmpty
    }

    func value(for key: SecretKey) -> String {
        values[key.rawValue] ?? ""
    }

    mutating func set(_ value: String, for key: SecretKey) {
        if value.isEmpty {
            values.removeValue(forKey: key.rawValue)
        } else {
            values[key.rawValue] = value
        }
    }

    mutating func removeValue(for key: SecretKey) {
        values.removeValue(forKey: key.rawValue)
    }
}

protocol SecretStore: Sendable {
    func loadVault() throws -> SecretVault
    func saveVault(_ vault: SecretVault) throws
}

struct SecretStoreFactory: Sendable {
    let keychain: any SecretStore
    let database: any SecretStore

    static func live() -> SecretStoreFactory {
        SecretStoreFactory(
            keychain: KeychainSecretStore(),
            database: DatabaseSecretStore(databaseURL: DatabaseSecretStore.defaultDatabaseURL)
        )
    }

    func store(for mode: SecretStorageMode) -> any SecretStore {
        switch mode {
        case .keychain:
            keychain
        case .database:
            database
        }
    }
}

struct KeychainSecretStore: SecretStore {
    static let service = "com.alight.codexnotch.secret-vault"
    static let account = "default"

    func loadVault() throws -> SecretVault {
        let encoded = try KeychainStore.read(service: Self.service, account: Self.account)
        guard !encoded.isEmpty else {
            return SecretVault()
        }
        let data = Data(encoded.utf8)
        return try JSONDecoder().decode(SecretVault.self, from: data)
    }

    func saveVault(_ vault: SecretVault) throws {
        let data = try JSONEncoder().encode(vault)
        let encoded = String(decoding: data, as: UTF8.self)
        try KeychainStore.write(encoded, service: Self.service, account: Self.account)
    }
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var vault: SecretVault

    init(vault: SecretVault = SecretVault()) {
        self.vault = vault
    }

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
        self.vault = vault
    }
}

struct DatabaseSecretStore: SecretStore {
    let databaseURL: URL

    static var defaultDatabaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("codex监测", isDirectory: true)
            .appendingPathComponent("secrets.sqlite3")
    }

    func loadVault() throws -> SecretVault {
        try prepareDatabase()
        let output = try Shell.run(
            "/usr/bin/sqlite3",
            [databaseURL.path, "SELECT payload FROM secret_vault WHERE id = 'default' LIMIT 1;"],
            timeout: 4
        )
        let encoded = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encoded.isEmpty else {
            return SecretVault()
        }
        guard let data = Data(base64Encoded: encoded) else {
            return SecretVault()
        }
        return try JSONDecoder().decode(SecretVault.self, from: data)
    }

    func saveVault(_ vault: SecretVault) throws {
        try prepareDatabase()
        let data = try JSONEncoder().encode(vault)
        let encoded = data.base64EncodedString()
        let sql = """
        INSERT INTO secret_vault(id, payload, updated_at)
        VALUES('default', '\(encoded)', strftime('%s','now'))
        ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at;
        """
        _ = try Shell.run("/usr/bin/sqlite3", [databaseURL.path, sql], timeout: 4)
        chmod(databaseURL.path, S_IRUSR | S_IWUSR)
    }

    private func prepareDatabase() throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)
        let sql = """
        CREATE TABLE IF NOT EXISTS secret_vault(
            id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        _ = try Shell.run("/usr/bin/sqlite3", [databaseURL.path, sql], timeout: 4)
        chmod(databaseURL.path, S_IRUSR | S_IWUSR)
    }
}
