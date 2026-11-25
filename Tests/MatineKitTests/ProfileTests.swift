import Foundation
import Testing
@testable import MatineKit

/// A wall clock and the monotonic one beside it. Moving `now` moves both (time
/// passing); `setWallClock` moves only the date, as Settings › Date & Time does.
final class Clock: @unchecked Sendable {
    var uptime: TimeInterval = 5_000
    private(set) var wall = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
        get { wall }
        set {
            uptime += newValue.timeIntervalSince(wall)
            wall = newValue
        }
    }
    func setWallClock(_ date: Date) { wall = date }
    /// A restart: the monotonic clock begins again.
    func reboot() { uptime = 1 }
    func gate(_ secrets: any SecretStore) -> PinGate {
        PinGate(secrets: secrets, now: { [self] in wall }, uptime: { [self] in uptime })
    }
}

@Suite struct PinGateTests {
    let secrets = InMemorySecretStore()
    let clock = Clock()
    var gate: PinGate { clock.gate(secrets) }

    @Test func aProfileWithoutAPinIsOpen() throws {
        #expect(try gate.check("", for: "a") == .open)
    }

    @Test func onlyFourDigitsAreAPin() {
        #expect(PinGate.isValid("0420"))
        for bad in ["420", "04201", "04a0", "٠١٢٣", ""] { #expect(!PinGate.isValid(bad)) }
        #expect(throws: PinGate.PinError.notFourDigits) { try gate.setPin("12", for: "a") }
    }

    @Test func rightPinOpensAndWrongCountsDown() throws {
        try gate.setPin("1234", for: "a")
        #expect(try gate.check("0000", for: "a") == .wrong(attemptsLeft: 4))
        #expect(try gate.check("0000", for: "a") == .wrong(attemptsLeft: 3))
        #expect(try gate.check("1234", for: "a") == .open)
        // Success resets the count.
        #expect(try gate.check("0000", for: "a") == .wrong(attemptsLeft: 4))
    }

    @Test func fiveMissesLockAndLockoutsDoubleUpToTheCap() throws {
        try gate.setPin("1234", for: "a")
        var lockouts: [TimeInterval] = []
        for _ in 0..<7 {
            for _ in 0..<4 { _ = try gate.check("0000", for: "a") }
            guard case .locked(let until) = try gate.check("0000", for: "a") else { Issue.record("expected a lockout"); return }
            lockouts.append(until.timeIntervalSince(clock.now))
            // Even the right PIN is refused while locked.
            #expect(try gate.check("1234", for: "a") == .locked(until: until))
            clock.now = until.addingTimeInterval(1)
        }
        #expect(lockouts == [30, 60, 120, 240, 480, 900, 900])
    }

    /// The lock lives in the secret store (the Keychain in the app), not in
    /// the gate: a fresh gate over the same store, as after a relaunch, is still locked.
    @Test func theLockIsStoredNotHeldInMemory() throws {
        try gate.setPin("1234", for: "a")
        for _ in 0..<5 { _ = try gate.check("0000", for: "a") }
        let relaunched = clock.gate(secrets)
        guard case .locked = try relaunched.check("1234", for: "a") else { Issue.record("lock was lost"); return }
    }

    private func lock() throws {
        try gate.setPin("1234", for: "a")
        for _ in 0..<5 { _ = try gate.check("0000", for: "a") }
    }

    @Test func settingTheDateForwardDoesNotSkipALockout() throws {
        try lock()
        clock.setWallClock(clock.now.addingTimeInterval(20 * 60))
        guard case .locked = try gate.check("1234", for: "a") else { Issue.record("the lock was skipped"); return }
    }

    @Test func settingTheDateBackDoesNotStretchOrSkipALockout() throws {
        try lock()
        clock.setWallClock(clock.now.addingTimeInterval(-3 * 24 * 3600))
        guard case .locked(let until) = try gate.check("1234", for: "a") else { Issue.record("the lock was skipped"); return }
        // Still the 30 seconds it was, not three days.
        #expect(until.timeIntervalSince(clock.now) <= PinGate.firstLockout)
        clock.now = clock.now.addingTimeInterval(PinGate.firstLockout + 1)
        #expect(try gate.check("1234", for: "a") == .open)
    }

    @Test func timePassingEndsTheLockout() throws {
        try lock()
        clock.now = clock.now.addingTimeInterval(PinGate.firstLockout + 1)
        #expect(try gate.check("1234", for: "a") == .open)
    }

    /// After a restart only the date is left to go by, and a lock that sits further
    /// out than its own length means the date was set back: it starts again from
    /// now for its own length, no more.
    @Test func afterARestartADateSetBackRearmsTheLockForItsLength() throws {
        try lock()
        clock.reboot()
        clock.setWallClock(clock.now.addingTimeInterval(-3 * 24 * 3600))
        guard case .locked(let until) = try gate.check("1234", for: "a") else { Issue.record("the lock was skipped"); return }
        #expect(until.timeIntervalSince(clock.now) == PinGate.firstLockout)
        clock.now = clock.now.addingTimeInterval(PinGate.firstLockout + 1)
        #expect(try gate.check("1234", for: "a") == .open)
    }

    @Test func afterARestartTheDateStillEndsALockout() throws {
        try lock()
        clock.reboot()
        clock.setWallClock(clock.now.addingTimeInterval(60))
        #expect(try gate.check("1234", for: "a") == .open)
    }

    @Test func aRecordFromAnOlderBuildStillLocksOnTheDate() throws {
        try gate.setPin("1234", for: "a")
        let until = clock.now.addingTimeInterval(20)
        let old = try JSONEncoder().encode(PinGate.Attempts(failures: 0, lockouts: 1, lockedUntil: until))
        try secrets.write(old, for: PinGate.attemptsKey("a"))
        #expect(try gate.check("1234", for: "a") == .locked(until: until))
        clock.now = until.addingTimeInterval(1)
        #expect(try gate.check("1234", for: "a") == .open)
    }

    @Test func removingThePinOpensTheProfile() throws {
        try gate.setPin("1234", for: "a")
        try gate.removePin(for: "a")
        #expect(try gate.check("", for: "a") == .open)
        #expect(try !gate.hasPin("a"))
    }
}

@Suite struct ProfilesTests {
    let settings = InMemoryKeyValueStore()
    let secrets = InMemorySecretStore()
    let transport = FakeTransport()

