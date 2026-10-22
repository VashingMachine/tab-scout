import Foundation

@main
struct CommandTests {
    static var checks = 0

    static func main() {
        expect(PaletteCommand.query(in: " `gr ") == "gr", "A leading ` starts a command")
        expect(PaletteCommand.query(in: "`") == "" && PaletteCommand.query(in: "a`b") == nil && PaletteCommand.query(in: "?x") == nil,
               "Only a leading ` counts, even before a name is typed")
        expect(PaletteCommand.matches("", in: .chrome) == [.group], "Chrome lists the group command")
        expect(PaletteCommand.matches("", in: .safari).isEmpty && PaletteCommand.matches("group", in: .safari).isEmpty,
               "Safari never lists a command it cannot run")
        expect(PaletteCommand.matches("GR", in: .chrome) == [.group], "Names match from their start, ignoring case")
        expect(PaletteCommand.matches("topic", in: .chrome) == [.group], "Summaries match too")
        expect(PaletteCommand.matches("roup", in: .chrome) == [.group] && PaletteCommand.matches("close", in: .chrome).isEmpty,
               "Text inside a name is found through the summary, and unrelated text finds nothing")
        expect(PaletteCommand.allCases.allSatisfy { !$0.summary.isEmpty && !$0.browsers.isEmpty },
               "Every command describes itself and works somewhere")
        print("Passed \(checks) command checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
}
