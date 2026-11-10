import Foundation

@main
struct TabTidyTests {
    static var checks = 0
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() throws {
        duplicates()
        stale()
        removing()
        moving()
        try sightings()
        print("Passed \(checks) tab tidying checks")
    }

    static func tab(_ index: Int, _ url: String, window: Int = 1, browser: Browser = .safari) -> BrowserTab {
        BrowserTab(browser: browser, windowID: window, index: index, title: "Tab \(index)", url: url)
    }

    static func duplicates() {
        let mail = tab(1, "https://mail.example/"), again = tab(2, "https://mail.example/"), third = tab(1, "HTTPS://Mail.example:443", window: 2)
        let docs = tab(3, "https://docs.example/a"), other = tab(4, "https://docs.example/a#part"), start = tab(5, ""), empty = tab(6, "")
        let all = [mail, again, docs, other, start, empty, third]
        expect(TabTidy.duplicates(in: all, active: nil, recent: []) == [again, third],
               "Of the tabs showing one page the first stays; another fragment is another page, and empty tabs are left alone")
        expect(TabTidy.duplicates(in: all, active: third, recent: [again]) == [mail, again], "The tab on screen is the one that stays")
        expect(TabTidy.duplicates(in: all, active: docs, recent: [again, mail]) == [mail, third], "Otherwise the one viewed last stays")
        expect(TabTidy.duplicates(in: [mail, docs], active: nil, recent: []).isEmpty, "Pages open once have no duplicates")
        let many = (1...(TabTidy.limit + 50)).map { tab($0, "https://same.example/") }
        expect(TabTidy.duplicates(in: many, active: nil, recent: []).count == TabTidy.limit, "One command closes a bounded number of tabs")
    }

    static func stale() {
        let old = tab(1, "https://old.example/"), fresh = tab(2, "https://fresh.example/"), unknown = tab(3, "https://unknown.example/")
        let shown = tab(4, "https://shown.example/")
        let seen: [BrowserTab: Date] = [old: now.addingTimeInterval(-8 * 86_400), fresh: now.addingTimeInterval(-6 * 86_400),
                                        shown: now.addingTimeInterval(-30 * 86_400)]
        expect(TabTidy.stale(in: [old, fresh, unknown, shown], active: shown, days: 7, now: now) { seen[$0] } == [old],
               "Only tabs seen longer ago than the days allowed go; the one on screen and those without a record stay")
        expect(TabTidy.stale(in: [old, fresh], active: nil, days: 5, now: now) { seen[$0] } == [old, fresh]
               && TabTidy.stale(in: [old, fresh], active: nil, days: 30, now: now) { seen[$0] }.isEmpty, "The days allowed are respected")
    }

    static func removing() {
        let first = [tab(1, "https://a/"), tab(2, "https://b/"), tab(3, "https://c/"), tab(4, "https://d/")]
        let second = [tab(1, "https://e/", window: 2), tab(2, "https://f/", window: 2)]
        let chrome = tab(3, "https://c/", browser: .chrome)
        let left = TabTidy.removing([first[1], first[2], second[0]], from: first + second + [chrome])
        expect(left == [tab(1, "https://a/"), BrowserTab(windowID: 1, index: 2, title: "Tab 4", url: "https://d/"),
                        BrowserTab(windowID: 2, index: 1, title: "Tab 2", url: "https://f/"), chrome],
               "Tabs after a closed one move up in their own window; other windows and browsers keep their places")
        expect(TabTidy.removing([first[0]], from: [first[0]]).isEmpty, "A closed tab is gone")
    }

    static func moving() {
        expect(TabTidy.canMove("https://example.org/a") && TabTidy.canMove("HTTP://example.org") && TabTidy.canMove("file:///Users/me/notes.html"),
               "Web pages and files can open in another browser")
        expect(!TabTidy.canMove("") && !TabTidy.canMove("chrome://settings/") && !TabTidy.canMove("favorites://")
               && !TabTidy.canMove("about:blank") && !TabTidy.canMove("not an address"), "A browser's own pages cannot")
    }

    static func sightings() throws {
        let mail = tab(1, "https://mail.example/"), docs = tab(2, "https://docs.example/"), start = tab(3, "favorites://")
        let chromeMail = tab(1, "https://mail.example/", browser: .chrome)
        var sightings = TabSightings()
        expect(sightings.note(open: [mail, docs, start], in: .safari, at: now), "Pages seen open for the first time are noted")
        expect(sightings.entry(for: mail) == TabSightings.Entry(firstOpen: now, lastViewed: nil, alreadyOpen: true)
               && sightings.entry(for: start) == nil && sightings.entries.count == 2,
               "Pages found open at the start were opened nobody knows when; a browser's own pages are not tracked")
        expect(!sightings.note(open: [docs, mail], in: .safari, at: now.addingTimeInterval(60)), "The same pages again change nothing")
        expect(sightings.entry(for: mail)?.firstOpen == now, "A page keeps the time it was first seen")

        let longAgo = now.addingTimeInterval(-30 * 86_400), later = now.addingTimeInterval(3_600)
        let news = tab(4, "https://news.example/")
        expect(sightings.note(open: [mail, docs, news], in: .safari, at: later)
               && sightings.entry(for: news) == TabSightings.Entry(firstOpen: later, lastViewed: nil), "A page opened since has a known start")
        expect(sightings.lastSeen(mail, read: longAgo) == longAgo && sightings.lastSeen(mail, read: nil) == now,
               "A page open from the start goes by when it was last read, and failing that by the start")
        expect(sightings.lastSeen(news, read: longAgo) == later && sightings.lastSeen(news, read: nil) == later,
               "A page opened since is never older than its opening, however long ago it was read elsewhere")
        expect(sightings.lastSeen(start, read: longAgo) == nil && sightings.lastSeen(chromeMail, read: longAgo) == nil,
               "A tab without a record has no last view, so it is never swept")

        sightings.view(mail, at: later)
        sightings.view(chromeMail, at: later)
        expect(sightings.entry(for: mail) == TabSightings.Entry(firstOpen: now, lastViewed: later, alreadyOpen: true)
               && sightings.entry(for: chromeMail) == TabSightings.Entry(firstOpen: later, lastViewed: later),
               "A view is remembered, per browser, also for a page not listed yet")
        expect(sightings.lastSeen(mail, read: longAgo) == later && sightings.lastSeen(news, read: later.addingTimeInterval(60)) == later.addingTimeInterval(60),
               "The latest view counts, whoever noticed it")
        expect(sightings.note(open: [docs], in: .safari, at: later) && sightings.entry(for: mail) == nil
               && sightings.entry(for: chromeMail) != nil, "A page no longer open in a browser is forgotten there only")

        let decoded = try JSONDecoder().decode(TabSightings.self, from: JSONEncoder().encode(sightings))
        expect(decoded == sightings, "Sightings survive being saved")
        var full = TabSightings()
        _ = full.note(open: (1...(TabSightings.limit + 20)).map { tab($0, "https://site\($0).example/") }, in: .safari, at: now)
        expect(full.entries.count == TabSightings.limit, "The record is bounded")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
}
