import CryptoKit
import Foundation

/// What a keyword generator reads about one title: the text that decides
/// its keywords, and a hash of it. Keywords made from this text stay good
/// until the hash changes, so a library is only ever re-read when an item's
/// text did.
public struct KeywordSource: Sendable, Equatable {
    public var id: String
    public var name: String
    public var originalTitle: String?
    public var overview: String?
    public var genres: [String]
    public var tags: [String]
    /// An episode's series: "Capítulo 3" alone tells the model nothing.
    public var seriesName: String?

    public init(item: Item) {
        id = item.id
        name = item.displayName
        seriesName = item.kind == .episode ? item.seriesName : nil
        originalTitle = item.originalTitle
        overview = item.overview
        genres = item.genres ?? []
        tags = item.tags ?? []
    }

    public init(id: String, name: String, originalTitle: String? = nil, overview: String? = nil, genres: [String] = [], tags: [String] = [], seriesName: String? = nil) {
        self.seriesName = seriesName
        self.id = id
        self.name = name
        self.originalTitle = originalTitle
        self.overview = overview
        self.genres = genres
        self.tags = tags
    }

    /// The field values alone, no labels: what a keyword is compared with.
    public var fieldValues: [String] {
        [name, originalTitle ?? "", overview ?? "", seriesName ?? ""] + genres + tags
    }

    /// The fields, labelled, one per line: what the model is shown, and what is hashed.
    public var text: String {
        var lines = ["name: \(name)"]
        if let originalTitle, originalTitle != name { lines.append("original title: \(originalTitle)") }
        // Only present on episodes, so films' text (and hash) is unchanged.
        if let seriesName, !seriesName.isEmpty { lines.append("series: \(seriesName)") }
        if !genres.isEmpty { lines.append("genres: \(genres.joined(separator: ", "))") }
        if !tags.isEmpty { lines.append("tags: \(tags.joined(separator: ", "))") }
        if let overview, !overview.isEmpty { lines.append("synopsis: \(overview)") }
        return lines.joined(separator: "\n")
    }

    /// SHA-256 of `text`, as the first 8 bytes in hex: plenty to notice an
    /// edit, and a quarter the size of the whole digest in every record.
    public var hash: String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// The extra search words for one item, in both languages, and what they
/// were made from.
public struct ItemKeywords: Codable, Sendable, Equatable {
    /// Lowercase words, English and Spanish together.
    public var words: [String]
    /// `KeywordSource.hash` when they were made.
    public var sourceHash: String
    /// Seconds since 1970 when they were made.
    public var made: Int
    /// The generator and its instructions' version (`KeywordGenerator.identifier`):
    /// switching generator or editing the prompt makes entries stale.
    public var generation: String
    /// Set on an entry a fallback generator made because the better one
    /// refused the item or wasn't there: the better generator's identifier
    /// when it was tried. The entry is kept (not retried on every run) until
    /// that generator's identifier changes (a new model or new instructions).
    public var retryAfter: String?

    public init(words: [String], sourceHash: String, made: Int, generation: String = "", retryAfter: String? = nil) {
        self.words = words
        self.sourceHash = sourceHash
        self.made = made
        self.generation = generation
        self.retryAfter = retryAfter
    }

    // Short keys: the store holds thousands of these, and CloudKit later.
    enum CodingKeys: String, CodingKey { case words = "w", sourceHash = "h", made = "t", generation = "g", retryAfter = "r" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = try c.decode([String].self, forKey: .words)
        sourceHash = try c.decode(String.self, forKey: .sourceHash)
        made = try c.decode(Int.self, forKey: .made)
        generation = try c.decodeIfPresent(String.self, forKey: .generation) ?? ""
        retryAfter = try c.decodeIfPresent(String.self, forKey: .retryAfter)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(words, forKey: .words)
        try c.encode(sourceHash, forKey: .sourceHash)
        try c.encode(made, forKey: .made)
        if !generation.isEmpty { try c.encode(generation, forKey: .generation) }
        try c.encodeIfPresent(retryAfter, forKey: .retryAfter)
    }

