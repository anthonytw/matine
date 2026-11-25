import Foundation
import Testing
@testable import MatineKit

@Suite struct APIManifestTests {
    /// Calls every endpoint and checks each request it sent is in the manifest,
    /// so the drift check can't miss a call the client makes.
    @Test func everyRequestTheClientSendsIsInTheManifest() async throws {
        let transport = FakeTransport()
        for (method, path) in [
            ("GET", "/System/Info/Public"), ("GET", "/Users/Me"), ("GET", "/Items/ID"),
        ] { transport.on(method, path, body: #"{"Id":"x","Name":"x","ServerName":"x","Version":"1","Type":"Movie"}"#) }
        for path in ["/UserViews", "/UserItems/Resume", "/Shows/NextUp", "/Items"] { transport.on("GET", path, fixture: "empty-page") }
        transport.on("GET", "/Items/Latest", body: "[]")
        transport.on("POST", "/Users/AuthenticateByName", fixture: "auth")
        transport.on("POST", "/Sessions/Logout")
        transport.on("POST", "/UserFavoriteItems/ID")
        transport.on("DELETE", "/UserFavoriteItems/ID")
        transport.on("POST", "/UserPlayedItems/ID")
        transport.on("POST", "/UserItems/ID/UserData")
        transport.on("GET", "/api-docs/openapi.json")
        transport.on("GET", "/Shows/ID/Episodes", fixture: "empty-page")
        transport.on("GET", "/Shows/ID/Seasons", fixture: "empty-page")
        transport.on("POST", "/Items/ID/PlaybackInfo", fixture: "playback-direct")
        for path in ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"] { transport.on("POST", path) }
        for path in ["/Sessions/Capabilities/Full", "/Sessions/SID/Playing", "/Sessions/SID/Playing/Pause", "/Sessions/SID/Playing/Seek"] { transport.on("POST", path) }
        transport.on("GET", "/Sessions", body: "[]")
        var stream: URL?

        let client = makeClient(transport)
        _ = try await client.publicInfo()
        _ = try await client.authenticate(username: "u", password: "p")
        try await client.logout()
        _ = try await client.libraries(userId: "u")
        _ = try await client.resume(userId: "u")
        _ = try await client.nextUp(userId: "u", seriesId: "s")
        _ = try await client.latest(userId: "u", libraryId: "l")
        _ = try await client.pinned(userId: "u")
        try await client.setPinned(true, itemId: "ID", userId: "u")
        try await client.setPinned(false, itemId: "ID", userId: "u")
        try await client.setPlayed(itemId: "ID", userId: "u")
        try await client.setPlaybackPosition(ticks: 1, itemId: "ID", userId: "u")
        _ = try await client.item("ID", userId: "u")
        _ = try await client.openAPISpec()
        _ = try await client.libraryPage(userId: "u", libraryId: "l")
        _ = try await client.catalog(userId: "u")
        _ = try await client.personItems(personId: "P", userId: "u")
        _ = try await client.episodes(seriesId: "ID", userId: "u", limit: 1)
        _ = try await client.seasons(seriesId: "ID", userId: "u")
        _ = try await client.seasonEpisodes(seriesId: "ID", seasonId: "S", userId: "u")
        _ = try await client.firstUnwatchedEpisode(seriesId: "ID", userId: "u")
        let plan = try await client.playbackPlan(itemId: "ID", userId: "u")
        try await client.reportStart(PlaybackReport(plan: plan, positionTicks: 0, isPaused: false))
        try await client.reportProgress(PlaybackReport(plan: plan, positionTicks: 0, isPaused: false))
        try await client.reportStopped(PlaybackReport(plan: plan, positionTicks: 0, isPaused: true))
        stream = plan.url
        try await client.reportCapabilities()
        _ = try await client.controllableSessions(userId: "u")
        try await client.sendPlay(sessionId: "SID", itemId: "ID", startTicks: 10)
        try await client.sendPlaystate(sessionId: "SID", .pause)
        try await client.sendPlaystate(sessionId: "SID", .seek, seekTicks: 5)
        transport.singlePage = ["/Items"]
        _ = try await client.mediaFiles(userId: "u", libraryId: "l")
        transport.on("GET", "/Videos/ID/stream", status: 206, body: "0123456789abcdef")
        _ = try await client.fileBytes(itemId: "ID", sourceId: "S", offset: 0, count: 16)

        let manifest = Dictionary(uniqueKeysWithValues: APIManifest.calls.map { ("\($0.method) \($0.path)", Set($0.query)) })
        for request in transport.requests where request.url!.path != "/api-docs/openapi.json" {
            var path = request.url!.path
            if path.hasPrefix("/Sessions/SID/Playing/") { path = "/Sessions/{sessionId}/Playing/{command}" }
            if path == "/Sessions/SID/Playing" { path = "/Sessions/{sessionId}/Playing" }
            path = path
                .replacingOccurrences(of: "/Shows/ID", with: "/Shows/{seriesId}")
                .replacingOccurrences(of: "/ID", with: "/{itemId}")
            let key = "\(request.httpMethod!) \(path)"
            let allowed = try #require(manifest[key], "\(key) is missing from APIManifest.calls")
            let sent = Set(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
            #expect(sent.isSubset(of: allowed), "\(key) sends \(sent.subtracting(allowed)) not in the manifest")
        }
        // The stream URL the player fetches is checked the same way.
        let streamURL = try #require(stream)
        let streamQuery = Set(URLComponents(url: streamURL, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name))
        #expect(streamQuery.isSubset(of: manifest["GET /Videos/{itemId}/stream"]!))
        let image = makeClient(transport).imageURL(ImageRef(itemId: "ID", kind: .primary, tag: "t"), maxHeight: 1)
        let imageQuery = Set(URLComponents(url: image, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name))
        #expect(imageQuery.isSubset(of: manifest["GET /Items/{itemId}/Images/{imageType}"]!))
    }

    @Test func aRemovedCallOrFieldIsReported() throws {
        let spec = #"{"paths":{"/Users/Me":{"get":{"parameters":[]}}},"components":{"schemas":{"BaseItemDto":{"properties":{"Id":{}}}}}}"#
        let problems = try APIManifest.problems(in: Data(spec.utf8))
        #expect(problems.contains("GET /UserViews: gone"))
        #expect(problems.contains("schema BaseItemDto: no field Name"))
        #expect(problems.contains("schema UserDto: gone"))
    }
}
