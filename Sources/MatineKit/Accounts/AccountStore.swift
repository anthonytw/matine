import Foundation

/// One saved profile: a Jellyfin user on the server, as shown on the picker.
/// Nothing secret here; the token and PIN sit in the `SecretStore`.
public struct Account: Codable, Sendable, Hashable, Identifiable {
    /// The Jellyfin user id.
    public var id: String
    public var name: String
    public var server: URL
    public var language: AppLanguage
    /// Random, one per profile. Jellyfin keeps one session per device id and
    /// ends the old one when another sign-in reuses it, so profiles sharing
    /// an id would sign each other out.
    public var deviceId: String
    /// What the picker calls it, set by a grown-up; nil shows `name`.
    public var displayName: String?
    public var role: ProfileRole
    public var avatar: Avatar

    public init(
        id: String, name: String, server: URL, language: AppLanguage = .default, deviceId: String = UUID().uuidString,
        displayName: String? = nil, role: ProfileRole = .adult, avatar: Avatar? = nil
    ) {
        self.id = id
        self.name = name
        self.server = server
        self.language = language
        self.deviceId = deviceId
        self.displayName = displayName
        self.role = role
        self.avatar = avatar ?? .initial(for: id)
    }

    /// Profiles saved by an earlier build have no name, role or avatar yet:
    /// they open as adults with their own robot.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        server = try c.decode(URL.self, forKey: .server)
        language = try c.decode(AppLanguage.self, forKey: .language)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        // A look this build doesn't know (saved by a newer one) falls back
        // rather than failing the whole profile list.
        role = (try? c.decodeIfPresent(ProfileRole.self, forKey: .role)) ?? .adult
        avatar = (try? c.decodeIfPresent(Avatar.self, forKey: .avatar)) ?? .initial(for: id)
    }
}

/// Small non-secret settings. tvOS gives apps no guaranteed file storage, so
/// the app passes `UserDefaults`; the CLI and tests pass their own.
public protocol KeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

extension UserDefaults: @retroactive @unchecked Sendable {}
extension UserDefaults: KeyValueStore {
    public func set(_ data: Data?, forKey key: String) {
        if let data { set(data as Any, forKey: key) } else { removeObject(forKey: key) }
    }
}

public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
    public func set(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }
}

/// The saved profiles, their tokens and PINs, and each profile's device id is on the profile itself.
public struct AccountStore: Sendable {
    public let settings: any KeyValueStore
    let secrets: any SecretStore

    static let accountsKey = "matine.accounts"

    public init(settings: any KeyValueStore, secrets: any SecretStore) {
        self.settings = settings
        self.secrets = secrets
    }

    /// The saved profiles; none if the list can't be read (see `loadAccounts`).
    public func accounts() -> [Account] {
        (try? loadAccounts()) ?? []
    }

    /// The saved profiles. A missing list is `[]`; a list that exists but
    /// doesn't decode throws, so nothing writes over it.
    public func loadAccounts() throws -> [Account] {
        guard let data = settings.data(forKey: Self.accountsKey) else { return [] }
        return try JSONDecoder().decode([Account].self, from: data)
    }

    func save(_ accounts: [Account]) throws {
        settings.set(try JSONEncoder().encode(accounts), forKey: Self.accountsKey)
    }

    /// Adds the account or replaces the one with the same id, keeping picker order.
    public func upsert(_ account: Account, token: String) throws {
        var all = try loadAccounts()
        try secrets.writeString(token, for: Self.tokenKey(account.id))
        if let index = all.firstIndex(where: { $0.id == account.id }) { all[index] = account } else { all.append(account) }
        try save(all)
    }

    /// Adds a profile that has no session on this device yet (one the household
    /// brought): no token, so it shows as needing sign-in. Keeps an existing one.
    public func insert(_ account: Account) throws {
        var all = try loadAccounts()
        guard !all.contains(where: { $0.id == account.id }) else { return }
        all.append(account)
        try save(all)
    }

    /// The profile's recent searches, kept in the secret store (this device
    /// only, never in a backup). Earlier builds kept them in the settings, which
    /// backups carry: `migrateRecentSearches()` moves what is left there.
    public func recentSearches(for accountId: String) -> RecentSearches {
        RecentSearches(settings: SecretKeyValueStore(secrets: secrets), accountId: accountId)
    }

    /// Once at launch: searches an earlier build left in the (backed-up) settings move into the
    /// Keychain, unless it already has some, and are cleared from the settings.
    public func migrateRecentSearches() {
        for account in accounts() {
            let key = RecentSearches.key(account.id)
            guard let old = settings.data(forKey: key) else { continue }
            if ((try? secrets.read(key)) ?? nil) == nil { try? secrets.write(old, for: key) }
            settings.set(nil, forKey: key)
        }
    }

    private func forgetRecentSearches(_ accountId: String) {
        settings.set(nil, forKey: RecentSearches.key(accountId))
        try? secrets.delete(RecentSearches.key(accountId))
    }

    /// Forgets only the session: the profile, its PIN and its device id stay.
    public func removeToken(_ accountId: String) throws {
        try secrets.delete(Self.tokenKey(accountId))
        forgetRecentSearches(accountId)
    }

    public func update(_ account: Account) throws {
        var all = try loadAccounts()
        guard let index = all.firstIndex(where: { $0.id == account.id }) else { return }
        all[index] = account
        try save(all)
    }

    /// Forgets the profile on this device: its token, PIN, attempt record and recent searches.
    public func remove(_ accountId: String) throws {
        for key in [Self.tokenKey(accountId), PinGate.pinKey(accountId), PinGate.attemptsKey(accountId)] {
            try secrets.delete(key)
        }
        forgetRecentSearches(accountId)
        try save(loadAccounts().filter { $0.id != accountId })
    }

    /// What `reconcileInstall()` found.
    public enum InstallState: Sendable, Equatable {
        /// No saved profiles: a first launch, or a reinstall (leftover secrets were removed).
        case fresh
        /// This install's own profiles.
        case normal
        /// Profiles with no secrets behind them: the settings came back from an
        /// iCloud or Finder backup, but Keychain items marked "this device only"
        /// (tokens, PINs) never do. The profiles, and what hung on them (recent
        /// searches), were removed: a PIN profile must never return without its PIN.
        case restored
    }

    static let installMarkerKey = "install-marker"

    /// Run once at launch. The marker is a Keychain item, so (like PINs) it
    /// lives only on this device. Profiles saved here without a marker are
    /// either from a build that predates it (their tokens are still in the
    /// Keychain: kept, and marked) or restored from a backup (no secrets: wiped).
    @discardableResult
    public func reconcileInstall() throws -> InstallState {
        func mark() throws { try secrets.write(Data("1".utf8), for: Self.installMarkerKey) }
        guard settings.data(forKey: Self.accountsKey) != nil else {
            try secrets.removeAll()
            try mark()
            return .fresh
        }
        if try secrets.read(Self.installMarkerKey) != nil { return .normal }
        // A list that exists but doesn't decode throws here, and nothing is touched.
        let saved = try loadAccounts()
        if try saved.contains(where: { try token(for: $0.id) != nil }) {
            try mark()
            return .normal
        }
        for account in saved { try remove(account.id) }
        try mark()
        return .restored
    }

    public func token(for accountId: String) throws -> String? {
        try secrets.readString(Self.tokenKey(accountId))
    }

    static func tokenKey(_ accountId: String) -> String { "token.\(accountId)" }
}
