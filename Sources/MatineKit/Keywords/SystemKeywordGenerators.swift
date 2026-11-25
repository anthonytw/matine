// The on-device generators. macOS and iOS only: tvOS has neither framework,
// so the TV reads the keywords an iPhone or Mac made (see `KeywordStore`).
#if canImport(FoundationModels) && !os(tvOS)
import CryptoKit
import Foundation
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
@Generable
struct GeneratedKeywords {
    @Guide(description: "Spanish search words for this title: nouns, themes, animals, places and characters it is about. Lowercase, one or two words each.", .maximumCount(6))
    var spanish: [String]
    @Guide(description: "The same ideas as English search words. Lowercase, one or two words each.", .maximumCount(6))
    var english: [String]
}

/// Keywords from Apple's on-device language model: a few nouns and themes
/// per title in Spanish and English, so "dog" finds a film about a "perro".
@available(macOS 26.0, iOS 26.0, *)
public struct ModelKeywordGenerator: KeywordGenerator {
    static let instructions = """
        You write search keywords for a family video library. Given a title's details, answer with \
        at most 6 Spanish and 6 English words (12 in all) that someone might type to find it: \
        the main nouns, animals, things, places, themes and characters, each idea in both languages. \
        Lowercase. No spoilers, no plot twists. Never real people's names (actors, directors). \
        Never the title's own words.
        """

    /// Bump when the instructions change: entries of an older version are redone,
    /// newer ones are kept (two builds never redo each other's). The hash only
    /// tells editions apart (a forgotten bump shows as a new identifier).
    static let version = 1

    public let identifier = "foundation-models/v\(ModelKeywordGenerator.version)-" + SHA256.hash(data: Data(ModelKeywordGenerator.instructions.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()

    public init() {}

    /// Nil when the model can be used, else exactly why not.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "SystemLanguageModel unavailable: deviceNotEligible (this device can't run Apple Intelligence)"
        case .unavailable(.appleIntelligenceNotEnabled): "SystemLanguageModel unavailable: appleIntelligenceNotEnabled (turn on Apple Intelligence in Settings)"
        case .unavailable(.modelNotReady): "SystemLanguageModel unavailable: modelNotReady (still downloading, or the assets service isn't running)"
        case .unavailable(let other): "SystemLanguageModel unavailable: \(other)"
        }
    }

    public func checkAvailable() async throws {
        if let reason = Self.unavailableReason { throw KeywordsUnavailable(reason) }
    }

    public func keywords(for source: KeywordSource) async throws -> [String] {
        try await checkAvailable()
        // A fresh session per title: no history to carry over or to fill the context.
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(to: String(source.text.prefix(1200)), generating: GeneratedKeywords.self)
        return response.content.spanish + response.content.english
    }
}
#endif

#if canImport(Translation) && canImport(NaturalLanguage) && !os(tvOS)
import Foundation
import NaturalLanguage
import Translation

/// Keywords by translation: the title, genres and tags in the other of
/// Spanish and English. Plain and literal ("Perro valiente" gives "brave
/// dog"), but it needs only the Translation models, not Apple Intelligence.
/// The language packs must already be installed (Settings, Translation
/// Languages): it never asks for a download, which takes a view.
@available(macOS 26.0, iOS 26.0, *)
public actor TranslationKeywordGenerator: KeywordGenerator {
    public nonisolated let identifier = "translation/2"
    /// Used when a text's language can't be told (a bare title).
    public nonisolated let defaultLanguage: String
    /// A session is not Sendable; each is only used by this actor, one call at a time.
    private final class Box: @unchecked Sendable {
        let session: TranslationSession
        init(_ session: TranslationSession) { self.session = session }
    }
    private var sessions: [String: Box] = [:]

    public init(defaultLanguage: String = "es") { self.defaultLanguage = defaultLanguage }

    /// The recognizer's guesses among Spanish and English.
    public static func hypotheses(_ text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.spanish, .english]
        recognizer.processString(text)
        var out: [String: Double] = [:]
        for (language, p) in recognizer.languageHypotheses(withMaximum: 2) { out[language.rawValue] = p }
        return out
    }

    /// Checks both directions are installed; the system call never returns
    /// on a seat without its daemon, so it is raced against a timeout.
    public func checkAvailable() async throws {
        for (from, to) in [("es", "en"), ("en", "es")] {
            let status = await withTimeout(10) {
                await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
            }
            guard let status else { throw KeywordsUnavailable("Translation \(from) to \(to): the translation service didn't answer in 10 s (is translationd running in this session?)") }
            guard status == .installed else {
                throw KeywordsUnavailable("Translation \(from) to \(to) is \(status == .supported ? "not downloaded (add it in Settings, Translation Languages)" : "unsupported")")
            }
        }
    }

    private func session(_ from: String, _ to: String) -> Box {
        if let existing = sessions[from + to] { return existing }
        let made = Box(TranslationSession(installedSource: Locale.Language(identifier: from), target: Locale.Language(identifier: to)))
        sessions[from + to] = made
        return made
    }

    public func keywords(for source: KeywordSource) async throws -> [String] {
        let itemLanguage = KeywordLanguage.ofItem(source, hypotheses: Self.hypotheses, fallback: defaultLanguage)
        var pieces = [source.name] + source.genres + source.tags
        if let original = source.originalTitle, original != source.name { pieces.append(original) }
        // Each piece in its own direction: a Spanish title carries English genres.
        var byLanguage: [String: [String]] = [:]
        for piece in pieces {
            byLanguage[KeywordLanguage.pick(Self.hypotheses(piece), fallback: itemLanguage), default: []].append(piece)
        }
        var words: [String] = []
        for (from, texts) in byLanguage.sorted(by: { $0.key < $1.key }) {
            let to = from == "es" ? "en" : "es"
            let responses = try await session(from, to).session.translations(from: texts.map { TranslationSession.Request(sourceText: $0) })
            for response in responses { words.append(contentsOf: SearchText.words(response.targetText)) }
        }
        return words
    }
}
#endif
