import Foundation
import Testing
@testable import MatineKit

/// Who Quick Connect may sign in, and where the app lands afterwards.
@Suite struct QuickConnectPolicyTests {
    let secrets = InMemorySecretStore()

    func profiles(_ t: FakeTransport) -> Profiles {
        Profiles(
            store: AccountStore(settings: InMemoryKeyValueStore(), secrets: secrets),
            pins: PinGate(secrets: secrets), deviceName: "iPhone", version: "1.0", transport: t
        )
    }

    /// The fixture signs in "user-1" with token "tok-123".
    func transport() -> FakeTransport {
        let t = FakeTransport()
        t.on("GET", "/QuickConnect/Enabled", body: "true")
        t.on("POST", "/QuickConnect/Initiate", body: QuickConnectTests.waiting)
        t.on("GET", "/QuickConnect/Connect", body: QuickConnectTests.approved)
        t.on("POST", "/Users/AuthenticateWithQuickConnect", fixture: "auth")
        t.on("POST", "/Sessions/Logout")
        return t
    }

    func logouts(_ t: FakeTransport) -> [String] {
        t.requests.filter { $0.url!.path == "/Sessions/Logout" }.map { $0.value(forHTTPHeaderField: "Authorization") ?? "" }
    }

    func add(_ p: Profiles, id: String, role: ProfileRole = .adult, pin: String? = nil, deviceId: String = "old-device") throws {
        try p.store.upsert(Account(id: id, name: id, server: testServer, deviceId: deviceId, role: role), token: "tok-\(id)")
        if let pin { try p.pins.setPin(pin, for: id) }
    }

    @Test func approvalByAnotherUserInAgainModeIsRefusedAndEnded() async throws {
        let t = transport()
        let p = profiles(t)
        try add(p, id: "kid", role: .kid)
        let session = try await p.startQuickConnect(server: testServer, deviceId: "dev-kid")
        // The fixture approves user-1, but this sign-in is for "kid".
        await #expect(throws: QuickConnectError.wrongUser) {
            _ = try await p.finishQuickConnect(session, policy: .again(userId: "kid"), sleep: { _ in })
        }
        // Nothing saved for the approver, and the session that was opened is ended.
        #expect(p.store.accounts().map(\.id) == ["kid"])
        #expect(try p.store.token(for: "user-1") == nil)
        #expect(logouts(t).count == 1 && logouts(t)[0].contains(#"Token="tok-123""#))
    }

    @Test func theRightUserInAgainModeIsSavedOnTheSameDevice() async throws {
        let t = transport()
        let p = profiles(t)
        try add(p, id: "user-1", deviceId: "dev-known")
        let session = try await p.startQuickConnect(server: testServer, deviceId: "dev-known")
        let result = try await p.finishQuickConnect(session, policy: .again(userId: "user-1"), sleep: { _ in })
        #expect(result.account.deviceId == "dev-known")
        #expect(try p.store.token(for: "user-1") == "tok-123")
        // Same device id: the server replaced the old session, nothing to end.
        #expect(logouts(t).isEmpty)
        let polled = try #require(t.requests.first { $0.url!.path == "/QuickConnect/Connect" })
        #expect(polled.value(forHTTPHeaderField: "Authorization")?.contains(#"DeviceId="dev-known""#) == true)
    }

    @Test func aNewProfileInAHouseWithKidsNeedsAGrownUpFirst() async throws {
        let t = transport()
        let p = profiles(t)
        try add(p, id: "kid", role: .kid)
        try add(p, id: "mum", pin: "1234")
        let session = try await p.startQuickConnect(server: testServer)
        await #expect(throws: QuickConnectError.needsGrownUp) {
            _ = try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: false), sleep: { _ in })
        }
        #expect(p.store.accounts().map(\.id) == ["kid", "mum"])
        #expect(logouts(t).count == 1)

        // Once a grown-up's PIN was asked, the same sign-in goes through.
        let again = try await p.startQuickConnect(server: testServer)
        let result = try await p.finishQuickConnect(again, policy: .newProfile(grownUpCleared: true), sleep: { _ in })
        #expect(result.account.id == "user-1" && result.landing == .home)
    }

    @Test func onlyABrandNewProfileIsMarkedNewAndRemovingItIsAlwaysRuleSafe() async throws {
        // A house with a kid and one grown-up with a PIN: the worst case for removals.
        let t = transport()
        let p = profiles(t)
        try add(p, id: "kid", role: .kid)
        try add(p, id: "mum", pin: "1234")
        let session = try await p.startQuickConnect(server: testServer)
        let fresh = try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: true), sleep: { _ in })
        #expect(fresh.isNew)
        let accounts = p.store.accounts()
        #expect(p.rules(for: accounts).refusal(removing: fresh.account) == nil)
        // The same user signing in again is not new: it may be the last PIN adult.
        let second = try await p.startQuickConnect(server: testServer)
        let again = try await p.finishQuickConnect(second, policy: .newProfile(grownUpCleared: true), sleep: { _ in })
        #expect(!again.isNew)
        // Even an existing sole PIN adult approved this way is never marked new.
        let lone = profiles(transport())
        try add(lone, id: "kid", role: .kid)
        try add(lone, id: "user-1", pin: "4321")
        let third = try await lone.startQuickConnect(server: testServer)
        let existing = try await lone.finishQuickConnect(third, policy: .newProfile(grownUpCleared: true), sleep: { _ in })
        #expect(!existing.isNew)
        #expect(lone.rules(for: lone.store.accounts()).refusal(removing: existing.account) != nil)
    }

    @Test func noKidsNoGrownUpNeeded() async throws {
        let t = transport()
        let p = profiles(t)
        try add(p, id: "mum", pin: "1234")
        let session = try await p.startQuickConnect(server: testServer)
        let result = try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: false), sleep: { _ in })
        #expect(result.account.id == "user-1")
    }

    @Test func aProfileWithAPinLandsOnThePinNotHome() async throws {
        let t = transport()
        let p = profiles(t)
        try add(p, id: "user-1", pin: "4321")
        let session = try await p.startQuickConnect(server: testServer)
        let result = try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: false), sleep: { _ in })
        #expect(result.landing == .pin)
        #expect(p.landing(for: result.account) == .pin)
    }

    @Test func aPinThatCantBeReadCountsAsSet() throws {
        struct Broken: SecretStore {
            func read(_ key: String) throws -> Data? { throw QuickConnectError.disabled }
            func write(_ value: Data, for key: String) throws {}
            func delete(_ key: String) throws {}
            func removeAll() throws {}
        }
        let p = Profiles(store: AccountStore(settings: InMemoryKeyValueStore(), secrets: InMemorySecretStore()),
                         pins: PinGate(secrets: Broken()), deviceName: "iPhone", version: "1.0", transport: FakeTransport())
        #expect(p.landing(for: Account(id: "x", name: "x", server: testServer)) == .pin)
    }

    @Test func aPasswordSessionUnderAnotherDeviceIdIsEnded() async throws {
        let t = transport()
        let p = profiles(t)
        try add(p, id: "user-1", deviceId: "old-device")
        let session = try await p.startQuickConnect(server: testServer)   // a fresh device id
        let result = try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: false), sleep: { _ in })
        #expect(result.account.deviceId != "old-device")
        // The old session (its own token, its own device id) was logged out first.
        let ended = logouts(t)
        #expect(ended.count == 1 && ended[0].contains(#"DeviceId="old-device""#) && ended[0].contains(#"Token="tok-user-1""#))
    }
}

