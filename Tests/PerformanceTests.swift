import Foundation

@main
struct PerformanceTests {
    static func main() {
        let tabs = (0..<1_000).map { BrowserTab(windowID: $0 / 20, index: $0 % 20 + 1, title: "Project documentation \($0)", url: "https://example.com/projects/\($0)") }
        let index = TabSearchIndex(tabs)
        let start = ProcessInfo.processInfo.systemUptime
        var count = 0
        for i in 0..<100 { count += index.results(query: "project \(i)").count }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(count > 0, "Benchmark must produce real results")
        precondition(elapsed < 5, "Indexed search regression: 100 queries of 1,000 tabs exceeded five seconds")
        // Misspelled words send every tab through the initials and typo checks.
        let fuzzyStart = ProcessInfo.processInfo.systemUptime
        var fuzzyCount = 0
        for i in 0..<100 { fuzzyCount += index.results(query: "projetc documentatoin zq\(i)").count }
        let fuzzyElapsed = ProcessInfo.processInfo.systemUptime - fuzzyStart
        precondition(fuzzyCount == 0, "Unmatched misspellings must not produce results")
        precondition(index.results(query: "projetc documentatoin").count == 1_000, "Misspellings still match every tab")
        precondition(fuzzyElapsed < 5, "Fuzzy search regression: 100 misspelled queries of 1,000 tabs exceeded five seconds")
        var calls = 0
        let store = TabStore { completion in calls += 1; completion(.success(TabInventory(tabs: tabs))) }
        store.load { _ in }
        let warmStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { store.load { result in precondition((try? result.get().tabs.count) == 1_000) } }
        let warmElapsed = ProcessInfo.processInfo.systemUptime - warmStart
        precondition(calls == 1, "Warm openings must not make additional Safari reads")
        print(String(format: "Performance: indexed search %.2f ms/query, misspelled %.2f ms/query (1,000 tabs); warm cache %.3f ms/open; 100 warm openings, 0 extra Safari reads", elapsed * 10, fuzzyElapsed * 10, warmElapsed * 10))
    }
}
