import Foundation
import SQLite3

/// A SQLite file shaped like a browser's database, kept open so tests can hold Chrome's locks.
final class Database {
    var handle: OpaquePointer?

    init(_ url: URL, _ schema: String...) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        precondition(sqlite3_open(url.path, &handle) == SQLITE_OK)
        schema.forEach(execute)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) {
        precondition(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK, "Fixture SQL failed: \(sql)")
    }

    static func chrome(_ url: URL) -> Database {
        Database(url, "CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL)",
                 "CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL, segment_id INTEGER, visit_duration INTEGER DEFAULT 0 NOT NULL)",
                 "CREATE INDEX visits_time_index ON visits (visit_time)")
    }

    static func firefox(_ url: URL) -> Database {
        Database(url, "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, hidden INTEGER DEFAULT 0 NOT NULL, visit_count INTEGER DEFAULT 0, last_visit_date INTEGER)",
                 "CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER, visit_date INTEGER, visit_type INTEGER, session INTEGER)")
    }

    /// A visit as Firefox notes it: 1 a link followed, 2 an address typed, 5 a redirect, 7 a download, 8 a link in a frame.
    func firefoxVisit(_ id: Int, _ url: String, _ title: String, at date: Date, type: Int = 1, hidden: Bool = false) {
        let time = BrowserHistory.firefoxTime(date)
        execute("INSERT OR IGNORE INTO moz_places (id, url, title, hidden, last_visit_date) VALUES (\(id), '\(url)', '\(title)', \(hidden ? 1 : 0), \(time))")
        execute("INSERT INTO moz_historyvisits (place_id, visit_date, visit_type) VALUES (\(id), \(time), \(type))")
    }

    func visit(_ id: Int, _ url: String, _ title: String, at date: Date, transition: Int64 = 0) {
        let time = BrowserHistory.chromeTime(date)
        execute("INSERT OR IGNORE INTO urls (id, url, title, last_visit_time) VALUES (\(id), '\(url)', '\(title)', \(time))")
        execute("INSERT INTO visits (url, visit_time, transition) VALUES (\(id), \(time), \(transition))")
    }
}

