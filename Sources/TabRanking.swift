import Foundation

/// The signals that place an open tab in the results. Every value lies between 0 and 1;
/// `lexical` is the text-match tier divided by 100 and is 0 for empty input.
enum RankingSignal: Int, CaseIterable {
    case lexical, usage, recency

    var name: String { String(describing: self) }
}

struct RankingFeatures: Equatable {
    private(set) var values = [Double](repeating: 0, count: RankingSignal.allCases.count)

    subscript(signal: RankingSignal) -> Double {
        get { values[signal.rawValue] }
        set { values[signal.rawValue] = min(1, max(0, newValue.isFinite ? newValue : 0)) }
    }
}

/// Points awarded per signal. Typed queries keep match quality dominant: the other signals together
/// can reorder neighbouring match tiers but never lift a weak match over a strong one.
/// Empty input has no match quality, so what you looked at recently decides.
struct RankingWeights: Equatable {
    var typed: [Double]
    var empty: [Double]

    static let standard = RankingWeights(
        typed: weights([.lexical: 100, .usage: 4, .recency: 4]),
        empty: weights([.usage: 4, .recency: 20]))

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
    var weights = RankingWeights.standard
}

struct RankedTab: Equatable {
    let tab: SafariTab
    let features: RankingFeatures
    let score: Double
}

enum TabRanker {
    /// The weakest match that can be the Enter default: every query word found as typed.
    static let confidentMatch = 0.6

    /// A tab viewed `rank` switches ago; the previous tab has rank 0.
    static func recency(rank: Int) -> Double { exp(-Double(rank) / 4) }

    static func rank(typed: Bool, matches: [TabSearchIndex.Match], history: HistorySearchIndex,
                     context: RankingContext, now: Date) -> [RankedTab] {
        var recencyRank: [SafariTab: Int] = [:]
        for tab in context.focusOrder where tab != context.activeTab && recencyRank[tab] == nil {
            recencyRank[tab] = recencyRank.count
        }
        let ranked = matches.map { match -> RankedTab in
            var features = RankingFeatures()
            features[.lexical] = Double(match.relevance) / 100
            features[.usage] = history.usageScore(url: match.tab.url, now: now) / 60
            features[.recency] = recencyRank[match.tab].map { recency(rank: $0) } ?? 0
            return RankedTab(tab: match.tab, features: features, score: context.weights.score(features, typed: typed))
        }
        // Equal scores keep the order the matches arrived in.
        return ranked.indices.sorted { a, b in
            ranked[a].score == ranked[b].score ? a < b : ranked[a].score > ranked[b].score
        }.map { ranked[$0] }
    }
}
