import Foundation
import NaturalLanguage

/// Finds open tabs by meaning when few match the typed text: each typed word is widened to its nearest
/// words, so "email" finds an Inbox and "cooking" a recipe. Runs on this Mac with no download.
enum SemanticSearch {
    /// Semantic guesses only fill in when fewer tabs than this match the typed text.
    static let fewMatches = 3
    static let limit = 5

    /// Cosine distances run from about 0.6 for near synonyms to 1.05 for loosely related words.
    static func strength(distance: Double) -> Double { min(1, max(0, (1.05 - distance) / 0.45)) }

    static func matches(_ query: String, in index: TabSearchIndex, textMatches: Int,
                        neighbors: (String) -> [Neighbor]) -> [TabSearchIndex.SemanticMatch] {
        guard textMatches < fewMatches else { return [] }
        let text = TabSearch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return [] }
        let prepared = TextQuery(normalized: text)
        var expansions: [String: [Neighbor]] = [:]
        for token in prepared.tokens where token.count >= 3 && token.allSatisfy(\.isLetter) {
            let found = neighbors(token).filter { $0.strength > 0 && $0.word != token }
            if !found.isEmpty { expansions[token] = found }
        }
        guard !expansions.isEmpty else { return [] }
        return Array(index.semanticMatches(prepared, expansions: expansions).prefix(limit))
    }
}

// Main-thread owned; neighbours are cached because every keystroke asks again.
final class WordNeighbors {
    private lazy var embedding = NLEmbedding.wordEmbedding(for: .english)
    private var cache: [String: [Neighbor]] = [:]

    func callAsFunction(_ word: String) -> [Neighbor] {
        if let known = cache[word] { return known }
        guard let embedding, embedding.contains(word) else { cache[word] = []; return [] }
        let found = embedding.neighbors(for: word, maximumCount: 12, distanceType: .cosine).map {
            Neighbor(word: TabSearch.normalized($0.0), strength: SemanticSearch.strength(distance: $0.1))
        }
        if cache.count > 2_000 { cache.removeAll() }
        cache[word] = found
        return found
    }
}
