import Foundation

@main
struct SafariNativeNewTabTests {
    static var checks = 0

    static func main() throws {
        try exactCommand()
        try alternatives()
        try deniedAndMissing()
        try fileMenuIsolation()
        try traversalBoundaries()
        try failures()
        print("Passed \(checks) native Safari new-tab checks")
    }

    static func exactCommand() throws {
        let fixture = Fixture([
            0: Node(role: "AXMenu", children: [1, 2, 3]),
            1: command(modifiers: 1),
            2: command(),
            3: Node(role: "AXMenuItem", identifier: "CloseTab", character: "w", modifiers: 0, enabled: true)
        ])
        let data = try SafariNativeNewTab.open(using: fixture.access, accessibilityTrusted: { true })
        expect(data == Data("ok".utf8), "Successful native creation acknowledges completion")
        expect(fixture.pressed == [2], "Only the standard Command-T NewTab menu item is pressed once")
        expect(fixture.rootReads == 1, "The search starts only from Safari's menu bar")
        expect(!fixture.reads.contains("character:3"), "Unrelated commands need no shortcut metadata reads")
        let uppercase = Fixture([0: Node(role: "AXMenu", children: [1]), 1: command(character: "T")])
        let uppercaseData = try SafariNativeNewTab.open(using: uppercase.access, accessibilityTrusted: { true })
        expect(uppercaseData == Data("ok".utf8), "Uppercase menu shortcut characters acknowledge completion")
        expect(uppercase.pressed == [1], "Uppercase T with no extra modifiers is the same standard Command-T action")
    }

    static func alternatives() throws {
        for modifiers in [1, 2, 3, 4, 8, 16] {
            let fixture = Fixture([0: Node(role: "AXMenuBar", children: [1]), 1: command(modifiers: modifiers)])
            expectFailure(fixture, "Modified or no-command alternatives are never activated")
            let uppercase = Fixture([0: Node(role: "AXMenu", children: [1]), 1: command(modifiers: modifiers, character: "T")])
            expectFailure(uppercase, "Uppercase shortcut characters do not bypass modifier rejection")
        }
        for invalid in [
            Node(role: "AXMenuItem", identifier: "NewTab", character: "n", modifiers: 0, enabled: true),
            Node(role: "AXMenuItem", identifier: "NewTab", character: "t", modifiers: nil, enabled: true),
            Node(role: "AXMenuItem", identifier: "NewTab", character: "t", modifiers: 0, enabled: false),
            Node(role: "AXMenuItem", identifier: "NewTab", character: "t", modifiers: 0, enabled: nil),
            Node(role: "AXMenuItem", identifier: "NewTabAtEnd", character: "t", modifiers: 0, enabled: true),
            Node(role: "AXMenuItem", identifier: nil, character: "t", modifiers: 0, enabled: true),
            Node(role: "AXMenuBarItem", identifier: "NewTab", character: "t", modifiers: 0, enabled: true)
        ] {
            expectFailure(Fixture([0: Node(role: "AXMenuBar", children: [1]), 1: invalid]),
                          "Only exact enabled menu-item metadata can invoke New Tab")
        }
        expectFailure(Fixture([0: Node(role: "AXMenuBar", children: [1, 2]), 1: command(), 2: command()]),
                      "Ambiguous standard commands are not pressed")
    }

    static func deniedAndMissing() throws {
        let fixture = Fixture([0: Node(role: "AXMenuBar", children: [1]), 1: command()])
        expectError({ try SafariNativeNewTab.open(using: fixture.access, accessibilityTrusted: { false }) },
                    message: SafariNativeNewTab.permissionMessage, "Denied Accessibility has an actionable error")
        expect(fixture.rootReads == 0 && fixture.reads.isEmpty && fixture.pressed.isEmpty,
               "Permission denial reads no Safari metadata and performs no actions")
        expectFailure(Fixture([0: Node(role: "AXMenuBar")]), "Missing command fails without an empty-tab fallback")
        let missingSafari = Fixture([:])
        missingSafari.failOn = "root"
        expectError({ try SafariNativeNewTab.open(using: missingSafari.access, accessibilityTrusted: { true }) },
                    message: BridgeError.unavailable.localizedDescription, "Missing Safari is propagated")
        expect(missingSafari.pressed.isEmpty, "Missing Safari cannot invoke anything")
    }

