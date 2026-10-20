import Foundation
import os

/// Durations of user-visible steps. Read them with:
/// log show --last 5m --predicate 'subsystem == "local.tabscout.app" AND category == "timing"'
enum Timing {
    private static let logger = Logger(subsystem: "local.tabscout.app", category: "timing")

    static func log(_ step: String, since start: DispatchTime) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        logger.notice("\(step, privacy: .public): \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
    }
}

struct SafariTab: Hashable {
    let windowID: Int
    let index: Int
    let title: String
    let url: String

    var displayTitle: String { title.isEmpty ? (url.isEmpty ? "Untitled tab" : url) : title }
    var host: String { URL(string: url)?.host ?? url }
    /// A fresh tab showing the Start Page, Favorites or an empty page, which a new page can replace.
    var isBlank: Bool { ["", "about:blank", "favorites://", "topsites://"].contains(url) }
}

struct TabInventory: Equatable {
    let tabs: [SafariTab]
    /// The current tab of the frontmost Safari window.
    let active: SafariTab?

    init(tabs: [SafariTab], active: SafariTab? = nil) {
        self.tabs = tabs
        self.active = active
    }

    static func decode(_ data: Data) throws -> TabInventory {
        let rows = try JSONDecoder().decode([[TabValue]].self, from: data)
        var active: SafariTab?
        let tabs = try rows.map { row -> SafariTab in
            guard row.count == 5, case .number(let window) = row[0],
                  case .number(let index) = row[1], case .text(let title) = row[2],
                  case .text(let url) = row[3], case .flag(let current) = row[4] else { throw BridgeError.invalidResponse }
            let tab = SafariTab(windowID: window, index: index, title: title, url: url)
            // Windows arrive front to back, so the first current tab is the one on screen.
            if current && active == nil { active = tab }
            return tab
        }
        return TabInventory(tabs: tabs, active: active)
    }

    /// The tab on screen from the bridge's `active` command, or nil when Safari has no window.
    static func decodeActive(_ data: Data) throws -> SafariTab? {
        let row = try JSONDecoder().decode([TabValue].self, from: data)
        if row.isEmpty { return nil }
        guard row.count == 4, case .number(let window) = row[0], case .number(let index) = row[1],
              case .text(let title) = row[2], case .text(let url) = row[3] else { throw BridgeError.invalidResponse }
        return SafariTab(windowID: window, index: index, title: title, url: url)
    }
}

private enum TabValue: Decodable {
    case number(Int)
    case flag(Bool)
    case text(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Int.self) { self = .number(number) }
        else if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else { self = .text(try value.decode(String.self)) }
    }
}

enum BridgeError: LocalizedError {
    case invalidResponse
    case unavailable
    case permission
    case staleTab
    case timeout
    case script(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Safari returned an unreadable tab list. Try again."
        case .unavailable: return "Safari is not running."
        case .permission: return "Allow Safari access in System Settings > Privacy & Security > Automation."
        case .staleTab: return "That tab was closed or moved. Refresh the tab list."
        case .timeout: return "Safari took too long to respond. Try again."
        case .script(let message): return message
        }
    }
}

enum TabSearch {
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? folded
    }

    static func results(_ tabs: [SafariTab], query: String) -> [SafariTab] {
        TabSearchIndex(tabs).results(query: query)
    }
}

struct TabSearchIndex {
    struct Match {
        let tab: SafariTab
        let relevance: Int
    }
    private struct Entry {
        let tab: SafariTab
        let fields: TextFields
    }
    private let entries: [Entry]

    init(_ tabs: [SafariTab]) {
        entries = tabs.map { Entry(tab: $0, fields: TextFields(title: $0.displayTitle, url: $0.url)) }
    }

    struct SemanticMatch: Equatable {
        let tab: SafariTab
        let strength: Double
        /// The title word that made the connection.
        let word: String
    }

    func results(query: String) -> [SafariTab] {
        matches(query: query).map(\.tab)
    }

