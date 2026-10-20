import AppKit

@main
struct PanelPlacementTests {
    static var checks = 0
    static let panel = CGSize(width: 660, height: 440)
    static let primary = PanelPlacement.Screen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 30, width: 1440, height: 846)
    )
    static let left = PanelPlacement.Screen(
        frame: CGRect(x: -1280, y: 0, width: 1280, height: 1024),
        visibleFrame: CGRect(x: -1280, y: 0, width: 1280, height: 1000)
    )
    static let above = PanelPlacement.Screen(
        frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 876)
    )
    static let right = PanelPlacement.Screen(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: 24, width: 1920, height: 1032)
    )

    static func main() {
        coordinateConversion()
        safariWindowCentering()
        screenSelection()
        visibleFrameClamping()
        fallbacksAndInvalidInput()
        placementProperties()
        print("Passed \(checks) deterministic panel placement checks")
    }

    static func coordinateConversion() {
        expectRect(PanelPlacement.appKitFrame(
            fromAccessibilityFrame: CGRect(x: 100, y: 80, width: 1000, height: 600),
            primaryScreenTop: 900
        ), CGRect(x: 100, y: 220, width: 1000, height: 600),
        "Accessibility top-left coordinates convert using the primary display top")
        expectRect(PanelPlacement.appKitFrame(
            fromAccessibilityFrame: CGRect(x: -1200, y: -124, width: 1000, height: 700),
            primaryScreenTop: 900
        ), CGRect(x: -1200, y: 324, width: 1000, height: 700),
        "A taller display left of the primary does not replace the primary coordinate anchor")
        expectRect(PanelPlacement.appKitFrame(
            fromAccessibilityFrame: CGRect(x: 80, y: -800, width: 1000, height: 700),
            primaryScreenTop: 900
        ), CGRect(x: 80, y: 1000, width: 1000, height: 700),
        "Displays above the primary preserve negative Accessibility y positions")
        expectRect(PanelPlacement.appKitFrame(
            fromAccessibilityFrame: CGRect(x: 50, y: 1000, width: 1000, height: 700),
            primaryScreenTop: 900
        ), CGRect(x: 50, y: -800, width: 1000, height: 700),
        "Displays below the primary convert to negative AppKit y positions")

        for rect in invalidRects() {
            expect(PanelPlacement.appKitFrame(fromAccessibilityFrame: rect, primaryScreenTop: 900) == nil,
                   "Invalid Accessibility geometry is rejected")
        }
        for top in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
            expect(PanelPlacement.appKitFrame(fromAccessibilityFrame: primary.frame,
                                             primaryScreenTop: top) == nil,
                   "Nonfinite coordinate anchors are rejected")
        }
    }

    static func safariWindowCentering() {
        let frame = CGRect(x: 100, y: 160, width: 1000, height: 600)
        expectPoint(origin(frame), CGPoint(x: 270, y: 240),
                    "The panel centers in Safari, with no screen-centered vertical offset")
        expectPoint(origin(frame, fallback: left), CGPoint(x: 270, y: 240),
                    "An unrelated fallback display cannot move a Safari-centered panel")
        expectPoint(origin(CGRect(x: -1100, y: 200, width: 1000, height: 600)),
                    CGPoint(x: -930, y: 280), "A Safari window on the left display owns the panel")
        expectPoint(origin(CGRect(x: 100, y: 1100, width: 1000, height: 600)),
                    CGPoint(x: 270, y: 1180), "A Safari window above the primary owns the panel")
        expectPoint(origin(CGRect(x: 1500, y: 180, width: 1400, height: 800)),
                    CGPoint(x: 1870, y: 360), "The panel centers on the active Safari window on a larger display")
        expectPoint(origin(primary.frame), CGPoint(x: 390, y: 230),
                    "Fullscreen Safari uses its actual midpoint, not the inset visible frame midpoint")
        expectPoint(origin(CGRect(x: 300, y: 200, width: 400, height: 200)),
                    CGPoint(x: 170, y: 80), "A panel larger than Safari still uses the Safari window midpoint")
    }

    static func screenSelection() {
        let spanning = CGRect(x: -200, y: 100, width: 1000, height: 600)
        expectPoint(origin(spanning, fallback: left), CGPoint(x: 0, y: 180),
                    "Largest full-screen overlap wins rather than the fallback or mouse display")
        let mostlyLeft = CGRect(x: -800, y: 100, width: 1000, height: 600)
        expectPoint(origin(mostlyLeft), CGPoint(x: -660, y: 180),
                    "A spanning Safari window with greater left-display overlap clamps on that display")
        let offscreen = CGRect(x: 5000, y: 3000, width: 1000, height: 600)
        expectPoint(origin(offscreen, fallback: left), CGPoint(x: -970, y: 280),
                    "A completely offscreen window uses the supplied fallback screen center")
        expectPoint(origin(CGRect(x: 1440, y: 0, width: 1, height: 1)),
                    CGPoint(x: 1440, y: 24), "Touching a neighboring display does not count as an overlap")
        let tied = CGRect(x: -500, y: 100, width: 1000, height: 600)
        expectPoint(PanelPlacement.origin(panelSize: panel, browserFrame: tied,
                                          screens: [primary, left], fallbackScreen: right),
                    CGPoint(x: 0, y: 180), "Equal-overlap ties retain the first display instead of using fallback")
        expectPoint(PanelPlacement.origin(panelSize: panel, browserFrame: tied,
                                          screens: [left, primary], fallbackScreen: right),
                    CGPoint(x: -660, y: 180), "Equal-overlap tie selection remains stable in display order")
    }

    static func visibleFrameClamping() {
        expectPoint(origin(CGRect(x: 0, y: 300, width: 200, height: 200)), CGPoint(x: 0, y: 180),
                    "Left edge clamping keeps the full panel visible")
        expectPoint(origin(CGRect(x: 1300, y: 300, width: 100, height: 200)), CGPoint(x: 780, y: 180),
                    "Right edge clamping keeps the full panel visible")
        expectPoint(origin(CGRect(x: 500, y: -100, width: 500, height: 200)), CGPoint(x: 420, y: 30),
                    "Bottom clamping avoids the Dock area")
        expectPoint(origin(CGRect(x: 500, y: 800, width: 500, height: 150)), CGPoint(x: 420, y: 436),
                    "Top clamping avoids the menu bar area")
        expectPoint(origin(CGRect(x: 1300, y: 800, width: 100, height: 100)), CGPoint(x: 780, y: 436),
                    "Both axes clamp independently near a display corner")
        expectPoint(origin(primary.frame, size: CGSize(width: 1600, height: 1000)),
                    CGPoint(x: -80, y: -47), "An oversized panel is centered in the visible frame without resizing")
        expectPoint(origin(CGRect(x: 0, y: 100, width: 100, height: 200),
                           size: CGSize(width: 1600, height: 440)), CGPoint(x: -80, y: 30),
                    "Only an oversized horizontal axis uses visible-frame centering")
        expectPoint(origin(CGRect(x: 100, y: 500, width: 400, height: 200),
                           size: CGSize(width: 660, height: 1000)), CGPoint(x: 0, y: -47),
                    "Only an oversized vertical axis uses visible-frame centering")
        expectPoint(origin(nil, size: primary.visibleFrame.size), primary.visibleFrame.origin,
                    "A panel exactly as large as the usable display fills its visible frame")
    }

    static func fallbacksAndInvalidInput() {
        expectPoint(origin(nil), CGPoint(x: 390, y: 233),
                    "Without Safari window bounds, placement falls back to the visible screen center")
        expectPoint(origin(nil, fallback: left), CGPoint(x: -970, y: 280),
                    "No-window fallback respects a non-primary display")
        for frame in invalidRects() {
            expectPoint(origin(frame), CGPoint(x: 390, y: 233),
                        "Invalid Safari geometry falls back without retaining invalid coordinates")
        }
        for size in [CGSize.zero, CGSize(width: -1, height: 440), CGSize(width: 660, height: -1),
                     CGSize(width: CGFloat.nan, height: 440), CGSize(width: 660, height: CGFloat.infinity)] {
            expect(origin(primary.frame, size: size) == nil, "Invalid panel dimensions cannot produce placement")
        }
        expect(PanelPlacement.origin(panelSize: panel, browserFrame: nil, screens: [], fallbackScreen: nil) == nil,
               "No valid screen returns no placement")
        let invalid = PanelPlacement.Screen(frame: .zero, visibleFrame: .zero)
        expect(PanelPlacement.origin(panelSize: panel, browserFrame: primary.frame,
                                     screens: [invalid], fallbackScreen: invalid) == nil,
               "Unusable display geometry returns no placement")
        expectPoint(PanelPlacement.origin(panelSize: panel, browserFrame: primary.frame,
                                          screens: [invalid, primary], fallbackScreen: invalid),
                    CGPoint(x: 390, y: 230), "An invalid display does not hide valid Safari screen geometry")
        expectPoint(PanelPlacement.origin(panelSize: panel, browserFrame: nil,
                                          screens: [], fallbackScreen: primary),
                    CGPoint(x: 390, y: 233), "A valid fallback alone is sufficient for no-window placement")
    }

    static func placementProperties() {
        // This fixed grid covers ordinary, tiny, and partially offscreen Safari windows on every display.
        for screen in [primary, left, above, right] {
            for fractionX in [CGFloat(0.05), 0.25, 0.5, 0.75, 0.95] {
                for fractionY in [CGFloat(0.05), 0.25, 0.5, 0.75, 0.95] {
                    for size in [CGSize(width: 100, height: 100), CGSize(width: 600, height: 500),
                                 CGSize(width: 1100, height: 750)] {
                        let center = CGPoint(x: screen.frame.minX + screen.frame.width * fractionX,
                                             y: screen.frame.minY + screen.frame.height * fractionY)
                        let safari = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                            width: size.width, height: size.height)
                        guard let point = PanelPlacement.origin(panelSize: panel, browserFrame: safari,
                                                               screens: [screen], fallbackScreen: screen) else {
                            preconditionFailure("Valid fixture must have placement")
                        }
                        let actual = CGRect(origin: point, size: panel)
                        expect(screen.visibleFrame.insetBy(dx: -0.0001, dy: -0.0001).contains(actual),
                               "A fitting panel always remains entirely within its chosen visible display")
                        let desired = CGRect(x: center.x - panel.width / 2, y: center.y - panel.height / 2,
                                             width: panel.width, height: panel.height)
                        if screen.visibleFrame.contains(desired) {
                            expectPoint(point, desired.origin, "Unclamped placement remains exactly Safari-centered")
                        }
                    }
                }
            }
        }
    }

    static func origin(_ browserFrame: CGRect?, size: CGSize = panel,
                       fallback: PanelPlacement.Screen? = primary) -> CGPoint? {
        PanelPlacement.origin(panelSize: size, browserFrame: browserFrame,
                              screens: [primary, left, above, right], fallbackScreen: fallback)
    }

    static func invalidRects() -> [CGRect] {
        [.zero, CGRect(x: 0, y: 0, width: 0, height: 500),
         CGRect(x: 0, y: 0, width: 500, height: 0),
         CGRect(x: 0, y: 0, width: -500, height: 500),
         CGRect(x: 0, y: 0, width: 500, height: -500),
         CGRect(x: CGFloat.nan, y: 0, width: 500, height: 500),
         CGRect(x: 0, y: CGFloat.infinity, width: 500, height: 500),
         CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 500),
         CGRect(x: 0, y: 0, width: 500, height: CGFloat.nan)]
    }

    static func expectPoint(_ actual: CGPoint?, _ expected: CGPoint, _ message: String) {
        expect(actual.map { abs($0.x - expected.x) < 0.0001 && abs($0.y - expected.y) < 0.0001 } == true,
               "\(message): expected \(expected), got \(String(describing: actual))")
    }

    static func expectRect(_ actual: CGRect?, _ expected: CGRect, _ message: String) {
        expect(actual.map {
            abs($0.origin.x - expected.origin.x) < 0.0001 && abs($0.origin.y - expected.origin.y) < 0.0001 &&
            abs($0.width - expected.width) < 0.0001 && abs($0.height - expected.height) < 0.0001
        } == true, "\(message): expected \(expected), got \(String(describing: actual))")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
}
