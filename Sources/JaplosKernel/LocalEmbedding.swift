import Foundation
import NaturalLanguage

/// Offline sentence embeddings via Apple's NaturalLanguage `NLEmbedding`.
/// No network / paid API. Falls back to nil when the language model isn't on-device.
public enum LocalEmbedding {
    public static var isAvailable: Bool {
        sentenceModel(for: .simplifiedChinese) != nil
            || sentenceModel(for: .english) != nil
            || sentenceModel(for: .traditionalChinese) != nil
    }

    public static var backendName: String {
        if sentenceModel(for: .simplifiedChinese) != nil { return "NLEmbedding.zh-Hans" }
        if sentenceModel(for: .traditionalChinese) != nil { return "NLEmbedding.zh-Hant" }
        if sentenceModel(for: .english) != nil { return "NLEmbedding.en" }
        return "unavailable"
    }

    /// `NLEmbedding` is not thread-safe: concurrent `vector(for:)` calls inside
    /// CoreNLP segfault. Serialise the computation behind one lock.
    private static let computeLock = NSLock()

    /// Returns a unit-ish vector for ranking, or nil if embeddings aren't available.
    public static func vector(for text: String) -> [Double]? {
        computeLock.lock()
        defer { computeLock.unlock() }
        return vectorLocked(for: text)
    }

    private static func vectorLocked(for text: String) -> [Double]? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clipped = String(trimmed.prefix(2_000))

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(clipped)
        let guessed = recognizer.dominantLanguage

        let order: [NLLanguage]
        if let guessed {
            order = [guessed, .simplifiedChinese, .traditionalChinese, .english]
        } else {
            order = [.simplifiedChinese, .traditionalChinese, .english]
        }

        var seen = Set<String>()
        for lang in order {
            let key = lang.rawValue
            if seen.contains(key) { continue }
            seen.insert(key)
            guard let model = sentenceModel(for: lang) else { continue }
            if let v = model.vector(for: clipped) {
                return v.map { Double($0) }
            }
            // NLEmbedding sometimes wants shorter phrases — try first sentence-ish chunk.
            let short = String(clipped.prefix(400))
            if short != clipped, let v = model.vector(for: short) {
                return v.map { Double($0) }
            }
        }
        return nil
    }

    public static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        guard denom > 1e-12 else { return 0 }
        return dot / denom
    }

    // Cache models — loading dictionaries is relatively expensive.
    private static let lock = NSLock()
    private static var cache: [String: NLEmbedding] = [:]

    private static func sentenceModel(for language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        let key = language.rawValue
        if let hit = cache[key] { return hit }
        guard let model = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        cache[key] = model
        return model
    }
}
