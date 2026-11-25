import Foundation
import Testing
@testable import MatineKit

/// iCloud in memory: what the household holds, shared by every device's `FakeHouseholdCloud`.
final class HouseholdHub: @unchecked Sendable {
    let lock = NSLock()
    var seq = 0
    var members: [String: (member: HouseholdMember, seq: Int, by: String)] = [:]
    var requests: [String: (request: ApprovalRequest, seq: Int, by: String)] = [:]
    var accountId = "icloud-a"
}

final class FakeHouseholdCloud: HouseholdCloud, @unchecked Sendable {
    let hub: HouseholdHub
    let me = UUID().uuidString
    private var cursor = 0
    private var signedIn = true
    private(set) var saves = 0
    private(set) var deletes: [String] = []
    private var flagReset = false
    var database: ApprovalRequest.Database = .private
    /// While set, `fetchChanges` waits here until `open()`; `entered` says it has arrived.
    let gate = FetchGate()

    init(_ hub: HouseholdHub) { self.hub = hub }

    func account() async -> KeywordCloudAccount { signedIn ? .available : .noAccount }
    func accountId() async -> String? { hub.lock.withLock { hub.accountId } }
    func signOut() { signedIn = false }
    func markReset() { flagReset = true }

    func fetchChanges() async throws -> HouseholdCloudChanges {
        await gate.pass()
        return hub.lock.withLock {
            let saved = hub.members.values.filter { $0.seq > cursor && $0.by != me }.map(\.member)
            var requests = hub.requests.values.filter { $0.seq > cursor && $0.by != me }.map(\.request)
            for index in requests.indices { requests[index].database = database }
            cursor = hub.seq
            defer { flagReset = false }
            return HouseholdCloudChanges(saved: saved, requests: requests, reset: flagReset)
        }
    }

    func save(members: [HouseholdMember], requests: [ApprovalRequest]) async throws -> Set<String> {
        hub.lock.withLock {
            saves += 1
            for m in members { hub.seq += 1; hub.members[m.recordName] = (m, hub.seq, me) }
            for r in requests { hub.seq += 1; hub.requests[r.id] = (r, hub.seq, me) }
            return Set(members.map(\.recordName) + requests.map(\.id))
        }
    }

    func delete(requestIds: [String]) async throws {
        hub.lock.withLock {
            for id in requestIds { hub.requests[id] = nil }
            deletes += requestIds
        }
    }

    func reset() async {}
}

final class FetchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var arrived = false
    private var waiting: CheckedContinuation<Void, Never>?

    func close() { lock.withLock { closed = true; arrived = false } }
    var entered: Bool { lock.withLock { arrived } }
    func open() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            closed = false
            defer { waiting = nil }
            return waiting
        }
        waiter?.resume()
    }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = lock.withLock { () -> Bool in
                guard closed else { return true }
                arrived = true
                waiting = continuation
                return false
            }
            if proceed { continuation.resume() }
        }
    }
}

/// A Keychain whose reads of the household book can be made to fail.
final class BookFailingSecrets: SecretStore, @unchecked Sendable {
    let inner = InMemorySecretStore()
    private let lock = NSLock()
    private var failing = false
    private(set) var bookWrites = 0
    struct Failure: Error {}
    func failBook(_ on: Bool) { lock.withLock { failing = on } }
    func read(_ key: String) throws -> Data? {
        if key == HouseholdBook.key, lock.withLock({ failing }) { throw Failure() }
        return try inner.read(key)
    }
    func write(_ value: Data, for key: String) throws {
        if key == HouseholdBook.key { lock.withLock { bookWrites += 1 } }
        try inner.write(value, for: key)
    }
    func delete(_ key: String) throws { try inner.delete(key) }
    func removeAll() throws { try inner.removeAll() }
}

final class HouseholdClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 1_800_000_000
    var date: Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
    func advance(_ by: Double) { lock.withLock { seconds += by } }
}

/// One device: its own profiles, Keychain, server connection and view of iCloud.
struct HouseholdDevice {
    let profiles: Profiles
    let sync: HouseholdSync
    let cloud: FakeHouseholdCloud
    let transport: FakeTransport
    let secrets: any SecretStore

