import Foundation
import Testing
@testable import MatineKit

@Suite struct TopShelfTests {
    let account = Account(id: "user-1", name: "ana", server: testServer, language: .spanish)
    let client = makeClient(FakeTransport())

    func item(_ id: String, _ kind: ItemKind = .movie, primary: String? = "p") -> Item {
        var i = Item(id: id, name: "Title \(id)", kind: kind)
        if let primary { i.imageTags = ["Primary": primary] }
        return i
    }

    @Test func watchingComesFirstWithoutDuplicatesThenPinned() throws {
        let rows = [
            HomeRow(kind: .pinned, items: [item("pin-1")]),
            HomeRow(kind: .continueWatching, items: [item("a"), item("b"), item("c")]),
            HomeRow(kind: .latest(libraryId: "l", libraryName: "L"), items: [item("x")]),
        ]
        let shelf = try #require(TopShelfSnapshot.make(account: account, client: client, rows: rows))
        #expect(shelf.sections.map(\.title) == ["Seguir viendo", "Fijados"])
        #expect(shelf.sections[0].tiles.map(\.id) == ["a", "b", "c"])
        #expect(shelf.sections[1].tiles.map(\.id) == ["pin-1"])
        #expect(shelf.accountId == "user-1")
    }

    @Test func titlesFollowTheProfileLanguage() throws {
        var english = account
        english.language = .english
        let shelf = try #require(TopShelfSnapshot.make(account: english, client: client, rows: [HomeRow(kind: .pinned, items: [item("p")])]))
        #expect(shelf.sections.map(\.title) == ["Pinned"])
    }

    @Test func nothingToShowIsNoShelf() {
        #expect(TopShelfSnapshot.make(account: account, client: client, rows: []) == nil)
    }

    @Test func sectionsAreCapped() throws {
        let many = (0..<40).map { item("m\($0)") }
        let shelf = try #require(TopShelfSnapshot.make(account: account, client: client, rows: [HomeRow(kind: .continueWatching, items: many)]))
        #expect(shelf.sections[0].tiles.count == TopShelfSnapshot.tilesPerSection)
    }

    @Test func tilesCarryNoTokenAndLinkBackToTheProfile() throws {
        let shelf = try #require(TopShelfSnapshot.make(account: account, client: client, rows: [HomeRow(kind: .pinned, items: [item("p1")])]))
        let tile = shelf.sections[0].tiles[0]
        let encoded = String(decoding: try shelf.encoded(), as: UTF8.self)
        #expect(!encoded.contains("tok-123"))
        #expect(AppLink(tile.display) == .item("p1", account: "user-1"))
        #expect(AppLink(tile.play) == .play("p1", account: "user-1"))
        #expect(TopShelfSnapshot.decode(try shelf.encoded()) == shelf)
        #expect(!tile.wide)
    }

    @Test func episodeTilesNameTheirSeries() throws {
        var e = item("e1", .episode)
        e.seriesName = "Una serie"
        e.seasonNumber = 1
        e.episodeNumber = 2
        let shelf = try #require(TopShelfSnapshot.make(account: account, client: client, rows: [HomeRow(kind: .continueWatching, items: [e])]))
        #expect(shelf.sections[0].tiles[0].title == "Una serie · T1 · E2 · Title e1")
    }

    @Test(arguments: [
        "matine://item/abc?account=u", "matine://play/abc-123?account=u",
    ])
    func linksParse(_ raw: String) {
        #expect(AppLink(URL(string: raw)!) != nil)
    }

    @Test(arguments: [
        "matine://item/abc", "matine://item/?account=u", "matine://delete/abc?account=u",
        "matine://item/a/b?account=u", "other://item/abc?account=u", "matine://item/a%20b?account=u",
        "matine://item/abc?account=",
    ])
    func badLinksAreRefused(_ raw: String) {
        #expect(AppLink(URL(string: raw)!) == nil)
    }
}
