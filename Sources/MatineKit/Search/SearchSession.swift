import Foundation
import Observation

/// Everything Search does that isn't drawing, for both apps: the profile's
/// catalog read once and again after `freshFor`, the index built off the
/// main actor, rebuilt when keywords arrive (an older build never lands over
/// a newer one), the meaning index read and cached, and each query answered
/// (word matches at once, then, after a pause, the titles related by meaning).
/// The views only show `results` and call `load()`, `search(_:)`,
/// `keywordsChanged()` and `reset()`.
@MainActor @Observable
public final class SearchSession {
    /// The model and its reading of the catalog, together: one is no use without the other.
    struct Meaning: Sendable {
        let model: any TokenVectors
        let index: MeaningIndex
    }

    /// Long enough that a search session reads the catalog once; short
    /// enough that last night's additions show up.
    public static let freshFor: TimeInterval = 15 * 60

    public private(set) var index: SearchIndex?
    public private(set) var results = SearchResults()
    /// The catalog could not be read and there is nothing to search yet.
    public private(set) var failed = false
    /// People and studios are in the index (they arrive after the first one:
    /// the server takes over a second to look them up).
    public private(set) var withCredits = false
    /// Bumped whenever what a query would find has changed (a new index, a
    /// new catalog, the meaning index arriving): the view re-runs `search`.
    public private(set) var revision = 0

    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var meaning: Meaning?
    /// The catalog `meaning` read (it's read again when the catalog is).
    @ObservationIgnored private var meaningOf: Date?
    /// The last meaning matches: kept while the next are worked out, so the
    /// row doesn't vanish and return at every keystroke.
    @ObservationIgnored private var related: [Item] = []
    /// Counts the indexes set, so a slower, older build can't replace a newer one.
    @ObservationIgnored private var indexSerial = 0
    @ObservationIgnored private var rebuild: Task<Void, Never>?

    @ObservationIgnored private let catalog: @Sendable (_ credits: Bool) async throws -> [Item]
    @ObservationIgnored private let supportsCredits: Bool
    @ObservationIgnored private let keywords: @MainActor (_ items: [Item]) async -> KeywordStore
    @ObservationIgnored private let keywordVersion: @MainActor () -> Int
    @ObservationIgnored private let catalogRead: @MainActor ([Item]) -> Void
    @ObservationIgnored private let sessionExpired: @MainActor (any Error) -> Bool
    @ObservationIgnored private let makeModel: @Sendable () async -> (any TokenVectors)?
    @ObservationIgnored private let cache: MeaningCache?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let pause: Duration

    /// - Parameters:
    ///   - catalog: reads the profile's catalog; `credits` asks for people and studios too.
    ///   - supportsCredits: false when `catalog` can't give credits (a downloaded-only source).
    ///   - keywords: the keywords to index `items` with (as of the last sync).
    ///   - keywordVersion: changes when new keywords are ready.
    ///   - catalogRead: told each catalog read (the TV refreshes iCloud's keywords from it).
    ///   - sessionExpired: true when `error` was the session ending (it is handled elsewhere: no retry message).
    ///   - makeModel: the on-device meaning model, nil when absent.
    public init(
        catalog: @escaping @Sendable (_ credits: Bool) async throws -> [Item],
        supportsCredits: Bool,
        keywords: @escaping @MainActor (_ items: [Item]) async -> KeywordStore,
        keywordVersion: @escaping @MainActor () -> Int,
        catalogRead: @escaping @MainActor ([Item]) -> Void = { _ in },
        sessionExpired: @escaping @MainActor (any Error) -> Bool = { _ in false },
        makeModel: @escaping @Sendable () async -> (any TokenVectors)?,
        cache: MeaningCache?,
        now: @escaping @Sendable () -> Date = { Date() },
        pause: Duration = .milliseconds(300)
    ) {
        self.catalog = catalog
        self.supportsCredits = supportsCredits
        self.keywords = keywords
        self.keywordVersion = keywordVersion
        self.catalogRead = catalogRead
        self.sessionExpired = sessionExpired
        self.makeModel = makeModel
        self.cache = cache
        self.now = now
        self.pause = pause
    }

