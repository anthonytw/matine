import Foundation
import Testing
@testable import MatineKit

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current.addTimeInterval(seconds) } }
}

@Suite struct BatchedSyncTests {
    private func rig(_ ids: String...) async throws -> (Rig, DownloadStore) {
        let rig = Rig()
        try await rig.download(contentsOf: ids)
        return (rig, rig.downloader.store(for: "user-1"))
    }

    private func itemsPaths(_ rig: Rig) -> [String] { rig.lib.transport.requests.compactMap { $0.url?.path }.filter { $0.hasPrefix("/Items") } }

    @Test func syncAsksForEveryItemInOneBatch() async throws {
        let (rig, store) = try await rig("e1", "e2", "f1")
        let before = rig.lib.transport.requests.count
        let userData = #""UserData":{"IsFavorite":true}"#
        rig.lib.transport.on("GET", "/Items", body: #"{"Items":["# + [
            itemJSON("e1", "Uno", "Episode", extra: userData), itemJSON("e2", "Dos", "Episode"), itemJSON("f1", "Una película", "Movie"),
            itemJSON("S", "Serie", "Series"), itemJSON("A", "Temporada 1", "Season"), itemJSON("lib", "Series", "CollectionFolder"),
            itemJSON("lib2", "Películas", "CollectionFolder"),
        ].joined(separator: ",") + "]}")
        _ = try await DownloadSync.run(store: store, queue: ProgressQueue(store: store), client: rig.client)
        let sent = Array(rig.lib.transport.requests.dropFirst(before))
        #expect(sent.count == 1 && sent[0].url?.path == "/Items")
        let ids = Set((sent[0].query("ids") ?? "").split(separator: ",").map(String.init))
        #expect(ids == ["e1", "e2", "f1", "S", "A", "lib", "lib2"])
        #expect(store.entry("e1")?.item.userData?.isFavorite == true)
        #expect(sent[0].url?.absoluteString.contains("ApiKey") == false)
    }

    @Test func anItemLeftOutOfTheBatchIsConfirmedBeforeItIsDeleted() async throws {
        let (rig, store) = try await rig("e1", "f1")
        // The batch leaves out f1; asked for alone, the server says 404, so it goes. e1 stays.
        rig.lib.transport.on("GET", "/Items", body: #"{"Items":["# + [
            itemJSON("e1", "Uno", "Episode"), itemJSON("S", "Serie", "Series"), itemJSON("A", "Temporada 1", "Season"),
            itemJSON("lib", "Series", "CollectionFolder"), itemJSON("lib2", "Películas", "CollectionFolder"),
        ].joined(separator: ",") + "]}")
        rig.lib.transport.on("GET", "/Items/f1", status: 404)
        let gone = GoneLog()
        _ = try await DownloadSync.run(store: store, queue: ProgressQueue(store: store), client: rig.client, removed: { gone.add($0) })
        #expect(gone.all == ["f1"])
        #expect(store.entry("f1") == nil && store.entry("e1") != nil)
    }

    @Test func aLeftOutItemThatTheServerStillShowsStays() async throws {
        let (rig, store) = try await rig("f1")
        // An empty batch (a server quirk) must not wipe anything: f1 answers when asked alone.
        rig.lib.transport.on("GET", "/Items", body: #"{"Items":[]}"#)
        _ = try await DownloadSync.run(store: store, queue: ProgressQueue(store: store), client: rig.client)
        #expect(store.entry("f1") != nil)
    }

    @Test func aFailedBatchFallsBackToOneByOne() async throws {
        let (rig, store) = try await rig("f1")
        rig.lib.transport.on("GET", "/Items", status: 500)
        rig.lib.transport.on("GET", "/Items/f1", body: itemJSON("f1", "Una película", "Movie", extra: #""UserData":{"IsFavorite":true}"#))
        _ = try await DownloadSync.run(store: store, queue: ProgressQueue(store: store), client: rig.client)
        #expect(store.entry("f1")?.item.userData?.isFavorite == true)
    }

    @Test func idsAreSentInChunks() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items", body: #"{"Items":[]}"#)
        let ids = (0..<250).map { "id\($0)" }
        _ = try await makeClient(transport).items(ids: ids, userId: "u")
        let sent = transport.requests.map { ($0.query("ids") ?? "").split(separator: ",").count }
        #expect(sent == [100, 100, 50])
    }

    @Test func flushChecksResumePointsInOneRequest() async throws {
        let rig = Rig()
        try await rig.download("e1", "e2")
        let store = rig.downloader.store(for: "user-1")
        let queue = ProgressQueue(store: store)
        queue.record(itemId: "e1", positionTicks: 500, played: false)
        queue.record(itemId: "e2", positionTicks: 600, played: false)
        let t = rig.lib.transport
        t.on("GET", "/Items", body: #"{"Items":["# + [itemJSON("e1", "Uno", "Episode", extra: #""RunTimeTicks":1000"#), itemJSON("e2", "Dos", "Episode", extra: #""RunTimeTicks":1000"#)].joined(separator: ",") + "]}")
        t.on("POST", "/UserItems/e1/UserData")
        t.on("POST", "/UserItems/e2/UserData")
        let before = t.requests.count
        #expect(try await queue.flush(client: rig.client, userId: "user-1") == 2)
        let paths = t.requests.dropFirst(before).compactMap { $0.url?.path }
        #expect(paths.filter { $0.hasPrefix("/Items/") }.isEmpty && paths.filter { $0 == "/Items" }.count == 1)
    }

    final class GoneLog: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var all: [String] { lock.withLock { list } }
        func add(_ id: String) { lock.withLock { list.append(id) } }
    }
}

extension Rig {
    func download(contentsOf ids: [String], user: String = "user-1") async throws {
        await downloader.start()
        for id in ids { try await downloader.enqueue(itemId: id, client: client, userId: user) }
        await settle(user: user)
    }
}

@Suite struct SeasonEnqueueTests {
    private func count(_ transport: FakeTransport, _ method: String, _ path: String) -> Int {
        transport.requests.filter { $0.httpMethod == method && $0.url?.path == path }.count
    }

    @Test func parentsAreFetchedOnceForTheWholeSeason() async throws {
        let rig = Rig()
        await rig.downloader.start()
        try await rig.downloader.enqueueSeason(seriesId: "S", seasonId: "A", client: rig.client, userId: "user-1")
        await rig.settle()
        let t = rig.lib.transport
        #expect(count(t, "GET", "/Items/A") == 1 && count(t, "GET", "/Items/S") == 1)
        #expect(count(t, "GET", "/Items/e1/Ancestors") + count(t, "GET", "/Items/e2/Ancestors") == 1)
        let store = rig.downloader.store(for: "user-1")
        #expect(store.entries().map(\.item.id).sorted() == ["e1", "e2"] && store.entries().allSatisfy { $0.state == .complete })
        // The parents are all there for the offline mirror.
        let manifest = store.snapshot()
        #expect(Set(manifest.parents.keys) == ["A", "S", "lib"])
        #expect(Set(manifest.items.values.compactMap(\.libraryId)) == ["lib"])
    }

    @Test func oneBadEpisodeDoesNotStopTheRest() async throws {
        let rig = Rig()
        await rig.downloader.start()
        rig.lib.transport.on("POST", "/Items/e1/PlaybackInfo", status: 500)
        await #expect(throws: JellyfinError.self) {
            try await rig.downloader.enqueueSeason(seriesId: "S", seasonId: "A", client: rig.client, userId: "user-1")
        }
        await rig.settle()
        let store = rig.downloader.store(for: "user-1")
        #expect(store.entry("e1") == nil)
        #expect(store.entry("e2")?.state == .complete)
    }

    @Test func aSpecialShownInTheSeasonKeepsItsOwnSeasonOffline() async throws {
        let rig = Rig()
        await rig.downloader.start()
        let t = rig.lib.transport
        t.on("GET", "/Shows/S/Episodes", body: #"{"Items":["# + [itemJSON("e1", "Uno", "Episode"), itemJSON("e4", "Especial", "Episode")].joined(separator: ",") + "]}")
        t.on("GET", "/Items/e4", body: itemJSON("e4", "Especial", "Episode", extra: #""SeriesId":"S","ParentId":"Z","SeriesName":"Serie","ParentIndexNumber":0,"IndexNumber":1"#))
        t.on("GET", "/Items/Z", body: itemJSON("Z", "Especiales", "Season", extra: #""SeriesId":"S","IndexNumber":0"#))
        t.on("GET", "/Items/e4/Ancestors", body: "[" + itemJSON("lib", "Series", "CollectionFolder", extra: #""CollectionType":"tvshows""#) + "]")
        t.on("POST", "/Items/e4/PlaybackInfo", fixture: "playback-direct")
        try await rig.downloader.enqueueSeason(seriesId: "S", seasonId: "A", client: rig.client, userId: "user-1")
        await rig.settle()
        let manifest = rig.downloader.store(for: "user-1").snapshot()
        #expect(Set(manifest.parents.keys) == ["A", "S", "Z", "lib"])
        #expect(count(t, "GET", "/Items/Z") == 1 && count(t, "GET", "/Items/A") == 1)
    }

    @Test func aLostServerStopsTheSeasonAtOnce() async throws {
        let rig = Rig()
        await rig.downloader.start()
        rig.lib.transport.on("POST", "/Items/e1/PlaybackInfo", unreachable: true)
        await #expect(throws: JellyfinError.transport(code: URLError.notConnectedToInternet.rawValue)) {
            try await rig.downloader.enqueueSeason(seriesId: "S", seasonId: "A", client: rig.client, userId: "user-1")
        }
        #expect(count(rig.lib.transport, "GET", "/Items/e2") == 0)
    }

    @Test func aRefusedSignInStopsTheSeason() async throws {
        let rig = Rig()
        await rig.downloader.start()
        rig.lib.transport.on("GET", "/Items/e1", status: 401)
        await #expect(throws: JellyfinError.unauthorized) {
            try await rig.downloader.enqueueSeason(seriesId: "S", seasonId: "A", client: rig.client, userId: "user-1")
        }
        #expect(rig.downloader.store(for: "user-1").entry("e2") == nil)
    }
}

@Suite struct ProgressThrottleTests {
    private func rig(_ clock: TestClock) -> Rig {
        Rig(clock: clock)
    }

    private func ticks(_ rig: Rig) -> [Double?] {
        rig.updates.all.filter { $0.state == .downloading }.map(\.fraction)
    }

    @Test func tickersAreThinnedButStateChangesAlwaysGetThrough() async throws {
        let clock = TestClock()
        let rig = rig(clock)
        rig.engine.behavior = "hang"
        try await rig.download("f1")
        let key = "user-1/f1"
        let before = rig.updates.all.count
        // 100 tiny ticks in the same instant: only the first is forwarded.
        for n in 1...100 { rig.engine.emit(.progress(key: key, written: Int64(n), total: 10_000)) }
        await rig.waitForUpdates(before + 1)
        #expect(rig.updates.all.count == before + 1)
        // A move of a percent gets through at once.
        rig.engine.emit(.progress(key: key, written: 200, total: 10_000))
        await rig.waitForUpdates(before + 2)
        // So does a later tick of a tiny move, half a second on.
        clock.advance(0.6)
        rig.engine.emit(.progress(key: key, written: 201, total: 10_000))
        await rig.waitForUpdates(before + 3)
        #expect(rig.updates.all.count == before + 3)
        rig.engine.emit(.finished(key: key, bytes: 10_000))
        await rig.waitForUpdates(before + 4)
        #expect(rig.updates.all.last?.state == .complete && rig.updates.all.last?.fraction == 1)
    }
}

extension Rig {
    func waitForUpdates(_ count: Int) async {
        for _ in 0..<300 where updates.all.count < count { try? await Task.sleep(for: .milliseconds(10)) }
        // Let any extra updates that would wrongly follow show up.
        try? await Task.sleep(for: .milliseconds(30))
    }
}

@Suite struct ProgressWriteTests {
    @Test func throttleLetsOneWriteThroughPerMinuteUnlessForced() {
        let throttle = WriteThrottle(interval: 60)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(throttle.due("a", ticks: 1, force: false, now: t0))
        #expect(!throttle.due("a", ticks: 1, force: false, now: t0.addingTimeInterval(10)))
        #expect(throttle.due("b", ticks: 1, force: false, now: t0.addingTimeInterval(10)))
        // The same position is never written twice, forced or not (a paused player).
        #expect(!throttle.due("a", ticks: 1, force: true, now: t0.addingTimeInterval(10.5)))
        #expect(throttle.due("a", ticks: 2, force: true, now: t0.addingTimeInterval(11)))
        #expect(!throttle.due("a", ticks: 3, force: false, now: t0.addingTimeInterval(50)))
        #expect(throttle.due("a", ticks: 4, force: false, now: t0.addingTimeInterval(72)))
    }

    @Test func playingWritesTheManifestAboutOnceAMinuteButPausingAlwaysWrites() async throws {
        let rig = Rig()
        try await rig.download("e1")
        let store = rig.downloader.store(for: "user-1")
        let source = LocalLibrarySource(store: store, queue: ProgressQueue(store: store))
        let plan = try await source.playbackPlan(itemId: "e1", startTicks: 0, allowDirectPlay: true)
        try await source.reportProgress(PlaybackReport(plan: plan, positionTicks: 300, isPaused: false))
        try await source.reportProgress(PlaybackReport(plan: plan, positionTicks: 400, isPaused: false))
        #expect(store.entry("e1")?.item.userData?.playbackPositionTicks == 300)
        try await source.reportProgress(PlaybackReport(plan: plan, positionTicks: 500, isPaused: true))
        #expect(store.entry("e1")?.item.userData?.playbackPositionTicks == 500)
        try await source.reportStopped(PlaybackReport(plan: plan, positionTicks: 600, isPaused: false))
        #expect(store.entry("e1")?.item.userData?.playbackPositionTicks == 600)
        // Paused at 600 and reporting it again: nothing is rewritten.
        let touched = store.entry("e1")?.touchedAt
        try await source.reportProgress(PlaybackReport(plan: plan, positionTicks: 600, isPaused: true))
        #expect(store.entry("e1")?.touchedAt == touched)
    }
}

@Suite struct ArtNameTests {
    @Test func theArtSetFollowsSavesAndRemovals() throws {
        let store = DownloadStore(root: tempRoot(), userId: "u")
        let ref = ImageRef(itemId: "x", kind: .primary, tag: "t")
        #expect(!store.hasArt(ref))
        try store.saveArt(Data("jpeg".utf8), for: ref)
        #expect(store.hasArt(ref))
        // A fresh store reads what is on disk.
        #expect(DownloadStore(root: store.directory.deletingLastPathComponent(), userId: "u").hasArt(ref))
        store.removeAll()
        #expect(!store.hasArt(ref))
    }

    @Test func lastPlayedReadsServerDatesWithAndWithoutFractions() {
        let long = UserData(lastPlayedDate: "2026-11-24T10:00:00.1234567Z").lastPlayedAt
        let plain = UserData(lastPlayedDate: "2026-11-24T10:00:00Z").lastPlayedAt
        #expect(plain == Date(timeIntervalSince1970: 1_795_514_400))
        #expect(long.map { abs($0.timeIntervalSince(plain ?? .distantPast) - 0.123) < 0.01 } == true)
        #expect(UserData(lastPlayedDate: "nonsense").lastPlayedAt == nil)
    }
}