    init(_ hub: HouseholdHub, _ clock: HouseholdClock, name: String = "iPad", secrets: (any SecretStore)? = nil) {
        self.secrets = secrets ?? InMemorySecretStore()
        transport = FakeTransport()
        transport.on("GET", "/QuickConnect/Enabled", body: "true")
        transport.on("POST", "/QuickConnect/Authorize", body: "true")
        profiles = Profiles(
            store: AccountStore(settings: InMemoryKeyValueStore(), secrets: self.secrets), pins: PinGate(secrets: self.secrets),
            deviceName: name, version: "1.0", transport: transport
        )
        cloud = FakeHouseholdCloud(hub)
        sync = HouseholdSync(cloud: cloud, profiles: profiles, now: { clock.date })
    }

    var accounts: [Account] { profiles.store.accounts() }
    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
    func hasToken(_ id: String) -> Bool { ((try? profiles.store.token(for: id)) ?? nil) != nil }
    func pin(_ id: String) -> String? { (try? profiles.pins.storedPin(for: id)) ?? nil }

    @discardableResult
    func add(_ id: String, name: String? = nil, role: ProfileRole = .adult, pin: String? = nil) throws -> Account {
        let account = Account(id: id, name: name ?? "user-\(id)", server: testServer, role: role)
        try profiles.store.upsert(account, token: "tok-\(id)")
        if let pin { try profiles.pins.setPin(pin, for: id) }
        return account
    }

    func edit(_ id: String, _ change: (inout Account) -> Void) throws {
        var account = try #require(account(id))
        change(&account)
        try profiles.store.update(account)
    }

    func authorizations() -> Int { transport.requests.filter { $0.url?.path == "/QuickConnect/Authorize" }.count }
}

func record(_ id: String) -> String { HouseholdRecordName.make(server: testServer, userId: id) }

@Suite struct HouseholdMemberTests {
    @Test func theRecordNameHashesTheServerAndUserAndNothingElse() {
        let name = HouseholdRecordName.make(server: testServer, userId: "user-ana")
        #expect(name.hasPrefix("p") && name.count == 33)
        #expect(!name.contains("ana") && !name.contains("example"))
        #expect(name == HouseholdRecordName.make(server: URL(string: "https://tv.example.test/")!, userId: "user-ana"))
        #expect(name != HouseholdRecordName.make(server: testServer, userId: "user-bea"))
    }

    @Test func aMemberCarriesNoTokenNoDeviceIdAndNoAttempts() throws {
        let account = Account(id: "u1", name: "ana", server: testServer, deviceId: "DEVICE-SECRET-ID", displayName: "Mamá")
        let member = HouseholdMember(account: account, pin: "1234", modified: 5)
        let json = String(decoding: try JSONEncoder().encode(member), as: UTF8.self)
        #expect(!json.contains("DEVICE-SECRET-ID") && !json.lowercased().contains("token") && !json.contains("deviceId"))
        #expect(member.pin == "1234" && member.displayName == "Mamá")
    }

    @Test func theNewerCopyWinsAndATombstoneBeatsALiveCopyOfTheSameSecond() {
        let base = HouseholdMember(server: testServer, userId: "u1", name: "ana", modified: 10)
        var newer = base
        newer.modified = 11
        newer.role = .kid
        #expect(newer.supersedes(base) && !base.supersedes(newer))
        var gone = base
        gone.removed = true
        #expect(gone.supersedes(base) && !base.supersedes(gone))
    }

    @Test func twoDifferentCopiesOfTheSameSecondAgreeOnOneWinner() {
        var a = HouseholdMember(server: testServer, userId: "u1", name: "ana", modified: 10)
        var b = a
        a.displayName = "A"
        b.displayName = "B"
        #expect(a.supersedes(b) != b.supersedes(a))
    }
}

