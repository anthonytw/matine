import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Why keywords can't be made here (no model, not downloaded, Apple
/// Intelligence off): stops a whole run, unlike one item's failure.
public struct KeywordsUnavailable: Error, CustomStringConvertible, Sendable, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Makes the extra search words, in both languages, for one title. The
/// implementations use on-device models and exist on macOS and iOS only
/// (tvOS has neither FoundationModels nor Translation); tests use a fake.
public protocol KeywordGenerator: Sendable {
    /// Names the generator and the version of its instructions; stored with
    /// each entry, so changing either makes old entries stale.
    var identifier: String { get }
    /// Throws `KeywordsUnavailable`, with the reason, if keywords can't be
    /// made at all here. Called once before a run; it must not hang.
    func checkAvailable() async throws
    /// Raw words; `KeywordWords.clean` tidies them. Throws `KeywordsUnavailable`
    /// when the model isn't there.
    func keywords(for source: KeywordSource) async throws -> [String]
}

extension KeywordGenerator {
    public func checkAvailable() async throws {}
}

public enum KeywordWords {
    /// The folded words the name tagger finds as people in the item's own
    /// text (real sentences, original casing: the tagger can't judge a bare
    /// lowercase keyword, and calls plain Spanish pairs like "perro valiente"
    /// names). A keyword containing one is dropped: the prompt only asks the
    /// model not to name actors.
    public static func personNames(in source: KeywordSource) -> Set<String> {
        #if canImport(NaturalLanguage)
        var names = Set<String>()
        for text in [source.name, source.originalTitle ?? "", source.overview ?? ""] where !text.isEmpty {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
                if tag == .personalName { names.formUnion(SearchText.words(String(text[range]))) }
                return true
            }
        }
        return names
        #else
        return []
        #endif
    }

    /// Lowercase, trimmed, one to three words each, no duplicates, none of
    /// function words, none made only of words the title's own fields
    /// already spell (Search finds those anyway), none containing a person's
    /// name from the item's text (`personNames`; pass your own, or nil to
    /// find them), at most `KeywordStore.maxWords`.
    public static func clean(_ raw: [String], source: KeywordSource? = nil, personNames: Set<String>? = nil) -> [String] {
        let known = Set(source.map { $0.fieldValues.flatMap(SearchText.words) } ?? [])
        let names = personNames ?? source.map(Self.personNames(in:)) ?? []
        var seen = Set<String>()
        var out: [String] = []
        for word in raw {
            let trimmed = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let folded = SearchText.words(trimmed)
            guard !folded.isEmpty, folded.count <= 3, trimmed.count <= 32 else { continue }
            let key = folded.joined(separator: " ")
            guard seen.insert(key).inserted else { continue }
            if folded.allSatisfy(known.contains) { continue }
            if folded.count == 1, SearchText.stopwords.contains(key) { continue }
            if folded.contains(where: names.contains) { continue }
            out.append(trimmed)
            if out.count == KeywordStore.maxWords { break }
        }
        return out
    }
}

/// Which items get keywords, and the run that fills a store.
public struct KeywordBuilder: Sendable {
    public struct Report: Sendable {
        public var generated = 0
        /// How many of `generated` came from the fallback generator.
        public var fellBack = 0
        public var failed: [(id: String, message: String)] = []
        /// Items asked about whose new entry lost to a better one already held
        /// (a fallback never replaces a model's entry made from the same text).
        /// Nothing is stored for them, so a caller that loops on `limit` must
        /// not ask for them again, or it would stop on the same item forever.
        public var skipped: [String] = []
    }

    public let generator: any KeywordGenerator
    /// Makes the words for an item the generator refuses (the model's
    /// guardrails call some synopses unsafe) or when it isn't there. Its
    /// entries are marked to be retried with `generator` once that changes.
    public let fallback: (any KeywordGenerator)?
    public let now: @Sendable () -> Date

    public init(generator: any KeywordGenerator, fallback: (any KeywordGenerator)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.generator = generator
        self.fallback = fallback
        self.now = now
    }

