import Foundation

/// Actions typed after "`" in place of a search, such as "`group". Each names the browsers it works in, and the
/// palette lists only those of the browser it opened over.
enum PaletteCommand: String, CaseIterable {
    case group

    static let prefix = "`"

    var name: String { rawValue }

    var summary: String {
        switch self {
        case .group: return "Group this window's tabs by topic"
        }
    }

    var browsers: Set<Browser> {
        switch self {
        // Safari lets no other app make tab groups.
        case .group: return [.chrome]
        }
    }

    /// The text after "`", or nil when the text is not a command.
    static func query(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// The commands `browser` supports that fit the typed text: names starting with it, then summaries mentioning it.
    static func matches(_ query: String, in browser: Browser) -> [PaletteCommand] {
        let text = query.lowercased()
        let supported = allCases.filter { $0.browsers.contains(browser) }
        guard !text.isEmpty else { return supported }
        let named = supported.filter { $0.name.hasPrefix(text) }
        return named + supported.filter { !named.contains($0) && $0.summary.lowercased().contains(text) }
    }
}