@main
struct BrowserHistoryTests {
    static var checks = 0
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("TabScout-BrowserHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let scratch = home.appendingPathComponent("scratch", isDirectory: true)
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        let safari = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari")
        let fixtures = makeFixtures(home: home, chrome: chrome, safari: safari)

        let history = BrowserHistory(home: home, scratch: scratch)
        let profiles = history.profiles()
        expect(profiles.map(\.id) == ["safari", "safari:AB12-CD", "chrome:Profile 2", "chrome:Default", "chrome:Profile 4",
                                      "firefox:w9.work", "firefox:x1.default-release", "zen:z1.Default (release)"],
               "Find Safari's own profile, its further profiles, Chrome's profiles in Chrome's order, and Firefox's and Zen's as their lists name them")
        expect(profiles.map(\.name) == ["Safari", "Safari – Work", "Chrome – Work", "Chrome – Personal", "Chrome – Broken",
                                        "Firefox – Work stuff", "Firefox – default-release", "Zen – Default (release)"],
               "Profiles carry the names people gave them")
        expect(profiles[3].icons?.lastPathComponent == "Favicons" && profiles[1].icons == nil && profiles[6].icons?.lastPathComponent == "favicons.sqlite",
               "Chrome and Firefox profiles have an icon database; Safari's have none")

        let all = read(history, excluding: [], now: now)
        let pages = Dictionary(uniqueKeysWithValues: all.snapshot.visits.map { ($0.url, $0) })
        expect(pages["https://mail.example/inbox"]?.lastVisited == now.addingTimeInterval(-120)
               && pages["https://mail.example/inbox"]?.visitCount == 2 && pages["https://mail.example/inbox"]?.title == "Inbox",
               "Read Chrome's visits with their times and the page's title")
        expect(pages["https://ads.example/frame"] == nil && pages["https://ads.example/manual"] == nil,
               "Pages loaded inside other pages' frames are left out, whatever their extra transition flags")
        expect(pages["https://redirected.example/"] != nil, "A link with extra transition flags is still a visit")
        expect(pages["https://old.example/"] == nil, "Visits older than Tab Scout keeps history are left out")
        expect(pages["https://shared.example/"]?.visitCount == 2, "A page visited in two profiles counts both visits")
        expect(pages["https://work.example/plan"] != nil && pages["https://work.example/board"] != nil,
               "Read further Safari profiles and further Chrome profiles")
        expect(pages["https://wal.example/"] != nil, "Visits Chrome has not yet moved out of its write-ahead log are read")
        expect(all.snapshot.searches.map(\.query) == ["chrome tabs"], "Google searches in Chrome's history become past searches")
        expect(all.icons["https://mail.example"] == Data("mail32".utf8) && all.icons["https://touch.example"] == nil,
               "Each site gets the icon most of its pages use, closest to 32 pixels, never a touch icon")
        expect(pages["https://fox.example/docs"]?.visitCount == 2 && pages["https://fox.example/docs"]?.title == "Fox Docs"
               && pages["https://fox.example/docs"]?.lastVisited == now.addingTimeInterval(-30),
               "Read Firefox's visits with their times and the page's title")
        expect(pages["https://redirect.example/hop"] == nil && pages["https://frame.example/ad"] == nil
               && pages["https://download.example/file.zip"] == nil && pages["https://old-fox.example/"] == nil,
               "Pages Firefox hides, frames, downloads and visits older than Tab Scout keeps are left out")
        expect(pages["https://fox-wal.example/"] != nil, "Visits Firefox has not yet moved out of its write-ahead log are read")
        expect(pages["https://zen.example/calm"]?.title == "Calm", "Zen's history is read as Firefox's is, from its own folder")
        expect(all.icons["https://fox.example"] == Data("fox32".utf8),
               "A Firefox site gets the icon most of its pages use, in the size closest to 32 pixels, never a drawing without a size")
        expect(all.icons["https://root.example"] == Data("root32".utf8), "A site whose pages name no icon gets the one at its root")
        expect(all.icons.count == 3, "Nothing else becomes an icon")
        expect(all.failed == ["chrome:Profile 4"], "An unreadable profile is reported while the others are read")
        expect(((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).isEmpty,
               "Copies of Chrome's databases are deleted after reading")

        var direct: Error?
        do { try HistoryStore.query(chrome.appendingPathComponent("Default/History"), sql: "SELECT count(*) FROM urls", bind: { _ in }, row: { _ in }) }
        catch { direct = error }
        expect(direct as? HistoryError == .unavailable, "Chrome's lock refuses opening its history directly, as in the real Chrome")
        expect(pages["https://mail.example/inbox"] != nil, "Its history is still read from the copy")

        let withoutDefault = read(history, excluding: ["chrome:Default", "safari:AB12-CD", "firefox:x1.default-release"], now: now)
        let urls = Set(withoutDefault.snapshot.visits.map(\.url))
        expect(!urls.contains("https://mail.example/inbox") && !urls.contains("https://work.example/plan")
               && !urls.contains("https://fox.example/docs") && urls.contains("https://zen.example/calm")
               && urls.contains("https://work.example/board") && withoutDefault.icons.isEmpty,
               "A profile turned off contributes neither pages nor icons")

        fixtures.icons.execute("DELETE FROM icon_mapping")
        expect(read(history, excluding: [], now: now.addingTimeInterval(60)).icons["https://mail.example"] != nil, "Icons are reused for ten minutes")
        expect(read(history, excluding: [], now: now.addingTimeInterval(601)).icons["https://mail.example"] == nil, "Icons are read again after ten minutes")

        let bare = home.appendingPathComponent("bare", isDirectory: true)
        _ = Database.chrome(bare.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"))
        try! FileManager.default.createDirectory(at: bare.appendingPathComponent("Library/Application Support/Google/Chrome/Crashpad"),
                                                 withIntermediateDirectories: true)
        _ = Database.firefox(bare.appendingPathComponent("Library/Application Support/Firefox/Profiles/q1.default-release/places.sqlite"))
        try! FileManager.default.createDirectory(at: bare.appendingPathComponent("Library/Application Support/Firefox/Profiles/empty.old"),
                                                 withIntermediateDirectories: true)
        expect(BrowserHistory(home: bare, scratch: scratch).profiles().map(\.name) == ["Safari", "Chrome – Default", "Firefox – default-release"],
               "Without Chrome's Local State or Firefox's list, profile folders are found by name")
        expect(BrowserHistory(home: home.appendingPathComponent("nothing"), scratch: scratch).profiles().map(\.id) == ["safari"],
               "Without Chrome or further Safari profiles, only Safari's own profile is listed")

        expect(BrowserHistory.date(chromeTime: 13_000_000_000_000_000) == Date(timeIntervalSince1970: 1_355_526_400),
               "Chrome counts microseconds from 1601")
        expect(BrowserHistory.firefoxTime(Date(timeIntervalSince1970: 1_800_000_000.25)) == 1_800_000_000_250_000,
               "Firefox counts microseconds from 1970")
        let listed = BrowserHistory.firefoxProfiles(inList: """
            [Install4F96D1932A9F858E]
            Default=Profiles/x1.default-release

            [Profile0]
            Name=Everyday
            IsRelative=1
            Path=Profiles/x1.default-release
            [Profile1]
            Name=Elsewhere
            IsRelative=0
            Path=/Volumes/Work/fox
            [Profile2]
            IsRelative=1
            Path=Profiles/n0.unnamed
            [Profile3]
            Name=Escaping
            IsRelative=1
            Path=../../Chrome/Default
            [Profile4]
            Name=No folder
            [General]
            Version=2
            """)
        expect(listed.map(\.name) == ["Everyday", "Elsewhere", "n0.unnamed"] && listed.map(\.path) == ["Profiles/x1.default-release", "/Volumes/Work/fox", "Profiles/n0.unnamed"]
               && listed.map(\.relative) == [true, false, true],
               "Firefox's list gives each profile's name and folder; installations, profiles without a folder and folders reaching outside are skipped")
        expect(BrowserHistory.date(chromeTime: BrowserHistory.chromeTime(now)) == now, "Chrome times convert both ways")
        expect(BrowserHistory.origin(of: "HTTPS://Mail.Example:443/inbox?x") == "https://mail.example"
               && BrowserHistory.origin(of: "http://dev.example:8080/") == "http://dev.example:8080"
               && BrowserHistory.origin(of: "chrome://newtab/") == nil, "Icons are kept by site")
        withExtendedLifetime(fixtures) { }
        print("Passed \(checks) browser history checks")
    }

    /// Databases that must stay open while the tests run: one holds Chrome's lock, one keeps its write-ahead log.
    struct Fixtures {
        let locked: Database
        let wal: Database
        let icons: Database
    }

    static func makeFixtures(home: URL, chrome: URL, safari: URL) -> Fixtures {
        let safariSchema = ["CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER)",
                            "CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT)"]
        let work = Database(safari.appendingPathComponent("Profiles/AB12-CD/History.db"), safariSchema[0], safariSchema[1])
        work.execute("INSERT INTO history_items VALUES (1, 'https://work.example/plan', 1)")
        work.execute("INSERT INTO history_visits VALUES (1, 1, \(now.addingTimeInterval(-60).timeIntervalSinceReferenceDate), 'Plan')")
        try! FileManager.default.createDirectory(at: safari.appendingPathComponent("Profiles/DefaultProfile"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: safari.appendingPathComponent("Profiles/EMPTY-9"), withIntermediateDirectories: true)
        _ = Database(safari.appendingPathComponent("SafariTabs.db"),
                     "CREATE TABLE bookmarks (id INTEGER PRIMARY KEY, title TEXT, subtype INTEGER, external_uuid TEXT)",
                     "INSERT INTO bookmarks VALUES (1, 'Work', 2, 'ab12-cd'), (2, 'Favorites', 0, NULL), (3, 'Groceries', 0, 'EMPTY-9')")

        let state = """
        {"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 2": {"name": "Work"}, "Profile 3": {"name": "Deleted"},
                                    "Profile 4": {"name": "Broken"}},
                     "profiles_order": ["Profile 2", "Default"]}}
        """
        try! FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try! Data(state.utf8).write(to: chrome.appendingPathComponent("Local State"))
        let personal = Database.chrome(chrome.appendingPathComponent("Default/History"))
        personal.visit(1, "https://mail.example/inbox", "Inbox", at: now.addingTimeInterval(-3_600))
        personal.visit(1, "https://mail.example/inbox", "Inbox", at: now.addingTimeInterval(-120), transition: 1)
        personal.visit(2, "https://ads.example/frame", "Ad", at: now.addingTimeInterval(-100), transition: 3 | 0x1000_0000)
        personal.visit(3, "https://ads.example/manual", "Ad", at: now.addingTimeInterval(-100), transition: 4)
        personal.visit(4, "https://redirected.example/", "Redirected", at: now.addingTimeInterval(-90), transition: 0x3000_0000)
        personal.visit(5, "https://www.google.com/search?q=chrome+tabs", "chrome tabs - Google", at: now.addingTimeInterval(-300))
        personal.visit(6, "https://old.example/", "Old", at: now.addingTimeInterval(-HistoryStore.retention - 60))
        personal.visit(7, "https://shared.example/", "Shared", at: now.addingTimeInterval(-500))
        // Chrome holds its history in exclusive locking mode while it runs.
        personal.execute("PRAGMA locking_mode = EXCLUSIVE")
        personal.execute("BEGIN EXCLUSIVE")
        personal.execute("COMMIT")

        let second = Database.chrome(chrome.appendingPathComponent("Profile 2/History"))
        second.execute("PRAGMA journal_mode = WAL")
        second.execute("PRAGMA wal_autocheckpoint = 0")
        second.visit(1, "https://work.example/board", "Board", at: now.addingTimeInterval(-200))
        second.visit(2, "https://shared.example/", "Shared", at: now.addingTimeInterval(-400))
        second.visit(3, "https://wal.example/", "Unsaved", at: now.addingTimeInterval(-10))

        _ = Database(chrome.appendingPathComponent("Profile 3/Preferences.db"), "CREATE TABLE unrelated (id INTEGER)")
        try! FileManager.default.createDirectory(at: chrome.appendingPathComponent("Profile 4"), withIntermediateDirectories: true)
        try! Data("not a database".utf8).write(to: chrome.appendingPathComponent("Profile 4/History"))
        _ = Database.chrome(chrome.appendingPathComponent("Profile 9/History"))

        let icons = Database(chrome.appendingPathComponent("Default/Favicons"),
                             "CREATE TABLE favicons(id INTEGER PRIMARY KEY, url LONGVARCHAR NOT NULL, icon_type INTEGER DEFAULT 1)",
                             "CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, last_updated INTEGER DEFAULT 0, image_data BLOB, width INTEGER DEFAULT 0, height INTEGER DEFAULT 0, last_requested INTEGER DEFAULT 0)",
                             "CREATE TABLE icon_mapping(id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, icon_id INTEGER)")
        icons.execute("INSERT INTO favicons VALUES (1, 'https://mail.example/favicon.ico', 1), (2, 'https://mail.example/promo.ico', 1), (3, 'https://touch.example/apple-touch-icon.png', 2)")
        for (id, icon, width, name) in [(1, 1, 16, "mail16"), (2, 1, 32, "mail32"), (3, 1, 64, "mail64"), (4, 2, 32, "promo32"), (5, 3, 180, "touch")] {
            let hex = Data(name.utf8).map { String(format: "%02x", $0) }.joined()
            icons.execute("INSERT INTO favicon_bitmaps (id, icon_id, image_data, width, height) VALUES (\(id), \(icon), X'\(hex)', \(width), \(width))")
        }
        icons.execute("""
            INSERT INTO icon_mapping (page_url, icon_id) VALUES ('https://mail.example/inbox', 1), ('https://mail.example/sent', 1),
            ('https://MAIL.example:443/drafts', 1), ('https://mail.example/promo', 2), ('https://touch.example/', 3), ('chrome://newtab/', 1)
            """)
        makeFirefoxFixtures(home: home)
        return Fixtures(locked: personal, wal: second, icons: icons)
    }

    /// Firefox with two profiles and Zen with one, each in its own folder with its own list of profiles.
    static func makeFirefoxFixtures(home: URL) {
        let firefox = home.appendingPathComponent("Library/Application Support/Firefox")
        let zen = home.appendingPathComponent("Library/Application Support/zen")
        try! FileManager.default.createDirectory(at: firefox, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: zen, withIntermediateDirectories: true)
        try! Data("""
            [Install4F96D1932A9F858E]
            Default=Profiles/x1.default-release
            Locked=1

            [Profile1]
            Name=Work stuff
            IsRelative=1
            Path=Profiles/w9.work

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/x1.default-release
            Default=1

            [Profile2]
            Name=Gone
            IsRelative=1
            Path=Profiles/gone.gone

            [General]
            StartWithLastProfile=1
            """.utf8).write(to: firefox.appendingPathComponent("profiles.ini"))
        try! Data("[Profile0]\nName=Default (release)\nIsRelative=1\nPath=Profiles/z1.Default (release)\n".utf8).write(to: zen.appendingPathComponent("profiles.ini"))

        let everyday = Database.firefox(firefox.appendingPathComponent("Profiles/x1.default-release/places.sqlite"))
        // Firefox keeps its history in a write-ahead log while it runs.
        everyday.execute("PRAGMA journal_mode = WAL")
        everyday.firefoxVisit(1, "https://fox.example/docs", "Fox Docs", at: now.addingTimeInterval(-240))
        everyday.firefoxVisit(1, "https://fox.example/docs", "Fox Docs", at: now.addingTimeInterval(-30), type: 2)
        everyday.firefoxVisit(2, "https://redirect.example/hop", "Hop", at: now.addingTimeInterval(-50), type: 5, hidden: true)
        everyday.firefoxVisit(3, "https://frame.example/ad", "Ad", at: now.addingTimeInterval(-50), type: 8)
        everyday.firefoxVisit(4, "https://download.example/file.zip", "file.zip", at: now.addingTimeInterval(-50), type: 7)
        everyday.firefoxVisit(5, "https://old-fox.example/", "Old", at: now.addingTimeInterval(-HistoryStore.retention - 60))
        everyday.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        everyday.execute("PRAGMA wal_autocheckpoint = 0")
        everyday.firefoxVisit(6, "https://fox-wal.example/", "Unsaved", at: now.addingTimeInterval(-10))
        open.append(everyday)
        _ = Database.firefox(firefox.appendingPathComponent("Profiles/w9.work/places.sqlite"))
        let calm = Database.firefox(zen.appendingPathComponent("Profiles/z1.Default (release)/places.sqlite"))
        calm.firefoxVisit(1, "https://zen.example/calm", "Calm", at: now.addingTimeInterval(-70))

        let icons = Database(firefox.appendingPathComponent("Profiles/x1.default-release/favicons.sqlite"),
                             "CREATE TABLE moz_icons(id INTEGER PRIMARY KEY, icon_url TEXT NOT NULL, fixed_icon_url_hash INTEGER NOT NULL DEFAULT 0, width INTEGER NOT NULL DEFAULT 0, root INTEGER NOT NULL DEFAULT 0, color INTEGER, expire_ms INTEGER NOT NULL DEFAULT 0, flags INTEGER NOT NULL DEFAULT 0, data BLOB)",
                             "CREATE TABLE moz_pages_w_icons(id INTEGER PRIMARY KEY, page_url TEXT NOT NULL, page_url_hash INTEGER NOT NULL DEFAULT 0)",
                             "CREATE TABLE moz_icons_to_pages(page_id INTEGER NOT NULL, icon_id INTEGER NOT NULL, expire_ms INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (page_id, icon_id))")
        // 65535 is the width Firefox gives a drawing, which has no size of its own.
        for (id, address, width, root, name) in [(1, "https://fox.example/icon-16.png", 16, 0, "fox16"), (2, "https://fox.example/icon-32.png", 32, 0, "fox32"),
                                                 (3, "https://fox.example/logo.svg", 65535, 0, "foxsvg"), (4, "https://root.example/favicon.ico", 16, 1, "root16"),
                                                 (5, "https://root.example/favicon.ico", 32, 1, "root32"), (6, "https://root.example/favicon.ico", 256, 1, "root256")] {
            let hex = Data(name.utf8).map { String(format: "%02x", $0) }.joined()
            icons.execute("INSERT INTO moz_icons (id, icon_url, width, root, data) VALUES (\(id), '\(address)', \(width), \(root), X'\(hex)')")
        }
        icons.execute("INSERT INTO moz_pages_w_icons (id, page_url) VALUES (1, 'https://fox.example/docs'), (2, 'https://fox.example/blog'), (3, 'about:newtab')")
        icons.execute("INSERT INTO moz_icons_to_pages (page_id, icon_id) VALUES (1, 1), (1, 2), (1, 3), (2, 1), (2, 2), (3, 1)")
    }

    /// Databases kept open for the whole run, as a running browser keeps its own.
    static var open: [Database] = []

    /// Reads off the main thread, as Tab Scout's history worker does.
    static func read(_ history: BrowserHistory, excluding excluded: Set<String>, now: Date) -> BrowserImport {
        var result: BrowserImport?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            result = history.read(excluding: excluded, now: now)
            done.signal()
        }
        done.wait()
        return result!
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
}