    var profiles: Profiles {
        let store = AccountStore(settings: settings, secrets: secrets)
        return Profiles(store: store, pins: PinGate(secrets: secrets), deviceName: "Apple TV", version: "0.1.0", transport: transport)
    }

    @Test func eachProfileHasItsOwnDeviceIdAndKeepsItOnReSignIn() async throws {
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        let first = try await profiles.signIn(server: testServer, username: "ana", password: "secreto")
        let again = try await profiles.signIn(server: testServer, username: "ana", password: "secreto")
        #expect(again.deviceId == first.deviceId)
        let other = Account(id: "user-2", name: "luis", server: testServer)
        #expect(other.deviceId != first.deviceId)
        // The re-sign-in itself presented the profile's device id.
        let header = try #require(transport.requests.last?.value(forHTTPHeaderField: "Authorization"))
        #expect(header.contains("DeviceId=\"\(first.deviceId)\""))
    }

    @Test func anAddressThatIsNotHTTPIsRefusedBeforeAnythingIsSent() async {
        await #expect(throws: JellyfinError.unsupportedServer) {
            try await profiles.signIn(server: URL(string: "ftp://tv.example.test")!, username: "ana", password: "secreto")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func plainHTTPIsSupportedButNotSecure() {
        let plain = URL(string: "http://192.168.1.20:8096")!
        #expect(Profiles.isSupported(plain))
        #expect(!Profiles.isSecure(plain))
        #expect(Profiles.isSupported(testServer))
        #expect(Profiles.isSecure(testServer))
        #expect(!Profiles.isSupported(URL(string: "http://")!))
    }

    @Test func aProfileListThatDoesNotDecodeIsNeverOverwritten() throws {
        let junk = Data(#"[{"id":"old"}]"#.utf8)
        settings.set(junk, forKey: AccountStore.accountsKey)
        let store = AccountStore(settings: settings, secrets: secrets)
        #expect(throws: (any Error).self) { _ = try store.loadAccounts() }
        #expect(throws: (any Error).self) {
            try store.upsert(Account(id: "user-3", name: "luis", server: testServer), token: "t3")
        }
        #expect(settings.data(forKey: AccountStore.accountsKey) == junk)
        #expect(try secrets.read("token.user-3") == nil)
        // A missing list is simply empty.
        #expect(try AccountStore(settings: InMemoryKeyValueStore(), secrets: secrets).loadAccounts() == [])
    }

    @Test func signInSavesTheDeviceIdItAuthenticatedWith() async throws {
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        transport.on("POST", "/Sessions/Logout")
        // A saved profile under the same id but another name: the lookup by name
        // misses it, so sign-in uses a fresh device id and must save that one.
        try profiles.store.upsert(Account(id: "user-1", name: "renamed", server: testServer, deviceId: "stale"), token: "t")
        let account = try await profiles.signIn(server: testServer, username: "ana", password: "secreto")
        let auth = try #require(transport.requests.last { $0.url?.path == "/Users/AuthenticateByName" })
        #expect(auth.value(forHTTPHeaderField: "Authorization")?.contains("DeviceId=\"\(account.deviceId)\"") == true)
        #expect(account.deviceId != "stale")
        #expect(profiles.store.accounts().first?.deviceId == account.deviceId)
    }

    /// The old device id's session would otherwise stay in the server's device list until revoked by hand.
    @Test func aRenamedUsersOldSessionIsEnded() async throws {
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        transport.on("POST", "/Sessions/Logout")
        try profiles.store.upsert(Account(id: "user-1", name: "renamed", server: testServer, deviceId: "stale"), token: "t")
        _ = try await profiles.signIn(server: testServer, username: "ana", password: "secreto")
        let logouts = transport.requests.filter { $0.url?.path == "/Sessions/Logout" }
        #expect(logouts.count == 1)
        #expect(logouts.first?.value(forHTTPHeaderField: "Authorization")?.contains("DeviceId=\"stale\"") == true)
    }

    /// "Sign in again" is for one user: any other answer saves nothing and ends the session it opened.
    @Test func aSignInAgainThatAnswersAsAnotherUserSavesNothing() async throws {
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        transport.on("POST", "/Sessions/Logout")
        await #expect(throws: Profiles.SignInError.wrongUser) {
            try await profiles.signIn(server: testServer, username: "ana", password: "x", expecting: "somebody-else")
        }
        #expect(profiles.store.accounts().isEmpty)
        #expect(try profiles.store.token(for: "user-1") == nil)
        let logout = try #require(transport.requests.last { $0.url?.path == "/Sessions/Logout" })
        #expect(logout.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"tok-123\"") == true)
        // The right user is saved.
        let account = try await profiles.signIn(server: testServer, username: "ana", password: "x", expecting: "user-1")
        #expect(account.id == "user-1")
    }

