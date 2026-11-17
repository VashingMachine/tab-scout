import Foundation

@main
struct CoreTests {
    static var checks = 0
    static func main() throws {
        let a = BrowserTab(windowID: 9, index: 1, title: "GitHub - Code", url: "https://github.com/acme/code")
        let b = BrowserTab(windowID: 10, index: 2, title: "GitHub documentation", url: "https://docs.example.org/github")
        let c = BrowserTab(windowID: 10, index: 3, title: "Zażółć gęślą", url: "https://example.org/polish")
        let tabs = [b, a, c]
        expect(TabSearch.results(tabs, query: "github").first == a, "Prefer a matching site host")
        expect(TabSearch.results(tabs, query: "  GITHUB  code ") == [a], "Case-insensitive multiword matching")
        expect(TabSearch.results(tabs, query: "zazolc") == [c], "Diacritics match")
        expect(TabSearch.results(tabs, query: "acme/code") == [a], "Search URL paths")
        expect(TabSearch.results(tabs, query: "missing").isEmpty, "No unrelated fuzzy matches")
        expect(TabSearch.results(tabs, query: "") == tabs, "Stable order for an empty query")
        smartMatching()

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
        expect(["", "about:blank", "favorites://"].allSatisfy { tab("Start Page", $0).isBlank }, "Start Page and empty pages are blank tabs")
        expect(!tab("Example", "https://example.org/").isBlank && !tab("", "bookmarks://").isBlank, "A loaded page is not a blank tab")

        let data = Data("[[9,1,\"A \\\"quote\\\" \\n title\",\"https://example.com/a?x=1&y=2\",true]]".utf8)
        let decoded = try TabInventory.decode(data)
        expect(decoded.tabs[0].title == "A \"quote\" \n title", "Decode escaped tab titles")
        expect(decoded.tabs[0].windowID == 9, "Preserve Safari window IDs")
        expect(decoded.active == decoded.tabs[0], "Decode the current tab marker")
        let windows = try TabInventory.decode(Data("[[1,1,\"A\",\"a\",false],[1,2,\"B\",\"b\",true],[2,1,\"C\",\"c\",true]]".utf8))
        expect(windows.active == BrowserTab(windowID: 1, index: 2, title: "B", url: "b"), "The first window's current tab is active")
        try expect(TabInventory.decode(Data("[[1,1,\"A\",\"a\",false]]".utf8)).active == nil, "No marked tab means no active tab")
        for invalid in ["[[1,2,3,4,true]]", "[[1,2,\"A\",\"a\"]]", "[[1,2,\"A\",\"a\",1]]", "[[1,2,\"A\",\"a\",\"true\"]]", "[[true,2,\"A\",\"a\",true]]"] {
            do { _ = try TabInventory.decode(Data(invalid.utf8)); fatalError("Invalid rows must fail: \(invalid)") } catch { }
        }
        try expect(TabInventory.decode(Data("[]".utf8)) == TabInventory(tabs: []), "Empty Safari session")

        try browsers()
        ownPages()
        expect(capture(), "Capture Safari Cmd+T")
        expect(!capture(browser: false), "Leave other apps' Cmd+T alone")
        expect(!capture(shift: true), "Preserve Safari reopen-tab shortcut")
        expect(!capture(option: true), "Preserve modified shortcuts")
        expect(!capture(enabled: false), "Pause restores normal Cmd+T")
        expect(!capture(code: 16), "Leave other keys alone")
        print("Passed \(checks) core checks")
    }

