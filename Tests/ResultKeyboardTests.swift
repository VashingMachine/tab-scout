import AppKit

@main
struct ResultKeyboardTests {
    static var checks = 0

    static func main() {
        let accessoryFlags: [NSEvent.ModifierFlags] = [
            [], .numericPad, .function, .capsLock,
            [.numericPad, .function], [.numericPad, .capsLock], [.function, .capsLock],
            [.numericPad, .function, .capsLock]
        ]
        let shortcutFlags: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]

        for keyCode: UInt16 in [125, 126] {
            let step = keyCode == 125 ? 1 : -1
            for accessory in accessoryFlags {
                for combination in 0..<16 {
                    var flags = accessory
                    for (bit, modifier) in shortcutFlags.enumerated() where combination & (1 << bit) != 0 {
                        flags.formUnion(modifier)
                    }
                    let input = event(keyCode: keyCode, flags: flags)
                    expect(ResultKeyboard.navigationStep(for: input) == (combination == 0 ? step : nil),
                           "Arrow \(keyCode) ignores accessory flags but respects shortcut modifiers \(flags.rawValue)")
                }
            }
        }

        for keyCode: UInt16 in [0, 17, 36, 76, 53, 123, 124, 116, 121, 115, 119] {
            for flags: NSEvent.ModifierFlags in [[], [.numericPad, .function, .capsLock]] {
                expect(ResultKeyboard.navigationStep(for: event(keyCode: keyCode, flags: flags)) == nil,
                       "Non-Up/Down key \(keyCode) does not navigate results even with accessory flags")
            }
        }

        for accessory in accessoryFlags {
            for combination in 0..<16 {
                var flags = accessory
                for (bit, modifier) in shortcutFlags.enumerated() where combination & (1 << bit) != 0 {
                    flags.formUnion(modifier)
                }
                let command = combination & 1 != 0, shift = combination & 8 != 0
                expect(ResultKeyboard.forcesNewTab(flags) == (command || shift),
                       "Enter opens a new tab exactly when Command or Shift is held \(flags.rawValue)")
                expect(ResultKeyboard.holdsShiftAlone(flags) == (combination == 8),
                       "Only Shift without other shortcut modifiers lists the new tab first \(flags.rawValue)")
            }
        }

        let standardArrow = event(keyCode: 125, flags: [.numericPad, .function])
        expect(!standardArrow.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               "Regression fixture reproduces the nonempty flags carried by standard AppKit arrows")
        print("Passed \(checks) synthetic AppKit result keyboard checks")
    }

    static func event(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        let characters = keyCode == 126 ? "\u{F700}" : keyCode == 125 ? "\u{F701}" : "x"
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: keyCode) else {
            preconditionFailure("Could not construct offline keyboard fixture")
        }
        return event
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
}