    /// Whether the meaning model has read the catalog (related titles are on).
    public var hasMeaning: Bool { meaning != nil }

    /// Reads the catalog if it's missing or stale (keeping the old one
    /// meanwhile), then has the model read it, in the background. Cancelling
    /// the calling task stops the reading; calling again carries on from the cache.
    public func load() async {
        if loadedAt.map({ now().timeIntervalSince($0) >= Self.freshFor }) ?? true {
            do {
                // Once an index with credits exists, a refresh fetches them
                // too and swaps when they arrive: the names never drop out.
                let items = try await catalog(withCredits)
                guard !Task.isCancelled else { return }
                let seen = keywordVersion()
                let words = await keywords(items)
                let built = await Self.build(items, keywords: words)
                guard !Task.isCancelled else { return }
                rebuild?.cancel()
                setIndex(built)
                // Keywords that arrived while this was built are not in it.
                if keywordVersion() != seen { keywordsChanged() }
                loadedAt = now()
                revision += 1
                catalogRead(items)
                failed = false
            } catch {
                if !Task.isCancelled, !sessionExpired(error), index == nil { failed = true }
                return
            }
        }
        if supportsCredits, !withCredits, let credited = try? await catalog(true), !Task.isCancelled {
            let seen = keywordVersion()
            let built = await Self.build(credited, keywords: await keywords(credited))
            guard !Task.isCancelled else { return }
            rebuild?.cancel()
            setIndex(built)
            withCredits = true
            if keywordVersion() != seen { keywordsChanged() }
        }
        guard let index, let loadedAt, meaningOf != loadedAt, let model = await makeModel() else { return }
        let reading = await MeaningIndex.build(items: index.items, model: model, cache: cache)
        guard !Task.isCancelled else { return }
        meaning = Meaning(model: model, index: reading)
        meaningOf = loadedAt
        revision += 1
    }

    /// New keywords: the same catalog, indexed again. An older build never lands over a
    /// newer index (a catalog read, or a later rebuild): each assignment counts, and a
    /// rebuild that started before another one finished is dropped.
    public func keywordsChanged() {
        guard let items = index?.items else { return }
        rebuild?.cancel()
        let serial = indexSerial
        rebuild = Task {
            let words = await keywords(items)
            let built = await Self.build(items, keywords: words)
            guard !Task.isCancelled, serial == indexSerial else { return }
            setIndex(built)
        }
    }

    /// Forgets the catalog (the source changed: offline shows only what is downloaded).
    public func reset() {
        rebuild?.cancel()
        index = nil
        loadedAt = nil
        meaning = nil
        meaningOf = nil
        related = []
        results = SearchResults()
        revision += 1
    }

    /// Sets `results` for `text`: word matches at once (worked out off the
    /// main actor, so typing stays smooth), then the related titles after a
    /// pause, which only spares the model a reading per keystroke.
    public func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard let index, !query.isEmpty else {
            results = SearchResults()
            related = []
            return
        }
        let words = await Task.detached { index.wordMatches(query) }.value
        guard !Task.isCancelled else { return }
        results = words.adding(related: related, query: query)
        guard let meaning else { return }
        try? await Task.sleep(for: pause)
        guard !Task.isCancelled, let vectors = try? await meaning.model.vectors(for: query) else { return }
        let found = await Task.detached { meaning.index.related(to: vectors) }.value
        guard !Task.isCancelled else { return }
        related = found
        results = words.adding(related: found, query: query)
    }

    private func setIndex(_ built: SearchIndex) {
        indexSerial += 1
        index = built
        revision += 1
    }

    /// The index takes a moment on a big library: built off the main actor, as searches are.
    private static func build(_ items: [Item], keywords: KeywordStore) async -> SearchIndex {
        await Task.detached { SearchIndex(items: items, keywords: keywords) }.value
    }
}
