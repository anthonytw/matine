import Foundation
import Testing
@testable import MatineKit

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

@Suite struct QuickConnectTests {
    static let waiting = #"{"Authenticated":false,"Secret":"qc-secret-1","Code":"123456"}"#
    static let approved = #"{"Authenticated":true,"Secret":"qc-secret-1","Code":"123456"}"#

    func profiles(_ t: FakeTransport) -> Profiles {
        Profiles(
            store: AccountStore(settings: InMemoryKeyValueStore(), secrets: InMemorySecretStore()),
            pins: PinGate(secrets: InMemorySecretStore()), deviceName: "iPhone", version: "1.0", transport: t
        )
    }

    func transport(connect: String = waiting) -> FakeTransport {
        let t = FakeTransport()
        t.on("GET", "/QuickConnect/Enabled", body: "true")
        t.on("POST", "/QuickConnect/Initiate", body: Self.waiting)
        t.on("GET", "/QuickConnect/Connect", body: connect)
        t.on("POST", "/Users/AuthenticateWithQuickConnect", fixture: "auth")
        return t
    }

    @Test func startShowsTheCodeAndKeepsTheSecretInside() async throws {
        let t = transport()
        let session = try await profiles(t).startQuickConnect(server: testServer)
        #expect(session.code == "123456")
        #expect(!"\(session)".contains("qc-secret-1") && !String(reflecting: session).contains("qc-secret-1"))
        // Initiate is anonymous: no token goes with it.
        #expect(t.requests.allSatisfy { !($0.value(forHTTPHeaderField: "Authorization") ?? "").contains("Token=") })
    }

    @Test func disabledServerIsSaidSo() async {
        let t = transport()
        t.on("GET", "/QuickConnect/Enabled", body: "false")
        await #expect(throws: QuickConnectError.disabled) { _ = try await profiles(t).startQuickConnect(server: testServer) }
    }