@Suite struct ApprovalPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let adult = Account(id: "u1", name: "ana", server: testServer)

    func request(age: TimeInterval = 10, code: String = "123456", user: String = "u1", database: ApprovalRequest.Database = .private) -> ApprovalRequest {
        ApprovalRequest(server: testServer, userId: user, code: code, device: "iPad", created: now.addingTimeInterval(-age), database: database)
    }

    func holder(_ account: Account? = nil, token: Bool = true, member: Bool = true) -> ApprovalPolicy.Holder {
        .init(account: account ?? adult, hasToken: token, inHousehold: member)
    }

    @Test func aFreshRequestForAProfileThisDeviceHoldsIsApproved() {
        #expect(ApprovalPolicy.decide(request(), now: now, holder: holder(), alreadyHandled: false) == .approve)
    }

    @Test func aSharedDatabaseNeverApproves() {
        #expect(ApprovalPolicy.decide(request(database: .shared), now: now, holder: holder(), alreadyHandled: false) == .skip)
    }

    @Test func staleOrFutureRequestsAreDiscarded() {
        #expect(ApprovalPolicy.decide(request(age: 301), now: now, holder: holder(), alreadyHandled: false) == .discard)
        #expect(ApprovalPolicy.decide(request(age: 299), now: now, holder: holder(), alreadyHandled: false) == .approve)
        #expect(ApprovalPolicy.decide(request(age: -61), now: now, holder: holder(), alreadyHandled: false) == .discard)
        #expect(ApprovalPolicy.decide(request(age: -30), now: now, holder: holder(), alreadyHandled: false) == .approve)
    }

    @Test func aCodeThatIsNotSixDigitsIsDiscarded() {
        for code in ["12345", "1234567", "12345a", "", "١٢٣٤٥٦"] {
            #expect(ApprovalPolicy.decide(request(code: code), now: now, holder: holder(), alreadyHandled: false) == .discard)
        }
    }

    @Test func eachRequestIsHandledOnce() {
        #expect(ApprovalPolicy.decide(request(), now: now, holder: holder(), alreadyHandled: true) == .skip)
    }

    @Test func onlyTheDeviceHoldingThatUsersTokenOnThatServerApproves() {
        #expect(ApprovalPolicy.decide(request(), now: now, holder: nil, alreadyHandled: false) == .skip)
        #expect(ApprovalPolicy.decide(request(), now: now, holder: holder(token: false), alreadyHandled: false) == .skip)
        #expect(ApprovalPolicy.decide(request(user: "u2"), now: now, holder: holder(), alreadyHandled: false) == .skip)
        let elsewhere = Account(id: "u1", name: "ana", server: URL(string: "https://other.example.test")!)
        #expect(ApprovalPolicy.decide(request(), now: now, holder: holder(elsewhere), alreadyHandled: false) == .skip)
    }

    @Test func aProfileRemovedFromTheHouseholdNeverApproves() {
        #expect(ApprovalPolicy.decide(request(), now: now, holder: holder(member: false), alreadyHandled: false) == .skip)
    }

    @Test func ageIsCheckedBeforeTheDatabase() {
        #expect(ApprovalPolicy.decide(request(age: 301, database: .shared), now: now, holder: holder(), alreadyHandled: false) == .discard)
        #expect(ApprovalPolicy.decide(request(age: 10, database: .shared), now: now, holder: holder(), alreadyHandled: false) == .skip)
    }

    @Test func aKidProfileNeverApproves() {
        var kid = adult
        kid.role = .kid
        #expect(ApprovalPolicy.decide(request(), now: now, holder: holder(kid), alreadyHandled: false) == .skip)
    }
}

@Suite struct HouseholdSyncTests {
    let hub = HouseholdHub()
    let clock = HouseholdClock()

    @Test func aNewDeviceShowsTheSameProfilesWithoutTokensAndWithTheirPins() async throws {
        let phone = HouseholdDevice(hub, clock, name: "iPhone"), tv = HouseholdDevice(hub, clock, name: "Apple TV")
        try phone.add("ana", pin: "4321")
        try phone.add("kid", role: .kid)
        try phone.edit("kid") { $0.displayName = "Peque"; $0.language = .english }
        _ = await phone.sync.sync()

        let report = await tv.sync.sync()
        #expect(report.changed)
        #expect(Set(tv.accounts.map(\.id)) == ["ana", "kid"])
        #expect(!tv.hasToken("ana") && !tv.hasToken("kid"))
        #expect(tv.pin("ana") == "4321" && tv.pin("kid") == nil)
        let kid = try #require(tv.account("kid"))
        #expect(kid.role == .kid && kid.shownName == "Peque" && kid.language == .english)
        #expect(kid.deviceId != phone.account("kid")?.deviceId)
    }

    @Test func aSecondSyncWithNothingNewSendsNothing() async throws {
        let phone = HouseholdDevice(hub, clock)
        try phone.add("ana")
        _ = await phone.sync.sync()
        let saves = phone.cloud.saves
        clock.advance(10)
        let report = await phone.sync.sync()
        #expect(phone.cloud.saves == saves && !report.changed)
    }

