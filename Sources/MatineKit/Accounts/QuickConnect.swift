import Foundation

/// Why a Quick Connect step didn't work, apart from the transport errors.
public enum QuickConnectError: Error, Equatable, Sendable {
    /// The server has Quick Connect switched off.
    case disabled
    /// Not a 6-digit code, or the server doesn't know it (mistyped, or expired).
    case invalidCode
    /// The request lapsed on the server before anyone approved it.
    case expired
    /// Nobody approved it in time.
    case timedOut
    /// Signing in again for one profile, but someone else approved the code.
    /// Nothing was saved and the new session was ended.
    case wrongUser
    /// A new profile in a house with kid profiles needs a grown-up's PIN first.
    /// Nothing was saved and the new session was ended.
    case needsGrownUp
}

/// Who a Quick Connect sign-in is allowed to be.
public enum QuickConnectPolicy: Sendable, Equatable {
    /// Signing in again for a known profile (its token expired): only that
    /// user's approval counts.
    case again(userId: String)
    /// A new profile. `grownUpCleared`: the screen was reached through a
    /// grown-up's PIN (needed once a kid profile exists).
    case newProfile(grownUpCleared: Bool)
}

/// Where the app goes after a sign-in: a profile behind a PIN never opens
/// without it, whichever way it signed in.
public enum SignInLanding: Sendable, Equatable {
    case home, pin
}

public struct QuickConnectSignIn: Sendable {
    public let account: Account
    public let landing: SignInLanding
    /// The profile wasn't saved here before this sign-in. Only a new profile
    /// can be undone ("No soy yo"): removing it is always safe under the house
    /// rules (it has no PIN and is nobody's only adult), while an existing one
    /// might be the last grown-up with a PIN.
    public let isNew: Bool
}

/// A sign-in waiting for approval from a device that is already signed in.
/// `code` is what the person types over there; the secret that claims the
/// result stays inside, so nothing that prints or logs a session can leak it.
public struct QuickConnectSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "QuickConnectSession(code: \(code))" }
    public var debugDescription: String { description }

    public let code: String
    public let server: URL
    let secret: String
    let deviceId: String
}

struct QuickConnectResult: Decodable {
    var authenticated: Bool?
    var secret: String
    var code: String
    enum CodingKeys: String, CodingKey {
        case authenticated = "Authenticated"
        case secret = "Secret"
        case code = "Code"
    }
}

extension JellyfinClient {
    public func quickConnectEnabled() async throws -> Bool {
        try await get("/QuickConnect/Enabled")
    }

    /// Starts a request; the server answers with the secret and the code to show.
    func quickConnectInitiate() async throws -> QuickConnectResult {
        try await withToken(nil).get("/QuickConnect/Initiate", method: "POST")
    }

    /// Whether the request has been approved yet. The API takes the secret as
    /// a query parameter: it is the one-time secret of this request (good for
    /// one sign-in, useless once claimed), not the account's access token.
    func quickConnectApproved(secret: String) async throws -> Bool {
        do {
            let result: QuickConnectResult = try await withToken(nil).get("/QuickConnect/Connect", query: [
                URLQueryItem(name: "secret", value: secret),
            ])
            return result.authenticated ?? false
        } catch JellyfinError.http(status: 404) {
            throw QuickConnectError.expired
        }
    }

    /// Claims an approved request: the user and a fresh access token.
    func authenticate(quickConnectSecret secret: String) async throws -> (User, String) {
        struct Body: Encodable, Sendable { let Secret: String }
        let data = try await withToken(nil).send("POST", "/Users/AuthenticateWithQuickConnect", body: Body(Secret: secret))
        guard let result = try? JSONDecoder().decode(AuthenticationResult.self, from: data) else {
            throw JellyfinError.decoding("/Users/AuthenticateWithQuickConnect")
        }
        return (result.user, result.accessToken)
    }

    /// Approves the 6-digit `code` shown on another device, as the signed-in user.
    public func quickConnectAuthorize(code: String) async throws {
        do {
            _ = try await send("POST", "/QuickConnect/Authorize", query: [URLQueryItem(name: "code", value: code)])
        } catch JellyfinError.http(status: 404) {
            throw QuickConnectError.invalidCode
        }
    }
}

extension JellyfinClient {
    /// `get` with another method (Initiate is a POST with no body).
    func get<T: Decodable>(_ path: String, method: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(method, path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw JellyfinError.decoding("\(path): \(error)")
        }
    }
}

