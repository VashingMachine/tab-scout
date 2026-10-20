import AppKit
import ApplicationServices

enum PanelPlacement {
    struct Screen {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy { $0.isFinite }
            && rect.size.width > 0 && rect.size.height > 0
    }

    static func appKitFrame(fromAccessibilityFrame frame: CGRect, primaryScreenTop: CGFloat) -> CGRect? {
        guard valid(frame), primaryScreenTop.isFinite else { return nil }
        // AX uses a top-left origin on the primary display; AppKit uses bottom-left coordinates.
        let converted = CGRect(x: frame.minX, y: primaryScreenTop - frame.maxY,
                               width: frame.width, height: frame.height)
        return valid(converted) ? converted : nil
    }

    static func origin(panelSize: CGSize, browserFrame: CGRect?, screens: [Screen], fallbackScreen: Screen?) -> CGPoint? {
        guard panelSize.width.isFinite, panelSize.height.isFinite,
              panelSize.width > 0, panelSize.height > 0 else { return nil }
        let screens = screens.filter { valid($0.frame) && valid($0.visibleFrame) }
        let browserFrame = browserFrame.flatMap { valid($0) ? $0 : nil }
        var selected: Screen?
        var largestOverlap: CGFloat = 0
        if let browserFrame {
            for screen in screens {
                let overlap = screen.frame.intersection(browserFrame)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > largestOverlap { selected = screen; largestOverlap = area }
            }
        }
        if selected == nil {
            selected = fallbackScreen.flatMap { valid($0.frame) && valid($0.visibleFrame) ? $0 : nil } ?? screens.first
        }
        guard let screen = selected else { return nil }
        let visible = screen.visibleFrame
        let target = largestOverlap > 0 ? (browserFrame ?? visible) : visible
        func place(size: CGFloat, midpoint: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            if size > maximum - minimum { return (minimum + maximum - size) / 2 }
            return min(max(midpoint - size / 2, minimum), maximum - size)
        }
        return CGPoint(x: place(size: panelSize.width, midpoint: target.midX, minimum: visible.minX, maximum: visible.maxX),
                       y: place(size: panelSize.height, midpoint: target.midY, minimum: visible.minY, maximum: visible.maxY))
    }
}

enum BrowserWindowFrame {
    static func current(bundleID: String, primaryScreenTop: CGFloat) -> CGRect? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        func values(_ element: AXUIElement, _ names: [String]) -> [AnyObject]? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0,
                  AXUIElementSetMessagingTimeout(element, Float(min(0.04, remaining))) == .success else { return nil }
            var result: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success,
                  let result = result as? [AnyObject], result.count == names.count else { return nil }
            return result
        }
        guard let windows = values(application, [kAXFocusedWindowAttribute, kAXMainWindowAttribute]) else { return nil }
        // Read only top-level window geometry, never the browser's accessibility webpage tree.
        for value in windows where CFGetTypeID(value) == AXUIElementGetTypeID() {
            let window = value as! AXUIElement
            guard let frame = values(window, [kAXRoleAttribute, kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute]),
                  frame[0] as? String == kAXWindowRole, frame[1] as? Bool != true,
                  CFGetTypeID(frame[2]) == AXValueGetTypeID(), CFGetTypeID(frame[3]) == AXValueGetTypeID() else { continue }
            let positionValue = frame[2] as! AXValue
            let sizeValue = frame[3] as! AXValue
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
                  AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size),
                  let converted = PanelPlacement.appKitFrame(fromAccessibilityFrame: CGRect(origin: position, size: size),
                                                            primaryScreenTop: primaryScreenTop) else { continue }
            return converted
        }
        return nil
    }
}
