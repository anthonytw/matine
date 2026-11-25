import Foundation

/// How Search reads text: case, accents and width folded away ("Dragón" and
/// "dragon" are one word), split into words, with small Spanish and English
/// function words set aside and plurals matched to singulars.
enum SearchText {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func words(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The words of a text as Search indexes it: `words`, plus each
    /// hyphenated or apostrophed word written as one ("Spider-Man" is also
    /// "spiderman"), so either spelling finds it.
    static func terms(_ text: String) -> [Term] {
        let folded = fold(text)
        var terms = words(folded).map(Term.init)
        for chunk in folded.split(whereSeparator: \.isWhitespace) {
            let parts = words(String(chunk))
            if parts.count > 1 { terms.append(Term(parts.joined())) }
        }
        return terms
    }

    /// Words too common to narrow anything down, in both languages (folded).
    static let stopwords: Set<String> = [
        "el", "la", "los", "las", "un", "una", "unos", "unas", "de", "del", "y", "e", "o", "u", "en", "a", "al",
        "con", "por", "para", "su", "sus", "mi", "que", "se", "lo", "le",
        "the", "an", "of", "and", "or", "in", "on", "to", "for", "with", "his", "her", "its", "my",
    ]

    /// The words of a query that carry meaning; all of them if every word is
    /// a function word (someone searching "el").
    static func queryWords(_ text: String) -> [Term] {
        let all = words(text)
        let content = all.filter { !stopwords.contains($0) }
        return (content.isEmpty ? all : content).map(Term.init)
    }

    /// A word, ready to compare: its letters (as bytes: folded text is
    /// nearly all ASCII) and the singulars it could be the plural of.
    struct Term: Sendable {
        let text: String
        let bytes: [UInt8]
        /// The word and its possible singulars: "leones" → leon(e)s, leone,
        /// leon; "peces" → pez; "dragons" → dragon. Two words are the same
        /// word in the plural when these meet.
        let forms: Set<String>

        init(_ text: String) {
            self.text = text
            bytes = Array(text.utf8)
            forms = SearchText.forms(text)
        }
    }

    static func forms(_ word: String) -> Set<String> {
        var forms: Set<String> = [word]
        guard word.hasSuffix("s") else { return forms }
        // "-s" off any plural; "-es" off too only where it is one ("leones",
        // not "hanks", whose "-ks" would otherwise leave "han").
        var candidates = [String(word.dropLast())]
        if word.hasSuffix("es") { candidates.append(String(word.dropLast(2))) }
        for singular in candidates where singular.count >= 3 {
            forms.insert(singular)
        }
        if word.hasSuffix("ces"), word.count > 4 { forms.insert(String(word.dropLast(3)) + "z") }
        return forms
    }

    /// How well a query word matches a word of the text: 1 for the same word,
    /// 0.8 for the start of it (typing "gall" finds "gallinita") or the same
    /// word in the plural, 0.5 for one typo in a longer word (where `typos`
    /// allows: in a title, not a synopsis, whose many words would each be
    /// one typo from something), 0 for none.
    static func match(_ query: Term, _ word: Term, typos: Bool = true) -> Double {
        if word.text == query.text { return 1 }
        if word.text.hasPrefix(query.text) || !query.forms.isDisjoint(with: word.forms) { return 0.8 }
        if typos, query.bytes.count >= 5, word.bytes.count >= 5 {
            if oneEditApart(query.bytes[...], word.bytes[...])
                || (word.bytes.count > query.bytes.count && oneEditApart(query.bytes[...], word.bytes.prefix(query.bytes.count))) {
                return 0.5
            }
        }
        return 0
    }

    static func match(_ query: String, _ word: String, typos: Bool = true) -> Double {
        match(Term(query), Term(word), typos: typos)
    }

    /// True when one insertion, deletion, substitution or swap of neighbors
    /// turns `a` into `b` (or they're equal).
    static func oneEditApart(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Bool {
        if abs(a.count - b.count) > 1 { return false }
        var i = a.startIndex, j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] { i += 1; j += 1 }
        if i == a.endIndex, j == b.endIndex { return true }
        if a.count == b.count {
            // Substitution, or two neighbors swapped.
            if a[(i + 1)...].elementsEqual(b[(j + 1)...]) { return true }
            return i + 1 < a.endIndex && a[i] == b[j + 1] && a[i + 1] == b[j] && a[(i + 2)...].elementsEqual(b[(j + 2)...])
        }
        // Insertion or deletion: skip one letter of the longer.
        return a.count > b.count ? a[(i + 1)...].elementsEqual(b[j...]) : a[i...].elementsEqual(b[(j + 1)...])
    }
}
