import Foundation

/// Safari tabs in the order they were last on screen, most recent first.
/// Safari exposes no stable tab identifier, so a tab is recognized by its window and URL,
/// preferring the remembered title and index when several tabs share a URL.
struct TabFocusHistory {
    private(set) var tabs: [SafariTab] = []
    let limit: Int

    init(limit: Int = 50) { self.limit = limit }

    mutating func focus(_ tab: SafariTab) {
        tabs.removeAll { $0.windowID == tab.windowID && $0.url == tab.url && $0.title == tab.title }
        tabs.insert(tab, at: 0)
        if tabs.count > limit { tabs.removeLast(tabs.count - limit) }
    }

    /// The most recently focused tab that is still open and is not `active`, as it appears in `openTabs`.
    func previous(active: SafariTab?, in openTabs: [SafariTab]) -> SafariTab? {
        for entry in tabs {
            if let tab = Self.resolve(entry, in: openTabs), tab != active { return tab }
        }
        return nil
    }

    /// Every remembered tab that is still open, as it appears in `openTabs`, most recently viewed first.
    func order(in openTabs: [SafariTab]) -> [SafariTab] {
        var seen = Set<SafariTab>()
        return tabs.compactMap { Self.resolve($0, in: openTabs) }.filter { seen.insert($0).inserted }
    }

    private static func resolve(_ entry: SafariTab, in openTabs: [SafariTab]) -> SafariTab? {
        // A title can change in the background (unread counts, timers); a URL change means the tab navigated away.
        let candidates = openTabs.filter { $0.windowID == entry.windowID && $0.url == entry.url }
        return candidates.first { $0.index == entry.index && $0.title == entry.title }
            ?? candidates.first { $0.title == entry.title }
            ?? candidates.first { $0.index == entry.index }
            ?? candidates.first
    }
}
