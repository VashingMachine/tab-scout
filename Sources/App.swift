import AppKit
import ApplicationServices
import ServiceManagement

private func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
}

private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let preview = CommandLine.arguments.contains("--preview")
    private var bridge: SafariBridge!
    private var tabStore: TabStore!
    private lazy var favicons = FaviconStore()
    private var searchIndex = TabSearchIndex([])
    private var windowNumbers: [Int: Int] = [:]
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var capturedT = false
    private var safariActive = false
    private var enabled = true
    private var workspaceObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var permissionTimer: Timer?
    private var cacheTimer: Timer?
    private var panel: SearchPanel!
    private var searchField: NSSearchField!
    private var table: NSTableView!
    private var footer: NSTextField!
    private var emptyLabel: NSTextField!
    private var retryButton: NSButton!
    private var tabs: [SafariTab] = []
    private var rows: [SearchRow] = []
    private var requestID = 0
    private var loading = false
    private var acting = false
    private var ready = false
    private var returnApp: NSRunningApplication?
    private var setupWindow: NSWindow?
    private var accessibilityState: NSTextField?
    private var safariState: NSTextField?
    private var setupStatus: NSTextField?
    private var safariAllowed = false
    private var controlPermissionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !preview, let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "local.tabscout.app").first(where: { $0.processIdentifier != getpid() }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        guard let script = Bundle.main.url(forResource: "SafariBridge", withExtension: "scpt") else {
            let alert = NSAlert()
            alert.messageText = "Tab Scout could not start"
            alert.informativeText = "SafariBridge.scpt is missing. Rebuild the app using build.sh."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        bridge = SafariBridge(scriptURL: script)
        tabStore = TabStore { [weak self] completion in self?.bridge.list(completion: completion) }
        tabStore.onPermissionDenied = { [weak self] in
            self?.safariAllowed = false
            self?.updatePermissionLabels()
        }
        buildMenu()
        buildPanel()
        safariActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Safari"
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.safariActive = app.bundleIdentifier == "com.apple.Safari"
            if self.safariActive && self.safariAllowed { self.tabStore.prewarm() }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Safari" else { return }
            self?.tabStore.invalidate()
            self?.clearResults()
            if self?.panel.isVisible == true { self?.loadTabs(force: true) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        if preview {
            showSearch(nil)
        } else {
            installTapIfAllowed()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.installTapIfAllowed()
                self?.updatePermissionLabels()
            }
            cacheTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.tabStore.snapshot == nil { self.clearResults() }
                if self.panel.isVisible && !self.acting && !self.loading { self.loadTabs() }
                else if self.safariActive && self.safariAllowed { self.tabStore.prewarm() }
            }
            if eventTap == nil { showPermissions(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if eventTap == nil && !preview { showPermissions(nil) } else { showSearch(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        permissionTimer?.invalidate()
        cacheTimer?.invalidate()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        appMenu.addItem(withTitle: "Quit Tab Scout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        for (name, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = main

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = symbol("rectangle.on.rectangle")
        statusItem.button?.toolTip = "Tab Scout"
        let menu = NSMenu()
        let search = menu.addItem(withTitle: "Search Safari Tabs", action: #selector(showSearch(_:)), keyEquivalent: "")
        search.target = self
        menu.addItem(.separator())
        pauseItem = menu.addItem(withTitle: "Capture Cmd+T in Safari", action: #selector(toggleCapture(_:)), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.state = .on
        let permissions = menu.addItem(withTitle: "Permissions...", action: #selector(showPermissions(_:)), keyEquivalent: "")
        permissions.target = self
        loginItem = menu.addItem(withTitle: "Start at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tab Scout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    private func installTapIfAllowed() {
        guard !preview, eventTap == nil, AXIsProcessTrusted() else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = owner.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyUp, code == 17, owner.capturedT {
                owner.capturedT = false
                return nil
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let flags = event.flags
            if ShortcutDecision.shouldCapture(keyCode: code, command: flags.contains(.maskCommand), shift: flags.contains(.maskShift), control: flags.contains(.maskControl), option: flags.contains(.maskAlternate), safariActive: owner.safariActive, enabled: owner.enabled) {
                owner.capturedT = true
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { owner.showSearch(nil) }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        eventTap = tap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func buildPanel() {
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 440), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Tab Scout"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        searchField = NSSearchField()
        searchField.placeholderString = "Search tabs or enter an address"
        searchField.font = .systemFont(ofSize: 21)
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(searchField)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(line)

        table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateSelection(_:))
        table.allowsEmptySelection = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)

        emptyLabel = NSTextField(wrappingLabelWithString: "")
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(emptyLabel)
        footer = NSTextField(labelWithString: "")
        footer.font = .systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(footer)
        retryButton = iconButton("arrow.clockwise", tip: "Refresh tabs", action: #selector(refresh(_:)))
        let settings = iconButton("gearshape", tip: "Permissions", action: #selector(showPermissions(_:)))
        background.addSubview(retryButton)
        background.addSubview(settings)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            searchField.heightAnchor.constraint(equalToConstant: 38),
            line.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 15),
            line.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -43),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -60),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            footer.centerYAnchor.constraint(equalTo: retryButton.centerYAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -12),
            settings.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            settings.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -9),
            retryButton.trailingAnchor.constraint(equalTo: settings.leadingAnchor, constant: -5),
            retryButton.bottomAnchor.constraint(equalTo: settings.bottomAnchor)
        ])
    }

    private func iconButton(_ name: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(image: symbol(name) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 28)])
        return button
    }

    @objc func showSearch(_ sender: Any?) {
        guard !acting else { return }
        if panel.isVisible { dismiss(restoreFocus: true); return }
        returnApp = NSWorkspace.shared.frontmostApplication
        setupWindow?.orderOut(nil)
        searchField.stringValue = ""
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2 + 80))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        loadTabs()
    }

    @objc private func refresh(_ sender: Any?) { if !acting { loadTabs(force: true) } }

    private func loadTabs(force: Bool = false) {
        requestID += 1
        let token = requestID
        loading = true
        if !ready {
            clearResults()
            footer.stringValue = "Loading tabs..."
        }
        emptyLabel.stringValue = ""
        retryButton.isEnabled = false
        if preview {
            let samples = [
                SafariTab(windowID: 1, index: 1, title: "GitHub - Projects", url: "https://github.com/"),
                SafariTab(windowID: 1, index: 2, title: "Apple Developer Documentation", url: "https://developer.apple.com/documentation/"),
                SafariTab(windowID: 2, index: 1, title: "Wikipedia", url: "https://en.wikipedia.org/")
            ]
            didLoad(.success(TabSnapshot(tabs: samples, index: TabSearchIndex(samples), fetchedAt: Date(), revision: 0)), token: token)
        } else {
            tabStore.load(force: force) { [weak self] result in self?.didLoad(result, token: token) }
        }
    }

    private func didLoad(_ result: Result<TabSnapshot, Error>, token: Int) {
        guard token == requestID, panel.isVisible else { return }
        loading = false
        retryButton.isEnabled = true
        switch result {
        case .success(let snapshot):
            let hadResults = ready
            self.tabs = snapshot.tabs
            searchIndex = snapshot.index
            windowNumbers = [:]
            for tab in tabs where windowNumbers[tab.windowID] == nil { windowNumbers[tab.windowID] = windowNumbers.count + 1 }
            ready = true
            if !tabs.isEmpty || NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").count > 0 { safariAllowed = true }
            updateRows(preserveSelection: hadResults)
            updatePermissionLabels()
        case .failure(let error):
            if !preview && tabStore.snapshot == nil {
                clearResults()
            }
            if case BridgeError.permission = error {
                safariAllowed = false
                clearResults()
            }
            footer.stringValue = ready ? "Cached tabs | Refresh unavailable" : "Safari access unavailable"
            footer.toolTip = error.localizedDescription
            emptyLabel.stringValue = ready ? "" : error.localizedDescription
            updatePermissionLabels()
        }
    }

    func controlTextDidChange(_ obj: Notification) { if ready { updateRows() } }

    private func updateRows(preserveSelection: Bool = false) {
        let selected = preserveSelection && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = searchIndex.results(query: query)
        let new = SearchRow.newTab(NewTabDestination.from(query))
        rows = query.isEmpty ? [new] + matches.prefix(30).map(SearchRow.tab) : matches.map(SearchRow.tab) + [new]
        table.reloadData()
        let row = selected.flatMap { SearchRow.retainedSelection(of: $0, in: rows) } ?? 0
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        emptyLabel.stringValue = ""
        let windows = Set(tabs.map(\.windowID)).count
        let tabCount = "\(tabs.count) \(tabs.count == 1 ? "tab" : "tabs")"
        let windowCount = "\(windows) \(windows == 1 ? "window" : "windows")"
        footer.stringValue = query.isEmpty ? "\(tabCount) in \(windowCount)" : "\(matches.count) matching \(matches.count == 1 ? "tab" : "tabs")"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("resultCell"), owner: self) as? ResultCell ?? ResultCell()
        switch rows[row] {
        case .tab(let tab):
            let image = preview ? nil : favicons.imageFor(url: tab.url)
            cell.configure(title: tab.displayTitle,
                           detail: (tab.url.isEmpty ? "Start Page" : tab.url) + " | Window \(windowNumbers[tab.windowID] ?? 1)",
                           url: tab.url, image: image ?? symbol("globe"), tint: image == nil ? .systemTeal : nil)
            if !preview && image == nil {
                favicons.request(url: tab.url) { [weak cell] image in
                    cell?.applyFavicon(image, for: tab.url)
                }
            }
        case .newTab(let destination):
            switch destination {
            case .url(let url):
                cell.configure(title: url == "about:blank" ? "New tab" : "Open \(url)", detail: "New Safari tab", url: nil,
                               image: symbol("plus.square"), tint: .systemBlue)
            case .search(let query):
                cell.configure(title: "Search for \(query)", detail: "Safari's default search engine", url: nil,
                               image: symbol("magnifyingglass"), tint: .systemBlue)
            }
        }
        return cell
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel?.isKeyWindow == true else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { if !acting { dismiss(restoreFocus: true) }; return nil }
        if event.keyCode == 17 && flags == .command { if !acting { dismiss(restoreFocus: true) }; return nil }
        if event.keyCode == 36 || event.keyCode == 76 {
            activate(forceNew: flags.contains(.command))
            return nil
        }
        if (event.keyCode == 125 || event.keyCode == 126) && flags.isEmpty {
            guard !rows.isEmpty else { return nil }
            let step = event.keyCode == 125 ? 1 : -1
            let selected = min(max(table.selectedRow + step, 0), rows.count - 1)
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.scrollRowToVisible(selected)
            return nil
        }
        return event
    }

    @objc private func activateSelection(_ sender: Any?) { activate(forceNew: false) }

    private func activate(forceNew: Bool) {
        guard ready, !acting else { return }
        let row: SearchRow
        if forceNew { row = .newTab(NewTabDestination.from(searchField.stringValue)) }
        else {
            guard rows.indices.contains(table.selectedRow) else { return }
            row = rows[table.selectedRow]
        }
        if preview { footer.stringValue = "Preview only"; return }
        acting = true
        searchField.isEnabled = false
        retryButton.isEnabled = false
        footer.stringValue = "Opening..."
        let completion: (Result<Data, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.acting = false
            self.searchField.isEnabled = true
            self.retryButton.isEnabled = true
            switch result {
            case .success:
                self.tabStore.invalidate()
                self.dismiss(restoreFocus: false)
                self.tabStore.prewarm()
            case .failure(let error):
                self.emptyLabel.stringValue = ""
                self.footer.stringValue = error.localizedDescription
                self.footer.toolTip = error.localizedDescription
                self.panel.makeFirstResponder(self.searchField)
                if case BridgeError.staleTab = error { self.loadTabs(force: true) }
            }
        }
        switch row {
        case .tab(let tab): bridge.select(tab, completion: completion)
        case .newTab(let destination): bridge.open(destination, windowID: tabs.first?.windowID ?? 0, completion: completion)
        }
    }

    private func dismiss(restoreFocus: Bool) {
        requestID += 1
        panel.orderOut(nil)
        clearResults()
        searchField.stringValue = ""
        loading = false
        if restoreFocus, let app = returnApp, app.processIdentifier != getpid() { app.activate(options: []) }
        returnApp = nil
    }

    private func clearResults() {
        tabs = []
        rows = []
        searchIndex = TabSearchIndex([])
        windowNumbers = [:]
        ready = false
        table?.reloadData()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, panel.isVisible, !loading, !acting else { return }
        dismiss(restoreFocus: false)
    }

    @objc private func toggleCapture(_ sender: Any?) {
        enabled.toggle()
        pauseItem.state = enabled ? .on : .off
    }

    @objc private func toggleLogin(_ sender: Any?) {
        guard !preview else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change login settings"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func showPermissions(_ sender: Any?) {
        guard !preview else { footer.stringValue = "Preview only"; return }
        if panel?.isVisible == true { dismiss(restoreFocus: false) }
        if setupWindow == nil { buildPermissions() }
        updatePermissionLabels()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.center()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildPermissions() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 292), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tab Scout"
        window.isReleasedWhenClosed = false
        setupWindow = window
        guard let content = window.contentView else { return }
        let heading = NSTextField(labelWithString: "Permissions")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.frame = NSRect(x: 28, y: 237, width: 420, height: 28)
        content.addSubview(heading)
        let axTitle = NSTextField(labelWithString: controlPermissionName)
        axTitle.font = .systemFont(ofSize: 15, weight: .medium)
        axTitle.frame = NSRect(x: 28, y: 191, width: 260, height: 22)
        content.addSubview(axTitle)
        accessibilityState = NSTextField(labelWithString: "")
        accessibilityState?.font = .systemFont(ofSize: 12)
        accessibilityState?.textColor = .secondaryLabelColor
        accessibilityState?.frame = NSRect(x: 28, y: 166, width: 280, height: 20)
        content.addSubview(accessibilityState!)
        let ax = NSButton(title: "Open Settings", target: self, action: #selector(openAccessibility(_:)))
        ax.bezelStyle = .rounded
        ax.frame = NSRect(x: 322, y: 175, width: 132, height: 32)
        content.addSubview(ax)
        let safariTitle = NSTextField(labelWithString: "Safari")
        safariTitle.font = .systemFont(ofSize: 15, weight: .medium)
        safariTitle.frame = NSRect(x: 28, y: 124, width: 260, height: 22)
        content.addSubview(safariTitle)
        safariState = NSTextField(labelWithString: "")
        safariState?.font = .systemFont(ofSize: 12)
        safariState?.textColor = .secondaryLabelColor
        safariState?.frame = NSRect(x: 28, y: 99, width: 280, height: 20)
        content.addSubview(safariState!)
        let safari = NSButton(title: "Allow Access", target: self, action: #selector(requestSafari(_:)))
        safari.bezelStyle = .rounded
        safari.frame = NSRect(x: 322, y: 108, width: 132, height: 32)
        content.addSubview(safari)
        let line = NSBox(frame: NSRect(x: 28, y: 79, width: 424, height: 1))
        line.boxType = .separator
        content.addSubview(line)
        setupStatus = NSTextField(labelWithString: "")
        setupStatus?.font = .systemFont(ofSize: 12)
        setupStatus?.textColor = .secondaryLabelColor
        setupStatus?.frame = NSRect(x: 28, y: 31, width: 270, height: 20)
        content.addSubview(setupStatus!)
        let search = NSButton(title: "Open Search", target: self, action: #selector(showSearch(_:)))
        search.image = symbol("magnifyingglass")
        search.imagePosition = .imageLeading
        search.bezelStyle = .rounded
        search.frame = NSRect(x: 322, y: 24, width: 132, height: 32)
        content.addSubview(search)
    }

    private func updatePermissionLabels() {
        // Checking trust registers the executable with macOS. Preview builds must not do that.
        guard !preview else { return }
        let trusted = AXIsProcessTrusted()
        accessibilityState?.stringValue = trusted ? (eventTap == nil ? "Access granted; shortcut unavailable" : "Allowed") : "Required for Cmd+T"
        safariState?.stringValue = safariAllowed ? "Allowed" : "Required for tab access"
        setupStatus?.stringValue = trusted && safariAllowed && eventTap != nil ? "Ready" : "Permissions needed"
    }

    @objc private func openAccessibility(_ sender: Any?) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    @objc private func requestSafari(_ sender: NSButton) {
        sender.isEnabled = false
        safariState?.stringValue = "Requesting access..."
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Safari.app"), configuration: NSWorkspace.OpenConfiguration()) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil else { sender.isEnabled = true; self.safariState?.stringValue = "Could not open Safari"; return }
                self.bridge.list { [weak self] result in
                    guard let self else { return }
                    sender.isEnabled = true
                    switch result {
                    case .success:
                        self.safariAllowed = true
                        self.tabStore.prewarm()
                        self.updatePermissionLabels()
                    case .failure(let error): self.safariState?.stringValue = "Access unavailable"; self.setupStatus?.stringValue = "Check Automation settings"; self.setupStatus?.toolTip = error.localizedDescription
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    self.setupWindow?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

@main
struct TabScoutMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
