import Foundation

/// One word of a text as an on-device language model reads it: the word,
/// and a unit-length vector for what it means in that sentence.
public struct TokenVector: Sendable, Equatable {
    public var token: String
    public var vector: [Float]

    public init(token: String, vector: [Float]) {
        self.token = token
        self.vector = vector
    }
}

/// An on-device model that turns text into per-word vectors where words
/// close in meaning sit close together, across languages ("snake" near
/// "serpiente" and "víbora"). Apple's NaturalLanguage provides one
/// (`ContextualVectors`); tests use a fake.
public protocol TokenVectors: Sendable {
    /// Names the model and its revision: vectors from different models
    /// don't compare, so cached ones are dropped when it changes.
    var modelIdentifier: String { get }
    func vectors(for text: String) async throws -> [TokenVector]
}

/// A title's word vectors, kept small: one flat run of bytes, each component
/// of a unit-length vector rounded to 1/127 (a dot product of two such vectors
/// is within about 0.01 of the exact one, far inside the z-score margin
/// `MeaningIndex` asks for). A 512-wide float vector per word, as its own
/// array, was some 80 to 160 KB a title; this is a quarter of the bytes per
/// word, with no per-word allocation, and at most `maxTokens` words.
public struct PackedVectors: Sendable, Equatable {
    /// The most words kept for a title: its name comes first, then the opening
    /// of its synopsis, so the cut falls on the synopsis.
    public static let maxTokens = 32
    static let scale: Float = 127

    public let dimension: Int
    public private(set) var bytes: [Int8]

    public var count: Int { dimension > 0 ? bytes.count / dimension : 0 }
    public var isEmpty: Bool { count == 0 }

    public init(_ vectors: [[Float]]) {
        let kept = vectors.filter { !$0.isEmpty }.prefix(Self.maxTokens)
        dimension = kept.first?.count ?? 0
        var out: [Int8] = []
        out.reserveCapacity(kept.count * dimension)
        for vector in kept {
            for index in 0..<dimension {
                let value = index < vector.count ? vector[index] : 0
                out.append(Int8(max(-127, min(127, (value * Self.scale).rounded()))))
            }
        }
        bytes = out
    }

    /// From a cache file: `bytes` is whole vectors of `dimension`.
    init?(dimension: Int, bytes: [Int8]) {
        guard dimension >= 0, bytes.isEmpty || (dimension > 0 && bytes.count % dimension == 0) else { return nil }
        self.dimension = dimension
        self.bytes = bytes
    }

    /// The vectors back as floats (tests, and nothing hot).
    var rows: [[Float]] {
        (0..<count).map { row in bytes[(row * dimension)..<((row + 1) * dimension)].map { Float($0) / Self.scale } }
    }

    /// The largest dot product between `word` and any vector held (-1 when none).
    func closest(to word: [Float]) -> Float {
        let width = min(dimension, word.count)
        guard width > 0 else { return -1 }
        return bytes.withUnsafeBufferPointer { held in
            word.withUnsafeBufferPointer { query in
                var best: Float = -1
                for row in 0..<count {
                    let base = row * dimension
                    var sum: Float = 0
                    for index in 0..<width { sum += Float(held[base + index]) * query[index] }
                    best = max(best, sum / Self.scale)
                }
                return best
            }
        }
    }
}

/// Titles related to a search by meaning rather than by its words: every
/// title's name and synopsis, read once by the on-device model, compared
/// word by word with the query. A title scores the mean, over the query's
/// words, of its closest word; it counts as related when it stands well
/// clear of the rest of the catalog for that query (a z-score), so no
/// absolute threshold has to suit every model and query.
public struct MeaningIndex: Sendable {
    public static let limit = 12
    /// Standard deviations above the catalog's mean score.
    static let clearance: Float = 2.5

    let entries: [(item: Item, vectors: PackedVectors)]

    init(entries: [(item: Item, vectors: PackedVectors)]) {
        self.entries = entries.filter { !$0.vectors.isEmpty }
    }

