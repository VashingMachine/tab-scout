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

    /// Shift held without other shortcut modifiers lists that new tab first, so Enter's target is visible.
    static func holdsShiftAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control, .option, .shift]) == .shift
    }
}