    @Test func anAddressThatIsNotHTTPIsRefused() async {
        await #expect(throws: JellyfinError.unsupportedServer) {
            _ = try await profiles(transport()).startQuickConnect(server: URL(string: "ftp://tv.example.test")!)
        }
    }

    @Test func pollsWithBackoffThenSignsInAndSavesTheProfile() async throws {
        let t = transport()
        let p = profiles(t)
        let session = try await p.startQuickConnect(server: testServer)
        let delays = DelayLog()
        let signedIn = try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: true), sleep: { delay in
            delays.add(delay)
            // Approved while the app waits.
            if delays.all.count == 3 { t.on("GET", "/QuickConnect/Connect", body: Self.approved) }
        })
        let account = signedIn.account
        #expect(signedIn.landing == .home)
        #expect(delays.all == [.seconds(2), .seconds(3), .seconds(4.5)])
        #expect(try p.store.token(for: account.id) != nil)
        #expect(p.store.accounts().map(\.id) == [account.id])
        // The profile keeps the device id the request was made with.
        let polled = try #require(t.requests.first { $0.url!.path == "/QuickConnect/Connect" })
        #expect(polled.value(forHTTPHeaderField: "Authorization")?.contains(account.deviceId) == true)
    }

    @Test func aCheckCutOffWhileTheAppIsAwayKeepsWaiting() async throws {
        // On the same phone: the code is approved in Safari while Matiné is
        // suspended, and the check in flight comes back as a network error.
        let t = transport()
        let p = profiles(t)
        let session = try await p.startQuickConnect(server: testServer)
        t.on("GET", "/QuickConnect/Connect", unreachable: true)
        let delays = DelayLog()
        let signedIn = try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: true), sleep: { delay in
            delays.add(delay)
            if delays.all.count == 2 { t.on("GET", "/QuickConnect/Connect", body: Self.approved) }
        })
        #expect(signedIn.landing == .home)
        #expect(delays.all.count == 2)
    }

    @Test func stillUnreachableAtTheEndSaysSoNotExpired() async throws {
        let t = transport()
        let p = profiles(t)
        let session = try await p.startQuickConnect(server: testServer)
        t.on("GET", "/QuickConnect/Connect", unreachable: true)
        await #expect(throws: JellyfinError.transport(code: URLError.notConnectedToInternet.rawValue)) {
            try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: true), timeout: 10, sleep: { _ in })
        }
    }

    @Test func approvingWhileQuickConnectIsOffSaysSoInsteadOfSigningOut() async throws {
        let t = transport()
        let p = profiles(t)
        t.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        let account = try await p.signIn(server: testServer, username: "u", password: "p")
        t.on("GET", "/QuickConnect/Enabled", body: "false")
        t.on("POST", "/QuickConnect/Authorize", status: 401)
        await #expect(throws: QuickConnectError.disabled) { try await p.approveQuickConnect(code: "123456", as: account) }
    }

    @Test func theBackoffStopsGrowingAtTheCeiling() async throws {
        let t = transport()
        let p = profiles(t)
        let session = try await p.startQuickConnect(server: testServer)
        let delays = DelayLog()
        _ = try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: true), sleep: { delay in
            delays.add(delay)
            if delays.all.count == 6 { t.on("GET", "/QuickConnect/Connect", body: Self.approved) }
        })
        #expect(delays.all.max() == .seconds(6))
    }

    @Test func nobodyApprovingTimesOut() async throws {
        let t = transport()
        let p = profiles(t)
        let session = try await p.startQuickConnect(server: testServer)
        await #expect(throws: QuickConnectError.timedOut) {
            _ = try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: true), timeout: 10, sleep: { _ in })
        }
        #expect(p.store.accounts().isEmpty)
    }

    @Test func aLapsedRequestIsExpiredNotAnError() async throws {
        let t = transport()
        let p = profiles(t)
        let session = try await p.startQuickConnect(server: testServer)
        t.on("GET", "/QuickConnect/Connect", status: 404)
        await #expect(throws: QuickConnectError.expired) { _ = try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: true), sleep: { _ in }) }
    }

    @Test func cancellingStopsPolling() async throws {
        let t = transport()
        let p = profiles(t)
        let session = try await p.startQuickConnect(server: testServer)
        let task = Task { try await p.finishQuickConnect(session, policy: .newProfile(grownUpCleared: true), sleep: { _ in try await Task.sleep(for: .seconds(60)) }) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func approvingSendsTheCodeAsTheSignedInProfile() async throws {
        let t = FakeTransport()
        t.on("GET", "/QuickConnect/Enabled", body: "true")
        t.on("POST", "/QuickConnect/Authorize", body: "true")
        let p = profiles(t)
        let account = try p.saveSignIn(user: User(id: "u1", name: "Ana", serverId: nil), token: "tok-9", server: testServer, deviceId: "d1")
        try await p.approveQuickConnect(code: " 654321 ", as: account)
        let request = try #require(t.requests.first { $0.url!.path == "/QuickConnect/Authorize" })
        #expect(request.query("code") == "654321")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains(#"Token="tok-9""#) == true)
    }

    @Test func badCodesNeverReachTheServer() async throws {
        let t = FakeTransport()
        let p = profiles(t)
        let account = try p.saveSignIn(user: User(id: "u1", name: "Ana", serverId: nil), token: "tok-9", server: testServer, deviceId: "d1")
        for typed in ["12345", "1234567", "12a456", ""] {
            await #expect(throws: QuickConnectError.invalidCode) { try await p.approveQuickConnect(code: typed, as: account) }
        }
        #expect(t.requests.isEmpty)
    }

    @Test func aCodeTheServerDoesNotKnowIsInvalid() async throws {
        let t = FakeTransport()
        t.on("GET", "/QuickConnect/Enabled", body: "true")
        t.on("POST", "/QuickConnect/Authorize", status: 404)
        let p = profiles(t)
        let account = try p.saveSignIn(user: User(id: "u1", name: "Ana", serverId: nil), token: "tok-9", server: testServer, deviceId: "d1")
        await #expect(throws: QuickConnectError.invalidCode) { try await p.approveQuickConnect(code: "111111", as: account) }
    }
}

final class DelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [Duration] = []
    func add(_ d: Duration) { lock.withLock { delays.append(d) } }
    var all: [Duration] { lock.withLock { delays } }
}