extension Profiles {
    /// Six digits, as the server shows them.
    public static func isQuickConnectCode(_ typed: String) -> Bool {
        typed.count == 6 && typed.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Asks `server` for a code to approve elsewhere. The request gets its own
    /// device id (the one the profile will keep if it is approved), or the
    /// known profile's when signing in again for it: Jellyfin keeps one
    /// session per device id, so the old session is replaced, not left alive.
    public func startQuickConnect(server: URL, deviceId: String? = nil) async throws -> QuickConnectSession {
        guard Self.isSupported(server) else { throw JellyfinError.unsupportedServer }
        let deviceId = deviceId ?? UUID().uuidString
        let client = JellyfinClient(server: server, identity: identity(deviceId: deviceId), transport: transport)
        guard try await client.quickConnectEnabled() else { throw QuickConnectError.disabled }
        let started = try await client.quickConnectInitiate()
        return QuickConnectSession(code: started.code, server: server, secret: started.secret, deviceId: deviceId)
    }

    /// Waits for the code to be approved (polling with a gentle backoff from
    /// `firstDelay` up to `maxDelay`), then signs in and saves the profile as
    /// `signIn` does, if `policy` allows who was approved (otherwise the new
    /// session is ended and nothing is saved). The landing says whether the
    /// profile opens or asks for its PIN. Cancelling the task stops the
    /// polling; the request simply lapses on the server.
    @discardableResult
    public func finishQuickConnect(
        _ session: QuickConnectSession,
        policy: QuickConnectPolicy,
        timeout: TimeInterval = 5 * 60,
        firstDelay: Duration = .seconds(2),
        maxDelay: Duration = .seconds(6),
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> QuickConnectSignIn {
        let client = JellyfinClient(server: session.server, identity: identity(deviceId: session.deviceId), transport: transport)
        var delay = firstDelay
        var waited = Duration.zero
        // The sleeps count toward the timeout; checks that hang on a dead
        // network don't, so the wall clock is a backstop at twice the timeout.
        let started = ContinuousClock.now
        var lastNetworkError: JellyfinError?
        while true {
            try Task.checkCancellation()
            // A check cut off by the network (the app sent to the background
            // while the code is approved in a browser on the same phone, a
            // moment without Wi-Fi) is just another "not yet": the code stays
            // valid until it times out.
            do {
                if try await client.quickConnectApproved(secret: session.secret) { break }
                lastNetworkError = nil
            } catch let error as JellyfinError {
                guard case .transport = error else { throw error }
                try Task.checkCancellation()
                lastNetworkError = error
            }
            if waited >= .seconds(timeout) || ContinuousClock.now - started >= .seconds(timeout * 2) {
                // Still unreachable at the end: say so, not "expired".
                throw lastNetworkError ?? QuickConnectError.timedOut
            }
            try await sleep(delay)
            waited += delay
            delay = min(maxDelay, delay * 1.5)
        }
        let (user, token) = try await client.authenticate(quickConnectSecret: session.secret)
        let accounts = store.accounts()
        let previous = accounts.first { $0.id == user.id }

        // Who approved decides before anything is saved; a refused session ends.
        func refuse(_ error: QuickConnectError) async -> QuickConnectError {
            try? await JellyfinClient(
                server: session.server, identity: identity(deviceId: session.deviceId), token: token, transport: transport
            ).logout()
            return error
        }
        switch policy {
        case .again(let expected):
            guard user.id == expected else { throw await refuse(.wrongUser) }
        case .newProfile(let cleared):
            // Adding someone to a house with kids asks a grown-up first (an
            // already saved profile signing in again is not adding).
            if previous == nil, !cleared, rules(for: accounts).needsGrownUp { throw await refuse(.needsGrownUp) }
        }

        // The same user signed in on this device under another device id (a
        // password sign-in): end that session rather than leave it alive.
        if let previous, previous.deviceId != session.deviceId, let old = try? self.client(for: previous) {
            try? await old.logout()
        }
        let account = try saveSignIn(user: user, token: token, server: session.server, deviceId: session.deviceId)
        return QuickConnectSignIn(account: account, landing: landing(for: account), isNew: previous == nil)
    }

    func rules(for accounts: [Account]) -> HouseRules {
        // A PIN that can't be read counts as set: the gate fails closed.
        HouseRules(accounts: accounts, hasPin: { (try? pins.hasPin($0)) ?? true })
    }

    /// A profile behind a PIN opens on the PIN screen, never straight onto Home.
    public func landing(for account: Account) -> SignInLanding {
        ((try? pins.hasPin(account.id)) ?? true) ? .pin : .home
    }

    /// Approves a code from another device, as `account`: any profile whose
    /// gate the caller has already passed (`HouseRules.approveGate`: its own
    /// PIN, a grown-up's, or none needed). It need not be the profile open on
    /// the screen, and nothing here switches profiles. The caller must also
    /// have a person confirm the code, since whoever approves signs the
    /// other device in as `account`.
    public func approveQuickConnect(code: String, as account: Account) async throws {
        let code = code.trimmingCharacters(in: .whitespaces)
        guard Self.isQuickConnectCode(code) else { throw QuickConnectError.invalidCode }
        guard let client = try client(for: account) else { throw JellyfinError.unauthorized }
        // Jellyfin answers 401 to an approval while Quick Connect is off; asked
        // first, so a 401 after this really means the profile's session ended.
        guard try await client.quickConnectEnabled() else { throw QuickConnectError.disabled }
        try await client.quickConnectAuthorize(code: code)
    }
}
