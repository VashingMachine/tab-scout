import Foundation

@main
struct CacheTests {
    static var checks = 0
    static func main() {
        var date = Date(timeIntervalSince1970: 1_000)
        var pending: [(Result<TabInventory, Error>) -> Void] = []
        let store = TabStore(now: { date }) { pending.append($0) }
        let tab = SafariTab(windowID: 1, index: 1, title: "Original", url: "https://example.com/original")
        let changed = SafariTab(windowID: 1, index: 1, title: "Changed", url: "https://example.com/changed")
        var first: [Result<TabSnapshot, Error>] = []
        var second: [Result<TabSnapshot, Error>] = []
        store.load { first.append($0) }
        expect(first.isEmpty && store.isRefreshing, "Cold load does not fabricate a snapshot")
        store.load { second.append($0) }
        store.prewarm()
        expect(pending.count == 1, "Concurrent cold loads and prewarm share one read")
        pending.removeFirst()(.success(TabInventory(tabs: [tab])))
        expect(first.count == 1 && second.count == 1, "Every cold subscriber receives the snapshot")
        expect(!store.isRefreshing && store.snapshot?.tabs == [tab], "Snapshot remains cached after load")
        expect(store.snapshot?.index.results(query: "original") == [tab], "Snapshot contains its prebuilt search index")

        var warm: [Result<TabSnapshot, Error>] = []
        store.load { warm.append($0) }
        expect(warm.count == 1 && pending.isEmpty, "Fresh hit is synchronous with no Safari request")
        date.addTimeInterval(5)
        var stale: [Result<TabSnapshot, Error>] = []
        store.load { stale.append($0) }
        expect(stale.count == 1 && pending.count == 1, "At freshness boundary stale results appear before refresh")
        var coalesced: [Result<TabSnapshot, Error>] = []
        store.load { coalesced.append($0) }
        expect(coalesced.count == 1 && pending.count == 1, "Stale subscribers share the refresh")
        pending.removeFirst()(.success(TabInventory(tabs: [changed])))
        expect(stale.count == 2 && coalesced.count == 2, "Subscribers receive both cached and fresh results")
        expect(store.snapshot?.tabs == [changed] && store.snapshot?.revision == 2, "Refresh replaces snapshot atomically")
        expect(store.snapshot?.index.results(query: "original").isEmpty == true, "Search index does not retain old titles")

        store.load(force: true) { _ in }
        expect(pending.count == 1, "Manual refresh bypasses fresh TTL")
        pending.removeFirst()(.failure(BridgeError.timeout))
        expect(store.snapshot?.tabs == [changed] && !store.isRefreshing, "Transient error retains usable stale data")
        store.load(force: true) { _ in }
        var permissionRevoked = false
        store.onPermissionDenied = { permissionRevoked = true }
        pending.removeFirst()(.failure(BridgeError.permission))
        expect(store.snapshot == nil, "Permission revocation clears the tab cache")
        expect(permissionRevoked, "Background permission failure notifies owner to stop prewarming")

        store.prewarm()
        pending.removeFirst()(.success(TabInventory(tabs: [])))
        var emptyDelivered = false
        store.load { result in emptyDelivered = (try? result.get().tabs.isEmpty) == true }
        expect(emptyDelivered && pending.isEmpty, "Empty Safari inventory is a valid fresh cache hit")
        date.addTimeInterval(120)
        expect(store.snapshot == nil, "Sensitive tab metadata expires at retention boundary")
        var expiredDelivered = false
        store.load { _ in expiredDelivered = true }
        expect(!expiredDelivered && pending.count == 1, "Expired tabs are never presented as warm results")

        let obsolete = pending.removeFirst()
        store.invalidate()
        var latest: [Result<TabSnapshot, Error>] = []
        store.load { latest.append($0) }
        obsolete(.success(TabInventory(tabs: [tab])))
        expect(store.snapshot == nil && store.isRefreshing, "Late invalidated request cannot repopulate cache or end newer read")
        pending.removeFirst()(.success(TabInventory(tabs: [changed])))
        expect(latest.count == 1 && store.snapshot?.tabs == [changed], "New generation wins after invalidation")
        date.addTimeInterval(-1)
        expect(store.snapshot == nil, "Clock rollback does not create indefinitely fresh data")

        var observed: [SafariTab?] = []
        let observedStore = TabStore(now: { date }) { pending.append($0) }
        observedStore.onSnapshot = { observed.append($0.active) }
        observedStore.prewarm()
        pending.removeFirst()(.success(TabInventory(tabs: [tab, changed], active: changed)))
        expect(observed == [changed] && observedStore.snapshot?.active == changed, "Background reads report the on-screen tab")
        var replayed = 0
        observedStore.load { _ in replayed += 1 }
        expect(replayed == 1 && observed.count == 1, "Replaying a cached snapshot does not report the tab again")
        observedStore.load(force: true) { _ in }
        let superseded = pending.removeFirst()
        observedStore.invalidate()
        superseded(.success(TabInventory(tabs: [tab, changed], active: tab)))
        expect(observed == [changed], "A read started before a tab switch cannot report the old tab")
        observedStore.prewarm()
        pending.removeFirst()(.failure(BridgeError.timeout))
        expect(observed == [changed] && pending.isEmpty, "Failed reads report nothing")

        let warmStore = TabStore(now: { date }) { pending.append($0) }
        warmStore.prewarm()
        pending.removeFirst()(.success(TabInventory(tabs: [tab, changed], active: tab)))
        warmStore.load(force: true) { _ in }
        let beforeSwitch = pending.removeFirst()
        warmStore.noteActivation(changed)
        expect(warmStore.snapshot?.tabs == [tab, changed] && warmStore.snapshot?.active == changed,
               "A switch made by Tab Scout keeps the tabs and records the new on-screen tab")
        var reopened: [Result<TabSnapshot, Error>] = []
        warmStore.load { reopened.append($0) }
        expect(reopened.count == 1 && (try? reopened[0].get().active) == changed, "Reopening right after a switch is served from memory")
        beforeSwitch(.success(TabInventory(tabs: [tab, changed], active: tab)))
        expect(warmStore.snapshot?.active == changed, "A read started before the switch cannot restore the old on-screen tab")
        expect(pending.count == 1 && warmStore.isRefreshing, "Reopening after a switch still refreshes the kept tabs in the background")
        warmStore.prewarm()
        expect(pending.count == 1, "That refresh is shared with the next prewarm")
        pending.removeFirst()(.success(TabInventory(tabs: [tab, changed], active: changed)))
        warmStore.noteActivation(nil)
        expect(warmStore.snapshot?.active == nil && warmStore.snapshot?.tabs.count == 2, "Opening a new tab keeps the list without guessing the new tab")
        let coldStore = TabStore(now: { date }) { pending.append($0) }
        coldStore.noteActivation(tab)
        expect(coldStore.snapshot == nil && pending.isEmpty, "Without cached tabs there is nothing to keep")

        let fixtures = (0..<200).map { SafariTab(windowID: $0 / 20, index: $0 % 20 + 1, title: "Zażółć project \($0)", url: "https://example\($0 % 7).com/docs/\($0)") }
        let index = TabSearchIndex(fixtures)
        for query in ["", "zazolc", "PROJECT 12", "example3.com", "docs/5", "missing", "  project   19  "] {
            expect(index.results(query: query) == TabSearch.results(fixtures, query: query), "Indexed search preserves matching and order: \(query)")
        }
        expect(index.results(query: "project 199").count == 1, "Multi-token index returns expected exact fixture")
        expect(index.results(query: "example3.com") == fixtures.filter { $0.host == "example3.com" }, "Host matching has an independent expected inventory")
        expect(index.results(query: "docs/5") == fixtures.filter { $0.url.contains("docs/5") }, "URL-path matching preserves original order")
        let exact = SafariTab(windowID: 1, index: 1, title: "GitHub", url: "https://other.example.com")
        let host = SafariTab(windowID: 1, index: 2, title: "Source code", url: "https://github.com/acme")
        let prefix = SafariTab(windowID: 1, index: 3, title: "GitHub documentation", url: "https://docs.example.com")
        let contains = SafariTab(windowID: 1, index: 4, title: "Notes about GitHub", url: "https://notes.example.com")
        let urlOnly = SafariTab(windowID: 1, index: 5, title: "API", url: "https://api.github.com")
        expect(TabSearchIndex([urlOnly, contains, prefix, host, exact]).results(query: "github") == [exact, host, prefix, contains, urlOnly], "Independent fixture verifies exact-title, host-prefix, title-prefix, title-contains and URL-only ranking")
        print("Passed \(checks) tab cache and indexed-search checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
}
