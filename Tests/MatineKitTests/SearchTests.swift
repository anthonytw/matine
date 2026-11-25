import Foundation
import Testing
@testable import MatineKit

private func item(
    _ id: String, _ name: String, _ kind: ItemKind = .movie,
    original: String? = nil, overview: String? = nil, genres: [String]? = nil, tags: [String]? = nil
) -> Item {
    var item = Item(id: id, name: name, kind: kind)
    item.originalTitle = original
    item.overview = overview
    item.genres = genres
    item.tags = tags
    return item
}

private let catalog = [
    item("m1", "El faro de las gaviotas", original: "The Gull Lighthouse", overview: "Una niña cuida un faro.", genres: ["Aventura"]),
    item("m2", "Viaje al volcán", overview: "Dos hermanos y un dragón buscan el fuego.", tags: ["snake"]),
    item("s1", "Los leones del parque", .series, overview: "Una familia de leones."),
    item("e1", "La tormenta", .episode, overview: "Llueve en el faro."),
    item("e2", "El dentista", .episode),
    item("v1", "Concierto de invierno", .video),
    item("x1", "Temporada 1", .season),
]

@Suite struct SearchTextTests {
    @Test func caseAndAccentsAreFoldedAway() {
        #expect(SearchText.words("¡El DRAGÓN, ñu!") == ["el", "dragon", "nu"])
    }

    @Test func wordStartsPluralsAndOneTypoMatch() {
        #expect(SearchText.match("gall", "gallinita") == 0.8)
        #expect(SearchText.match("leones", "leon") == 0.8)
        #expect(SearchText.match("viboras", "vibora") == 0.8)
        #expect(SearchText.match("denitsta", "dentista") == 0.5) // two letters swapped
        #expect(SearchText.match("dentsta", "dentista") == 0.5) // one missing
        #expect(SearchText.match("faro", "faro") == 1)
        #expect(SearchText.match("faro", "fuego") == 0)
        // Short words get no typo leeway: "cara" isn't "casa".
        #expect(SearchText.match("cara", "casa") == 0)
    }

    @Test func pluralsMatchTheirSingularNotEveryWordStartingLikeIt() {
        #expect(SearchText.match("peces", "pez") == 0.8)
        #expect(SearchText.match("luces", "luz") == 0.8)
        #expect(SearchText.match("meses", "mes") == 0.8)
        #expect(SearchText.match("dragons", "dragon") == 0.8)
        #expect(SearchText.match("leon", "leones") == 0.8) // and the other way
        #expect(SearchText.match("tres", "tren") == 0)
        #expect(SearchText.match("lunes", "luna") == 0)
        #expect(SearchText.match("cats", "catedral") == 0)
    }

    @Test func noTypoLeewayWhereItWouldFindAnything() {
        #expect(SearchText.match("perro", "pero") == 0) // too short to be a typo of
        #expect(SearchText.match("perro", "persona", typos: false) == 0)
        #expect(SearchText.match("perro", "perso") == 0.5) // in a title, one letter off still finds
    }

    @Test func functionWordsAreSetAsideUnlessThatsAllThereIs() {
        #expect(SearchText.queryWords("el faro de la playa").map(\.text) == ["faro", "playa"])
        #expect(SearchText.queryWords("the").map(\.text) == ["the"])
    }
}

@Suite struct SearchIndexTests {
    let index = SearchIndex(items: catalog)

    private func ids(_ query: String) -> [SearchResults.Group: [String]] {
        Dictionary(uniqueKeysWithValues: index.search(query).sections.map { ($0.group, $0.items.map(\.id)) })
    }

    @Test func resultsComeGroupedByKindWithTheTitleMatchFirst() {
        let results = index.search("faro")
        #expect(results.sections.map(\.group) == [.movies, .episodes])
        #expect(results.sections[0].items.map(\.id) == ["m1"])
        #expect(results.sections[1].items.map(\.id) == ["e1"]) // found by its synopsis
    }

    @Test func theOriginalTitleTagsAndGenresAreSearched() {
        #expect(ids("gull lighthouse") == [.movies: ["m1"]])
        #expect(ids("snake") == [.movies: ["m2"]])
        #expect(ids("aventura") == [.movies: ["m1"]])
    }

