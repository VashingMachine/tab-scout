import Foundation

/// Remembers what was typed before each choice, so the same letters lead to the same page next time,
/// even when the page title never contained them. Firefox calls this adaptive history.
struct QueryAffinity: Codable, Equatable {
    struct Choice: Codable, Equatable {
        let input: String
        /// A normalized page URL, or `QueryAffinity.search` for choosing to search the typed text.
        let target: String
        var weight: Double
        var lastUsed: Date
    }

    /// The target recorded when typed text was searched although open tabs were offered first.
    static let search = "tabscout:search"
    static let limit = 500
    static let halfLife: TimeInterval = 30 * 24 * 60 * 60

    private(set) var choices: [Choice] = []

    static func input(_ text: String) -> String { HistoryIdentity.query(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    static func decayed(_ choice: Choice, now: Date) -> Double {
        choice.weight * pow(0.5, max(0, now.timeIntervalSince(choice.lastUsed)) / halfLife)
    }

    mutating func record(input text: String, target: String, at now: Date) {
        let input = Self.input(text)
        guard !input.isEmpty, input.count <= 256, !target.isEmpty else { return }
        if let index = choices.firstIndex(where: { $0.input == input && $0.target == target }) {
            choices[index].weight = Self.decayed(choices[index], now: now) + 1
            choices[index].lastUsed = max(choices[index].lastUsed, now)
        } else {
            choices.append(Choice(input: input, target: target, weight: 1, lastUsed: now))
        }
        if choices.count > Self.limit {
            // The faintest memories go first.
            let keep = choices.indices.sorted { Self.decayed(choices[$0], now: now) > Self.decayed(choices[$1], now: now) }
                .prefix(Self.limit)
            choices = Set(keep).sorted().map { choices[$0] }
        }
    }

    /// How strongly each target was chosen for text like `query`, between 0 and 1. A target's share of the
    /// choices made for this text sets the ceiling, and repeated choices approach it: one choice gives about
    /// half, three about nine tenths.
    func strengths(for query: String, now: Date) -> [String: Double] {
        let query = Self.input(query)
        guard !query.isEmpty else { return [:] }
        var evidence: [String: Double] = [:]
        for choice in choices {
            // Typing the same text counts fully, a shorter start of it nearly so, and a longer version less.
            let closeness = choice.input == query ? 1
                : choice.input.hasPrefix(query) ? 0.8
                : query.hasPrefix(choice.input) && choice.input.count >= 2 ? 0.5 : 0
            guard closeness > 0 else { continue }
            evidence[choice.target, default: 0] += closeness * Self.decayed(choice, now: now)
        }
        let total = evidence.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return evidence.mapValues { $0 / total * (1 - exp(-$0 / 1.5)) }
    }
}
