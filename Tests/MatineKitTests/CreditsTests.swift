import Foundation
import Testing
@testable import MatineKit

@Suite struct CreditsTests {
    private func credited() throws -> Item {
        try JSONDecoder().decode(Item.self, from: FakeTransport.fixture("credits-item"))
    }

    @Test func detailDecodesCreditsRatingsAndStudios() throws {
        let item = try credited()
        #expect(item.officialRating == "ES-12")
        #expect(item.communityRating == 8.46)
        #expect(item.ratingText == "★ 8.5")
        #expect(item.taglines == ["Una luz entre la niebla"])
        #expect(item.studios == ["Estudio Brisa", "Casa Marea"])
        #expect(item.cast.map(\.name) == ["Alma Ventura", "Bruno Salcedo"])
        #expect(item.cast.first?.role == "Marta Quiroga")
        #expect(item.cast.last?.role == nil) // an empty role is no role
        #expect(item.directors.map(\.name) == ["Celia Montoya"])
        #expect(item.writers.map(\.name) == ["Dario Lerma"])
        #expect(item.guestStars.map(\.name) == ["Elena Rastro"])
        // The entry with no Id dropped out; the unknown type is kept as other.
        #expect(item.people?.count == 7)
        #expect(item.hasCredits)
    }

    @Test func personPhotoIsATokenlessImage() throws {
        let item = try credited()
        let client = makeClient(FakeTransport())
        let url = try #require(item.cast.first?.image.map { client.imageURL($0, maxHeight: 300) })
        #expect(url.absoluteString == "https://tv.example.test/Items/p1/Images/Primary?tag=ph1&maxHeight=300&quality=90")
        #expect(!url.absoluteString.contains("tok-123"))
        #expect(item.cast.last?.image == nil)
    }

    @Test func initialsForAPlaceholder() {
        #expect(Person(id: "a", name: "Alma Ventura", kind: .actor).initials == "AV")
        #expect(Person(id: "a", name: "Ana María de la Torre", kind: .actor).initials == "AT")
        #expect(Person(id: "a", name: "Cher", kind: .actor).initials == "C")
    }

