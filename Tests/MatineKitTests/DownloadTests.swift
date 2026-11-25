import Foundation
import Testing
@testable import MatineKit

/// A transfer that "downloads" bytes straight into place, or fails, at once.
final class FakeEngine: DownloadEngine, @unchecked Sendable {
    let events: AsyncStream<DownloadEvent>
    private let continuation: AsyncStream<DownloadEvent>.Continuation
    private let destination: @Sendable (String) -> URL?
    private let lock = NSLock()
    private var started: [(request: URLRequest, key: String, resumeData: Data?)] = []
    private var cancelled: [String] = []
    private var alive: Set<String> = []
    /// "ok": write and finish; "hang": do nothing; "fail": fail with resume data.
    var behavior = "ok"
    /// The refusal a "fail" carries (nil: a lost connection, with resume data).
    var failStatus: Int?

    init(root: URL) {
        (events, continuation) = AsyncStream.makeStream()
        destination = Downloader.destination(root: root)
    }

    var requests: [URLRequest] { lock.withLock { started.map(\.request) } }
    var resumes: [Data?] { lock.withLock { started.map(\.resumeData) } }
    var cancelledKeys: [String] { lock.withLock { cancelled } }

    func start(_ request: URLRequest, key: String, resumeData: Data?) {
        lock.withLock { started.append((request, key, resumeData)) }
        switch behavior {
        case "ok":
            let target = destination(key)!
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("fake-mp4".utf8).write(to: target)
            continuation.yield(.progress(key: key, written: 4, total: 8))
            continuation.yield(.finished(key: key, bytes: 8))
        case "fail":
            lock.withLock { _ = alive.remove(key) }
            continuation.yield(.failed(key: key, status: failStatus, resumeData: failStatus == nil ? Data("resume".utf8) : Data("stale".utf8)))
        default:
            lock.withLock { _ = alive.insert(key) }
        }
    }

    /// Hands the downloader an event as if the transfer had produced it.
    func emit(_ event: DownloadEvent) { continuation.yield(event) }

    func cancel(key: String) { lock.withLock { cancelled.append(key); _ = alive.remove(key) } }
    func activeKeys() async -> Set<String> { lock.withLock { alive } }
}

