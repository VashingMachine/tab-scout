import Foundation

@main
struct TabFocusHistoryTests {
    static var checks = 0

    static func main() {
        toggling()
        manualSwitches()
        changingTabs()
        bounds()
        ordering()
        browsers()
        print("Passed \(checks) tab focus history checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func tab(_ title: String, _ url: String, window: Int = 1, index: Int = 1) -> BrowserTab {
        BrowserTab(windowID: window, index: index, title: title, url: url)
    }

    static func browsers() {
        let safari = tab("Docs", "https://docs.example/")
        let chrome = BrowserTab(browser: .chrome, windowID: 1, index: 1, title: "Docs", url: "https://docs.example/")
        var history = TabFocusHistory()
        history.focus(safari)
        history.focus(chrome)
        expect(history.tabs == [chrome, safari], "The same page in two browsers is two tabs")
        expect(history.previous(active: chrome, in: [safari, chrome]) == safari, "Cmd+T, Enter flips between browsers")
        history.forget(.chrome)
        expect(history.tabs == [safari], "A browser that quit is forgotten")
    }

    static func toggling() {
        let a = tab("A", "https://example.com/a")
        let b = tab("B", "https://example.com/b", index: 2)
        let c = tab("C", "https://example.com/c", index: 3)
        let open = [a, b, c]
        var history = TabFocusHistory()
        expect(history.previous(active: a, in: open) == nil, "A fresh history offers no previous tab")
        history.focus(a)
        expect(history.previous(active: a, in: open) == nil, "The tab on screen is never its own previous tab")
        history.focus(c)
        expect(history.previous(active: c, in: open) == a, "Switching tabs makes the starting tab previous")
        history.focus(a)
        expect(history.previous(active: a, in: open) == c, "Returning makes the other tab previous again")
        history.focus(c)
        expect(history.previous(active: c, in: open) == a, "Repeated returns keep toggling between two tabs")
        expect(history.tabs == [c, a], "Refocusing a tab moves it to the front without duplicates")
        history.focus(c)
        expect(history.tabs == [c, a], "Seeing the same tab again changes nothing")
    }

    static func manualSwitches() {
        let a = tab("A", "https://example.com/a")
        let b = tab("B", "https://example.com/b", index: 2)
        let c = tab("C", "https://example.com/c", index: 3)
        let other = tab("Other window", "https://example.com/other", window: 2)
        var history = TabFocusHistory()
        for item in [a, b, c] { history.focus(item) }
        expect(history.previous(active: c, in: [a, b, c]) == b, "The most recently viewed tab wins, not the first one")
        expect(history.previous(active: c, in: [a, c]) == a, "A closed previous tab falls back to the one before it")
        expect(history.previous(active: a, in: [a]) == nil, "No previous tab remains when everything else closed")
        history.focus(other)
        expect(history.previous(active: other, in: [a, b, c, other]) == c, "The previous tab may be in another window")
        expect(history.previous(active: nil, in: [a, b, c, other]) == other, "Without a known active tab the latest open tab is offered")
    }

    static func changingTabs() {
        let mail = tab("Inbox (3)", "https://mail.example.com/", index: 4)
        let docs = tab("Docs", "https://docs.example.com/", index: 5)
        var history = TabFocusHistory()
        history.focus(mail)
        history.focus(docs)
        let unread = tab("Inbox (4)", mail.url, index: 4)
        expect(history.previous(active: docs, in: [unread, docs]) == unread, "A background title change keeps the tab recognizable")
        let moved = tab(mail.title, mail.url, index: 2)
        let movedDocs = tab(docs.title, docs.url, index: 3)
        expect(history.previous(active: movedDocs, in: [moved, movedDocs]) == moved, "Closing an earlier tab does not lose the previous tab")
        expect(history.previous(active: docs, in: [tab("Inbox (3)", mail.url, window: 2, index: 4), docs]) == nil,
               "The same page in another window is a different tab")
        expect(history.previous(active: docs, in: [tab(mail.title, "https://mail.example.com/message", index: 4), docs]) == nil,
               "A tab that navigated elsewhere no longer counts as the previous page")

        let twin = tab(mail.title, mail.url, index: 7)
        expect(history.previous(active: docs, in: [twin, mail, docs]) == mail, "Among duplicate pages the remembered position wins")
        expect(history.previous(active: docs, in: [unread, tab("Inbox (3)", mail.url, index: 6), docs])?.index == 6,
               "Among duplicate pages a matching title beats a matching position")

        var retitled = TabFocusHistory()
        retitled.focus(docs)
        retitled.focus(mail)
        expect(retitled.previous(active: unread, in: [unread, docs]) == docs,
               "A stale entry for the on-screen tab is skipped after its title changes")
    }

    static func bounds() {
        var history = TabFocusHistory(limit: 3)
        let tabs = (1...5).map { tab("Tab \($0)", "https://example.com/\($0)", index: $0) }
        for item in tabs { history.focus(item) }
        expect(history.tabs == Array(tabs.suffix(3).reversed()), "The history keeps only the most recent tabs")
        expect(history.previous(active: tabs[4], in: tabs) == tabs[3], "Bounding keeps the latest previous tab")
    }

    static func ordering() {
        let a = tab("A", "https://example.com/a")
        let b = tab("B", "https://example.com/b", index: 2)
        let c = tab("C", "https://example.com/c", index: 3)
        let d = tab("D", "https://example.com/d", index: 4)
        var history = TabFocusHistory()
        expect(history.order(in: [a, b, c]).isEmpty, "Nothing viewed yet means no recency order")
        for item in [a, b, c, b] { history.focus(item) }
        expect(history.order(in: [a, b, c, d]) == [b, c, a], "Open tabs are listed most recently viewed first, never twice")
        expect(history.order(in: [a, c, d]) == [c, a], "Closed tabs drop out of the order")
        let retitled = tab("C (1)", c.url, index: 3)
        expect(history.order(in: [a, b, retitled]) == [b, retitled, a], "A retitled tab keeps its place, as it appears now")
        history.focus(retitled)
        expect(history.order(in: [a, b, retitled]) == [retitled, b, a],
               "A stale entry and a fresh one for the same tab collapse into one position")
    }
}
