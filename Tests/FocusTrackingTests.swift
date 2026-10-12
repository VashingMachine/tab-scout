import Foundation

@main
struct FocusTrackingTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var checks = 0

    static func main() {
        visits()
        engagement()
        print("Passed \(checks) focus tracking checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        // fatalError prints the message in optimized builds too.
        if !condition() { fatalError(message) }
    }

    static func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    static func tab(_ title: String, _ url: String, window: Int = 1, index: Int = 1) -> SafariTab {
        SafariTab(windowID: window, index: index, title: title, url: url)
    }

    static func visits() {
        let mail = tab("Inbox (3)", "https://mail.example.com/")
        let docs = tab("Docs", "https://docs.example.com/", index: 2)
        var tracker = FocusTracker()
        expect(tracker.observe(mail, at: at(0)) == nil, "The first tab seen starts a visit without ending one")
        expect(tracker.observe(tab("Inbox (4)", mail.url), at: at(5)) == nil, "A changing title continues the visit")
        expect(tracker.current?.title == "Inbox (4)", "The visit follows the latest title")
        let switched = tracker.observe(docs, at: at(30))
        expect(switched == FocusVisit(tab: tab("Inbox (4)", mail.url), start: at(0), duration: 30, next: docs),
               "Switching tabs ends the visit, naming the next tab")
        expect(tracker.observe(tab("Docs", docs.url, window: 2), at: at(40))?.duration == 10,
               "The same page in another window is a different tab")
        expect(tracker.pause(at: at(50)) == FocusVisit(tab: tab("Docs", docs.url, window: 2), start: at(40), duration: 10, next: nil),
               "Safari going to the background ends the visit")
        expect(tracker.pause(at: at(60)) == nil, "Pausing twice ends nothing more")
        expect(tracker.observe(tab("Docs", docs.url, window: 2), at: at(100)) == nil,
               "Coming back to the same tab starts a fresh visit")
        expect(tracker.observe(mail, at: at(130))?.duration == 30, "The fresh visit counts only time since returning")
        expect(tracker.observe(docs, at: at(130 + 3_600))?.duration == FocusTracker.longestVisit,
               "A visit left on screen for an hour is capped")
        expect(tracker.observe(docs, at: at(3_740)) == nil, "Seeing the same tab again ends nothing")
        expect(tracker.observe(nil, at: at(3_750))?.duration == 20, "No tab on screen ends the visit")
        expect(tracker.observe(mail, at: at(3_800)) == nil, "After no tab, the next tab only starts a visit")
        expect(tracker.observe(docs, at: at(3_700))?.duration == 0, "A clock moving backwards never gives negative time")
    }

    static func engagement() {
        let page = tab("Docs", "https://Docs.example.com")
        var engagement = Engagement()
        let key = HistoryIdentity.url(page.url)!
        expect(engagement.strength(url: key, now: now) == 0, "Unread pages have no engagement")
        engagement.record(FocusVisit(tab: page, start: now, duration: 300, next: nil), now: now)
        let fiveMinutes = engagement.strength(url: key, now: now)
        expect(abs(fiveMinutes - (1 - exp(-1))) < 0.001, "Five minutes of reading gives about two thirds")
        engagement.record(FocusVisit(tab: page, start: now, duration: 300, next: nil), now: now)
        expect(engagement.strength(url: key, now: now) > fiveMinutes, "Reading time adds up")
        expect(engagement.strength(url: key, now: at(14 * 86_400)) < engagement.strength(url: key, now: now),
               "Reading time fades")
        engagement.record(FocusVisit(tab: tab("Blank", "about:blank"), start: now, duration: 60, next: nil), now: now)
        engagement.record(FocusVisit(tab: tab("Glance", "https://glance.example.com/"), start: now, duration: 0, next: nil), now: now)
        expect(engagement.entries.count == 1, "Pages without a web address or without time are not recorded")
        var bounded = Engagement()
        for index in 0..<(Engagement.limit + 5) {
            bounded.record(FocusVisit(tab: tab("Page", "https://example.com/\(index)"), start: now,
                                      duration: Double(index + 1), next: nil), now: now)
        }
        expect(bounded.entries.count == Engagement.limit && bounded.entries["https://example.com/0"] == nil,
               "Memory is bounded, forgetting the least read pages")
    }
}