    /// What the model reads for a title: its tidy name (no file-name prefix,
    /// which would tie every episode to its show) and the start of its
    /// synopsis (the opening says what it's about).
    static func text(_ item: Item) -> String {
        guard let overview = item.overview, !overview.isEmpty else { return item.displayName }
        return item.displayName + ". " + String(overview.prefix(400))
    }

    /// Vectors worth comparing: function words ("el", "the") and stray
    /// letters match everything a little and would blur every score.
    static func meaningful(_ tokens: [TokenVector]) -> [[Float]] {
        tokens.filter { token in
            let folded = SearchText.fold(token.token)
            return folded.count >= 2 && !SearchText.stopwords.contains(folded) && folded.contains(where: \.isLetter)
        }
        .map(\.vector)
    }

    /// Reads every title through `model`, reusing `cache`'s vectors for
    /// titles whose text hasn't changed. Titles it can't read are left out.
    public static func build(items: [Item], model: any TokenVectors, cache: MeaningCache? = nil) async -> MeaningIndex {
        var stored = cache?.load(model: model.modelIdentifier) ?? [:]
        var fresh: [String: PackedVectors] = [:]
        var reads = 0
        var entries: [(Item, PackedVectors)] = []
        for item in items where SearchIndex.group(item.kind) != nil {
            if Task.isCancelled { break }
            let text = text(item)
            let key = "\(item.id)|\(StableHash.fnv1a(text))"
            let vectors: PackedVectors
            if let known = stored.removeValue(forKey: key) {
                vectors = known
            } else if let read = try? await model.vectors(for: text) {
                vectors = PackedVectors(meaningful(read))
                reads += 1
            } else {
                continue
            }
            fresh[key] = vectors
            entries.append((item, vectors))
        }
        // A full reading keeps only what the catalog still holds; one cut
        // short keeps everything, so the next carries on where it stopped.
        // Nothing read and nothing gone: the file already says this.
        if Task.isCancelled {
            if reads > 0 { cache?.save(fresh.merging(stored) { new, _ in new }, model: model.modelIdentifier) }
        } else if reads > 0 || !stored.isEmpty {
            cache?.save(fresh, model: model.modelIdentifier)
        }
        return MeaningIndex(entries: entries)
    }

    /// Titles about what `query` means, most related first.
    public func related(to query: [TokenVector]) -> [Item] {
        let words = Self.meaningful(query)
        guard !words.isEmpty, entries.count >= 4 else { return [] }
        let scores = entries.map { entry in
            words.reduce(Float(0)) { sum, word in
                sum + entry.vectors.closest(to: word)
            } / Float(words.count)
        }
        let mean = scores.reduce(0, +) / Float(scores.count)
        let spread = (scores.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(scores.count)).squareRoot()
        guard spread > 1e-4 else { return [] }
        return zip(entries, scores)
            .filter { ($0.1 - mean) / spread >= Self.clearance }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.limit)
            .map(\.0.item)
    }
}

/// The model's reading of each title, kept on disk between launches (in
/// Caches: the system may clear it, and it's rebuilt). Keyed by item and a
/// hash of its text, so an edited synopsis is read again.
public struct MeaningCache: Sendable {
    let url: URL

    public init(url: URL) { self.url = url }

    /// Where a profile's reading lives in `caches`. The name is a hash of the
    /// account id, never the id itself: the id comes from the server, and a
    /// hostile one ("../x") must not choose where a file is written.
    public static func url(accountId: String, in caches: URL) -> URL {
        caches.appending(path: Self.prefix + Self.hex(StableHash.fnv1a(accountId)) + ".bin")
    }

    private static let prefix = "search-meaning-"

