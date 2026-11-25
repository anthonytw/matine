import Foundation

/// What Search shows: matches grouped by kind (the TV app's layout), each
/// group best first, groups in order of their best match; then titles
/// related by meaning, which match no word typed but the same idea.
public struct SearchResults: Sendable, Equatable {
    public enum Group: Sendable, Hashable {
        case movies, series, episodes, videos
        /// About the same thing, in either language (see `MeaningIndex`).
        case related
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var group: Group
        public var items: [Item]
        public var id: Group { group }
    }

    /// Why a result matched when its title doesn't say: someone in it, a
    /// character, or its studio. Keyed by item id; only for shown items.
    public enum Reason: Sendable, Hashable {
        case person(String)
        /// A character, and who plays them.
        case character(String, actor: String)
        case studio(String)

        /// The line a result shows under its caption.
        public var text: String {
            switch self {
            case .person(let name): name
            case .character(let role, let actor): "\(role) · \(actor)"
            case .studio(let name): name
            }
        }
    }

    public var sections: [Section]
    public var reasons: [String: Reason]
    public var isEmpty: Bool { sections.isEmpty }

    public init(sections: [Section] = [], reasons: [String: Reason] = [:]) {
        self.sections = sections
        self.reasons = reasons
    }
}

/// The profile's whole catalog, read once and searched on the device: no
/// round trip per keystroke, and matching that Jellyfin's name-only search
/// can't do. Every title, original title, synopsis, genre and tag is
/// searched, ignoring case and accents, matching word starts, plurals and
/// single typos.
public struct SearchIndex: Sendable {
    /// Per group, a row's worth; the rest is a more precise search away.
    public static let groupLimit = 30

    struct Entry: Sendable {
        let item: Item
        /// The words of each field, with its weight (a title outranks a
        /// synopsis) and whether a typo still finds them (titles only).
        let fields: [(weight: Double, terms: [SearchText.Term], typos: Bool)]
        /// The name's words, spaced: the whole query is looked for in it.
        let foldedName: String
        /// Each credited person's name, spaced: a query that is a whole name.
        let foldedPeople: [String]
        /// Each credited person on their own (name words, character words):
        /// a query naming someone must be satisfied by one of them, not by
        /// "Nico" in one name and "Varela" in another.
        let persons: [(name: [SearchText.Term], role: [SearchText.Term])]
    }

    enum Weight {
        static let name = 10.0, originalTitle = 8.0, tags = 6.0, people = 5.5, characters = 5.5, genres = 4.0, keywords = 3.0, overview = 2.0
        static let studios = 1.5
    }

    let entries: [Entry]
    public var items: [Item] { entries.map(\.item) }

    /// `keywords` (see `KeywordStore`) add each item's extra words in both
    /// languages. Stale ones (the item's text changed since) still count: they
    /// describe what the title is about, which rarely moves, and a missing
    /// word costs more than a slightly old one, at a weight below titles,
    /// tags and genres.
    /// A keyword on more than this share of the items that have keywords
    /// ("familia", "aventura") says nothing about any one of them and would
    /// flood every search for it: it is ignored. Only judged once there are
    /// `frequencyMinimum` such items.
    ///
    /// Guards against judging too early (a partial run whose first titles
    /// share a theme): nothing is dropped until `frequencyMinimum` titles
    /// and half of those that could have keywords have them, nor a word on
    /// fewer than `frequentFloor` titles. A long series repeating its theme
    /// on every episode can still push that word over the share for the
    /// whole library; judging episode words against their own series is the
    /// follow-up if a library shows it.
    static let frequentShare = 0.12
    static let frequencyMinimum = 25
    static let frequentFloor = 8

    /// A keyword as compared for frequency: folded, each word in the
    /// singular ("perros" and "perro" are one, as are "leones" and "león").
    static func frequencyKey(_ keyword: String) -> String {
        SearchText.words(keyword).map(singular).joined(separator: " ")
    }

    /// The usual Spanish and English plural endings undone: "-ces" → "-z",
    /// "-es" after a consonant (leones, flores, foxes), else "-s" (perros,
    /// casas, trees). A guess, but the same guess for both forms of a word.
    static func singular(_ word: String) -> String {
        let letters = Array(word)
        guard letters.count > 3, letters.last == "s" else { return word }
        if word.hasSuffix("ces"), letters.count > 4 { return String(letters.dropLast(3)) + "z" }
        if word.hasSuffix("es"), letters.count > 4, !"aeiou".contains(letters[letters.count - 3]) {
            return String(letters.dropLast(2))
        }
        return String(letters.dropLast())
    }

    /// The keywords (as `frequencyKey`) too common to index.
    static func frequentKeywords(items: [Item], keywords: KeywordStore?) -> Set<String> {
        guard let keywords else { return [] }
        // Over the items that have keywords: titles still waiting for theirs
        // would otherwise water the share down.
        let wanted = items.filter(KeywordBuilder.wantsKeywords)
        let eligible = wanted.filter { keywords.keywords(for: $0.id) != nil }
        guard eligible.count >= frequencyMinimum, eligible.count * 2 >= wanted.count else { return [] }
        var counts: [String: Int] = [:]
        for item in eligible {
            for key in Set((keywords.keywords(for: item.id)?.words ?? []).map(frequencyKey)) { counts[key, default: 0] += 1 }
        }
        let limit = Double(eligible.count) * frequentShare
        return Set(counts.filter { Double($0.value) > limit && $0.value >= frequentFloor }.keys)
    }