    /// Firefox's own pages, such as about:config, and the browsers built on it.
    static func ownPages() {
        for browser in [Browser.firefox, .zen] {
            expect(NewTabDestination.from(" about:config ", in: browser) == .url("about:config"), "One of \(browser.name)'s own pages is an address there")
            expect(NewTabDestination.from("about:", in: browser) == .url("about:") && NewTabDestination.from("About:Preferences#privacy", in: browser) == .url("About:Preferences#privacy"),
                   "The address goes as it was typed, also unfinished and at a part of a page")
            expect(NewTabDestination.from("about: time", in: browser) == .search("about: time") && NewTabDestination.from("about", in: browser) == .search("about")
                   && NewTabDestination.from("javascript:alert(1)", in: browser) == .search("javascript:alert(1)")
                   && NewTabDestination.from("file:///etc/passwd", in: browser) == .search("file:///etc/passwd")
                   && NewTabDestination.from("chrome://settings", in: browser) == .search("chrome://settings"),
                   "Words after the colon, the word alone and other schemes stay search text")
            expect(NewTabDestination.from("example.com/docs", in: browser) == .url("https://example.com/docs") && NewTabDestination.from("", in: browser) == .defaultPage,
                   "Web addresses and empty input mean what they mean everywhere")
        }
        for browser in [Browser.safari, .chrome] {
            expect(NewTabDestination.from("about:config", in: browser) == .search("about:config") && BrowserPage.suggestions(for: "about:", in: browser) == nil
                   && browser.pages.isEmpty, "\(browser.name) has no pages of its own to open, so the text is searched")
        }
        let names = { (typed: String, browser: Browser) in BrowserPage.suggestions(for: typed, in: browser)?.map(\.url) }
        expect(names("about:", .firefox)?.count == 45 && names("about:", .firefox)?.prefix(3) == ["about:config", "about:preferences", "about:addons"],
               "\"about:\" alone lists every page, the ones for settings first")
        expect(Set(names("about:", .firefox) ?? []).count == 45 && Browser.firefox.pages.allSatisfy { $0.url == $0.url.lowercased() && !$0.title.isEmpty },
               "No page is listed twice, and each has a lowercase address and a title")
        expect(names(" ABOUT: ", .zen) == names("about:", .firefox)?.filter { $0 != "about:crashes" }, "Zen has Firefox's pages but for the crash reports, in any case of letters")
        expect(names("about:config", .zen) == ["about:config", "about:buildconfig"], "The page of the typed name comes first, then those whose name contains it")
        expect(names("about:c", .zen)?.prefix(4) == ["about:config", "about:cache", "about:certificate", "about:compat"],
               "Names beginning with the text come in the list's order")
        expect(names("about:log", .zen) == ["about:logins", "about:logging", "about:loginsimportreport", "about:logo", "about:sync-log"],
               "Names containing the text follow those beginning with it")
        expect(names("about:pass", .zen) == ["about:logins", "about:webauthn", "about:loginsimportreport"] && names("about:settings", .zen) == ["about:preferences", "about:profiling"]
               && names("about:ext", .zen) == ["about:addons", "about:debugging"], "A word of a page's title finds it too")
        expect(names("about:pro", .zen) == ["about:profiles", "about:protections", "about:processes", "about:profiling", "about:url-classifier"],
               "Pages found by their title come after those found by their name")
        expect(names("about:nosuchpage", .zen) == [] && names("about config", .zen) == nil && names("config", .zen) == nil,
               "An unknown name finds no page, and text that is no such address is not about pages at all")
        expect(names("about:preferences#privacy", .zen) == ["about:preferences"] && names("about:reader?url=https://example.org/", .zen) == []
               && BrowserPage.namesPart("about:preferences#privacy") && !BrowserPage.namesPart("about:preferences"),
               "Text naming a part of a page finds that page alone")
        let settings = BrowserPage(url: "about:preferences", title: "Settings")
        expect(settings.isShown(at: "about:preferences") && settings.isShown(at: "about:preferences#privacy") && settings.isShown(at: "About:Preferences?x")
               && !settings.isShown(at: "about:preferencesx") && !settings.isShown(at: "https://example.org/about:preferences"),
               "A tab shows a page at its address, also at one of its parts")
    }

