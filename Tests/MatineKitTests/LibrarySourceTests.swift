import Foundation
import Testing
@testable import MatineKit

@Suite struct LibrarySourceTests {
    func source(_ t: FakeTransport) -> any LibrarySource {
        ServerLibrarySource(client: makeClient(t), userId: "user-1")
    }

    @Test func homeIsTheLoadersRows() async throws {
        let t = FakeTransport()
        t.on("GET", "/Items", fixture: "empty-page")
        t.on("GET", "/UserItems/Resume", fixture: "resume")
        t.on("GET", "/Shows/NextUp", fixture: "empty-page")
        t.on("GET", "/UserViews", fixture: "user-views")
        t.on("GET", "/Items/Latest", fixture: "latest-movies")
        let home = try await source(t).home()
        #expect(home.rows.map(\.id) == ["resume", "latest.lib-movies", "latest.lib-shows"])
        #expect(home.libraries.map(\.id) == ["lib-movies", "lib-shows"])
    }

    @Test func librariesAreVideoOnesOnly() async throws {
        let t = FakeTransport()
        t.on("GET", "/UserViews", fixture: "user-views")
        let libraries = try await source(t).libraries()
        #expect(libraries.map(\.id) == ["lib-movies", "lib-shows"])
        #expect(t.requests.first?.query("userId") == "user-1")
    }

    @Test func libraryPageAsksForTheUsersPageInTheSort() async throws {
        let t = FakeTransport()
        t.on("GET", "/Items", fixture: "empty-page")
        let page = try await source(t).libraryPage(libraryId: "lib-movies", sort: .dateAdded, start: 60, limit: 30, countTotal: true)
        let request = try #require(t.requests.first)
        #expect(request.query("parentId") == "lib-movies" && request.query("userId") == "user-1")
        #expect(request.query("startIndex") == "60" && request.query("limit") == "30")
        #expect(request.query("sortOrder") == "Descending")
        #expect(page.start == 60 && page.limit == 30)
    }

    @Test func seriesCallsGoToTheShowsEndpoints() async throws {
        let t = FakeTransport()
        t.on("GET", "/Shows/SER/Seasons", body: #"{"Items":[{"Id":"a","Name":"T1","Type":"Season","IndexNumber":1}]}"#)
        t.on("GET", "/Shows/SER/Episodes", fixture: "empty-page")
        let s = source(t)
        #expect(try await s.seasons(seriesId: "SER").map(\.id) == ["a"])
        _ = try await s.episodes(seriesId: "SER", seasonId: "a")
        #expect(t.requests.last?.query("seasonId") == "a")
    }

    @Test func pinningUsesTheFavoriteEndpointForThisUser() async throws {
        let t = FakeTransport()
        t.on("POST", "/UserFavoriteItems/x")
        t.on("DELETE", "/UserFavoriteItems/x")
        try await source(t).setPinned(true, itemId: "x")
        try await source(t).setPinned(false, itemId: "x")
        #expect(t.requests.map { $0.httpMethod } == ["POST", "DELETE"])
        #expect(t.requests.allSatisfy { $0.query("userId") == "user-1" })
    }

    @Test func playbackNeverPutsTheTokenInAURL() async throws {
        let t = FakeTransport()
        t.on("POST", "/Items/movie-1/PlaybackInfo", fixture: "playback-direct")
        let s = source(t)
        let plan = try await s.playbackPlan(itemId: "movie-1", startTicks: 7, allowDirectPlay: true)
        #expect(plan.startTicks == 7)
        #expect(!plan.url.absoluteString.contains("tok-123"))
        #expect(s.streamHeaders["Authorization"]?.contains("tok-123") == true)
        #expect(!s.imageURL(ImageRef(itemId: "i", kind: .primary, tag: "t"), maxHeight: 300).absoluteString.contains("tok-123"))
    }

    @Test func reportsGoThroughTheSourceInOrder() async throws {
        let t = FakeTransport()
        t.on("POST", "/Sessions/Playing")
        t.on("POST", "/Sessions/Playing/Stopped")
        let plan = PlaybackPlan(itemId: "m", mediaSourceId: "s", playSessionId: "p", method: .directPlay, url: testServer, startTicks: 0)
        let session = PlaybackSession(reporter: source(t), plan: plan)
        await session.update(positionTicks: 0, isPaused: false)
        await session.stop(positionTicks: 50)
        #expect(t.requests.map { $0.url!.path } == ["/Sessions/Playing", "/Sessions/Playing/Stopped"])
    }

    /// The Apple TV's decisions, pinned: the profile the server is asked with.
    @Test func theAppleTVProfileIsPinned() async throws {
        let t = FakeTransport()
        t.on("POST", "/Items/movie-1/PlaybackInfo", fixture: "playback-direct")
        // A metered connection means nothing to the TV: same ceiling either way.
        _ = try await source(t).playbackPlan(itemId: "movie-1", startTicks: 0, allowDirectPlay: true, constrained: true)
        let body = try #require(t.requests.first?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["MaxStreamingBitrate"] as? Int == 120_000_000)
        #expect(sent["EnableDirectPlay"] as? Bool == true)
        let profile = try #require(sent["DeviceProfile"] as? [String: Any])
        #expect(profile["Name"] as? String == "Matine Apple TV")
        #expect(profile["MaxStreamingBitrate"] as? Int == 120_000_000)
        #expect(profile["MaxStaticBitrate"] as? Int == 120_000_000)
        #expect((profile["CodecProfiles"] as? [Any])?.isEmpty == true)
        let direct = try #require((profile["DirectPlayProfiles"] as? [[String: Any]])?.first)
        #expect(direct["Container"] as? String == "mp4,m4v,mov")
        #expect(direct["VideoCodec"] as? String == "h264,hevc")
        #expect(direct["AudioCodec"] as? String == "aac,ac3,eac3,mp3,alac,flac")
        let transcode = try #require((profile["TranscodingProfiles"] as? [[String: Any]])?.first)
        #expect(transcode["Container"] as? String == "mp4" && transcode["Protocol"] as? String == "hls")
        #expect(transcode["VideoCodec"] as? String == "h264,hevc" && transcode["AudioCodec"] as? String == "aac,ac3,eac3")
        #expect(transcode["MinSegments"] as? Int == 2 && transcode["BreakOnNonKeyFrames"] as? Bool == true)
        #expect((profile["SubtitleProfiles"] as? [[String: String]])?.first == ["Format": "vtt", "Method": "Hls"])
    }

    @Test func aPhoneSourceIsLighterThanTheTV() async throws {
        let t = FakeTransport()
        t.on("POST", "/Items/movie-1/PlaybackInfo", fixture: "playback-direct")
        let phone = ServerLibrarySource(client: makeClient(t), userId: "user-1", device: "iPhone")
        _ = try await phone.playbackPlan(itemId: "movie-1", startTicks: 0, allowDirectPlay: true, constrained: true)
        let body = try #require(t.requests.first?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["MaxStreamingBitrate"] as? Int == 6_000_000)
    }
}
