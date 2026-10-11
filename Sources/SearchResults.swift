import Foundation

enum SearchRow: Equatable {
    case tab(SafariTab)
    case newTab(NewTabDestination)
    case recentSearch(PastSearch)
    case history(HistoryVisit)
    case suggestion(String)
    case section(SearchSection)

    var isSelectable: Bool {
        if case .section = self { return false }
        return true
    }

    var destination: NewTabDestination? {
        switch self {
        case .tab, .section: return nil
        case .newTab(let destination): return destination
        case .recentSearch(let item): return .search(item.query)
        case .history(let item): return .url(item.url)
        case .suggestion(let query): return .search(query)
        }
    }

    static func retainedSelection(of previous: SearchRow, in rows: [SearchRow]) -> Int? {
        if let exact = rows.firstIndex(of: previous) { return exact }
        let candidates = rows.indices.filter { index in
            switch (previous, rows[index]) {
            case (.tab(let selected), .tab(let tab)):
                return tab.windowID == selected.windowID && tab.title == selected.title && tab.url == selected.url
            case (.recentSearch(let selected), .recentSearch(let item)):
                return HistoryIdentity.query(selected.query) == HistoryIdentity.query(item.query)
            case (.history(let selected), .history(let item)):
                guard let key = HistoryIdentity.url(selected.url) else { return false }
                return key == HistoryIdentity.url(item.url)
            case (.suggestion(let selected), .suggestion(let query)):
                return HistoryIdentity.query(selected) == HistoryIdentity.query(query)
            case (.suggestion(let selected), .recentSearch(let item)):
                return HistoryIdentity.query(selected) == HistoryIdentity.query(item.query)
            case (.recentSearch(let selected), .suggestion(let query)):
                return HistoryIdentity.query(selected.query) == HistoryIdentity.query(query)
            case (.history(let selected), .tab(let tab)):
                guard let key = HistoryIdentity.url(selected.url) else { return false }
                return key == HistoryIdentity.url(tab.url)
            case (.tab(let selected), .history(let item)):
                guard let key = HistoryIdentity.url(selected.url) else { return false }
                return key == HistoryIdentity.url(item.url)
            default: return false
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

enum SearchSection: String {
    case tabs = "Open Tabs"
    case recent = "Recent Searches"
    case history = "History"
    case google = "Google Suggestions"
}

enum ResultNavigation {
    static func first(in rows: [SearchRow]) -> Int? { rows.firstIndex(where: \.isSelectable) }

    static func next(in rows: [SearchRow], from selected: Int, step: Int) -> Int? {
        guard step == 1 || step == -1 else { return nil }
        guard rows.indices.contains(selected) else { return first(in: rows) }
        var candidate = selected + step
        while rows.indices.contains(candidate) {
            if rows[candidate].isSelectable { return candidate }
            candidate += step
        }
        return rows[selected].isSelectable ? selected : first(in: rows)
    }
}
