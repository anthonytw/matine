import Foundation
import Testing
@testable import MatineKit

private func title(_ id: String, _ name: String, _ kind: ItemKind = .movie, overview: String? = nil) -> Item {
    var item = Item(id: id, name: name, kind: kind)
    item.overview = overview
    return item
}

/// A library that answers only `catalog()`, and counts how often it is asked.
private final class FakeSource: LibrarySource, @unchecked Sendable {
    let userId = "user-1"
    private let lock = NSLock()
    private var items: [Item]
    private var failing = false
    private var calls = 0

    init(_ items: [Item]) { self.items = items }

    var reads: Int { lock.withLock { calls } }
    func set(_ items: [Item]) { lock.withLock { self.items = items } }
    func fail(_ on: Bool) { lock.withLock { failing = on } }

    struct Down: Error {}

    func catalog() async throws -> [Item] {
        try lock.withLock {
            calls += 1
            if failing { throw Down() }
            return items
        }
    }

    func home() async throws -> HomeContent { throw Down() }
    func libraries() async throws -> [Item] { throw Down() }
    func libraryPage(libraryId: String, sort: LibrarySort, start: Int, limit: Int, countTotal: Bool) async throws -> ItemPage { throw Down() }
    func item(_ itemId: String) async throws -> Item { throw Down() }
    func seasons(seriesId: String) async throws -> [Item] { throw Down() }
    func episodes(seriesId: String, seasonId: String) async throws -> [Item] { throw Down() }
    func episodeToPlay(seriesId: String) async throws -> Item? { throw Down() }
    func setPinned(_ pinned: Bool, itemId: String) async throws { throw Down() }
    func playbackPlan(itemId: String, startTicks: Int64, allowDirectPlay: Bool, constrained: Bool) async throws -> PlaybackPlan { throw Down() }
    var streamHeaders: [String: String] { [:] }
    func imageURL(_ ref: ImageRef, maxHeight: Int) -> URL { URL(string: "https://example.invalid/")! }
    func reportStart(_ report: PlaybackReport) async throws {}
    func reportProgress(_ report: PlaybackReport) async throws {}
    func reportStopped(_ report: PlaybackReport) async throws {}
}

private final class SearchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

/// Keywords the session is handed, and when they change.
@MainActor private final class Words {
    var store = KeywordStore()
    var version = 0
    /// Suspends the next keyword read until `open()`.
    var gate: CheckedContinuation<Void, Never>?
    var holdNext = false
    var reads = 0
    var started: CheckedContinuation<Void, Never>?

    func read() async -> KeywordStore {
        reads += 1
        let snapshot = store
        if holdNext {
            holdNext = false
            started?.resume()
            started = nil
            await withCheckedContinuation { gate = $0 }
        }
        return snapshot
    }

    func open() {
        gate?.resume()
        gate = nil
    }
}

private struct AxisVectors: TokenVectors {
    let modelIdentifier = "axes#1"
    func vectors(for text: String) async throws -> [TokenVector] {
        text.split { !$0.isLetter }.map { word in
            var vector = [Float](repeating: 0, count: 4)
            switch word.lowercased() {
            case "snake", "serpiente": vector[0] = 1
            default: vector[3] = 1
            }
            return TokenVector(token: String(word), vector: vector)
        }
    }
}

@MainActor private func session(
    _ source: FakeSource, words: Words = Words(), clock: SearchTestClock = SearchTestClock(), credits: Bool = false,
    model: (any TokenVectors)? = nil, cache: MeaningCache? = nil,
    expired: Bool = false, readNotice: @escaping @MainActor ([Item]) -> Void = { _ in }
) -> SearchSession {
    SearchSession(
        catalog: { _ in try await source.catalog() }, supportsCredits: credits,
        keywords: { _ in await words.read() }, keywordVersion: { words.version },
        catalogRead: readNotice, sessionExpired: { _ in expired },
        makeModel: { model }, cache: cache, now: { clock.now }, pause: .zero
    )
}

private let library = [
    title("m1", "El faro de las gaviotas", overview: "Una niña cuida un faro."),
    title("m2", "Viaje al volcán", overview: "Dos hermanos y un dragón."),
    title("s1", "Los leones del parque", .series),
    title("e1", "La tormenta", .episode),
]

@MainActor @Suite struct SearchSessionTests {
    @Test func loadingBuildsTheIndexAndAQueryFindsTitles() async {
        let source = FakeSource(library)
        let search = session(source)
        #expect(search.index == nil)
        await search.load()
        #expect(search.index != nil && !search.failed)
        await search.search("  faro ")
        #expect(search.results.sections.flatMap(\.items).map(\.id) == ["m1"])
        await search.search("")
        #expect(search.results.isEmpty)
    }

    @Test func aFreshCatalogIsNotReadAgainUntilItIsStale() async {
        let source = FakeSource(library)
        let clock = SearchTestClock()
        var notices = 0
        let search = session(source, clock: clock, readNotice: { _ in notices += 1 })
        await search.load()
        await search.load()
        #expect(source.reads == 1 && notices == 1)
        clock.advance(SearchSession.freshFor + 1)
        source.set(library + [title("m3", "Un tren azul")])
        await search.load()
        #expect(source.reads == 2 && notices == 2)
        await search.search("tren")
        #expect(search.results.sections.flatMap(\.items).map(\.id) == ["m3"])
    }

