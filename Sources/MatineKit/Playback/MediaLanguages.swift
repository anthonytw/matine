import Foundation

/// Which audio and subtitle track a profile starts on, for files the player
/// opens directly. (Server HLS follows the user's server-side preferences.)
public enum MediaLanguages {
    /// A track language as a two-letter code: "spa" and "es-MX" both give "es".
    public static func code(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        let base = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lower
        let threeLetter = ["spa": "es", "esl": "es", "eng": "en"]
        return threeLetter[base] ?? base
    }

    public struct Choice: Sendable, Hashable {
        /// Index into the audio tracks offered, nil to leave the file's own default.
        public var audio: Int?
        /// Index into the subtitle tracks, nil for none.
        public var subtitle: Int?
    }

    /// The first audio track in the most preferred language available. If the
    /// audio is in a known language other than the profile's first, the
    /// profile's subtitles are turned on when the file has them (English film,
    /// Spanish profile: Spanish subtitles); otherwise subtitles stay as they
    /// are. Audio of unknown language ("und", untagged: typical of downloaded
    /// videos, often already in the household's language) never triggers them.
    public static func choose(preferred: [String], audio: [String?], subtitles: [String?]) -> Choice {
        let audio = audio.map(code), subtitles = subtitles.map(code)
        guard let first = preferred.first else { return Choice(audio: nil, subtitle: nil) }
        let pickedAudio = preferred.lazy.compactMap { language in audio.firstIndex { $0 == language } }.first
        guard let pickedAudio, let heard = audio[pickedAudio] else { return Choice(audio: nil, subtitle: nil) }
        guard heard != first else { return Choice(audio: pickedAudio, subtitle: nil) }
        return Choice(audio: pickedAudio, subtitle: subtitles.firstIndex { $0 == first })
    }
}