    @Test func everyWordMustMatchSomewhere() {
        #expect(ids("faro dragon").isEmpty)
        #expect(ids("dragon fuego") == [.movies: ["m2"]])
    }

    @Test func pluralsTyposAndAccentsStillFind() {
        #expect(ids("leon") == [.series: ["s1"]])
        #expect(ids("VOLCAN") == [.movies: ["m2"]])
        #expect(ids("denitsta") == [.episodes: ["e2"]])
    }

    @Test func anEpisodeIsFoundByItsOwnNameNotItsFileNamePrefix() {
        var episode = item("e9", "Cuentos S01E009 - El pirata", .episode)
        episode.seriesName = "Cuentos"
        let index = SearchIndex(items: [episode])
        #expect(index.search("cuentos").isEmpty)
        #expect(index.search("pirata").sections.first?.items.first?.searchCaption == "El pirata · Cuentos")
    }

    @Test func searchLeadsWithTheEpisodesNameAndSaysWhereItIsFromBelow() {
        var episode = item("e9", "Cuentos S01E009 - El pirata", .episode)
        episode.seriesName = "Cuentos para dormir - en español"
        episode.seasonNumber = 1
        episode.episodeNumber = 9
        #expect(episode.displayName == "El pirata")
        #expect(episode.searchSubtitle(.spanish) == "T1 · E9 · Cuentos para dormir - en español")
        #expect(episode.searchSubtitle(.english) == "S1 · E9 · Cuentos para dormir - en español")
        episode.seriesName = nil
        #expect(episode.searchSubtitle(.spanish) == "T1 · E9")
        #expect(item("m", "Una película", .movie).searchSubtitle(.spanish) == nil)
    }

    @Test func onATieFilmsAndShowsComeBeforeEpisodes() {
        let index = SearchIndex(items: [
            item("e", "A", .episode, overview: "Nieve en invierno."),
            item("m", "B", overview: "Nieve en la montaña."),
        ])
        #expect(index.search("nieve").sections.map(\.group) == [.movies, .episodes])
    }

    @Test func aSynopsisNeedsTheRealWordNotOneLetterOff() {
        let index = SearchIndex(items: [
            item("a", "La gran aventura", overview: "Quiere volar, pero no puede. El personaje principal."),
            item("b", "El perrito", overview: "Un perro."),
        ])
        #expect(index.search("perro").sections.first?.items.map(\.id) == ["b"])
    }

    @Test func hyphenatedNamesFindEitherWay() {
        let index = SearchIndex(items: [item("a", "Spider-Man: un nuevo universo")])
        #expect(!index.search("spiderman").isEmpty)
        #expect(!index.search("spider man").isEmpty)
        #expect(!index.search("spider-man").isEmpty)
    }

    @Test func aRelatedTitleBeyondTheRowIsNotLost() {
        let many = (0..<(SearchIndex.groupLimit + 1)).map { item("m\($0)", "Nieve \($0)") }
        let results = SearchIndex(items: many).search("nieve", related: many)
        #expect(results.sections.first?.items.count == SearchIndex.groupLimit)
        #expect(results.sections.last?.group == .related)
        #expect(results.sections.last?.items.count == 1) // the one the row had no room for
    }

    @Test func seasonsAreNotResults() {
        #expect(ids("temporada").isEmpty)
    }

    @Test func relatedTitlesFollowWithoutRepeats() {
        let results = index.search("faro", related: [catalog[0], catalog[5]])
        #expect(results.sections.map(\.group) == [.movies, .episodes, .related])
        #expect(results.sections.last?.items.map(\.id) == ["v1"])
    }
}

/// Vectors by hand: each "word" sits on an axis; words that mean the same
/// thing share one, whatever the language.
private struct FakeVectors: TokenVectors {
    let modelIdentifier = "fake#1"
    static let axes: [String: Int] = [
        "snake": 0, "serpiente": 0, "víboras": 0, "cobra": 0,
        "lighthouse": 1, "faro": 1,
        "dentist": 2, "dentista": 2,
        "winter": 3, "invierno": 3,
    ]

