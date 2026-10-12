import Foundation

@main
struct LearningTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var checks = 0

    static func main() throws {
        affinity()
        affinityBounds()
        try storage()
        print("Passed \(checks) learning checks")
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        checks += 1
        if try !condition() { fatalError(message) }
    }

    static func date(daysAgo: Double) -> Date { now.addingTimeInterval(-daysAgo * 86_400) }

    static func affinity() {
        let jira = "https://jira.example.com/"
        let jenkins = "https://jenkins.example.com/"
        var affinity = QueryAffinity()
        expect(affinity.strengths(for: "j", now: now).isEmpty, "Nothing is learned before a choice")
        affinity.record(input: " J ", target: jira, at: now)
        let once = affinity.strengths(for: "j", now: now)[jira] ?? 0
        expect(once > 0.45 && once < 0.55, "One choice gives about half strength")
        affinity.record(input: "j", target: jira, at: now)
        affinity.record(input: "j", target: jira, at: now)
        let thrice = affinity.strengths(for: "J", now: now)[jira] ?? 0
        expect(thrice > 0.85 && thrice < 1, "Repeated choices approach full strength without reaching it")
        expect(affinity.choices.count == 1, "The same text and page are remembered once")

        affinity.record(input: "j", target: jenkins, at: now)
        let shared = affinity.strengths(for: "j", now: now)
        expect(shared[jira]! > shared[jenkins]! && shared[jira]! < thrice,
               "Choosing another page for the same text shares the strength")
        expect((affinity.strengths(for: "", now: now)).isEmpty, "Empty text has no affinity")
        expect(affinity.strengths(for: "x", now: now).isEmpty, "Unrelated text has no affinity")

        var lengths = QueryAffinity()
        lengths.record(input: "jira board", target: jira, at: now)
        let shorter = lengths.strengths(for: "jira", now: now)[jira] ?? 0
        let same = lengths.strengths(for: "jira board", now: now)[jira] ?? 0
        expect(shorter > 0 && shorter < same, "Typing the start of earlier text counts, less than the same text")
        var longer = QueryAffinity()
        longer.record(input: "ji", target: jira, at: now)
        let extended = longer.strengths(for: "jira board", now: now)[jira] ?? 0
        expect(extended > 0 && extended < (longer.strengths(for: "ji", now: now)[jira] ?? 0),
               "Typing past earlier text still counts, but less")
        var single = QueryAffinity()
        single.record(input: "j", target: jira, at: now)
        expect(single.strengths(for: "jenkins", now: now).isEmpty, "A single earlier letter does not claim longer text")

        var decaying = QueryAffinity()
        decaying.record(input: "docs", target: jira, at: date(daysAgo: 30))
        let faded = decaying.strengths(for: "docs", now: now)[jira] ?? 0
        expect(faded < once && faded > 0, "Old choices fade")
        decaying.record(input: "docs", target: jira, at: now)
        expect(abs((decaying.choices.first?.weight ?? 0) - 1.5) < 0.001, "A new choice adds to the faded weight")

        var normalized = QueryAffinity()
        normalized.record(input: "Łódź", target: jira, at: now)
        expect(normalized.strengths(for: "lodz", now: now)[jira] != nil, "Typed text is folded like search queries")
        normalized.record(input: "   ", target: jira, at: now)
        normalized.record(input: "x", target: "", at: now)
        expect(normalized.choices.count == 1, "Blank text or targets are not recorded")
    }

    static func affinityBounds() {
        var affinity = QueryAffinity()
        for index in 0..<(QueryAffinity.limit + 20) {
            affinity.record(input: "query \(index)", target: "https://example.com/\(index)",
                            at: date(daysAgo: Double(QueryAffinity.limit + 20 - index)))
        }
        expect(affinity.choices.count == QueryAffinity.limit, "Memory is bounded")
        expect(affinity.choices.first?.input == "query 20" && affinity.choices.last?.input == "query \(QueryAffinity.limit + 19)",
               "The faintest choices are forgotten first, keeping the rest in order")
        affinity.record(input: String(repeating: "a", count: 300), target: "https://example.com/", at: now)
        expect(affinity.choices.count == QueryAffinity.limit && !affinity.choices.contains { $0.input.count > 256 },
               "Overlong text is not recorded")
    }

    static func storage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabScoutLearning-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("learning-v1.json")
        let store = LearningStore(directory: directory, saveDelay: 0)
        expect(store.state == LearningState() && !store.storageError, "A missing file starts empty")
        store.update { $0.affinity.record(input: "mail", target: "https://mail.example.com/", at: now) }
        store.flush()
        expect(FileManager.default.fileExists(atPath: file.path), "Learning is saved")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "The saved file is private")
        expect(LearningStore(directory: directory).state == store.state, "Learning survives a restart")

        store.clear()
        store.flush()
        let cleared = LearningStore(directory: directory)
        expect(cleared.state == LearningState(), "Clearing forgets everything learned")

        try Data("not json".utf8).write(to: file)
        let corrupt = LearningStore(directory: directory, saveDelay: 0)
        expect(corrupt.storageError && corrupt.state == LearningState(), "An unreadable file starts empty and reports it")
        corrupt.update { $0.affinity.record(input: "x", target: "https://x.example.com/", at: now) }
        corrupt.flush()
        expect(LearningStore(directory: directory).state == corrupt.state, "The next save replaces an unreadable file")

        try Data(#"{"version":1,"state":{}}"#.utf8).write(to: file)
        expect(LearningStore(directory: directory).state == LearningState(), "A file from an older version loads what it has")
        try Data(#"{"version":2,"state":{}}"#.utf8).write(to: file)
        expect(LearningStore(directory: directory).storageError, "A file from a newer version is not trusted")

        let memory = LearningStore(directory: nil, saveDelay: 0)
        memory.update { $0.affinity.record(input: "x", target: "https://x.example.com/", at: now) }
        memory.flush()
        expect(memory.state.affinity.choices.count == 1, "A preview store learns in memory only")
    }
}