func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("matine-test-" + UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func itemJSON(_ id: String, _ name: String, _ type: String, extra: String = "") -> String {
    #"{"Id":"\#(id)","Name":"\#(name)","Type":"\#(type)"\#(extra.isEmpty ? "" : "," + extra)}"#
}

/// A synthetic show: series S with seasons A (1) and B (2); episodes e1, e2 (A) and e3 (B); a film f1.
struct Library {
    let transport = FakeTransport()

    init() {
        let tags = #""ImageTags":{"Primary":"t1"}"#
        transport.on("GET", "/Items/e1", body: itemJSON("e1", "Uno", "Episode", extra: #""SeriesId":"S","ParentId":"A","SeriesName":"Serie","ParentIndexNumber":1,"IndexNumber":1,"RunTimeTicks":1000,\#(tags)"#))
        transport.on("GET", "/Items/e2", body: itemJSON("e2", "Dos", "Episode", extra: #""SeriesId":"S","ParentId":"A","SeriesName":"Serie","ParentIndexNumber":1,"IndexNumber":2,"RunTimeTicks":1000"#))
        transport.on("GET", "/Items/e3", body: itemJSON("e3", "Tres", "Episode", extra: #""SeriesId":"S","ParentId":"B","SeriesName":"Serie","ParentIndexNumber":2,"IndexNumber":1,"RunTimeTicks":1000"#))
        transport.on("GET", "/Items/f1", body: itemJSON("f1", "Una película", "Movie", extra: #""RunTimeTicks":2000,\#(tags)"#))
        transport.on("GET", "/Items/S", body: itemJSON("S", "Serie", "Series", extra: tags))
        transport.on("GET", "/Items/A", body: itemJSON("A", "Temporada 1", "Season", extra: #""SeriesId":"S","IndexNumber":1"#))
        transport.on("GET", "/Items/B", body: itemJSON("B", "Temporada 2", "Season", extra: #""SeriesId":"S","IndexNumber":2"#))
        let library = #"{"Items":[\#(itemJSON("lib", "Series", "CollectionFolder", extra: #""CollectionType":"tvshows""#))]}"#
        _ = library
        for id in ["e1", "e2", "e3"] {
            transport.on("GET", "/Items/\(id)/Ancestors", body: "[" + itemJSON("lib", "Series", "CollectionFolder", extra: #""CollectionType":"tvshows""#) + "]")
        }
        transport.on("GET", "/Items/f1/Ancestors", body: "[" + itemJSON("lib2", "Películas", "CollectionFolder", extra: #""CollectionType":"movies""#) + "]")
        for id in ["e1", "e2", "e3", "f1"] {
            transport.on("POST", "/Items/\(id)/PlaybackInfo", fixture: "playback-direct")
        }
        for path in ["/Items/S/Images/Primary", "/Items/e1/Images/Primary", "/Items/f1/Images/Primary"] {
            transport.on("GET", path, body: "jpeg")
        }
        transport.on("GET", "/Shows/S/Episodes", body: #"{"Items":[\#(itemJSON("e1", "Uno", "Episode")),\#(itemJSON("e2", "Dos", "Episode"))]}"#)
    }
}

struct Rig {
    let root = tempRoot()
    let lib = Library()
    let engine: FakeEngine
    let downloader: Downloader
    let client: JellyfinClient
    let updates = UpdateLog()

    final class UpdateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [DownloadUpdate] = []
        var all: [DownloadUpdate] { lock.withLock { list } }
        func add(_ update: DownloadUpdate) { lock.withLock { list.append(update) } }
    }

    init(user: String = "user-1", clock: TestClock? = nil) {
        engine = FakeEngine(root: root)
        let log = updates
        downloader = Downloader(root: root, engine: engine, now: { clock?.now ?? Date() }, onUpdate: { log.add($0) })
        client = makeClient(lib.transport)
        _ = user
    }

    func download(_ ids: String..., user: String = "user-1") async throws {
        await downloader.start()
        for id in ids { try await downloader.enqueue(itemId: id, client: client, userId: user) }
        await settle(user: user)
    }

    /// Waits until no download of the profile is still in flight.
    func settle(user: String = "user-1") async {
        let store = downloader.store(for: user)
        for _ in 0..<200 where store.entries().contains(where: { $0.state == .downloading }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite struct DownloadStoreTests {
    @Test func itemRoundTripsThroughTheManifest() throws {
        let item = try JSONDecoder().decode(Item.self, from: Data(#"""
        {"Id":"x","Name":"Algo","Type":"Movie","Overview":"Sinopsis","Genres":["Drama"],"RunTimeTicks":5,
         "ImageTags":{"Primary":"p"},"Studios":[{"Name":"Estudio"}],"People":[{"Id":"p1","Name":"Ana","Type":"Actor"}],
         "UserData":{"Played":false,"PlaybackPositionTicks":3,"IsFavorite":true},"ParentId":"par"}
        """#.utf8))
        let store = DownloadStore(root: tempRoot(), userId: "u")
        try store.begin(DownloadedItem(item: item, state: .complete, method: .original, mediaSourceId: "m", fileName: nil, bytes: 1, addedAt: Date(timeIntervalSince1970: 100), touchedAt: nil, libraryId: nil), parents: [])
        let again = DownloadStore(root: store.directory.deletingLastPathComponent(), userId: "u")
        let back = try #require(again.entry("x"))
        #expect(back.item == item)
        #expect(back.item.studios == ["Estudio"] && back.item.parentId == "par")
        #expect(back.addedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func idsCannotEscapeTheProfileFolder() {
        let store = DownloadStore(root: tempRoot(), userId: "../../etc")
        #expect(store.directory.deletingLastPathComponent().lastPathComponent.hasPrefix("matine-test-"))
        #expect(!store.fileURL(itemId: "../x").path.contains(".."))
    }

    @Test func theFolderIsOutOfBackups() throws {
        let store = DownloadStore(root: tempRoot(), userId: "u")
        let values = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func progressNeverClearsWatchedAndCountsPast90Percent() throws {
        let store = DownloadStore(root: tempRoot(), userId: "u")
        var item = Item(id: "x", name: "N", kind: .movie)
        item.runTimeTicks = 1000
        try store.begin(DownloadedItem(item: item, state: .complete, method: .original, mediaSourceId: "m", fileName: nil, bytes: 0, addedAt: Date(), touchedAt: nil, libraryId: nil), parents: [])
        #expect(store.applyProgress(itemId: "x", positionTicks: 400) == false)
        #expect(store.entry("x")?.item.userData?.playbackPositionTicks == 400)
        #expect(store.applyProgress(itemId: "x", positionTicks: 950) == true)
        #expect(store.entry("x")?.item.userData?.played == true)
        #expect(store.applyProgress(itemId: "x", positionTicks: 100) == false)
        #expect(store.entry("x")?.item.userData?.played == true)
    }
}

@Suite struct DownloaderTests {
    @Test func downloadsTheOriginalFileWithTheTokenInTheHeaderOnly() async throws {
        let rig = Rig()
        try await rig.download("f1")
        let request = try #require(rig.engine.requests.first)
        #expect(request.url?.path == "/Items/f1/Download")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("tok-123") == true)
        #expect(!request.url!.absoluteString.contains("tok-123"))
        let store = rig.downloader.store(for: "user-1")
        let entry = try #require(store.entry("f1"))
        #expect(entry.state == .complete && entry.method == .original && entry.mediaSourceId == "src-1" && entry.bytes == 8)
        #expect(entry.libraryId == "lib2")
        #expect(store.playableFile("f1") != nil)
        #expect(!rig.updates.all.isEmpty && rig.updates.all.last?.state == .complete)
    }

    @Test func aFileThatWontDirectPlayFallsBackToARemux() async throws {
        let rig = Rig()
        rig.lib.transport.on("POST", "/Items/f1/PlaybackInfo", fixture: "playback-hls")
        try await rig.download("f1")
        let request = try #require(rig.engine.requests.first)
        #expect(request.url?.path == "/Videos/f1/stream.mp4")
        #expect(request.url?.absoluteString.contains("tok-123") == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
        let store = rig.downloader.store(for: "user-1")
        #expect(store.entry("f1")?.method == .remux)
    }

    @Test func anEpisodeBringsItsSeasonSeriesLibraryAndArtwork() async throws {
        let rig = Rig()
        try await rig.download("e1")
        let store = rig.downloader.store(for: "user-1")
        let manifest = store.snapshot()
        #expect(Set(manifest.parents.keys) == ["A", "S", "lib"])
        #expect(store.hasArt(ImageRef(itemId: "S", kind: .primary, tag: "t1")))
        #expect(store.hasArt(ImageRef(itemId: "e1", kind: .primary, tag: "t1")))
    }

    @Test func aSeriesItselfIsNotDownloadable() async throws {
        let rig = Rig()
        await #expect(throws: DownloadError.notDownloadable) {
            try await rig.downloader.enqueue(itemId: "S", client: rig.client, userId: "user-1")
        }
    }

    @Test func aSeasonDownloadsEveryEpisode() async throws {
        let rig = Rig()
        await rig.downloader.start()
        try await rig.downloader.enqueueSeason(seriesId: "S", seasonId: "A", client: rig.client, userId: "user-1")
        await rig.settle()
        let store = rig.downloader.store(for: "user-1")
        #expect(Set(store.entries().map(\.item.id)) == ["e1", "e2"])
    }

    @Test func asking_twice_downloadsOnce() async throws {
        let rig = Rig()
        try await rig.download("f1", "f1")
        #expect(rig.engine.requests.count == 1)
    }

    @Test func aFailedDownloadKeepsResumeDataAndResumesWithIt() async throws {
        let rig = Rig()
        rig.engine.behavior = "fail"
        try await rig.download("f1")
        let store = rig.downloader.store(for: "user-1")
        #expect(store.entry("f1")?.state == .failed)
        #expect(try Data(contentsOf: store.resumeURL(itemId: "f1")) == Data("resume".utf8))
        rig.engine.behavior = "ok"
        await rig.downloader.resumeAll(client: rig.client, userId: "user-1")
        await rig.settle()
        #expect(rig.engine.resumes.last == Data("resume".utf8))
        #expect(store.entry("f1")?.state == .complete)
        #expect(!FileManager.default.fileExists(atPath: store.resumeURL(itemId: "f1").path))
    }

    @Test func resumeAllLeavesLiveTransfersAlone() async throws {
        let rig = Rig()
        rig.engine.behavior = "hang"
        try await rig.download("f1")
        await rig.downloader.resumeAll(client: rig.client, userId: "user-1")
        #expect(rig.engine.requests.count == 1)
    }

    @Test func cellularIsOffUntilAllowed() async throws {
        let rig = Rig()
        try await rig.download("f1")
        #expect(rig.engine.requests.first?.allowsCellularAccess == false)
        await rig.downloader.setAllowsCellular(true)
        try await rig.download("e1")
        #expect(rig.engine.requests.last?.allowsCellularAccess == true)
    }

    @Test func profilesNeverSeeEachOthersDownloads() async throws {
        let rig = Rig()
        try await rig.download("f1", user: "kid")
        let kid = rig.downloader.store(for: "kid")
        let parent = rig.downloader.store(for: "parent")
        #expect(kid.entry("f1") != nil && parent.entry("f1") == nil)
        let source = LocalLibrarySource(store: parent, queue: ProgressQueue(store: parent))
        #expect(try await source.catalog().isEmpty)
        #expect(try await source.libraries().isEmpty)
        #expect(parent.directory != kid.directory)
    }

    @Test func deletingTheLastChildRemovesParentsAndArtwork() async throws {
        let rig = Rig()
        try await rig.download("e1", "e2")
        let store = rig.downloader.store(for: "user-1")
        await rig.downloader.remove(itemId: "e1", userId: "user-1")
        #expect(Set(store.snapshot().parents.keys) == ["A", "S", "lib"])
        #expect(store.entry("e1") == nil && !FileManager.default.fileExists(atPath: store.fileURL(itemId: "e1").path))
        await rig.downloader.remove(itemId: "e2", userId: "user-1")
        #expect(store.snapshot().parents.isEmpty)
        let art = try FileManager.default.contentsOfDirectory(atPath: store.artDirectory.path)
        #expect(art.isEmpty)
        #expect(rig.engine.cancelledKeys == ["user-1/e1", "user-1/e2"])
    }

    @Test func aSeasonStaysWhileAnotherSeasonsEpisodeIsDeleted() async throws {
        let rig = Rig()
        try await rig.download("e1", "e3")
        let store = rig.downloader.store(for: "user-1")
        await rig.downloader.remove(itemId: "e3", userId: "user-1")
        #expect(Set(store.snapshot().parents.keys) == ["A", "S", "lib"])
        #expect(store.snapshot().parents["B"] == nil)
    }

    @Test func deleteAllEmptiesTheProfileAndReportsStorage() async throws {
        let rig = Rig()
        try await rig.download("e1", "f1")
        let store = rig.downloader.store(for: "user-1")
        #expect(store.bytesUsed() > 16)
        await rig.downloader.removeAll(userId: "user-1")
        #expect(store.entries().isEmpty && store.snapshot().parents.isEmpty)
        #expect(store.bytesUsed() < 100)
    }
}

@Suite struct LocalLibraryTests {
    func mirror(_ ids: String...) async throws -> (Rig, LocalLibrarySource, DownloadStore) {
        let rig = Rig()
        try await rig.download(ids.first!, ids.dropFirst().first ?? ids.first!)
        for id in ids.dropFirst(2) { try await rig.downloader.enqueue(itemId: id, client: rig.client, userId: "user-1") }
        await rig.settle()
        let store = rig.downloader.store(for: "user-1")
        return (rig, LocalLibrarySource(store: store, queue: ProgressQueue(store: store)), store)
    }

    @Test func aLibraryAppearsOnlyIfSomethingInItIsDownloaded() async throws {
        let (_, source, _) = try await mirror("e1")
        #expect(try await source.libraries().map(\.id) == ["lib"])
        let page = try await source.libraryPage(libraryId: "lib2", sort: .title, start: 0, limit: 10, countTotal: true)
        #expect(page.items.isEmpty)
    }

    @Test func aSeriesShowsOnlyItsDownloadedEpisodesAndSeasons() async throws {
        let (_, source, _) = try await mirror("e1", "e3")
        let page = try await source.libraryPage(libraryId: "lib", sort: .title, start: 0, limit: 10, countTotal: true)
        #expect(page.items.map(\.id) == ["S"] && page.total == 1)
        #expect(try await source.seasons(seriesId: "S").map(\.id) == ["A", "B"])
        #expect(try await source.episodes(seriesId: "S", seasonId: "A").map(\.id) == ["e1"])
        #expect(try await source.episodes(seriesId: "S", seasonId: "B").map(\.id) == ["e3"])
        #expect(try await source.item("S").userData?.unplayedItemCount == 2)
    }

    @Test func aSeasonWithNothingDownloadedIsHidden() async throws {
        let (_, source, _) = try await mirror("e1", "e2")
        #expect(try await source.seasons(seriesId: "S").map(\.id) == ["A"])
        await #expect(throws: LocalLibrarySource.Unavailable.notDownloaded) { _ = try await source.item("B") }
    }

    @Test func filmsAndSeriesShareTheirOwnLibraries() async throws {
        let (_, source, _) = try await mirror("e1", "f1")
        #expect(Set(try await source.libraries().map(\.id)) == ["lib", "lib2"])
        let films = try await source.libraryPage(libraryId: "lib2", sort: .dateAdded, start: 0, limit: 10, countTotal: false)
        #expect(films.items.map(\.id) == ["f1"] && films.total == nil)
    }

    @Test func homeHasRowsOnlyForWhatIsThere() async throws {
        let (_, source, _) = try await mirror("e1", "f1")
        let home = try await source.home()
        #expect(home.rows.map(\.id) == ["latest.lib2", "latest.lib"])
        #expect(home.libraries.count == 2)
    }

    @Test func playingOffersTheFileAndNoHeaders() async throws {
        let (_, source, store) = try await mirror("f1")
        let plan = try await source.playbackPlan(itemId: "f1", startTicks: 5, allowDirectPlay: true)
        #expect(plan.url == store.fileURL(itemId: "f1") && plan.url.isFileURL)
        #expect(plan.method == .directPlay && plan.mediaSourceId == "src-1" && plan.startTicks == 5)
        #expect(source.streamHeaders.isEmpty)
        await #expect(throws: LocalLibrarySource.Unavailable.notDownloaded) {
            _ = try await source.playbackPlan(itemId: "e1", startTicks: 0, allowDirectPlay: true)
        }
    }

    @Test func artworkComesFromTheDevice() async throws {
        let (_, source, store) = try await mirror("f1")
        let url = source.imageURL(ImageRef(itemId: "f1", kind: .primary, tag: "t1"), maxHeight: 300)
        #expect(url.isFileURL && url == store.artURL(ImageRef(itemId: "f1", kind: .primary, tag: "t1")))
        #expect(try Data(contentsOf: url) == Data("jpeg".utf8))
    }

    @Test func catalogHoldsOnlyDownloadedTitlesAndTheirSeries() async throws {
        let (_, source, _) = try await mirror("e1", "f1")
        #expect(Set(try await source.catalog().map(\.id)) == ["e1", "f1", "S"])
        // Search runs over it unchanged.
        let index = SearchIndex(items: try await source.catalog())
        #expect(index.search("uno").sections.flatMap(\.items).map(\.id).contains("e1"))
    }

    @Test func downloadingItemsAreNotListed() async throws {
        let rig = Rig()
        rig.engine.behavior = "hang"
        try await rig.download("f1")
        let store = rig.downloader.store(for: "user-1")
        let source = LocalLibrarySource(store: store, queue: ProgressQueue(store: store))
        #expect(try await source.libraries().isEmpty)
        #expect(try await source.catalog().isEmpty)
    }

    @Test func progressMadeOfflineShowsAtOnceAndIsQueued() async throws {
        let (_, source, store) = try await mirror("e1", "e2")
        let plan = try await source.playbackPlan(itemId: "e1", startTicks: 0, allowDirectPlay: true)
        try await source.reportProgress(PlaybackReport(plan: plan, positionTicks: 300, isPaused: false))
        let home = try await source.home()
        #expect(home.rows.first?.id == "resume" && home.rows.first?.items.map(\.id) == ["e1"])
        #expect(try await source.episodeToPlay(seriesId: "S")?.id == "e1")
        try await source.reportStopped(PlaybackReport(plan: plan, positionTicks: 990, isPaused: true))
        #expect(try await source.item("e1").userData?.played == true)
        #expect(try await source.episodeToPlay(seriesId: "S")?.id == "e2")
        let queue = ProgressQueue(store: store)
        #expect(queue.pending.map(\.itemId) == ["e1"] && queue.pending.first?.played == true)
    }
}

@Suite struct ProgressQueueTests {
    func queue() -> (ProgressQueue, DownloadStore) {
        let store = DownloadStore(root: tempRoot(), userId: "user-1")
        return (ProgressQueue(store: store), store)
    }

    @Test func theLatestRecordPerItemWins() {
        let (queue, store) = queue()
        queue.record(itemId: "a", positionTicks: 10, played: false, at: Date(timeIntervalSince1970: 1))
        queue.record(itemId: "a", positionTicks: 50, played: false, at: Date(timeIntervalSince1970: 2))
        queue.record(itemId: "b", positionTicks: 5, played: false, at: Date(timeIntervalSince1970: 3))
        #expect(queue.pending.map(\.positionTicks) == [50, 5])
        // It survives a restart.
        #expect(ProgressQueue(store: store).pending.count == 2)
    }

    @Test func aWatchedMarkWaitingIsNotUndoneByALaterPosition() {
        let (queue, _) = queue()
        queue.record(itemId: "a", positionTicks: 0, played: true)
        queue.record(itemId: "a", positionTicks: 40, played: false)
        #expect(queue.pending.first?.played == true)
    }

    @Test func flushSendsPositionsAndWatchedMarksOnlyAndEmptiesTheQueue() async throws {
        let (queue, _) = queue()
        let t = FakeTransport()
        t.on("GET", "/Items", body: #"{"Items":["# + itemJSON("a", "A", "Movie", extra: #""RunTimeTicks":1000"#) + "]}")
        t.on("POST", "/UserItems/a/UserData")
        t.on("POST", "/UserPlayedItems/b")
        queue.record(itemId: "a", positionTicks: 70, played: false, at: Date(timeIntervalSince1970: 1))
        queue.record(itemId: "b", positionTicks: 0, played: true, at: Date(timeIntervalSince1970: 2))
        #expect(try await queue.flush(client: makeClient(t), userId: "user-1") == 2)
        #expect(t.requests.map { "\($0.httpMethod!) \($0.url!.path)" } == ["GET /Items", "POST /UserItems/a/UserData", "POST /UserPlayedItems/b"])
        #expect(t.requests.filter { $0.httpMethod != "GET" }.allSatisfy { $0.httpMethod == "POST" })
        #expect(String(data: t.requests[1].httpBody ?? Data(), encoding: .utf8)?.contains("70") == true)
        #expect(queue.pending.isEmpty)
    }

    @Test func aDroppedConnectionKeepsEverythingQueued() async throws {
        let (queue, _) = queue()
        let t = FakeTransport()
        t.on("GET", "/Items/a", body: itemJSON("a", "A", "Movie", extra: #""RunTimeTicks":1000"#))
        t.on("POST", "/UserItems/a/UserData", unreachable: true)
        queue.record(itemId: "a", positionTicks: 70, played: false)
        await #expect(throws: JellyfinError.self) { try await queue.flush(client: makeClient(t), userId: "user-1") }
        #expect(queue.pending.count == 1)
    }

    @Test func anItemTheServerNoLongerHasIsDropped() async throws {
        let (queue, _) = queue()
        let t = FakeTransport()
        t.on("GET", "/Items/a", status: 404)
        queue.record(itemId: "a", positionTicks: 70, played: false)
        #expect(try await queue.flush(client: makeClient(t), userId: "user-1") == 0)
        #expect(queue.pending.isEmpty)
    }

    @Test func syncSendsThenRefreshesFromTheServer() async throws {
        let rig = Rig()
        try await rig.download("f1")
        let store = rig.downloader.store(for: "user-1")
        let queue = ProgressQueue(store: store)
        queue.record(itemId: "f1", positionTicks: 100, played: false)
        rig.lib.transport.on("POST", "/UserItems/f1/UserData")
        rig.lib.transport.on("GET", "/Items/f1", body: itemJSON("f1", "Una película", "Movie", extra: #""UserData":{"IsFavorite":true,"PlaybackPositionTicks":100}"#))
        #expect(try await DownloadSync.run(store: store, queue: queue, client: rig.client) == 1)
        #expect(store.entry("f1")?.item.userData?.isFavorite == true)
        #expect(queue.pending.isEmpty)
    }
}

@Suite struct HybridTests {
    func hybrid(_ rig: Rig, offline: Bool = false) async -> (HybridLibrarySource, ConnectionState, ProgressQueue) {
        let store = rig.downloader.store(for: "user-1")
        let queue = ProgressQueue(store: store)
        let connection = ConnectionState(offline: offline)
        let source = HybridLibrarySource(
            server: ServerLibrarySource(client: rig.client, userId: "user-1", device: "iPhone"),
            local: LocalLibrarySource(store: store, queue: queue), connection: connection
        )
        return (source, connection, queue)
    }

    @Test func onlineReadsTheServer() async throws {
        let rig = Rig()
        try await rig.download("f1")
        rig.lib.transport.on("GET", "/UserViews", fixture: "user-views")
        let (source, connection, _) = await hybrid(rig)
        #expect(try await source.libraries().map(\.id) == ["lib-movies", "lib-shows"])
        #expect(!connection.isOffline)
    }

    @Test func aLostConnectionSwitchesToTheMirrorByItself() async throws {
        let rig = Rig()
        try await rig.download("f1")
        rig.lib.transport.on("GET", "/UserViews", unreachable: true)
        let (source, connection, _) = await hybrid(rig)
        let changes = Changes()
        connection.onChange { changes.add($0) }
        #expect(try await source.libraries().map(\.id) == ["lib2"])
        #expect(connection.isOffline && changes.all == [true])
        // Once offline, the server isn't asked again.
        let before = rig.lib.transport.requests.count
        _ = try await source.libraries()
        #expect(rig.lib.transport.requests.count == before)
        connection.set(offline: false)
        #expect(changes.all == [true, false])
    }

    @Test func aBadGatewayCountsAsOfflineButAnExpiredSessionDoesNot() async throws {
        let rig = Rig()
        rig.lib.transport.on("GET", "/UserViews", status: 502)
        let (source, connection, _) = await hybrid(rig)
        _ = try await source.libraries()
        #expect(connection.isOffline)
        rig.lib.transport.on("GET", "/UserViews", status: 401)
        connection.set(offline: false)
        await #expect(throws: JellyfinError.unauthorized) { _ = try await source.libraries() }
        #expect(!connection.isOffline)
    }

    @Test func aDownloadedItemPlaysFromTheFileEvenOnline() async throws {
        let rig = Rig()
        try await rig.download("f1")
        let (source, _, _) = await hybrid(rig)
        let plan = try await source.playbackPlan(itemId: "f1", startTicks: 0, allowDirectPlay: true)
        #expect(plan.url.isFileURL)
        // Something not downloaded still streams.
        let streamed = try await source.playbackPlan(itemId: "e1", startTicks: 0, allowDirectPlay: true)
        #expect(!streamed.url.isFileURL && streamed.url.host == "tv.example.test")
    }

    @Test func onlinePlayReportsToTheServerAndKeepsTheMirrorInStep() async throws {
        let rig = Rig()
        try await rig.download("f1")
        rig.lib.transport.on("POST", "/Sessions/Playing/Stopped")
        let (source, _, queue) = await hybrid(rig)
        let plan = try await source.playbackPlan(itemId: "f1", startTicks: 0, allowDirectPlay: true)
        try await source.reportStopped(PlaybackReport(plan: plan, positionTicks: 500, isPaused: true))
        #expect(rig.lib.transport.requests.last?.url?.path == "/Sessions/Playing/Stopped")
        #expect(queue.pending.isEmpty)
        #expect(rig.downloader.store(for: "user-1").entry("f1")?.item.userData?.playbackPositionTicks == 500)
    }

    @Test func aReportThatCantReachTheServerIsQueued() async throws {
        let rig = Rig()
        try await rig.download("f1")
        rig.lib.transport.on("POST", "/Sessions/Playing/Stopped", unreachable: true)
        let (source, connection, queue) = await hybrid(rig)
        let plan = try await source.playbackPlan(itemId: "f1", startTicks: 0, allowDirectPlay: true)
        try await source.reportStopped(PlaybackReport(plan: plan, positionTicks: 500, isPaused: true))
        #expect(connection.isOffline)
        #expect(queue.pending.map(\.positionTicks) == [500])
    }

    @Test func offlinePlayNeverTouchesTheNetwork() async throws {
        let rig = Rig()
        try await rig.download("f1")
        let (source, _, queue) = await hybrid(rig, offline: true)
        let before = rig.lib.transport.requests.count
        let plan = try await source.playbackPlan(itemId: "f1", startTicks: 0, allowDirectPlay: true)
        try await source.reportStart(PlaybackReport(plan: plan, positionTicks: 0, isPaused: false))
        try await source.reportProgress(PlaybackReport(plan: plan, positionTicks: 100, isPaused: false))
        #expect(rig.lib.transport.requests.count == before)
        #expect(queue.pending.map(\.positionTicks) == [100])
    }

    @Test func reachabilityIsAnAnonymousServerInfoCall() async {
        let t = FakeTransport()
        t.on("GET", "/System/Info/Public", body: "{}")
        #expect(await makeClient(t).isReachable())
        t.on("GET", "/System/Info/Public", unreachable: true)
        #expect(await !makeClient(t).isReachable())
    }

    final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Bool] = []
        var all: [Bool] { lock.withLock { list } }
        func add(_ value: Bool) { lock.withLock { list.append(value) } }
    }
}