    /// Tabs whose title contains, for at least one typed word, a word of similar meaning from `expansions`,
    /// while every other typed word is found as typed or widened too. Strongest first.
    func semanticMatches(_ query: TextQuery, expansions: [String: [Neighbor]]) -> [SemanticMatch] {
        entries.enumerated().compactMap { offset, entry -> (Int, SemanticMatch)? in
            var weakest = 1.0
            var bridge: String?
            for token in query.tokens {
                if entry.fields.text.contains(token) { continue }
                // A similar word counts as a whole title word or the start of one: "recipe" finds "recipes".
                let found = expansions[token]?.compactMap { neighbor -> (Double, String)? in
                    guard let word = entry.fields.words.first(where: {
                        $0 == neighbor.word || (neighbor.word.count >= 4 && $0.hasPrefix(neighbor.word))
                    }) else { return nil }
                    return (neighbor.strength, word)
                }.max { $0.0 < $1.0 }
                guard let found else { return nil }
                weakest = min(weakest, found.0)
                bridge = bridge ?? found.1
            }
            guard let bridge else { return nil }
            return (offset, SemanticMatch(tab: entry.tab, strength: weakest, word: bridge))
        }.sorted { $0.1.strength == $1.1.strength ? $0.0 < $1.0 : $0.1.strength > $1.1.strength }.map(\.1)
    }

    func matches(query: String) -> [Match] {
        let query = TabSearch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return entries.map { Match(tab: $0.tab, relevance: 0) } }
        let prepared = TextQuery(normalized: query)
        return entries.enumerated().compactMap { offset, entry -> (Int, Int, SafariTab)? in
            guard let score = entry.fields.relevance(prepared, fuzzy: true) else { return nil }
            return (score, offset, entry.tab)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map { Match(tab: $0.2, relevance: $0.0) }
    }
}

/// A word with a similar meaning to a typed word, such as one from the system's word embedding.
struct Neighbor: Equatable {
    let word: String
    /// Between 0 and 1.
    let strength: Double
}

/// A normalized query, prepared once per keystroke.
struct TextQuery {
    let text: String
    let tokens: [String]
    fileprivate let phrase: String

    init(normalized text: String) {
        self.text = text
        tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        phrase = " " + tokens.joined(separator: " ")
    }
}

/// The searchable forms of one page title and URL, prepared once per tab or history entry.
struct TextFields {
    let title: String
    /// The host without a leading "www.".
    let host: String
    let text: String
    /// Title words split at punctuation: "GitHub - Code" becomes github, code.
    let words: [String]
    /// Title words also split at camelCase, for initials: git, hub, code. Empty unless prepared for loose matching.
    let parts: [String]
    let siteWords: [String]
    private let spacedTitle: String
    private let spacedParts: String

    init(title: String, url: String, loose: Bool = true) {
        self.title = TabSearch.normalized(title)
        let host = TabSearch.normalized(URL(string: url)?.host ?? url)
        self.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let address = TabSearch.normalized(url)
        text = self.title + " " + address
        words = self.title.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        parts = loose ? TextMatch.words(title) : []
        siteWords = address.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        spacedTitle = " " + words.joined(separator: " ") + " "
        spacedParts = loose ? " " + parts.joined(separator: " ") + " " : ""
    }

    /// Match tiers, best first: the whole query as host or title (100-85), at a word start in the title (80),
    /// as the initials of consecutive title words (75), inside a title word (70); then every word of the query
    /// at a word start (65), anywhere (60), as initials (58, or 55 with words skipped), or with a typo (50).
    /// Initials and typos count only when `fuzzy` is set.
    func relevance(_ query: TextQuery, fuzzy: Bool) -> Int? {
        // Most entries miss a typed word, so that cheap test comes first.
        let firstMissing = query.tokens.firstIndex { !text.contains($0) }
        if firstMissing != nil && !fuzzy { return nil }
        if firstMissing == nil {
            if host == query.text { return 100 }
            if title == query.text { return 95 }
            if host.hasPrefix(query.text) { return 90 }
            if title.hasPrefix(query.text) { return 85 }
            if spacedTitle.contains(query.phrase) || spacedParts.contains(query.phrase) { return 80 }
            if title.contains(query.text) { return 70 }
        }
        var best = 0
        var weakest = 65
        for (index, token) in query.tokens.enumerated() {
            if firstMissing.map({ index < $0 || (index > $0 && text.contains(token)) }) ?? true {
                let wordStart = words.contains { $0.hasPrefix(token) } || parts.contains { $0.hasPrefix(token) }
                    || siteWords.contains { $0.hasPrefix(token) }
                weakest = min(weakest, wordStart ? 65 : 60)
            } else if let skipped = TextMatch.initialsSkipping(token, in: parts) {
                if query.tokens.count == 1 && skipped == 0 { best = 75 }
                weakest = min(weakest, skipped == 0 ? 58 : 55)
            } else if TextMatch.nearMiss(token, in: words) || TextMatch.nearMiss(token, in: siteWords) {
                weakest = min(weakest, 50)
            } else {
                return nil
            }
        }
        return max(best, weakest)
    }
}

