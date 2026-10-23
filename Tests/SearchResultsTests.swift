import Foundation

@main
struct SearchResultsTests {
    static func main() {
        let selected = BrowserTab(windowID: 8, index: 5, title: "Selected", url: "https://example.com/a")
        let moved = BrowserTab(windowID: 8, index: 4, title: "Selected", url: "https://example.com/a")
        let otherWindow = BrowserTab(windowID: 9, index: 4, title: "Selected", url: "https://example.com/a")
        let another = BrowserTab(windowID: 8, index: 3, title: "Other", url: "https://example.com/b")
        let duplicate = BrowserTab(windowID: 8, index: 6, title: "Selected", url: "https://example.com/a")
        let command = SearchRow.newTab(.search("example"))
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(another), .tab(moved), command]) == 1, "A moved tab retains selection after background refresh")
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(otherWindow), .tab(moved)]) == 1, "Matching tabs in other windows cannot steal selection")
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(moved), .tab(duplicate)]) == nil, "Ambiguous duplicate tabs are not guessed")
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(duplicate), .tab(selected)]) == 1, "An exact row retains priority over similar duplicates")
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(another), command]) == nil, "Closed tabs are not retained")
        precondition(SearchRow.retainedSelection(of: command, in: [.tab(moved), command]) == 1, "A selected new-tab action remains selected")
        precondition(SearchRow.retainedSelection(of: command, in: [.newTab(.search("changed"))]) == nil, "A changed query does not retain an unrelated action")
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: []) == nil, "Empty inventory has no retained selection")
        let defaultPage = SearchRow.newTab(.defaultPage)
        precondition(defaultPage.destination == .defaultPage, "The empty-query row exposes a distinct native new-tab destination")
        precondition(defaultPage.isSelectable, "The native new-tab action remains actionable")
        precondition(SearchRow.retainedSelection(of: defaultPage, in: [defaultPage, .section(.recent), .tab(moved)]) == 0, "A refreshed tab inventory retains the selected native new-tab action")
        precondition(SearchRow.retainedSelection(of: defaultPage, in: [.newTab(.search("changed"))]) == nil, "Typing a search does not retain the native new-tab action")
        precondition(SearchRow.retainedSelection(of: command, in: [defaultPage]) == nil, "Clearing a query does not retain the old search action")
        print("Passed 13 selection-retention checks")
        let listed: [SearchRow] = [.tab(selected), .tab(another), .section(.history), command, .section(.google), .suggestion("examples")]
        precondition(SearchRow.newTabFirst(.search("example"), in: listed) == [command, .tab(selected), .tab(another), .section(.history), .section(.google), .suggestion("examples")],
                     "Holding Shift moves the typed text's new-tab row to the top without listing it twice")
        precondition(SearchRow.newTabFirst(.url("https://example.com/"), in: [.tab(selected)]) == [.newTab(.url("https://example.com/")), .tab(selected)],
                     "Holding Shift lists a typed address first even where tabs alone matched")
        precondition(SearchRow.newTabFirst(.defaultPage, in: [.previousTab(another), .tab(selected), defaultPage]) == [defaultPage, .previousTab(another), .tab(selected)],
                     "With empty input, holding Shift lists the new-tab page before the previous tab")
        print("Passed 3 new-tab-first checks")
    }
}
