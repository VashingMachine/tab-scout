import Foundation

/// The tabs shown when one was picked: their signals in display order, by signal name, and which was chosen.
/// Holds numbers only, never titles or addresses.
struct RankingImpression: Codable, Equatable {
    let typed: Bool
    let candidates: [[String: Double]]
    let chosen: Int

    static let candidateLimit = 8

    /// Nil when the list cannot teach anything: fewer than two tabs, or a choice outside the list.
    init?(typed: Bool, shown: [RankingFeatures], chosen: Int) {
        guard shown.count >= 2, shown.indices.contains(chosen) else { return nil }
        // Keep the chosen tab and those around it, at most `candidateLimit`.
        let start = max(0, min(chosen - Self.candidateLimit / 2, shown.count - Self.candidateLimit))
        let kept = shown[start..<min(shown.count, start + Self.candidateLimit)]
        self.typed = typed
        candidates = kept.map { features in
            Dictionary(uniqueKeysWithValues: RankingSignal.allCases.compactMap { signal in
                let value = (features[signal] * 1_000).rounded() / 1_000
                return value == 0 ? nil : (signal.name, value)
            })
        }
        self.chosen = chosen - start
    }

    func vectors() -> [[Double]] {
        candidates.map { values in RankingSignal.allCases.map { values[$0.name] ?? 0 } }
    }
}

/// How often the picked tab was ranked first, and its mean reciprocal rank: 1 when always first, 0.5 when always second.
struct RankingQuality: Equatable {
    let picks: Int
    let firstChoice: Double
    let reciprocalRank: Double

    static let none = RankingQuality(picks: 0, firstChoice: 0, reciprocalRank: 0)
}

/// Recent picks, and the weights learned from them when they beat the standard ones.
struct RankingLog: Codable, Equatable {
    static let limit = 500
    /// Picks needed in a mode before its weights are learned.
    static let trainingMinimum = 30
    /// New picks between training runs.
    static let trainingInterval = 10

    private(set) var impressions: [RankingImpression] = []
    /// Learned points by mode ("typed", "empty") and signal name; missing signals keep the standard points.
    private(set) var learned: [String: [String: Double]] = [:]
    private(set) var sinceTraining = 0

    var needsTraining: Bool { sinceTraining >= Self.trainingInterval }
    var isPersonalized: Bool { !learned.isEmpty }

    mutating func record(_ impression: RankingImpression) {
        impressions.append(impression)
        if impressions.count > Self.limit { impressions.removeFirst(impressions.count - Self.limit) }
        sinceTraining += 1
    }

    mutating func adopt(_ weights: RankingWeights?) {
        sinceTraining = 0
        guard let weights else { learned = [:]; return }
        learned = [:]
        for typed in [true, false] where weights.points(typed: typed) != RankingWeights.standard.points(typed: typed) {
            learned[typed ? "typed" : "empty"] = Dictionary(uniqueKeysWithValues: RankingSignal.allCases.map {
                ($0.name, weights.points(typed: typed)[$0.rawValue])
            })
        }
    }

    var weights: RankingWeights {
        func merged(_ mode: String, _ standard: [Double]) -> [Double] {
            guard let points = learned[mode] else { return standard }
            return RankingSignal.allCases.map { points[$0.name] ?? standard[$0.rawValue] }
        }
        return RankingWeights(typed: merged("typed", RankingWeights.standard.typed),
                              empty: merged("empty", RankingWeights.standard.empty))
    }
}

enum RankTrainer {
    /// The signals each mode may learn. Match quality anchors the scale of typed results, and the
    /// on-device model's picks always lead, so neither is learned.
    static func learnable(typed: Bool) -> Set<RankingSignal> {
        typed ? [.usage, .recency, .affinity, .dwell, .related, .transition, .timeOfDay, .semantic, .content]
            : [.usage, .recency, .dwell, .related, .transition, .timeOfDay]
    }

    /// Re-ranks each logged list with `weights`. A tab scoring the same as the picked one counts as above it.
    static func evaluate(_ impressions: [RankingImpression], weights: RankingWeights) -> RankingQuality {
        guard !impressions.isEmpty else { return .none }
        var first = 0.0
        var reciprocal = 0.0
        for impression in impressions {
            let points = weights.points(typed: impression.typed)
            let scores = impression.vectors().map { zip(points, $0).reduce(0) { $0 + $1.0 * $1.1 } }
            let picked = scores[impression.chosen]
            let rank = 1 + scores.indices.filter { $0 != impression.chosen && scores[$0] >= picked }.count
            if rank == 1 { first += 1 }
            reciprocal += 1 / Double(rank)
        }
        let count = Double(impressions.count)
        return RankingQuality(picks: impressions.count, firstChoice: first / count, reciprocalRank: reciprocal / count)
    }

    /// Pairwise logistic regression: every picked tab should outscore every other tab shown with it.
    /// Weights are pulled towards the standard ones and kept between zero and three times their standard size.
    static func train(_ impressions: [RankingImpression], typed: Bool, from start: [Double],
                      iterations: Int = 400) -> [Double] {
        let mask = learnable(typed: typed)
        let standard = RankingWeights.standard.points(typed: typed)
        let ceilings = standard.map { max(3 * $0, 10) }
        var pairs: [[Double]] = []
        for impression in impressions where impression.typed == typed {
            let vectors = impression.vectors()
            for other in vectors.indices where other != impression.chosen {
                pairs.append(zip(vectors[impression.chosen], vectors[other]).map { $0 - $1 })
            }
        }
        guard !pairs.isEmpty else { return start }
        // A score gap of `temperature` points counts as a confident order.
        let temperature = 10.0
        let regularization = 0.002
        let rate = 40.0
        var weights = start
        for _ in 0..<iterations {
            var gradient = [Double](repeating: 0, count: weights.count)
            for difference in pairs {
                let margin = zip(weights, difference).reduce(0) { $0 + $1.0 * $1.1 } / temperature
                let pull = 1 / (1 + exp(margin)) / temperature
                for index in gradient.indices { gradient[index] -= pull * difference[index] }
            }
            for index in weights.indices where mask.contains(RankingSignal(rawValue: index)!) {
                let step = gradient[index] / Double(pairs.count) + regularization * (weights[index] - standard[index]) / 10
                weights[index] = min(ceilings[index], max(0, weights[index] - rate * step))
            }
        }
        return weights
    }

    /// Learns weights for each mode with enough picks and keeps them only when they rank the most recent
    /// fifth of picks, which training did not see, better than the standard weights. Nil when the standard
    /// weights should stay.
    static func improve(_ log: RankingLog) -> RankingWeights? {
        var result = RankingWeights.standard
        var changed = false
        for typed in [true, false] {
            let picks = log.impressions.filter { $0.typed == typed }
            guard picks.count >= RankingLog.trainingMinimum else { continue }
            let split = picks.count * 4 / 5
            let trial = train(Array(picks[..<split]), typed: typed, from: RankingWeights.standard.points(typed: typed))
            var candidate = RankingWeights.standard
            candidate.setPoints(trial, typed: typed)
            let recent = Array(picks[split...])
            let learned = evaluate(recent, weights: candidate)
            let standard = evaluate(recent, weights: .standard)
            guard learned.reciprocalRank > standard.reciprocalRank + 0.001 else { continue }
            result.setPoints(train(picks, typed: typed, from: trial), typed: typed)
            changed = true
        }
        return changed ? result : nil
    }
}
