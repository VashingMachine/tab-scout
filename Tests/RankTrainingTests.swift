import Foundation

@main
struct RankTrainingTests {
    static var checks = 0

    static func main() throws {
        impressions()
        try log()
        evaluation()
        training()
        print("Passed \(checks) ranking training checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    static func features(_ values: [RankingSignal: Double]) -> RankingFeatures {
        var features = RankingFeatures()
        for (signal, value) in values { features[signal] = value }
        return features
    }

    static func impressions() {
        let a = features([.lexical: 0.85, .recency: 0.12345])
        let b = features([.lexical: 0.6])
        expect(RankingImpression(typed: true, shown: [a], chosen: 0) == nil, "A single tab teaches nothing")
        expect(RankingImpression(typed: true, shown: [a, b], chosen: 2) == nil, "A choice outside the list is ignored")
        let pair = RankingImpression(typed: true, shown: [a, b], chosen: 1)!
        expect(pair.candidates == [["lexical": 0.85, "recency": 0.123], ["lexical": 0.6]] && pair.chosen == 1,
               "Signals are kept by name, rounded, without zeros")
        expect(pair.vectors()[0][RankingSignal.recency.rawValue] == 0.123 && pair.vectors()[1].count == RankingSignal.allCases.count,
               "Logged signals turn back into full vectors")
        let many = (0..<20).map { features([.recency: Double($0) / 20]) }
        let late = RankingImpression(typed: false, shown: many, chosen: 15)!
        expect(late.candidates.count == RankingImpression.candidateLimit && late.chosen == 4,
               "A long list keeps the tabs around the pick")
        let early = RankingImpression(typed: false, shown: many, chosen: 1)!
        expect(early.chosen == 1 && early.candidates.count == RankingImpression.candidateLimit, "A pick near the top keeps the top")
        let end = RankingImpression(typed: false, shown: many, chosen: 19)!
        expect(end.chosen == 7, "A pick at the end keeps the last tabs")
    }

    static func log() throws {
        var log = RankingLog()
        let pick = RankingImpression(typed: true, shown: [features([.lexical: 1]), features([.lexical: 0.6])], chosen: 0)!
        for _ in 0..<(RankingLog.limit + 5) { log.record(pick) }
        expect(log.impressions.count == RankingLog.limit, "The log is bounded")
        expect(log.needsTraining, "Enough new picks call for training")
        expect(log.weights == .standard && !log.isPersonalized, "Nothing learned means standard weights")
        var tuned = RankingWeights.standard
        var points = tuned.points(typed: false)
        points[RankingSignal.dwell.rawValue] = 15
        tuned.setPoints(points, typed: false)
        log.adopt(tuned)
        expect(!log.needsTraining && log.isPersonalized && log.weights == tuned && log.learned["typed"] == nil,
               "Adopting weights stores only the modes that changed")
        let saved = try JSONDecoder().decode(RankingLog.self, from: JSONEncoder().encode(log))
        expect(saved == log && saved.weights == tuned, "The log and learned weights survive saving")
        log.adopt(nil)
        expect(log.weights == .standard && !log.isPersonalized, "Adopting nothing returns to the standard weights")
        let older = try JSONDecoder().decode(RankingLog.self, from: Data(#"{"impressions":[],"learned":{"empty":{"recency":12}},"sinceTraining":0}"#.utf8))
        expect(older.weights.points(typed: false)[RankingSignal.recency.rawValue] == 12
               && older.weights.points(typed: false)[RankingSignal.related.rawValue] == RankingWeights.standard.empty[RankingSignal.related.rawValue],
               "Signals missing from saved weights keep their standard points")
    }

    static func evaluation() {
        let first = RankingImpression(typed: true, shown: [features([.lexical: 1]), features([.lexical: 0.6])], chosen: 0)!
        let second = RankingImpression(typed: true, shown: [features([.lexical: 1]), features([.lexical: 0.6])], chosen: 1)!
        let tie = RankingImpression(typed: true, shown: [features([.lexical: 0.6]), features([.lexical: 0.6])], chosen: 0)!
        expect(RankTrainer.evaluate([], weights: .standard) == .none, "No picks, no quality")
        let quality = RankTrainer.evaluate([first, second], weights: .standard)
        expect(quality == RankingQuality(picks: 2, firstChoice: 0.5, reciprocalRank: 0.75), "First choice rate and reciprocal rank")
        expect(RankTrainer.evaluate([tie], weights: .standard).firstChoice == 0, "A tie with another tab does not count as first")
    }

    /// People who return to the tabs they read longest, more than to the ones they glanced at last.
    static func readers(_ count: Int, seed: Int) -> [RankingImpression] {
        var state = UInt64(seed)
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        return (0..<count).map { _ in
            let glanced = features([.recency: 0.9 + 0.1 * random(), .dwell: 0.1 * random()])
            let read = features([.recency: 0.4 + 0.2 * random(), .dwell: 0.8 + 0.2 * random()])
            let other = features([.recency: 0.3 * random(), .dwell: 0.3 * random()])
            return RankingImpression(typed: false, shown: [glanced, read, other], chosen: 1)!
        }
    }

    static func training() {
        let picks = readers(80, seed: 7)
        let before = RankTrainer.evaluate(picks, weights: .standard)
        expect(before.firstChoice < 0.1, "Standard weights put the glanced tab first for these readers")
        var log = RankingLog()
        picks.forEach { log.record($0) }
        let started = Date()
        guard let learned = RankTrainer.improve(log) else { return expect(false, "Learning must adopt better weights") }
        let elapsed = Date().timeIntervalSince(started)
        let after = RankTrainer.evaluate(readers(40, seed: 99), weights: learned)
        expect(after.firstChoice > 0.9, "Learned weights rank unseen picks of the same kind first")
        let empty = learned.points(typed: false)
        let standard = RankingWeights.standard.points(typed: false)
        expect(empty[RankingSignal.dwell.rawValue] > standard[RankingSignal.dwell.rawValue]
               && empty[RankingSignal.recency.rawValue] <= standard[RankingSignal.recency.rawValue],
               "Reading time gains weight and recency does not")
        expect(learned.points(typed: true) == RankingWeights.standard.points(typed: true), "A mode without picks keeps standard weights")
        expect(zip(empty, standard).allSatisfy { $0.0 >= 0 && $0.0 <= max(3 * $0.1, 10) }, "Learned weights stay within bounds")
        expect(elapsed < 5, "Training is quick enough for the background")

        var typedLog = RankingLog()
        for impression in readers(60, seed: 3) {
            let vectors = impression.vectors()
            typedLog.record(RankingImpression(typed: true, shown: vectors.enumerated().map { index, values in
                var copy = RankingFeatures()
                for signal in RankingSignal.allCases { copy[signal] = values[signal.rawValue] }
                copy[.lexical] = index == 0 ? 0.9 : 0.6
                copy[.assistant] = index == 2 ? 1 : 0
                return copy
            }, chosen: 1)!)
        }
        let typedWeights = RankTrainer.improve(typedLog)?.points(typed: true) ?? RankingWeights.standard.typed
        expect(typedWeights[RankingSignal.lexical.rawValue] == 100 && typedWeights[RankingSignal.assistant.rawValue] == 200,
               "Match quality and the model's picks are never relearned")

        var consistent = RankingLog()
        for _ in 0..<60 {
            consistent.record(RankingImpression(typed: false, shown: [features([.recency: 1]), features([.recency: 0.5])], chosen: 0)!)
        }
        expect(RankTrainer.improve(consistent) == nil, "Picks the standard weights already rank first teach nothing new")
        var few = RankingLog()
        readers(RankingLog.trainingMinimum - 1, seed: 1).forEach { few.record($0) }
        expect(RankTrainer.improve(few) == nil, "Too few picks keep the standard weights")
    }
}