    func vectors(for text: String) async throws -> [TokenVector] {
        text.split { !$0.isLetter }.map { word in
            var vector = [Float](repeating: 0, count: 6)
            if let axis = Self.axes[word.lowercased()] {
                vector[axis] = 1
            } else {
                // Everything else points the same way: "unrelated".
                vector[5] = 1
            }
            return TokenVector(token: String(word), vector: vector)
        }
    }
}

@Suite struct MeaningIndexTests {
    private let titles = [
        item("a", "Las víboras del desierto"),
        item("b", "Un día de lluvia"),
        item("c", "La casa de la abuela"),
        item("d", "Paseo por el bosque"),
        item("e", "El tren de la tarde"),
        item("f", "Cuentos de la noche"),
        item("g", "El jardín secreto"),
        item("h", "Pan con tomate"),
    ]

    @Test func aWordInOneLanguageFindsATitleInTheOther() async throws {
        let model = FakeVectors()
        let meaning = await MeaningIndex.build(items: titles, model: model)
        #expect(try await meaning.related(to: model.vectors(for: "snake")).map(\.id) == ["a"])
        #expect(try await meaning.related(to: model.vectors(for: "serpiente")).map(\.id) == ["a"])
    }

    @Test func nothingStandsOutNothingIsRelated() async throws {
        let model = FakeVectors()
        let meaning = await MeaningIndex.build(items: titles, model: model)
        #expect(try await meaning.related(to: model.vectors(for: "dentist")).isEmpty)
        #expect(try await meaning.related(to: model.vectors(for: "the")).isEmpty) // function words only
    }

    @Test func theCacheIsReusedAndDroppedWhenTheModelChanges() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "matine-meaning-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = MeaningCache(url: url)
        _ = await MeaningIndex.build(items: titles, model: FakeVectors(), cache: cache)
        let stored = try #require(cache.load(model: "fake#1"))
        #expect(stored.count == titles.count)
        #expect(stored.values.contains { $0.rows == [[1, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 1]] }) // "víboras", "desierto"; not "las", "del"
        #expect(cache.load(model: "fake#2") == nil)

        // An edited synopsis is read again; the others come from the cache.
        let counting = CountingVectors()
        var edited = titles
        edited[1].overview = "Llueve."
        _ = await MeaningIndex.build(items: edited, model: counting, cache: cache)
        #expect(await counting.reads == 1)

