import Foundation

/// An identifier that ties pages about the same piece of work together.
struct TabEntity: Hashable {
    enum Kind: Hashable {
        /// A ticket key such as ACME-123, found in a title or address.
        case issue
        /// A pull request, merge request or issue of a code repository: acme/api#4.
        case item
        case repository
        /// A Google Docs, Sheets or Slides file.
        case document
        case site
    }

    let kind: Kind
    let value: String

    var strength: Double {
        switch kind {
        case .issue, .item, .document: return 1
        case .repository: return 0.5
        case .site: return 0.15
        }
    }

    var label: String {
        switch kind {
        case .issue, .item: return value
        case .repository: return "Repository " + value
        case .document: return "Same document"
        case .site: return value
        }
    }
}

enum RelatedTabs {
    /// The weakest relation worth naming on a result row.
    static let named = 0.5
    private static let issuePattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9-])([A-Z][A-Z0-9]{1,9})-([1-9][0-9]{0,6})(?![A-Za-z0-9])"#)
    // Standards and versions that look like ticket keys.
    private static let notIssues: Set<String> = ["UTF", "ISO", "SHA", "MD", "COVID", "GPT", "RFC", "ES", "HTTP", "TLS", "IPV", "WCAG", "X"]
    private static let notOwners: Set<String> = [
        "about", "account", "apps", "collections", "dashboard", "enterprise", "explore", "features", "issues",
        "login", "marketplace", "new", "notifications", "orgs", "pricing", "pulls", "search", "settings",
        "sponsors", "topics", "trending", "users"
    ]

    static func entities(title: String, url: String) -> Set<TabEntity> {
        var found = Set<TabEntity>()
        for text in [title, url.removingPercentEncoding ?? url] {
            let range = NSRange(text.startIndex..., in: text)
            for match in issuePattern.matches(in: text, range: range) {
                guard let project = Range(match.range(at: 1), in: text), !notIssues.contains(String(text[project])),
                      let whole = Range(match.range, in: text) else { continue }
                found.insert(TabEntity(kind: .issue, value: String(text[whole])))
            }
        }
        guard let components = URLComponents(string: url), let rawHost = components.host?.lowercased(), !rawHost.isEmpty else {
            return found
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        found.insert(TabEntity(kind: .site, value: host))
        let path = components.path.split(separator: "/").map(String.init)
        if host == "github.com" || host == "gitlab.com" || host.hasPrefix("gitlab."), path.count >= 2,
           !notOwners.contains(path[0].lowercased()) {
            let repository = (path[0] + "/" + path[1]).lowercased()
            found.insert(TabEntity(kind: .repository, value: repository))
            // GitHub: owner/repo/pull/4; GitLab: owner/repo/-/merge_requests/4.
            let rest = Array(path.dropFirst(2).drop { $0 == "-" })
            if rest.count >= 2, ["pull", "issues", "merge_requests"].contains(rest[0]), Int(rest[1]) != nil {
                found.insert(TabEntity(kind: .item, value: repository + "#" + rest[1]))
            }
        }
        if host == "docs.google.com", path.count >= 3, ["document", "spreadsheets", "presentation"].contains(path[0]),
           path[1] == "d" {
            found.insert(TabEntity(kind: .document, value: path[2]))
        }
        return found
    }

    /// How closely each other open tab relates to `active`, with the strongest identifier they share.
    static func relations(to active: SafariTab?, in tabs: [SafariTab]) -> [SafariTab: (strength: Double, shared: TabEntity)] {
        guard let active else { return [:] }
        let anchor = entities(title: active.title, url: active.url)
        guard !anchor.isEmpty else { return [:] }
        var result: [SafariTab: (strength: Double, shared: TabEntity)] = [:]
        for tab in tabs where tab != active {
            let shared = entities(title: tab.title, url: tab.url).intersection(anchor)
            guard let strongest = shared.max(by: { ($0.strength, $1.value) < ($1.strength, $0.value) }) else { continue }
            result[tab] = (strongest.strength, strongest)
        }
        return result
    }
}
