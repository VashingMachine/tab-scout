import Foundation
import SQLite3

private final class HistoryFixture {
    let directory: URL
    let databaseURL: URL
    var database: OpaquePointer?

    init(schema: Bool = true) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabScout-HistoryTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("History.db")
        precondition(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        if schema {
            execute("CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER)")
            execute("CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT)")
            execute("CREATE INDEX visit_time_index ON history_visits (visit_time)")
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
        try? FileManager.default.removeItem(at: directory)
    }

    func execute(_ sql: String) {
        precondition(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "Fixture SQL failed")
    }

    func add(id: Int, url: String, title: String, at date: Date, itemID: Int? = nil) {
        let itemID = itemID ?? id
        var item: OpaquePointer?
        precondition(sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO history_items (id, url, visit_count) VALUES (?, ?, 1)", -1, &item, nil) == SQLITE_OK)
        sqlite3_bind_int64(item, 1, Int64(itemID))
        bind(url, at: 2, in: item)
        precondition(sqlite3_step(item) == SQLITE_DONE)
        sqlite3_finalize(item)
        var visit: OpaquePointer?
        precondition(sqlite3_prepare_v2(database, "INSERT INTO history_visits (id, history_item, visit_time, title) VALUES (?, ?, ?, ?)", -1, &visit, nil) == SQLITE_OK)
        sqlite3_bind_int64(visit, 1, Int64(id))
        sqlite3_bind_int64(visit, 2, Int64(itemID))
        sqlite3_bind_double(visit, 3, date.timeIntervalSinceReferenceDate)
        bind(title, at: 4, in: visit)
        precondition(sqlite3_step(visit) == SQLITE_DONE)
        sqlite3_finalize(visit)
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        value.withCString { _ = sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
}

@main
struct HistoryTests {
    static var checks = 0
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() {
        identities()
        merging()
        databaseReading()
        databaseLimits()
        persistence()
        refreshAndPermissions()
        partialFailures()
        disablingSafariHistory()
        print("Passed \(checks) history import, persistence and refresh checks")
    }

    static func identities() {
        expect(HistoryIdentity.url("HTTPS://EXAMPLE.COM:443") == "https://example.com/", "Identity normalizes only scheme, host, default port and empty path")
        expect(HistoryIdentity.url("http://example.com:80/a") == "http://example.com/a", "HTTP default port is equivalent")
        expect(HistoryIdentity.url("https://example.com:8443/a") == "https://example.com:8443/a", "Nondefault ports stay distinct")
        expect(HistoryIdentity.url("https://example.com/A?q=One#Part") != HistoryIdentity.url("https://example.com/a?q=one#part"), "Case-sensitive paths, queries and fragments stay distinct")
        expect(HistoryIdentity.url("https://example.com/a?one=1") != HistoryIdentity.url("https://example.com/a?one=2"), "Ordinary URL query strings are never discarded")
        for url in ["file:///private/history", "about:blank", "javascript:alert(1)", "not a URL", "https://", "https://user:secret@example.com/"] {
            expect(HistoryIdentity.url(url) == nil, "Invalid, non-web and credential-bearing choices are not persisted")
        }
        expect(HistoryIdentity.query("  Zażółć  ŁÓDŹ\nProject ") == "zazolc lodz project", "Query identity folds accents, case and spacing")
        for (url, expected) in [
            ("https://www.google.com/search?q=chatgpt+billing", "chatgpt billing"),
            ("https://google.pl/search?q=za%C5%BC%C3%B3%C5%82%C4%87", "zażółć"),
            ("https://www.google.co.uk/search?client=safari&q=Swift%20testing", "Swift testing"),
            ("https://google.com/search?q=C%2B%2B+language", "C++ language"),
            ("https://google.com/search?q=%25%2B%26%3D", "%+&="),
            ("https://GOOGLE.COM/search?q=one%09two", "one two"),
            ("http://google.com:80/search?q=old+search", "old search")
        ] {
            expect(HistorySearchQuery.from(url: url) == expected, "Trusted Google form-encoded query is extracted correctly")
        }
        for url in [
            "https://evilgoogle.com/search?q=private", "https://google.com.evil.test/search?q=private",
            "https://sites.google.com/search?q=private", "https://accounts.google.com/search?q=private",
            "https://www.google.com/url?q=private", "https://google.com/?q=private",
            "https://google.com/search?q=one&q=two", "https://google.com/search?q=",
            "https://google.com/search?Q=private", "https://google.com/search?q=%00private",
            "file://google.com/search?q=private", "https://user:secret@google.com/search?q=private",
            "https://google.com:444/search?q=private", "https://example.com/search?q=private",
            "https://google.com/search?q=" + String(repeating: "x", count: 513)
        ] {
            expect(HistorySearchQuery.from(url: url) == nil, "Untrusted, malformed or unsupported search URL is ignored")
        }
        expect(HistorySearchQuery.cleaned("\t one   two\n") == "one two", "Local searches retain readable spelling and collapse whitespace")
        expect(HistorySearchQuery.cleaned("   ") == nil, "Empty local queries are not recorded")
    }

    static func merging() {
        let old = date.addingTimeInterval(-100)
        let first = HistorySnapshot(visits: [
            HistoryVisit(url: "https://EXAMPLE.com:443", title: "Old", lastVisited: old, visitCount: 3),
            HistoryVisit(url: "https://example.com/?q=one", title: "Query", lastVisited: old, visitCount: 2)
        ], searches: [PastSearch(query: "CHATGPT billing", lastUsed: old, useCount: 3)])
        let second = HistorySnapshot(visits: [HistoryVisit(url: "https://example.com/", title: "New", lastVisited: date, visitCount: 2)],
                                     searches: [PastSearch(query: "chatgpt  billing", lastUsed: date, useCount: 2)])
        let merged = HistoryStore.merge(first, second, now: date)
        expect(merged.visits.count == 2, "Equivalent URLs merge but unrelated query strings remain separate")
        expect(merged.visits[0] == HistoryVisit(url: "https://example.com/", title: "New", lastVisited: date, visitCount: 3), "New title and visit time win without double-counting imported/local overlap")
        expect(merged.searches == [PastSearch(query: "chatgpt billing", lastUsed: date, useCount: 3)], "Normalized query duplicates retain latest readable query and strongest count")
        let additive = HistoryStore.merge(first, second, now: date, additive: true)
        expect(additive.visits[0].visitCount == 5 && additive.searches[0].useCount == 5, "Independent recorded events increment counts")
        let rejected = HistorySnapshot(visits: [
            HistoryVisit(url: "file:///history", title: "No", lastVisited: date, visitCount: 1),
            HistoryVisit(url: "https://old.example/", title: "Old", lastVisited: date.addingTimeInterval(-HistoryStore.retention - 1), visitCount: 1),
            HistoryVisit(url: "https://future.example/", title: "Future", lastVisited: date.addingTimeInterval(1), visitCount: 1),
            HistoryVisit(url: "https://zero.example/", title: "Zero", lastVisited: date, visitCount: 0)
        ], searches: [
            PastSearch(query: "old", lastUsed: date.addingTimeInterval(-HistoryStore.retention - 1), useCount: 1),
            PastSearch(query: "future", lastUsed: date.addingTimeInterval(1), useCount: 1),
            PastSearch(query: "negative", lastUsed: date, useCount: -1),
            PastSearch(query: "", lastUsed: date, useCount: 1)
        ])
        expect(HistoryStore.merge(rejected, .empty, now: date) == .empty, "Invalid, expired, future and nonpositive entries are dropped")
        let boundary = HistoryVisit(url: "https://boundary.example/", title: "Boundary", lastVisited: date.addingTimeInterval(-HistoryStore.retention), visitCount: 1)
        expect(HistoryStore.merge(HistorySnapshot(visits: [boundary], searches: []), .empty, now: date).visits == [boundary], "Retention cutoff is inclusive")
        let huge = HistoryVisit(url: "https://huge.example/", title: String(repeating: "t", count: 1_100), lastVisited: date, visitCount: Int.max)
        let limited = HistoryStore.merge(HistorySnapshot(visits: [huge], searches: []), .empty, now: date).visits[0]
        expect(limited.visitCount == 100_000 && limited.title.count == 1_024, "Corrupt counts and excessive titles are bounded")
        let many = HistorySnapshot(visits: (0..<5_100).map {
            HistoryVisit(url: "https://example.com/\($0)", title: "\($0)", lastVisited: date.addingTimeInterval(Double(-$0)), visitCount: 1)
        }, searches: (0..<550).map { PastSearch(query: "Query \($0)", lastUsed: date.addingTimeInterval(Double(-$0)), useCount: 1) })
        let bounded = HistoryStore.merge(many, .empty, now: date)
        expect(bounded.visits.count == HistoryStore.maximumVisits && bounded.searches.count == HistoryStore.maximumSearches, "Snapshot bounds visits and queries")
        expect(bounded.visits.last?.url == "https://example.com/4999", "Most recent visits survive truncation")
        let local = HistoryStore.merge(many, .empty, now: date, localOnly: true)
        expect(local.visits.count == HistoryStore.maximumLocalVisits, "Persistent local choices have a smaller independent bound")
        let tied = HistorySnapshot(visits: ["z", "a"].map { HistoryVisit(url: "https://\($0).example/", title: $0, lastVisited: date, visitCount: 1) },
                                   searches: ["z", "a"].map { PastSearch(query: $0, lastUsed: date, useCount: 1) })
        expect(HistoryStore.merge(tied, .empty, now: date).visits.map(\.title) == ["a", "z"], "Visit ties have deterministic ordering")
        expect(HistoryStore.merge(tied, .empty, now: date).searches.map(\.query) == ["a", "z"], "Query ties have deterministic ordering")
        let encoded = try! JSONEncoder().encode(bounded)
        expect((try! JSONDecoder().decode(HistorySnapshot.self, from: encoded)) == bounded, "Snapshots round-trip through the persisted format")
    }

    static func databaseReading() {
        let fixture = HistoryFixture()
        fixture.add(id: 1, url: "https://example.com/", title: "Old title", at: date.addingTimeInterval(-20))
        fixture.add(id: 2, url: "https://example.com/", title: "Latest title", at: date, itemID: 1)
        fixture.add(id: 3, url: "https://www.google.com/search?q=ChatGPT+billing", title: "Results", at: date.addingTimeInterval(-1))
        fixture.add(id: 4, url: "https://google.pl/search?q=chatgpt%20billing", title: "Results", at: date.addingTimeInterval(-2))
        fixture.add(id: 5, url: "https://example.com/search?q=private", title: "Other search", at: date.addingTimeInterval(-3))
        fixture.add(id: 6, url: "https://old.example/", title: "Old", at: date.addingTimeInterval(-HistoryStore.retention - 1))
        fixture.add(id: 7, url: "https://future.example/", title: "Future", at: date.addingTimeInterval(1))
        fixture.add(id: 8, url: "file:///private", title: "Non-web", at: date)
        fixture.add(id: 9, url: "https://example.com/?q=';DROP%20TABLE%20history_items;--", title: "'; DROP TABLE history_items;--", at: date.addingTimeInterval(-4))
        let before = try! Data(contentsOf: fixture.databaseURL)
        let snapshot = try! read(fixture.databaseURL).get()
        expect(snapshot.visits.count == 5, "Importer excludes old, future and non-web rows")
        expect(snapshot.visits[0].lastVisited == date, "Safari timestamps use the 2001 Cocoa epoch, not Unix time")
        expect(snapshot.visits[0].title == "Latest title" && snapshot.visits[0].visitCount == 2, "Recent repeated visits aggregate with the latest title")
        expect(snapshot.searches == [PastSearch(query: "ChatGPT billing", lastUsed: date.addingTimeInterval(-1), useCount: 2)], "Google history searches aggregate across trusted regional hosts")
        expect(snapshot.visits.contains { $0.title.contains("DROP TABLE") }, "Quotes and SQL-like data remain ordinary strings")
        expect((try! Data(contentsOf: fixture.databaseURL)) == before, "SQLite import does not modify any database bytes")
        expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-journal"), "Read-only import creates no journal")
        fixture.execute("SELECT * FROM history_items")
        let missing = fixture.directory.appendingPathComponent("missing.db")
        expect(error(read(missing)) == .unavailable, "Missing history reports unavailable")
        expect(!FileManager.default.fileExists(atPath: missing.path), "Read-only import never creates a missing database")
        let unsupported = HistoryFixture(schema: false)
        expect(error(read(unsupported.databaseURL)) == .invalidDatabase, "Unsupported Safari schema has a typed failure")
        let malformed = fixture.directory.appendingPathComponent("malformed.db")
        try! Data("this is not SQLite".utf8).write(to: malformed)
        expect(error(read(malformed)) == .invalidDatabase, "Malformed SQLite data is rejected")
        fixture.execute("PRAGMA journal_mode=WAL")
        fixture.add(id: 10, url: "https://wal.example/", title: "WAL", at: date)
        expect((try! read(fixture.databaseURL).get()).visits.contains { $0.title == "WAL" }, "Read-only connection sees recent committed WAL history without copying it")
        fixture.execute("BEGIN EXCLUSIVE")
        expect((try? read(fixture.databaseURL).get()) != nil, "WAL writer does not prevent a bounded read-only snapshot")
        fixture.execute("ROLLBACK")
        let locked = HistoryFixture()
        locked.execute("BEGIN EXCLUSIVE")
        expect(error(read(locked.databaseURL)) == .unavailable, "Locked rollback-journal database times out with a typed transient failure")
        locked.execute("ROLLBACK")
        expect(HistoryError.needsPermission.errorDescription?.contains("Full Disk Access") == true, "Permission failure names optional required permission")
    }

    static func databaseLimits() {
        let fixture = HistoryFixture()
        fixture.execute("BEGIN")
        for index in 0..<(HistoryStore.maximumSafariRows + 2) {
            fixture.add(id: index + 1, url: "https://example.com/\(index)", title: "\(index)", at: date.addingTimeInterval(Double(-index)))
        }
        fixture.execute("COMMIT")
        let snapshot = try! read(fixture.databaseURL).get()
        expect(snapshot.visits.count == 5_000, "Large database is bounded to the newest distinct URLs")
        expect(snapshot.visits.first?.title == "0" && snapshot.visits.last?.title == "4999", "Newest history rows win the bounded import")
        let repeated = HistoryFixture()
        repeated.execute("BEGIN")
        for index in 0..<(HistoryStore.maximumSafariRows + 2) {
            repeated.add(id: index + 1, url: "https://repeat.example/", title: "Repeated", at: date.addingTimeInterval(Double(-index)), itemID: 1)
        }
        repeated.execute("COMMIT")
        expect((try! read(repeated.databaseURL).get()).visits[0].visitCount == 10_000, "Raw scan is capped even when all visits have the same URL")
    }

    static func persistence() {
        let fixture = HistoryFixture()
        let localURL = fixture.directory.appendingPathComponent("local", isDirectory: true)
        let store = HistoryStore(directory: localURL, safariDBURL: fixture.databaseURL, freshFor: 0, now: { date })
        expect(store.snapshot == .empty, "Cold store does not fabricate local history")
        expect((try! load(store, safari: false).get()) == .empty, "Missing local history is an empty usable snapshot")
        expect(!FileManager.default.fileExists(atPath: localURL.path), "Reading empty local history creates no files")
        store.recordVisit(url: "https://EXAMPLE.com:443", title: "Chosen")
        store.recordSearch(query: "  ChatGPT   billing ")
        expect(store.snapshot.visits.count == 1 && store.snapshot.searches.count == 1, "Accepted choices are visible immediately before disk persistence")
        let first = try! load(store, safari: false).get()
        expect(first.visits[0].visitCount == 1 && first.searches[0].query == "ChatGPT billing", "Accepted choices persist normalized identities and readable queries")
        store.recordVisit(url: "https://example.com/", title: "Chosen again")
        store.recordSearch(query: "chatgpt billing")
        let second = try! load(store, safari: false).get()
        expect(second.visits.count == 1 && second.visits[0].visitCount == 2, "Repeated tab choices increment one persistent visit")
        expect(second.searches.count == 1 && second.searches[0].useCount == 2, "Repeated query choices increment one persistent query")
        for input in ["file:///private", "about:blank", "javascript:alert(1)"] { store.recordVisit(url: input, title: "Ignore") }
        store.recordSearch(query: "\u{0000}private")
        store.recordSearch(query: "")
        expect((try! load(store, safari: false).get()) == second, "Ineligible local records are ignored without changing persistence")
        let file = localURL.appendingPathComponent("choices-v1.json")
        let directoryMode = (try! FileManager.default.attributesOfItem(atPath: localURL.path)[.posixPermissions] as! NSNumber).intValue
        let fileMode = (try! FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue
        expect(directoryMode == 0o700 && fileMode == 0o600, "Local history directory and file are owner-only")
        expect((try! FileManager.default.contentsOfDirectory(atPath: localURL.path)) == ["choices-v1.json"], "Atomic persistence leaves no staging files")
        let restarted = HistoryStore(directory: localURL, safariDBURL: fixture.databaseURL, freshFor: 0, now: { date })
        expect((try! load(restarted, safari: false).get()) == second, "Accepted choices survive app restarts")
        restarted.recordSearch(query: "New startup choice")
        let early = HistoryStore(directory: localURL, safariDBURL: fixture.databaseURL, freshFor: 0, now: { date })
        early.recordVisit(url: "https://startup.example/", title: "Startup")
        let earlySnapshot = try! load(early, safari: false).get()
        expect(earlySnapshot.visits.contains { $0.title == "Chosen" }, "Choice made before initial load does not discard persisted visits")
        expect(earlySnapshot.visits.contains { $0.title == "Startup" }, "Choice made before initial load is retained")
        early.clearLocal()
        expect(early.snapshot == .empty, "Clear removes local choices immediately")
        expect((try! load(early, safari: false).get()) == .empty, "Clear is serialized after writes and cannot resurrect queued records")
        expect(!FileManager.default.fileExists(atPath: file.path), "Clear deletes the local history file")
        let cleared = HistoryStore(directory: localURL, safariDBURL: fixture.databaseURL, now: { date })
        expect((try! load(cleared, safari: false).get()) == .empty, "Cleared choices stay cleared after restart")
        try! FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        try! Data("malformed local JSON".utf8).write(to: file)
        let malformed = HistoryStore(directory: localURL, safariDBURL: fixture.databaseURL, freshFor: 0, now: { date })
        expect(error(load(malformed, safari: false)) == .storage, "Malformed local data returns a typed storage failure")
        malformed.recordSearch(query: "Recovered")
        expect((try! load(malformed, safari: false).get()).searches.map(\.query) == ["Recovered"], "New accepted choice recovers from malformed local data")
        let expired = HistoryStore(directory: localURL, safariDBURL: fixture.databaseURL, freshFor: 0, now: { date.addingTimeInterval(HistoryStore.retention + 1) })
        expect((try! load(expired, safari: false).get()) == .empty, "Persistent records expire after the retention period")
        let expiredFile = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let expiredSnapshot = expiredFile["snapshot"] as! [String: Any]
        expect((expiredSnapshot["visits"] as! [Any]).isEmpty && (expiredSnapshot["searches"] as! [Any]).isEmpty, "Expired private records are also purged from disk, not only hidden in memory")
        try! Data("{\"version\":2,\"snapshot\":{\"visits\":[],\"searches\":[]}}".utf8).write(to: file)
        let unsupported = HistoryStore(directory: localURL, safariDBURL: fixture.databaseURL, freshFor: 0, now: { date })
        expect(error(load(unsupported, safari: false)) == .storage, "Unknown local schema is not silently misread")
        unsupported.clearLocal()
        _ = load(unsupported, safari: false)
        let largeData = Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1)
        try! largeData.write(to: file)
        let oversized = HistoryStore(directory: localURL, safariDBURL: fixture.databaseURL, freshFor: 0, now: { date })
        expect(error(load(oversized, safari: false)) == .storage, "Oversized local files are rejected before JSON decoding")
    }

    static func refreshAndPermissions() {
        let fixture = HistoryFixture()
        let imported = HistorySnapshot(visits: [HistoryVisit(url: "https://safari.example/", title: "Safari", lastVisited: date, visitCount: 4)],
                                       searches: [PastSearch(query: "Safari query", lastUsed: date, useCount: 4)])
        var current = date
        var reads = 0
        var readerOnMain = false
        var permissionDenied = false
        let store = HistoryStore(directory: fixture.directory.appendingPathComponent("choices"), safariDBURL: fixture.databaseURL,
                                 freshFor: 30, now: { current }) { _, _ in
            reads += 1
            readerOnMain = Thread.isMainThread
            if permissionDenied { throw HistoryError.needsPermission }
            return imported
        }
        var results: [Result<HistorySnapshot, Error>] = []
        store.load(includeSafari: true) { expect(Thread.isMainThread, "History completion returns on main thread"); results.append($0) }
        store.load(includeSafari: true) { results.append($0) }
        spin { results.count == 2 }
        expect(reads == 1 && !readerOnMain, "Concurrent refreshes coalesce into one background import")
        expect(results.allSatisfy { (try? $0.get()) == imported }, "Every coalesced caller receives the imported snapshot")
        var synchronous = false
        store.load(includeSafari: true) { _ in synchronous = true }
        expect(synchronous && reads == 1, "Fresh history cache responds synchronously without SQLite")
        current.addTimeInterval(30)
        _ = load(store, safari: true)
        expect(reads == 2, "Refresh happens exactly at TTL boundary")
        current.addTimeInterval(-1)
        _ = load(store, safari: true)
        expect(reads == 3, "Clock rollback invalidates freshness")
        expect((try! load(store, safari: false).get()) == .empty && store.snapshot == .empty, "Disabling Safari history immediately excludes imported data")
        expect(reads == 3, "Local-only load never invokes Safari importer")
        store.recordSearch(query: "Local query")
        _ = load(store, safari: false)
        expect(store.snapshot.searches.map(\.query) == ["Local query"], "Local choices work without Safari history")
        current.addTimeInterval(31)
        permissionDenied = true
        expect(error(load(store, safari: true)) == .needsPermission, "Denied Full Disk Access has a typed permission outcome")
        expect(store.snapshot.visits.isEmpty && store.snapshot.searches.map(\.query) == ["Local query"], "Permission revocation clears Safari cache but keeps local choices")
        permissionDenied = false
        _ = load(store, safari: true)
        expect(store.snapshot.visits == imported.visits, "Granting access retries the previously denied import")
        store.clearLocal()
        _ = load(store, safari: false)
        _ = load(store, safari: true)
        expect(store.snapshot == imported, "Clearing Tab Scout choices does not clear or alter Safari history")
    }

    static func partialFailures() {
        let fixture = HistoryFixture()
        let localURL = fixture.directory.appendingPathComponent("local", isDirectory: true)
        try! FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        try! Data("corrupt local JSON".utf8).write(to: localURL.appendingPathComponent("choices-v1.json"))
        let imported = HistorySnapshot(visits: [HistoryVisit(url: "https://example.com/", title: "Imported", lastVisited: date, visitCount: 3)],
                                       searches: [PastSearch(query: "Imported query", lastUsed: date, useCount: 2)])
        var importError: HistoryError?
        let store = HistoryStore(directory: localURL, safariDBURL: fixture.databaseURL, freshFor: 0, now: { date }) { _, _ in
            if let importError { throw importError }
            return imported
        }
        expect((try! load(store, safari: true).get()) == imported, "Corrupt local choices do not suppress successful Safari history")
        expect(store.localStorageError == .storage, "Degraded local storage is exposed separately from the successful imported snapshot")
        expect(error(load(store, safari: false)) == .storage, "Local-only load still reports its storage failure")
        store.recordSearch(query: "Recovered local")
        expect((try! load(store, safari: true).get()).searches.count == 2, "Accepted choices recover local storage while preserving imported searches")
        expect(store.localStorageError == nil, "Successful local persistence clears the storage warning")
        for failure in [HistoryError.unavailable, .invalidDatabase, .needsPermission] {
            importError = failure
            expect(error(load(store, safari: true)) == failure, "Importer failure remains typed")
            expect(store.snapshot.visits.isEmpty, "Any inaccessible import drops stale browsing history immediately")
            expect(store.snapshot.searches.map(\.query) == ["Recovered local"], "Importer failure retains accepted local choices")
            importError = nil
            expect((try! load(store, safari: true).get()).visits == imported.visits, "A later successful read restores browsing history")
        }
        let blockedURL = fixture.directory.appendingPathComponent("not-a-directory")
        try! Data("regular file".utf8).write(to: blockedURL)
        let blocked = HistoryStore(directory: blockedURL, safariDBURL: fixture.databaseURL, freshFor: 0, now: { date })
        blocked.recordSearch(query: "Unwritten choice")
        expect(error(load(blocked, safari: false)) == .storage && blocked.localStorageError == .storage, "Disk write failure is not silently reported as persistent success")
        expect(blocked.snapshot.searches.map(\.query) == ["Unwritten choice"], "Disk write failure does not lose the current in-memory choice")
        blocked.recordSearch(query: "Unwritten choice")
        _ = load(blocked, safari: false)
        expect(blocked.snapshot.searches[0].useCount == 2, "Repeated failed writes do not discard earlier in-memory choices")
        try! FileManager.default.removeItem(at: blockedURL)
        blocked.recordSearch(query: "Recovered disk")
        expect((try! load(blocked, safari: false).get()).searches.count == 2 && blocked.localStorageError == nil, "Local writes recover after storage becomes available")
    }

    static func disablingSafariHistory() {
        let fixture = HistoryFixture()
        let imported = HistorySnapshot(visits: [HistoryVisit(url: "https://safari.example/", title: "Imported", lastVisited: date, visitCount: 1)],
                                       searches: [PastSearch(query: "Imported query", lastUsed: date, useCount: 1)])
        var reads = 0
        let store = HistoryStore(directory: fixture.directory.appendingPathComponent("off-cache"), safariDBURL: fixture.databaseURL,
                                 now: { date }) { _, _ in reads += 1; return imported }
        expect((try! load(store, safari: true).get()) == imported, "Enabled source warms Safari cache")
        expect((try! load(store, safari: false).get()) == .empty, "Disabled source immediately excludes its cached corpus")
        expect((try! load(store, safari: true).get()) == imported && reads == 2, "Re-enabling forces a new import even within the old freshness interval")

        let gate = DispatchSemaphore(value: 0)
        var started = false
        var lateReads = 0
        let late = HistoryStore(directory: fixture.directory.appendingPathComponent("off-in-flight"), safariDBURL: fixture.databaseURL,
                                now: { date }) { _, _ in
            lateReads += 1
            if lateReads == 1 {
                DispatchQueue.main.async { started = true }
                precondition(gate.wait(timeout: .now() + 10) == .success)
            }
            return imported
        }
        var originalResponse: Result<HistorySnapshot, Error>?
        late.load(includeSafari: true) { originalResponse = $0 }
        spin { started }
        var offResponse: Result<HistorySnapshot, Error>?
        late.load(includeSafari: false) { offResponse = $0 }
        expect(late.snapshot == .empty, "Disabling a source clears visible data without waiting for its blocked reader")
        gate.signal()
        spin { originalResponse != nil && offResponse != nil }
        expect((try! originalResponse!.get()) == imported, "Original enabled caller still receives its own response for generation filtering")
        expect((try! offResponse!.get()) == .empty && late.snapshot == .empty, "Late enabled response cannot repopulate the disabled cache")
        expect((try! load(late, safari: true).get()) == imported && lateReads == 2, "Re-enabling after late completion performs a fresh import")

        let reenablingGate = DispatchSemaphore(value: 0)
        var reenablingStarted = false
        var reenablingReads = 0
        let replacement = HistorySnapshot(visits: [HistoryVisit(url: "https://new.example/", title: "Replacement", lastVisited: date, visitCount: 1)], searches: [])
        let reenabling = HistoryStore(directory: fixture.directory.appendingPathComponent("off-on-in-flight"), safariDBURL: fixture.databaseURL,
                                      now: { date }) { _, _ in
            reenablingReads += 1
            if reenablingReads == 1 {
                DispatchQueue.main.async { reenablingStarted = true }
                precondition(reenablingGate.wait(timeout: .now() + 10) == .success)
                return imported
            }
            return replacement
        }
        var oldResponse: Result<HistorySnapshot, Error>?
        var newResponse: Result<HistorySnapshot, Error>?
        reenabling.load(includeSafari: true) { oldResponse = $0 }
        spin { reenablingStarted }
        reenabling.load(includeSafari: false) { _ in }
        reenabling.load(includeSafari: true) { newResponse = $0 }
        reenablingGate.signal()
        spin { oldResponse != nil && newResponse != nil }
        expect(reenablingReads == 2, "Re-enabling during an old import starts a new generation rather than coalescing obsolete work")
        expect((try! oldResponse!.get()) == imported && (try! newResponse!.get()) == replacement, "Each generation receives the response it requested")
        expect(reenabling.snapshot == replacement, "Only post-enable generation is retained as the current Safari cache")
    }

    static func read(_ url: URL) -> Result<HistorySnapshot, Error> {
        var result: Result<HistorySnapshot, Error>?
        DispatchQueue.global(qos: .utility).async {
            let loaded = Result { try HistoryStore.readSafari(at: url, now: date) }
            DispatchQueue.main.async { result = loaded }
        }
        spin { result != nil }
        return result!
    }

    static func load(_ store: HistoryStore, safari: Bool) -> Result<HistorySnapshot, Error> {
        var result: Result<HistorySnapshot, Error>?
        store.load(includeSafari: safari) { result = $0 }
        spin { result != nil }
        return result!
    }

    static func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        precondition(condition(), "Timed out awaiting history worker")
    }

    static func error(_ result: Result<HistorySnapshot, Error>) -> HistoryError? {
        if case .failure(let error) = result { return error as? HistoryError }
        return nil
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
}