    static func fileMenuIsolation() throws {
        let fixture = Fixture([
            0: Node(role: "AXMenu", children: [1]), 1: command(),
            -3: Node(role: "AXMenuBarItem", children: [-4]),
            -4: Node(role: "AXMenu", identifier: "SafariHistoryMenu", children: Array(1000...10000))
        ], menuBarItems: [-1, -3])
        _ = try SafariNativeNewTab.open(using: fixture.access, accessibilityTrusted: { true })
        expect(fixture.pressed == [1], "A huge History menu does not prevent the File command")
        expect(!fixture.reads.contains("children:-4"), "History-menu contents are never enumerated")
        expect(!fixture.reads.contains("role:1000"), "History entries are never inspected")

        let missingFile = Fixture([0: Node(role: "AXMenu", children: [1]), 1: command()],
                                  fileMenuIdentifier: "OtherMenu")
        expectFailure(missingFile, "The native File-menu identifier is required")
        expect(!missingFile.reads.contains("children:0"), "Unrecognized menu contents are not inspected")

        let duplicateFile = Fixture([
            0: Node(role: "AXMenu", children: [1]), 1: command(),
            -3: Node(role: "AXMenuBarItem", children: [-4]),
            -4: Node(role: "AXMenu", identifier: "SafariFileMenu", children: [2]), 2: command()
        ], menuBarItems: [-1, -3])
        expectFailure(duplicateFile, "Ambiguous File menus are rejected without action")

        let oversizedTop = Fixture([0: Node(role: "AXMenu", children: [1]), 1: command()],
                                   menuBarItems: Array(100...129))
        expectFailure(oversizedTop, "Top-level discovery has a separate 30-node budget")
        expect(!oversizedTop.reads.contains("role:100"), "Oversized top-level menus are not expanded")
    }

    static func traversalBoundaries() throws {
        let outside = Fixture([
            0: Node(role: "AXMenuBar", children: [1, 2]),
            1: Node(role: "AXWindow", children: [3]),
            2: command(), 3: command()
        ])
        _ = try SafariNativeNewTab.open(using: outside.access, accessibilityTrusted: { true })
        expect(outside.pressed == [2], "Window or webpage roles cannot become part of the menu traversal")
        expect(!outside.reads.contains("children:1") && !outside.reads.contains("role:3"),
               "No children or content of non-menu nodes are read")

        var deep = [Int: Node]()
        for id in 0...5 { deep[id] = Node(role: id == 0 ? "AXMenuBar" : "AXMenu", children: [id + 1]) }
        deep[6] = command()
        let depthFixture = Fixture(deep)
        expectFailure(depthFixture, "Commands beyond five menu levels are not invoked")
        expect(!depthFixture.reads.contains("role:6"), "The depth bound prevents reading deeper node metadata")
        deep[5] = command()
        deep.removeValue(forKey: 6)
        let atDepth = Fixture(deep)
        _ = try SafariNativeNewTab.open(using: atDepth.access, accessibilityTrusted: { true })
        expect(atDepth.pressed == [5], "The maximum permitted depth remains usable")

        let tooWide = Fixture([0: Node(role: "AXMenuBar", children: Array(1...200))])
        expectFailure(tooWide, "A menu exceeding the 200-node budget fails before visiting its children")
        expect(!tooWide.reads.contains("role:1"), "An oversized child list is not expanded")
        var bounded = [0: Node(role: "AXMenuBar", children: Array(1...199))]
        for id in 1...199 { bounded[id] = id == 199 ? command() : Node(role: "AXMenuItem") }
        let atNodeLimit = Fixture(bounded)
        _ = try SafariNativeNewTab.open(using: atNodeLimit.access, accessibilityTrusted: { true })
        expect(atNodeLimit.pressed == [199], "Exactly 200 menu nodes remain within budget")

        let cycle = Fixture([0: Node(role: "AXMenuBar", children: [0])])
        expectFailure(cycle, "Malformed cyclic trees cannot loop forever or perform actions")
        expect(cycle.reads.filter { $0 == "role:0" }.count <= 7, "Cycle traversal is bounded by depth")

        let timedOut = Fixture([0: Node(role: "AXMenuBar", children: [1]), 1: command()])
        let start = Date(timeIntervalSince1970: 0)
        var reads = 0
        expectError({
            try SafariNativeNewTab.open(using: timedOut.access, accessibilityTrusted: { true }, now: {
                reads += 1
                return reads == 1 ? start : start.addingTimeInterval(3)
            })
        }, message: SafariNativeNewTab.unavailableMessage, "Menu traversal has a time bound")
        expect(timedOut.pressed.isEmpty && timedOut.rootReads == 0 && timedOut.reads.isEmpty,
               "Timed-out traversal performs no command or metadata reads")
    }

