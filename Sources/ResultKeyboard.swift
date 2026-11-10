import AppKit

enum ResultKeyboard {
    static func navigationStep(for event: NSEvent) -> Int? {
        // Arrow keys carry numericPad/function flags even without shortcut modifiers.
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(shortcutModifiers).isEmpty else { return nil }
        switch event.keyCode {
        case 126: return -1
        case 125: return 1
        default: return nil
        }
    }

    /// Cmd+Enter and Shift+Enter open the typed text in a new tab even when a tab matches.
    static func forcesNewTab(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.isDisjoint(with: [.command, .shift])
    }

    /// Tab goes to the next place and Shift+Tab to the one before; with Option the tab on screen comes along.
    static func placeStep(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> (step: Int, carries: Bool)? {
        let held = flags.intersection([.command, .control, .option, .shift])
        guard keyCode == 48, held.isSubset(of: [.option, .shift]) else { return nil }
        return (held.contains(.shift) ? -1 : 1, held.contains(.option))
    }

    /// Command+W closes the selected tab, as it closes a tab in a browser. Command+Delete does too while nothing
    /// is typed; with text in the field it keeps deleting to the start of the line.
    static func closesTab(keyCode: UInt16, flags: NSEvent.ModifierFlags, typed: Bool) -> Bool {
        guard flags.intersection([.command, .control, .option, .shift]) == .command else { return false }
        return keyCode == 13 || (keyCode == 51 && !typed)
    }

    /// Shift held without other shortcut modifiers lists that new tab first, so Enter's target is visible.
    static func holdsShiftAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control, .option, .shift]) == .shift
    }
}
