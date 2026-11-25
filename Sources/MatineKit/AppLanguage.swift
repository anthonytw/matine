import Foundation

/// The interface language of one profile. Independent of the Apple TV's own
/// language: each profile picks, Spanish by default.
public enum AppLanguage: String, Codable, Sendable {
    case spanish = "es-ES"
    case english = "en-US"

    public static let `default`: AppLanguage = .spanish

    /// Sent to Jellyfin so server-side text (genre names, errors) follows the profile.
    public var acceptLanguage: String {
        switch self {
        case .spanish: "es-ES,es;q=0.9"
        case .english: "en-US,en;q=0.9"
        }
    }

    public var locale: Locale { Locale(identifier: rawValue) }

    /// The language a SwiftUI view is showing, from its `\.locale` (the apps set it
    /// to the profile's `locale`): English for an English locale, else Spanish.
    public init(locale: Locale) {
        self = locale.language.languageCode == .english ? .english : .spanish
    }

    /// A season's short label: "T1" (temporada) in Spanish, "S1" in English.
    public func seasonLabel(_ number: Int) -> String {
        switch self {
        case .spanish: "T\(number)"
        case .english: "S\(number)"
        }
    }

    /// Spoken and subtitle languages to prefer, best first (ISO 639-1): the
    /// profile's own, then the other one the household uses.
    public var mediaLanguages: [String] {
        switch self {
        case .spanish: ["es", "en"]
        case .english: ["en", "es"]
        }
    }
}
