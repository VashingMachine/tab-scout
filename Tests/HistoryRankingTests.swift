import Foundation

@main
struct HistoryRankingTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var checks = 0

    static func main() {
        relevance()
        tabRanking()
        historyRanking()
        resultComposition()
        queryIdentity()
        navigation()
        selectionRetention()
        print("Passed \(checks) history ranking and result navigation checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func date(daysAgo: Double) -> Date { now.addingTimeInterval(-daysAgo * 86_400) }

    static func tab(_ title: String, _ url: String, window: Int = 1, index: Int = 1) -> SafariTab {
        SafariTab(windowID: window, index: index, title: title, url: url)
    }

    static func visit(_ title: String, _ url: String, days: Double = 0, count: Int = 1) -> HistoryVisit {
        HistoryVisit(url: url, title: title, lastVisited: date(daysAgo: days), visitCount: count)
    }

    static func search(_ query: String, days: Double = 0, count: Int = 1) -> PastSearch {
        PastSearch(query: query, lastUsed: date(daysAgo: days), useCount: count)
    }

    static func rows(_ query: String, tabs: [SafariTab] = [], visits: [HistoryVisit] = [],
                     searches: [PastSearch] = [], suggestions: [String] = []) -> [SearchRow] {
        SearchResultBuilder.rows(query: query, matches: TabSearchIndex(tabs).matches(query: query),
                                 allTabs: tabs,
                                 history: HistorySearchIndex(HistorySnapshot(visits: visits, searches: searches)),
                                 suggestions: suggestions, now: now)
    }

    static func displayedTabs(_ rows: [SearchRow]) -> [SafariTab] {
        rows.compactMap { if case .tab(let item) = $0 { return item }; return nil }
    }

    static func remoteQueries(_ rows: [SearchRow]) -> [String] {
        rows.compactMap { if case .suggestion(let query) = $0 { return query }; return nil }
    }

    static func relevance() {
        let fresh = HistoryRelevance.score(lastUsed: now, count: 1, now: now)
        let monthOld = HistoryRelevance.score(lastUsed: date(daysAgo: 30), count: 1, now: now)
        let yearOld = HistoryRelevance.score(lastUsed: date(daysAgo: 365), count: 1, now: now)
        expect(fresh > monthOld && monthOld > yearOld, "Recency decays monotonically over time")
        expect(HistoryRelevance.score(lastUsed: now, count: 10, now: now) > fresh,
               "Repeated successful choices receive a frequency boost")
        expect(HistoryRelevance.score(lastUsed: now, count: 100_000, now: now) <= 60,
               "Very high frequency is capped rather than dominating relevance")
        expect(fresh > HistoryRelevance.score(lastUsed: date(daysAgo: 180), count: 100_000, now: now),
               "A new infrequent choice outranks a very old frequent choice at equal match quality")
        expect(HistoryRelevance.score(lastUsed: date(daysAgo: -5), count: 1, now: now) == fresh,
               "Future timestamps cannot gain extra recency")
        expect(HistoryRelevance.score(lastUsed: now, count: -1, now: now).isFinite,
               "Invalid negative counts cannot produce NaN or infinity")
        expect(HistoryRelevance.score(lastUsed: now, count: -1, now: now)
               == HistoryRelevance.score(lastUsed: now, count: 0, now: now),
               "Negative counts are treated as zero")
        expect(HistoryRelevance.score(lastUsed: now, count: 1_000, now: now)
               == HistoryRelevance.score(lastUsed: now, count: 1_000_000, now: now),
               "Frequency remains bounded after saturation")
    }

    static func tabRanking() {
        let exact = tab("work", "https://example.com/exact")
        let prefix = tab("work notes", "https://example.com/prefix", index: 2)
        let token = tab("notes about work", "https://example.com/token", index: 3)
        let inventory = [token, prefix, exact]
        let index = HistorySearchIndex(HistorySnapshot(visits: [
            visit(prefix.title, prefix.url, count: 100_000),
            visit(token.title, token.url, count: 100_000)
        ], searches: []))
        expect(index.rankTabs(TabSearchIndex(inventory).matches(query: "work"), now: now)
               == [exact, prefix, token], "Tab match tiers dominate history frequency and recency")

        let old = tab("work alpha", "https://example.com/old")
        let recent = tab("work beta", "https://example.com/recent", index: 2)
        let recentIndex = HistorySearchIndex(HistorySnapshot(visits: [
            visit(old.title, old.url, days: 30), visit(recent.title, recent.url)
        ], searches: []))
        expect(recentIndex.rankTabs(TabSearchIndex([old, recent]).matches(query: "work"), now: now)
               == [recent, old], "Recent history boosts equal-quality open tabs")
        let frequentIndex = HistorySearchIndex(HistorySnapshot(visits: [
            visit(old.title, old.url, count: 1), visit(recent.title, recent.url, count: 10)
        ], searches: []))
        expect(frequentIndex.rankTabs(TabSearchIndex([old, recent]).matches(query: "work"), now: now)
               == [recent, old], "Frequent history boosts equally recent matching tabs")

        let decayed = HistorySearchIndex(HistorySnapshot(visits: [
            visit(old.title, old.url, days: 180, count: 100_000), visit(recent.title, recent.url)
        ], searches: []))
        expect(decayed.rankTabs(TabSearchIndex([old, recent]).matches(query: "work"), now: now)
               == [recent, old], "Old frequency cannot permanently win an equal-quality tab match")
        expect(HistorySearchIndex(.empty).rankTabs(TabSearchIndex([old, recent]).matches(query: "work"), now: now)
               == [old, recent], "Without history equal-quality tabs preserve inventory order")

        let canonical = tab("work canonical", "https://EXAMPLE.com:443/", index: 4)
        let canonicalIndex = HistorySearchIndex(HistorySnapshot(visits: [
            visit("Previous title", "https://example.com", count: 20)
        ], searches: []))
        expect(canonicalIndex.rankTabs(TabSearchIndex([old, canonical]).matches(query: "work"), now: now)
               .first == canonical, "Usage follows normalized URLs despite a changed title or default port")

        let sameURL = tab("work recent title", recent.url, index: 5)
        expect(recentIndex.rankTabs(TabSearchIndex([sameURL, recent]).matches(query: "work"), now: now)
               == [sameURL, recent], "Duplicate open destinations preserve deterministic inventory order")
        expect(index.rankTabs([], now: now).isEmpty, "Empty matching tabs produce no results")
    }

    static func historyRanking() {
        let exact = visit("work", "https://example.com/exact", days: 180)
        let prefix = visit("work notes", "https://example.com/prefix", count: 100_000)
        let token = visit("notes about work", "https://example.com/token", count: 100_000)
        let history = HistorySearchIndex(HistorySnapshot(visits: [token, prefix, exact], searches: [
            search("notes about work", count: 100_000), search("work tools", count: 100_000),
            search("work", days: 180)
        ]))
        expect(history.browsingMatches(query: "work", now: now) == [exact, prefix, token],
               "History title match quality outranks large frequency and recency differences")
        expect(history.recentSearches(query: "work", now: now).map(\.query)
               == ["work", "work tools", "notes about work"],
               "Recent query exact, prefix and token tiers are ranked before usage")

        let host = visit("Unrelated title", "https://work/path", days: 180)
        let title = visit("work", "https://example.com/path", count: 100_000)
        expect(HistorySearchIndex(HistorySnapshot(visits: [title, host], searches: []))
               .browsingMatches(query: "work", now: now).first == host,
               "Exact host matches retain priority over an exact title boosted by history")

        let old = visit("work alpha", "https://example.com/a", days: 30)
        let fresh = visit("work beta", "https://example.com/b")
        expect(HistorySearchIndex(HistorySnapshot(visits: [old, fresh], searches: []))
               .browsingMatches(query: "work", now: now) == [fresh, old],
               "Equal-quality history visits are recency ranked")
        expect(HistorySearchIndex(HistorySnapshot(visits: [], searches: [
            search("work alpha"), search("work beta", count: 10)
        ])).recentSearches(query: "work", now: now).map(\.query) == ["work beta", "work alpha"],
               "Equal-quality recent queries use frequency to break a recency tie")

        expect(history.browsingMatches(query: "", now: now).isEmpty,
               "Empty input does not expose unrelated browsing history")
        expect(history.browsingMatches(query: "work missing", now: now).isEmpty,
               "Every query token is required for a history match")
        expect(history.recentSearches(query: "work missing", now: now).isEmpty,
               "Every query token is required for a recent search match")

        let tied = HistorySearchIndex(HistorySnapshot(visits: [
            visit("work b", "https://example.com/b"), visit("work a", "https://example.com/a")
        ], searches: [search("work b"), search("work a")]))
        expect(tied.browsingMatches(query: "work", now: now).map(\.title) == ["work b", "work a"],
               "History visit ties preserve source order")
        expect(tied.recentSearches(query: "work", now: now).map(\.query) == ["work b", "work a"],
               "Recent search ties preserve source order")

        let googleVisit = visit("work - Google Search", "https://www.google.com/search?client=safari&q=work")
        expect(HistorySearchIndex(HistorySnapshot(visits: [googleVisit], searches: [search("work")]))
               .browsingMatches(query: "work", now: now).isEmpty,
               "Known Google result pages are presented as queries instead of duplicate website history")

        let many = HistorySearchIndex(HistorySnapshot(visits: (0..<20).map {
            visit("work \($0)", "https://example.com/\($0)")
        }, searches: (0..<20).map { search("work \($0)", days: Double($0)) }))
        expect(many.browsingMatches(query: "work", now: now).count == 8, "Browsing history is bounded")
        expect(many.recentSearches(query: "work", now: now).count == 5, "Matching recent searches are bounded")
        expect(many.recentSearches(query: "", now: now).map(\.query) == (0..<5).map { "work \($0)" },
               "Empty-input recent searches use most recent first without frequency promotion")
    }

    static func resultComposition() {
        let provider = ["chat games", "chat meaning", "chat rooms"]
        let plain = rows("chat", suggestions: provider)
        expect(remoteQueries(plain) == provider, "Without local history provider ordering is unchanged")
        expect(plain.first == .newTab(.search("chat")), "Raw query is the default when no local matches exist")
        expect(plain.contains(.section(.google)), "Remote predictions have a Google section")

        let duplicateTyped = rows("coffee  beans", suggestions: ["Coffee beans", "coffee  beans", "coffee beans origin"])
        expect(remoteQueries(duplicateTyped) == ["coffee beans origin"],
               "Predictions equal to the normalized typed query are omitted")
        expect(duplicateTyped.first == .newTab(.search("coffee  beans")),
               "Omitting an exact Google prediction leaves the original raw-query action as default")
        let blank = rows(" \n\t ", searches: [search("recent search")], suggestions: provider)
        expect(blank.first == .newTab(.url("about:blank")), "Empty input defaults to a blank new tab")
        expect(remoteQueries(blank).isEmpty && !blank.contains(.section(.google)),
               "Empty input never displays remote predictions")
        expect(blank.contains(.section(.recent)), "Recent searches remain available below empty-input default")

        let current = tab("New title", "https://EXAMPLE.com:443/", index: 7)
        let oldTitle = visit("Swift documentation", "https://example.com")
        let reused = rows("swift", tabs: [current], visits: [oldTitle])
        expect(TabSearchIndex([current]).matches(query: "swift").isEmpty,
               "Fixture's current tab title and URL do not independently match")
        expect(displayedTabs(reused) == [current],
               "A matching previous history title reuses its currently open tab")
        expect(!reused.contains(.history(oldTitle)), "Reusing an open destination cannot create a duplicate history action")
        expect(reused.first(where: \.isSelectable) == .tab(current),
               "An open tab recovered through history remains the default local destination")
        expect(SearchRow.tab(current).destination == nil, "Recovered tabs use switching, not URL creation")
        let lookup = OpenTabLookup([current])
        expect(lookup.tab(for: HistoryIdentity.url(oldTitle.url)!) == current,
               "Cached open-tab lookup uses the same normalized destination identity")
        let cachedRows = SearchResultBuilder.rows(query: "swift", matches: [], allTabs: [current],
                                                  history: HistorySearchIndex(HistorySnapshot(visits: [oldTitle], searches: [])),
                                                  suggestions: [], now: now, openTabs: lookup)
        expect(cachedRows == reused, "Cached lookup preserves default-builder results exactly")

        let first = tab("Swift reference", "https://example.com/reference")
        let second = tab("Swift reference", first.url, window: 2, index: 4)
        let duplicated = rows("swift", tabs: [first, second], visits: [
            visit("Swift reference", first.url), visit("Swift reference duplicate", first.url)
        ])
        expect(displayedTabs(duplicated) == [first, second], "Separate open tabs remain distinct even at the same URL")
        expect(!duplicated.contains(.section(.history)), "Already matched open destinations suppress all redundant history rows")
        expect(OpenTabLookup([first, second]).tab(for: HistoryIdentity.url(first.url)!) == first,
               "Cached lookup chooses the first snapshot tab deterministically for a repeated URL")

        let duplicateHistory = rows("swift", visits: [
            visit("Swift docs", "https://example.com"), visit("Swift docs copy", "https://EXAMPLE.com:443/")
        ])
        expect(duplicateHistory.filter { if case .history = $0 { return true }; return false }.count == 1,
               "Equivalent browsing history destinations are displayed only once")
        expect(rows("swift", visits: [oldTitle]).contains(.history(oldTitle)),
               "A closed historical destination opens through a history row")
        expect(SearchRow.history(oldTitle).destination == .url(oldTitle.url), "History rows resolve to their visited URL")
        expect(SearchRow.recentSearch(search("swift docs")).destination == .search("swift docs"),
               "Recent search rows execute the saved query")
        expect(SearchRow.suggestion("swift tools").destination == .search("swift tools"),
               "Remote prediction rows execute their displayed query")

        let manyTabs = (0..<30).map { tab("work \($0)", "https://example.com/\($0)", index: $0 + 1) }
        expect(displayedTabs(rows("work", tabs: manyTabs)) == manyTabs, "Every matching open tab remains reachable")
        expect(displayedTabs(rows("", tabs: manyTabs)) == manyTabs, "Empty input keeps the complete open-tab inventory")
        expect(remoteQueries(rows("work", suggestions: (0..<20).map { "work \($0)" })).count == 8,
               "Google predictions are bounded")
        expect(rows("swift", suggestions: []).allSatisfy(\.isSelectable), "No empty section headers are emitted")
        let invalidVisit = visit("work invalid", "file:///private/synthetic-history")
        let invalidRows = rows("work", tabs: [tab("Unrelated", "about:blank")], visits: [invalidVisit])
        expect(!invalidRows.contains(.section(.history)), "Invalid history URLs cannot emit a history section")
        expect(displayedTabs(invalidRows).isEmpty,
               "Two nil URL identities cannot accidentally recover an unrelated open tab")
        expect(!invalidRows.contains(.history(invalidVisit)), "Invalid history destinations cannot become selectable rows")
        expect(OpenTabLookup([tab("Invalid", invalidVisit.url)]).tab(for: invalidVisit.url) == nil,
               "Cached lookup excludes invalid URL identities entirely")
    }

    static func queryIdentity() {
        let googleA = "https://www.google.com/search?client=safari&q=%C5%81%C3%B3d%C5%BA+Trips"
        let googleB = "https://www.google.pl/search?q=lodz%20trips&client=safari"
        let first = HistorySearchQuery.from(url: googleA)
        let second = HistorySearchQuery.from(url: googleB)
        expect(first == "Łódź Trips", "Google history query extraction decodes form spaces and Unicode")
        expect(second == "lodz trips", "Google query extraction ignores unrelated client parameters")
        expect(HistoryIdentity.query(first!) == HistoryIdentity.query(second!),
               "Queries normalize case and Polish diacritics across search URLs")
        let merged = HistoryStore.merge(HistorySnapshot(visits: [], searches: [search(first!, days: 2)]),
                                        HistorySnapshot(visits: [], searches: [search(second!, count: 3)]), now: now)
        expect(merged.searches.count == 1 && merged.searches[0].useCount == 3,
               "Equivalent Google search history merges without inflating duplicate counts")
        let combined = rows("lodz", searches: merged.searches,
                            suggestions: ["ŁÓDŹ trips", "lodz trips", "Łódź Train", "LODZ TRAIN", "lodz weather"])
        expect(remoteQueries(combined) == ["Łódź Train", "lodz weather"],
               "Recent Google queries suppress equivalent predictions and remote duplicates")
        expect(combined.filter { if case .recentSearch = $0 { return true }; return false }.count == 1,
               "Merged recent queries display a single local row")

        for invalid in ["https://google.com.evil.example/search?q=work",
                        "https://evilgoogle.com/search?q=work", "https://maps.google.com/search?q=work",
                        "https://www.google.com/url?q=work", "https://www.google.com/search?q=",
                        "https://www.google.com/search?q=work&q=other", "file:///search?q=work"] {
            expect(HistorySearchQuery.from(url: invalid) == nil,
                   "Untrusted or ambiguous Google history query rejected: \(invalid)")
        }
    }

    static func navigation() {
        let list: [SearchRow] = [
            .section(.tabs), .tab(tab("A", "https://example.com/a")),
            .section(.recent), .recentSearch(search("a query")),
            .section(.history), .history(visit("B", "https://example.com/b")),
            .section(.google), .suggestion("a suggestion")
        ]
        expect(SearchSection.tabs.rawValue == "Open Tabs", "Open tabs have a distinct section label")
        expect(list.enumerated().allSatisfy { $0.offset.isMultiple(of: 2) ? !$0.element.isSelectable : $0.element.isSelectable },
               "Only content rows, never section headers, are selectable")
        expect(ResultNavigation.first(in: list) == 1, "Initial selection skips the leading header")
        expect(ResultNavigation.next(in: list, from: 1, step: 1) == 3, "Down arrow skips a recent-search header")
        expect(ResultNavigation.next(in: list, from: 3, step: 1) == 5, "Down arrow skips a history header")
        expect(ResultNavigation.next(in: list, from: 5, step: 1) == 7, "Down arrow skips a Google header")
        expect(ResultNavigation.next(in: list, from: 7, step: -1) == 5, "Up arrow skips a Google header")
        expect(ResultNavigation.next(in: list, from: 5, step: -1) == 3, "Up arrow skips a history header")
        expect(ResultNavigation.next(in: list, from: 3, step: -1) == 1, "Up arrow skips a recent-search header")
        expect(ResultNavigation.next(in: list, from: 1, step: -1) == 1, "Up arrow clamps at the first selectable row")
        expect(ResultNavigation.next(in: list, from: 7, step: 1) == 7, "Down arrow clamps at the final selectable row")
        expect(ResultNavigation.next(in: list, from: -1, step: 1) == 1, "Invalid previous selection recovers to the first row")
        expect(ResultNavigation.next(in: list, from: 0, step: 1) == 1, "Navigation from a header finds selectable content")
        expect(ResultNavigation.next(in: list, from: 1, step: 0) == nil, "Unsupported zero navigation step is rejected")
        expect(ResultNavigation.next(in: list, from: 1, step: 2) == nil, "Unsupported multi-row navigation step is rejected")
        expect(ResultNavigation.first(in: []) == nil, "Empty lists have no initial selection")
        expect(ResultNavigation.next(in: [], from: 0, step: 1) == nil, "Empty lists have no next selection")
        expect(ResultNavigation.first(in: [.section(.tabs), .section(.google)]) == nil,
               "Headers alone cannot become the initial selection")
        expect(ResultNavigation.next(in: [.section(.tabs)], from: 0, step: 1) == nil,
               "Headers alone cannot become a navigated selection")
        expect(SearchRow.section(.google).destination == nil, "Headers never execute a search")
    }

    static func selectionRetention() {
        let previous = search("Łódź trips", days: 2)
        let updated = search("LODZ TRIPS", count: 8)
        expect(SearchRow.retainedSelection(of: .recentSearch(previous), in: [
            .section(.recent), .recentSearch(search("other")), .recentSearch(updated)
        ]) == 2, "Recent query selection survives refreshed timestamps, counts and normalization")
        expect(SearchRow.retainedSelection(of: .recentSearch(previous), in: [
            .recentSearch(updated), .recentSearch(search("lodz trips", count: 2))
        ]) == nil, "Ambiguous normalized recent-query selection is not guessed")
        expect(SearchRow.retainedSelection(of: .recentSearch(previous), in: [.recentSearch(search("different"))]) == nil,
               "Removed recent queries do not retain unrelated rows")

        let previousVisit = visit("Old title", "https://EXAMPLE.com:443/", days: 30)
        let updatedVisit = visit("New title", "https://example.com", count: 5)
        expect(SearchRow.retainedSelection(of: .history(previousVisit), in: [
            .section(.history), .history(updatedVisit)
        ]) == 1, "History selection survives changed titles, usage dates and canonical URL spelling")
        expect(SearchRow.retainedSelection(of: .history(visit("Previous invalid", "about:blank")), in: [
            .history(visit("Different invalid", "file:///private/synthetic-history"))
        ]) == nil, "Nil URL identities cannot retain selection of an unrelated invalid history row")
        expect(SearchRow.retainedSelection(of: .suggestion("Łódź Train"), in: [
            .section(.google), .suggestion("lodz train")
        ]) == 1, "Prediction selection survives equivalent normalized spelling")
        expect(SearchRow.retainedSelection(of: .suggestion("work"), in: [.suggestion("work tools")]) == nil,
               "A changed prediction cannot inherit a selected different query")
        let unrelated = SearchRow.tab(tab("Unrelated", "https://example.com/unrelated"))
        expect(SearchRow.retainedSelection(of: .suggestion("Łódź tools"), in: [
            unrelated, .section(.recent), .recentSearch(search("LODZ TOOLS"))
        ]) == 2, "Late history promotes a selected prediction without changing the chosen normalized query")
        expect(SearchRow.retainedSelection(of: .recentSearch(search("Łódź tools")), in: [
            unrelated, .suggestion("lodz tools")
        ]) == 1, "Removing local history preserves a selected equivalent remote prediction")
        expect(SearchRow.retainedSelection(of: .suggestion("Łódź tools"), in: [
            .recentSearch(search("lodz tools")), .recentSearch(search("LODZ TOOLS", count: 2))
        ]) == nil, "A query promoted to duplicate equivalent recent rows is not guessed")
        expect(SearchRow.retainedSelection(of: .suggestion("Łódź tools"), in: [
            .recentSearch(search("lodz tools")), .suggestion("LODZ TOOLS")
        ]) == nil, "Equivalent query targets across categories remain ambiguous")

        let recoveredTab = tab("Updated title", "https://example.com", window: 4, index: 3)
        expect(SearchRow.retainedSelection(of: .history(previousVisit), in: [
            unrelated, .section(.history), .tab(recoveredTab)
        ]) == 2, "Refreshed open tabs promote a selected history URL without changing its destination")
        expect(SearchRow.retainedSelection(of: .history(previousVisit), in: [
            .tab(recoveredTab), .tab(tab("Another title", "https://EXAMPLE.com:443/", window: 7))
        ]) == nil, "A history destination promoted to multiple open tabs is not guessed")
        expect(SearchRow.retainedSelection(of: .history(previousVisit), in: [
            .history(updatedVisit), .tab(recoveredTab)
        ]) == nil, "Duplicate canonical URL targets across history and tab categories remain ambiguous")
        expect(SearchRow.retainedSelection(of: .history(visit("Invalid", "about:blank")), in: [
            .tab(tab("Unrelated invalid", "file:///private/synthetic-history"))
        ]) == nil, "Invalid URLs cannot become cross-category promoted selections")

        let selected = tab("Selected", "https://example.com/a", window: 8, index: 5)
        let moved = tab(selected.title, selected.url, window: 8, index: 4)
        let duplicate = tab(selected.title, selected.url, window: 8, index: 6)
        let otherWindow = tab(selected.title, selected.url, window: 9, index: 4)
        expect(SearchRow.retainedSelection(of: .tab(selected), in: [.section(.tabs), .tab(moved)]) == 1,
               "A moved tab retains selection when uniquely identifiable")
        expect(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(otherWindow), .tab(moved)]) == 1,
               "Matching tabs in other windows do not steal a moved-tab selection")
        expect(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(moved), .tab(duplicate)]) == nil,
               "Ambiguous duplicate tabs are not guessed after a move")
        expect(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(duplicate), .tab(selected)]) == 1,
               "An exact selected-tab identity takes priority over duplicate-looking tabs")
        let raw = SearchRow.newTab(.search("work"))
        expect(SearchRow.retainedSelection(of: raw, in: [.suggestion("work tools"), raw]) == 1,
               "Late predictions do not change the selected raw-query action")
        expect(SearchRow.retainedSelection(of: raw, in: [.newTab(.search("different"))]) == nil,
               "Editing the query does not retain an unrelated raw-query action")
    }
}
