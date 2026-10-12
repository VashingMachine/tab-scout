import Foundation

enum HistoryRelevance {
    static func score(lastUsed: Date, count: Int, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(lastUsed)) / 86_400
        let recency = 40 * exp(-days / 30)
        let frequency = min(20, 4 * log2(Double(max(0, count)) + 1))
        return recency + frequency
    }
}

struct HistorySearchIndex {
    private struct VisitEntry {
        let visit: HistoryVisit
        let fields: TextFields
    }
    private struct QueryEntry {
        let search: PastSearch
        let normalized: String
    }
    private let visits: [VisitEntry]
    private let queries: [QueryEntry]
    private let usage: [String: HistoryVisit]

    init(_ snapshot: HistorySnapshot) {
        visits = snapshot.visits.filter { HistoryIdentity.url($0.url) != nil && HistorySearchQuery.from(url: $0.url) == nil }.map {
            VisitEntry(visit: $0, fields: TextFields(title: $0.title, url: $0.url, loose: false))
        }
        queries = snapshot.searches.map { QueryEntry(search: $0, normalized: HistoryIdentity.query($0.query)) }
        usage = Dictionary(snapshot.visits.compactMap { visit -> (String, HistoryVisit)? in
            guard let key = HistoryIdentity.url(visit.url) else { return nil }
            return (key, visit)
        }, uniquingKeysWith: { old, new in
            old.lastVisited > new.lastVisited ? old : new
        })
    }

    func rankTabs(_ matches: [TabSearchIndex.Match], now: Date) -> [SafariTab] {
        TabRanker.rank(typed: matches.contains { $0.relevance > 0 }, matches: matches,
                       history: self, context: RankingContext(), now: now).map(\.tab)
    }

    func recentSearches(query: String, now: Date) -> [PastSearch] {
        let query = HistoryIdentity.query(query)
        guard !query.isEmpty else {
            return queries.sorted { $0.search.lastUsed > $1.search.lastUsed }.prefix(5).map(\.search)
        }
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return queries.enumerated().compactMap { offset, entry -> (Int, Double, Int, PastSearch)? in
            guard tokens.allSatisfy({ entry.normalized.contains($0) }) else { return nil }
            let match = entry.normalized == query ? 100 : entry.normalized.hasPrefix(query) ? 90 : 60
            return (match, HistoryRelevance.score(lastUsed: entry.search.lastUsed, count: entry.search.useCount, now: now), offset, entry.search)
        }.sorted { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            return a.1 == b.1 ? a.2 < b.2 : a.1 > b.1
        }.prefix(5).map { $0.3 }
    }

    func browsingMatches(query: String, now: Date) -> [HistoryVisit] {
        let query = HistoryIdentity.query(query)
        guard !query.isEmpty else { return [] }
        let prepared = TextQuery(normalized: query)
        return visits.enumerated().compactMap { offset, entry -> (Int, Double, Int, HistoryVisit)? in
            // Typos and initials stay limited to open tabs; history is too large for loose matches.
            guard let match = entry.fields.relevance(prepared, fuzzy: false) else { return nil }
            return (match, HistoryRelevance.score(lastUsed: entry.visit.lastVisited, count: entry.visit.visitCount, now: now), offset, entry.visit)
        }.sorted { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            return a.1 == b.1 ? a.2 < b.2 : a.1 > b.1
        }.prefix(8).map { $0.3 }
    }

    func usageScore(url: String, now: Date) -> Double {
        guard let key = HistoryIdentity.url(url), let visit = usage[key] else { return 0 }
        return HistoryRelevance.score(lastUsed: visit.lastVisited, count: visit.visitCount, now: now)
    }
}

struct OpenTabLookup {
    private let tabs: [String: SafariTab]

    init(_ tabs: [SafariTab]) {
        self.tabs = Dictionary(tabs.compactMap { tab -> (String, SafariTab)? in
            guard let key = HistoryIdentity.url(tab.url) else { return nil }
            return (key, tab)
        }, uniquingKeysWith: { first, _ in first })
    }

    func tab(for key: String) -> SafariTab? { tabs[key] }
}

enum SearchResultBuilder {
    static func rows(query: String, matches: [TabSearchIndex.Match], allTabs: [SafariTab],
                     history: HistorySearchIndex, suggestions: [String], now: Date,
                     openTabs: OpenTabLookup? = nil, previousTab: SafariTab? = nil,
                     activeTab: SafariTab? = nil, context: RankingContext = RankingContext()) -> [SearchRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [SearchRow] = []
        // The tab on screen is never a destination. With empty input, Enter returns to the previously
        // viewed tab, the other open tabs follow it, and the new-tab action comes after all of them.
        let previous = query.isEmpty ? previousTab : nil
        var context = context
        context.activeTab = activeTab
        let ranked = TabRanker.rank(typed: !query.isEmpty, matches: matches, allTabs: allTabs, history: history,
                                    context: context, now: now)
            .filter { $0.tab != previous && $0.tab != activeTab }
        let tabs = ranked.map(\.tab)
        if let previous { rows.append(.previousTab(previous)) }
        // A guess from a typo or initials is offered, but Enter keeps meaning the typed text.
        let typedFirst = !query.isEmpty && ranked.first.map { !TabRanker.isConfident($0.features) } == true
        if typedFirst { rows.append(.newTab(NewTabDestination.from(query))) }
        rows += tabs.map(SearchRow.tab)
        if query.isEmpty { rows.append(.newTab(.defaultPage)) }
        let recent = history.recentSearches(query: query, now: now)
        if !recent.isEmpty {
            rows.append(.section(.recent))
            rows += recent.map(SearchRow.recentSearch)
        }
        var seenURLs = Set(tabs.compactMap { HistoryIdentity.url($0.url) })
        let openByURL = openTabs ?? OpenTabLookup(allTabs)
        let browsing = history.browsingMatches(query: query, now: now).compactMap { visit -> SearchRow? in
            guard let key = HistoryIdentity.url(visit.url) else { return nil }
            guard seenURLs.insert(key).inserted else { return nil }
            if let open = openByURL.tab(for: key) { return open == activeTab ? nil : .tab(open) }
            return .history(visit)
        }
        if !browsing.isEmpty {
            rows.append(.section(.history))
            rows += browsing
        }
        if !query.isEmpty && !typedFirst { rows.append(.newTab(NewTabDestination.from(query))) }
        var seenQueries = Set(recent.map { HistoryIdentity.query($0.query) })
        seenQueries.insert(HistoryIdentity.query(query))
        let remote = suggestions.compactMap { suggestion -> SearchRow? in
            guard seenQueries.insert(HistoryIdentity.query(suggestion)).inserted else { return nil }
            return .suggestion(suggestion)
        }
        if !query.isEmpty && !remote.isEmpty {
            rows.append(.section(.google))
            rows += remote.prefix(8)
        }
        return rows
    }
}
