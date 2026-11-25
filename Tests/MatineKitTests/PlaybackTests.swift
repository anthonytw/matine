import Foundation
import Testing
@testable import MatineKit

final class ManualClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@Suite struct PlaybackTests {
    @Test func aFileThatPlaysAsIsStreamsDirectlyWithoutAToken() async throws {
        let t = FakeTransport()
        t.on("POST", "/Items/movie-1/PlaybackInfo", fixture: "playback-direct")
        let plan = try await makeClient(t).playbackPlan(itemId: "movie-1", userId: "u", startTicks: 42)
        #expect(plan.method == .directPlay)
        #expect(plan.url.absoluteString == "https://tv.example.test/Videos/movie-1/stream?static=true&mediaSourceId=src-1&playSessionId=play-1&tag=etag-1")
        #expect(plan.startTicks == 42 && plan.playSessionId == "play-1")
        // The server got our Apple TV profile.
        let body = try #require(t.requests.first?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let profile = try #require(sent["DeviceProfile"] as? [String: Any])
        let direct = try #require((profile["DirectPlayProfiles"] as? [[String: Any]])?.first)
        #expect(direct["Container"] as? String == "mp4,m4v,mov")
        #expect(sent["StartTimeTicks"] as? Int == 42)
    }

    @Test func anythingElseUsesTheServersHLSWithTheTokenStripped() async throws {
        let t = FakeTransport()
        t.on("POST", "/Items/movie-2/PlaybackInfo", fixture: "playback-hls")
        let plan = try await makeClient(t).playbackPlan(itemId: "movie-2", userId: "u")
        #expect(plan.method == .transcode)
        #expect(plan.url.path == "/videos/movie-2/master.m3u8")
        #expect(!plan.url.absoluteString.contains("tok-123"))
        #expect(plan.url.query?.contains("PlaySessionId=play-2") == true)
    }

    @Test func noMediaSourceIsUnplayable() async {
        let t = FakeTransport()
        t.on("POST", "/Items/x/PlaybackInfo", body: #"{"MediaSources":[],"ErrorCode":"NoCompatibleStream"}"#)
        await #expect(throws: PlaybackError.unplayable("NoCompatibleStream")) {
            _ = try await makeClient(t).playbackPlan(itemId: "x", userId: "u")
        }
    }

    @Test func streamHeadersCarryTheToken() {
        #expect(makeClient(FakeTransport()).streamHeaders["Authorization"]?.contains(#"Token="tok-123""#) == true)
    }

    func session(_ t: FakeTransport, _ clock: ManualClock) -> PlaybackSession {
        let plan = PlaybackPlan(itemId: "movie-1", mediaSourceId: "src-1", playSessionId: "play-1", method: .directPlay,
                                url: testServer, startTicks: 0)
        return PlaybackSession(client: makeClient(t), plan: plan, now: { [clock] in clock.now })
    }

    func paths(_ t: FakeTransport) -> [String] { t.requests.map { $0.url!.path } }

    @Test func reportsStartThenEveryTenSecondsThenStopOnce() async throws {
        let t = FakeTransport()
        for p in ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"] { t.on("POST", p) }
        let clock = ManualClock()
        let s = session(t, clock)
        await s.update(positionTicks: 0, isPaused: false)
        for second in 1...25 {
            clock.now = clock.now.addingTimeInterval(1)
            await s.update(positionTicks: Ticks.from(seconds: Double(second)), isPaused: false)
        }
        await s.stop(positionTicks: Ticks.from(seconds: 25))
        await s.stop(positionTicks: Ticks.from(seconds: 26))
        await s.update(positionTicks: Ticks.from(seconds: 27), isPaused: false)
        #expect(paths(t) == ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"])
        let stop = try #require(t.requests.last?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: stop) as? [String: Any])
        #expect(json["PositionTicks"] as? Int == 250_000_000)
        #expect(json["PlaySessionId"] as? String == "play-1")
        #expect(json["PlayMethod"] as? String == "DirectPlay")
    }

    @Test func pausingReportsAtOnce() async {
        let t = FakeTransport()
        for p in ["/Sessions/Playing", "/Sessions/Playing/Progress"] { t.on("POST", p) }
        let clock = ManualClock()
        let s = session(t, clock)
        await s.update(positionTicks: 0, isPaused: false)
        clock.now = clock.now.addingTimeInterval(2)
        await s.update(positionTicks: 20, isPaused: true)
        clock.now = clock.now.addingTimeInterval(1)
        await s.update(positionTicks: 20, isPaused: true)
        await s.flush()
        #expect(paths(t) == ["/Sessions/Playing", "/Sessions/Playing/Progress"])
    }

