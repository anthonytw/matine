import Foundation
import Testing
@testable import MatineKit

/// A URLProtocol that fails every request with one URLError.
final class FailingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var code = URLError.Code.cancelled
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(Self.code)) }
    override func stopLoading() {}
}

@Suite(.serialized) struct CancellationTests {
    @Test func aCancelledRequestIsACancelledTaskNotALostConnection() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: configuration))
        FailingProtocol.code = .cancelled
        await #expect(throws: CancellationError.self) { _ = try await transport.perform(URLRequest(url: testServer)) }
        FailingProtocol.code = .notConnectedToInternet
        await #expect(throws: JellyfinError.transport(code: URLError.notConnectedToInternet.rawValue)) {
            _ = try await transport.perform(URLRequest(url: testServer))
        }
    }

    @Test func onlyRealConnectionTroubleCountsAsOffline() {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff] {
            #expect(JellyfinError.transport(code: code.rawValue).isConnectivity)
        }
        for code in [URLError.Code.cancelled, .badURL, .serverCertificateUntrusted, .badServerResponse] {
            #expect(!JellyfinError.transport(code: code.rawValue).isConnectivity)
        }
        for status in [0, 502, 503, 504] { #expect(JellyfinError.http(status: status).isConnectivity) }
        for status in [400, 401, 404, 500] { #expect(!JellyfinError.http(status: status).isConnectivity) }
    }

    @Test func aCancelledReadLeavesTheAppOnline() async throws {
        let rig = Rig()
        rig.lib.transport.on("GET", "/UserViews", fixture: "user-views", delay: .seconds(5))
        let store = rig.downloader.store(for: "user-1")
        let connection = ConnectionState()
        let source = HybridLibrarySource(
            server: ServerLibrarySource(client: rig.client, userId: "user-1", device: "iPhone"),
            local: LocalLibrarySource(store: store, queue: ProgressQueue(store: store)), connection: connection
        )
        let task = Task { try await source.libraries() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.result
        #expect(!connection.isOffline)
        // And a transport that reports the cancellation the way URLSession now does.
        let throwing = FakeTransport()
        throwing.on("GET", "/UserViews", unreachable: true)
        throwing.cancelOnNextCall = true
        let other = HybridLibrarySource(
            server: ServerLibrarySource(client: makeClient(throwing), userId: "user-1", device: "iPhone"),
            local: LocalLibrarySource(store: store, queue: ProgressQueue(store: store)), connection: connection
        )
        await #expect(throws: CancellationError.self) { _ = try await other.libraries() }
        #expect(!connection.isOffline)
    }
}

@Suite struct FlushRulesTests {
    func setup(_ server: String, position: Int64 = 400, at: Date = Date()) -> (ProgressQueue, FakeTransport) {
        let store = DownloadStore(root: tempRoot(), userId: "user-1")
        let queue = ProgressQueue(store: store)
        let t = FakeTransport()
        t.on("GET", "/Items/a", body: server)
        t.on("POST", "/UserItems/a/UserData")
        queue.record(itemId: "a", positionTicks: position, played: false, at: at)
        return (queue, t)
    }

    func item(_ extra: String) -> String { itemJSON("a", "A", "Movie", extra: #""RunTimeTicks":1000,"# + extra) }
    func posts(_ t: FakeTransport) -> Int { t.requests.filter { $0.httpMethod == "POST" }.count }

    @Test func aPositionIsNotSentForSomethingTheServerHasWatched() async throws {
        let (queue, t) = setup(item(#""UserData":{"Played":true}"#))
        #expect(try await queue.flush(client: makeClient(t), userId: "user-1") == 0)
        #expect(posts(t) == 0 && queue.pending.isEmpty)
    }

    @Test func aPositionOlderThanAnotherDevicesIsNotSent() async throws {
        let (queue, t) = setup(item(#""UserData":{"LastPlayedDate":"2026-11-24T20:00:00.0000000Z"}"#), at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try await queue.flush(client: makeClient(t), userId: "user-1") == 0)
        #expect(posts(t) == 0)
    }

    @Test func aPositionNewerThanTheServersIsSent() async throws {
        let (queue, t) = setup(item(#""UserData":{"LastPlayedDate":"2026-11-20T20:00:00Z"}"#), at: Date(timeIntervalSince1970: 1_795_300_000))
        #expect(try await queue.flush(client: makeClient(t), userId: "user-1") == 1)
        #expect(posts(t) == 1)
    }

    @Test func theFirstFewPercentMakeNoResumePoint() async throws {
        let (queue, t) = setup(item(""), position: 40)
        #expect(try await queue.flush(client: makeClient(t), userId: "user-1") == 0)
        #expect(posts(t) == 0 && queue.pending.isEmpty)
        let store = DownloadStore(root: tempRoot(), userId: "u")
        var movie = Item(id: "x", name: "N", kind: .movie)
        movie.runTimeTicks = 1000
        try store.begin(DownloadedItem(item: movie, state: .complete, method: .original, mediaSourceId: "m", fileName: nil, bytes: 0, addedAt: Date(), touchedAt: nil, libraryId: nil), parents: [])
        store.applyProgress(itemId: "x", positionTicks: 40)
        #expect(store.entry("x")?.item.userData?.playbackPositionTicks == 0 && store.entry("x")?.item.progressPercent == nil)
    }

    @Test func aWatchedMarkAlwaysGoes() async throws {
        let store = DownloadStore(root: tempRoot(), userId: "user-1")
        let queue = ProgressQueue(store: store)
        let t = FakeTransport()
        t.on("POST", "/UserPlayedItems/a")
        queue.record(itemId: "a", positionTicks: 0, played: true, at: Date(timeIntervalSince1970: 1))
        #expect(try await queue.flush(client: makeClient(t), userId: "user-1") == 1)
        #expect(t.requests.map(\.httpMethod) == ["POST"])
    }

    @Test func aRefusedRecordDoesNotHoldUpTheNextOne() async throws {
        let store = DownloadStore(root: tempRoot(), userId: "user-1")
        let queue = ProgressQueue(store: store)
        let t = FakeTransport()
        t.on("GET", "/Items/a", body: item(""))
        t.on("GET", "/Items/b", body: itemJSON("b", "B", "Movie", extra: #""RunTimeTicks":1000"#))
        t.on("POST", "/UserItems/a/UserData", status: 400)
        t.on("POST", "/UserItems/b/UserData")
        queue.record(itemId: "a", positionTicks: 400, played: false, at: Date(timeIntervalSince1970: 1))
        queue.record(itemId: "b", positionTicks: 400, played: false, at: Date(timeIntervalSince1970: 2))
        #expect(try await queue.flush(client: makeClient(t), userId: "user-1") == 1)
        #expect(queue.pending.isEmpty)
    }

    @Test func aServerErrorStopsTheFlushAndKeepsEverything() async throws {
        let (queue, t) = setup(item(""))
        t.on("POST", "/UserItems/a/UserData", status: 500)
        await #expect(throws: JellyfinError.http(status: 500)) { try await queue.flush(client: makeClient(t), userId: "user-1") }
        #expect(queue.pending.count == 1)
    }
}

@Suite struct DownloadRobustnessTests {
    @Test func aRefusalDeletesResumeDataAndIsNotRetriedByItself() async throws {
        let rig = Rig()
        rig.engine.behavior = "fail"
        rig.engine.failStatus = 403
        try await rig.download("f1")
        let store = rig.downloader.store(for: "user-1")
        #expect(store.entry("f1")?.state == .failed && store.entry("f1")?.failure == .refused)
        #expect(!FileManager.default.fileExists(atPath: store.resumeURL(itemId: "f1").path))
        #expect(rig.updates.all.last?.status == 403)
        rig.engine.behavior = "ok"
        await rig.downloader.resumeAll(client: rig.client, userId: "user-1")
        #expect(rig.engine.requests.count == 1)
        await rig.downloader.resumeAll(client: rig.client, userId: "user-1", includingRefused: true)
        await rig.settle()
        #expect(rig.engine.requests.count == 2 && store.entry("f1")?.state == .complete)
    }

    @Test func aLostConnectionIsRetriedByItselfWithItsResumeData() async throws {
        let rig = Rig()
        rig.engine.behavior = "fail"
        try await rig.download("f1")
        let store = rig.downloader.store(for: "user-1")
        #expect(store.entry("f1")?.failure == .connection)
        rig.engine.behavior = "ok"
        await rig.downloader.resumeAll(client: rig.client, userId: "user-1")
        await rig.settle()
        #expect(store.entry("f1")?.state == .complete && store.entry("f1")?.failure == nil)
    }

    @Test func aFileThatArrivedWhileTheAppWasGoneIsMarkedCompleteNotFetchedAgain() async throws {
        let rig = Rig()
        rig.engine.behavior = "hang"
        try await rig.download("f1")
        let store = rig.downloader.store(for: "user-1")
        store.setExpectedBytes("f1", 8)
        try Data("fake-mp4".utf8).write(to: store.fileURL(itemId: "f1"))
        rig.engine.cancel(key: "user-1/f1")
        await rig.downloader.resumeAll(client: rig.client, userId: "user-1")
        #expect(store.entry("f1")?.state == .complete && store.entry("f1")?.bytes == 8)
        #expect(rig.engine.requests.count == 1)
    }

    @Test func aPartialFileOfTheWrongSizeIsFetchedAgain() async throws {
        let rig = Rig()
        rig.engine.behavior = "hang"
        try await rig.download("f1")
        let store = rig.downloader.store(for: "user-1")
        store.setExpectedBytes("f1", 100)
        try Data("short".utf8).write(to: store.fileURL(itemId: "f1"))
        rig.engine.cancel(key: "user-1/f1")
        await rig.downloader.resumeAll(client: rig.client, userId: "user-1")
        #expect(rig.engine.requests.count == 2)
    }

    @Test func askingTwiceAtOnceIsOneTransfer() async throws {
        let rig = Rig()
        rig.lib.transport.on("GET", "/Items/f1", body: itemJSON("f1", "Una película", "Movie", extra: #""RunTimeTicks":2000"#), delay: .milliseconds(100))
        await rig.downloader.start()
        async let first: Void = rig.downloader.enqueue(itemId: "f1", client: rig.client, userId: "user-1")
        async let second: Void = rig.downloader.enqueue(itemId: "f1", client: rig.client, userId: "user-1")
        _ = try await (first, second)
        await rig.settle()
        #expect(rig.engine.requests.count == 1)
    }

    @Test func deleteAllDuringAnEnqueueWins() async throws {
        let rig = Rig()
        rig.lib.transport.on("GET", "/Items/f1", body: itemJSON("f1", "Una película", "Movie", extra: #""RunTimeTicks":2000"#), delay: .milliseconds(150))
        await rig.downloader.start()
        async let pending: Void = rig.downloader.enqueue(itemId: "f1", client: rig.client, userId: "user-1")
        try await Task.sleep(for: .milliseconds(40))
        await rig.downloader.removeAll(userId: "user-1")
        try await pending
        #expect(rig.engine.requests.isEmpty)
        #expect(rig.downloader.store(for: "user-1").entries().isEmpty)
    }

    @Test func deletingTheItemDuringAnEnqueueWins() async throws {
        let rig = Rig()
        rig.lib.transport.on("GET", "/Items/f1", body: itemJSON("f1", "Una película", "Movie", extra: #""RunTimeTicks":2000"#), delay: .milliseconds(150))
        await rig.downloader.start()
        async let pending: Void = rig.downloader.enqueue(itemId: "f1", client: rig.client, userId: "user-1")
        try await Task.sleep(for: .milliseconds(40))
        await rig.downloader.remove(itemId: "f1", userId: "user-1")
        try await pending
        #expect(rig.engine.requests.isEmpty && rig.downloader.store(for: "user-1").entries().isEmpty)
    }

    @Test func eraseRemovesTheWholeProfileFolderIncludingQueuedProgress() async throws {
        let rig = Rig()
        try await rig.download("f1")
        let store = rig.downloader.store(for: "user-1")
        ProgressQueue(store: store).record(itemId: "f1", positionTicks: 500, played: false)
        let directory = store.directory
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("progress.json").path))
        await rig.downloader.erase(userId: "user-1")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // A fresh store for the same id starts empty.
        #expect(rig.downloader.store(for: "user-1").entries().isEmpty)
    }

    @Test func aDownloadTheServerNowRefusesIsDeletedWithItsParents() async throws {
        let rig = Rig()
        try await rig.download("e1", "f1")
        let store = rig.downloader.store(for: "user-1")
        rig.lib.transport.on("GET", "/Items/e1", status: 404)
        rig.lib.transport.on("GET", "/Items/f1", status: 403)
        let removed = Removed()
        try await DownloadSync.run(store: store, queue: ProgressQueue(store: store), client: rig.client, removed: { removed.add($0) })
        #expect(Set(removed.all) == ["e1", "f1"])
        #expect(store.entries().isEmpty && store.snapshot().parents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(itemId: "e1").path))
    }

    @Test func aServerHiccupDuringSyncDeletesNothing() async throws {
        let rig = Rig()
        try await rig.download("f1")
        let store = rig.downloader.store(for: "user-1")
        rig.lib.transport.on("GET", "/Items/f1", status: 500)
        try await DownloadSync.run(store: store, queue: ProgressQueue(store: store), client: rig.client)
        #expect(store.entry("f1") != nil)
    }

    @Test func aFailedManifestWriteThrowsAndLeavesMemoryAsItWas() throws {
        let store = DownloadStore(root: tempRoot(), userId: "u")
        let movie = Item(id: "x", name: "N", kind: .movie)
        let entry = DownloadedItem(item: movie, state: .downloading, method: .original, mediaSourceId: "m", fileName: nil, bytes: 0, addedAt: Date(), touchedAt: nil, libraryId: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path) }
        #expect(throws: (any Error).self) { try store.begin(entry, parents: []) }
        #expect(store.entry("x") == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path)
        try store.begin(entry, parents: [])
        #expect(store.entry("x") != nil)
    }

    @Test func anEnqueueDroppedForAnExistingDownloadReportsItsRealState() async throws {
        let rig = Rig()
        try await rig.download("f1")
        let before = rig.updates.all.count
        try await rig.downloader.enqueue(itemId: "f1", client: rig.client, userId: "user-1")
        let last = try #require(rig.updates.all.dropFirst(before).last)
        #expect(last.itemId == "f1" && last.state == .complete)
    }

    @Test func anAbandonedEnqueueTellsTheScreensTheItemIsGone() async throws {
        let rig = Rig()
        rig.lib.transport.on("GET", "/Items/f1", body: itemJSON("f1", "Una película", "Movie", extra: #""RunTimeTicks":2000"#), delay: .milliseconds(150))
        await rig.downloader.start()
        async let pending: Void = rig.downloader.enqueue(itemId: "f1", client: rig.client, userId: "user-1")
        try await Task.sleep(for: .milliseconds(40))
        await rig.downloader.remove(itemId: "f1", userId: "user-1")
        try await pending
        let last = try #require(rig.updates.all.last)
        #expect(last.itemId == "f1" && last.state == nil)
    }

    @Test func askingAgainAfterACancelLetsTheFirstAskGoOn() async throws {
        let rig = Rig()
        rig.lib.transport.on("GET", "/Items/f1", body: itemJSON("f1", "Una película", "Movie", extra: #""RunTimeTicks":2000"#), delay: .milliseconds(150))
        await rig.downloader.start()
        async let first: Void = rig.downloader.enqueue(itemId: "f1", client: rig.client, userId: "user-1")
        try await Task.sleep(for: .milliseconds(40))
        await rig.downloader.remove(itemId: "f1", userId: "user-1")
        try await rig.downloader.enqueue(itemId: "f1", client: rig.client, userId: "user-1")
        try await first
        await rig.settle()
        #expect(rig.downloader.store(for: "user-1").entry("f1")?.state == .complete)
    }

    @Test func aNewSignInForgetsStaleResumeData() throws {
        let store = DownloadStore(root: tempRoot(), userId: "u")
        try Data("old-token-request".utf8).write(to: store.resumeURL(itemId: "x"))
        store.clearResumeData()
        #expect(!FileManager.default.fileExists(atPath: store.resumeURL(itemId: "x").path))
        #expect(FileManager.default.fileExists(atPath: store.resumeDirectory.path))
    }

    final class Removed: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var all: [String] { lock.withLock { list } }
        func add(_ id: String) { lock.withLock { list.append(id) } }
    }
}
