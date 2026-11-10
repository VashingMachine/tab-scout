import Foundation

@main
struct CommandTests {
    static var checks = 0

    static func main() {
        expect(PaletteCommand.query(in: " `gr ") == "gr", "A leading ` starts a command")
        expect(PaletteCommand.query(in: "`") == "" && PaletteCommand.query(in: "a`b") == nil && PaletteCommand.query(in: "?x") == nil,
               "Only a leading ` counts, even before a name is typed")
        expect(PaletteCommand.matches("", in: .chrome) == PaletteCommand.allCases, "Chrome lists every command")
        expect(PaletteCommand.matches("", in: .safari) == [.move, .copy, .dupes, .sweep, .undo],
               "Safari lists the commands that need nothing only Chrome offers")
        expect(PaletteCommand.matches("group", in: .safari).isEmpty && PaletteCommand.matches("mu", in: .safari).isEmpty,
               "Safari never lists a command it cannot run")
        expect(PaletteCommand.matches("GR", in: .chrome) == [.group, .ungroup] && PaletteCommand.matches("sw", in: .chrome) == [.sweep],
               "Names match from their start, ignoring case, before summaries that mention the text")
        expect(PaletteCommand.matches("topic", in: .chrome) == [.group], "Summaries match too")
        expect(PaletteCommand.matches("roup", in: .chrome) == [.group, .ungroup] && PaletteCommand.matches("zebra", in: .chrome).isEmpty,
               "Text inside a name is found through the summary, and unrelated text finds nothing")
        expect(PaletteCommand.matches("m", in: .chrome) == [.move, .mute] && PaletteCommand.matches("move work", in: .chrome) == [.move],
               "Only the first word names the command")
        expect(PaletteCommand.allCases.allSatisfy { !$0.summary.isEmpty && !$0.browsers.isEmpty && !$0.symbol.isEmpty },
               "Every command describes itself, has its own symbol and works somewhere")
        expect(Set(PaletteCommand.allCases.map(\.symbol)).count == PaletteCommand.allCases.count, "No two commands share a symbol")

        var context = CommandContext(browser: .safari)
        expect(PaletteCommand.choices("move", context: context).map(\.option) == [nil],
               "With nowhere to go, move still lists one row, which says so")
        context.places = [CommandPlace(id: "chrome:Profile 3", name: "Work"), CommandPlace(id: "chrome:Default", name: "Personal")]
        let moves = PaletteCommand.choices("m", context: context)
        expect(moves.map(\.option) == ["chrome:Profile 3", "chrome:Default"] && moves[0].title == "move to Work",
               "Move lists a row per other place, the next place first, so `m and Enter moves there")
        expect(PaletteCommand.choices("move pers", context: context).map(\.option) == ["chrome:Default"]
               && PaletteCommand.choices("move to WORK", context: context).map(\.option) == ["chrome:Profile 3"]
               && PaletteCommand.choices("move to", context: context).count == 2
               && PaletteCommand.choices("move nowhere", context: context).isEmpty, "Text after move picks the place by name")

        expect(PaletteCommand.choices("copy", context: context).map(\.option) == ["address", "markdown"]
               && PaletteCommand.choices("copy md", context: context).map(\.option) == ["markdown"]
               && PaletteCommand.choices("copy link", context: context).map(\.title) == ["copy link"]
               && PaletteCommand.choices("copy u", context: context).map(\.option) == ["address"], "Copy offers the address or a Markdown link")
        expect(PaletteCommand.choices("address", context: context).map(\.option) == ["address", "markdown"],
               "A command found through its summary lists all its rows")

        expect(PaletteCommand.choices("dupes", context: context)[0].detail == "No page is open twice here", "Nothing to close is said plainly")
        context.duplicates = 1
        expect(PaletteCommand.choices("du", context: context)[0].detail.contains("1 duplicate tab "), "One duplicate is counted in the singular")
        context.stale = { days in days >= 14 ? 3 : 12 }
        let sweep = PaletteCommand.choices("sweep", context: context)[0]
        expect(sweep.option == "7" && sweep.title == "sweep" && sweep.detail == "Close 12 tabs not viewed for 7 days",
               "Sweep allows a week unless told otherwise")
        let longer = PaletteCommand.choices("sweep 14", context: context)[0]
        expect(longer.option == "14" && longer.title == "sweep 14" && longer.detail == "Close 3 tabs not viewed for 14 days",
               "A number after sweep is its days")
        expect(PaletteCommand.choices("sweep 0", context: context)[0].option == "1"
               && PaletteCommand.choices("sweep soon", context: context)[0].option == "7", "Days stay sensible whatever is typed")
        expect(PaletteCommand.choices("undo", context: context)[0].detail == "Nothing to reopen", "Undo says when there is nothing to reopen")
        context.undoable = 4
        expect(PaletteCommand.choices("undo", context: context)[0].detail == "Reopen 4 tabs Tab Scout closed", "Undo counts what it reopens")
        expect(PaletteCommand.choices("", context: context).count == 7 && PaletteCommand.choices("", context: context).allSatisfy { !$0.detail.isEmpty },
               "With nothing typed every row of every command is listed and explained")
        context.browser = .chrome
        expect(PaletteCommand.choices("mute", context: context).map(\.command) == [.mute], "Chrome's own commands are single rows")

        expect(PaletteCommand.markdownLink(title: "Fix [ACT-1] (draft)", url: "https://example.org/a(b) c")
               == "[Fix \\[ACT-1\\] (draft)](https://example.org/a%28b%29%20c)", "A Markdown link survives brackets, parentheses and spaces")
        expect(PaletteCommand.markdownLink(title: "", url: "https://example.org/") == "[https://example.org/](https://example.org/)"
               && PaletteCommand.markdownLink(title: "Two\nlines", url: "https://e.org/") == "[Two lines](https://e.org/)",
               "A missing title falls back on the address, and a title stays on one line")
        expect(PaletteCommand.counted(1, "tab") == "1 tab" && PaletteCommand.counted(0, "tab") == "0 tabs", "Counts read naturally")
        print("Passed \(checks) command checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
}
