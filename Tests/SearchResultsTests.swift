import Foundation

@main
struct SearchResultsTests {
    static func main() {
        let selected = SafariTab(windowID: 8, index: 5, title: "Selected", url: "https://example.com/a")
        let moved = SafariTab(windowID: 8, index: 4, title: "Selected", url: "https://example.com/a")
        let otherWindow = SafariTab(windowID: 9, index: 4, title: "Selected", url: "https://example.com/a")
        let another = SafariTab(windowID: 8, index: 3, title: "Other", url: "https://example.com/b")
        let duplicate = SafariTab(windowID: 8, index: 6, title: "Selected", url: "https://example.com/a")
        let command = SearchRow.newTab(.search("example"))
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(another), .tab(moved), command]) == 1, "A moved tab retains selection after background refresh")
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(otherWindow), .tab(moved)]) == 1, "Matching tabs in other windows cannot steal selection")
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(moved), .tab(duplicate)]) == nil, "Ambiguous duplicate tabs are not guessed")
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(duplicate), .tab(selected)]) == 1, "An exact row retains priority over similar duplicates")
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: [.tab(another), command]) == nil, "Closed tabs are not retained")
        precondition(SearchRow.retainedSelection(of: command, in: [.tab(moved), command]) == 1, "A selected new-tab action remains selected")
        precondition(SearchRow.retainedSelection(of: command, in: [.newTab(.search("changed"))]) == nil, "A changed query does not retain an unrelated action")
        precondition(SearchRow.retainedSelection(of: .tab(selected), in: []) == nil, "Empty inventory has no retained selection")
        print("Passed 8 selection-retention checks")
    }
}