    public init(items: [Item], keywords: KeywordStore? = nil) {
        let frequent = Self.frequentKeywords(items: items, keywords: keywords)
        // Jellyfin lists a series' regulars on every one of its episodes:
        // an episode keeps only who the series doesn't have (guest stars)
        // or its own crew, so a search for a regular finds the series once.
        var seriesPeople: [String: Set<String>] = [:]
        for item in items where item.kind == .series { seriesPeople[item.id] = Set((item.people ?? []).map(\.id)) }
        entries = items.compactMap { original in
            let group = Self.group(original.kind)
            guard group != nil else { return nil }
            var item = original
            if item.kind == .episode, let regulars = item.seriesId.flatMap({ seriesPeople[$0] }) {
                // Only actors: a guest star the series lists too (TMDB does) stays on her episode.
                item.people = item.people?.filter { $0.kind != .actor || !regulars.contains($0.id) }
            }
            // The tidy name: a file-name prefix ("Show S01E05 - ") would make
            // every episode match the show's words.
            var fields: [(Double, [SearchText.Term], Bool)] = [(Weight.name, SearchText.terms(item.displayName), true)]
            if let original = item.originalTitle, original != item.name { fields.append((Weight.originalTitle, SearchText.terms(original), true)) }
            if let tags = item.tags, !tags.isEmpty { fields.append((Weight.tags, SearchText.terms(tags.joined(separator: " ")), true)) }
            if let genres = item.genres, !genres.isEmpty { fields.append((Weight.genres, SearchText.terms(genres.joined(separator: " ")), false)) }
            // Typos off: generated words, many per item, would each sit one typo from something.
            if let extra = keywords?.keywords(for: item.id)?.words.filter({ !frequent.contains(Self.frequencyKey($0)) }), !extra.isEmpty {
                fields.append((Weight.keywords, SearchText.terms(extra.joined(separator: " ")), false))
            }
            // Actors, directors and guest stars by name and the characters
            // they play (no typos: common first names would flood); the studio, low.
            let credited = Self.credits(item)
            if let studios = item.studios, !studios.isEmpty {
                fields.append((Weight.studios, SearchText.terms(studios.joined(separator: " ")), false))
            }
            if let overview = item.overview { fields.append((Weight.overview, SearchText.terms(overview), false)) }
            return Entry(item: item, fields: fields, foldedName: SearchText.words(item.displayName).joined(separator: " "),
                         foldedPeople: credited.map { SearchText.words($0.name).joined(separator: " ") },
                         persons: credited.map { (SearchText.terms($0.name), SearchText.terms($0.role ?? "")) })
        }
    }

    /// The credits Search indexes.
    static func credits(_ item: Item) -> [Person] {
        (item.people ?? []).filter(\.isSearched)
    }

    /// Why `item` matched `query` when its title doesn't: the credit or
    /// studio that does. Nil when the title (or anything else) explains it.
    public static func reason(for item: Item, query: String) -> SearchResults.Reason? {
        let words = SearchText.queryWords(query)
        guard !words.isEmpty else { return nil }
        // Titles and tags forgive a typo; credits and studios don't (as in `score`).
        let titleTerms = SearchText.terms(([item.displayName, item.originalTitle].compactMap { $0 } + (item.tags ?? [])).joined(separator: " "))
        if words.allSatisfy({ word in titleTerms.contains { SearchText.match(word, $0, typos: true) > 0 } }) { return nil }
        func hits(_ text: String) -> Bool {
            let terms = SearchText.terms(text)
            return words.contains { word in terms.contains { SearchText.match(word, $0, typos: false) > 0 } }
        }
        let credited = credits(item)
        if let person = credited.first(where: { hits($0.name) }) { return .person(person.name) }
        if let person = credited.first(where: { $0.role.map(hits) ?? false }), let role = person.role {
            return .character(role, actor: person.name)
        }
        if let studio = item.studios?.first(where: hits) { return .studio(studio) }
        return nil
    }

    static func group(_ kind: ItemKind) -> SearchResults.Group? {
        switch kind {
        case .movie: .movies
        case .series: .series
        case .episode: .episodes
        case .video: .videos
        default: nil
        }
    }

    static func rank(_ kind: ItemKind) -> Int {
        switch kind {
        case .movie: 0
        case .series: 1
        case .video: 2
        default: 3
        }
    }