    @Test func aSignInAgainUnderTheSameDeviceIdEndsNothing() async throws {
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        transport.on("POST", "/Sessions/Logout")
        _ = try await profiles.signIn(server: testServer, username: "ana", password: "secreto")
        _ = try await profiles.signIn(server: testServer, username: "ana", password: "secreto")
        #expect(!transport.requests.contains { $0.url?.path == "/Sessions/Logout" })
    }

    @Test(arguments: [
        ("https://ana:secret@tv.example.test/web/", "https://tv.example.test"),
        ("ana:secret@tv.example.test", "https://tv.example.test"),
        ("tv.example.test", "https://tv.example.test"),
        ("  https://tv.example.test/  ", "https://tv.example.test"),
        ("https://tv.example.test/web/#/home", "https://tv.example.test"),
        ("https://tv.example.test/web/index.html?x=1", "https://tv.example.test"),
        ("https://example.test/jellyfin/web/", "https://example.test/jellyfin"),
        ("https://example.test/webcams", "https://example.test/webcams"),
    ])
    func typedServerAddressesAreCleanedUp(typed: String, expected: String) {
        #expect(Profiles.serverURL(from: typed)?.absoluteString == expected)
    }

    @Test func plainHTTPOrNoHostIsNotAServer() {
        #expect(Profiles.serverURL(from: "http://tv.example.test")?.absoluteString == "http://tv.example.test")
        #expect(Profiles.serverURL(from: "HTTP://nas:8096/web/")?.absoluteString == "http://nas:8096")
        #expect(Profiles.serverURL(from: "nas.local:8096")?.absoluteString == "https://nas.local:8096")
        #expect(Profiles.serverURL(from: "ftp://tv.example.test") == nil)
        #expect(Profiles.serverURL(from: "https://") == nil)
        #expect(Profiles.serverURL(from: "") == nil)
    }

    @Test func signInSavesTheProfileAndItsTokenSeparately() async throws {
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        let account = try await profiles.signIn(server: testServer, username: "ana", password: "secreto")
        #expect(profiles.store.accounts() == [account])
        #expect(try profiles.store.token(for: account.id) == "tok-123")
        // The saved profile list holds no token and no password.
        let saved = String(decoding: settings.data(forKey: AccountStore.accountsKey)!, as: UTF8.self)
        #expect(!saved.contains("tok-123") && !saved.contains("secreto"))
    }

    @Test func signingInAgainKeepsLanguageLookRolePinAndOrder() async throws {
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        var account = try await profiles.signIn(server: testServer, username: "ana", password: "secreto")
        try profiles.store.upsert(Account(id: "user-2", name: "luis", server: testServer), token: "t2")
        account.language = .english
        account.role = .kid
        account.displayName = "Ani"
        account.avatar = Avatar(figure: .animal(.cat), color: .teal)
        try profiles.store.update(account)
        try profiles.pins.setPin("1234", for: account.id)

        let again = try await profiles.signIn(server: testServer, username: "ana", password: "secreto")
        #expect(again.language == .english)
        // A kid signing in again stays a kid, with its name and look.
        #expect(again.role == .kid && again.displayName == "Ani" && again.avatar == account.avatar)
        #expect(try profiles.pins.hasPin(account.id))
        #expect(profiles.store.accounts().map(\.id) == ["user-1", "user-2"])
    }

