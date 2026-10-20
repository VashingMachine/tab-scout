import Foundation

@main
struct SemanticSearchTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var checks = 0

    static func main() {
        expansion()
        ranking()
        systemEmbedding()
        print("Passed \(checks) semantic search checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    static func tab(_ title: String, _ url: String, index: Int = 1) -> BrowserTab {
        BrowserTab(windowID: 1, index: index, title: title, url: url)
    }

    static let inbox = tab("Inbox (2) - Fastmail", "https://app.fastmail.com/", index: 1)
    static let recipe = tab("Best lasagne recipes", "https://food.example.com/lasagne", index: 2)
    static let flights = tab("Cheap flights and booking", "https://air.example.com/", index: 3)
    static let cat = tab("Cat videos", "https://video.example.com/cats", index: 4)
    static let tabs = [inbox, recipe, flights, cat]

    static func fake(_ word: String) -> [Neighbor] {
        switch word {
        case "email": return [Neighbor(word: "mail", strength: 0.4), Neighbor(word: "inbox", strength: 0.3)]
        case "cooking": return [Neighbor(word: "recipe", strength: 0.4), Neighbor(word: "dish", strength: 0.4)]
        case "travel": return [Neighbor(word: "booking", strength: 0.1), Neighbor(word: "trip", strength: 0.5)]
        case "cheap": return [Neighbor(word: "inexpensive", strength: 0.6)]
        case "zero": return [Neighbor(word: "inbox", strength: 0)]
        default: return []
        }
    }

    static func similar(_ query: String, textMatches: Int = 0) -> [TabSearchIndex.SemanticMatch] {
        SemanticSearch.matches(query, in: TabSearchIndex(tabs), textMatches: textMatches, neighbors: fake)
    }

    static func expansion() {
        expect(similar("email").map(\.tab) == [inbox] && similar("email").first?.word == "inbox",
               "A typed word finds a title word of similar meaning, naming it")
        expect(similar("cooking").first?.word == "recipes", "A similar word may start a longer title word")
        expect(similar("cooking").first?.strength == 0.4, "The connection's strength is kept")
        expect(similar("cheap travel").map(\.tab) == [flights], "Typed words found as typed combine with widened ones")
        expect(similar("travel cats").isEmpty, "Every typed word must be found as typed or widened")
        expect(similar("cheap").isEmpty, "A widened word must appear in the title")
        expect(similar("zero").isEmpty, "Neighbours without strength do not count")
        expect(similar("email", textMatches: SemanticSearch.fewMatches).isEmpty, "Enough text matches leave meaning out")
        expect(similar("").isEmpty && similar("em").isEmpty && similar("e2e").isEmpty,
               "Short, blank or non-word input is not widened")
        expect(SemanticSearch.strength(distance: 0.6) == 1 && SemanticSearch.strength(distance: 1.05) == 0
               && SemanticSearch.strength(distance: 0.9) > 0.3, "Distances map to strengths between 0 and 1")
        let many = (1...9).map { tab("Recipe \($0)", "https://food.example.com/\($0)", index: $0) }
        expect(SemanticSearch.matches("cooking", in: TabSearchIndex(many), textMatches: 0, neighbors: fake).count == SemanticSearch.limit,
               "Guesses by meaning are bounded")
    }

    static func ranking() {
        let lexical = tab("Email settings", "https://example.com/settings", index: 5)
        let all = tabs + [lexical]
        let found = SemanticSearch.matches("email", in: TabSearchIndex(all), textMatches: 1, neighbors: fake)
        let context = RankingContext(semantic: Dictionary(found.map { ($0.tab, $0.strength) }, uniquingKeysWith: max))
        let rows = SearchResultBuilder.rows(query: "email", matches: TabSearchIndex(all).matches(query: "email"), allTabs: all,
                                            history: HistorySearchIndex(.empty), suggestions: [], now: now, context: context)
        let listed = rows.compactMap { if case .tab(let item) = $0 { return item }; return nil }
        expect(listed == [lexical, inbox], "Tabs found by meaning follow every text match")
        let only = SearchResultBuilder.rows(query: "cooking", matches: [], allTabs: tabs, history: HistorySearchIndex(.empty),
                                            suggestions: [], now: now,
                                            context: RankingContext(semantic: [recipe: 0.4]))
        expect(only.first == .newTab(.search("cooking")) && only.contains(.tab(recipe)),
               "A guess by meaning is offered below the typed search, which stays the Enter default")
        let empty = SearchResultBuilder.rows(query: "", matches: TabSearchIndex(tabs).matches(query: ""), allTabs: tabs,
                                             history: HistorySearchIndex(.empty), suggestions: [], now: now,
                                             context: RankingContext(semantic: [cat: 1]))
        expect(empty.first == .tab(inbox), "Meaning plays no part in empty input")
    }

    static func systemEmbedding() {
        let neighbors = WordNeighbors()
        let email = neighbors("email")
        // macOS ships an English word embedding; skip the live check where it is missing.
        guard !email.isEmpty else { print("Skipped system word embedding checks: unavailable"); return }
        expect(email.contains { $0.word == "inbox" || $0.word == "mail" }, "The system embedding relates email to mail")
        expect(neighbors("email") == email, "Neighbours are cached")
        expect(neighbors("qwzxv").isEmpty, "Unknown words have no neighbours")
        let found = SemanticSearch.matches("email", in: TabSearchIndex([inbox, cat]), textMatches: 0) { neighbors($0) }
        expect(found.map(\.tab) == [inbox], "The live embedding finds an inbox for email")
    }
}
