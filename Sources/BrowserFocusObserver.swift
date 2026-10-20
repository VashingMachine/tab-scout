import ApplicationServices
import Foundation

/// Calls `onChange` soon after a browser's tab on screen may have changed: a browser window title changes with
/// its current tab, and focus moves between windows. Uses the accessibility permission that the Cmd+T hook
/// already needs. Several notifications in quick succession produce one call.
final class BrowserFocusObserver {
    private static let notifications = [kAXTitleChangedNotification, kAXFocusedWindowChangedNotification,
                                        kAXMainWindowChangedNotification, kAXWindowCreatedNotification]
    private let delay: TimeInterval
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var pending = false
    private(set) var processID: pid_t = 0
    var onChange: (() -> Void)?

    init(delay: TimeInterval = 0.3) { self.delay = delay }

    var isObserving: Bool { observer != nil }

    /// Returns whether the browser's notifications are now observed.
    @discardableResult
    func start(processID: pid_t) -> Bool {
        if observer != nil && self.processID == processID { return true }
        stop()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            let owner = Unmanaged<BrowserFocusObserver>.fromOpaque(context).takeUnretainedValue()
            // A new window reports its own title changes only once observed.
            if notification as String == kAXWindowCreatedNotification { owner.watch(element) }
            owner.changed()
        }
        guard AXObserverCreate(processID, callback, &created) == .success, let created else { return false }
        let application = AXUIElementCreateApplication(processID)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let added = Self.notifications.map { AXObserverAddNotification(created, application, $0 as CFString, context) }
        // Without any accepted notification there is nothing to observe, typically for lack of permission.
        guard added.contains(.success) else { return false }
        observer = created
        self.application = application
        self.processID = processID
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows) == .success,
           let windows = windows as? [AXUIElement] {
            windows.forEach(watch)
        }
        return true
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        application = nil
        processID = 0
        pending = false
    }

    private func watch(_ window: AXUIElement) {
        guard let observer else { return }
        AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
    }

    private func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pending else { return }
            self.pending = false
            self.onChange?()
        }
    }
}
