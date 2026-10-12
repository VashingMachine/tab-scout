import Foundation

/// One stretch of time a tab stayed on screen while Safari was in front.
struct FocusVisit: Equatable {
    let tab: SafariTab
    let start: Date
    let duration: TimeInterval
    /// The tab that came on screen next, or nil when Safari went to the background.
    let next: SafariTab?
}

/// Turns observations of the tab on screen into completed visits. A tab is the same while it keeps
/// its window and URL; a changing title (unread counts, timers) does not end a visit.
struct FocusTracker {
    /// Longer stretches are capped: the person probably walked away.
    static let longestVisit: TimeInterval = 10 * 60
    private(set) var current: SafariTab?
    private var since: Date?

    /// Records the tab now on screen and returns the visit that just ended, if the tab changed.
    mutating func observe(_ tab: SafariTab?, at date: Date) -> FocusVisit? {
        if let tab, let current, tab.windowID == current.windowID, tab.url == current.url {
            self.current = tab
            if since == nil { since = date }
            return nil
        }
        let ended = finish(at: date, next: tab)
        current = tab
        since = tab == nil ? nil : date
        return ended
    }

    /// Safari went to the background: the visit ends, and the next observation starts a new one.
    mutating func pause(at date: Date) -> FocusVisit? {
        let ended = finish(at: date, next: nil)
        since = nil
        return ended
    }

    private func finish(at date: Date, next: SafariTab?) -> FocusVisit? {
        guard let current, let since else { return nil }
        return FocusVisit(tab: current, start: since,
                          duration: min(Self.longestVisit, max(0, date.timeIntervalSince(since))), next: next)
    }
}

/// How long each page was read, fading over two weeks.
struct Engagement: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let url: String
        var seconds: Double
        var lastSeen: Date
    }

    static let limit = 1_000
    static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    /// Five minutes of reading gives about two thirds strength.
    static let scale: TimeInterval = 5 * 60

    private(set) var entries: [String: Entry] = [:]

    static func decayed(_ entry: Entry, now: Date) -> Double {
        entry.seconds * pow(0.5, max(0, now.timeIntervalSince(entry.lastSeen)) / halfLife)
    }

    mutating func record(_ visit: FocusVisit, now: Date) {
        guard visit.duration > 0, let url = HistoryIdentity.url(visit.tab.url) else { return }
        let previous = entries[url].map { Self.decayed($0, now: now) } ?? 0
        entries[url] = Entry(url: url, seconds: previous + visit.duration, lastSeen: now)
        if entries.count > Self.limit {
            let keep = entries.values.sorted { Self.decayed($0, now: now) > Self.decayed($1, now: now) }.prefix(Self.limit)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.url, $0) })
        }
    }

    /// Between 0 and 1 for a normalized URL.
    func strength(url: String, now: Date) -> Double {
        guard let entry = entries[url] else { return 0 }
        return 1 - exp(-Self.decayed(entry, now: now) / Self.scale)
    }
}
