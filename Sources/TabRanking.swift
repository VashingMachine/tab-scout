import Foundation

/// The signals that place an open tab in the results. Every value lies between 0 and 1;
/// `lexical` is the text-match tier divided by 100 and is 0 for empty input.
enum RankingSignal: Int, CaseIterable {
    case lexical, usage, recency, affinity, dwell, related, transition, timeOfDay, semantic, content, assistant

    var name: String { String(describing: self) }
}

struct RankingFeatures: Equatable {
    private(set) var values = [Double](repeating: 0, count: RankingSignal.allCases.count)

    subscript(signal: RankingSignal) -> Double {
        get { values[signal.rawValue] }
        set { values[signal.rawValue] = min(1, max(0, newValue.isFinite ? newValue : 0)) }
    }
}

/// Points awarded per signal. Typed queries keep match quality dominant: usage and recency together
/// can reorder neighbouring match tiers but never lift a weak match over a strong one. Only a page chosen
/// repeatedly for the same text can: affinity is the user's own answer to what the text means.
/// Empty input has no match quality, so what you looked at recently decides.
struct RankingWeights: Equatable {
    var typed: [Double]
    var empty: [Double]

    static let standard = RankingWeights(
        typed: weights([.lexical: 100, .usage: 4, .recency: 4, .affinity: 100, .dwell: 3, .related: 5,
                        .transition: 3, .timeOfDay: 2, .semantic: 40, .content: 45, .assistant: 200]),
        empty: weights([.usage: 4, .recency: 20, .dwell: 6, .related: 18, .transition: 10, .timeOfDay: 6]))

    static func weights(_ points: [RankingSignal: Double]) -> [Double] {
        RankingSignal.allCases.map { points[$0] ?? 0 }
    }

