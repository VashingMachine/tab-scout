import AppKit
import ApplicationServices

struct SafariNewTabMenuAccess<Node> {
    let menuBar: () throws -> Node
    let role: (Node) throws -> String?
    let identifier: (Node) throws -> String?
    let commandCharacter: (Node) throws -> String?
    let commandModifiers: (Node) throws -> Int?
    let enabled: (Node) throws -> Bool?
    let children: (Node) throws -> [Node]
    let press: (Node) throws -> Void
}

enum SafariNativeNewTab {
    static let maximumDepth = 5
    static let maximumNodes = 200
    static let unavailableMessage = "Safari's New Tab command is unavailable. Activate Safari and try again."
    static let permissionMessage = "Allow Tab Scout in System Settings > Privacy & Security > Accessibility (Device Control and Data Access), then reopen Tab Scout."

    static func open() throws -> Data {
        let access = SafariNewTabMenuAccess<AXUIElement>(
            menuBar: {
                guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else {
                    throw BridgeError.unavailable
                }
                let application = AXUIElementCreateApplication(safari.processIdentifier)
                guard AXUIElementSetMessagingTimeout(application, 0.5) == .success,
                      let value = try attribute(application, kAXMenuBarAttribute),
                      CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    throw BridgeError.script(unavailableMessage)
                }
                return value as! AXUIElement
            },
            role: { try attribute($0, kAXRoleAttribute) as? String },
            identifier: { try attribute($0, kAXIdentifierAttribute) as? String },
            commandCharacter: { try attribute($0, kAXMenuItemCmdCharAttribute) as? String },
            commandModifiers: { (try attribute($0, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue },
            enabled: { (try attribute($0, kAXEnabledAttribute) as? NSNumber)?.boolValue },
            children: {
                guard let value = try attribute($0, kAXChildrenAttribute) else { return [] }
                guard let children = value as? [AXUIElement] else { throw BridgeError.script(unavailableMessage) }
                return children
            },
            press: {
                let timeoutResult = AXUIElementSetMessagingTimeout($0, 0.5)
                guard timeoutResult == .success else { throw error(for: timeoutResult) }
                let result = AXUIElementPerformAction($0, kAXPressAction as CFString)
                guard result == .success else { throw error(for: result) }
            }
        )
        return try open(using: access, accessibilityTrusted: AXIsProcessTrusted)
    }

    static func open<Node>(using access: SafariNewTabMenuAccess<Node>, accessibilityTrusted: () -> Bool,
                           now: () -> Date = Date.init) throws -> Data {
        guard accessibilityTrusted() else { throw BridgeError.script(permissionMessage) }
        let deadline = now().addingTimeInterval(2)
        func bounded<Value>(_ operation: () throws -> Value) throws -> Value {
            guard now() < deadline else { throw BridgeError.script(unavailableMessage) }
            return try operation()
        }
        let menuBar = try bounded { try access.menuBar() }
        guard try bounded({ try access.role(menuBar) }) == kAXMenuBarRole else {
            throw BridgeError.script(unavailableMessage)
        }
        let menuBarItems = try bounded { try access.children(menuBar) }
        var topLevelNodes = 1 + menuBarItems.count
        guard topLevelNodes <= 30 else { throw BridgeError.script(unavailableMessage) }
        var fileMenus = [Node]()
        for item in menuBarItems {
            guard try bounded({ try access.role(item) }) == kAXMenuBarItemRole else { continue }
            let menus = try bounded { try access.children(item) }
            topLevelNodes += menus.count
            guard topLevelNodes <= 30 else { throw BridgeError.script(unavailableMessage) }
            for menu in menus {
                if try bounded({ try access.role(menu) }) == kAXMenuRole,
                   try bounded({ try access.identifier(menu) }) == "SafariFileMenu" {
                    fileMenus.append(menu)
                }
            }
        }
        guard fileMenus.count == 1, let fileMenu = fileMenus.first else {
            throw BridgeError.script(unavailableMessage)
        }
        var pending = [(fileMenu, 0)]
        var visited = 0
        var matches = [Node]()
        let menuRoles = Set([kAXMenuRole, kAXMenuItemRole])

        // Only inspect File-menu descendants, not history menus, windows, or webpage content.
        while let (node, depth) = pending.popLast() {
            guard visited < maximumNodes, depth <= maximumDepth, now() < deadline else {
                throw BridgeError.script(unavailableMessage)
            }
            visited += 1
            guard let role = try bounded({ try access.role(node) }), menuRoles.contains(role) else { continue }
            if role == kAXMenuItemRole as String,
               try bounded({ try access.identifier(node) }) == "NewTab",
               try bounded({ try access.commandCharacter(node) })?.lowercased() == "t",
               try bounded({ try access.commandModifiers(node) }) == 0,
               try bounded({ try access.enabled(node) }) == true {
                matches.append(node)
            }
            let children = try bounded { try access.children(node) }
            guard children.count <= maximumNodes - visited - pending.count else {
                throw BridgeError.script(unavailableMessage)
            }
            pending += children.reversed().map { ($0, depth + 1) }
        }
        guard matches.count == 1, let command = matches.first, now() < deadline else {
            throw BridgeError.script(unavailableMessage)
        }
        try bounded { try access.press(command) }
        return Data("ok".utf8)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        let timeoutResult = AXUIElementSetMessagingTimeout(element, 0.5)
        guard timeoutResult == .success else { throw error(for: timeoutResult) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .attributeUnsupported || result == .noValue { return nil }
        guard result == .success else { throw error(for: result) }
        return value
    }

    private static func error(for result: AXError) -> BridgeError {
        .script(result == .apiDisabled ? permissionMessage : unavailableMessage)
    }
}