    /// How good the generator that made this is (`KeywordGenerations.rank`).
    public var rank: Int { KeywordGenerations.rank(of: generation) }

    /// True when this entry should replace `other` for the same item:
    /// - `currentHash` (the item's text now), when known, decides first: the
    ///   entry made from the current text beats one made from older text;
    /// - the same text: a better generator beats a worse one (a model entry
    ///   is never replaced by a fallback one), the same rank goes to the newer;
    /// - changed text, neither matching: the newer.
    /// A tie is false: the one already held stays.
    public func wins(over other: ItemKeywords, currentHash: String? = nil) -> Bool {
        if let currentHash {
            let (mine, theirs) = (sourceHash == currentHash, other.sourceHash == currentHash)
            if mine != theirs { return mine }
        }
        if sourceHash == other.sourceHash {
            if rank != other.rank { return rank > other.rank }
            let (mine, theirs) = (KeywordGenerations.version(of: generation), KeywordGenerations.version(of: other.generation))
            if KeywordGenerations.family(of: generation) == KeywordGenerations.family(of: other.generation), mine != theirs { return mine > theirs }
        }
        return made > other.made
    }
}

/// The generators by name, and which is better. An entry made by a better
/// generator is kept when a worse one is run (`matine keywords --generator
/// translate` leaves the model's entries alone).
public enum KeywordGenerations {
    /// Apple's language model 2, translation 1, anything else (and entries
    /// from before generators were named) 0.
    public static func rank(of identifier: String) -> Int {
        if identifier.hasPrefix("foundation-models/") { return 2 }
        if identifier.hasPrefix("translation/") { return 1 }
        return 0
    }

    /// The generator without its version: "translation/2" is "translation".
    public static func family(of identifier: String) -> String {
        identifier.split(separator: "/", maxSplits: 1).first.map(String.init) ?? identifier
    }

    /// The generator's ordered version, bumped by hand when its instructions
    /// or method change: "foundation-models/v2-1a2b3c4d" is 2 (the hash only
    /// tells the editions apart), "translation/2" is 2. Without a number
    /// (the model's identifiers before versions existed) it is 1. Ordered, so
    /// two builds with different prompts never redo each other's entries
    /// back and forth: only an older version is redone.
    public static func version(of identifier: String) -> Int {
        let tail = identifier.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let digits: (String) -> Int? = { Int($0.prefix { $0.isNumber }) }
        if tail.hasPrefix("v"), let n = digits(String(tail.dropFirst())) { return n }
        if family(of: identifier) == "translation", let n = digits(tail) { return n }
        return 1
    }
}

/// Keywords by item id: a small JSON file (about 100 bytes an item), later
/// one CloudKit record per entry.
public struct KeywordStore: Codable, Sendable, Equatable {
    /// The file layout. A reader refuses a newer one rather than misread it.
    public static let schemaVersion = 1
    /// The most words kept for one item.
    public static let maxWords = 12

    public private(set) var entries: [String: ItemKeywords]

    public init(entries: [String: ItemKeywords] = [:]) { self.entries = entries.mapValues(Self.clamped) }

    public var count: Int { entries.count }

