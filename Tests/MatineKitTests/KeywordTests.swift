import Foundation
import Testing
@testable import MatineKit

private struct Boom: Error {}

private struct FakeGenerator: KeywordGenerator {
    let identifier = "fake"
    let table: [String: [String]]
    var failing: Set<String> = []
    var unavailable = false
    var unavailableOn: Set<String> = []
    func keywords(for source: KeywordSource) async throws -> [String] {
        if unavailableOn.contains(source.id) { throw KeywordsUnavailable("gone") }
        if unavailable { throw KeywordsUnavailable("no model") }
        if failing.contains(source.id) { throw Boom() }
        return table[source.id] ?? []
    }
}

private func movie(_ id: String, _ name: String, overview: String? = nil, kind: ItemKind = .movie) -> Item {
    var item = Item(id: id, name: name, kind: kind)
    item.overview = overview
    return item
}

@Suite struct KeywordTests {
    @Test func hashChangesOnlyWithTheText() {
        let a = KeywordSource(item: movie("1", "Pelo largo", overview: "Un perro."))
        let same = KeywordSource(item: movie("other", "Pelo largo", overview: "Un perro."))
        let edited = KeywordSource(item: movie("1", "Pelo largo", overview: "Un gato."))
        #expect(a.hash == same.hash)
        #expect(a.hash != edited.hash)
        #expect(a.hash.count == 16)
    }

    @Test func cleanLowercasesDedupesAndCaps() {
        let source = KeywordSource(id: "1", name: "Luna")
        let words = KeywordWords.clean(["Perro", " perro ", "DOG.", "the", "luna", "a b c d", "x y z"] + (0..<20).map { "w\($0)" }, source: source, personNames: [])
        #expect(Array(words.prefix(3)) == ["perro", "dog", "x y z"])
        #expect(!words.contains("the") && !words.contains("luna") && !words.contains("a b c d"))
        #expect(words.count == KeywordStore.maxWords)
    }

    @Test func storeRoundTripsCompactAndRefusesNewerSchema() throws {
        var store = KeywordStore()
        store.set("m1", ItemKeywords(words: ["dog", "perro"], sourceHash: "abc", made: 5))
        let data = try store.data()
        #expect(String(decoding: data, as: UTF8.self) == #"{"e":{"m1":{"h":"abc","t":5,"w":["dog","perro"]}},"v":1}"#)
        #expect(try KeywordStore(data: data) == store)
        #expect(throws: (any Error).self) { try KeywordStore(data: Data(#"{"v":2,"e":{}}"#.utf8)) }
    }

    @Test func mergeKeepsTheNewerAndPruneDropsGone() {
        var a = KeywordStore(entries: ["x": .init(words: ["old"], sourceHash: "h", made: 1), "gone": .init(words: ["z"], sourceHash: "h", made: 1)])
        let b = KeywordStore(entries: ["x": .init(words: ["new"], sourceHash: "h", made: 2), "y": .init(words: ["y"], sourceHash: "h", made: 1)])
        a.merge(b)
        #expect(a.keywords(for: "x")?.words == ["new"])
        #expect(a.keywords(for: "y") != nil)
        a.prune(keeping: ["x", "y"])
        #expect(a.keywords(for: "gone") == nil)
    }

    @Test func builderOnlyRedoesStaleItemsAndSkipsContainers() async throws {
        let dog = movie("m1", "Pelo largo", overview: "Una historia.")
        let episode = movie("e1", "Capitulo", kind: .episode)
        let season = movie("s1", "Temporada 1", kind: .season)
        let builder = KeywordBuilder(generator: FakeGenerator(table: ["m1": ["dog", "perro"], "e1": ["puppy"], "s1": ["nope"]]), now: { Date(timeIntervalSince1970: 100) })
        var store = KeywordStore()
        var report = try await builder.fill(&store, items: [dog, episode, season])
        #expect(report.generated == 2)
        #expect(store.keywords(for: "m1")?.words == ["dog", "perro"])
        #expect(store.keywords(for: "e1")?.words == ["puppy"])
        #expect(store.keywords(for: "s1") == nil)
        #expect(store.isFresh(dog))
        report = try await builder.fill(&store, items: [dog])
        #expect(report.generated == 0)
        var edited = dog
        edited.overview = "Un gato."
        #expect(!store.isFresh(edited))
        report = try await builder.fill(&store, items: [edited], limit: 1)
        #expect(report.generated == 1)
    }

