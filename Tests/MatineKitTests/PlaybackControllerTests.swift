import Foundation
import Testing
@testable import MatineKit

#if canImport(AVFoundation)
/// A source that records what the player asks of it and offers streams that can't load.
final class StubSource: LibrarySource, @unchecked Sendable {
    let userId = "u"
    private let lock = NSLock()
    private var _asked: [Bool] = []
    private var _reports: [String] = []
    var asked: [Bool] { lock.withLock { _asked } }
    var reports: [String] { lock.withLock { _reports } }

    func playbackPlan(itemId: String, startTicks: Int64, allowDirectPlay: Bool, constrained: Bool) async throws -> PlaybackPlan {
        lock.withLock { _asked.append(allowDirectPlay) }
        return PlaybackPlan(
            itemId: itemId, mediaSourceId: "s", playSessionId: "p", method: allowDirectPlay ? .directPlay : .transcode,
            url: URL(fileURLWithPath: "/nonexistent/matine-test.mp4"), startTicks: startTicks
        )
    }
    var streamHeaders: [String: String] { ["Authorization": "x"] }
    func reportStart(_ report: PlaybackReport) async throws { lock.withLock { _reports.append("start") } }
    func reportProgress(_ report: PlaybackReport) async throws { lock.withLock { _reports.append("progress") } }
    func reportStopped(_ report: PlaybackReport) async throws { lock.withLock { _reports.append("stopped") } }

    func home() async throws -> HomeContent { HomeContent(rows: [], libraries: []) }
    func libraries() async throws -> [Item] { [] }
    func libraryPage(libraryId: String, sort: LibrarySort, start: Int, limit: Int, countTotal: Bool) async throws -> ItemPage {
        ItemPage(items: [], total: 0, start: start, limit: limit)
    }
    func item(_ itemId: String) async throws -> Item { Item(id: itemId, name: "x", kind: .movie) }
    func seasons(seriesId: String) async throws -> [Item] { [] }
    func episodes(seriesId: String, seasonId: String) async throws -> [Item] { [] }
    func episodeToPlay(seriesId: String) async throws -> Item? { nil }
    func catalog() async throws -> [Item] { [] }
    func setPinned(_ pinned: Bool, itemId: String) async throws {}
    func imageURL(_ ref: ImageRef, maxHeight: Int) -> URL { testServer }
}

@MainActor @Suite struct PlaybackControllerTests {
    let movie = Item(id: "movie-1", name: "Peli", kind: .movie)

    @Test func aFileAVPlayerRefusesIsRetriedOnceAsHLSThenFailsAndStopsTheServerStream() async {
        let source = StubSource()
        let playback = Playback(readyTimeout: .seconds(10))
        await playback.start(item: movie, source: source, startTicks: 0, language: .spanish)
        #expect(source.asked == [true, false])
        #expect(playback.failed && playback.player == nil)
        // The failed server stream is ended (it may have begun transcoding).
        #expect(source.reports == ["stopped"])
    }

    @Test func closingWhileStartingTearsDownWhatStartBuildsAndReportsNothingPlayed() async {
        let source = StubSource()
        let playback = Playback(readyTimeout: .seconds(10))
        async let started: Void = playback.start(item: movie, source: source, startTicks: 5_000_000, language: .spanish)
        let played = await playback.close()
        await started
        #expect(!played)
        #expect(!playback.failed)
        #expect(playback.player == nil)
    }

    @Test func keepAliveWrapsTheStoppedReport() async {
        let source = StubSource()
        let playback = Playback(readyTimeout: .seconds(10))
        let wrapped = Counter()
        playback.keepAlive = { work in
            _ = wrapped.bump()
            await work()
        }
        await playback.start(item: movie, source: source, startTicks: 0, language: .spanish)
        _ = await playback.close()
        #expect(wrapped.count == 1)
    }

    @Test func theInfoPanelShowsTheEpisodeAndItsSeries() {
        var episode = Item(id: "e", name: "S01E02 - Dos", kind: .episode)
        episode.seriesName = "Serie"
        episode.seasonNumber = 1
        episode.episodeNumber = 2
        episode.overview = "Sinopsis"
        #expect(Playback.metadata(for: episode, language: .spanish).count == 3)
        #expect(Playback.metadata(for: movie, language: .spanish).count == 1)
    }
}

@Suite struct ExternalPlaybackTests {
    private func plan(_ url: URL) -> PlaybackPlan {
        PlaybackPlan(itemId: "m", mediaSourceId: "s", playSessionId: "p", method: .directPlay, url: url, startTicks: 0)
    }

    @Test func aDownloadedFileMayBeAirPlayedButAServerStreamMayNot() {
        #expect(Playback.allowsExternalPlayback(for: plan(URL(fileURLWithPath: "/tmp/matine-test.mp4"))))
        #expect(!Playback.allowsExternalPlayback(for: plan(URL(string: "https://example.invalid/Videos/m/stream.mp4")!)))
    }
}
#endif
