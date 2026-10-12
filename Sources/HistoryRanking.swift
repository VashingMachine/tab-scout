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
        let title: String
        let host: String
        let text: String
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
            VisitEntry(visit: $0, title: TabSearch.normalized($0.title),
                       host: TabSearch.normalized(URL(string: $0.url)?.host ?? ""),
                       text: TabSearch.normalized($0.title + " " + $0.url))
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
        matches.enumerated().map { ($0.offset, $0.element, usageScore(url: $0.element.tab.url, now: now)) }.sorted { a, b in
            if a.1.relevance != b.1.relevance { return a.1.relevance > b.1.relevance }
            return a.2 == b.2 ? a.0 < b.0 : a.2 > b.2
        }.map { $0.1.tab }
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
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return visits.enumerated().compactMap { offset, entry -> (Int, Double, Int, HistoryVisit)? in
            guard tokens.allSatisfy({ entry.text.contains($0) }) else { return nil }
            let match = entry.host == query ? 100 : entry.title == query ? 95 : entry.host.hasPrefix(query) ? 90 : entry.title.hasPrefix(query) ? 85 : entry.title.contains(query) ? 80 : 60
            return (match, HistoryRelevance.score(lastUsed: entry.visit.lastVisited, count: entry.visit.visitCount, now: now), offset, entry.visit)
        }.sorted { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            return a.1 == b.1 ? a.2 < b.2 : a.1 > b.1
        }.prefix(8).map { $0.3 }
    }

    private func usageScore(url: String, now: Date) -> Double {
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
                     activeTab: SafariTab? = nil) -> [SearchRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [SearchRow] = []
        // The tab on screen is never a destination. With empty input, Enter returns to the previously
        // viewed tab, the other open tabs follow it, and the new-tab action comes after all of them.
        let previous = query.isEmpty ? previousTab : nil
        let tabs = history.rankTabs(matches, now: now).filter { $0 != previous && $0 != activeTab }
        if let previous { rows.append(.previousTab(previous)) }
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
        if !query.isEmpty { rows.append(.newTab(NewTabDestination.from(query))) }
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
