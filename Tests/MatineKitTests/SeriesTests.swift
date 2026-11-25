import Foundation
import Testing
@testable import MatineKit

@Suite struct SeriesTests {
    @Test func seasonEpisodesAskForOneSeasonOfTiles() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Shows/SER/Episodes", fixture: "empty-page")
        _ = try await makeClient(transport).seasonEpisodes(seriesId: "SER", seasonId: "SEA", userId: "u")
        let request = try #require(transport.requests.first)
        #expect(request.query("seasonId") == "SEA")
        #expect(request.query("enableImageTypes") == "Primary,Backdrop,Logo")
        #expect(request.query("limit") == "2000")
    }

    @Test func seasonsDecode() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Shows/SER/Seasons", body: #"{"Items":[{"Id":"a","Name":"Temporada 1","Type":"Season","IndexNumber":1}],"TotalRecordCount":1}"#)
        let seasons = try await makeClient(transport).seasons(seriesId: "SER", userId: "u")
        #expect(seasons.map(\.name) == ["Temporada 1"])
        #expect(seasons.first?.kind == .season)
        #expect(seasons.first?.seasonIndex == 1)
        #expect(transport.requests.first?.query("enableImages") == "false")
    }

    @Test func profilesPreferTheirOwnLanguageThenTheOther() {
        #expect(AppLanguage.spanish.mediaLanguages == ["es", "en"])
        #expect(AppLanguage.english.mediaLanguages == ["en", "es"])
    }

    @Test func trackLanguageCodesAreNormalized() {
        #expect(MediaLanguages.code("spa") == "es")
        #expect(MediaLanguages.code("es-MX") == "es")
        #expect(MediaLanguages.code("EN") == "en")
        #expect(MediaLanguages.code(nil) == nil)
    }

    @Test func ownLanguageAudioNeedsNoSubtitles() {
        let choice = MediaLanguages.choose(preferred: ["es", "en"], audio: ["eng", "spa"], subtitles: ["es", "en"])
        #expect(choice == .init(audio: 1, subtitle: nil))
    }

    @Test func foreignAudioGetsTheProfilesSubtitles() {
        let choice = MediaLanguages.choose(preferred: ["es", "en"], audio: ["en"], subtitles: ["en", "es"])
        #expect(choice == .init(audio: 0, subtitle: 1))
    }

    @Test func nothingMatchingLeavesTheFilesDefaults() {
        let choice = MediaLanguages.choose(preferred: ["en", "es"], audio: ["ja"], subtitles: ["fr"])
        #expect(choice == .init(audio: nil, subtitle: nil))
    }
}

@Suite struct TrackChoiceEdgeTests {
    @Test func unknownLanguageAudioNeverTurnsSubtitlesOn() {
        let choice = MediaLanguages.choose(preferred: ["es", "en"], audio: ["und", nil], subtitles: ["es"])
        #expect(choice.audio == nil && choice.subtitle == nil)
    }

    @Test func aFileWithoutSubtitlesStillGetsItsAudio() {
        let choice = MediaLanguages.choose(preferred: ["es", "en"], audio: ["eng", "spa"], subtitles: [])
        #expect(choice.audio == 1 && choice.subtitle == nil)
    }
}

@Suite struct SeriesPageRulesTests {
    func season(_ id: String, _ number: Int) -> Item {
        var s = Item(id: id, name: id, kind: .season)
        s.episodeNumber = number   // a season's own number is its IndexNumber
        return s
    }

    @Test func theSeasonShownFirstHoldsTheNextEpisode() {
        let seasons = [season("specials", 0), season("s1", 1), season("s2", 2)]
        var next = Item(id: "e", name: "e", kind: .episode)
        next.seasonNumber = 2
        #expect(Item.defaultSeason(seasons, next: next)?.id == "s2")
    }

    @Test func withoutANextEpisodeItIsTheFirstRealSeasonNotSpecials() {
        let seasons = [season("specials", 0), season("s1", 1)]
        #expect(Item.defaultSeason(seasons, next: nil)?.id == "s1")
        #expect(Item.defaultSeason([season("specials", 0)], next: nil)?.id == "specials")
        #expect(Item.defaultSeason([], next: nil) == nil)
    }

    @Test func progressShowsOnlyBetweenStartAndWatched() {
        var item = Item(id: "m", name: "m", kind: .movie)
        #expect(item.progressPercent == nil)
        item.userData = UserData(playedPercentage: 0)
        #expect(item.progressPercent == nil)
        item.userData = UserData(playedPercentage: 42)
        #expect(item.progressPercent == 42)
        item.userData = UserData(played: true, playedPercentage: 42)
        #expect(item.progressPercent == nil)
    }

    @Test func episodeTitles() {
        var e = Item(id: "e", name: "El robo", kind: .episode)
        #expect(e.episodeTitle(.spanish) == "El robo")
        e.seasonNumber = 1
        e.episodeNumber = 3
        #expect(e.episodeTitle(.spanish) == "T1 · E3 · El robo")
    }
}

@Suite struct LibraryExtrasTests {
    @Test func resumeCanStayInOneLibrary() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/UserItems/Resume", fixture: "empty-page")
        let client = makeClient(transport)
        _ = try await client.resume(userId: "u")
        _ = try await client.resume(userId: "u", libraryId: "LIB")
        #expect(transport.requests[0].query("parentId") == nil)
        #expect(transport.requests[1].query("parentId") == "LIB")
    }

    @Test func shuffledAsksTheServerForARandomHandfulOfWatchables() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items", fixture: "empty-page")
        _ = try await makeClient(transport).shuffled(userId: "u", libraryId: "LIB")
        let request = try #require(transport.requests.first)
        #expect(request.query("sortBy") == "Random")
        #expect(request.query("parentId") == "LIB")
        #expect(request.query("includeItemTypes") == "Movie,Episode,Video")
        #expect(request.query("recursive") == "true")
    }
}