    @Test func signOutForgetsTokenPinAndProfileEvenOffline() async throws {
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        let account = try await profiles.signIn(server: testServer, username: "ana", password: "secreto")
        try profiles.pins.setPin("1234", for: account.id)
        transport.on("POST", "/Sessions/Logout", unreachable: true)
        try await profiles.signOut(account)
        #expect(profiles.store.accounts().isEmpty)
        #expect(try profiles.store.token(for: account.id) == nil)
        #expect(try !profiles.pins.hasPin(account.id))
    }

    @Test func clientUsesTheProfileLanguage() throws {
        let account = Account(id: "user-3", name: "luis", server: testServer, language: .english)
        try profiles.store.upsert(account, token: "t3")
        let client = try #require(try profiles.client(for: account))
        #expect(client.language == .english && client.token == "t3")
    }
}

@Suite struct UsernameTests {
    @Test func typedNamesAreTrimmedAndComposed() {
        // Swift compares strings by canonical equivalence; the server compares
        // bytes, so compare the UTF-8.
        let decomposed = "ni\u{006E}\u{0303}a"   // n + combining tilde
        #expect(Array(decomposed.utf8) != Array("niña".utf8))
        #expect(Array(Profiles.cleanUsername("  \(decomposed) \n").utf8) == Array("niña".utf8))
        #expect(Profiles.cleanUsername("ana") == "ana")
    }

    @Test func signInSendsTheCleanName() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        let profiles = Profiles(store: AccountStore(settings: InMemoryKeyValueStore(), secrets: InMemorySecretStore()),
                                pins: PinGate(secrets: InMemorySecretStore()), deviceName: "Apple TV", version: "0", transport: transport)
        _ = try await profiles.signIn(server: testServer, username: " ni\u{006E}\u{0303}a ", password: "x")
        let body = try #require(transport.requests.first?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(Array(sent["Username", default: ""].utf8) == Array("niña".utf8))
    }
}

@Suite struct ApproveGateTests {
    private let adult = Account(id: "a", name: "ana", server: URL(string: "https://media.example.test")!)
    private let kid = Account(id: "k", name: "leo", server: URL(string: "https://media.example.test")!, role: .kid)

    @Test func anAdultWithAPinUsesItsOwn() {
        let rules = HouseRules(accounts: [adult, kid], hasPin: { $0 == "a" })
        #expect(rules.approveGate(for: adult) == .ownPin)
    }

    @Test func anAdultWithoutAPinNeedsAGrownUpOnlyWhenKidsLiveThere() {
        let other = Account(id: "b", name: "bea", server: adult.server)
        let withKids = HouseRules(accounts: [adult, other, kid], hasPin: { $0 == "b" })
        #expect(withKids.approveGate(for: adult) == .grownUpPin)
        let noKids = HouseRules(accounts: [adult, other], hasPin: { $0 == "b" })
        #expect(noKids.approveGate(for: adult) == .open)
        // Kids but no grown-up PIN anywhere: nothing to check against (as needsGrownUp).
        #expect(HouseRules(accounts: [adult, kid], hasPin: { _ in false }).approveGate(for: adult) == .open)
        // A PIN of its own, no kids: still its own PIN.
        #expect(HouseRules(accounts: [adult], hasPin: { _ in true }).approveGate(for: adult) == .ownPin)
    }

    @Test func aKidNeedsAGrownUpsPin() {
        let rules = HouseRules(accounts: [adult, kid], hasPin: { $0 == "a" })
        #expect(rules.approveGate(for: kid) == .grownUpPin)
    }

    @Test func aKidCannotApproveWhenNoGrownUpHasAPin() {
        let rules = HouseRules(accounts: [adult, kid], hasPin: { _ in false })
        #expect(rules.approveGate(for: kid) == .notAllowed)
    }

    @Test func aBlankPasswordIsSentAsAnEmptyPw() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        let secrets = InMemorySecretStore()
        let profiles = Profiles(
            store: AccountStore(settings: InMemoryKeyValueStore(), secrets: secrets), pins: PinGate(secrets: secrets),
            deviceName: "Apple TV", version: "0.1.0", transport: transport
        )
        _ = try await profiles.signIn(server: testServer, username: "leo", password: "")
        let data = try #require(transport.requests.first?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body["Pw"] == "")
        #expect(body["Username"] == "leo")
    }
}