    @Test func aTitleWithoutMetadataHasNone() throws {
        let item = try JSONDecoder().decode(Item.self, from: Data(#"{"Id":"v","Name":"Video casero","Type":"Video","People":[],"Studios":[],"CommunityRating":0}"#.utf8))
        #expect(!item.hasCredits)
        #expect(item.ratingText == nil)
        #expect(item.officialRating == nil)
        #expect(item.studios == [])
    }

    @Test func malformedCreditsNeverFailTheItem() throws {
        let item = try JSONDecoder().decode(Item.self, from: Data(#"{"Id":"v","Name":"X","Type":"Movie","People":"oops","Studios":5,"CommunityRating":"x"}"#.utf8))
        #expect(item.people == nil)
        #expect(item.studios == nil)
        #expect(item.communityRating == nil)
    }

    @Test func personItemsAsksForThePersonAndFoldsEpisodesIntoSeries() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items", body: """
        {"Items":[
         {"Id":"m1","Name":"Película","Type":"Movie"},
         {"Id":"e1","Name":"Uno","Type":"Episode","SeriesId":"s1","SeriesName":"Serie Uno","SeriesPrimaryImageTag":"t1"},
         {"Id":"e2","Name":"Dos","Type":"Episode","SeriesId":"s1","SeriesName":"Serie Uno"},
         {"Id":"s2","Name":"Serie Dos","Type":"Series"},
         {"Id":"e3","Name":"Tres","Type":"Episode","SeriesId":"s2","SeriesName":"Serie Dos"},
         {"Id":"e4","Name":"Suelto","Type":"Episode"}
        ]}
        """)
        let client = makeClient(transport)
        let found = try await client.personItems(personId: "p1", userId: "u")
        let request = try #require(transport.requests.last)
        #expect(request.query("personIds") == "p1")
        #expect(request.query("includeItemTypes") == "Movie,Series,Episode,Video")
        #expect(request.url?.absoluteString.contains("tok-123") == false)
        let grouped = Item.grouped(byPerson: found)
        // By name: Película, Serie Dos, Serie Uno, Suelto.
        #expect(grouped.map(\.id) == ["m1", "s2", "s1", "e4"])
        #expect(grouped[2].kind == .series)
        #expect(grouped[2].posterImage?.tag == "t1")
    }

    @Test func catalogKeepsOnlyTheCreditsSearchUses() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items", body: #"{"Items":[{"Id":"f","Name":"F","Type":"Movie","People":[{"Id":"a","Name":"A","Type":"Actor"},{"Id":"b","Name":"B","Type":"Producer"},{"Id":"c","Name":"C","Type":"Director"}]}]}"#)
        let client = makeClient(transport)
        let items = try await client.catalog(userId: "u", credits: true)
        #expect(items[0].people?.map(\.name) == ["A", "C"])
        #expect(transport.requests.last?.query("fields")?.contains("People") == true)
        // The default is the quick one: the server looks people up slowly.
        _ = try await client.catalog(userId: "u")
        #expect(transport.requests.last?.query("fields")?.contains("People") == false)
    }
}

@Suite struct CreditsSearchTests {
    private static func make(_ id: String, _ name: String, _ kind: ItemKind, _ people: [Person], studios: [String]? = nil) -> Item {
        var item = Item(id: id, name: name, kind: kind)
        item.people = people
        item.studios = studios
        return item
    }

    private let index: SearchIndex = {
        let lead = Person(id: "p1", name: "Alma Ventura", role: "Marta Quiroga", kind: .actor)
        let guest = Person(id: "p2", name: "Bruno Salcedo", role: "El cartero", kind: .guestStar)
        let director = Person(id: "p3", name: "Celia Montoya", kind: .director)
        return SearchIndex(items: [
            CreditsSearchTests.make("m1", "El faro azul", .movie, [lead, director], studios: ["Estudio Brisa"]),
            CreditsSearchTests.make("s1", "Los vecinos", .series, [lead]),
            CreditsSearchTests.make("e1", "La visita", .episode, [guest]),
            CreditsSearchTests.make("m2", "Ventura en la nieve", .movie, []),
            CreditsSearchTests.make("m3", "Otra película", .movie, [Person(id: "p9", name: "Alma Lerma", kind: .actor)]),
        ])
    }()

    private func ids(_ query: String) -> [String] {
        index.search(query).sections.flatMap(\.items).map(\.id)
    }

    @Test func actorsAndDirectorsFindTheirTitles() {
        #expect(Set(ids("alma ventura").prefix(2)) == ["m1", "s1"])
        #expect(ids("montoya") == ["m1"])
    }

    @Test func wordsMustAllBelongToOnePerson() {
        // "Tomás" and "Varela" on one title, but in two different people: no match.
        let crossed = SearchIndex(items: [
            CreditsSearchTests.make("x1", "Película uno", .movie, [
                Person(id: "a", name: "Tomás Gallo", kind: .actor), Person(id: "b", name: "Lucía Varela", kind: .actor),
            ]),
            CreditsSearchTests.make("x2", "Película dos", .movie, [Person(id: "c", name: "Tomás Varela", kind: .actor)]),
        ])
        #expect(crossed.search("tomas varela").sections.flatMap(\.items).map(\.id) == ["x2"])
        // One person's name plus the character they play is still one person.
        let both = SearchIndex(items: [CreditsSearchTests.make("x3", "Otra", .movie, [Person(id: "d", name: "Rosa Mares", role: "Capitana", kind: .actor)])])
        #expect(both.search("rosa capitana").sections.flatMap(\.items).map(\.id) == ["x3"])
    }

    @Test func aWordFoundOnlyInASynopsisCannotPairWithAPerson() {
        // "nico" is a director here and "varela" only in a synopsis: not Nico Varela.
        var stray = CreditsSearchTests.make("z1", "Capítulo suelto", .episode, [Person(id: "t", name: "Nico Albarrán", kind: .director)])
        stray.overview = "Lola cuenta que Varela no llamó."
        let real = CreditsSearchTests.make("z2", "Película real", .movie, [Person(id: "h", name: "Nico Varela", kind: .actor)])
        let index = SearchIndex(items: [stray, real])
        #expect(index.search("nico varela").sections.flatMap(\.items).map(\.id) == ["z2"])
        // A title word still pairs with a person ("faro" in the title, "ventura" an actor).
        let titled = SearchIndex(items: [CreditsSearchTests.make("z3", "El faro azul", .movie, [Person(id: "v", name: "Alma Ventura", kind: .actor)])])
        #expect(titled.search("faro ventura").sections.flatMap(\.items).map(\.id) == ["z3"])
    }

    @Test func aGuestStarTheSeriesAlsoListsStaysOnHerEpisode() {
        let star = Person(id: "g", name: "Mara Vidal", role: "Vecina", kind: .guestStar)
        let series = CreditsSearchTests.make("s7", "Barrio alto", .series, [star])
        var episode = CreditsSearchTests.make("e7", "La mudanza", .episode, [star])
        episode.seriesId = "s7"
        let index = SearchIndex(items: [series, episode])
        #expect(Set(index.search("mara").sections.flatMap(\.items).map(\.id)) == ["s7", "e7"])
    }

    @Test func pluralsOfNamesEndingInKsDoNotBecomeShortWords() {
        #expect(SearchText.match("hanks", "han") == 0)
        #expect(SearchText.match("leones", "leon") == 0.8)
        #expect(SearchText.match("dragons", "dragon") == 0.8)
    }

    @Test func aSeriesRegularFindsTheSeriesNotEveryEpisode() {
        let regular = Person(id: "r1", name: "Pilar Cuesta", role: "Nora", kind: .actor)
        let guest = Person(id: "g1", name: "Hugo Prado", role: "El cartero", kind: .guestStar)
        let crew = Person(id: "d1", name: "Iris Vega", kind: .director)
        let series = CreditsSearchTests.make("s9", "La casa del lago", .series, [regular])
        var episodes: [Item] = []
        for number in 1...3 {
            var episode = CreditsSearchTests.make("ep\(number)", "Capítulo \(number)", .episode, number == 2 ? [regular, guest, crew] : [regular])
            episode.seriesId = "s9"
            episodes.append(episode)
        }
        let index = SearchIndex(items: [series] + episodes)
        #expect(index.search("pilar").sections.flatMap(\.items).map(\.id) == ["s9"])
        #expect(index.search("nora").sections.flatMap(\.items).map(\.id) == ["s9"])
        // Guest stars and an episode's own crew still find it.
        #expect(index.search("prado").sections.flatMap(\.items).map(\.id) == ["ep2"])
        #expect(index.search("vega").sections.flatMap(\.items).map(\.id) == ["ep2"])
        #expect(index.search("nora").reasons["s9"] == .character("Nora", actor: "Pilar Cuesta"))
    }

    @Test func charactersAndGuestStarsFindTheirTitles() {
        #expect(ids("quiroga").contains("m1"))
        #expect(ids("cartero") == ["e1"])
        #expect(ids("salcedo") == ["e1"])
    }

    @Test func namesGetNoTypoLeeway() {
        // Common first names would flood: "montoia" is not "montoya".
        #expect(ids("montoia").isEmpty)
        #expect(ids("salsedo").isEmpty)
        #expect(ids("quiroga").contains("m1")) // spelled right, it is found
    }

    @Test func studiosFindTitlesButRankBelowTitles() {
        #expect(ids("brisa") == ["m1"])
        let both = SearchIndex(items: index.items + [Item(id: "m4", name: "Brisa de mar", kind: .movie)])
        #expect(both.search("brisa").sections.flatMap(\.items).first?.id == "m4")
    }

    @Test func aTitleOutranksACreditWithTheSameWord() {
        let found = ids("ventura")
        #expect(found.first == "m2")
        #expect(Set(found) == ["m2", "m1", "s1"])
    }

    @Test func resultsSayWhyTheyMatchedWhenTheTitleDoesNot() {
        let results = index.search("ventura")
        #expect(results.reasons["m2"] == nil)
        #expect(results.reasons["m1"] == .person("Alma Ventura"))
        #expect(index.search("quiroga").reasons["m1"] == .character("Marta Quiroga", actor: "Alma Ventura"))
        #expect(index.search("brisa").reasons["m1"] == .studio("Estudio Brisa"))
    }

    @Test func titlesWithoutCreditsSearchAsBefore() {
        let plain = SearchIndex(items: [Item(id: "v", name: "Video casero", kind: .video)])
        #expect(plain.search("casero").sections.flatMap(\.items).map(\.id) == ["v"])
        #expect(plain.search("casero").reasons.isEmpty)
    }
}