    func score(_ features: RankingFeatures, typed: Bool) -> Double {
        zip(typed ? self.typed : empty, features.values).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

struct RankingContext {
    /// Open tabs in the order they were last on screen, most recent first.
    var focusOrder: [SafariTab] = []
    var activeTab: SafariTab?
    /// How strongly the typed text led to each normalized URL before, from `QueryAffinity`.
    var affinity: [String: Double] = [:]
    /// How long each open tab was read, from `Engagement`.
    var dwell: [SafariTab: Double] = [:]
    /// How closely each open tab relates to the one on screen, from `RelatedTabs`.
    var related: [SafariTab: Double] = [:]
    /// How likely each open tab's site follows the site on screen, from `Habits`.
    var transition: [SafariTab: Double] = [:]
    /// How much each open tab's site belongs to this hour of the week, from `Habits`.
    var timeOfDay: [SafariTab: Double] = [:]
    /// Tabs found by meaning rather than text, from `SemanticSearch`. They rank below every text match.
    var semantic: [SafariTab: Double] = [:]
    /// Tabs whose page text contains the typed words, from `PageTextIndex`. They also rank below text matches.
    var content: [SafariTab: Double] = [:]
    /// Tabs the on-device model picked for a "?" request, from `TabAssistant`: 1 for its first pick, less after.
    var assistant: [SafariTab: Double] = [:]
    var weights = RankingWeights.standard
}

struct RankedTab: Equatable {
    let tab: SafariTab
    let features: RankingFeatures
    let score: Double
}

enum QueryIntent {
    private static let questionWords: Set<String> = [
        "how", "what", "why", "when", "where", "who", "which", "is", "are", "can", "does", "do", "should",
        "could", "would", "will", "jak", "co", "czy", "dlaczego", "kiedy", "gdzie", "kto", "ile", "ktory", "ktora"
    ]

    /// Questions and phrases of four or more words read as something to search for, not a tab to find.
    static func isQuestion(_ query: String) -> Bool {
        let words = HistoryIdentity.query(query).split(separator: " ")
        guard words.count >= 2 else { return false }
        return query.hasSuffix("?") || words.count >= 4 || questionWords.contains(String(words[0]))
    }
}

enum TabRanker {
    /// The weakest match that can be the Enter default: every query word found as typed.
    static let confidentMatch = 0.6
    /// A page chosen once for this text is enough to be the Enter default.
    static let confidentAffinity = 0.45
    /// Open tabs that only learned text points to need at least this much affinity to be listed.
    static let listedAffinity = 0.2

    static func isConfident(_ features: RankingFeatures) -> Bool {
        features[.lexical] >= confidentMatch || features[.affinity] >= confidentAffinity || features[.assistant] > 0
    }

    /// Whether Enter should search or open the typed text instead of switching to the best tab.
    static func prefersTyped(query: String, best: RankedTab?, context: RankingContext) -> Bool {
        guard let best, !query.isEmpty else { return false }
        if !isConfident(best.features) { return true }
        let learned = best.features[.affinity]
        if best.features[.assistant] > 0 { return false }
        // Having chosen a new tab for this text before outweighs a weaker memory of any tab.
        if (context.affinity[QueryAffinity.newTab] ?? 0) >= max(confidentAffinity, learned + 0.01) { return true }
        // A question is only a tab when the page title holds the whole phrase or it was chosen for it before.
        return QueryIntent.isQuestion(query) && best.features[.lexical] < 0.8 && learned < confidentAffinity
    }

    /// A tab viewed `rank` switches ago; the previous tab has rank 0.
    static func recency(rank: Int) -> Double { exp(-Double(rank) / 4) }

    static func rank(typed: Bool, matches: [TabSearchIndex.Match], allTabs: [SafariTab] = [],
                     history: HistorySearchIndex, context: RankingContext, now: Date) -> [RankedTab] {
        var recencyRank: [SafariTab: Int] = [:]
        for tab in context.focusOrder where tab != context.activeTab && recencyRank[tab] == nil {
            recencyRank[tab] = recencyRank.count
        }
        var candidates = matches
        var listed = Set(matches.map(\.tab))
        if typed && !context.affinity.isEmpty {
            // Text chosen for a page before finds it even when its title and address do not contain it.
            candidates += allTabs.filter { tab in
                !listed.contains(tab) && (HistoryIdentity.url(tab.url).flatMap { context.affinity[$0] } ?? 0) >= listedAffinity
            }.map { TabSearchIndex.Match(tab: $0, relevance: 0) }
            listed.formUnion(candidates.map(\.tab))
        }
        if typed && !(context.semantic.isEmpty && context.content.isEmpty && context.assistant.isEmpty) {
            candidates += allTabs.filter {
                !listed.contains($0) && (context.semantic[$0] != nil || context.content[$0] != nil || context.assistant[$0] != nil)
            }.map { TabSearchIndex.Match(tab: $0, relevance: 0) }
        }
        let ranked = candidates.map { match -> RankedTab in
            var features = RankingFeatures()
            features[.lexical] = Double(match.relevance) / 100
            features[.usage] = history.usageScore(url: match.tab.url, now: now) / 60
            features[.recency] = recencyRank[match.tab].map { recency(rank: $0) } ?? 0
            features[.dwell] = context.dwell[match.tab] ?? 0
            features[.related] = context.related[match.tab] ?? 0
            features[.transition] = context.transition[match.tab] ?? 0
            features[.timeOfDay] = context.timeOfDay[match.tab] ?? 0
            features[.semantic] = context.semantic[match.tab] ?? 0
            features[.content] = context.content[match.tab] ?? 0
            features[.assistant] = context.assistant[match.tab] ?? 0
            if !context.affinity.isEmpty {
                features[.affinity] = HistoryIdentity.url(match.tab.url).flatMap { context.affinity[$0] } ?? 0
            }
            return RankedTab(tab: match.tab, features: features, score: context.weights.score(features, typed: typed))
        }
        // Equal scores keep the order the matches arrived in.
        return ranked.indices.sorted { a, b in
            ranked[a].score == ranked[b].score ? a < b : ranked[a].score > ranked[b].score
        }.map { ranked[$0] }
    }
}
