import Foundation
import Testing
@testable import MatineKit

@Suite struct HomeLoaderTests {
    func transport() -> FakeTransport {
        let t = FakeTransport()
        t.on("GET", "/Items", fixture: "empty-page")
        t.on("GET", "/UserItems/Resume", fixture: "resume")
        t.on("GET", "/Shows/NextUp", fixture: "empty-page")
        t.on("GET", "/UserViews", fixture: "user-views")
        return t
    }

    @Test func rowsComeInHomeOrderAndEmptyOnesAreDropped() async throws {
        let t = transport()
        t.on("GET", "/Items/Latest", fixture: "latest-movies")
        let rows = try await HomeLoader(client: makeClient(t), userId: "user-1").load().rows
        // Fijados and Next up are empty here and left out; music has no row.
        #expect(rows.map(\.id) == ["resume", "latest.lib-movies", "latest.lib-shows"])
    }

    @Test func latestRowsFollowTheLibraryOrderNotTheOrderCallsFinish() async throws {
        let t = transport()
        // The first library answers last.
        t.on("GET", "/Items/Latest", parentId: "lib-movies", fixture: "latest-movies", delay: .milliseconds(80))
        t.on("GET", "/Items/Latest", parentId: "lib-shows", fixture: "latest-shows")
        let rows = try await HomeLoader(client: makeClient(t), userId: "user-1").load().rows
        let latest = rows.compactMap { row -> (String, String)? in
            if case .latest(_, let name) = row.kind { return (name, row.items[0].id) }
            return nil
        }
        #expect(latest.map(\.0) == ["Películas", "Series"])
        // And each row holds its own library's items.
        #expect(latest.map(\.1) == ["movie-1", "series-1"])
    }

    @Test func musicLibrariesAreNeverAsked() async throws {
        let t = transport()
        t.on("GET", "/Items/Latest", fixture: "latest-movies")
        _ = try await HomeLoader(client: makeClient(t), userId: "user-1").load().rows
        let asked = t.requests.filter { $0.url!.path == "/Items/Latest" }.compactMap { $0.query("parentId") }
        #expect(Set(asked) == ["lib-movies", "lib-shows"])
    }

    @Test func aFailingRowIsLeftOutAndTheRestStillLoad() async throws {
        let t = transport()
        t.on("GET", "/UserItems/Resume", status: 500)
        t.on("GET", "/Items/Latest", parentId: "lib-movies", unreachable: true)
        t.on("GET", "/Items/Latest", parentId: "lib-shows", fixture: "latest-shows")
        let rows = try await HomeLoader(client: makeClient(t), userId: "user-1").load().rows
        #expect(rows.map(\.id) == ["latest.lib-shows"])
    }

    @Test func everyRowFailingFailsTheLoadInsteadOfAnEmptyHome() async {
        let t = transport()
        t.on("GET", "/Items", status: 500)
        t.on("GET", "/UserItems/Resume", status: 500)
        t.on("GET", "/Shows/NextUp", status: 500)
        t.on("GET", "/Items/Latest", status: 500)
        await #expect(throws: JellyfinError.http(status: 500)) {
            _ = try await HomeLoader(client: makeClient(t), userId: "user-1").load()
        }
    }

    @Test func anExpiredSessionFailsTheWholeLoad() async {
        let t = transport()
        t.on("GET", "/Shows/NextUp", status: 401)
        t.on("GET", "/Items/Latest", fixture: "latest-movies")
        await #expect(throws: JellyfinError.unauthorized) {
            _ = try await HomeLoader(client: makeClient(t), userId: "user-1").load().rows
        }
    }

    @Test func notListingTheLibrariesFailsTheLoad() async {
        let t = transport()
        t.on("GET", "/UserViews", status: 500)
        await #expect(throws: JellyfinError.http(status: 500)) {
            _ = try await HomeLoader(client: makeClient(t), userId: "user-1").load().rows
        }
    }
}
