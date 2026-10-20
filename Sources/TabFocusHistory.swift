import Foundation

/// Browser tabs in the order they were last on screen, most recent first, across browsers.
/// Safari exposes no stable tab identifier, so a tab is recognized by its browser, window and URL,
/// preferring the remembered title and index when several tabs share a URL.
struct TabFocusHistory {
    private(set) var tabs: [BrowserTab] = []
    let limit: Int

    init(limit: Int = 50) { self.limit = limit }

    mutating func focus(_ tab: BrowserTab) {
        tabs.removeAll { $0.browser == tab.browser && $0.windowID == tab.windowID && $0.url == tab.url && $0.title == tab.title }
        tabs.insert(tab, at: 0)
        if tabs.count > limit { tabs.removeLast(tabs.count - limit) }
    }

    /// Forgets the tabs of a browser that quit; its window numbers start again when it relaunches.
    mutating func forget(_ browser: Browser) {
        tabs.removeAll { $0.browser == browser }
    }

    /// The most recently focused tab that is still open and is not `active`, as it appears in `openTabs`.
    func previous(active: BrowserTab?, in openTabs: [BrowserTab]) -> BrowserTab? {
        for entry in tabs {
            if let tab = Self.resolve(entry, in: openTabs), tab != active { return tab }
        }
        return nil
    }

    /// Every remembered tab that is still open, as it appears in `openTabs`, most recently viewed first.
    func order(in openTabs: [BrowserTab]) -> [BrowserTab] {
        var seen = Set<BrowserTab>()
        return tabs.compactMap { Self.resolve($0, in: openTabs) }.filter { seen.insert($0).inserted }
    }

    private static func resolve(_ entry: BrowserTab, in openTabs: [BrowserTab]) -> BrowserTab? {
        // A title can change in the background (unread counts, timers); a URL change means the tab navigated away.
        let candidates = openTabs.filter { $0.browser == entry.browser && $0.windowID == entry.windowID && $0.url == entry.url }
        return candidates.first { $0.index == entry.index && $0.title == entry.title }
            ?? candidates.first { $0.title == entry.title }
            ?? candidates.first { $0.index == entry.index }
            ?? candidates.first
    }
}