    @Test func anEditOnOneDeviceReachesTheOthers() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("kid", role: .kid)
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()

        clock.advance(60)
        try tv.edit("kid") { $0.displayName = "Nene"; $0.avatar = Avatar(figure: .animal(.cat), color: .teal) }
        try tv.profiles.pins.setPin("2222", for: "ana")
        _ = await tv.sync.sync()
        let report = await phone.sync.sync()
        #expect(report.changed)
        #expect(phone.account("kid")?.shownName == "Nene" && phone.account("kid")?.avatar == Avatar(figure: .animal(.cat), color: .teal))
        #expect(phone.pin("ana") == "2222")
        // Tokens and device ids stay where they are.
        #expect(phone.hasToken("ana"))
    }

    @Test func theNewestEditWinsWholeAndAnOlderOneDoesNotOverwriteIt() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()

        clock.advance(60)
        try phone.edit("ana") { $0.displayName = "Primero" }
        _ = await phone.sync.sync()
        clock.advance(60)
        try tv.edit("ana") { $0.displayName = "Segundo" }
        _ = await tv.sync.sync()
        _ = await phone.sync.sync()
        #expect(phone.account("ana")?.displayName == "Segundo")
        _ = await tv.sync.sync()
        #expect(tv.account("ana")?.displayName == "Segundo")
    }

    @Test func aPinChangeIsAnEditToo() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()
        clock.advance(30)
        try phone.profiles.pins.removePin(for: "ana")
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()
        #expect(tv.pin("ana") == nil)
    }

    @Test func aProfileAlreadyHereTakesTheHouseholdsCopyAtFirstMeeting() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("kid", role: .kid)
        try phone.add("ana", pin: "1111")
        _ = await phone.sync.sync()
        clock.advance(100)
        // The TV signed this user in by password before it ever synced: the household's role stands.
        try tv.add("kid")
        _ = await tv.sync.sync()
        #expect(tv.account("kid")?.role == .kid)
        #expect(tv.hasToken("kid"))
    }

    @Test func signingOutStaysOnThisDeviceAndTheProfileRemainsInTheHousehold() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("kid", role: .kid)
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()

        clock.advance(30)
        try await phone.profiles.endSession(try #require(phone.account("kid")))
        _ = await phone.sync.sync()
        #expect(phone.account("kid") != nil && !phone.hasToken("kid"))
        #expect(phone.account("kid")?.deviceId != nil)
        _ = await tv.sync.sync()
        #expect(tv.account("kid") != nil)
        // Nor does a sync bring the profile back with a PIN it never had, or lose the adult's.
        #expect(phone.pin("ana") == "1111")
    }

    @Test func removingEverywhereLeavesATombstoneEveryDeviceObeys() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("bea")
        _ = await phone.sync.sync()
        try tv.add("bea")
        _ = await tv.sync.sync()
        #expect(tv.account("bea") != nil)

        clock.advance(30)
        try await phone.sync.removeEverywhere(try #require(phone.account("bea")))
        #expect(phone.account("bea") == nil && !phone.hasToken("bea"))
        _ = await phone.sync.sync()
        let report = await tv.sync.sync()
        #expect(tv.account("bea") == nil && !tv.hasToken("bea"))
        #expect(report.removed.map(\.id) == ["bea"])
        // The server session on the TV was ended, best effort.
        #expect(tv.transport.requests.contains { $0.url?.path == "/Sessions/Logout" })
        #expect(tv.account("ana") != nil)
        // A later sync doesn't resurrect it anywhere.
        clock.advance(30)
        _ = await tv.sync.sync()
        _ = await phone.sync.sync()
        #expect(tv.account("bea") == nil && phone.account("bea") == nil)
    }

    @Test func aTombstoneDoesNotKeepThePinOrTheToken() async throws {
        let phone = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("bea", pin: "2222")
        _ = await phone.sync.sync()
        try await phone.sync.removeEverywhere(try #require(phone.account("bea")))
        _ = await phone.sync.sync()
        let held = try #require(hub.members[record("bea")]?.member)
        #expect(held.removed && held.pin.isEmpty)
        #expect(phone.pin("bea") == nil)
    }

    @Test func aProfileSignedInAgainAfterItsTombstoneComesBack() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("bea")
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()
        clock.advance(30)
        try await phone.sync.removeEverywhere(try #require(phone.account("bea")))
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()
        #expect(tv.account("bea") == nil)
        clock.advance(30)
        try tv.add("bea")
        _ = await tv.sync.sync()
        _ = await phone.sync.sync()
        #expect(phone.account("bea") != nil && !phone.hasToken("bea"))
    }

    @Test func aChangeThatWouldLeaveKidsWithoutAnAdultPinIsHeldBackAndReported() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("kid", role: .kid)
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()

        // Another device (not guarded by these rules) publishes ana without a PIN.
        clock.advance(60)
        var unguarded = try #require(hub.members[record("ana")]?.member)
        unguarded.pin = ""
        unguarded.displayName = "Nueva"
        unguarded.modified += 100
        hub.lock.withLock { hub.seq += 1; hub.members[record("ana")] = (unguarded, hub.seq, "other") }

        let report = await tv.sync.sync()
        #expect(report.held == ["user-ana"])
        #expect(tv.pin("ana") == "1111")
        #expect(tv.account("ana")?.displayName == nil)
        #expect(HouseRules(accounts: tv.accounts, hasPin: { tv.pin($0) != nil }).isSafe)
    }

    @Test func aTombstoneForTheOnlyAdultWithAPinIsHeldBack() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("kid", role: .kid)
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()
        var gone = try #require(hub.members[record("ana")]?.member)
        gone.removed = true
        gone.pin = ""
        gone.modified += 100
        hub.lock.withLock { hub.seq += 1; hub.members[record("ana")] = (gone, hub.seq, "other") }

        let report = await tv.sync.sync()
        #expect(report.held == ["user-ana"] && report.removed.isEmpty)
        #expect(tv.account("ana") != nil && tv.pin("ana") == "1111")
    }

    @Test func aKidArrivingBeforeItsAdultIsHeldUntilTheAdultArrives() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("kid", role: .kid)
        _ = await phone.sync.sync()
        // The kid's record reaches the TV first.
        let adultRecord = hub.members[record("ana")]
        hub.lock.withLock { hub.members[record("ana")] = nil }
        var report = await tv.sync.sync()
        #expect(tv.accounts.isEmpty && report.held == ["user-kid"])
        hub.lock.withLock { hub.seq += 1; hub.members[record("ana")] = adultRecord.map { ($0.member, hub.seq, $0.by) } }
        report = await tv.sync.sync()
        #expect(Set(tv.accounts.map(\.id)) == ["ana", "kid"] && report.held.isEmpty)
        #expect(tv.pin("ana") == "1111")
    }

    @Test func aPinThatIsNotFourDigitsIsNeverReadAsNoPin() async throws {
        let tv = HouseholdDevice(hub, clock)
        try tv.add("ana", pin: "1111")
        _ = await tv.sync.sync()
        var bad = try #require(hub.members[record("ana")]?.member)
        bad.pin = "12"
        bad.modified += 100
        hub.lock.withLock { hub.seq += 1; hub.members[record("ana")] = (bad, hub.seq, "other") }
        let report = await tv.sync.sync()
        #expect(report.held == ["user-ana"] && tv.pin("ana") == "1111")
    }

    @Test func anotherAppleIDNeverReceivesTheProfilesAlreadyOnThisDevice() async throws {
        let phone = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        _ = await phone.sync.sync()
        #expect(hub.members[record("ana")] != nil)

        // The device now belongs to someone else's iCloud.
        let other = HouseholdHub()
        other.accountId = "icloud-b"
        let moved = HouseholdDevice(other, clock)
        let sync = HouseholdSync(cloud: moved.cloud, profiles: phone.profiles, now: { clock.date })
        _ = await sync.sync()
        #expect(other.members.isEmpty)
        #expect(phone.account("ana") != nil && phone.pin("ana") == "1111")

        // What it adds afterwards is its new owner's.
        clock.advance(30)
        try phone.add("bea")
        _ = await sync.sync()
        #expect(Set(other.members.keys) == [record("bea")])
    }

    @Test func aResetCloudGetsEverythingAgain() async throws {
        let phone = HouseholdDevice(hub, clock)
        try phone.add("ana")
        _ = await phone.sync.sync()
        hub.lock.withLock { hub.members = [:] }
        phone.cloud.markReset()
        _ = await phone.sync.sync()
        #expect(hub.members[record("ana")] != nil)
    }

    @Test func signedOutOfICloudChangesNothing() async throws {
        let phone = HouseholdDevice(hub, clock)
        try phone.add("ana")
        phone.cloud.signOut()
        let report = await phone.sync.sync()
        #expect(report.unavailable != nil && phone.account("ana") != nil && hub.members.isEmpty)
    }

    // MARK: Approval

    @Test func anotherDeviceApprovesTheRequestAndDeletesIt() async throws {
        let phone = HouseholdDevice(hub, clock, name: "iPhone"), ipad = HouseholdDevice(hub, clock, name: "iPad")
        try phone.add("ana", name: "ana", pin: "1111")
        _ = await phone.sync.sync()
        _ = await ipad.sync.sync()
        #expect(!ipad.hasToken("ana"))

        let id = await ipad.sync.requestApproval(server: testServer, userId: "ana", code: "123456", device: "iPad")
        #expect(id != nil)
        let report = await phone.sync.sync()
        #expect(report.approvals == [.init(device: "iPad", name: "ana")])
        #expect(phone.authorizations() == 1)
        #expect(phone.transport.requests.contains { $0.url?.query?.contains("code=123456") == true })
        #expect(hub.requests.isEmpty)
        // The other device itself never approves its own request.
        #expect(ipad.authorizations() == 0)
    }

    @Test func eachRequestIsApprovedOnceEvenIfItIsSeenAgain() async throws {
        let phone = HouseholdDevice(hub, clock), ipad = HouseholdDevice(hub, clock)
        try phone.add("ana")
        _ = await phone.sync.sync()
        let id = try #require(await ipad.sync.requestApproval(server: testServer, userId: "ana", code: "123456", device: "iPad"))
        let request = try #require(hub.requests[id]?.request)
        #expect(await phone.sync.sync().approvals.count == 1)
        // CloudKit delivers the same request again (e.g. after a reset).
        hub.lock.withLock { hub.seq += 1; hub.requests[id] = (request, hub.seq, "x") }
        phone.cloud.markReset()
        #expect(await phone.sync.sync().approvals.isEmpty)
        #expect(phone.authorizations() == 1)
    }

    @Test func aStaleRequestIsDeletedNotApproved() async throws {
        let phone = HouseholdDevice(hub, clock), ipad = HouseholdDevice(hub, clock)
        try phone.add("ana")
        _ = await phone.sync.sync()
        let id = try #require(await ipad.sync.requestApproval(server: testServer, userId: "ana", code: "123456", device: "iPad"))
        clock.advance(6 * 60)
        let report = await phone.sync.sync()
        #expect(report.approvals.isEmpty && phone.authorizations() == 0)
        #expect(hub.requests[id] == nil)
    }

    @Test func aRequestFromASharedDatabaseIsNeverApproved() async throws {
        let phone = HouseholdDevice(hub, clock), ipad = HouseholdDevice(hub, clock)
        try phone.add("ana")
        _ = await phone.sync.sync()
        phone.cloud.database = .shared
        let id = try #require(await ipad.sync.requestApproval(server: testServer, userId: "ana", code: "123456", device: "iPad"))
        let report = await phone.sync.sync()
        #expect(report.approvals.isEmpty && phone.authorizations() == 0)
        #expect(hub.requests[id] != nil)
    }

    @Test func aKidProfileIsNeverApprovedAutomatically() async throws {
        let phone = HouseholdDevice(hub, clock), ipad = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("kid", role: .kid)
        _ = await phone.sync.sync()
        _ = await ipad.sync.requestApproval(server: testServer, userId: "kid", code: "123456", device: "iPad")
        #expect(await phone.sync.sync().approvals.isEmpty)
        #expect(phone.authorizations() == 0)
    }

    @Test func aDeviceWithoutThatProfilesTokenLeavesTheRequestForOthers() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock), ipad = HouseholdDevice(hub, clock)
        try phone.add("ana")
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()
        let id = try #require(await ipad.sync.requestApproval(server: testServer, userId: "ana", code: "123456", device: "iPad"))
        #expect(await tv.sync.sync().approvals.isEmpty)
        #expect(hub.requests[id] != nil)
        #expect(await phone.sync.sync().approvals.count == 1)
    }

    @Test func aProfileRemovedFromTheHouseholdIsNotApproved() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock), ipad = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("bea")
        _ = await phone.sync.sync()
        try tv.add("bea")
        _ = await tv.sync.sync()
        clock.advance(10)
        try await phone.sync.removeEverywhere(try #require(phone.account("bea")))
        _ = await phone.sync.sync()
        // The TV has not yet heard of the tombstone when the request arrives, but does in the same sync.
        _ = await ipad.sync.requestApproval(server: testServer, userId: "bea", code: "123456", device: "iPad")
        #expect(await tv.sync.sync().approvals.isEmpty)
        #expect(tv.authorizations() == 0)
    }

    @Test func aFailedApprovalLeavesTheCodeForAnyoneToApproveByHand() async throws {
        let phone = HouseholdDevice(hub, clock), ipad = HouseholdDevice(hub, clock)
        phone.transport.on("POST", "/QuickConnect/Authorize", status: 404)
        try phone.add("ana")
        _ = await phone.sync.sync()
        let id = try #require(await ipad.sync.requestApproval(server: testServer, userId: "ana", code: "123456", device: "iPad"))
        #expect(await phone.sync.sync().approvals.isEmpty)
        #expect(hub.requests[id] != nil)
    }

    @Test func withdrawingARequestDeletesIt() async throws {
        let ipad = HouseholdDevice(hub, clock)
        let id = try #require(await ipad.sync.requestApproval(server: testServer, userId: "ana", code: "123456", device: "iPad"))
        await ipad.sync.withdraw(id)
        #expect(hub.requests.isEmpty)
    }

    @Test func noRequestIsPostedWithoutICloud() async {
        let ipad = HouseholdDevice(hub, clock)
        ipad.cloud.signOut()
        #expect(await ipad.sync.requestApproval(server: testServer, userId: "ana", code: "123456", device: "iPad") == nil)
    }

    // MARK: Undoing a sign-in, racing, and the review's other cases

    @Test func undoingAHeldSignInOfAUserTheHouseholdKnowsWritesNoTombstone() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("bea")
        _ = await phone.sync.sync()

        // Someone else is signed in as bea on the TV by a code; "No soy yo" is still possible.
        try tv.add("bea")
        await tv.sync.hold(userId: "bea")
        clock.advance(30)
        _ = await tv.sync.sync()
        await tv.sync.forget(try #require(tv.account("bea")))
        clock.advance(30)
        _ = await tv.sync.sync()
        _ = await phone.sync.sync()

        let held = try #require(hub.members[record("bea")]?.member)
        #expect(!held.removed)
        #expect(phone.account("bea") != nil)
        // bea is still a household profile here, needing sign-in.
        #expect(tv.account("bea") != nil && !tv.hasToken("bea"))
    }

    @Test func undoingAHeldSignInOfANewUserLeavesNoTrace() async throws {
        let phone = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        _ = await phone.sync.sync()
        try phone.add("eve")
        await phone.sync.hold(userId: "eve")
        _ = await phone.sync.sync()
        #expect(hub.members[record("eve")] == nil)
        await phone.sync.forget(try #require(phone.account("eve")))
        clock.advance(30)
        _ = await phone.sync.sync()
        #expect(phone.account("eve") == nil && hub.members[record("eve")] == nil)
    }

    @Test func aHeldSignInIsPublishedOnceReleased() async throws {
        let phone = HouseholdDevice(hub, clock)
        try phone.add("eve")
        await phone.sync.hold(userId: "eve")
        _ = await phone.sync.sync()
        #expect(hub.members[record("eve")] == nil)
        await phone.sync.release(userId: "eve")
        _ = await phone.sync.sync()
        #expect(hub.members[record("eve")] != nil)
    }

    @Test func aRemovalMadeWhileASyncIsInFlightIsNotOverwrittenByIt() async throws {
        let phone = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("bea")
        _ = await phone.sync.sync()
        clock.advance(30)

        phone.cloud.gate.close()
        let inFlight = Task { await phone.sync.sync() }
        while !phone.cloud.gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        try await phone.sync.removeEverywhere(try #require(phone.account("bea")))
        phone.cloud.gate.open()
        _ = await inFlight.value
        clock.advance(30)
        _ = await phone.sync.sync()
        #expect(hub.members[record("bea")]?.member.removed == true)
        #expect(phone.account("bea") == nil)
    }

    @Test func aKeychainErrorIsNotAnEmptyBook() async throws {
        let secrets = BookFailingSecrets()
        let phone = HouseholdDevice(hub, clock, secrets: secrets)
        try phone.add("ana")
        _ = await phone.sync.sync()
        let writes = secrets.bookWrites
        #expect(writes > 0)

        // The same Keychain read fails when a fresh actor loads the book.
        secrets.failBook(true)
        let again = HouseholdSync(cloud: phone.cloud, profiles: phone.profiles, now: { clock.date })
        let report = await again.sync()
        #expect(report.unavailable != nil)
        #expect(secrets.bookWrites == writes)
    }

    @Test func aHeldBackChangeDoesNotHoldBackWhatTheHouseCanTake() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("kid", role: .kid)
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()

        // Other devices publish: ana's PIN gone (unsafe), a new adult without a PIN and a new kid (both fine).
        var noPin = try #require(hub.members[record("ana")]?.member)
        noPin.pin = ""
        noPin.modified += 100
        let cy = HouseholdMember(server: testServer, userId: "cy", name: "user-cy", modified: noPin.modified)
        let kid2 = HouseholdMember(server: testServer, userId: "kid2", name: "user-kid2", role: .kid, modified: noPin.modified)
        hub.lock.withLock {
            for member in [noPin, cy, kid2] { hub.seq += 1; hub.members[member.recordName] = (member, hub.seq, "other") }
        }
        let report = await tv.sync.sync()
        #expect(Set(tv.accounts.map(\.id)) == ["ana", "kid", "cy", "kid2"])
        #expect(report.held == ["user-ana"] && tv.pin("ana") == "1111")
    }

    @Test func aTombstoneForAProfileThisDeviceIsSignedInAsDoesNotRemoveItAtFirstMeeting() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("bea")
        _ = await phone.sync.sync()
        try await phone.sync.removeEverywhere(try #require(phone.account("bea")))
        _ = await phone.sync.sync()

        clock.advance(60)
        try tv.add("bea")
        _ = await tv.sync.sync()
        #expect(tv.account("bea") != nil && tv.hasToken("bea"))
        let revived = try #require(hub.members[record("bea")]?.member)
        #expect(!revived.removed)
    }

    @Test func aMemberNeverShowsItsPin() {
        let member = HouseholdMember(server: testServer, userId: "u1", name: "ana", pin: "9876", modified: 5)
        #expect(!"\(member)".contains("9876") && !String(reflecting: member).contains("9876"))
    }

    @Test func aTrailingSlashOnTheServerStillMatches() {
        let slash = URL(string: "https://tv.example.test/")!
        let account = Account(id: "u1", name: "ana", server: slash)
        let request = ApprovalRequest(server: testServer, userId: "u1", code: "123456", device: "iPad", created: Date())
        let holder = ApprovalPolicy.Holder(account: account, hasToken: true, inHousehold: true)
        #expect(ApprovalPolicy.decide(request, now: Date(), holder: holder, alreadyHandled: false) == .approve)
    }

    @Test func aMutedProfileTakesTheNewAccountsTombstone() async throws {
        let phone = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        try phone.add("bea")
        _ = await phone.sync.sync()

        // The device joins another Apple ID whose household already removed bea.
        let other = HouseholdHub()
        other.accountId = "icloud-b"
        let gone = HouseholdMember(server: testServer, userId: "bea", name: "user-bea", modified: 2_000_000_000, removed: true)
        let ana = HouseholdMember(server: testServer, userId: "ana", name: "user-ana", pin: "1111", modified: 2_000_000_000)
        other.lock.withLock {
            for member in [gone, ana] { other.seq += 1; other.members[member.recordName] = (member, other.seq, "x") }
        }
        let moved = HouseholdDevice(other, clock)
        let sync = HouseholdSync(cloud: moved.cloud, profiles: phone.profiles, now: { clock.date })
        _ = await sync.sync()
        #expect(phone.account("bea") == nil && phone.account("ana") != nil)
    }

    @Test func aProfileAppearingWhileASignInIsAwaitedIsNotPublishedAsNew() async throws {
        let phone = HouseholdDevice(hub, clock)
        try phone.add("ana", pin: "1111")
        _ = await phone.sync.sync()
        await phone.sync.holdNewSignIns(true)
        try phone.add("eve")
        _ = await phone.sync.sync()
        #expect(hub.members[record("eve")] == nil)
        await phone.sync.holdNewSignIns(false)
        _ = await phone.sync.sync()
        #expect(hub.members[record("eve")] != nil)
    }
}