    enum CodingKeys: String, CodingKey { case version = "v", entries = "e" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version <= Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "keywords schema \(version) is newer than this app reads (\(Self.schemaVersion))")
        }
        entries = try c.decode([String: ItemKeywords].self, forKey: .entries).mapValues(Self.clamped)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .version)
        try c.encode(entries, forKey: .entries)
    }

    static func clamped(_ keywords: ItemKeywords) -> ItemKeywords {
        var keywords = keywords
        keywords.words = Array(keywords.words.prefix(maxWords))
        return keywords
    }

    public func keywords(for id: String) -> ItemKeywords? { entries[id] }

    /// Keeps the entry, clamped to `maxWords`.
    public mutating func set(_ id: String, _ keywords: ItemKeywords) {
        entries[id] = Self.clamped(keywords)
    }

    /// True when the item has keywords made from its current text that a run
    /// of `generation` (a generator's identifier; nil: any) needn't redo:
    /// - made by that generator at that version or a newer one, or by a
    ///   better generator (never redo a model entry because translation was
    ///   asked for);
    /// - a fallback entry (`retryAfter`) stays until a newer version of the
    ///   generator that refused it exists, then it is retried;
    /// - an older version of the same generator, or a worse or unrelated
    ///   one, is redone.
    public func isFresh(_ item: Item, generation: String? = nil) -> Bool {
        guard let entry = entries[item.id], entry.sourceHash == KeywordSource(item: item).hash else { return false }
        guard let generation else { return true }
        if entry.generation == generation { return true }
        let family = KeywordGenerations.family(of: generation)
        let wanted = KeywordGenerations.version(of: generation)
        // Same generator: only an older version is redone (a newer build's entry stays).
        if KeywordGenerations.family(of: entry.generation) == family { return KeywordGenerations.version(of: entry.generation) >= wanted }
        // A fallback entry waits for a newer version of the generator that refused it.
        if let retry = entry.retryAfter, KeywordGenerations.family(of: retry) == family { return KeywordGenerations.version(of: retry) >= wanted }
        return entry.rank > KeywordGenerations.rank(of: generation)
    }

    /// The items with no keywords yet, or keywords made from older text or
    /// by another generator.
    public func stale(in items: [Item], generation: String? = nil) -> [Item] {
        items.filter { !isFresh($0, generation: generation) }
    }

    /// Merges `other` in. Per item: when `currentHashes` (item id to current
    /// `KeywordSource.hash`) says which record matches the item's text now,
    /// that one wins, so a newer record made from old text can't beat a
    /// matching one; for the same text a better generator wins (a model entry
    /// never gives way to a fallback one); otherwise the newer `made` wins
    /// (this store's on a tie; see `ItemKeywords.wins`). Entries only
    /// `other` has are added.
    public mutating func merge(_ other: KeywordStore, currentHashes: [String: String] = [:]) {
        for (id, theirs) in other.entries {
            guard let mine = entries[id] else { entries[id] = Self.clamped(theirs); continue }
            if theirs.wins(over: mine, currentHash: currentHashes[id]) { entries[id] = Self.clamped(theirs) }
        }
    }

    /// Drops entries for items no longer in the library. There are no
    /// tombstones: a merge brings a pruned entry back from any store that
    /// still has it, so a CloudKit design must delete records explicitly.
    /// Prune only against the whole catalog (`KeywordBuilder.mayPrune`).
    public mutating func prune(keeping ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public init(data: Data) throws { self = try JSONDecoder().decode(KeywordStore.self, from: data) }
}

/// Picking Spanish or English for a piece of text, from a recognizer's
/// guesses (the seam: tests pass their own).
public enum KeywordLanguage {
    /// "es" or "en" when one is at least 60% likely, else `fallback`.
    public static func pick(_ hypotheses: [String: Double], fallback: String) -> String {
        let best = ["es", "en"].map { ($0, hypotheses[$0] ?? 0) }.max { $0.1 < $1.1 }!
        return best.1 >= 0.6 ? best.0 : fallback
    }

    /// The item's own language from its name and synopsis (no labels, which are English).
    public static func ofItem(_ source: KeywordSource, hypotheses: (String) -> [String: Double], fallback: String) -> String {
        pick(hypotheses([source.name, source.overview ?? ""].joined(separator: ". ")), fallback: fallback)
    }
}

/// `operation`'s result, or nil if it hasn't finished in `seconds` or the
/// caller is cancelled. The operation isn't waited for after that: some
/// system calls never return on a seat without their daemon. Whichever
/// side loses is cancelled.
public func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let once = Once<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.install(continuation)
            once.track(Task { once.resume(await operation()) })
            once.track(Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(nil)
            })
        }
    } onCancel: {
        once.resume(nil)
    }
}

private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var finished = false

    func install(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(returning: nil)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }

    func resume(_ value: T?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let (c, losers) = (continuation, tasks)
        continuation = nil
        tasks = []
        lock.unlock()
        c?.resume(returning: value)
        losers.forEach { $0.cancel() }
    }
}
