import Foundation

/// Actions typed after "`" in place of a search, such as "`move" or "`group". Each names the browsers it works in,
/// and the palette lists only those of the browser it opened over.
enum PaletteCommand: String, CaseIterable {
    case move, copy, dupes, sweep, undo, group, ungroup, mute

    static let prefix = "`"
    /// How many days a tab goes unviewed before `sweep` closes it, unless a number is typed after it.
    static let sweepDays = 7

    var name: String { rawValue }

    var summary: String {
        switch self {
        case .move: return "Move this tab to another browser or profile"
        case .copy: return "Copy this tab's address"
        case .dupes: return "Close duplicate tabs"
        case .sweep: return "Close tabs not viewed for a while"
        case .undo: return "Reopen tabs Tab Scout closed"
        case .group: return "Group this window's tabs by topic"
        case .ungroup: return "Take this window's tabs out of their groups"
        case .mute: return "Mute tabs playing sound, or unmute them"
        }
    }

    var browsers: Set<Browser> {
        switch self {
        // Chrome lets only extensions group and mute tabs; Safari lets no other app do either. Firefox and Zen
        // are reached through Tab Scout's extension anyway, which mutes there too.
        case .group, .ungroup: return [.chrome]
        case .mute: return [.chrome, .firefox, .zen]
        case .move, .copy, .dupes, .sweep, .undo: return Set(Browser.allCases)
        }
    }

    /// The system symbol drawn beside the command.
    var symbol: String {
        switch self {
        case .move: return "arrow.right.square"
        case .copy: return "doc.on.doc"
        case .dupes: return "square.on.square"
        case .sweep: return "wind"
        case .undo: return "arrow.uturn.backward"
        case .group: return "rectangle.3.group"
        case .ungroup: return "rectangle.split.3x1"
        case .mute: return "speaker.slash"
        }
    }

    /// The text after "`", or nil when the text is not a command.
    static func query(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// The commands `browser` supports that fit the typed text: names starting with its first word, then
    /// summaries mentioning all of it.
    static func matches(_ query: String, in browser: Browser) -> [PaletteCommand] {
        let text = query.lowercased().trimmingCharacters(in: .whitespaces)
        let supported = allCases.filter { $0.browsers.contains(browser) }
        guard let first = text.split(whereSeparator: \.isWhitespace).first.map(String.init) else { return supported }
        let named = supported.filter { $0.name.hasPrefix(first) }
        return named + supported.filter { !named.contains($0) && $0.summary.lowercased().contains(text) }
    }

    /// The rows listed for the typed text. Words after a command's name pick among its rows: a place for `move`,
    /// a form for `copy`, a number of days for `sweep`.
    static func choices(_ query: String, context: CommandContext) -> [CommandChoice] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let argument = words.dropFirst().joined(separator: " ")
        return matches(query, in: context.browser).flatMap { command -> [CommandChoice] in
            // Text that found a command through its summary says nothing about its rows.
            let named = words.first.map { command.name.hasPrefix($0) } ?? false
            return command.choices(argument: named ? argument : "", context: context)
        }
    }

    private func choices(argument: String, context: CommandContext) -> [CommandChoice] {
        switch self {
        case .move:
            guard !context.places.isEmpty else {
                return [CommandChoice(command: self, title: name, detail: "Open another browser or Chrome profile to move tabs there")]
            }
            let wanted = argument == "to" ? "" : argument.hasPrefix("to ") ? String(argument.dropFirst(3)) : argument
            return context.places.filter { wanted.isEmpty || $0.name.lowercased().contains(wanted) }.map { place in
                CommandChoice(command: self, option: place.id, title: "move to \(place.name)",
                              detail: "Open this tab in \(place.name) and close it here; Option+Enter keeps it")
            }
        case .copy:
            let forms: [(option: String, title: String, detail: String, words: [String])] = [
                ("address", "copy", "Copy this tab's address", ["address", "url"]),
                ("markdown", "copy link", "Copy a Markdown link with this tab's title", ["link", "markdown", "md"])
            ]
            return forms.filter { form in argument.isEmpty || form.words.contains { $0.hasPrefix(argument) } }.map {
                CommandChoice(command: self, option: $0.option, title: $0.title, detail: $0.detail)
            }
        case .dupes:
            return [CommandChoice(command: self, title: name, detail: context.duplicates == 0 ? "No page is open twice here"
                                  : "Close \(Self.counted(context.duplicates, "duplicate tab")) and keep one of each page")]
        case .sweep:
            let days = min(max(Int(argument) ?? Self.sweepDays, 1), 365)
            let found = context.stale(days)
            let span = Self.counted(days, "day")
            return [CommandChoice(command: self, option: String(days), title: days == Self.sweepDays ? name : "\(name) \(days)",
                                  detail: found == 0 ? "No tab here went unviewed for \(span)"
                                  : "Close \(Self.counted(found, "tab")) not viewed for \(span)")]
        case .undo:
            return [CommandChoice(command: self, title: name, detail: context.undoable == 0 ? "Nothing to reopen"
                                  : "Reopen \(Self.counted(context.undoable, "tab")) Tab Scout closed")]
        case .group, .ungroup, .mute:
            return [CommandChoice(command: self, title: name, detail: summary)]
        }
    }

    /// "1 tab" or "7 tabs".
    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// "[title](address)", with whatever would end the title or the address early escaped.
    static func markdownLink(title: String, url: String) -> String {
        let shown = (title.isEmpty ? url : title).split(whereSeparator: \.isNewline).joined(separator: " ")
        let name = ["\\", "[", "]"].reduce(shown) { $0.replacingOccurrences(of: $1, with: "\\" + $1) }
        let address = [(" ", "%20"), ("(", "%28"), (")", "%29")].reduce(url) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        return "[\(name)](\(address))"
    }
}

/// A place a tab can move to: another browser, or a Chrome profile.
struct CommandPlace: Equatable {
    let id: String
    let name: String
}

/// What the commands would act on now, which their rows describe.
struct CommandContext {
    var browser = Browser.safari
    /// The other places, in the order the palette swipes through them.
    var places: [CommandPlace] = []
    /// How many tabs `dupes` would close.
    var duplicates = 0
    /// How many tabs went unviewed for this many days.
    var stale: (Int) -> Int = { _ in 0 }
    /// How many tabs `undo` would reopen.
    var undoable = 0
}

/// One row of command mode: a command and, where it takes one, what it goes to or how it works.
struct CommandChoice: Equatable {
    let command: PaletteCommand
    /// The place a tab moves to, the form an address is copied in, or the days `sweep` allows.
    var option: String?
    let title: String
    let detail: String
}
