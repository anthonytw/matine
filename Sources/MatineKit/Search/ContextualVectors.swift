#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// Apple's on-device contextual embedding for Latin-script languages: one
/// multilingual model for Spanish and English (and others) together, so
/// words of both languages land in the same space. Nothing leaves the
/// device. The model is a system download: `make()` asks for it and is nil
/// until the device has it (Search then matches words only).
public actor ContextualVectors: TokenVectors {
    private let embedding: NLContextualEmbedding
    public nonisolated let modelIdentifier: String

    private init(embedding: NLContextualEmbedding) {
        self.embedding = embedding
        modelIdentifier = "\(embedding.modelIdentifier)#\(embedding.revision)"
    }

    /// The model, ready to use; nil when this device can't have it or
    /// doesn't have it yet. Never waits on the download: the first ask
    /// starts it, and each later ask (each visit to Search) checks again,
    /// so a model that arrives while the app sits suspended is picked up
    /// without a relaunch.
    public static func make() async -> ContextualVectors? { await Loader.shared.model() }

    private actor Loader {
        static let shared = Loader()
        private var ready: ContextualVectors?
        private var downloading = false

        func model() -> ContextualVectors? {
            if let ready { return ready }
            guard let embedding = NLContextualEmbedding(script: .latin),
                  embedding.languages.contains(.spanish), embedding.languages.contains(.english)
            else { return nil }
            guard embedding.hasAvailableAssets else {
                if !downloading {
                    downloading = true
                    // Done or failed, a later ask may try again.
                    embedding.requestAssets { _, _ in Task { await Loader.shared.finished() } }
                }
                return nil
            }
            guard (try? embedding.load()) != nil else { return nil }
            ready = ContextualVectors(embedding: embedding)
            return ready
        }

        private func finished() { downloading = false }
    }

    public func vectors(for text: String) throws -> [TokenVector] {
        let result = try embedding.embeddingResult(for: text, language: nil)
        var tokens: [TokenVector] = []
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { values, range in
            let vector = values.map(Float.init)
            let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if length > 0 { tokens.append(TokenVector(token: String(text[range]), vector: vector.map { $0 / length })) }
            return true
        }
        return tokens
    }
}
#endif
