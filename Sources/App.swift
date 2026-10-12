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
    private lazy var historyStore = HistoryStore()
    private lazy var learning = LearningStore(directory: preview ? nil : LearningStore.defaultDirectory)
    private lazy var wordNeighbors = WordNeighbors()
    private var similarWords: [SafariTab: String] = [:]
    private var pageText = PageTextIndex()
    private var pageTextQueue: [SafariTab] = []
    private var pageTextReading = false
    private var pageTextItems: [NSMenuItem] = []
    private var mentions: [SafariTab: String] = [:]
    private var pageTextEnabled: Bool { UserDefaults.standard.bool(forKey: "PageTextEnabled") }
    private lazy var googleSuggestions = GoogleSuggestionsService()
    private let historyQueue = DispatchQueue(label: "local.tabscout.history-index", qos: .userInitiated)
    private var historyIndex = HistorySearchIndex(.empty)
    private var indexedHistory: HistorySnapshot?
    private var openTabs = OpenTabLookup([])
    private var remoteSuggestions: [String] = []
    private var historyRequestID = 0
    private var historyError: Error?
    private var historyLoaded = false
    private var googleItems: [NSMenuItem] = []
    private var historyItems: [NSMenuItem] = []
    private var historyState: NSTextField?
    private lazy var relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    private var googleEnabled: Bool { UserDefaults.standard.bool(forKey: "GoogleSuggestionsEnabled") }
    private var safariHistoryEnabled: Bool { UserDefaults.standard.bool(forKey: "SafariHistoryEnabled") }
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
    private var focusHistory = TabFocusHistory()
    private var focusTracker = FocusTracker()
    private let focusObserver = SafariFocusObserver()
    private var activeReadInFlight = false
    private var activeReadAgain = false
    private var launchObserver: NSObjectProtocol?
    private var tabDwell: [SafariTab: Double] = [:]
    private var relatedTabs: [SafariTab: (strength: Double, shared: TabEntity)] = [:]
    private var tabTransition: [SafariTab: Double] = [:]
    private var tabTimeOfDay: [SafariTab: Double] = [:]
    private var activeTab: SafariTab?
    private var previousTab: SafariTab?
    private var focusOrder: [SafariTab] = []
    private var rows: [SearchRow] = []
    private var requestID = 0
    private var loading = false
    private var acting = false
    private var ready = false
    private var pendingActivation: Bool?
    private var returnApp: NSRunningApplication?
    private var setupWindow: NSWindow?
    private var accessibilityState: NSTextField?
    private var safariState: NSTextField?
    private var setupStatus: NSTextField?
    private var safariAllowed = false
    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "Version \(info["CFBundleShortVersionString"] as? String ?? "unknown")"
        return (info["TabScoutBuild"] as? String).map { "\(version) (\($0))" } ?? version
    }
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
        // Every read, including background prewarms, notes which tab is on screen.
        tabStore.onSnapshot = { [weak self] snapshot in
            if let active = snapshot.active { self?.observeFocus(active) }
        }
        focusObserver.onChange = { [weak self] in self?.readActiveTab() }
        buildMenu()
        buildPanel()
        reloadHistory()
        safariActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Safari"
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let wasActive = self.safariActive
            self.safariActive = app.bundleIdentifier == "com.apple.Safari"
            if !self.preview && self.safariActive && self.safariAllowed { self.tabStore.prewarm(); self.readActiveTab() }
            if wasActive && !self.safariActive { self.pauseFocus() }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Safari" else { return }
            self?.startFocusObserver()
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Safari", self?.preview == false else { return }
            self?.tabStore.invalidate()
            self?.pauseFocus()
            self?.focusObserver.stop()
            self?.focusHistory = TabFocusHistory()
            self?.clearResults()
            if self?.panel.isVisible == true { self?.loadTabs(force: true) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        if preview, let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            renderSnapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else if preview {
            showSearch(nil)
        } else {
            installTapIfAllowed()
            startFocusObserver()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.installTapIfAllowed()
                self?.startFocusObserver()
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
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        focusObserver.stop()
        pauseFocus()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        permissionTimer?.invalidate()
        cacheTimer?.invalidate()
        if !preview { googleSuggestions.cancel() }
        learning.flush()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        addSearchPreferences(to: appMenu)
        appMenu.addItem(.separator())
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
        menu.addItem(.separator())
        addSearchPreferences(to: menu)
        menu.addItem(.separator())
        loginItem = menu.addItem(withTitle: "Start at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: versionText, action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit Tab Scout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    private func addSearchPreferences(to menu: NSMenu) {
        let google = menu.addItem(withTitle: "Google Suggestions", action: #selector(toggleGoogle(_:)), keyEquivalent: "")
        google.target = self
        google.state = googleEnabled ? .on : .off
        googleItems.append(google)
        let history = menu.addItem(withTitle: "Use Safari History", action: #selector(toggleSafariHistory(_:)), keyEquivalent: "")
        history.target = self
        history.state = safariHistoryEnabled ? .on : .off
        historyItems.append(history)
        let text = menu.addItem(withTitle: "Search Page Text", action: #selector(togglePageText(_:)), keyEquivalent: "")
        text.target = self
        text.state = pageTextEnabled ? .on : .off
        pageTextItems.append(text)
        let clear = menu.addItem(withTitle: "Clear Tab Scout History...", action: #selector(clearHistory(_:)), keyEquivalent: "")
        clear.target = self
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

    /// Follows tab switches as they happen, so recency and reading time stay exact between Cmd+T presses.
    private func startFocusObserver() {
        guard !preview, !focusObserver.isObserving, AXIsProcessTrusted(),
              let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else { return }
        if focusObserver.start(processID: safari.processIdentifier) && safariActive { readActiveTab() }
    }

    /// Reads the tab on screen, at most one read at a time with a pause after each, however busy the page title.
    private func readActiveTab() {
        guard !preview, safariActive, safariAllowed else { return }
        if activeReadInFlight { activeReadAgain = true; return }
        activeReadInFlight = true
        bridge.active { [weak self] result in
            guard let self else { return }
            if case .success(let tab) = result, self.safariActive, let tab { self.observeFocus(tab) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.activeReadInFlight = false
                if self.activeReadAgain { self.activeReadAgain = false; self.readActiveTab() }
            }
        }
    }

    /// Reading time counts only while Safari is in front.
    private func observeFocus(_ tab: SafariTab) {
        focusHistory.focus(tab)
        if safariActive, let visit = focusTracker.observe(tab, at: Date()) { recordVisit(visit) }
        // A page looked at for a few seconds has loaded; reading only viewed pages never wakes sleeping tabs.
        guard pageTextEnabled, !preview else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let current = self.focusTracker.current,
                  current.windowID == tab.windowID, current.url == tab.url else { return }
            self.readPageText(current)
        }
    }

    private func readPageText(_ tab: SafariTab) {
        guard pageText.needsReading(tab, now: Date()), !pageTextQueue.contains(where: { PageTextIndex.Key($0) == PageTextIndex.Key(tab) }) else { return }
        pageTextQueue.append(tab)
        readNextPageText()
    }

    private func readNextPageText() {
        guard pageTextEnabled, !pageTextReading, !pageTextQueue.isEmpty else { return }
        let tab = pageTextQueue.removeFirst()
        pageTextReading = true
        bridge.text(of: tab) { [weak self] result in
            guard let self else { return }
            if self.pageTextEnabled, case .success(let text) = result { self.pageText.store(text, for: tab, at: Date()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.pageTextReading = false
                self.readNextPageText()
            }
        }
    }

    private func pauseFocus() {
        if let visit = focusTracker.pause(at: Date()) { recordVisit(visit) }
    }

    private func recordVisit(_ visit: FocusVisit) {
        learning.update {
            $0.engagement.record(visit, now: Date())
            $0.habits.record(visit, calendar: .current)
        }
    }

    private func buildPanel() {
        // A non-activating panel takes keyboard focus while Safari stays the active app. macOS refuses
        // activation requests from a menu-bar app launched in the background until the user has clicked it,
        // which left Cmd+T doing nothing after every launch.
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
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
        searchField.font = .systemFont(ofSize: 18)
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
        table.rowHeight = 44
        table.intercellSpacing = NSSize(width: 0, height: 1)
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
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(footer)
        retryButton = iconButton("arrow.clockwise", tip: "Refresh tabs", action: #selector(refresh(_:)))
        let settings = iconButton("gearshape", tip: "Permissions", action: #selector(showPermissions(_:)))
        background.addSubview(retryButton)
        background.addSubview(settings)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 32),
            line.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            line.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -32),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -60),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            footer.centerYAnchor.constraint(equalTo: retryButton.centerYAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -12),
            settings.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            settings.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -5),
            retryButton.trailingAnchor.constraint(equalTo: settings.leadingAnchor, constant: -2),
            retryButton.bottomAnchor.constraint(equalTo: settings.bottomAnchor)
        ])
    }

    private func iconButton(_ name: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(image: symbol(name) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 24)])
        return button
    }

    @objc func showSearch(_ sender: Any?) {
        // The palette hides as soon as Enter is pressed; reopening during that action shows its progress.
        if acting { panel.makeKeyAndOrderFront(nil); return }
        if panel.isVisible { dismiss(restoreFocus: true); return }
        let opened = DispatchTime.now()
        returnApp = NSWorkspace.shared.frontmostApplication
        setupWindow?.orderOut(nil)
        searchField.stringValue = ""
        remoteSuggestions = []
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let fallback = screens.first(where: { $0.frame.contains(mouse) }) ?? screens.first
        let safariFrame = screens.first.flatMap { preview ? nil : SafariWindowFrame.current(primaryScreenTop: $0.frame.maxY) }
        if let origin = PanelPlacement.origin(panelSize: panel.frame.size, safariFrame: safariFrame,
                                              screens: screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) },
                                              fallbackScreen: fallback.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) }) {
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        // Cached tabs appear at once; the forced read catches tab switches made in Safari since the last one.
        loadTabs(force: true)
        reloadHistory()
        DispatchQueue.main.async { Timing.log("open", since: opened) }
    }

    @objc private func refresh(_ sender: Any?) { if !acting { loadTabs(force: true) } }

    /// Draws the preview palette into a PNG from an invisible window, so the layout can be checked
    /// without taking keyboard focus from the person at the Mac.
    private func renderSnapshot(to url: URL) {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        loadTabs()
        guard let view = panel.contentView else { return NSApp.terminate(nil) }
        view.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        NSApp.terminate(nil)
    }

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
            focusHistory.focus(samples[1])
            focusHistory.focus(samples[0])
            didLoad(.success(TabSnapshot(tabs: samples, active: samples[0], index: TabSearchIndex(samples), fetchedAt: Date(), revision: 0)), token: token)
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
            openTabs = OpenTabLookup(snapshot.tabs)
            activeTab = snapshot.active
            previousTab = focusHistory.previous(active: snapshot.active, in: snapshot.tabs)
            focusOrder = focusHistory.order(in: snapshot.tabs)
            let now = Date()
            tabDwell = Dictionary(snapshot.tabs.compactMap { tab -> (SafariTab, Double)? in
                guard let url = HistoryIdentity.url(tab.url) else { return nil }
                let strength = learning.state.engagement.strength(url: url, now: now)
                return strength > 0 ? (tab, strength) : nil
            }, uniquingKeysWith: max)
            relatedTabs = RelatedTabs.relations(to: snapshot.active, in: snapshot.tabs)
            pageText.retain(snapshot.tabs)
            let habits = learning.state.habits
            let from = snapshot.active.flatMap { Habits.site($0.url) }
            tabTransition = [:]
            tabTimeOfDay = [:]
            for tab in snapshot.tabs {
                guard let site = Habits.site(tab.url) else { continue }
                if let from { tabTransition[tab] = habits.transition(from: from, to: site, now: now) }
                tabTimeOfDay[tab] = habits.timeOfDay(site: site, at: now, calendar: .current, now: now)
            }
            windowNumbers = [:]
            for tab in tabs where windowNumbers[tab.windowID] == nil { windowNumbers[tab.windowID] = windowNumbers.count + 1 }
            ready = true
            if !tabs.isEmpty || NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").count > 0 { safariAllowed = true }
            updateRows(preserveSelection: hadResults)
            updatePermissionLabels()
            if let forceNew = pendingActivation {
                pendingActivation = nil
                activate(forceNew: forceNew)
            }
        case .failure(let error):
            pendingActivation = nil
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

    func controlTextDidChange(_ obj: Notification) {
        pendingActivation = nil
        remoteSuggestions = []
        if ready { updateRows() }
        requestSuggestions()
    }

    private func requestSuggestions() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview {
            remoteSuggestions = ["swift programming", "swift documentation", "swift concurrency"].filter {
                !query.isEmpty && $0.hasPrefix(query.lowercased())
            }
            if ready { updateRows(preserveSelection: true) }
            return
        }
        guard googleEnabled, panel.isVisible else { googleSuggestions.cancel(); return }
        googleSuggestions.suggestions(for: query) { [weak self] response in
            guard let self, self.googleEnabled, self.panel.isVisible,
                  self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == response.query else { return }
            self.remoteSuggestions = response.suggestions
            if self.ready { self.updateRows(preserveSelection: true) }
        }
    }

    private func reloadHistory() {
        historyRequestID += 1
        let token = historyRequestID
        if preview {
            let now = Date()
            historyIndex = HistorySearchIndex(HistorySnapshot(visits: [
                HistoryVisit(url: "https://www.swift.org/documentation/", title: "Swift Documentation", lastVisited: now.addingTimeInterval(-3_600), visitCount: 12)
            ], searches: [PastSearch(query: "swift concurrency", lastUsed: now.addingTimeInterval(-120), useCount: 3)]))
            return
        }
        historyStore.load(includeSafari: safariHistoryEnabled) { [weak self] result in
            guard let self, token == self.historyRequestID else { return }
            self.historyLoaded = true
            if case .failure(let error) = result { self.historyError = error } else { self.historyError = nil }
            let snapshot = (try? result.get()) ?? self.historyStore.snapshot
            // Indexing a large Safari history takes about 0.1 s, so an unchanged history keeps its index.
            guard snapshot != self.indexedHistory else { self.updatePermissionLabels(); return }
            let started = DispatchTime.now()
            self.historyQueue.async {
                let index = HistorySearchIndex(snapshot)
                DispatchQueue.main.async {
                    guard token == self.historyRequestID else { return }
                    Timing.log("history index", since: started)
                    self.historyIndex = index
                    self.indexedHistory = snapshot
                    self.updatePermissionLabels()
                    if self.ready && self.panel.isVisible { self.updateRows(preserveSelection: true) }
                }
            }
        }
    }

    private func updateRows(preserveSelection: Bool = false) {
        // A selection still on the top row follows the top row, so Enter keeps meaning the default result.
        let navigated = rows.indices.contains(table.selectedRow) && table.selectedRow != ResultNavigation.first(in: rows)
        let selected = preserveSelection && navigated ? rows[table.selectedRow] : nil
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = searchIndex.matches(query: query)
        let now = Date()
        let similar = SemanticSearch.matches(query, in: searchIndex, textMatches: matches.count) { self.wordNeighbors($0) }
        similarWords = Dictionary(similar.map { ($0.tab, $0.word) }, uniquingKeysWith: { first, _ in first })
        let mentioned = pageTextEnabled ? pageText.matches(query, in: tabs) : [:]
        mentions = mentioned.mapValues(\.snippet)
        let context = RankingContext(focusOrder: focusOrder, affinity: learning.state.affinity.strengths(for: query, now: now),
                                     dwell: tabDwell, related: relatedTabs.mapValues(\.strength),
                                     transition: tabTransition, timeOfDay: tabTimeOfDay,
                                     semantic: Dictionary(similar.map { ($0.tab, $0.strength) }, uniquingKeysWith: max),
                                     content: mentioned.mapValues(\.strength))
        rows = SearchResultBuilder.rows(query: query, matches: matches, allTabs: tabs, history: historyIndex,
                                        suggestions: remoteSuggestions, now: now, openTabs: openTabs,
                                        previousTab: previousTab, activeTab: activeTab, context: context)
        table.reloadData()
        if let row = selected.flatMap({ SearchRow.retainedSelection(of: $0, in: rows) }) ?? ResultNavigation.first(in: rows) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        emptyLabel.stringValue = ""
        let windows = Set(tabs.map(\.windowID)).count
        let tabCount = "\(tabs.count) \(tabs.count == 1 ? "tab" : "tabs")"
        let windowCount = "\(windows) \(windows == 1 ? "window" : "windows")"
        let localCount = rows.filter { row in
            switch row { case .previousTab, .tab, .history, .recentSearch: return true; default: return false }
        }.count
        let suggestionCount = rows.filter { if case .suggestion = $0 { return true }; return false }.count
        footer.stringValue = query.isEmpty ? "\(tabCount) in \(windowCount)" : "\(localCount) local \(localCount == 1 ? "result" : "results")" + (suggestionCount > 0 ? " | \(suggestionCount) Google suggestions" : "")
        footer.toolTip = preview ? nil : historyStore.localStorageError?.localizedDescription
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows.indices.contains(row) && !rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) && !rows[row].isSelectable ? 22 : 44
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if case .section(let section) = rows[row] {
            let label = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("section"), owner: self) as? NSTextField
                ?? NSTextField(labelWithString: "")
            label.identifier = NSUserInterfaceItemIdentifier("section")
            label.stringValue = section.rawValue
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("resultCell"), owner: self) as? ResultCell ?? ResultCell()
        switch rows[row] {
        case .previousTab(let tab), .tab(let tab):
            let image = preview ? nil : favicons.imageFor(url: tab.url)
            var location = (tab.url.isEmpty ? "Start Page" : tab.url) + " | Window \(windowNumbers[tab.windowID] ?? 1)"
            if let snippet = mentions[tab] {
                location = "Mentions: \(snippet) | " + location
            } else if let related = relatedTabs[tab], related.strength >= RelatedTabs.named {
                location = "Related: \(related.shared.label) | " + location
            } else if let word = similarWords[tab] {
                location = "Similar: \(word) | " + location
            }
            cell.configure(title: tab.displayTitle,
                           detail: rows[row] == .previousTab(tab) ? "Previous tab | " + location : location,
                           url: tab.url, image: image ?? symbol("globe"), tint: image == nil ? .systemTeal : nil)
            if !preview && image == nil {
                favicons.request(url: tab.url) { [weak cell] image in
                    cell?.applyFavicon(image, for: tab.url)
                }
            }
        case .newTab(let destination):
            switch destination {
            case .defaultPage:
                cell.configure(title: "New tab", detail: "Safari's new-tab page", url: nil,
                               image: symbol("plus.square"), tint: .systemBlue)
            case .url(let url):
                cell.configure(title: url == "about:blank" ? "New tab" : "Open \(url)", detail: "New Safari tab", url: nil,
                               image: symbol("plus.square"), tint: .systemBlue)
            case .search(let query):
                cell.configure(title: "Search for \(query)", detail: "Safari's default search engine", url: nil,
                               image: symbol("magnifyingglass"), tint: .systemBlue)
            }
        case .recentSearch(let search):
            cell.configure(title: search.query, detail: relativeDate.localizedString(for: search.lastUsed, relativeTo: Date()),
                           url: nil, image: symbol("clock"), tint: .secondaryLabelColor)
        case .suggestion(let query):
            cell.configure(title: query, detail: "Google", url: nil, image: symbol("magnifyingglass"), tint: .secondaryLabelColor)
        case .history(let visit):
            let image = preview ? nil : favicons.imageFor(url: visit.url)
            cell.configure(title: visit.title.isEmpty ? visit.url : visit.title,
                           detail: visit.url + " | " + relativeDate.localizedString(for: visit.lastVisited, relativeTo: Date()),
                           url: visit.url, image: image ?? symbol("clock"), tint: image == nil ? .secondaryLabelColor : nil)
            if !preview && image == nil {
                favicons.request(url: visit.url) { [weak cell] image in cell?.applyFavicon(image, for: visit.url) }
            }
        case .section: return nil
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
        if let step = ResultKeyboard.navigationStep(for: event) {
            guard !rows.isEmpty else { return nil }
            guard let selected = ResultNavigation.next(in: rows, from: table.selectedRow, step: step) else { return nil }
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.scrollRowToVisible(selected)
            return nil
        }
        return event
    }

    @objc private func activateSelection(_ sender: Any?) {
        // Ignore keyboard actions and heading clicks that leave an earlier row selected.
        let keyboard = NSApp.currentEvent?.type == .keyDown || NSApp.currentEvent?.type == .keyUp
        guard ResultActivation.allowsClick(in: rows, clickedRow: table.clickedRow, selectedRow: table.selectedRow, keyboardEvent: keyboard) else { return }
        activate(forceNew: false)
    }

    private func activate(forceNew: Bool) {
        guard !acting else { return }
        // Enter pressed while the tab list is still loading runs once it arrives.
        guard ready else { if loading { pendingActivation = forceNew }; return }
        let typed = searchField.stringValue
        let offeredTabs = rows.contains { if case .tab = $0 { return true }; return false }
        let row: SearchRow
        if forceNew { row = .newTab(NewTabDestination.from(searchField.stringValue)) }
        else {
            guard rows.indices.contains(table.selectedRow) else { return }
            row = rows[table.selectedRow]
        }
        guard row.isSelectable else { return }
        if preview { footer.stringValue = "Preview only"; return }
        acting = true
        searchField.isEnabled = false
        retryButton.isEnabled = false
        footer.stringValue = "Opening..."
        // Hide at once and let Safari finish in the background; a failure brings the palette back.
        panel.orderOut(nil)
        let started = DispatchTime.now()
        let completion: (Result<Data, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            Timing.log("activate", since: started)
            self.acting = false
            self.searchField.isEnabled = true
            self.retryButton.isEnabled = true
            switch result {
            case .success:
                self.rememberChoice(row, typed: typed, offeredTabs: offeredTabs)
                // Keep the tab list warm so an immediate Cmd+T needs no Safari read.
                switch row {
                case .previousTab(let tab), .tab(let tab):
                    self.observeFocus(tab)
                    self.tabStore.noteActivation(tab)
                default: self.tabStore.noteActivation(nil)
                }
                self.dismiss(restoreFocus: false)
                self.tabStore.prewarm()
            case .failure(let error):
                self.emptyLabel.stringValue = ""
                self.footer.stringValue = error.localizedDescription
                self.footer.toolTip = error.localizedDescription
                self.panel.makeKeyAndOrderFront(nil)
                self.panel.makeFirstResponder(self.searchField)
                if case BridgeError.staleTab = error { self.loadTabs(force: true) }
            }
        }
        switch row {
        case .previousTab(let tab), .tab(let tab): bridge.select(tab, completion: completion)
        default:
            if let destination = row.destination { bridge.open(destination, windowID: tabs.first?.windowID ?? 0, completion: completion) }
        }
    }

    private func rememberChoice(_ row: SearchRow, typed: String, offeredTabs: Bool) {
        let target: String? = switch row {
        case .previousTab(let tab), .tab(let tab): HistoryIdentity.url(tab.url)
        case .history(let visit): HistoryIdentity.url(visit.url)
        // Searching the typed text while tabs were offered teaches Enter to do that next time.
        case .newTab(.search), .newTab(.url): offeredTabs ? QueryAffinity.newTab : nil
        default: nil
        }
        if let target { learning.update { $0.affinity.record(input: typed, target: target, at: Date()) } }
        switch row {
        case .previousTab(let tab), .tab(let tab): historyStore.recordVisit(url: tab.url, title: tab.displayTitle)
        case .history(let visit): historyStore.recordVisit(url: visit.url, title: visit.title)
        default:
            if let destination = row.destination {
                switch destination {
                case .defaultPage: break
                case .search(let query): historyStore.recordSearch(query: query)
                case .url(let url): historyStore.recordVisit(url: url, title: url)
                }
            }
        }
        reloadHistory()
    }

    private func dismiss(restoreFocus: Bool) {
        requestID += 1
        pendingActivation = nil
        if !preview { googleSuggestions.cancel() }
        remoteSuggestions = []
        panel.orderOut(nil)
        clearResults()
        searchField.stringValue = ""
        loading = false
        if restoreFocus, let app = returnApp, app.processIdentifier != getpid() { app.activate(options: []) }
        returnApp = nil
    }

    private func clearResults() {
        tabs = []
        activeTab = nil
        previousTab = nil
        focusOrder = []
        tabDwell = [:]
        relatedTabs = [:]
        tabTransition = [:]
        tabTimeOfDay = [:]
        similarWords = [:]
        mentions = [:]
        rows = []
        searchIndex = TabSearchIndex([])
        openTabs = OpenTabLookup([])
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

    @objc private func toggleGoogle(_ sender: Any?) {
        guard !preview else { return }
        let enable = !googleEnabled
        if enable {
            let alert = NSAlert()
            alert.messageText = "Enable Google Suggestions?"
            alert.informativeText = "Eligible typed search text will be sent to Google for suggestions. Local history is not sent. These are generic suggestions, not signed-in Google account predictions. Searches still use Safari's configured search engine."
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        UserDefaults.standard.set(enable, forKey: "GoogleSuggestionsEnabled")
        googleItems.forEach { $0.state = enable ? .on : .off }
        googleSuggestions.clearCache()
        remoteSuggestions = []
        if panel.isVisible {
            if ready { updateRows(preserveSelection: true) }
            requestSuggestions()
        }
    }

    @objc private func toggleSafariHistory(_ sender: Any?) {
        guard !preview else { return }
        let enable = !safariHistoryEnabled
        UserDefaults.standard.set(enable, forKey: "SafariHistoryEnabled")
        historyItems.forEach { $0.state = enable ? .on : .off }
        // Remove imported results immediately; a denied or superseded read cannot leave them visible.
        historyIndex = HistorySearchIndex(.empty)
        indexedHistory = nil
        historyLoaded = false
        historyError = nil
        if ready && panel.isVisible { updateRows(preserveSelection: true) }
        updatePermissionLabels()
        reloadHistory()
    }

    @objc private func togglePageText(_ sender: Any?) {
        guard !preview else { return }
        let enable = !pageTextEnabled
        if enable {
            let alert = NSAlert()
            alert.messageText = "Search Page Text?"
            alert.informativeText = "Tab Scout will read the visible text of Safari pages after you have looked at them for a few seconds, so typing finds tabs that mention your words. The text stays in memory on this Mac: it is never saved or sent, and is dropped when a tab closes or this option is turned off. Pages you have not viewed are not read."
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        UserDefaults.standard.set(enable, forKey: "PageTextEnabled")
        pageTextItems.forEach { $0.state = enable ? .on : .off }
        if enable {
            if let current = focusTracker.current { readPageText(current) }
        } else {
            pageText.removeAll()
            pageTextQueue.removeAll()
        }
    }

    @objc private func clearHistory(_ sender: Any?) {
        guard !preview else { return }
        let alert = NSAlert()
        alert.messageText = "Clear Tab Scout History?"
        alert.informativeText = "This removes searches and tab choices saved by Tab Scout, and everything it learned from them. Safari's browsing history is not changed."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        historyStore.clearLocal()
        learning.clear()
        pageText.removeAll()
        googleSuggestions.clearCache()
        remoteSuggestions = []
        reloadHistory()
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 382), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tab Scout"
        window.isReleasedWhenClosed = false
        setupWindow = window
        guard let content = window.contentView else { return }
        let heading = NSTextField(labelWithString: "Permissions")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.frame = NSRect(x: 28, y: 327, width: 200, height: 28)
        content.addSubview(heading)
        let version = NSTextField(labelWithString: versionText)
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        version.alignment = .right
        version.lineBreakMode = .byTruncatingMiddle
        version.isSelectable = true
        version.frame = NSRect(x: 232, y: 333, width: 220, height: 16)
        content.addSubview(version)
        let axTitle = NSTextField(labelWithString: controlPermissionName)
        axTitle.font = .systemFont(ofSize: 15, weight: .medium)
        axTitle.frame = NSRect(x: 28, y: 281, width: 260, height: 22)
        content.addSubview(axTitle)
        accessibilityState = NSTextField(labelWithString: "")
        accessibilityState?.font = .systemFont(ofSize: 12)
        accessibilityState?.textColor = .secondaryLabelColor
        accessibilityState?.frame = NSRect(x: 28, y: 256, width: 280, height: 20)
        content.addSubview(accessibilityState!)
        let ax = NSButton(title: "Open Settings", target: self, action: #selector(openAccessibility(_:)))
        ax.bezelStyle = .rounded
        ax.frame = NSRect(x: 322, y: 265, width: 132, height: 32)
        content.addSubview(ax)
        let safariTitle = NSTextField(labelWithString: "Safari")
        safariTitle.font = .systemFont(ofSize: 15, weight: .medium)
        safariTitle.frame = NSRect(x: 28, y: 214, width: 260, height: 22)
        content.addSubview(safariTitle)
        safariState = NSTextField(labelWithString: "")
        safariState?.font = .systemFont(ofSize: 12)
        safariState?.textColor = .secondaryLabelColor
        safariState?.frame = NSRect(x: 28, y: 189, width: 280, height: 20)
        content.addSubview(safariState!)
        let safari = NSButton(title: "Allow Access", target: self, action: #selector(requestSafari(_:)))
        safari.bezelStyle = .rounded
        safari.frame = NSRect(x: 322, y: 198, width: 132, height: 32)
        content.addSubview(safari)
        let historyTitle = NSTextField(labelWithString: "Safari History (Optional)")
        historyTitle.font = .systemFont(ofSize: 15, weight: .medium)
        historyTitle.frame = NSRect(x: 28, y: 124, width: 280, height: 22)
        content.addSubview(historyTitle)
        historyState = NSTextField(labelWithString: "")
        historyState?.font = .systemFont(ofSize: 12)
        historyState?.textColor = .secondaryLabelColor
        historyState?.frame = NSRect(x: 28, y: 99, width: 280, height: 20)
        content.addSubview(historyState!)
        let history = NSButton(title: "Open Settings", target: self, action: #selector(openHistorySettings(_:)))
        history.bezelStyle = .rounded
        history.frame = NSRect(x: 322, y: 108, width: 132, height: 32)
        content.addSubview(history)
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
        historyState?.stringValue = !safariHistoryEnabled ? "Off" : !historyLoaded ? "Checking..." : historyError == nil ? "Allowed" : "Unavailable; local choices still work"
        historyState?.toolTip = historyError?.localizedDescription
        setupStatus?.stringValue = trusted && safariAllowed && eventTap != nil ? "Ready" : "Permissions needed"
    }

    @objc private func openAccessibility(_ sender: Any?) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    @objc private func openHistorySettings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Safari History Access"
        alert.informativeText = "macOS protects Safari history with Full Disk Access, a broad permission. Tab Scout reads history locally and never sends it to Google. Add this Tab Scout.app under Privacy & Security > Full Disk Access, then restart Tab Scout. Tab search and local choices work without this permission."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
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