    @Test func aFailedFirstReadShowsTheRetryStateAndASuccessClearsIt() async {
        let source = FakeSource(library)
        source.fail(true)
        let search = session(source)
        await search.load()
        #expect(search.failed && search.index == nil)
        source.fail(false)
        await search.load()
        #expect(!search.failed && search.index != nil)
    }

    @Test func anExpiredSessionIsHandledElsewhereAndShowsNoRetry() async {
        let source = FakeSource(library)
        source.fail(true)
        let search = session(source, expired: true)
        await search.load()
        #expect(!search.failed)
    }

    @Test func aFailedRefreshKeepsTheIndexWeHave() async {
        let source = FakeSource(library)
        let clock = SearchTestClock()
        let search = session(source, clock: clock)
        await search.load()
        clock.advance(SearchSession.freshFor + 1)
        source.fail(true)
        await search.load()
        #expect(search.index != nil)
        await search.search("faro")
        #expect(!search.results.isEmpty)
    }

    @Test func keywordsThatArriveWhileTheIndexIsBuiltAreIndexedToo() async {
        let source = FakeSource(library)
        let words = Words()
        let search = session(source, words: words)
        await search.load()
        await search.search("zorro")
        #expect(search.results.isEmpty)
        var store = KeywordStore()
        store.set("m2", ItemKeywords(words: ["zorro"], sourceHash: KeywordSource(item: library[1]).hash, made: 1, generation: "g/1", retryAfter: nil))
        words.store = store
        words.version += 1
        search.keywordsChanged()
        let before = search.revision
        for _ in 0..<200 where search.revision == before { try? await Task.sleep(for: .milliseconds(10)) }
        await search.search("zorro")
        #expect(search.results.sections.flatMap(\.items).map(\.id) == ["m2"])
    }

    @Test func anOlderRebuildNeverLandsOverANewerIndex() async {
        let source = FakeSource(library)
        let words = Words()
        let clock = SearchTestClock()
        let search = session(source, words: words, clock: clock)
        await search.load()
        // A keyword rebuild starts, and stalls reading keywords.
        words.holdNext = true
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            words.started = started
            search.keywordsChanged()
        }
        // Meanwhile a newer catalog is read and indexed.
        clock.advance(SearchSession.freshFor + 1)
        source.set(library + [title("m3", "Un tren azul")])
        await search.load()
        #expect(search.index?.items.count == library.count + 1)
        // The stalled rebuild finishes with the old catalog: it must be dropped.
        words.open()
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(search.index?.items.count == library.count + 1)
    }

    @Test func creditsArriveAfterTheFirstIndex() async {
        let source = FakeSource(library)
        let asked = Asked()
        let search = SearchSession(
            catalog: { credits in
                asked.add(credits)
                return try await source.catalog()
            }, supportsCredits: true,
            keywords: { _ in KeywordStore() }, keywordVersion: { 0 }, makeModel: { nil }, cache: nil
        )
        await search.load()
        #expect(search.withCredits)
        #expect(asked.values == [false, true])
        // Withheld on a source that has none (downloaded-only).
        let plain = session(FakeSource(library), credits: false)
        await plain.load()
        #expect(!plain.withCredits)
    }

    @Test func meaningMatchesFollowTheWordMatchesWithoutRepeats() async {
        var items = (0..<8).map { title("t\($0)", "Titulo \($0)", overview: "Algo distinto") }
        items.append(title("v1", "Las víboras", overview: "Una serpiente."))
        let source = FakeSource(items)
        let search = session(source, model: AxisVectors())
        await search.load()
        #expect(search.hasMeaning)
        await search.search("snake")
        #expect(search.results.sections.map(\.group) == [.related])
        #expect(search.results.sections.first?.items.map(\.id) == ["v1"])
        // A title the words already found isn't repeated under Relacionado.
        await search.search("serpiente")
        #expect(search.results.sections.flatMap(\.items).map(\.id).filter { $0 == "v1" }.count == 1)
    }

    @Test func resetForgetsTheCatalog() async {
        let source = FakeSource(library)
        let search = session(source)
        await search.load()
        search.reset()
        #expect(search.index == nil && search.results.isEmpty)
        await search.load()
        #expect(source.reads == 2 && search.index != nil)
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Bool] = []
    func add(_ value: Bool) { lock.withLock { list.append(value) } }
    var values: [Bool] { lock.withLock { list } }
}

@Suite struct SearchResultsAddingTests {
    @Test func relatedTitlesAreAppendedOnceAndReplaceAnEarlierSection() {
        var base = SearchResults(sections: [.init(group: .movies, items: [title("a", "Faro")])])
        base = base.adding(related: [title("a", "Faro"), title("b", "Otro")], query: "faro")
        #expect(base.sections.map(\.group) == [.movies, .related])
        #expect(base.sections.last?.items.map(\.id) == ["b"])
        let again = base.adding(related: [title("c", "Tercero")], query: "faro")
        #expect(again.sections.last?.items.map(\.id) == ["c"])
        #expect(again.sections.count == 2)
    }
}
