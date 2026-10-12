import Foundation

@main
struct CoreTests {
    static var checks = 0
    static func main() throws {
        let a = SafariTab(windowID: 9, index: 1, title: "GitHub - Code", url: "https://github.com/acme/code")
        let b = SafariTab(windowID: 10, index: 2, title: "GitHub documentation", url: "https://docs.example.org/github")
        let c = SafariTab(windowID: 10, index: 3, title: "Zażółć gęślą", url: "https://example.org/polish")
        let tabs = [b, a, c]
        expect(TabSearch.results(tabs, query: "github").first == a, "Prefer a matching site host")
        expect(TabSearch.results(tabs, query: "  GITHUB  code ") == [a], "Case-insensitive multiword matching")
        expect(TabSearch.results(tabs, query: "zazolc") == [c], "Diacritics match")
        expect(TabSearch.results(tabs, query: "acme/code") == [a], "Search URL paths")
        expect(TabSearch.results(tabs, query: "missing").isEmpty, "No unrelated fuzzy matches")
        expect(TabSearch.results(tabs, query: "") == tabs, "Stable order for an empty query")

        expect(NewTabDestination.from(" example.com/docs ") == .url("https://example.com/docs"), "Bare address")
        expect(NewTabDestination.from("localhost:3000") == .url("http://localhost:3000"), "Local development address")
        expect(NewTabDestination.from("127.0.0.1:8080/a") == .url("http://127.0.0.1:8080/a"), "Loopback address")
        expect(NewTabDestination.from("https://example.com?q=x&x=1") == .url("https://example.com?q=x&x=1"), "Preserve URL query")
        expect(NewTabDestination.from("how to bake bread") == .search("how to bake bread"), "Search sentence")
        expect(NewTabDestination.from("Swift") == .search("Swift"), "Search a single word")
        expect(NewTabDestination.from("javascript:alert(1)") == .search("javascript:alert(1)"), "Do not execute arbitrary URL schemes")
        expect(NewTabDestination.from("file:///etc/passwd") == .search("file:///etc/passwd"), "Do not open local files from query input")
        expect(NewTabDestination.from("") == .defaultPage, "Empty query opens Safari's configured new-tab page")
        expect(NewTabDestination.from(" \n\t ") == .defaultPage, "Whitespace-only query opens Safari's configured new-tab page")
        expect(NewTabDestination.from("favorites://") == .search("favorites://"), "Typed Safari internal schemes remain search text")
        expect(NewTabDestination.from("about:blank") == .search("about:blank"), "Typed non-web schemes remain search text")
        expect(NewTabDestination.from("  Swift programming  ") == .search("Swift programming"), "Nonempty search input still trims surrounding whitespace")
        expect(NewTabDestination.from("query \"quoted\"\nsecond line") == .search("query \"quoted\"\nsecond line"), "Preserve quotes and newlines as data")

        let data = Data("[[9,1,\"A \\\"quote\\\" \\n title\",\"https://example.com/a?x=1&y=2\",true]]".utf8)
        let decoded = try TabInventory.decode(data)
        expect(decoded.tabs[0].title == "A \"quote\" \n title", "Decode escaped tab titles")
        expect(decoded.tabs[0].windowID == 9, "Preserve Safari window IDs")
        expect(decoded.active == decoded.tabs[0], "Decode the current tab marker")
        let windows = try TabInventory.decode(Data("[[1,1,\"A\",\"a\",false],[1,2,\"B\",\"b\",true],[2,1,\"C\",\"c\",true]]".utf8))
        expect(windows.active == SafariTab(windowID: 1, index: 2, title: "B", url: "b"), "The first window's current tab is active")
        try expect(TabInventory.decode(Data("[[1,1,\"A\",\"a\",false]]".utf8)).active == nil, "No marked tab means no active tab")
        for invalid in ["[[1,2,3,4,true]]", "[[1,2,\"A\",\"a\"]]", "[[1,2,\"A\",\"a\",1]]", "[[1,2,\"A\",\"a\",\"true\"]]", "[[true,2,\"A\",\"a\",true]]"] {
            do { _ = try TabInventory.decode(Data(invalid.utf8)); fatalError("Invalid rows must fail: \(invalid)") } catch { }
        }
        try expect(TabInventory.decode(Data("[]".utf8)) == TabInventory(tabs: []), "Empty Safari session")

        expect(capture(), "Capture Safari Cmd+T")
        expect(!capture(safari: false), "Leave other apps' Cmd+T alone")
        expect(!capture(shift: true), "Preserve Safari reopen-tab shortcut")
        expect(!capture(option: true), "Preserve modified shortcuts")
        expect(!capture(enabled: false), "Pause restores normal Cmd+T")
        expect(!capture(code: 16), "Leave other keys alone")
        print("Passed \(checks) core checks")
    }

    static func capture(code: Int64 = 17, shift: Bool = false, option: Bool = false, safari: Bool = true, enabled: Bool = true) -> Bool {
        ShortcutDecision.shouldCapture(keyCode: code, command: true, shift: shift, control: false, option: option, safariActive: safari, enabled: enabled)
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        checks += 1
        if try !condition() { fatalError(message) }
    }
}