    @Test func aFailingReportDoesNotStopPlayback() async {
        let t = FakeTransport()
        t.on("POST", "/Sessions/Playing", unreachable: true)
        t.on("POST", "/Sessions/Playing/Stopped")
        let s = session(t, ManualClock())
        await s.update(positionTicks: 0, isPaused: false)
        await s.stop(positionTicks: 10)
        #expect(paths(t).last == "/Sessions/Playing/Stopped")
    }

    @Test func stopWithoutStartSendsNothingForADirectFile() async {
        let t = FakeTransport()
        await session(t, ManualClock()).stop(positionTicks: 10)
        #expect(t.requests.isEmpty)
    }

    @Test func stopWithoutStartStillEndsAServerTranscode() async {
        let t = FakeTransport()
        t.on("POST", "/Sessions/Playing/Stopped")
        let plan = PlaybackPlan(itemId: "movie-2", mediaSourceId: "src-2", playSessionId: "play-2", method: .transcode,
                                url: testServer, startTicks: 0)
        let s = PlaybackSession(client: makeClient(t), plan: plan)
        await s.stop(positionTicks: 0)
        await s.update(positionTicks: 10, isPaused: false)
        await s.flush()
        #expect(t.requests.map { $0.url!.path } == ["/Sessions/Playing/Stopped"])
    }
}

@Suite struct PlaybackSweepTests {
    func session(_ t: FakeTransport, _ clock: ManualClock = ManualClock()) -> PlaybackSession {
        let plan = PlaybackPlan(itemId: "movie-1", mediaSourceId: "src-1", playSessionId: "play-1", method: .directPlay,
                                url: testServer, startTicks: 0)
        return PlaybackSession(client: makeClient(t), plan: plan, now: { [clock] in clock.now })
    }

    @Test func aStopBeforeAnythingStartedKeepsALateUpdateFromStartingASession() async {
        let t = FakeTransport()
        t.on("POST", "/Sessions/Playing")
        let s = session(t)
        await s.stop(positionTicks: 0)
        await s.update(positionTicks: 10, isPaused: false)
        await s.flush()
        #expect(t.requests.isEmpty)
    }

    @Test func reportsLeaveInOrderEvenWhenTheNetworkIsSlow() async {
        let t = FakeTransport()
        // Start is slow; Stopped must still go after it, never before.
        t.on("POST", "/Sessions/Playing", delay: .milliseconds(120))
        t.on("POST", "/Sessions/Playing/Stopped")
        let s = session(t)
        await s.update(positionTicks: 0, isPaused: false)
        await s.stop(positionTicks: 50)
        #expect(t.requests.map { $0.url!.path } == ["/Sessions/Playing", "/Sessions/Playing/Stopped"])
    }

    @Test func stopReturnsOnlyOnceStoppedWasSent() async {
        let t = FakeTransport()
        t.on("POST", "/Sessions/Playing")
        t.on("POST", "/Sessions/Playing/Stopped", delay: .milliseconds(80))
        let s = session(t)
        await s.update(positionTicks: 0, isPaused: false)
        await s.stop(positionTicks: 50)
        #expect(t.requests.last?.url?.path == "/Sessions/Playing/Stopped")
    }

    @Test func unknownTimesBecomeZeroInsteadOfCrashing() {
        #expect(Ticks.from(seconds: .nan) == 0)
        #expect(Ticks.from(seconds: .infinity) == 0)
        #expect(Ticks.from(seconds: -3) == 0)
        #expect(Ticks.from(seconds: 1.5) == 15_000_000)
    }

    @Test func tokensAreRedactedFromPlaylistText() {
        let text = #"URI="Trickplay/320/tiles.m3u8?MediaSourceId=a&ApiKey=secret1" main.m3u8?api_key=secret2&x=1 apikey=secret3"#
        let clean = Redaction.tokens(in: text)
        #expect(!clean.contains("secret"))
        #expect(clean.contains("ApiKey=REDACTED") && clean.contains("&x=1"))
    }

    @Test func aRetryCanForceTheServersHLS() async throws {
        let t = FakeTransport()
        t.on("POST", "/Items/movie-2/PlaybackInfo", fixture: "playback-hls")
        _ = try await makeClient(t).playbackPlan(itemId: "movie-2", userId: "u", allowDirectPlay: false)
        let body = try #require(t.requests.first?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["EnableDirectPlay"] as? Bool == false)
        let profile = try #require(sent["DeviceProfile"] as? [String: Any])
        #expect((profile["SubtitleProfiles"] as? [[String: String]])?.first == ["Format": "vtt", "Method": "Hls"])
    }
}

