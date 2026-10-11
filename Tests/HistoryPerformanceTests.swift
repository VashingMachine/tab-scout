import Foundation

@main
struct HistoryPerformanceTests {
    static var checks = 0

    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tabs = (0..<1_000).map { index in
            SafariTab(windowID: index / 20 + 1, index: index % 20 + 1,
                      title: "Project \(index % 100) engineering tab \(index)",
                      url: "https://docs.example\(index % 25).com/page/\(index)")
        }
        let visits = (0..<5_000).map { index in
            HistoryVisit(url: "https://docs.example\(index % 25).com/page/\(index)",
                         title: "Project \(index % 100) engineering reference \(index)",
                         lastVisited: now.addingTimeInterval(Double(-index * 60)), visitCount: index % 40 + 1)
        }
        let searches = (0..<500).map { index in
            PastSearch(query: "Project \(index) engineering", lastUsed: now.addingTimeInterval(Double(-index * 60)),
                       useCount: index % 20 + 1)
        }
        let snapshot = HistorySnapshot(visits: visits, searches: searches)
        let buildStart = DispatchTime.now().uptimeNanoseconds
        let tabsIndex = TabSearchIndex(tabs)
        let history = HistorySearchIndex(snapshot)
        let openTabs = OpenTabLookup(tabs)
        let buildMS = elapsed(from: buildStart)
        expect(history.browsingMatches(query: "missing fixture", now: now).isEmpty, "Unknown fixture has no history matches")
        expect(history.browsingMatches(query: "engineering", now: now).count == 8, "Broad query keeps history presentation bounded")
        expect(history.recentSearches(query: "engineering", now: now).count == 5, "Broad query keeps prior searches bounded")
        let queries = (0..<100).map { index in
            switch index % 5 {
            case 0: return "project \(index)"
            case 1: return "engineering"
            case 2: return "docs.example\(index % 25).com"
            case 3: return "project \(index % 100) engineering"
            default: return "missing fixture \(index)"
            }
        }
        // Warm Foundation's normalization machinery before the measured query loop.
        _ = SearchResultBuilder.rows(query: "engineering", matches: tabsIndex.matches(query: "engineering"),
                                     allTabs: tabs, history: history, suggestions: [], now: now, openTabs: openTabs)
        var durations: [Double] = []
        var selectableCount = 0
        for query in queries {
            let started = DispatchTime.now().uptimeNanoseconds
            let rows = SearchResultBuilder.rows(query: query, matches: tabsIndex.matches(query: query),
                                                 allTabs: tabs, history: history,
                                                 suggestions: [query + " guide", query + " examples"], now: now, openTabs: openTabs)
            durations.append(elapsed(from: started))
            selectableCount += rows.filter(\.isSelectable).count
            expect(!rows.isEmpty, "Every query has at least its explicit new-search action")
        }
        let sorted = durations.sorted()
        let totalMS = durations.reduce(0, +)
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        expect(selectableCount > 20_000, "Benchmark performs substantial ranking work, not an empty-input shortcut")
        // Loose ceilings catch accidental quadratic work without relying on exact CI hardware speed.
        expect(buildMS < 2_000, "Bounded history index builds within the smoke-test budget")
        expect(totalMS < 10_000 && p95 < 500, "One hundred mixed broad/narrow queries finish within the smoke-test budget")
        print(String(format: "History benchmark: index %.2f ms; 100 queries %.2f ms; median %.2f ms; p95 %.2f ms", buildMS, totalMS, median, p95))
        print("Passed \(checks) bounded-history performance checks")
    }

    static func elapsed(from start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
}