    /// Everything someone can pick to watch, episodes included: in a
    /// library of read-aloud stories almost every title is an episode, and
    /// "dog" must find "Willi, el perro casi verde". Seasons and folders
    /// are only containers.
    public static func wantsKeywords(_ item: Item) -> Bool {
        switch item.kind {
        case .movie, .series, .video, .episode: true
        default: false
        }
    }

    /// Pruning removes entries for items not in `items`, so it is only right
    /// when asked for (`--prune`, from a profile that sees every library: a
    /// kid profile's catalog lacks what it can't see) and `items` is the
    /// whole catalog: not one library, and not a catalog that hit the fetch
    /// limit (items beyond it would be lost).
    public static func mayPrune(requested: Bool, library: String?, catalogCount: Int, catalogLimit: Int = 20_000) -> Bool {
        requested && library == nil && catalogCount < catalogLimit
    }

    /// Makes keywords for the items that need them (none, changed text, an
    /// older version of this generator or a worse one; all with `force`), at
    /// most `limit` of them. Entries a better generator made from the same
    /// text are kept. One item's failure is reported and skipped (after
    /// trying `fallback`); `KeywordsUnavailable` ends the run and is thrown,
    /// unless there is a `fallback` that is itself available: then the rest
    /// of the run uses it. Cancellation ends the run too. `each` hears every
    /// item as it is done; `checkpoint` gets the store every
    /// `checkpointEvery` items (0: never) and on the way out of a throw, so a
    /// long run is never lost whole.
    public func fill(
        _ store: inout KeywordStore, items: [Item], force: Bool = false, limit: Int? = nil,
        checkpointEvery: Int = 25, checkpoint: (KeywordStore) -> Void = { _ in },
        each: (Item, ItemKeywords) -> Void = { _, _ in }
    ) async throws -> Report {
        let wanted = items.filter(Self.wantsKeywords)
        var todo = force ? wanted : store.stale(in: wanted, generation: generator.identifier)
        // Films, series and videos first (few, and the most searched), then episodes.
        todo = todo.enumerated().sorted { (SearchIndex.rank($0.element.kind), $0.offset) < (SearchIndex.rank($1.element.kind), $1.offset) }.map(\.element)
        if let limit { todo = Array(todo.prefix(limit)) }
        var report = Report()
        // The fallback is only used if it can work at all.
        var fallbackReady = false
        if let fallback { fallbackReady = (try? await fallback.checkAvailable()) != nil }
        var primaryGone = false
        if fallbackReady { primaryGone = (try? await generator.checkAvailable()) == nil }
        do {
            for item in todo {
                try Task.checkCancellation()
                let source = KeywordSource(item: item)
                var words: [String]?
                var usedFallback = false
                if !primaryGone {
                    do {
                        words = try await generator.keywords(for: source)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as KeywordsUnavailable {
                        guard fallbackReady else { throw error }
                        primaryGone = true
                    } catch {
                        if !fallbackReady { report.failed.append((item.id, "\(error)")); continue }
                    }
                }
                if words == nil, let fallback, fallbackReady {
                    do {
                        words = try await fallback.keywords(for: source)
                        usedFallback = true
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        report.failed.append((item.id, "\(error)"))
                        continue
                    }
                }
                guard let words else { continue }
                let by = usedFallback ? fallback!.identifier : generator.identifier
                let keywords = ItemKeywords(
                    words: KeywordWords.clean(words, source: source), sourceHash: source.hash,
                    made: Int(now().timeIntervalSince1970), generation: by, retryAfter: usedFallback ? generator.identifier : nil
                )
                // A fallback never replaces what a better generator made from the same text.
                if usedFallback, let held = store.keywords(for: item.id), !keywords.wins(over: held) {
                    report.skipped.append(item.id)
                    continue
                }
                store.set(item.id, keywords)
                report.generated += 1
                if usedFallback { report.fellBack += 1 }
                each(item, keywords)
                if checkpointEvery > 0, report.generated % checkpointEvery == 0 { checkpoint(store) }
            }
        } catch {
            checkpoint(store)
            throw error
        }
        return report
    }
}