@Suite struct BrowsingTests {
    func page(_ ids: [String], start: Int, limit: Int = 2, total: Int? = nil) -> ItemPage {
        ItemPage(items: ids.map { Item(id: $0, name: $0, kind: .movie) }, total: total, start: start, limit: limit)
    }

    @Test func pagesBuildTheListUntilAShortPage() {
        var list = LibraryListing(sort: .title)
        #expect(list.nextStart == 0)
        do { let took = list.accept(page(["a", "b"], start: 0, total: 3), for: .title); #expect(took) }
        #expect(list.nextStart == 2)
        do { let took = list.accept(page(["c"], start: 2), for: .title); #expect(took) }
        #expect(list.items.map(\.id) == ["a", "b", "c"])
        #expect(list.nextStart == nil && list.total == 3)
    }

    @Test func aPageForAnOlderSortOrADuplicateIsIgnored() {
        var list = LibraryListing(sort: .title)
        list.accept(page(["a", "b"], start: 0), for: .title)
        list.reset(sort: .dateAdded)
        // The title page that was still in flight lands after the change.
        do { let took = list.accept(page(["c", "d"], start: 2), for: .title); #expect(!took) }
        do { let took = list.accept(page(["x", "y"], start: 2), for: .dateAdded); #expect(!took) }
        do { let took = list.accept(page(["y", "x"], start: 0), for: .dateAdded); #expect(took) }
        do { let took = list.accept(page(["y", "x"], start: 0), for: .dateAdded); #expect(!took) }
        #expect(list.items.map(\.id) == ["y", "x"])
    }

    /// After a playback the grid reads what it lists again and swaps it in: it keeps its length (and so its scroll position).
    @Test func aRefreshReplacesWhatIsListedAndKeepsHowFarItGoes() {
        var list = LibraryListing(sort: .title)
        list.accept(page(["a", "b"], start: 0, total: 5), for: .title)
        list.accept(page(["c", "d"], start: 2), for: .title)
        let took = list.refresh(with: page(["a", "b", "c", "d"], start: 0, limit: 60, total: 4), for: .title)
        #expect(took)
        #expect(list.items.map(\.id) == ["a", "b", "c", "d"])
        #expect(list.nextStart == nil)
    }

    @Test func aRefreshThatDoesNotBelongIsIgnored() {
        var list = LibraryListing(sort: .title)
        list.accept(page(["a", "b"], start: 0, total: 9), for: .title)
        // For another sort, not from the start, or too short to cover the list.
        do { let took = list.refresh(with: page(["a", "b"], start: 0), for: .dateAdded); #expect(!took) }
        do { let took = list.refresh(with: page(["b", "c"], start: 2), for: .title); #expect(!took) }
        do { let took = list.refresh(with: page(["a"], start: 0, limit: 1), for: .title); #expect(!took) }
        #expect(list.items.map(\.id) == ["a", "b"])
        #expect(list.nextStart == 2)
    }

    @Test func theTotalIsCountedOnlyWhenAskedFor() async throws {
        let t = FakeTransport()
        t.on("GET", "/Items", fixture: "empty-page")
        let client = makeClient(t)
        _ = try await client.libraryPage(userId: "u", libraryId: "l", start: 0)
        _ = try await client.libraryPage(userId: "u", libraryId: "l", start: 0, countTotal: true)
        #expect(t.requests.map { $0.query("enableTotalRecordCount") } == ["false", "true"])
    }

    @Test func aListEndsOnAShortPageWithoutATotal() {
        var list = LibraryListing(sort: .title)
        list.accept(page(["a", "b"], start: 0), for: .title)
        #expect(list.total == nil && list.nextStart == 2)
        list.accept(page(["c"], start: 2), for: .title)
        #expect(list.nextStart == nil)
    }

    @Test func anItemRepeatedAcrossPagesIsListedOnce() {
        var list = LibraryListing(sort: .title)
        list.accept(page(["a", "b"], start: 0), for: .title)
        // The server gained an item, so "b" slides into the next page too.
        list.accept(page(["b", "c"], start: 2), for: .title)
        #expect(list.items.map(\.id) == ["a", "b", "c"])
    }

    @Test func nameDisplaysWithoutAFileNamePrefix() {
        func name(_ n: String) -> String { Item(id: "i", name: n, kind: .episode).displayName }
        #expect(name("Serie Uno S01E041 - Titulo - canal ejemplo") == "Titulo - canal ejemplo")
        #expect(name("El robo") == "El robo")
        #expect(name("Serie S1E2 - ") == "Serie S1E2 - ")
        #expect(name("") == "")
        #expect(name("S01E02 sin guion") == "S01E02 sin guion")
    }

    @Test func tileCaptions() {
        var episode = Item(id: "e", name: "X S01E02 - Título", kind: .episode)
        #expect(episode.tileCaption(.spanish) == "Título")
        episode.seriesName = "Serie"
        #expect(episode.tileCaption(.spanish) == "Serie · Título")
        episode.episodeNumber = 2; episode.seasonNumber = 1
        #expect(episode.tileCaption(.spanish) == "Serie · T1 · E2")
        #expect(episode.episodeTitle(.spanish) == "T1 · E2 · Título")
        #expect(episode.tileCaption(.english) == "Serie · S1 · E2")
        #expect(episode.episodeTitle(.english) == "S1 · E2 · Título")
        var movie = Item(id: "m", name: "Peli", kind: .movie)
        movie.seriesName = "Ignorada"
        #expect(movie.tileCaption(.spanish) == "Peli")
    }

    @Test func specialsAreOnlyTheLastResortForUnwatched() async throws {
        let t = FakeTransport()
        let special = #"{"Id":"sp","Name":"sp","Type":"Episode","ParentIndexNumber":0,"IndexNumber":1}"#
        let real = #"{"Id":"s1","Name":"s1","Type":"Episode","ParentIndexNumber":1,"IndexNumber":1}"#
        // Specials come first, as the server's sort has them.
        t.on("GET", "/Items", body: "{\"Items\":[\(special),\(real)]}")
        let found = try await makeClient(t).firstUnwatchedEpisode(seriesId: "S", userId: "u")
        #expect(found?.id == "s1")
        t.on("GET", "/Items", body: "{\"Items\":[\(special)]}")
        let only = try await makeClient(t).firstUnwatchedEpisode(seriesId: "S", userId: "u")
        #expect(only?.id == "sp")
        t.on("GET", "/Items", body: "{\"Items\":[\(real)]}")
        let plain = try await makeClient(t).firstUnwatchedEpisode(seriesId: "S", userId: "u")
        #expect(plain?.id == "s1")
    }

    @Test func playOnASeriesTriesNextUpThenUnwatchedThenTheFirstEpisode() async throws {
        let one = #"{"Items":[{"Id":"ep","Name":"ep","Type":"Episode"}]}"#
        // Next up has it.
        var t = FakeTransport()
        t.on("GET", "/Shows/NextUp", body: one)
        #expect(try await makeClient(t).episodeToPlay(seriesId: "s", userId: "u")?.id == "ep")
        #expect(t.requests.count == 1)
        // Next up empty: the first unwatched, asked for as one item.
        t = FakeTransport()
        t.on("GET", "/Shows/NextUp", fixture: "empty-page")
        t.on("GET", "/Items", body: one)
        #expect(try await makeClient(t).episodeToPlay(seriesId: "s", userId: "u")?.id == "ep")
        let unwatched = try #require(t.requests.last)
        #expect(unwatched.query("filters") == "IsUnplayed" && unwatched.query("limit") == "1" && unwatched.query("parentId") == "s")
        // All watched: the first episode, still one item.
        t = FakeTransport()
        t.on("GET", "/Shows/NextUp", fixture: "empty-page")
        t.on("GET", "/Items", fixture: "empty-page")
        t.on("GET", "/Shows/s/Episodes", body: one)
        #expect(try await makeClient(t).episodeToPlay(seriesId: "s", userId: "u")?.id == "ep")
        #expect(t.requests.last?.query("limit") == "1")
    }

    @Test func playRules() {
        var movie = Item(id: "m", name: "m", kind: .movie)
        #expect(movie.resumeTicks == 0 && movie.isPinnable)
        movie.userData = UserData(playbackPositionTicks: 900)
        #expect(movie.resumeTicks == 900)
        #expect(!Item(id: "e", name: "e", kind: .episode).isPinnable)
    }

    @Test func theHomeLibrariesAreTheFilteredOnes() async throws {
        let t = FakeTransport()
        for p in ["/Items", "/Shows/NextUp", "/UserItems/Resume"] { t.on("GET", p, fixture: "empty-page") }
        t.on("GET", "/UserViews", fixture: "user-views")
        t.on("GET", "/Items/Latest", body: "[]")
        let content = try await HomeLoader(client: makeClient(t), userId: "u").load()
        #expect(content.libraries.map(\.id) == ["lib-movies", "lib-shows"])
    }
}
