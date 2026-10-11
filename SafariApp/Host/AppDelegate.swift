import AppKit
import SafariServices

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let extensionIdentifier = "local.tabscout.safari.Extension"
    private var window: NSWindow?
    private let status = NSTextField(labelWithString: "Checking Safari...")
    private let enableButton = NSButton(title: "Enable in Safari", target: nil, action: nil)

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        makeWindow()
        refreshStatus()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func makeMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Tab Scout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
    }

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tab Scout"
        window.isReleasedWhenClosed = false
        window.center()

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64)
        ])

        let title = NSTextField(labelWithString: "Tab Scout")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Safari Extension")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13)
        status.alignment = .center
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping

        enableButton.target = self
        enableButton.action = #selector(openSafariPreferences)
        enableButton.bezelStyle = .rounded
        enableButton.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        enableButton.imagePosition = .imageLeading
        enableButton.keyEquivalent = "\r"

        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh status")!, target: self, action: #selector(refreshStatus))
        refresh.bezelStyle = .rounded
        refresh.toolTip = "Refresh Safari extension status"
        let buttons = NSStackView(views: [enableButton, refresh])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [icon, title, subtitle, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                stack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48),
                status.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshStatus() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionIdentifier) { [weak self] state, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let state {
                    self.status.stringValue = state.isEnabled ? "Enabled in Safari" : "Not enabled in Safari"
                    self.enableButton.title = state.isEnabled ? "Safari Settings" : "Enable in Safari"
                } else {
                    self.status.stringValue = error?.localizedDescription ?? "Safari extension status unavailable"
                }
            }
        }
    }

    @objc private func openSafariPreferences() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionIdentifier) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.status.stringValue = error.localizedDescription
                } else {
                    self.refreshStatus()
                }
            }
        }
    }
}
