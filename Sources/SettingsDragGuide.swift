import AppKit
import SwiftUI

/// A small panel under System Settings with Tab Scout's icon to drag into a Privacy & Security list, as apps such as
/// Raycast offer. It never changes anything itself: the person drags the icon, and the panel closes once the step is
/// done, when System Settings closes, or when its close button is clicked.
final class SettingsDragGuide {
    struct Request {
        let title: String
        let detail: String
        /// Checked twice a second while the panel is open; true closes it.
        let isDone: () -> Bool
    }

    private static let settingsBundleID = "com.apple.systempreferences"
    private var panel: NSPanel?
    private var timer: Timer?
    private var request: Request?
    private var started = Date()
    private var dragging = false
    private var onFinish: (() -> Void)?

    var isShowing: Bool { panel != nil }

    /// Opens `pane` in System Settings and follows its window with the panel. `onFinish` runs once the step is done.
    func show(_ request: Request, pane: URL, onFinish: (() -> Void)? = nil) {
        close()
        self.request = request
        self.onFinish = onFinish
        started = Date()
        NSWorkspace.shared.open(pane)
        let view = DragGuideView(title: request.title, detail: request.detail, app: Bundle.main.bundleURL,
                                 onDrag: { [weak self] active in self?.dragging = active },
                                 onClose: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        self.panel = panel
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        request = nil
        onFinish = nil
        dragging = false
    }

    private var checks = 0

    private func tick() {
        guard let panel, let request else { return }
        checks += 1
        if checks % 5 == 0, request.isDone() {
            let finish = onFinish
            close()
            finish?()
            return
        }
        guard let frame = Self.settingsWindowFrame() else {
            // System Settings takes a moment to open; after that, a closed window ends the guide.
            if Date().timeIntervalSince(started) > 8 { close() } else { panel.orderOut(nil) }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front == Self.settingsBundleID || front == Bundle.main.bundleIdentifier || dragging else {
            panel.orderOut(nil)
            return
        }
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, below: frame))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Centered under the window, or over its bottom edge when the screen ends below it.
    static func origin(for size: NSSize, below window: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(window) }?.visibleFrame ?? window
        var origin = NSPoint(x: window.midX - size.width / 2, y: window.minY - size.height - 10)
        if origin.y < screen.minY { origin.y = window.minY + 16 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        return origin
    }

    /// The front System Settings window in Cocoa coordinates. Window bounds need no Screen Recording access.
    private static func settingsWindowFrame() -> NSRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 200, rect.height > 200 else { continue }
            // Window bounds have their origin at the top left of the main screen; Cocoa's is at its bottom left.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

private struct DragGuideView: View {
    let title: String
    let detail: String
    let app: URL
    let onDrag: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AppDragSource(app: app, onDrag: onDrag)
                .frame(width: 56, height: 56)
                .help("Drag into the list in System Settings")
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 290, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(tint: nil, cornerRadius: 22)
        .padding(1)
    }
}

/// Tab Scout's icon, which drags this copy of the app as a file, so the list gets exactly the app that is running.
private struct AppDragSource: NSViewRepresentable {
    let app: URL
    let onDrag: (Bool) -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.app = app
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.app = app
        view.onDrag = onDrag
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var app: URL = Bundle.main.bundleURL { didSet { needsDisplay = true } }
    var onDrag: (Bool) -> Void = { _ in }
    private var icon: NSImage { NSWorkspace.shared.icon(forFile: app.path) }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // The panel never activates, so the first click must start the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: app as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        onDrag(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDrag(false)
    }
}
