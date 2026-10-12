import Foundation

@main
struct FocusTrackingTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var checks = 0

    static func main() {
        visits()
        engagement()
        transitions()
        hours()
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

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 1_800_000_000 is Friday 15 January 2027, 08:00 UTC.
    static func visit(_ url: String, at seconds: TimeInterval, for duration: TimeInterval = 60) -> FocusVisit {
        FocusVisit(tab: tab("Page", url), start: at(seconds), duration: duration, next: nil)
    }

    static func transitions() {
        let mail = "https://mail.example.com/inbox"
        let calendarSite = "https://calendar.example.com/"
        let news = "https://www.news.example.com/"
        var habits = Habits()
        expect(Habits.slot(now, calendar: calendar) == "weekday 8", "The fixture starts on a weekday morning")
        for round in 0..<4 {
            let start = Double(round) * 300
            habits.record(visit(mail, at: start), calendar: calendar)
            habits.record(visit(news, at: start + 61, for: 1), calendar: calendar)
            habits.record(visit(calendarSite, at: start + 62), calendar: calendar)
        }
        let later = at(4 * 300)
        let next = habits.transition(from: "mail.example.com", to: "calendar.example.com", now: later)
        expect(next > 0.6, "A site that keeps following another becomes likely next")
        expect(habits.transition(from: "mail.example.com", to: "news.example.com", now: later) == 0,
               "Glancing at a tab on the way does not count as following")
        expect(habits.transition(from: "calendar.example.com", to: "mail.example.com", now: later) > 0,
               "The return trip across rounds is learned too")
        expect(habits.transition(from: "mail.example.com", to: "mail.example.com", now: later) == 0, "A site never follows itself")
        expect(habits.transition(from: "unknown.example.com", to: "mail.example.com", now: later) == 0, "Unknown sites predict nothing")
        expect(habits.transition(from: "mail.example.com", to: "calendar.example.com", now: later.addingTimeInterval(60 * 86_400)) < next,
               "Unrefreshed habits lose confidence")

        var gap = Habits()
        gap.record(visit(mail, at: 0), calendar: calendar)
        gap.record(visit(calendarSite, at: 60 + Habits.longestGap + 1), calendar: calendar)
        expect(gap.transition(from: "mail.example.com", to: "calendar.example.com", now: at(3_600)) == 0,
               "A long break between two visits is not a step from one to the other")
        var once = Habits()
        once.record(visit(mail, at: 0), calendar: calendar)
        once.record(visit(calendarSite, at: 61), calendar: calendar)
        expect(once.transition(from: "mail.example.com", to: "calendar.example.com", now: at(200)) < 0.3,
               "One step is weak evidence")
        expect(Habits.site("https://WWW.Example.com/a") == "example.com" && Habits.site("about:blank") == nil,
               "Sites ignore case and www., and only web pages count")

        var bounded = Habits()
        for index in 0..<(Habits.siteLimit + 10) {
            bounded.record(visit("https://site\(index).example.com/", at: Double(index) * 10, for: 5), calendar: calendar)
        }
        expect(bounded.transitions.count <= Habits.siteLimit && bounded.hours.count <= Habits.siteLimit + 1,
               "Memory is bounded")
        expect(bounded.transitions.values.allSatisfy { $0.counts.count <= Habits.followerLimit }, "Followers are bounded")
    }

    static func hours() {
        var habits = Habits()
        // Six weekday mornings, Friday and then Monday to Friday: a standup page at 9, mail and news all day.
        for day in [0, 3, 4, 5, 6, 7] {
            let morning = Double(day) * 86_400 + 3_600
            habits.record(visit("https://standup.example.com/", at: morning, for: 120), calendar: calendar)
            for hour in 0..<10 {
                habits.record(visit("https://mail.example.com/", at: morning + Double(hour) * 3_600 + 600), calendar: calendar)
                habits.record(visit("https://news.example.com/", at: morning + Double(hour) * 3_600 + 1_200), calendar: calendar)
            }
        }
        let monday = 10 * 86_400.0
        let nine = at(monday + 3_600)
        expect(Habits.slot(at(3_600), calendar: calendar) == "weekday 9" && Habits.slot(at(86_400), calendar: calendar) == "weekend 8",
               "Weekday and weekend hours are separate slots")
        let standup = habits.timeOfDay(site: "standup.example.com", at: nine, calendar: calendar, now: nine)
        expect(standup > 0.8, "A site used at one hour stands out at that hour")
        expect(habits.timeOfDay(site: "standup.example.com", at: at(monday + 2 * 3_600), calendar: calendar, now: nine) > 0.5,
               "Neighbouring hours count too")
        expect(habits.timeOfDay(site: "standup.example.com", at: at(monday + 8 * 3_600), calendar: calendar, now: nine) == 0,
               "Outside its hours the site gets no boost")
        expect(habits.timeOfDay(site: "standup.example.com", at: at(monday - 86_400 + 3_600), calendar: calendar, now: nine) == 0,
               "A weekday habit gives no boost at the weekend")
        expect(habits.timeOfDay(site: "mail.example.com", at: at(monday + 4 * 3_600), calendar: calendar, now: nine) < 0.2,
               "A site used evenly through the day is not tied to an hour")
        expect(habits.timeOfDay(site: "unknown.example.com", at: nine, calendar: calendar, now: nine) == 0,
               "Unknown sites get no boost")
        let saved = try! JSONDecoder().decode(Habits.self, from: JSONEncoder().encode(habits))
        expect(saved == habits && saved.timeOfDay(site: "standup.example.com", at: nine, calendar: calendar, now: nine) == standup,
               "Habits survive saving")
    }
}