    static func failures() throws {
        for operation in ["role:-2", "children:-2", "role:-1", "children:-1", "identifier:0", "children:0", "identifier:1", "character:1", "modifiers:1", "enabled:1", "children:1", "press:1"] {
            let fixture = Fixture([0: Node(role: "AXMenuBar", children: [1]), 1: command()])
            fixture.failOn = operation
            expectError({ try SafariNativeNewTab.open(using: fixture.access, accessibilityTrusted: { true }) },
                        message: SafariNativeNewTab.unavailableMessage, "AX lookup and press failures propagate")
            expect(fixture.pressed.isEmpty, "Failed AX operations have no successful or fallback action")
            expect(fixture.reads.filter { $0 == operation }.count == 1, "Failed operations are attempted only once")
        }
    }

    private static func command(modifiers: Int = 0, character: String = "t") -> Node {
        Node(role: "AXMenuItem", identifier: "NewTab", character: character, modifiers: modifiers, enabled: true)
    }

    private static func expectFailure(_ fixture: Fixture, _ message: String) {
        expectError({ try SafariNativeNewTab.open(using: fixture.access, accessibilityTrusted: { true }) },
                    message: SafariNativeNewTab.unavailableMessage, message)
        expect(fixture.pressed.isEmpty, "Failure does not create a tab or retry a command")
    }

    static func expectError(_ operation: () throws -> Data, message: String, _ description: String) {
        do { _ = try operation(); fatalError(description) }
        catch { expect(error.localizedDescription == message, description) }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
}

private struct Node {
    var role: String?
    var identifier: String? = nil
    var character: String? = nil
    var modifiers: Int? = nil
    var enabled: Bool? = nil
    var children: [Int] = []
}

private final class Fixture {
    let nodes: [Int: Node]
    var reads = [String]()
    var rootReads = 0
    var pressed = [Int]()
    var failOn: String?

    init(_ nodes: [Int: Node], menuBarItems: [Int] = [-1], fileMenuIdentifier: String? = "SafariFileMenu") {
        var menuNodes = nodes
        if var fileMenu = menuNodes[0] {
            fileMenu.role = "AXMenu"
            fileMenu.identifier = fileMenuIdentifier
            menuNodes[0] = fileMenu
        }
        menuNodes[-2] = Node(role: "AXMenuBar", children: menuBarItems)
        menuNodes[-1] = Node(role: "AXMenuBarItem", children: [0])
        self.nodes = menuNodes
    }

    func read(_ operation: String, node: Int) throws -> Node {
        reads.append("\(operation):\(node)")
        guard failOn != "\(operation):\(node)", let value = nodes[node] else {
            throw BridgeError.script(SafariNativeNewTab.unavailableMessage)
        }
        return value
    }

    var access: SafariNewTabMenuAccess<Int> {
        SafariNewTabMenuAccess(
            menuBar: {
                self.rootReads += 1
                if self.failOn == "root" { throw BridgeError.unavailable }
                return -2
            },
            role: { try self.read("role", node: $0).role },
            identifier: { try self.read("identifier", node: $0).identifier },
            commandCharacter: { try self.read("character", node: $0).character },
            commandModifiers: { try self.read("modifiers", node: $0).modifiers },
            enabled: { try self.read("enabled", node: $0).enabled },
            children: { try self.read("children", node: $0).children },
            press: {
                _ = try self.read("press", node: $0)
                self.pressed.append($0)
            }
        )
    }
}
