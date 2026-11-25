import Foundation

/// A profile's last few searches, newest first, on this device only. Shown
/// under the search field; forgotten with the profile. What someone searched
/// for is close to what they watch, so the app keeps it where a backup never
/// reaches (`AccountStore.recentSearches(for:)`: the Keychain, this device
/// only), not in the settings that iCloud and Finder back up.
public struct RecentSearches: Sendable {
    public static let limit = 8

    let settings: any KeyValueStore
    let key: String

    public init(settings: any KeyValueStore, accountId: String) {
        self.settings = settings
        key = Self.key(accountId)
    }

    static func key(_ accountId: String) -> String { "recent-searches.\(accountId)" }

    public func list() -> [String] {
        settings.data(forKey: key).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    /// Puts `text` first. Ignores anything under two characters; the same
    /// search in another case or with other spaces replaces the old one.
    public func add(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        guard clean.count >= 2 else { return }
        let rest = list().filter { $0.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame }
        save(Array(([clean] + rest).prefix(Self.limit)))
    }

    public func clear() { settings.set(nil, forKey: key) }

    private func save(_ list: [String]) {
        settings.set(try? JSONEncoder().encode(list), forKey: key)
    }
}

/// A `KeyValueStore` over the secret store (the Keychain in the app): for small
/// per-profile values that must stay on this device and out of backups.
public struct SecretKeyValueStore: KeyValueStore {
    let secrets: any SecretStore

    public init(secrets: any SecretStore) { self.secrets = secrets }

    public func data(forKey key: String) -> Data? { (try? secrets.read(key)) ?? nil }

    public func set(_ data: Data?, forKey key: String) {
        if let data { try? secrets.write(data, for: key) } else { try? secrets.delete(key) }
    }
}