    /// Sixteen lowercase hex digits.
    static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    /// Deletes what earlier versions left in `caches`: files named after the raw
    /// account id (anything that isn't the 16-hex form) and float-format (MTV1)
    /// files. Hashed names are never rebuilt from an id here.
    public static func removeLegacy(in caches: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: caches.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".bin") {
            let stem = name.dropFirst(prefix.count).dropLast(4)
            let hashed = stem.count == 16 && stem.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            let file = caches.appending(path: name)
            if hashed {
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let head = (try? handle.read(upToCount: 4)) ?? Data()
                try? handle.close()
                if head != Data("MTV1".utf8) { continue }
            }
            try? fileManager.removeItem(at: file)
        }
    }

    /// Once per launch, the first time a cache is asked for.
    private static let cleaned: Void = {
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first { removeLegacy(in: caches) }
    }()

    /// The cache for a profile in the system's Caches folder, if there is one.
    public static func standard(accountId: String) -> MeaningCache? {
        _ = cleaned
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            .map { MeaningCache(url: url(accountId: accountId, in: $0)) }
    }

    /// Deletes a profile's reading (sign-out).
    public static func remove(accountId: String) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: url(accountId: accountId, in: caches))
    }

    // MTV2: Int8 vectors (MTV1 held floats, and is dropped and rebuilt).
    private static let magic = Data("MTV2".utf8)

    func load(model: String) -> [String: PackedVectors]? {
        // Mapped, so a big file is paged in as it is read rather than copied whole.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.starts(with: Self.magic) else { return nil }
        var reader = Reader(data: data, offset: Self.magic.count)
        // Every count is checked against the bytes left, so a damaged file is
        // dropped (and rebuilt) rather than read past or looped over.
        guard reader.string() == model, let count = reader.int(), count <= reader.remaining / 12 else { return nil }
        var table: [String: PackedVectors] = [:]
        for _ in 0..<count {
            guard let key = reader.string(), let tokens = reader.int(), let dimension = reader.int(),
                  tokens == 0 || (dimension > 0 && tokens <= PackedVectors.maxTokens && tokens * dimension <= reader.remaining),
                  let bytes = reader.bytes(tokens * dimension),
                  let vectors = PackedVectors(dimension: tokens == 0 ? 0 : dimension, bytes: bytes.map { Int8(bitPattern: $0) })
            else { return nil }
            table[key] = vectors
        }
        return table
    }

    /// Written as a stream to a side file, then moved over the old one: the
    /// whole table is never held a second time as one `Data`.
    func save(_ table: [String: PackedVectors], model: String) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let side = url.appendingPathExtension("tmp")
        fileManager.createFile(atPath: side.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: side) else { return }
        defer { try? fileManager.removeItem(at: side) }
        var ok = true
        var buffer = Self.magic
        func flush(force: Bool = false) {
            guard force || buffer.count >= 1 << 20 else { return }
            do { try handle.write(contentsOf: buffer) } catch { ok = false }
            buffer.removeAll(keepingCapacity: true)
        }
        Self.put(model, &buffer)
        Self.put(table.count, &buffer)
        for (key, vectors) in table {
            Self.put(key, &buffer)
            Self.put(vectors.count, &buffer)
            Self.put(vectors.dimension, &buffer)
            vectors.bytes.withUnsafeBytes { buffer.append(contentsOf: $0) }
            flush()
        }
        flush(force: true)
        do { try handle.close() } catch { ok = false }
        // A failed write (disk full) must not replace the good file.
        if ok { _ = try? fileManager.replaceItemAt(url, withItemAt: side) }
    }

    private static func put(_ value: Int, _ data: inout Data) {
        withUnsafeBytes(of: UInt32(clamping: value).littleEndian) { data.append(contentsOf: $0) }
    }

    private static func put(_ text: String, _ data: inout Data) {
        let bytes = Data(text.utf8)
        put(bytes.count, &data)
        data.append(bytes)
    }

    private struct Reader {
        let data: Data
        var offset: Int
        var remaining: Int { data.count - offset }

        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            let start = data.startIndex + offset
            return Array(data[start..<(start + count)])
        }

        mutating func int() -> Int? {
            bytes(4).map { Int(UInt32(littleEndian: $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })) }
        }

        mutating func string() -> String? {
            int().flatMap { bytes($0) }.flatMap { String(bytes: $0, encoding: .utf8) }
        }
    }
}
