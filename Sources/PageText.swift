import Darwin
import Foundation

/// The visible text of pages the person has viewed, for the optional page text search.
/// Kept in memory only: it is never saved or sent, and closing a tab or turning the option off drops it.
struct PageTextIndex {
    struct Key: Hashable {
        let browser: Browser
        let windowID: Int
        let url: String

        init(_ tab: BrowserTab) {
            browser = tab.browser
            windowID = tab.windowID
            url = tab.url
        }
    }

    struct Match: Equatable {
        /// 1 when the typed words appear together, less when they are spread over the page.
        let strength: Double
        /// A few words around the first occurrence.
        let snippet: String
    }

    static let pageLimit = 30_000
    static let tabLimit = 150
    /// A page indexed this recently is not read again.
    static let freshFor: TimeInterval = 10 * 60

    // Folded text as UTF-8 bytes: memmem searches a full index within a keystroke.
    private var pages: [Key: (bytes: [UInt8], indexed: Date)] = [:]

    var count: Int { pages.count }

    func needsReading(_ tab: BrowserTab, now: Date) -> Bool {
        guard tab.url.hasPrefix("http"), let page = pages[Key(tab)] else { return tab.url.hasPrefix("http") }
        return now.timeIntervalSince(page.indexed) >= Self.freshFor
    }

    mutating func store(_ text: String, for tab: BrowserTab, at now: Date) {
        let words = TabSearch.normalized(String(text.prefix(Self.pageLimit))).split(whereSeparator: \.isWhitespace)
        pages[Key(tab)] = (Array(words.joined(separator: " ").utf8), now)
        if pages.count > Self.tabLimit, let oldest = pages.min(by: { $0.value.indexed < $1.value.indexed })?.key {
            pages[oldest] = nil
        }
    }

    /// Forgets pages whose tab closed or navigated elsewhere.
    mutating func retain(_ tabs: [BrowserTab]) {
        let open = Set(tabs.map(Key.init))
        pages = pages.filter { open.contains($0.key) }
    }

    mutating func removeAll() { pages.removeAll() }

    /// Open tabs whose page text contains every typed word. Three letters at least, so single letters
    /// do not match every page.
    func matches(_ query: String, in tabs: [BrowserTab]) -> [BrowserTab: Match] {
        let text = TabSearch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let prepared = TextQuery(normalized: text)
        guard text.count >= 3, !pages.isEmpty else { return [:] }
        let tokens = prepared.tokens.map { Array($0.utf8) }
        let joined = Array(prepared.tokens.joined(separator: " ").utf8)
        var found: [BrowserTab: Match] = [:]
        for tab in tabs {
            guard let page = pages[Key(tab)]?.bytes, let first = Self.find(tokens[0], in: page),
                  tokens.dropFirst().allSatisfy({ Self.find($0, in: page) != nil }) else { continue }
            let phrase = tokens.count > 1 ? Self.find(joined, in: page) : first
            let anchor = phrase.map { $0..<($0 + joined.count) } ?? first..<(first + tokens[0].count)
            found[tab] = Match(strength: phrase == nil ? 0.7 : 1, snippet: Self.snippet(page, around: anchor))
        }
        return found
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        return haystack.withUnsafeBytes { page in
            needle.withUnsafeBytes { word in
                memmem(page.baseAddress, page.count, word.baseAddress, word.count)
                    .map { page.baseAddress!.distance(to: UnsafeRawPointer($0)) }
            }
        }
    }

    /// About `radius` bytes on each side of the match, cut back to whole words.
    static func snippet(_ page: [UInt8], around range: Range<Int>, radius: Int = 40) -> String {
        let space = UInt8(ascii: " ")
        var start = max(0, range.lowerBound - radius)
        var end = min(page.count, range.upperBound + radius)
        if start > 0, let cut = page[start..<range.lowerBound].firstIndex(of: space) { start = cut + 1 }
        if end < page.count, let cut = page[range.upperBound..<end].lastIndex(of: space) { end = cut }
        return (start > 0 ? "…" : "") + String(decoding: page[start..<end], as: UTF8.self) + (end < page.count ? "…" : "")
    }
}
