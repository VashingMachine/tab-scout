import Foundation

enum SearchRow: Equatable {
    case tab(SafariTab)
    case newTab(NewTabDestination)

    static func retainedSelection(of previous: SearchRow, in rows: [SearchRow]) -> Int? {
        if let exact = rows.firstIndex(of: previous) { return exact }
        guard case .tab(let selected) = previous else { return nil }
        let candidates = rows.indices.filter { index in
            guard case .tab(let tab) = rows[index] else { return false }
            return tab.windowID == selected.windowID && tab.title == selected.title && tab.url == selected.url
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
