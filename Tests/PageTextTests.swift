import Foundation

@main
struct PageTextTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var checks = 0

    static func main() {
        indexing()
        ranking()
        performance()
        print("Passed \(checks) page text checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    static func tab(_ title: String, _ url: String, window: Int = 1, index: Int = 1) -> BrowserTab {
        BrowserTab(windowID: window, index: index, title: title, url: url)
    }

    static let article = tab("Designing resilient services", "https://blog.example.com/resilience")
    static let docs = tab("API reference", "https://docs.example.com/api", index: 2)

    static func indexing() {
        var index = PageTextIndex()
        expect(index.needsReading(article, now: now) && !index.needsReading(tab("Start", ""), now: now)
               && !index.needsReading(tab("Local", "file:///tmp/a.html"), now: now),
               "Only unread web pages need reading")
        index.store("Clients should keep a  Retry Budget\nof three attempts per request. Zażółć.", for: article, at: now)
        index.store("GET /users returns a list of users.", for: docs, at: now)
        expect(!index.needsReading(article, now: now.addingTimeInterval(60))
               && index.needsReading(article, now: now.addingTimeInterval(PageTextIndex.freshFor)),
               "A page read recently is not read again until it may have changed")
        let tabs = [article, docs]
        let phrase = index.matches("retry budget", in: tabs)
        expect(phrase.keys.sorted { $0.index < $1.index } == [article] && phrase[article]?.strength == 1,
               "Typed words found together in a page match fully")
        expect(phrase[article]?.snippet == "clients should keep a retry budget of three attempts per request. zazolc.",
               "A short page is shown whole in the snippet, with spacing and case folded")
        expect(index.matches("budget attempts", in: tabs)[article]?.strength == 0.7,
               "Typed words spread over the page match less strongly")
        expect(index.matches("zazolc", in: tabs)[article] != nil, "Page text folds diacritics like titles do")
        expect(index.matches("budget users", in: tabs).isEmpty, "Every typed word must be on the same page")
        expect(index.matches("re", in: tabs).isEmpty && index.matches("  ", in: tabs).isEmpty,
               "Fewer than three letters match no page")
        let moved = tab(article.title, article.url, index: 9)
        expect(index.matches("retry", in: [moved])[moved] != nil, "A tab that moved keeps its page text")
        let navigated = tab(article.title, "https://blog.example.com/other")
        expect(index.matches("retry", in: [navigated]).isEmpty, "A tab that navigated elsewhere loses the old text")
        expect(index.matches("retry", in: [tab(article.title, article.url, window: 2)]).isEmpty,
               "The same page in another window is a different tab")

        let long = (0..<40).map { "word\($0)" }.joined(separator: " ")
        var snippets = PageTextIndex()
        snippets.store(long + " needle " + long, for: article, at: now)
        let snippet = snippets.matches("needle", in: [article])[article]?.snippet ?? ""
        expect(snippet.hasPrefix("…word") && snippet.hasSuffix("…") && snippet.contains(" needle ") && snippet.count < 110,
               "A long page shows whole words around the match, marking what was cut")
        snippets.store(String(repeating: "a ", count: PageTextIndex.pageLimit) + "needle", for: article, at: now)
        expect(snippets.matches("needle", in: [article]).isEmpty, "Only the start of a very long page is kept")

        index.retain([docs])
        expect(index.count == 1 && index.matches("retry", in: tabs).isEmpty, "Closed tabs are forgotten")
        index.removeAll()
        expect(index.count == 0, "Turning the option off forgets everything")
        var bounded = PageTextIndex()
        for number in 0..<(PageTextIndex.tabLimit + 3) {
            bounded.store("text", for: tab("T", "https://example.com/\(number)"), at: now.addingTimeInterval(Double(number)))
        }
        expect(bounded.count == PageTextIndex.tabLimit
               && bounded.matches("text", in: [tab("T", "https://example.com/0")]).isEmpty,
               "Memory is bounded, forgetting the pages read longest ago")
    }

    static func ranking() {
        let titled = tab("Retry budget explained", "https://example.com/retry", index: 3)
        var index = PageTextIndex()
        index.store("we use a retry budget", for: article, at: now)
        let all = [article, docs, titled]
        let mentioned = index.matches("retry budget", in: all)
        let rows = SearchResultBuilder.rows(query: "retry budget", matches: TabSearchIndex(all).matches(query: "retry budget"),
                                            allTabs: all, history: HistorySearchIndex(.empty), suggestions: [], now: now,
                                            context: RankingContext(content: mentioned.mapValues(\.strength)))
        let listed = rows.compactMap { if case .tab(let item) = $0 { return item }; return nil }
        expect(listed == [titled, article], "A page mentioning the words follows tabs whose title holds them")
        let only = SearchResultBuilder.rows(query: "retry budget", matches: [], allTabs: [article],
                                            history: HistorySearchIndex(.empty), suggestions: [], now: now,
                                            context: RankingContext(content: [article: 1]))
        expect(only.first == .newTab(.search("retry budget")) && only.contains(.tab(article)),
               "A mention is offered below the typed search, which stays the Enter default")
    }

    static func performance() {
        var index = PageTextIndex()
        let page = (0..<4_000).map { "lorem\($0 % 97) ipsum" }.joined(separator: " ")
        let tabs = (0..<PageTextIndex.tabLimit).map { tab("Page \($0)", "https://example.com/\($0)", index: $0 + 1) }
        for item in tabs { index.store(page, for: item, at: now) }
        let started = DispatchTime.now().uptimeNanoseconds
        var found = 0
        for query in ["missing words", "lorem12 ipsum", "ipsum lorem5", "absent"] { found += index.matches(query, in: tabs).count }
        let perQuery = Double(DispatchTime.now().uptimeNanoseconds - started) / 4_000_000
        expect(found == 2 * tabs.count, "Every full page is searched")
        expect(perQuery < 100, "Searching a full page text index stays fast enough for typing")
        print(String(format: "Page text search: %.1f ms/query over %d pages of %d characters", perQuery, tabs.count, min(page.count, PageTextIndex.pageLimit)))
    }
}