    @Test func oneFailureIsReportedUnavailableStopsTheRun() async throws {
        let items = [movie("a", "Uno"), movie("b", "Dos")]
        var store = KeywordStore()
        let report = try await KeywordBuilder(generator: FakeGenerator(table: [:], failing: ["a"])).fill(&store, items: items)
        #expect(report.generated == 1 && report.failed.map(\.id) == ["a"])
        var empty = KeywordStore()
        await #expect(throws: KeywordsUnavailable("no model")) {
            _ = try await KeywordBuilder(generator: FakeGenerator(table: [:], unavailable: true)).fill(&empty, items: items)
        }
    }

    @Test func searchFindsItemsByKeywordsInEitherLanguage() {
        let items = [movie("m1", "Pelo largo"), movie("m2", "Viaje"), movie("m3", "Un perrito en la ciudad", overview: "Dog days.")]
        let store = KeywordStore(entries: ["m1": .init(words: ["dog", "perro", "cachorro"], sourceHash: "stale", made: 1)])
        let index = SearchIndex(items: items, keywords: store)
        #expect(index.search("dog").sections.flatMap(\.items).map(\.id) == ["m1", "m3"])
        #expect(Set(index.search("perro").sections.flatMap(\.items).map(\.id)) == ["m1", "m3"])
        // Keywords are not typo-tolerant, and without them nothing matches.
        #expect(index.search("cachorra").isEmpty)
        #expect(SearchIndex(items: items).search("cachorro").isEmpty)
    }

    @Test func aTitleOutranksAKeyword() {
        let items = [movie("k", "Otra cosa"), movie("t", "Dog")]
        let store = KeywordStore(entries: ["k": .init(words: ["dog"], sourceHash: "h", made: 1)])
        #expect(SearchIndex(items: items, keywords: store).search("dog").sections.first?.items.map(\.id) == ["t", "k"])
    }

    @Test func pruneOnlyAgainstTheWholeCatalog() {
        #expect(KeywordBuilder.mayPrune(requested: true, library: nil, catalogCount: 10))
        #expect(!KeywordBuilder.mayPrune(requested: false, library: nil, catalogCount: 10)) // only on --prune
        #expect(!KeywordBuilder.mayPrune(requested: true, library: "lib", catalogCount: 10))
        #expect(!KeywordBuilder.mayPrune(requested: true, library: nil, catalogCount: 20_000))
    }

    @Test func aRunThatStopsStillCheckpointsWhatItMade() async throws {
        let items = ["a", "b", "c"].map { movie($0, "Titulo \($0)") }
        let generator = FakeGenerator(table: ["a": ["dog"], "b": ["cat"]], unavailableOn: ["c"])
        var store = KeywordStore()
        let saved = Saved()
        await #expect(throws: KeywordsUnavailable("gone")) {
            _ = try await KeywordBuilder(generator: generator).fill(&store, items: items, checkpointEvery: 1, checkpoint: { saved.add($0.count) })
        }
        #expect(saved.counts == [1, 2, 2])
        #expect(store.count == 2)
    }

    @Test func anotherGeneratorMakesEntriesStale() async throws {
        let item = movie("m1", "Pelo largo")
        var store = KeywordStore()
        _ = try await KeywordBuilder(generator: FakeGenerator(table: ["m1": ["dog"]])).fill(&store, items: [item])
        #expect(store.isFresh(item, generation: "fake"))
        #expect(!store.isFresh(item, generation: "fake-v2"))
        #expect(store.stale(in: [item], generation: "other") == [item])
    }

    @Test func mixedLanguageIsDetectedPerPieceWithoutLabels() {
        // A recognizer seam: English genres inside a Spanish item.
        let guess: @Sendable (String) -> [String: Double] = { text in
            text == "Comedy" ? ["en": 0.9, "es": 0.1] : text.isEmpty ? [:] : ["es": 0.8, "en": 0.2]
        }
        let source = KeywordSource(id: "1", name: "El perro valiente", genres: ["Comedy"])
        let item = KeywordLanguage.ofItem(source, hypotheses: guess, fallback: "en")
        #expect(item == "es")
        #expect(KeywordLanguage.pick(guess("Comedy"), fallback: item) == "en")
        #expect(KeywordLanguage.pick(["es": 0.5, "en": 0.45], fallback: "en") == "en")
        #expect(!source.fieldValues.contains { $0.hasPrefix("name:") })
    }

    @Test func cleanDropsWordsTheFieldsSpellPeopleAndLongPhrases() {
        let source = KeywordSource(id: "1", name: "Luna", overview: "Con Ana Gomez en el bosque.", genres: ["Aventura"])
        let words = KeywordWords.clean(["ana gomez", "bosque", "aventura", "nico varela", "perro valiente", "lunas verdes"], source: source, personNames: ["varela"])
        #expect(words == ["perro valiente", "lunas verdes"])
    }

    @Test func mergePrefersTheMatchingHashThenNewerAndKeepsTiesAndClamps() {
        let long = (0..<30).map { "w\($0)" }
        var a = KeywordStore(entries: ["x": .init(words: ["fits"], sourceHash: "now", made: 1), "t": .init(words: ["mine"], sourceHash: "h", made: 5)])
        let b = KeywordStore(entries: ["x": .init(words: ["newer-stale"], sourceHash: "old", made: 9), "t": .init(words: ["theirs"], sourceHash: "h", made: 5), "z": .init(words: long, sourceHash: "h", made: 1)])
        a.merge(b, currentHashes: ["x": "now"])
        #expect(a.keywords(for: "x")?.words == ["fits"])
        #expect(a.keywords(for: "t")?.words == ["mine"])
        #expect(a.keywords(for: "z")?.words.count == KeywordStore.maxWords)
        a.merge(b)
        #expect(a.keywords(for: "x")?.words == ["newer-stale"])
        #expect(KeywordStore(entries: ["z": .init(words: long, sourceHash: "h", made: 1)]).keywords(for: "z")?.words.count == KeywordStore.maxWords)
    }

    @Test func keywordsOnManyItemsAreIgnoredButRareOnesStay() {
        var items: [Item] = []
        var entries: [String: ItemKeywords] = [:]
        for i in 0..<30 {
            items.append(movie("i\(i)", "Titulo\(i)"))
            entries["i\(i)"] = .init(words: i < 10 ? ["familia"] : ["rareza\(i)"], sourceHash: "h", made: 1)
        }
        entries["i0"]?.words.append("unico")
        let index = SearchIndex(items: items, keywords: KeywordStore(entries: entries))
        #expect(index.search("familia").isEmpty)
        #expect(index.search("unico").sections.flatMap(\.items).map(\.id) == ["i0"])
        // A small catalog is not judged.
        #expect(!SearchIndex(items: Array(items.prefix(5)), keywords: KeywordStore(entries: entries)).search("familia").isEmpty)
    }

    @Test func namesComeFromTheSourceTextNotFromTheKeyword() {
        // Plain Spanish pairs are never judged on their own (the tagger calls them names).
        let source = KeywordSource(id: "1", name: "Luna", overview: "Una niña y su amigo.")
        let words = KeywordWords.clean(["perro valiente", "gato negro", "casa embrujada", "rey león", "dragón rojo"], source: source)
        #expect(words.count == 5)
        let names = KeywordWords.personNames(in: KeywordSource(id: "2", name: "Luna", overview: "Dirigida por Marta Ibarra con Nico Varela."))
        #expect(KeywordWords.clean(["nico", "varela cine", "nube"], source: nil, personNames: ["varela"]) == ["nico", "nube"])
        _ = names // the real tagger's output is system-dependent; only that it runs
    }

    /// 30 films with keywords: "perro"/"perros" on 10 (33%), the rest one-offs.
    private func perroLibrary(waiting episodes: Int) -> SearchIndex {
        var items: [Item] = []
        var entries: [String: ItemKeywords] = [:]
        for i in 0..<30 {
            items.append(movie("i\(i)", "Titulo\(i)"))
            entries["i\(i)"] = .init(words: [i < 5 ? "perro" : i < 10 ? "perros" : "rareza\(i)"], sourceHash: "h", made: 1)
        }
        items += (0..<episodes).map { movie("e\($0)", "Cap\($0)", kind: .episode) }
        return SearchIndex(items: items, keywords: KeywordStore(entries: entries))
    }

    @Test func frequencyIsMeasuredOverItemsThatHaveKeywordsAndFoldsPlurals() {
        // 20 episodes still waiting would water the 33% share down if they counted.
        let index = perroLibrary(waiting: 20)
        #expect(index.search("perro").sections.flatMap(\.items).isEmpty)
        #expect(index.search("rareza20").sections.flatMap(\.items).count == 1)
    }

    @Test func pluralsShareOneFrequencyKey() {
        for (plural, single) in [("perros", "perro"), ("leones", "leon"), ("peces", "pez"), ("casas", "casa"), ("dogs", "dog"), ("foxes", "fox"), ("trees", "tree"), ("flores", "flor")] {
            #expect(SearchIndex.frequencyKey(plural) == SearchIndex.frequencyKey(single), "\(plural)")
        }
        #expect(SearchIndex.frequencyKey("osos polares") == "oso polar")
    }

    @Test func nothingIsDroppedWhileMostTitlesStillWaitForKeywords() {
        // 30 of 230 done: the first batch's shared theme isn't the library's.
        #expect(perroLibrary(waiting: 200).search("perro").sections.flatMap(\.items).count == 10)
    }

    @Test func aWordOnFewTitlesIsNeverDropped() {
        var items: [Item] = []
        var entries: [String: ItemKeywords] = [:]
        for i in 0..<30 {
            items.append(movie("i\(i)", "Titulo\(i)"))
            entries["i\(i)"] = .init(words: [i < 5 ? "perro" : "rareza\(i)"], sourceHash: "h", made: 1)
        }
        // 5 of 30 is over 12%, but under the floor of 8 titles.
        #expect(SearchIndex(items: items, keywords: KeywordStore(entries: entries)).search("perro").sections.flatMap(\.items).count == 5)
    }

    @Test func anEpisodeIsFoundByItsKeywords() {
        var story = movie("e1", "Willi, casi verde", kind: .episode)
        story.seriesName = "Cuentos"
        let index = SearchIndex(items: [story], keywords: KeywordStore(entries: ["e1": .init(words: ["dog", "perro"], sourceHash: "h", made: 1)]))
        #expect(index.search("dog").sections.flatMap(\.items).map(\.id) == ["e1"])
    }

    @Test func anEpisodeIsDescribedWithItsSeriesAndFilmsComeFirst() async throws {
        var episode = movie("e1", "Capitulo 3", kind: .episode)
        episode.seriesName = "Cuentos del bosque"
        let source = KeywordSource(item: episode)
        #expect(source.text.contains("series: Cuentos del bosque"))
        // The series' own words are already searchable: never stored as keywords.
        #expect(KeywordWords.clean(["bosque", "lobo"], source: source, personNames: []) == ["lobo"])
        // A film's text has no series line, so its hash is as before.
        #expect(KeywordSource(item: movie("m1", "Pelo largo")).text == "name: Pelo largo")
        let order = Order()
        let builder = KeywordBuilder(generator: FakeGenerator(table: ["e1": ["x"], "m1": ["y"]]))
        var store = KeywordStore()
        _ = try await builder.fill(&store, items: [episode, movie("m1", "Pelo largo")], each: { item, _ in order.add(item.id) })
        #expect(order.ids == ["m1", "e1"])
    }

    @Test func checkpointEveryZeroNeverCheckpointsMidRun() async throws {
        let saved = Saved()
        var store = KeywordStore()
        _ = try await KeywordBuilder(generator: FakeGenerator(table: [:])).fill(&store, items: [movie("a", "Uno"), movie("b", "Dos")], checkpointEvery: 0, checkpoint: { saved.add($0.count) })
        #expect(saved.counts.isEmpty)
    }

    @Test func timeoutReturnsTheResultOrNilAndHonorsCancellation() async {
        #expect(await withTimeout(5) { 7 } == 7)
        let started = Date()
        #expect(await withTimeout(0.05) { () -> Int in try? await Task.sleep(for: .seconds(30)); return 1 } == nil)
        #expect(Date().timeIntervalSince(started) < 5)
        let task = Task { await withTimeout(30) { () -> Int in try? await Task.sleep(for: .seconds(60)); return 1 } }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

private final class Saved: @unchecked Sendable {
    private(set) var counts: [Int] = []
    func add(_ n: Int) { counts.append(n) }
}

private final class Order: @unchecked Sendable {
    private(set) var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}
