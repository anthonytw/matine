import Foundation
import Testing
@testable import MatineKit

@Suite struct ClientTests {
    @Test func authHeaderCarriesIdentityAndToken() {
        let header = makeClient(FakeTransport()).authorizationHeader
        #expect(header == #"MediaBrowser Client="Matine", Device="Apple TV", DeviceId="device-1", Version="0.1.0", Token="tok-123""#)
    }

    @Test func authHeaderDropsCharactersJellyfinWouldMisparse() {
        #expect(JellyfinClient.headerSafe(#"Sala "grande", 4K ✨"#) == "Sala grande 4K ")
    }

    @Test func anonymousHeaderHasNoToken() {
        #expect(!makeClient(FakeTransport(), token: nil).authorizationHeader.contains("Token"))
    }

    @Test func tokenNeverAppearsInAnyURL() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/UserViews", fixture: "user-views")
        let client = makeClient(transport)
        _ = try await client.libraries(userId: "user-1")
        let image = client.imageURL(ImageRef(itemId: "movie-1", kind: .primary, tag: "ptag"), maxHeight: 400)
        for url in transport.requests.map({ $0.url! }) + [image] {
            #expect(!url.absoluteString.contains("tok-123"))
        }
        #expect(image.absoluteString == "https://tv.example.test/Items/movie-1/Images/Primary?tag=ptag&maxHeight=400&quality=90")
    }

    @Test func requestsSendTheProfileLanguage() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/UserViews", fixture: "user-views")
        _ = try await makeClient(transport, language: .english).libraries(userId: "user-1")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
    }

    @Test func wrongPasswordIsBadCredentials() async {
        let transport = FakeTransport()
        transport.on("POST", "/Users/AuthenticateByName", status: 401)
        await #expect(throws: JellyfinError.badCredentials) {
            _ = try await makeClient(transport, token: nil).authenticate(username: "ana", password: "x")
        }
    }

    @Test func signInSendsNameAndPasswordOnceAndReturnsToken() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        let (user, token) = try await makeClient(transport, token: nil).authenticate(username: "ana", password: "secreto")
        #expect(user.id == "user-1" && token == "tok-123")
        let sent = try #require(transport.requests.first?.httpBody)
        #expect(try JSONSerialization.jsonObject(with: sent) as? [String: String] == ["Username": "ana", "Pw": "secreto"])
    }

    @Test func expiredTokenIsUnauthorized() async {
        let transport = FakeTransport()
        transport.on("GET", "/UserViews", status: 401)
        await #expect(throws: JellyfinError.unauthorized) { _ = try await makeClient(transport).libraries(userId: "u") }
    }

    @Test func decodesOnlyWhatTilesNeedAndIgnoresTheRest() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/UserItems/Resume", fixture: "resume")
        let item = try #require(try await makeClient(transport).resume(userId: "user-1").first)
        #expect(item.kind == .episode)
        #expect(item.seasonNumber == 1 && item.episodeNumber == 2)
        #expect(item.userData?.playedPercentage == 41.5)
        // An episode without its own poster falls back to the series poster.
        #expect(item.posterImage == ImageRef(itemId: "series-1", kind: .primary, tag: "stag"))
        #expect(item.backdropImage == ImageRef(itemId: "series-1", kind: .backdrop, tag: "btag"))
    }

    @Test func unknownItemTypesDecodeAsOther() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items/Latest", fixture: "latest-shows")
        let items = try await makeClient(transport).latest(userId: "user-1", libraryId: "lib-shows")
        #expect(items.map(\.kind) == [.series, .other("MusicVideo")])
    }

    @Test func pinAndUnpinUseTheFavoriteEndpoint() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/UserFavoriteItems/series-1")
        transport.on("DELETE", "/UserFavoriteItems/series-1")
        let client = makeClient(transport)
        try await client.setPinned(true, itemId: "series-1", userId: "user-1")
        try await client.setPinned(false, itemId: "series-1", userId: "user-1")
        #expect(transport.requests.map { $0.httpMethod } == ["POST", "DELETE"])
        #expect(transport.requests.allSatisfy { $0.query("userId") == "user-1" })
    }

    @Test func pinnedAsksForFavoriteMoviesSeriesAndVideos() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items", fixture: "empty-page")
        _ = try await makeClient(transport).pinned(userId: "user-1")
        let request = try #require(transport.requests.first)
        #expect(request.query("filters") == "IsFavorite")
        #expect(request.query("includeItemTypes") == "Movie,Series,Video")
        #expect(request.query("recursive") == "true")
    }

    @Test func oneNullNameOrImageTagDoesNotFailThePage() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items/Latest", body: #"[{"Id":"a","Name":null,"Type":"Movie","ImageTags":{"Primary":null,"Thumb":"t"},"BackdropImageTags":[null,"b"]},{"Id":"b","Type":"Movie"}]"#)
        let items = try await makeClient(transport).latest(userId: "u", libraryId: "l")
        #expect(items.map(\.name) == ["", ""])
        #expect(items[0].imageTags == ["Thumb": "t"])
        #expect(items[0].backdropImageTags == ["b"])
        #expect(items[0].posterImage == nil)
    }

    @Test func wideTilesOnlyForOwnWideArt() {
        var item = Item(id: "a", name: "a", kind: .series)
        item.imageTags = ["Primary": "p"]
        item.primaryAspectRatio = 1.78
        #expect(item.hasWidePoster)
        item.primaryAspectRatio = 0.67
        #expect(!item.hasWidePoster)
        var episode = Item(id: "e", name: "e", kind: .episode)
        episode.primaryAspectRatio = 1.78
        episode.seriesId = "s"
        episode.seriesPrimaryImageTag = "sp"
        // No art of its own: it borrows the portrait series poster.
        #expect(!episode.hasWidePoster)
    }

    @Test func episodeLabels() {
        var episode = Item(id: "e", name: "e", kind: .episode)
        #expect(episode.episodeLabel(.spanish) == nil)
        episode.seasonNumber = 4
        #expect(episode.episodeLabel(.spanish) == nil)
        episode.episodeNumber = 23
        #expect(episode.episodeLabel(.spanish) == "T4 · E23")
        #expect(episode.episodeLabel(.english) == "S4 · E23")
        episode.seasonNumber = nil
        #expect(episode.episodeLabel(.spanish) == "E23")
        #expect(episode.episodeLabel(.english) == "E23")
        #expect(Item(id: "m", name: "m", kind: .movie).episodeLabel(.spanish) == nil)
    }

    @Test func languageFromLocale() {
        #expect(AppLanguage(locale: Locale(identifier: "en-US")) == .english)
        #expect(AppLanguage(locale: Locale(identifier: "en_GB")) == .english)
        #expect(AppLanguage(locale: Locale(identifier: "es-ES")) == .spanish)
        #expect(AppLanguage(locale: Locale(identifier: "fr-FR")) == .spanish)
        #expect(AppLanguage(locale: AppLanguage.english.locale) == .english)
    }

    @Test func redirectsStayOnTheServer() {
        let origin = URL(string: "https://tv.example.test/Users/Me")!
        #expect(SameOriginRedirects.allows(from: origin, to: URL(string: "https://tv.example.test/elsewhere")!))
        #expect(!SameOriginRedirects.allows(from: origin, to: URL(string: "http://tv.example.test/Users/Me")!))
        // Up from plain HTTP to HTTPS on the same host (a proxy upgrading), never to another host.
        let plain = URL(string: "http://tv.example.test:8096/Users/Me")!
        #expect(SameOriginRedirects.allows(from: plain, to: URL(string: "https://tv.example.test/Users/Me")!))
        #expect(!SameOriginRedirects.allows(from: plain, to: URL(string: "https://evil.example/Users/Me")!))
        #expect(!SameOriginRedirects.allows(from: origin, to: URL(string: "https://evil.example/Users/Me")!))
        #expect(!SameOriginRedirects.allows(from: origin, to: URL(string: "https://tv.example.test:8443/x")!))
        // The same origin spelled differently still counts.
        #expect(SameOriginRedirects.allows(from: origin, to: URL(string: "https://TV.example.test:443/x")!))
    }

    @Test func tilesAskOnlyForWhatTheyShow() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/UserItems/Resume", fixture: "empty-page")
        _ = try await makeClient(transport).resume(userId: "u")
        let request = try #require(transport.requests.first)
        #expect(request.query("fields") == "PrimaryImageAspectRatio,Overview")
        #expect(request.query("enableImageTypes") == "Primary,Backdrop,Logo")
    }

    @Test func serverURLWithAPathPrefixKeepsIt() {
        let client = JellyfinClient(server: URL(string: "https://example.test/jellyfin/")!, identity: testIdentity)
        #expect(client.url("/Users/Me").absoluteString == "https://example.test/jellyfin/Users/Me")
    }
}