    static func browsers() throws {
        expect(Browser(bundleID: "com.google.Chrome") == .chrome && Browser(bundleID: "com.apple.Safari") == .safari
               && Browser(bundleID: "com.tinyspeck.slackmacgap") == nil && Browser(bundleID: nil) == nil,
               "Recognize the supported browsers by bundle identifier")
        let chrome = try TabInventory.decode(Data("[[7,2,\"Mail\",\"https://mail.example/\",true]]".utf8), browser: .chrome)
        let mail = BrowserTab(browser: .chrome, windowID: 7, index: 2, title: "Mail", url: "https://mail.example/")
        expect(chrome.tabs == [mail] && chrome.active == mail, "Chrome's rows decode as Chrome tabs")
        expect(mail != BrowserTab(windowID: 7, index: 2, title: "Mail", url: "https://mail.example/"),
               "The same window and tab numbers in two browsers are different tabs")
        try expect(TabInventory.decodeActive(Data("[7,2,\"Mail\",\"m\"]".utf8), browser: .chrome)?.browser == .chrome,
                   "The Chrome tab on screen is a Chrome tab")
        expect(tab("New Tab", "chrome://newtab/").isBlank, "Chrome's new-tab page is a blank tab")
        expect(Browser(bundleID: "org.mozilla.firefox") == .firefox && Browser(bundleID: "app.zen-browser.zen") == .zen
               && Browser(bundleID: "org.mozilla.firefoxdeveloperedition") == nil,
               "Firefox and Zen are recognized by bundle identifier; other editions are not taken for them")
        expect(Browser.allCases.filter(\.usesExtension) == [.firefox, .zen], "Firefox and Zen are reached through Tab Scout's extension; Safari and Chrome are scripted")
        expect(tab("New Tab", "about:newtab").isBlank && tab("Firefox Home", "about:home").isBlank && !tab("Settings", "about:preferences").isBlank,
               "Firefox's new-tab and home pages are blank tabs; its other pages are not")
        expect(Browser.firefox.searchEngine == "Firefox's default search engine" && Browser.zen.searchEngine == "Zen's default search engine"
               && Browser.chrome.searchEngine == "Google in Chrome", "Firefox and Zen search with their own engine")
        expect(BridgeError.extensionMissing.message(for: .firefox) == "Firefox needs Tab Scout's extension. Add it in Tab Scout's Settings > Setup.",
               "A browser without the extension says what it needs")
        expect(Browser.googleSearch("C++ & rust") == "https://www.google.com/search?q=C%2B%2B%20%26%20rust",
               "Encode a Chrome search so plus signs and ampersands survive")
        expect(Browser.googleSearch("zażółć") == "https://www.google.com/search?q=za%C5%BC%C3%B3%C5%82%C4%87",
               "Encode non-ASCII search text as UTF-8")
        expect(BridgeError.permission.message(for: .chrome) == "Allow Chrome access in System Settings > Privacy & Security > Automation."
               && BridgeError.timeout.message(for: .chrome) == "Chrome took too long to respond. Try again.",
               "Errors name the browser they came from")
        let docs = tab("Docs", "https://docs.example/")
        let merged = TabSearchIndex(merging: [TabSearchIndex([docs]), TabSearchIndex([mail])])
        expect(merged.results(query: "") == [docs, mail] && merged.results(query: "mail") == [mail],
               "A merged index searches every browser's tabs in order")
    }

    static func tab(_ title: String, _ url: String) -> BrowserTab {
        BrowserTab(windowID: 1, index: 1, title: title, url: url)
    }

    static func relevance(_ query: String, _ tab: BrowserTab) -> Int? {
        TabSearchIndex([tab]).matches(query: query).first?.relevance
    }

