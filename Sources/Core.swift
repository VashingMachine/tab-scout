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

struct SafariTab: Equatable {
    let windowID: Int
    let index: Int
    let title: String
    let url: String

    var displayTitle: String { title.isEmpty ? (url.isEmpty ? "Untitled tab" : url) : title }
    var host: String { URL(string: url)?.host ?? url }
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
        let title: String
        let host: String
        let text: String
    }
    private let entries: [Entry]

    init(_ tabs: [SafariTab]) {
        entries = tabs.map { tab in
            let title = TabSearch.normalized(tab.displayTitle)
            return Entry(tab: tab, title: title, host: TabSearch.normalized(tab.host),
                         text: title + " " + TabSearch.normalized(tab.url))
        }
    }

    func results(query: String) -> [SafariTab] {
        matches(query: query).map(\.tab)
    }

    func matches(query: String) -> [Match] {
        let query = TabSearch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return entries.map { Match(tab: $0.tab, relevance: 0) } }
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.enumerated().compactMap { offset, entry -> (Int, Int, SafariTab)? in
            guard tokens.allSatisfy({ entry.text.contains($0) }) else { return nil }
            let score = entry.host == query ? 100 : entry.title == query ? 95 : entry.host.hasPrefix(query) ? 90 : entry.title.hasPrefix(query) ? 85 : entry.title.contains(query) ? 80 : 60
            return (score, offset, entry.tab)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map { Match(tab: $0.2, relevance: $0.0) }
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