@Suite struct PlaybackProfileTests {
    func body(_ profile: PlaybackProfile) async throws -> [String: Any] {
        let t = FakeTransport()
        t.on("POST", "/Items/movie-1/PlaybackInfo", fixture: "playback-direct")
        _ = try await makeClient(t).playbackPlan(itemId: "movie-1", userId: "u", profile: profile)
        let data = try #require(t.requests.first?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theTVProfileIsUnchanged() async throws {
        let sent = try await body(.appleTV)
        let profile = try #require(sent["DeviceProfile"] as? [String: Any])
        #expect(profile["Name"] as? String == "Matine Apple TV")
        #expect(profile["MaxStreamingBitrate"] as? Int == 120_000_000 && sent["MaxStreamingBitrate"] as? Int == 120_000_000)
        #expect((profile["CodecProfiles"] as? [Any])?.isEmpty == true)
    }

    @Test func aPhoneIsNamedForTheDeviceAndUncappedOnWiFi() async throws {
        let sent = try await body(.phone(device: "iPad", constrained: false))
        let profile = try #require(sent["DeviceProfile"] as? [String: Any])
        #expect(profile["Name"] as? String == "Matine iPad")
        #expect(profile["MaxStreamingBitrate"] as? Int == 40_000_000)
        #expect((profile["CodecProfiles"] as? [Any])?.isEmpty == true)
    }

    @Test func aMeteredConnectionAsksForLess() async throws {
        let sent = try await body(.phone(device: "iPhone", constrained: true))
        #expect(sent["MaxStreamingBitrate"] as? Int == 6_000_000)
        let profile = try #require(sent["DeviceProfile"] as? [String: Any])
        let condition = try #require(((profile["CodecProfiles"] as? [[String: Any]])?.first?["Conditions"] as? [[String: Any]])?.first)
        #expect(condition["Property"] as? String == "Width" && condition["Value"] as? String == "1280")
        #expect(condition["Condition"] as? String == "LessThanEqual")
    }

    @Test func theSourceChoosesTheProfileByDeviceAndConnection() async throws {
        let t = FakeTransport()
        t.on("POST", "/Items/movie-1/PlaybackInfo", fixture: "playback-direct")
        let source = ServerLibrarySource(client: makeClient(t), userId: "u", device: "iPhone")
        _ = try await source.playbackPlan(itemId: "movie-1", startTicks: 0, allowDirectPlay: true, constrained: true)
        let data = try #require(t.requests.first?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(sent["MaxStreamingBitrate"] as? Int == 6_000_000)
    }
}
