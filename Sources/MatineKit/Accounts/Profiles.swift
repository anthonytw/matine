import Foundation

/// Everything the picker and the CLI do with profiles, over one store.
public struct Profiles: Sendable {
    public let store: AccountStore
    public let pins: PinGate
    public let deviceName: String
    let version: String
    let transport: any HTTPTransport

    public init(
        store: AccountStore,
        pins: PinGate,
        deviceName: String,
        version: String,
        transport: any HTTPTransport = URLSessionTransport.shared
    ) {
        self.store = store
        self.pins = pins
        self.deviceName = deviceName
        self.version = version
        self.transport = transport
    }

    func identity(deviceId: String) -> ClientIdentity {
        ClientIdentity(deviceId: deviceId, deviceName: deviceName, version: version)
    }

    /// What someone typed or pasted, as a server URL: `https://` assumed when
    /// no scheme is given; query, fragment, `user:password@` and a pasted web-app
    /// path (`/web/…`) dropped (a proxy password must not land in the settings
    /// or a backup); no trailing slash. Nil unless the result is `https` or `http`
    /// with a host. Plain `http` is allowed (most home servers have no certificate);
    /// the sign-in screens warn about it (`isSecure`).
    public static func serverURL(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text) else { return nil }
        // One spelling per server (profiles and household records compare URLs). Nothing saved
        // before this has an upper-case scheme in the wild: the app is unreleased.
        components.scheme = components.scheme?.lowercased()
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var path = components.path
        if let web = path.range(of: "/web", options: [.caseInsensitive, .backwards]),
           path[web.upperBound...].isEmpty || path[web.upperBound...].hasPrefix("/") {
            path = String(path[..<web.lowerBound])
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        guard let url = components.url, isSupported(url) else { return nil }
        return url
    }

    /// A typed user name as the server stores it: no spaces around it, and
    /// accented letters in their composed form (the Apple TV keyboard can type
    /// "ñ" as "n" + a combining tilde, which the server would not match).
    public static func cleanUsername(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// `https://` with a host: the password and the token are encrypted on the way.
    /// Anything else that `isSupported` sends them in the clear, so the sign-in
    /// screens warn. Whether a plain address is "local" cannot be known from the
    /// name (a public-looking name can resolve inside the house), so none is refused.
    public static func isSecure(_ server: URL) -> Bool {
        server.scheme?.lowercased() == "https" && !(server.host ?? "").isEmpty
    }

    /// `https://` or `http://` with a host: an address the app can sign in to.
    public static func isSupported(_ server: URL) -> Bool {
        ["https", "http"].contains(server.scheme?.lowercased() ?? "") && !(server.host ?? "").isEmpty
    }

    /// A client for unauthenticated calls (server info, the API spec). It uses
    /// a throwaway device id and never signs in.
    public func anonymousClient(server: URL, language: AppLanguage = .default) -> JellyfinClient {
        JellyfinClient(server: server, identity: identity(deviceId: UUID().uuidString), language: language, transport: transport)
    }

    public enum SignInError: Error, Equatable, Sendable {
        /// Signing in again for one profile, but the server answered as another user.
        /// Nothing was saved and the new session was ended.
        case wrongUser
    }

    /// Signs in and saves the profile. Signing in again as the same user
    /// replaces its token and keeps its PIN, language, look and role.
    /// `expecting` is the user a sign-in again is for: any other answer (a
    /// different server, an account recreated under a new id) saves nothing,
    /// so it can never add a profile without the grown-up check.
    @discardableResult
    public func signIn(server: URL, username: String, password: String, expecting userId: String? = nil) async throws -> Account {
        guard Self.isSupported(server) else { throw JellyfinError.unsupportedServer }
        let username = Self.cleanUsername(username)
        let existing = store.accounts().first { $0.server == server && $0.name.lowercased() == username.lowercased() }
        let deviceId = existing?.deviceId ?? UUID().uuidString
        let client = JellyfinClient(server: server, identity: identity(deviceId: deviceId), transport: transport)
        let (user, token) = try await client.authenticate(username: username, password: password)
        if let userId, user.id != userId {
            try? await JellyfinClient(server: server, identity: identity(deviceId: deviceId), token: token, transport: transport).logout()
            throw SignInError.wrongUser
        }
        // The same user under another device id (renamed on the server, so the lookup by
        // name missed it): once the new sign-in is saved, end the old session rather than
        // leave it alive in the server's list. Its client is built first: saving replaces the token.
        var old: JellyfinClient?
        if let previous = store.accounts().first(where: { $0.id == user.id }), previous.deviceId != deviceId {
            old = try? self.client(for: previous)
        }
        let account = try saveSignIn(user: user, token: token, server: server, deviceId: deviceId)
        if let old { try? await old.logout() }
        return account
    }

    /// Saves the profile a sign-in produced (either way: password or Quick
    /// Connect). The device id the server just saw is the one saved, so the
    /// stored profile always matches the session this sign-in opened.
    func saveSignIn(user: User, token: String, server: URL, deviceId: String) throws -> Account {
        let previous = store.accounts().first { $0.id == user.id }
        var account = previous ?? Account(id: user.id, name: user.name, server: server)
        account.name = user.name
        account.server = server
        account.deviceId = deviceId
        try store.upsert(account, token: token)
        return account
    }

    /// A signed-in client for the profile, in its language. Nil if its token is gone.
    public func client(for account: Account) throws -> JellyfinClient? {
        guard let token = try store.token(for: account.id) else { return nil }
        return JellyfinClient(
            server: account.server, identity: identity(deviceId: account.deviceId), token: token,
            language: account.language, transport: transport
        )
    }

    /// Signs out of this device only: the server session ends (best effort) and
    /// the token goes, but the profile, its PIN and look stay, so the household
    /// still shows it and it can sign in again.
    public func endSession(_ account: Account) async throws {
        if let client = try client(for: account) { try? await client.logout() }
        try store.removeToken(account.id)
    }

    /// Ends the server session (best effort: offline still forgets locally) and
    /// removes the profile from this device.
    public func signOut(_ account: Account) async throws {
        if let client = try client(for: account) { try? await client.logout() }
        try store.remove(account.id)
    }
}