    static func smartMatching() {
        let gmail = tab("Inbox - Gmail", "https://mail.google.com/mail/u/0/")
        let openAI = tab("OpenAI blog", "https://openai.com/blog")
        let news = tab("AI news today", "https://news.example.com/")
        expect(TabSearch.results([gmail, openAI, news], query: "ai") == [news, openAI, gmail],
               "A match at the start of a word, including a camelCase word, beats one inside a word")
        let github = tab("GitHub - acme/api", "https://github.com/acme/api")
        let ghost = tab("Ghost blog", "https://ghost.org/")
        let hacker = tab("Hacker News", "https://news.ycombinator.com/")
        let dynamo = tab("Amazon DynamoDB - Console", "https://console.aws.amazon.com/dynamodbv2/home")
        let pull = tab("Fix login · Pull Request #4 · acme/api", "https://github.com/acme/api/pull/4")
        expect(TabSearch.results([hacker, github], query: "gh") == [github], "Initials of camelCase words find GitHub")
        expect(TabSearch.results([github, ghost], query: "gh") == [ghost, github],
               "A title that starts with the typed letters still beats initials")
        expect(relevance("hn", hacker) == 75, "Initials of consecutive title words are a strong match")
        expect(TabSearch.results([github, hacker, dynamo], query: "ddb") == [dynamo], "Initials may start mid-title")
        expect(relevance("pr", pull) == 75, "Initials find a pull request")
        expect(relevance("an", tab("Apple Developer News", "https://developer.apple.com/news/")) == 55,
               "Initials that skip a word are a weak match")
        expect(relevance("gh", tab("GitHub", "https://github.com/")) == 75 && relevance("g", github) == 90,
               "A single letter is a prefix, never initials")
        expect(TabSearch.results([github, gmail], query: "githbu") == [github], "A swapped pair of letters is one typo")
        expect(TabSearch.results([dynamo], query: "dynamdb") == [dynamo], "A missing letter is one typo")
        expect(relevance("githbu", github) == 50, "Typo matches rank below every literal match")
        expect(TabSearch.results([tab("Word list", "https://example.com/")], query: "wrod").isEmpty,
               "Words shorter than five letters must be typed exactly")
        expect(TabSearch.results([tab("Documentation", "https://example.com/")], query: "dcoumentatoin").count == 1,
               "Long words tolerate two typos")
        expect(TabSearch.results([github], query: "zzzzzz").isEmpty, "Typo tolerance does not match unrelated words")
        expect(relevance("github", tab("Home", "https://www.github.com/")) == 90, "A leading www. does not hide the site")
        expect(relevance("github acme", github) == 80, "Several typed words found together at word starts")
        expect(relevance("api acme", github) == 65, "Typed words found apart at word starts")
        expect(relevance("ithu", github) == 70, "Typed text inside a title word still matches, below word starts")
        expect(relevance("ub.com", github) == 60, "Typed text inside the address is the weakest literal match")
        expect(TextMatch.words("DBTable for DynamoDB, v2") == ["db", "table", "for", "dynamo", "db", "v2"],
               "Words split at punctuation and camelCase while keeping letters and digits together")
        expect(TextMatch.words("Zażółć gęślą") == ["zazolc", "gesla"], "Words fold diacritics")
        expect(TextMatch.editDistance(Array("abcd"), Array("abdc")[...], limit: 2) == 1, "A transposition is one edit")
        expect(TextMatch.editDistance(Array("abc"), Array("xyz")[...], limit: 1) == 2, "Distances beyond the limit stop early")
        expect(TextMatch.initialsSkipping("gh", in: ["git"]) == nil, "Initials need at least two words")
        let manyWords = (0..<40).map { _ in "aaaa" }
        expect(TextMatch.initialsSkipping("aaaaaaab", in: manyWords) == nil, "Repetitive titles cannot make initials slow")
    }

    static func capture(code: Int64 = 17, shift: Bool = false, option: Bool = false, browser: Bool = true, enabled: Bool = true) -> Bool {
        ShortcutDecision.shouldCapture(keyCode: code, command: true, shift: shift, control: false, option: option, browserActive: browser, enabled: enabled)
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        checks += 1
        if try !condition() { fatalError(message) }
    }
}