        // Nothing new and nothing gone: the file isn't written again.
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        _ = await MeaningIndex.build(items: edited, model: FakeVectors(), cache: cache)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == past)
    }

    @Test func aDamagedCacheIsDroppedNotLoopedOver() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "matine-meaning-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let model = Data("fake#1".utf8), key = Data("k".utf8)
        // One entry claiming four billion empty vectors.
        var data = Data("MTV2".utf8) + u32(UInt32(model.count)) + model + u32(1)
        data += u32(UInt32(key.count)) + key + u32(.max) + u32(0)
        try data.write(to: url)
        #expect(MeaningCache(url: url).load(model: "fake#1") == nil)
    }

    @Test func aVectorIsKeptToAHundredthAndAtMostMaxTokensAreHeld() {
        let unit: [Float] = [0.6, -0.8, 0, 0]
        let packed = PackedVectors([unit])
        #expect(packed.bytes.count == 4)
        for (a, b) in zip(packed.rows[0], unit) { #expect(abs(a - b) < 0.005) }
        // The dot product with a query stays within a hundredth of the exact one.
        let query: [Float] = [0.8, 0.6, 0, 0]
        let exact = zip(unit, query).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        #expect(abs(packed.closest(to: query) - exact) < 0.01)
        let many = PackedVectors((0..<(PackedVectors.maxTokens + 20)).map { _ in unit })
        #expect(many.count == PackedVectors.maxTokens)
        #expect(PackedVectors([]).closest(to: query) == -1)
    }

    @Test func packedVectorsRankTitlesAsFloatsWould() async throws {
        // Dense, non-axis vectors: related titles by the packed index match a float reference.
        struct Dense: TokenVectors {
            let modelIdentifier = "dense#1"
            func vectors(for text: String) async throws -> [TokenVector] {
                text.split { !$0.isLetter }.map { word in
                    var seed = StableHash.fnv1a(word.lowercased()) | 1
                    var raw: [Float] = (0..<64).map { _ in
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        return Float(Int64(bitPattern: seed >> 11) % 2001 - 1000) / 1000
                    }
                    // Words sharing a first letter point alike, so some titles stand clear.
                    raw[0] += word.lowercased().hasPrefix("z") ? 8 : 0
                    let norm = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
                    return TokenVector(token: String(word), vector: raw.map { $0 / norm })
                }
            }
        }
        var items = (0..<12).map { item("t\($0)", "Cosa numero \($0) tranquila") }
        items.append(item("z1", "Zorro zafiro zeta"))
        let model = Dense()
        let meaning = await MeaningIndex.build(items: items, model: model)
        let query = try await model.vectors(for: "zorro")
        // Float reference of the same scoring.
        var reference: [(String, Float)] = []
        for entry in items {
            let held = MeaningIndex.meaningful(try await model.vectors(for: MeaningIndex.text(entry)))
            let words = MeaningIndex.meaningful(query)
            let score = words.reduce(Float(0)) { sum, word in
                sum + held.reduce(Float(-1)) { max($0, zip(word, $1).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
            } / Float(words.count)
            reference.append((entry.id, score))
        }
        let mean = reference.map(\.1).reduce(0, +) / Float(reference.count)
        let spread = (reference.map { ($0.1 - mean) * ($0.1 - mean) }.reduce(0, +) / Float(reference.count)).squareRoot()
        let expected = reference.filter { ($0.1 - mean) / spread >= MeaningIndex.clearance }.sorted { $0.1 > $1.1 }.map(\.0)
        #expect(!expected.isEmpty)
        #expect(meaning.related(to: query).map(\.id) == expected)
    }

    @Test func aProfileCacheNameIsAHashNeverTheServersId() {
        let caches = URL(filePath: "/tmp/caches")
        let hostile = MeaningCache.url(accountId: "../../Library/Preferences/x", in: caches)
        #expect(hostile.deletingLastPathComponent().path == caches.path)
        #expect(!hostile.lastPathComponent.contains(".."))
        #expect(MeaningCache.url(accountId: "a", in: caches) != MeaningCache.url(accountId: "b", in: caches))
        #expect(MeaningCache.url(accountId: "a", in: caches) == MeaningCache.url(accountId: "a", in: caches))
    }

    @Test func oldCachesAreDeletedOnceAndCurrentOnesKept() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "matine-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appending(path: "search-meaning-0123456789abcdef0123456789abcdef.bin")
        let oldFormat = MeaningCache.url(accountId: "old", in: dir)
        let current = MeaningCache.url(accountId: "new", in: dir)
        let other = dir.appending(path: "keep.bin")
        try Data("MTV1xxxx".utf8).write(to: raw)
        try Data("MTV1xxxx".utf8).write(to: oldFormat)
        try Data("MTV2xxxx".utf8).write(to: current)
        try Data("x".utf8).write(to: other)
        MeaningCache.removeLegacy(in: dir)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == [current.lastPathComponent, "keep.bin"])
    }

    @Test func aFailedWriteLeavesNoSideFileAndAGoodCacheStays() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "matine-meaning-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = MeaningCache(url: url)
        _ = await MeaningIndex.build(items: titles, model: FakeVectors(), cache: cache)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
        #expect(cache.load(model: "fake#1") != nil)
    }

    @Test func theModelReadsTheTidyName() {
        var episode = item("e", "Cuentos S01E009 - El pirata", .episode)
        episode.overview = "Un barco."
        #expect(MeaningIndex.text(episode) == "El pirata. Un barco.")
    }
}

private actor CountingVectors: TokenVectors {
    nonisolated let modelIdentifier = "fake#1"
    private(set) var reads = 0

    func vectors(for text: String) async throws -> [TokenVector] {
        reads += 1
        return try await FakeVectors().vectors(for: text)
    }
}
