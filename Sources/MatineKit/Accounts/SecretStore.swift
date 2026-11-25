import Foundation
#if canImport(Security)
import Security
#endif

/// Where tokens and PINs live. The app uses the Keychain (the one storage tvOS
/// keeps for sure); tests use memory; the CLI uses a 0600 file.
public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ value: Data, for key: String) throws
    func delete(_ key: String) throws
    /// Removes every secret this store holds.
    func removeAll() throws
}

extension SecretStore {
    func readString(_ key: String) throws -> String? {
        try read(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func writeString(_ value: String, for key: String) throws {
        try write(Data(value.utf8), for: key)
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    public func write(_ value: Data, for key: String) throws { lock.withLock { values[key] = value } }
    public func delete(_ key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
    public func removeAll() throws { lock.withLock { values.removeAll() } }
}

#if canImport(Security)
/// Generic-password items under one service. `ThisDeviceOnly`: never synced
/// through iCloud Keychain and never restored onto another device.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    /// A shared keychain access group, or nil for the app's own (private) one.
    public let accessGroup: String?

    public init(service: String = "io.github.anthonytw.matine", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public struct Failure: Error, Equatable { public let status: Int32 }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ].merging(accessGroup.map { [kSecAttrAccessGroup as String: $0] } ?? [:]) { $1 }
    }

    public func read(_ key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    public func write(_ value: Data, for key: String) throws {
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var add = query(key)
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    public func removeAll() throws {
        let all: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            .merging(accessGroup.map { [kSecAttrAccessGroup as String: $0] } ?? [:]) { $1 }
        let status = SecItemDelete(all as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
#endif
