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
}