    /// The best one person's score for all of `words` (their name or the
    /// character they play, no typos), 0 when nobody matches every word.
    static func personScore(_ entry: Entry, _ words: [SearchText.Term]) -> Double {
        var bestPerson = 0.0
        for person in entry.persons {
            var sum = 0.0
            for word in words {
                var best = 0.0
                for candidate in person.name { best = max(best, Weight.people * SearchText.match(word, candidate, typos: false)) }
                for candidate in person.role { best = max(best, Weight.characters * SearchText.match(word, candidate, typos: false)) }
                if best == 0 { sum = 0; break }
                sum += best
            }
            bestPerson = max(bestPerson, sum)
        }
        return bestPerson
    }

    /// How well an entry matches, 0 for not at all: every meaningful word of
    /// the query must match somewhere.
    static func score(_ entry: Entry, words: [SearchText.Term], phrase: String) -> Double {
        var total = 0.0
        var viaCredits: [SearchText.Term] = []
        // A word only a synopsis, genre, keyword or studio has: too weak to
        // pair with a word found through a person.
        var hasWeakWord = false
        for word in words {
            var best = 0.0, strong = 0.0
            for field in entry.fields {
                for candidate in field.terms {
                    let quality = SearchText.match(word, candidate, typos: field.typos)
                    if quality > 0 {
                        best = max(best, field.weight * quality)
                        if field.weight >= Weight.tags { strong = max(strong, field.weight * quality) }
                    }
                }
            }
            if best == 0 { viaCredits.append(word) } else { total += best }
            if best > 0, strong == 0 { hasWeakWord = true }
        }
        // What no other field has must all be in ONE person's name or
        // character; and a person matching every word outright beats a
        // weaker field matching some of them (a synopsis naming "Ferrán"
        // must not outrank the character).
        var mixed = total
        if !viaCredits.isEmpty {
            let person = personScore(entry, viaCredits)
            // The other words must be title, original title or tags, or be this person's too.
            mixed = person > 0 && !hasWeakWord ? total + person : 0
        }
        total = max(mixed, personScore(entry, words))
        if total == 0 { return 0 }
        // The whole query at the start of the title, or inside it, first.
        if phrase.count >= 3 {
            if entry.foldedName.hasPrefix(phrase) { total += 8 } else if entry.foldedName.contains(phrase) { total += 5 }
            // A whole person's name ("nico varela") outweighs two stray words.
            else if phrase.contains(" "), entry.foldedPeople.contains(where: { $0.contains(phrase) }) { total += 4 }
        }
        return total
    }

    /// Word matches, scored, best first (ties: films and shows first, then by name).
    func scored(_ query: String) -> [(entry: Entry, score: Double)] {
        let words = SearchText.queryWords(query)
        guard !words.isEmpty else { return [] }
        let phrase = SearchText.words(query).joined(separator: " ")
        return entries
            .compactMap { entry in
                let score = Self.score(entry, words: words, phrase: phrase)
                return score > 0 ? (entry, score) : nil
            }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                // Even matches: a whole film or show before one episode.
                let ranks = (Self.rank(a.entry.item.kind), Self.rank(b.entry.item.kind))
                if ranks.0 != ranks.1 { return ranks.0 < ranks.1 }
                return a.entry.item.displayName < b.entry.item.displayName
            }
    }

    /// The results for `query`; `related` are the meaning matches (from
    /// `MeaningIndex`), shown after the word matches without repeating any.
    public func search(_ query: String, related: [Item] = []) -> SearchResults {
        wordMatches(query).adding(related: related, query: query)
    }

    /// The word matches alone, grouped. Meaning matches come later, with
    /// `SearchResults.adding(related:query:)`, without scoring the catalog again.
    public func wordMatches(_ query: String) -> SearchResults {
        let matches = scored(query)
        var sections: [SearchResults.Section] = []
        for (entry, _) in matches {
            let group = Self.group(entry.item.kind)!
            if let index = sections.firstIndex(where: { $0.group == group }) {
                if sections[index].items.count < Self.groupLimit { sections[index].items.append(entry.item) }
            } else {
                sections.append(.init(group: group, items: [entry.item]))
            }
        }
        // `matches` is best first, so sections already are in order of their best.
        var reasons: [String: SearchResults.Reason] = [:]
        for item in sections.flatMap(\.items) {
            if let reason = Self.reason(for: item, query: query) { reasons[item.id] = reason }
        }
        return SearchResults(sections: sections, reasons: reasons)
    }
}

extension SearchResults {
    /// These results with `related` (meaning matches) after them, leaving out
    /// any title already shown. A related section already here is replaced.
    public func adding(related: [Item], query: String) -> SearchResults {
        var sections = self.sections.filter { $0.group != .related }
        var reasons = self.reasons
        let shown = Set(sections.flatMap(\.items).map(\.id))
        let extra = related.filter { !shown.contains($0.id) }.prefix(SearchIndex.groupLimit)
        if !extra.isEmpty { sections.append(.init(group: .related, items: Array(extra))) }
        for item in extra where reasons[item.id] == nil {
            if let reason = SearchIndex.reason(for: item, query: query) { reasons[item.id] = reason }
        }
        let all = Set(sections.flatMap(\.items).map(\.id))
        return SearchResults(sections: sections, reasons: reasons.filter { all.contains($0.key) })
    }
}
