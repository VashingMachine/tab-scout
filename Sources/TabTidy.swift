import Foundation

/// When each open page was first seen open and last on screen, by browser and address, so `sweep` can tell the
/// tabs nobody returned to. A page opened in the background and never viewed counts from when it was first seen.
struct TabSightings: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var firstOpen: Date
        var lastViewed: Date?
        /// The page was open before its browser's tabs were first noted, so nobody knows since when.
        var alreadyOpen = false
    }

    static let limit = 2_000
    private(set) var entries: [String: Entry] = [:]
    /// The browsers whose tabs have been noted at least once.
    private(set) var known: Set<String> = []

    /// Web pages only; a browser's own pages are neither tracked nor swept.
    static func key(_ tab: BrowserTab) -> String? {
        HistoryIdentity.url(tab.url).map { tab.browser.rawValue + " " + $0 }
    }

    /// Notes the pages `browser` has open: one seen for the first time starts its clock, and one no longer open is
    /// forgotten. Returns whether anything changed.
    mutating func note(open tabs: [BrowserTab], in browser: Browser, at date: Date) -> Bool {
        let open = Set(tabs.compactMap(Self.key))
        let own = browser.rawValue + " "
        var changed = false
        for key in Array(entries.keys) where key.hasPrefix(own) && !open.contains(key) {
            entries[key] = nil
            changed = true
        }
        // The pages found open the first time were opened nobody knows when.
        let alreadyOpen = known.insert(browser.rawValue).inserted
        for key in open where entries[key] == nil && entries.count < Self.limit {
            entries[key] = Entry(firstOpen: date, lastViewed: nil, alreadyOpen: alreadyOpen)
            changed = true
        }
        return changed || alreadyOpen
    }

    mutating func view(_ tab: BrowserTab, at date: Date) {
        guard let key = Self.key(tab) else { return }
        if entries[key] != nil {
            entries[key]?.lastViewed = date
        } else if entries.count < Self.limit {
            entries[key] = Entry(firstOpen: date, lastViewed: date)
        }
    }

    func entry(for tab: BrowserTab) -> Entry? {
        Self.key(tab).flatMap { entries[$0] }
    }

    /// When a tab was last seen, for `sweep`, or nil for a tab without a record. `read` is when its page was last
    /// read according to anything else, which may be long before the tab was noted here. A page opened since
    /// counts from its opening at the earliest: a fresh tab of a page read long ago is not an old tab. A page
    /// already open at the start goes by its last view, and failing that by the start.
    func lastSeen(_ tab: BrowserTab, read: Date?) -> Date? {
        guard let entry = entry(for: tab) else { return nil }
        let viewed = [entry.lastViewed, read].compactMap { $0 }.max() ?? entry.firstOpen
        return entry.alreadyOpen ? viewed : max(viewed, entry.firstOpen)
    }
}

/// Which tabs the tidying commands close, and what the list looks like once they are gone.
enum TabTidy {
    /// The most tabs one command closes, so its request to the browser stays small.
    static let limit = 200

    /// The extra tabs of every page open more than once. Of the tabs showing one address, the one on screen stays,
    /// else the one viewed last, else the first listed.
    static func duplicates(in tabs: [BrowserTab], active: BrowserTab?, recent: [BrowserTab]) -> [BrowserTab] {
        var order: [String] = []
        var groups: [String: [BrowserTab]] = [:]
        for tab in tabs {
            guard let key = HistoryIdentity.url(tab.url) else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(tab)
        }
        let extra = order.flatMap { key -> [BrowserTab] in
            let same = groups[key] ?? []
            guard same.count > 1 else { return [] }
            let kept = same.first { $0 == active } ?? recent.first { same.contains($0) } ?? same[0]
            return same.filter { $0 != kept }
        }
        return Array(extra.prefix(limit))
    }

    /// The tabs last seen more than `days` ago, never the one on screen. A tab with no record stays: it may have
    /// been opened a moment ago.
    static func stale(in tabs: [BrowserTab], active: BrowserTab?, days: Int, now: Date,
                      lastSeen: (BrowserTab) -> Date?) -> [BrowserTab] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return Array(tabs.filter { tab in tab != active && (lastSeen(tab).map { $0 < cutoff } ?? false) }.prefix(limit))
    }

    /// `tabs` as the browser lists them once `closed` are gone: the tabs after a closed one move up in their window.
    static func removing(_ closed: [BrowserTab], from tabs: [BrowserTab]) -> [BrowserTab] {
        let gone = Set(closed)
        return tabs.compactMap { tab -> BrowserTab? in
            guard !gone.contains(tab) else { return nil }
            let before = closed.filter { $0.browser == tab.browser && $0.windowID == tab.windowID && $0.index < tab.index }.count
            guard before > 0 else { return tab }
            return BrowserTab(browser: tab.browser, windowID: tab.windowID, index: tab.index - before, title: tab.title, url: tab.url)
        }
    }

    /// Whether a page can be opened in another browser: web pages and files, not a browser's own pages.
    static func canMove(_ url: String) -> Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }
}
