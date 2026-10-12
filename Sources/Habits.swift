import Foundation

/// Which sites tend to follow which, and which sites are used at which hours of the week.
/// Learned from tabs that stayed on screen for a few seconds; glances while flicking through tabs do not count.
struct Habits: Codable, Equatable {
    /// Counts that fade together. Shares within a row are unaffected by fading, so only totals need it.
    struct Row: Codable, Equatable {
        var counts: [String: Double] = [:]
        var updated: Date

        func total(now: Date) -> Double { counts.values.reduce(0, +) * Habits.fade(since: updated, now: now) }

        mutating func add(_ key: String, now: Date, limit: Int) {
            let factor = Habits.fade(since: updated, now: now)
            if factor < 1 { counts = counts.mapValues { $0 * factor } }
            updated = max(updated, now)
            counts[key, default: 0] += 1
            if counts.count > limit, let faintest = counts.min(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
                counts[faintest] = nil
            }
        }
    }

    static let halfLife: TimeInterval = 21 * 24 * 60 * 60
    /// Shorter visits are glances.
    static let shortestVisit: TimeInterval = 3
    /// A longer gap between two visits, such as Safari in the background, is not one step to the next.
    static let longestGap: TimeInterval = 10 * 60
    static let siteLimit = 200
    static let followerLimit = 20

    /// Site → the sites that followed it.
    private(set) var transitions: [String: Row] = [:]
    /// Site → visits per hour of the week, keyed by `slot`. "all" holds the visits to every site.
    private(set) var hours: [String: Row] = [:]
    private var previous: (site: String, end: Date)?

    private enum CodingKeys: String, CodingKey { case transitions, hours }

    static func == (a: Habits, b: Habits) -> Bool { a.transitions == b.transitions && a.hours == b.hours }

    static func fade(since: Date, now: Date) -> Double { pow(0.5, max(0, now.timeIntervalSince(since)) / halfLife) }

    static func site(_ url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased(), !host.isEmpty,
              HistoryIdentity.url(url) != nil else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Weekdays and weekends have separate hours: "weekday 9" or "weekend 21".
    static func slot(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        let weekend = parts.weekday == 1 || parts.weekday == 7
        return (weekend ? "weekend " : "weekday ") + String(parts.hour ?? 0)
    }

    mutating func record(_ visit: FocusVisit, calendar: Calendar) {
        guard visit.duration >= Self.shortestVisit, let site = Self.site(visit.tab.url) else { return }
        let end = visit.start.addingTimeInterval(visit.duration)
        if let previous, previous.site != site, visit.start.timeIntervalSince(previous.end) <= Self.longestGap {
            Self.add(site, to: previous.site, in: &transitions, now: end, limit: Self.followerLimit, sites: Self.siteLimit)
        }
        previous = (site, end)
        let slot = Self.slot(visit.start, calendar: calendar)
        Self.add(slot, to: site, in: &hours, now: end, limit: 48, sites: Self.siteLimit + 1)
        Self.add(slot, to: "all", in: &hours, now: end, limit: 48, sites: Self.siteLimit + 1)
    }

    private static func add(_ key: String, to site: String, in rows: inout [String: Row], now: Date, limit: Int, sites: Int) {
        rows[site, default: Row(updated: now)].add(key, now: now, limit: limit)
        if rows.count > sites,
           let faintest = rows.filter({ $0.key != "all" }).min(by: { ($0.value.total(now: now), $1.key) < ($1.value.total(now: now), $0.key) })?.key {
            rows[faintest] = nil
        }
    }

    /// How likely `site` comes next after `from`, between 0 and 1, discounted until a few steps were seen.
    func transition(from: String, to site: String, now: Date) -> Double {
        guard from != site, let row = transitions[from], let count = row.counts[site] else { return 0 }
        let total = row.counts.values.reduce(0, +)
        return count / total * (1 - exp(-row.total(now: now) / 3))
    }

    /// How much more `site` is used around this hour than usual, between 0 and 1: zero for a site used
    /// evenly through the week, one for a site used three times as much as usual or more.
    func timeOfDay(site: String, at date: Date, calendar: Calendar, now: Date) -> Double {
        guard let row = hours[site], let all = hours["all"] else { return 0 }
        let hour = calendar.component(.hour, from: date)
        let prefix = Self.slot(date, calendar: calendar).hasPrefix("weekend") ? "weekend " : "weekday "
        let nearby = [-1, 0, 1].map { prefix + String((hour + $0 + 24) % 24) }
        let here = nearby.reduce(0) { $0 + (row.counts[$1] ?? 0) }
        let allHere = nearby.reduce(0) { $0 + (all.counts[$1] ?? 0) }
        let siteTotal = row.counts.values.reduce(0, +)
        let allTotal = all.counts.values.reduce(0, +)
        guard here > 0, allHere > 0, siteTotal > 0, allTotal > 0 else { return 0 }
        let lift = (here / allHere) / (siteTotal / allTotal)
        let confidence = 1 - exp(-here * Self.fade(since: row.updated, now: now) / 3)
        return min(1, max(0, (lift - 1) / 2)) * confidence
    }
}