enum TextMatch {
    static func words(_ text: String) -> [String] {
        // Mark camelCase boundaries before folding case: "DynamoDB" is dynamo, db and "DBTable" is db, table.
        let characters = Array(text)
        var marked = ""
        marked.reserveCapacity(characters.count + 8)
        for (offset, character) in characters.enumerated() {
            if offset > 0 {
                let previous = characters[offset - 1]
                let next = offset + 1 < characters.count ? characters[offset + 1] : nil
                if (previous.isLowercase && character.isUppercase)
                    || (previous.isUppercase && character.isUppercase && next?.isLowercase == true) { marked.append(" ") }
            }
            marked.append(character)
        }
        return TabSearch.normalized(marked).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Spells `token` with the starts of two or more title words in order, as "gh" does with git, hub and
    /// "ddb" with dynamo, db. Returns how few words between them had to be skipped, or nil when it cannot.
    static func initialsSkipping(_ token: String, in words: [String]) -> Int? {
        let token = Array(token)
        guard (2...8).contains(token.count), token.allSatisfy(\.isLetter),
              words.contains(where: { $0.first == token[0] }) else { return nil }
        let words = words.prefix(24).map(Array.init)
        var memo: [Int: Int?] = [:]
        func skipped(_ position: Int, _ first: Int, _ pieces: Int) -> Int? {
            if position == token.count { return pieces >= 2 ? 0 : nil }
            let key = (position * 32 + first) * 3 + min(pieces, 2)
            if let known = memo[key] { return known }
            var best: Int?
            for word in first..<words.count {
                // Words before the first piece are free; words between pieces count as skipped.
                let gap = pieces == 0 ? 0 : word - first
                if let best, gap >= best { break }
                var length = 0
                while length < words[word].count, position + length < token.count,
                      words[word][length] == token[position + length] {
                    length += 1
                    if let rest = skipped(position + length, word + 1, pieces + 1) { best = min(best ?? .max, gap + rest) }
                }
            }
            memo[key] = best
            return best
        }
        return skipped(0, 0, 0)
    }

    /// One typo (two from nine letters) against the start of a word: "githbu" finds github.
    static func nearMiss(_ token: String, in words: [String]) -> Bool {
        let token = Array(token)
        guard token.count >= 5 else { return false }
        let allowed = token.count >= 9 ? 2 : 1
        return words.contains { word in
            let word = Array(word)
            guard word.count >= token.count - allowed else { return false }
            return (token.count - allowed...min(word.count, token.count + allowed)).contains {
                editDistance(token, word[..<$0], limit: allowed) <= allowed
            }
        }
    }

    /// Optimal string alignment distance, where swapping two neighbouring letters is one edit.
    /// Stops early once every alignment exceeds `limit`.
    static func editDistance(_ a: [Character], _ b: ArraySlice<Character>, limit: Int) -> Int {
        let b = Array(b)
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var before = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            var smallest = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { current[j] = min(current[j], before[j - 2] + 1) }
                smallest = min(smallest, current[j])
            }
            if smallest > limit { return limit + 1 }
            before = previous
            previous = current
        }
        return previous[b.count]
    }
}

enum NewTabDestination: Equatable {
    case defaultPage
    case url(String)
    case search(String)

    static func from(_ input: String) -> NewTabDestination {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .defaultPage }
        guard !text.contains(where: \.isWhitespace) else { return .search(text) }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty {
            return .url(url.absoluteString)
        }

        // Only recognize bare hostnames, localhost and IP addresses as addresses.
        // Everything else goes through Safari's own configured search provider.
        let candidate = "https://" + text
        if let url = URL(string: candidate), let host = url.host,
           url.user == nil, url.password == nil,
           !text.contains("://"),
           host == "localhost" || host.contains(".") || host.hasPrefix("[") {
            let scheme = host == "localhost" || host == "127.0.0.1" || host == "[::1]" ? "http://" : "https://"
            if let result = URL(string: scheme + text) { return .url(result.absoluteString) }
        }
        return .search(text)
    }
}

enum ShortcutDecision {
    static func shouldCapture(keyCode: Int64, command: Bool, shift: Bool, control: Bool,
                              option: Bool, safariActive: Bool, enabled: Bool) -> Bool {
        enabled && safariActive && keyCode == 17 && command && !shift && !control && !option
    }
}
