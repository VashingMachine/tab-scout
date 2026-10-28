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

/// The results' scroll view offers every scroll event to `sideways` first, which takes those of a sideways swipe.
/// Overriding scrollWheel also turns off responsive scrolling, which would otherwise hand the rest of a gesture to
/// the scroll view after its first event, out of the palette's sight.
private final class ResultsScrollView: NSScrollView {
    var sideways: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if sideways?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate,
                         NSMenuDelegate {
    private let preview = CommandLine.arguments.contains("--preview")
    private var bridges: [Browser: BrowserBridge] = [:]
    private var stores: [Browser: TabStore] = [:]
    /// Each browser's latest tabs while the palette is open, merged into `tabs`.
    private var snapshots: [Browser: TabSnapshot] = [:]
    /// Browsers asked for their tabs whose answer has not arrived yet.
    private var waiting: Set<Browser> = []
    private var browserErrors: [Browser: Error] = [:]
    private lazy var favicons = FaviconStore()
    private lazy var browserHistory = BrowserHistory()
    private lazy var historyStore = HistoryStore(safariReader: { url, date in
        AppDelegate.excludedProfiles.contains(HistoryProfile.safariID) ? .empty : try HistoryStore.readSafari(at: url, now: date)
    }, profileReader: { [weak self, browserHistory] date in
        let found = browserHistory.read(excluding: AppDelegate.excludedProfiles, now: date)
        DispatchQueue.main.async { self?.didImport(found) }
        return found.snapshot
    })
    /// Every browser profile the last history import found, for the History Profiles menu.
    private var historyProfiles: [HistoryProfile] = []
    private var unreadableProfiles: Set<String> = []
    private lazy var learning = LearningStore(directory: preview ? nil : LearningStore.defaultDirectory)
    private lazy var wordNeighbors = WordNeighbors()
    private var similarWords: [BrowserTab: String] = [:]
    private var pageText = PageTextIndex()
    private var pageTextQueue: [BrowserTab] = []
    private var pageTextReading = false
    private var pageTextItems: [NSMenuItem] = []
    private var mentions: [BrowserTab: String] = [:]
    private var pageTextEnabled: Bool { UserDefaults.standard.bool(forKey: "PageTextEnabled") }
    private let assistant = TabAssistant()
    private var assistantQuestion: String?
    private var assistantPicks: [BrowserTab] = []
    private var assistantStatus: String?
    private var assistantWork: DispatchWorkItem?
    private let chromeLink = ChromeExtensionLink()
    private let grouper = TabGrouper()
    private let chromeProfiles = ChromeProfiles()
    /// The profiles of the browser the palette opened over, while it has more than one.
    private var profileState: ProfileState?
    private var profileSwipe = ProfileSwipe(count: 0, index: 0)
    /// The profile Chrome is in, or is being switched to.
    private var chromeProfile = 0
    private var profileTimer: Timer?
    private var profileSwitch: DispatchWorkItem?
    private var profileSwitching = false
    /// While Chrome brings a profile's window forward, the palette takes keyboard focus back instead of closing.
    private var keepPanelUntil: Date?
    /// After a profile switch, no browser is read again until the palette closes, so the listed tabs change once,
    /// to the new profile's, and never reorder under the pointer.
    private var listFrozen = false
    /// After a profile switch, the tab Chrome reports on screen, which the listed tabs follow instead of the one read
    /// with them.
    private var activeOverride: BrowserTab?
    /// From a profile switch until its tabs are listed; Enter pressed meanwhile waits for them.
    private var awaitingProfileTabs = false
    /// How many profiles Chrome had when last read. With more than one, the palette over Chrome lists only the profile
    /// in front.
    private var chromeProfileCount = 0
    /// Which extension connection, and so which Chrome profile, sees each Chrome window. A window belongs to one profile
    /// for good, so answers are kept while the same extensions stay connected.
    private var windowOwners: [Int: Int] = [:]
    private var ownerConnections: Set<Int> = []
    private var learningOwners = false
    /// Whether the palette is over a Chrome profile whose windows cannot be told from other profiles', for lack of
    /// Tab Scout's extension.
    private var profilesUnseparated = false
    private var lastSeen: [PageTextIndex.Key: Date] = [:]
    private var shownFeatures: [BrowserTab: RankingFeatures] = [:]
    private var rankingItem: NSMenuItem?
    private var training = false
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
    private lazy var relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    private var googleEnabled: Bool { UserDefaults.standard.bool(forKey: "GoogleSuggestionsEnabled") }
    private var safariHistoryEnabled: Bool { UserDefaults.standard.bool(forKey: "SafariHistoryEnabled") }
    /// Read by the history worker too; UserDefaults is safe to read from any thread.
    private static var excludedProfiles: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "ExcludedHistoryProfiles") ?? [])
    }
    private var searchIndex = TabSearchIndex([])
    private var windowNumbers: [Browser: [Int: Int]] = [:]
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var capturedT = false
    /// The browser in front, nil while another app is.
    private var frontBrowser: Browser?
    /// The browser most recently in front: new tabs open there, and the palette centers on its window.
    private var lastBrowser: Browser = .safari
    private var enabled = true
    private var workspaceObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var permissionTimer: Timer?
    private var cacheTimer: Timer?
    private var panel: SearchPanel!
    private var searchField: NSTextField!
    private var table: NSTableView!
    private var results: NSScrollView!
    private var profileAura: ProfileAuraView!
    private var profilePill: ProfilePillView!
    private var profileDots: ProfileDotsView!
    /// Keeps the footer's text clear of the profile dots while they show.
    private var footerBeforeDots: NSLayoutConstraint!
    private var footer: NSTextField!
    private var emptyLabel: NSTextField!
    private var retryButton: NSButton!
    private var tabs: [BrowserTab] = []
    private var focusHistory = TabFocusHistory()
    private var focusTracker = FocusTracker()
    private var focusObservers: [Browser: BrowserFocusObserver] = [:]
    private var activeReadInFlight = false
    private var activeReadAgain = false
    private var launchObserver: NSObjectProtocol?
    private var tabDwell: [BrowserTab: Double] = [:]
    private var relatedTabs: [BrowserTab: (strength: Double, shared: TabEntity)] = [:]
    private var tabTransition: [BrowserTab: Double] = [:]
    private var tabTimeOfDay: [BrowserTab: Double] = [:]
    private var activeTab: BrowserTab?
    private var previousTab: BrowserTab?
    private var focusOrder: [BrowserTab] = []
    private var rows: [SearchRow] = []
    private var requestID = 0
    private var loading = false
    private var acting = false
    private var ready = false
    private var pendingActivation: Bool?
    /// While Shift is held, the typed text opening in a new tab is listed first, as Shift+Enter does.
    private var newTabFirst = false
    private var returnApp: NSRunningApplication?
    private var setupWindow: NSWindow?
    private var setupRows: [SetupStep: SetupRow] = [:]
    private var setupStatus: NSTextField?
    private var loginBox: NSButton?
    /// Browsers whose Automation access the setup window is asking for.
    private var requestingAccess: Set<Browser> = []
    /// How many Chrome profiles had the extension connected when Add to Chrome was clicked; the setup window shows
    /// how to add it until one more connects.
    private var chromeProfilesBeforeAdding: Int?
    /// Whether Tab Scout's extension has connected from a Chrome profile, so it counts as added while Chrome is closed.
    private var chromeExtensionAdded: Bool {
        get { UserDefaults.standard.bool(forKey: "ChromeExtensionAdded") }
        set { UserDefaults.standard.set(newValue, forKey: "ChromeExtensionAdded") }
    }
    private var allowedBrowsers: Set<Browser> = []
    private var deniedBrowsers: Set<Browser> = []
    /// Browsers whose page text could not be read; Chrome needs Allow JavaScript from Apple Events.
    private var pageTextUnavailable: Set<Browser> = []
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
        let scripts = ["SafariBridge", "ChromeBridge"].compactMap { Bundle.main.url(forResource: $0, withExtension: "scpt") }
        guard scripts.count == 2 else {
            let alert = NSAlert()
            alert.messageText = "Tab Scout could not start"
            alert.informativeText = "SafariBridge.scpt or ChromeBridge.scpt is missing. Rebuild the app using build.sh."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        bridges = [.safari: BrowserBridge(scriptURL: scripts[0]),
                   // Chrome may be launching or asking for permission; Safari's tabs never wait for it anyway.
                   .chrome: BrowserBridge(browser: .chrome, scriptURL: scripts[1],
                                          executor: { try ScriptProcess.execute(scriptURL: $0, arguments: $1, timeout: 20) })]
        for browser in Browser.allCases {
            let store = TabStore { [weak self] completion in self?.bridges[browser]?.list(completion: completion) }
            store.onPermissionDenied = { [weak self] in
                self?.allowedBrowsers.remove(browser)
                self?.deniedBrowsers.insert(browser)
                self?.updateSetup()
            }
            // Every read, including background prewarms, proves access, and a read of the browser last in front notes
            // which tab is on screen.
            store.onSnapshot = { [weak self] snapshot in
                guard let self else { return }
                // Safari's script answers without asking Safari when it is closed, which proves nothing about access.
                if !snapshot.tabs.isEmpty || self.isRunning(browser) {
                    self.allowedBrowsers.insert(browser)
                    self.deniedBrowsers.remove(browser)
                }
                if browser == .chrome { self.learnWindowOwners(Set(snapshot.tabs.map(\.windowID))) }
                guard browser == self.lastBrowser, let active = snapshot.active else { return }
                self.observeFocus(active)
            }
            stores[browser] = store
            let observer = BrowserFocusObserver()
            observer.onChange = { [weak self] in if self?.frontBrowser == browser { self?.readActiveTab() } }
            focusObservers[browser] = observer
        }
        buildMenu()
        buildPanel()
        reloadHistory()
        frontBrowser = Browser(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        lastBrowser = frontBrowser ?? (!isRunning(.safari) && isRunning(.chrome) ? .chrome : .safari)
        // A preview can show the palette as it opens over a given browser: --browser chrome.
        if preview, let index = CommandLine.arguments.firstIndex(of: "--browser"), index + 1 < CommandLine.arguments.count,
           let browser = Browser(rawValue: CommandLine.arguments[index + 1]) {
            lastBrowser = browser
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let was = self.frontBrowser
            self.frontBrowser = Browser(bundleID: app.bundleIdentifier)
            if was != nil && self.frontBrowser != was { self.pauseFocus() }
            guard let browser = self.frontBrowser else { return }
            self.lastBrowser = browser
            if !self.preview && self.allowedBrowsers.contains(browser) { self.stores[browser]?.prewarm(); self.readActiveTab() }
            // Knowing beforehand whether Chrome has several profiles lists only the one in front from the start.
            if browser == .chrome && !self.preview {
                self.chromeProfiles.read { [weak self] state in if let state { self?.chromeProfileCount = state.profiles.count } }
            }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Browser(bundleID: app.bundleIdentifier) != nil else { return }
            self?.startFocusObservers()
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, !self.preview, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let browser = Browser(bundleID: app.bundleIdentifier) else { return }
            self.stores[browser]?.invalidate()
            if self.focusTracker.current?.browser == browser { self.pauseFocus() }
            self.focusObservers[browser]?.stop()
            self.focusHistory.forget(browser)
            self.snapshots[browser] = nil
            // New tabs go to a browser still open; with none open, to the one just quit.
            if self.lastBrowser == browser, let other = Browser.allCases.first(where: { $0 != browser && self.isRunning($0) }) {
                self.lastBrowser = other
            }
            if self.panel.isVisible { self.loadTabs(force: true) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            guard event.type == .scrollWheel else { return self.handleKey(event) }
            // Over the results, their scroll view offers each event to the swipe itself.
            let point = self.results.convert(event.locationInWindow, from: nil)
            return event.window === self.panel && self.results.bounds.contains(point) ? event : self.handleScroll(event)
        }
        if preview, let index = CommandLine.arguments.firstIndex(of: "--appearance"), index + 1 < CommandLine.arguments.count {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[index + 1] == "light" ? .aqua : .darkAqua)
        }
        if preview, let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            renderSnapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else if preview {
            showSearch(nil)
        } else {
            installTapIfAllowed()
            startFocusObservers()
            chromeLink.start()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.installTapIfAllowed()
                self?.startFocusObservers()
                self?.updateSetup()
            }
            cacheTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.stores.values.allSatisfy({ $0.snapshot == nil }) { self.clearResults() }
                if self.panel.isVisible && !self.acting && !self.loading && !self.listFrozen { self.loadTabs() }
                else if let browser = self.frontBrowser, self.allowedBrowsers.contains(browser) { self.stores[browser]?.prewarm() }
            }
            if eventTap == nil { showSetup(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if eventTap == nil && !preview { showSetup(nil) } else { showSearch(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        focusObservers.values.forEach { $0.stop() }
        pauseFocus()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        permissionTimer?.invalidate()
        cacheTimer?.invalidate()
        if !preview {
            googleSuggestions.cancel()
            chromeLink.stop()
        }
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
        let search = menu.addItem(withTitle: "Search Tabs", action: #selector(showSearch(_:)), keyEquivalent: "")
        search.target = self
        menu.addItem(.separator())
        pauseItem = menu.addItem(withTitle: "Capture Cmd+T in Safari and Chrome", action: #selector(toggleCapture(_:)), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.state = .on
        let setup = menu.addItem(withTitle: "Set Up Tab Scout...", action: #selector(showSetup(_:)), keyEquivalent: "")
        setup.target = self
        menu.addItem(.separator())
        addSearchPreferences(to: menu)
        menu.addItem(.separator())
        loginItem = menu.addItem(withTitle: "Start at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        rankingItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        updateRankingItem()
        menu.addItem(withTitle: versionText, action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit Tab Scout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    private func addSearchPreferences(to menu: NSMenu) {
        let google = menu.addItem(withTitle: "Google Suggestions", action: #selector(toggleGoogle(_:)), keyEquivalent: "")
        google.target = self
        google.state = googleEnabled ? .on : .off
        googleItems.append(google)
        let history = menu.addItem(withTitle: "Use Browser History", action: #selector(toggleSafariHistory(_:)), keyEquivalent: "")
        history.target = self
        history.state = safariHistoryEnabled ? .on : .off
        historyItems.append(history)
        let profiles = menu.addItem(withTitle: "History Profiles", action: nil, keyEquivalent: "")
        profiles.submenu = NSMenu(title: "History Profiles")
        profiles.submenu?.delegate = self
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
            if ShortcutDecision.shouldCapture(keyCode: code, command: flags.contains(.maskCommand), shift: flags.contains(.maskShift), control: flags.contains(.maskControl), option: flags.contains(.maskAlternate), browserActive: owner.frontBrowser != nil, enabled: owner.enabled) {
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
    private func startFocusObservers() {
        guard !preview, AXIsProcessTrusted() else { return }
        for (browser, observer) in focusObservers where !observer.isObserving {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first else { continue }
            if observer.start(processID: app.processIdentifier) && frontBrowser == browser { readActiveTab() }
        }
    }

    private func isRunning(_ browser: Browser) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty
    }

    private func bridge(_ browser: Browser) -> BrowserBridge { bridges[browser]! }

    private func describe(_ error: Error, _ browser: Browser) -> String {
        (error as? BridgeError)?.message(for: browser) ?? error.localizedDescription
    }

    /// Reads the tab on screen, at most one read at a time with a pause after each, however busy the page title.
    private func readActiveTab() {
        guard !preview, let browser = frontBrowser, allowedBrowsers.contains(browser) else { return }
        if activeReadInFlight { activeReadAgain = true; return }
        activeReadInFlight = true
        bridge(browser).active { [weak self] result in
            guard let self else { return }
            if case .success(let tab) = result, self.frontBrowser == browser, let tab {
                self.observeFocus(tab)
                self.followFrontTab(tab)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.activeReadInFlight = false
                if self.activeReadAgain { self.activeReadAgain = false; self.readActiveTab() }
            }
        }
    }

    /// Reading time counts only while the tab's browser is in front.
    private func observeFocus(_ tab: BrowserTab) {
        focusHistory.focus(tab)
        lastSeen[PageTextIndex.Key(tab)] = Date()
        if lastSeen.count > 500 { lastSeen = lastSeen.filter { $0.value > Date().addingTimeInterval(-7 * 86_400) } }
        if frontBrowser == tab.browser, let visit = focusTracker.observe(tab, at: Date()) { recordVisit(visit) }
        // A page looked at for a few seconds has loaded; reading only viewed pages never wakes sleeping tabs.
        guard pageTextEnabled, !preview, !pageTextUnavailable.contains(tab.browser) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let current = self.focusTracker.current,
                  current.windowID == tab.windowID, current.url == tab.url else { return }
            self.readPageText(current)
        }
    }

    private func readPageText(_ tab: BrowserTab) {
        guard pageText.needsReading(tab, now: Date()), !pageTextQueue.contains(where: { PageTextIndex.Key($0) == PageTextIndex.Key(tab) }) else { return }
        pageTextQueue.append(tab)
        readNextPageText()
    }

    private func readNextPageText() {
        guard pageTextEnabled, !pageTextReading, !pageTextQueue.isEmpty else { return }
        let tab = pageTextQueue.removeFirst()
        pageTextReading = true
        bridge(tab.browser).text(of: tab) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text): if self.pageTextEnabled { self.pageText.store(text, for: tab, at: Date()) }
            // Chrome refuses page scripts until Allow JavaScript from Apple Events is on. Its pages are not asked
            // again until Search Page Text is turned on again.
            case .failure(let error): if tab.browser == .chrome && error as? BridgeError != .staleTab { self.pageTextUnavailable.insert(.chrome) }
            }
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
        profileAura = ProfileAuraView()
        profileAura.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(profileAura)

        // A launcher-style bar: the system search field keeps its magnifier at 13 pt whatever its font,
        // so the symbol is drawn beside a plain field at the text's own size.
        let searchFont = NSFont.systemFont(ofSize: 22)
        let glass = NSImageView(image: symbol("magnifyingglass") ?? NSImage())
        glass.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: searchFont.pointSize, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor
        glass.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(glass)
        searchField = NSTextField()
        searchField.placeholderString = "Search tabs or enter an address"
        searchField.font = searchFont
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.setAccessibilityLabel("Search tabs or enter an address")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(searchField)
        profilePill = ProfilePillView()
        profilePill.isHidden = true
        profilePill.onPress = { [weak self] in
            guard let self, self.profileSwipe.count > 1 else { return }
            self.moveProfile(to: (self.profileSwipe.target + 1) % self.profileSwipe.count)
        }
        profilePill.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(profilePill)
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
        let scroll = ResultsScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // Sideways scrolling switches profiles; the results never move that way.
        scroll.horizontalScrollElasticity = .none
        scroll.sideways = { [weak self] event in self?.handleScroll(event) == nil }
        scroll.documentView = table
        // Its layer fades the list from one profile's tabs to the next.
        scroll.wantsLayer = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        results = scroll

        emptyLabel = NSTextField(wrappingLabelWithString: "")
        emptyLabel.font = .systemFont(ofSize: 13)
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
        let settings = iconButton("gearshape", tip: "Set Up Tab Scout", action: #selector(showSetup(_:)))
        background.addSubview(retryButton)
        background.addSubview(settings)
        profileDots = ProfileDotsView()
        profileDots.isHidden = true
        profileDots.onSelect = { [weak self] index in self?.moveProfile(to: index) }
        profileDots.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(profileDots)
        footerBeforeDots = footer.trailingAnchor.constraint(lessThanOrEqualTo: profileDots.leadingAnchor, constant: -12)
        NSLayoutConstraint.activate([
            profileAura.topAnchor.constraint(equalTo: background.topAnchor),
            profileAura.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            profileAura.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            profileAura.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            profilePill.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            profilePill.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            profileDots.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            profileDots.centerYAnchor.constraint(equalTo: retryButton.centerYAnchor),
            // The magnifier and typed text line up with the result icons and titles below.
            glass.centerXAnchor.constraint(equalTo: background.leadingAnchor, constant: 36),
            glass.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 56),
            searchField.trailingAnchor.constraint(equalTo: profilePill.leadingAnchor, constant: -10),
            line.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
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
        let browserFrame = screens.first.flatMap { preview ? nil : BrowserWindowFrame.current(bundleID: lastBrowser.bundleID, primaryScreenTop: $0.frame.maxY) }
        if let origin = PanelPlacement.origin(panelSize: panel.frame.size, browserFrame: browserFrame,
                                              screens: screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) },
                                              fallbackScreen: fallback.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) }) {
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        keepPanelUntil = nil
        listFrozen = false
        activeOverride = nil
        // Cached tabs appear at once; the forced read catches tab switches made in the browser since the last one.
        loadTabs(force: true)
        loadProfiles()
        reloadHistory()
        DispatchQueue.main.async { Timing.log("open", since: opened) }
    }

    @objc private func refresh(_ sender: Any?) {
        guard !acting else { return }
        listFrozen = false
        activeOverride = nil
        loadTabs(force: true)
    }

    /// Draws the preview palette into a PNG from an invisible window, so the layout can be checked
    /// without taking keyboard focus from the person at the Mac.
    private func renderSnapshot(to url: URL) {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        loadProfiles()
        loadTabs()
        // --query shows typed results; a moment of run loop lets the preview's "?" answer arrive.
        if let index = CommandLine.arguments.firstIndex(of: "--query"), index + 1 < CommandLine.arguments.count {
            searchField.stringValue = CommandLine.arguments[index + 1]
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        guard let view = panel.contentView else { return NSApp.terminate(nil) }
        view.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        // --profile-position 0.4 draws the palette partway through a swipe to the next profile.
        if let index = CommandLine.arguments.firstIndex(of: "--profile-position"), index + 1 < CommandLine.arguments.count,
           let position = Double(CommandLine.arguments[index + 1]) {
            applyProfilePosition(position)
        }
        view.displayIfNeeded()
        var image = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        if profileState == nil, let image {
            view.cacheDisplay(in: view.bounds, to: image)
        } else {
            // Drawing views alone leaves out the profile's colors, which are layers. The glass cannot be drawn
            // offscreen, so plain gray stands in for it under the layers of everything on it.
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            image = ProfileArt.render(view.bounds.size, scale: panel.backingScaleFactor) { context in
                context.setFillColor(NSColor(white: dark ? 0.2 : 0.93, alpha: 1).cgColor)
                context.fill(view.bounds)
                for subview in view.subviews where !subview.isHidden {
                    context.saveGState()
                    context.translateBy(x: subview.frame.minX, y: subview.frame.minY)
                    // The profile's colors are layers, which render directly; text on the glass is vibrant, which only
                    // drawing shows.
                    if subview === profileAura || subview === profilePill {
                        subview.layer?.render(in: context)
                    } else if let drawn = subview.bitmapImageRepForCachingDisplay(in: subview.bounds) {
                        subview.cacheDisplay(in: subview.bounds, to: drawn)
                        drawn.cgImage.map { context.draw($0, in: CGRect(origin: .zero, size: subview.bounds.size)) }
                    }
                    context.restoreGState()
                }
            }.map(NSBitmapImageRep.init(cgImage:))
        }
        try? image?.representation(using: .png, properties: [:])?.write(to: url)
        NSApp.terminate(nil)
    }

    private func loadTabs(force: Bool = false) {
        requestID += 1
        let token = requestID
        if !ready {
            clearResults()
            footer.stringValue = "Loading tabs..."
        }
        emptyLabel.stringValue = ""
        retryButton.isEnabled = false
        if preview {
            let safari = [
                BrowserTab(windowID: 1, index: 1, title: "GitHub - Projects", url: "https://github.com/"),
                BrowserTab(windowID: 1, index: 2, title: "Apple Developer Documentation", url: "https://developer.apple.com/documentation/"),
                BrowserTab(windowID: 2, index: 1, title: "Wikipedia", url: "https://en.wikipedia.org/")
            ]
            let chrome = [BrowserTab(browser: .chrome, windowID: 5, index: 1, title: "Swift Forums", url: "https://forums.swift.org/")]
            focusHistory.focus(safari[1])
            focusHistory.focus(safari[0])
            waiting = [.safari, .chrome]
            loading = true
            for (browser, samples) in [(Browser.safari, safari), (.chrome, chrome)] {
                didLoad(browser, .success(TabSnapshot(tabs: samples, active: samples[0], index: TabSearchIndex(samples),
                                                      fetchedAt: Date(), revision: 0)), token: token)
            }
            return
        }
        // Chrome is asked only while it runs; Safari's script answers at once when Safari is closed.
        let browsers = Browser.allCases.filter { $0 == .safari || isRunning($0) }
        snapshots = snapshots.filter { browsers.contains($0.key) }
        browserErrors = browserErrors.filter { browsers.contains($0.key) }
        waiting = Set(browsers)
        loading = true
        for browser in browsers {
            stores[browser]?.load(force: force) { [weak self] result in self?.didLoad(browser, result, token: token) }
        }
    }

    /// A browser asked for tabs that has not answered once, so its tabs are missing rather than stale.
    private var awaitingTabs: Bool { waiting.contains { snapshots[$0] == nil } }

    private func didLoad(_ browser: Browser, _ result: Result<TabSnapshot, Error>, token: Int) {
        guard token == requestID, panel.isVisible else { return }
        waiting.remove(browser)
        loading = !waiting.isEmpty
        switch result {
        case .success(let snapshot):
            snapshots[browser] = snapshot
            browserErrors[browser] = nil
            // Safari's script answers without asking Safari when it is closed, which proves nothing about access.
            if !snapshot.tabs.isEmpty || isRunning(browser) {
                allowedBrowsers.insert(browser)
                deniedBrowsers.remove(browser)
            }
        case .failure(let error):
            // Tabs already shown from the cache stay; a refused browser's tabs go.
            browserErrors[browser] = error
            if case BridgeError.permission = error {
                allowedBrowsers.remove(browser)
                deniedBrowsers.insert(browser)
                snapshots[browser] = nil
            }
        }
        retryButton.isEnabled = true
        guard !snapshots.isEmpty else {
            // Nothing to show: wait for the other browsers, then explain the failure.
            if loading { return }
            pendingActivation = nil
            let failure = browserErrors[lastBrowser].map { (lastBrowser, $0) } ?? browserErrors.first.map { ($0.key, $0.value) }
            clearResults()
            footer.stringValue = "\(failure?.0.name ?? "Browser") access unavailable"
            footer.toolTip = failure.map { describe($0.1, $0.0) }
            emptyLabel.stringValue = footer.toolTip ?? ""
            updateSetup()
            return
        }
        show(CombinedTabs(snapshots, front: lastBrowser))
        if !awaitingTabs, let forceNew = pendingActivation {
            pendingActivation = nil
            activate(forceNew: forceNew)
        }
    }

    /// Lists the merged tabs, again each time another browser's tabs arrive.
    /// `newContext` starts the selection over, as after a profile switch.
    private func show(_ combined: CombinedTabs, newContext: Bool = false) {
        let hadResults = ready && !newContext
        let active = activeOverride ?? combined.active
        let listed = profileTabs(combined.tabs, active: active)
        tabs = listed
        searchIndex = listed.count == combined.tabs.count ? combined.index : TabSearchIndex(listed)
        openTabs = OpenTabLookup(listed)
        activeTab = active
        previousTab = focusHistory.previous(active: active, in: listed)
        focusOrder = focusHistory.order(in: listed)
        let now = Date()
        tabDwell = Dictionary(listed.compactMap { tab -> (BrowserTab, Double)? in
            guard let url = HistoryIdentity.url(tab.url) else { return nil }
            let strength = learning.state.engagement.strength(url: url, now: now)
            return strength > 0 ? (tab, strength) : nil
        }, uniquingKeysWith: max)
        relatedTabs = RelatedTabs.relations(to: active, in: listed)
        // Until every browser has answered, the text of a missing browser's pages is kept; so is the text of tabs
        // another profile lists.
        if !awaitingTabs { pageText.retain(combined.tabs) }
        let habits = learning.state.habits
        let from = active.flatMap { Habits.site($0.url) }
        tabTransition = [:]
        tabTimeOfDay = [:]
        for tab in listed {
            guard let site = Habits.site(tab.url) else { continue }
            if let from { tabTransition[tab] = habits.transition(from: from, to: site, now: now) }
            tabTimeOfDay[tab] = habits.timeOfDay(site: site, at: now, calendar: .current, now: now)
        }
        windowNumbers = [:]
        for tab in tabs where windowNumbers[tab.browser]?[tab.windowID] == nil {
            windowNumbers[tab.browser, default: [:]][tab.windowID] = (windowNumbers[tab.browser]?.count ?? 0) + 1
        }
        ready = true
        updateRows(preserveSelection: hadResults)
        updateSetup()
    }

    func controlTextDidChange(_ obj: Notification) {
        pendingActivation = nil
        remoteSuggestions = []
        requestAssistant()
        if ready { updateRows() }
        requestSuggestions()
    }

    /// Asks the on-device model about a "?" request once typing pauses.
    private func requestAssistant() {
        guard let question = AssistantPrompt.question(in: searchField.stringValue) else { return resetAssistant() }
        guard question != assistantQuestion else { return }
        resetAssistant()
        assistantQuestion = question
        guard question.count >= 3 else { return }
        guard preview || TabAssistant.isAvailable else {
            assistantStatus = "Apple Intelligence is not available on this Mac"
            return
        }
        assistantStatus = "Asking Apple Intelligence..."
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.assistantQuestion == question else { return }
            if self.preview {
                self.assistantPicks = Array(self.tabs.filter { $0 != self.activeTab }.prefix(1))
                self.assistantStatus = "Picked by Apple Intelligence"
                return self.updateRows(preserveSelection: true)
            }
            let prompt = AssistantPrompt.prompt(question: question, tabs: self.tabs, recent: self.focusOrder, active: self.activeTab,
                                                lastSeen: { self.lastSeen[PageTextIndex.Key($0)] }, now: Date())
            let started = DispatchTime.now()
            self.assistant.pick(prompt) { [weak self] result in
                guard let self, self.assistantQuestion == question, self.panel.isVisible else { return }
                Timing.log("assistant", since: started)
                switch result {
                case .success(let picks):
                    self.assistantPicks = picks
                    self.assistantStatus = picks.isEmpty ? "Apple Intelligence found no matching tab" : "Picked by Apple Intelligence"
                case .failure:
                    self.assistantStatus = "Apple Intelligence could not answer"
                }
                if self.ready { self.updateRows(preserveSelection: true) }
            }
        }
        assistantWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func resetAssistant() {
        assistantWork?.cancel()
        assistantWork = nil
        assistant.cancel()
        assistantQuestion = nil
        assistantPicks = []
        assistantStatus = nil
    }

    private func requestSuggestions() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Requests for the on-device model are personal and commands are not searches; neither is sent to Google.
        guard AssistantPrompt.question(in: query) == nil, PaletteCommand.query(in: query) == nil else {
            googleSuggestions.cancel()
            return
        }
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
        historyStore.load(includeBrowsers: safariHistoryEnabled) { [weak self] result in
            guard let self, token == self.historyRequestID else { return }
            self.historyLoaded = true
            if case .failure(let error) = result { self.historyError = error } else { self.historyError = nil }
            let snapshot = (try? result.get()) ?? self.historyStore.snapshot
            // Indexing a large Safari history takes about 0.1 s, so an unchanged history keeps its index.
            guard snapshot != self.indexedHistory else { self.updateSetup(); return }
            let started = DispatchTime.now()
            self.historyQueue.async {
                let index = HistorySearchIndex(snapshot)
                DispatchQueue.main.async {
                    guard token == self.historyRequestID else { return }
                    Timing.log("history index", since: started)
                    self.historyIndex = index
                    self.indexedHistory = snapshot
                    self.updateSetup()
                    if self.ready && self.panel.isVisible { self.updateRows(preserveSelection: true) }
                }
            }
        }
    }

    private func updateRows(preserveSelection: Bool = false) {
        // A selection still on the top row follows the top row, so Enter keeps meaning the default result.
        // While Shift is held, the new tab listed first is selected.
        let navigated = rows.indices.contains(table.selectedRow) && table.selectedRow != ResultNavigation.first(in: rows)
        let selected = preserveSelection && navigated && !newTabFirst ? rows[table.selectedRow] : nil
        let typed = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let command = PaletteCommand.query(in: typed) { return showCommands(matching: command, keeping: selected) }
        // A "?" request is also matched as ordinary text while the on-device model answers.
        let question = AssistantPrompt.question(in: typed)
        let query = question ?? typed
        let matches = searchIndex.matches(query: query)
        let now = Date()
        let similar = SemanticSearch.matches(query, in: searchIndex, textMatches: matches.count) { self.wordNeighbors($0) }
        similarWords = Dictionary(similar.map { ($0.tab, $0.word) }, uniquingKeysWith: { first, _ in first })
        let mentioned = pageTextEnabled ? pageText.matches(query, in: tabs) : [:]
        mentions = mentioned.mapValues(\.snippet)
        var context = RankingContext(focusOrder: focusOrder, affinity: learning.state.affinity.strengths(for: query, now: now),
                                     dwell: tabDwell, related: relatedTabs.mapValues(\.strength),
                                     transition: tabTransition, timeOfDay: tabTimeOfDay,
                                     semantic: Dictionary(similar.map { ($0.tab, $0.strength) }, uniquingKeysWith: max),
                                     content: mentioned.mapValues(\.strength),
                                     assistant: question != nil && question == assistantQuestion
                                        ? Dictionary(assistantPicks.enumerated().map { ($1, 1 - 0.1 * Double($0)) }, uniquingKeysWith: max) : [:])
        context.weights = learning.state.ranking.weights
        let results = SearchResultBuilder.build(query: query, matches: matches, allTabs: tabs, history: historyIndex,
                                                suggestions: remoteSuggestions, now: now, openTabs: openTabs,
                                                previousTab: previousTab, activeTab: activeTab, context: context)
        rows = newTabFirst ? SearchRow.newTabFirst(NewTabDestination.from(query), in: results.rows) : results.rows
        shownFeatures = results.features
        table.reloadData()
        if let row = selected.flatMap({ SearchRow.retainedSelection(of: $0, in: rows) }) ?? ResultNavigation.first(in: rows) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        emptyLabel.stringValue = ""
        let windows = windowNumbers.values.reduce(0) { $0 + $1.count }
        let tabCount = "\(tabs.count) \(tabs.count == 1 ? "tab" : "tabs")"
        let windowCount = "\(windows) \(windows == 1 ? "window" : "windows")"
        let localCount = rows.filter { row in
            switch row { case .previousTab, .tab, .history, .recentSearch: return true; default: return false }
        }.count
        let suggestionCount = rows.filter { if case .suggestion = $0 { return true }; return false }.count
        footer.stringValue = query.isEmpty ? "\(tabCount) in \(windowCount)" : "\(localCount) local \(localCount == 1 ? "result" : "results")" + (suggestionCount > 0 ? " | \(suggestionCount) Google suggestions" : "")
        // A browser that could not be read is named, so its missing tabs are explained.
        let failed = Browser.allCases.filter { browserErrors[$0] != nil }
        if !failed.isEmpty { footer.stringValue += " | " + failed.map(\.name).joined(separator: ", ") + " unavailable" }
        // Without Tab Scout's extension, Chrome cannot say which profile a window belongs to.
        if profilesUnseparated { footer.stringValue += " | Every profile's tabs" }
        if question != nil { footer.stringValue = assistantStatus ?? "Type a request for Apple Intelligence" }
        let problems = [preview ? nil : historyStore.localStorageError?.localizedDescription,
                        profilesUnseparated ? "Add Tab Scout's Chrome extension to each profile to list only the tabs of the profile in front." : nil]
            + failed.map { browser in browserErrors[browser].map { describe($0, browser) } }
        footer.toolTip = problems.compactMap { $0 }.isEmpty ? nil : problems.compactMap { $0 }.joined(separator: "\n")
    }

    /// Lists the commands of the browser the palette opened over instead of tabs and pages.
    private func showCommands(matching text: String, keeping selected: SearchRow?) {
        rows = PaletteCommand.matches(text, in: lastBrowser).map(SearchRow.command)
        shownFeatures = [:]
        table.reloadData()
        if let row = selected.flatMap({ rows.firstIndex(of: $0) }) ?? ResultNavigation.first(in: rows) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        let offered = PaletteCommand.matches("", in: lastBrowser)
        emptyLabel.stringValue = !rows.isEmpty ? "" : offered.isEmpty ? "\(lastBrowser.name) has no commands yet" : "No matching command"
        footer.stringValue = offered.isEmpty ? "Commands" : "Commands for \(lastBrowser.name)"
        footer.toolTip = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) && !rows[row].isSelectable ? SectionHeaderCell.height : 44
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if case .section(let section) = rows[row] {
            let header = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("section"), owner: self) as? SectionHeaderCell
                ?? SectionHeaderCell()
            header.title = section.rawValue
            return header
        }
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("resultCell"), owner: self) as? ResultCell ?? ResultCell()
        switch rows[row] {
        case .previousTab(let tab), .tab(let tab):
            let image = preview ? nil : favicons.imageFor(url: tab.url)
            var location = (tab.url.isEmpty ? "Start Page" : tab.url) + " | " + windowLabel(tab)
            if assistantPicks.contains(tab), AssistantPrompt.question(in: searchField.stringValue) == assistantQuestion {
                location = "Picked by Apple Intelligence | " + location
            } else if let snippet = mentions[tab] {
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
                cell.configure(title: "New tab", detail: "\(lastBrowser.name)'s new-tab page", url: nil,
                               image: symbol("plus.square"), tint: .systemBlue)
            case .url(let url):
                cell.configure(title: url == "about:blank" ? "New tab" : "Open \(url)",
                               detail: blankActiveTab == nil ? "New \(lastBrowser.name) tab" : "This empty tab", url: nil,
                               image: symbol("plus.square"), tint: .systemBlue)
            case .search(let query):
                cell.configure(title: "Search for \(query)", detail: lastBrowser.searchEngine, url: nil,
                               image: symbol("magnifyingglass"), tint: .systemBlue)
            }
        case .recentSearch(let search):
            cell.configure(title: search.query, detail: relativeDate.localizedString(for: search.lastUsed, relativeTo: Date()),
                           url: nil, image: symbol("clock"), tint: .secondaryLabelColor)
        case .suggestion(let query):
            cell.configure(title: query, detail: "Google", url: nil, image: symbol("magnifyingglass"), tint: .secondaryLabelColor)
        case .command(let command):
            cell.configure(title: command.name, detail: command.summary, url: nil, image: symbol("rectangle.3.group"), tint: .systemBlue)
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

    /// "Window 2", or "Chrome window 2" once tabs from more than one browser are listed.
    private func windowLabel(_ tab: BrowserTab) -> String {
        let number = windowNumbers[tab.browser]?[tab.windowID] ?? 1
        return windowNumbers.count > 1 ? "\(tab.browser.name) window \(number)" : "Window \(number)"
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel?.isKeyWindow == true else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .flagsChanged { holdShift(ResultKeyboard.holdsShiftAlone(flags)); return event }
        if event.keyCode == 53 { if !acting { dismiss(restoreFocus: true) }; return nil }
        if event.keyCode == 17 && flags == .command { if !acting { dismiss(restoreFocus: true) }; return nil }
        if event.keyCode == 36 || event.keyCode == 76 {
            activate(forceNew: ResultKeyboard.forcesNewTab(flags))
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

    /// Shows the profiles of the browser the palette opened over. Only Chrome's can be told apart and switched.
    private func loadProfiles() {
        guard lastBrowser == .chrome else { return showProfiles(nil) }
        if preview {
            let names = CommandLine.arguments.firstIndex(of: "--profiles").flatMap {
                $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1].split(separator: ",").map(String.init) : nil
            } ?? ["Personal", "Work"]
            let menu = names.enumerated().map { ProfileMenuItem(title: $0.element, checked: $0.offset == 0) }
            chromeProfileCount = names.count
            return showProfiles(ProfileMenu.state(menu: menu, local: [], lastUsed: nil))
        }
        guard isRunning(.chrome) else { return showProfiles(nil) }
        chromeProfiles.read { [weak self] state in
            guard let self, self.panel.isVisible, self.lastBrowser == .chrome, !self.acting else { return }
            // Profiles added or removed since Chrome was last read change whether one profile is listed.
            if let state, state.profiles.count != self.chromeProfileCount {
                self.chromeProfileCount = state.profiles.count
                self.rescope(fade: false)
            }
            self.showProfiles(state)
        }
    }

    /// Shows `state`'s profiles, or hides them all with nil or a single profile. A menu read again only moves the
    /// palette to the profile Chrome is in while nothing is moving or switching.
    private func showProfiles(_ state: ProfileState?) {
        guard let state, state.profiles.count > 1 else {
            profileState = nil
            profileSwipe = ProfileSwipe(count: 0, index: 0)
            profileSwitch?.cancel()
            profileSwitch = nil
            stopProfileTimer()
            // Hidden rather than emptied: the next palette over the same profiles shows them without drawing again.
            for view in [profileAura, profilePill, profileDots] as [NSView] {
                view.isHidden = true
            }
            footerBeforeDots.isActive = false
            applyProfilePosition()
            return
        }
        let current = state.current ?? 0
        if profileState?.profiles == state.profiles {
            profileState = state
            guard current != chromeProfile, profileSwipe.axis != .sideways, profileSwitch == nil, !profileSwitching else { return }
            chromeProfile = current
            profileSwipe.move(to: current)
            return startProfileTimer()
        }
        let fresh = profileState == nil
        profileState = state
        chromeProfile = current
        profileSwipe = ProfileSwipe(count: state.profiles.count, index: current)
        stopProfileTimer()
        profileDots.colors = state.profiles.map(\.color)
        profilePill.show(state.profiles)
        for view in [profileAura, profilePill, profileDots] as [NSView] {
            view.isHidden = false
        }
        footerBeforeDots.isActive = true
        panel.contentView?.layoutSubtreeIfNeeded()
        // Each profile's color glows from behind its badge.
        profileAura.show(state.profiles, glowing: state.profiles.indices.map { profileAura.convert(profilePill.badgeCenter($0), from: profilePill) })
        applyProfilePosition()
        guard fresh, !preview else { return }
        for view in [profileAura, profilePill, profileDots] as [NSView] {
            view.alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            for view in [profileAura, profilePill, profileDots] as [NSView] {
                view.animator().alphaValue = 1
            }
        }
    }

    /// Sideways scrolling anywhere over the palette moves between profiles; up and down still scrolls the results.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, profileSwipe.count > 1, !acting else { return event }
        let time = event.timestamp
        if !event.momentumPhase.isEmpty {
            guard profileSwipe.swallowsMomentum else { return event }
            if !event.momentumPhase.isDisjoint(with: [.ended, .cancelled]) { profileSwipe.momentumEnded() }
            return nil
        }
        let dx = Double(event.scrollingDeltaX)
        let dy = Double(event.scrollingDeltaY)
        // A mouse wheel turned sideways, or a device without gestures, moves one profile per turn.
        if event.phase.isEmpty {
            guard profileSwipe.step(dx: dx, dy: dy, time: time) else { return event }
            startProfileTimer()
            requestProfile(profileSwipe.target, after: 0.35)
            return nil
        }
        if !event.phase.isDisjoint(with: [.mayBegin, .began]) {
            // Fingers on the trackpad catch a moving swipe and hold off a switch until they lift.
            stopProfileTimer()
            profileSwitch?.cancel()
            profileSwitch = nil
            profileSwipe.touch()
        }
        if !event.phase.isDisjoint(with: [.ended, .cancelled]) {
            let swiped = profileSwipe.release(time: time)
            startProfileTimer()
            requestProfile(profileSwipe.target, after: 0.12)
            return swiped ? nil : event
        }
        guard profileSwipe.scroll(dx: dx, dy: dy, time: time) else { return event }
        applyProfilePosition()
        return nil
    }

    /// Goes to a profile picked by a click on the pill or a dot.
    private func moveProfile(to index: Int) {
        guard profileSwipe.count > 1, !acting else { return }
        profileSwipe.move(to: index)
        startProfileTimer()
        requestProfile(profileSwipe.target, after: 0.12)
    }

    private func startProfileTimer() {
        guard profileTimer == nil, !profileSwipe.isSettled else { return applyProfilePosition() }
        var last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let now = CACurrentMediaTime()
            let moving = self.profileSwipe.advance(by: now - last)
            last = now
            self.applyProfilePosition()
            if !moving { self.stopProfileTimer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        profileTimer = timer
    }

    private func stopProfileTimer() {
        profileTimer?.invalidate()
        profileTimer = nil
    }

    /// Draws the profile's colors, pill and dots at the swipe's position, or at `position` for a preview. The results
    /// stay still, so nothing moves where the eye is reading.
    private func applyProfilePosition(_ position: Double? = nil) {
        let position = position ?? profileSwipe.position
        profileAura.position = position
        profilePill.position = position
        profileDots.position = position
    }

    /// Switches Chrome to the profile the swipe settles on, once it is clear the swipe will not go on.
    private func requestProfile(_ index: Int, after delay: TimeInterval) {
        profileSwitch?.cancel()
        profileSwitch = nil
        guard index != chromeProfile else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.profileSwitch = nil
            self?.switchProfile(to: index)
        }
        profileSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Has Chrome bring the profile's window forward, or open one, while the palette stays open over it.
    private func switchProfile(to index: Int) {
        guard let state = profileState, state.profiles.indices.contains(index), index != chromeProfile else { return }
        let profile = state.profiles[index]
        chromeProfile = index
        if preview { footer.stringValue = "Preview only"; return }
        freezeList()
        profileSwitching = true
        keepPanelUntil = Date().addingTimeInterval(3)
        // The leaving profile's tabs dim until the new profile's replace them.
        let leaving = activeTab?.browser == .chrome ? activeTab?.windowID : nil
        awaitingProfileTabs = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            results.animator().alphaValue = 0.45
        }
        let started = DispatchTime.now()
        chromeProfiles.switchTo(profile) { [weak self] result in
            guard let self else { return }
            Timing.log("profile switch", since: started)
            self.profileSwitching = false
            guard self.panel.isVisible else { return }
            switch result {
            case .success:
                self.keepPanelUntil = Date().addingTimeInterval(1.5)
                self.followSwitch(from: leaving)
                // Read again for the next palette, which then needs no read to show this profile.
                self.stores[.chrome]?.prewarm()
            case .failure(let error):
                self.keepPanelUntil = nil
                self.restoreResults()
                self.footer.stringValue = "Could not switch to \(profile.name)"
                self.footer.toolTip = error.localizedDescription
                // Back to the profile Chrome is in.
                self.loadProfiles()
            }
        }
    }

    /// Asks Chrome for the tab on screen until the profile's window is in front, or Chrome has opened one, then lists
    /// that profile's tabs.
    private func followSwitch(from window: Int?, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.15 : 0.25)) { [weak self] in
            guard let self, self.panel.isVisible, self.listFrozen else { return }
            self.bridge(.chrome).active { [weak self] result in
                guard let self, self.panel.isVisible else { return }
                if case .success(let tab?) = result, tab.windowID != window {
                    self.observeFocus(tab)
                    return self.followFrontTab(tab)
                }
                if attempt < 8 { self.followSwitch(from: window, attempt: attempt + 1) } else { self.restoreResults() }
            }
        }
    }

    /// Stops the listed tabs from changing until the palette closes. A read already under way would reorder them
    /// when it arrives, so it is let go.
    private func freezeList() {
        guard !listFrozen else { return }
        listFrozen = true
        requestID += 1
        waiting = []
        loading = false
        pendingActivation = nil
        retryButton.isEnabled = true
    }

    /// After a profile switch, follows the tab on screen: the tabs listed become its profile's, and new tabs and
    /// searches go to its window.
    private func followFrontTab(_ tab: BrowserTab) {
        guard listFrozen, panel.isVisible, tab.browser == lastBrowser, tab != activeTab else { return }
        activeOverride = tab
        rescope(fade: true)
    }

    /// Lists the tabs again from those already read, for a new tab on screen or newly told-apart windows. The list
    /// changes only when the tabs listed or the one on screen do; after a switch it fades from one profile to the next.
    private func rescope(fade: Bool) {
        defer { if fade { restoreResults() } }
        guard ready, panel.isVisible, !snapshots.isEmpty else { return }
        let combined = CombinedTabs(snapshots, front: lastBrowser)
        let active = activeOverride ?? combined.active
        guard profileTabs(combined.tabs, active: active) != tabs || active != activeTab else { return }
        if fade {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            results.layer?.add(transition, forKey: "profile")
        }
        show(combined, newContext: fade)
    }

    /// Shows the list at full strength again once a switched-to profile's tabs are listed, or the switch gave up,
    /// and runs an Enter pressed meanwhile.
    private func restoreResults() {
        awaitingProfileTabs = false
        if results.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                results.animator().alphaValue = 1
            }
        }
        guard let forceNew = pendingActivation, panel.isVisible else { return }
        pendingActivation = nil
        activate(forceNew: forceNew)
    }

    /// Over Chrome with several profiles, only the profile in front: its windows' tabs and no Safari tabs, so every
    /// pick stays in that profile. A profile's windows are those its copy of Tab Scout's extension sees; without the
    /// extension, every Chrome tab is listed.
    private func profileTabs(_ all: [BrowserTab], active: BrowserTab?) -> [BrowserTab] {
        profilesUnseparated = false
        guard lastBrowser == .chrome, chromeProfileCount > 1 else { return all }
        let chrome = all.filter { $0.browser == .chrome }
        guard let front = active?.browser == .chrome ? active?.windowID : chrome.first?.windowID else { return chrome }
        guard let windows = ProfileWindows.current(front: front, windows: chrome.map(\.windowID), owners: windowOwners) else {
            profilesUnseparated = true
            return chrome
        }
        return chrome.filter { windows.contains($0.windowID) }
    }

    /// Asks the profiles' extensions which of them sees each Chrome window not yet known, then lists the tabs again
    /// if that changes which belong to the profile in front. Answers are dropped when extensions connect or leave.
    private func learnWindowOwners(_ windows: Set<Int>) {
        guard !preview else { return }
        let connections = chromeLink.connectionIDs
        if connections != ownerConnections {
            windowOwners = [:]
            ownerConnections = connections
        }
        // Closed windows never come back; their ids are not reused.
        windowOwners = windowOwners.filter { windows.contains($0.key) }
        let unknown = windows.filter { windowOwners[$0] == nil }
        guard !connections.isEmpty, !unknown.isEmpty, !learningOwners else { return }
        learningOwners = true
        chromeLink.owners(of: Array(unknown)) { [weak self] found in
            guard let self else { return }
            self.learningOwners = false
            guard self.chromeLink.connectionIDs == self.ownerConnections else { return }
            self.windowOwners.merge(found) { $1 }
            self.rescope(fade: false)
        }
    }

    /// The browser's front window: the one holding the tab on screen, else the first listed, since windows are
    /// listed front to back.
    private func frontWindow(of browser: Browser) -> Int? {
        activeTab?.browser == browser ? activeTab?.windowID : tabs.first { $0.browser == browser }?.windowID
    }

    /// Lists the typed text as a new tab first while Shift is held.
    private func holdShift(_ held: Bool) {
        guard held != newTabFirst else { return }
        newTabFirst = held
        if ready { updateRows(preserveSelection: true) }
    }

    @objc private func activateSelection(_ sender: Any?) {
        // Ignore keyboard actions and heading clicks that leave an earlier row selected.
        let keyboard = NSApp.currentEvent?.type == .keyDown || NSApp.currentEvent?.type == .keyUp
        guard ResultActivation.allowsClick(in: rows, clickedRow: table.clickedRow, selectedRow: table.selectedRow, keyboardEvent: keyboard) else { return }
        activate(forceNew: false)
    }

    private func activate(forceNew: Bool) {
        guard !acting else { return }
        // Enter pressed while the tab list is still loading runs once every browser's tabs have arrived, and once a
        // switched-to profile's tabs are listed.
        guard ready, !awaitingTabs, !awaitingProfileTabs else { if loading || awaitingProfileTabs { pendingActivation = forceNew }; return }
        let typed = searchField.stringValue
        // Enter and Cmd+Enter both run the selected command; the "`" text never opens as a page.
        if PaletteCommand.query(in: typed) != nil {
            if rows.indices.contains(table.selectedRow), case .command(let command) = rows[table.selectedRow] { run(command) }
            return
        }
        let offeredTabs = rows.contains { if case .tab = $0 { return true }; return false }
        let shownTabs = rows.compactMap { row -> BrowserTab? in
            switch row { case .previousTab(let tab), .tab(let tab): return tab; default: return nil }
        }
        let shown = shownTabs.map { shownFeatures[$0] ?? RankingFeatures() }
        let row: SearchRow
        if forceNew { row = .newTab(NewTabDestination.from(AssistantPrompt.question(in: typed) ?? typed)) }
        else {
            guard rows.indices.contains(table.selectedRow) else { return }
            row = rows[table.selectedRow]
        }
        guard row.isSelectable else { return }
        if preview { footer.stringValue = "Preview only"; return }
        // A tab is switched to in its own browser; anything new opens in the browser last in front.
        let target: Browser = switch row {
        case .previousTab(let tab), .tab(let tab): tab.browser
        default: lastBrowser
        }
        acting = true
        searchField.isEnabled = false
        retryButton.isEnabled = false
        footer.stringValue = "Opening..."
        // Hide at once and let the browser finish in the background; a failure brings the palette back.
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
                switch row {
                case .previousTab(let tab), .tab(let tab):
                    if let chosen = shownTabs.firstIndex(of: tab) { self.learnRanking(typed: typed, shown: shown, chosen: chosen) }
                default: break
                }
                // Keep the tab list warm so an immediate Cmd+T needs no browser read.
                switch row {
                case .previousTab(let tab), .tab(let tab):
                    self.observeFocus(tab)
                    self.stores[target]?.noteActivation(tab)
                default: self.stores[target]?.noteActivation(nil)
                }
                self.dismiss(restoreFocus: false)
                self.stores[target]?.prewarm()
            case .failure(let error):
                self.emptyLabel.stringValue = ""
                self.footer.stringValue = self.describe(error, target)
                self.footer.toolTip = self.footer.stringValue
                self.panel.makeKeyAndOrderFront(nil)
                self.panel.makeFirstResponder(self.searchField)
                if case BridgeError.staleTab = error {
                    self.listFrozen = false
                    self.activeOverride = nil
                    self.loadTabs(force: true)
                }
            }
        }
        switch row {
        case .previousTab(let tab), .tab(let tab): bridge(target).select(tab, completion: completion)
        default:
            if let destination = row.destination {
                // Tabs are listed front window first, so this is the browser's front window.
                bridge(target).open(destination, windowID: frontWindow(of: target) ?? 0,
                                    reusing: blankActiveTab, completion: completion)
            }
        }
    }

    private func run(_ command: PaletteCommand) {
        if preview { footer.stringValue = "Preview only"; return }
        switch command {
        case .group: groupTabs()
        }
    }

    /// Sorts the front Chrome window's loose tabs into named groups: Apple Intelligence picks the topics on this Mac,
    /// and Tab Scout's extension makes the groups, since Chrome lets only extensions do that.
    private func groupTabs() {
        // Tabs are listed front window first.
        guard let windowID = frontWindow(of: .chrome) else {
            footer.stringValue = "Open a Chrome window to group its tabs"
            return
        }
        acting = true
        searchField.isEnabled = false
        retryButton.isEnabled = false
        footer.stringValue = "Grouping tabs..."
        // Hidden at once like any action; grouping takes a few seconds, and a failure brings the palette back.
        panel.orderOut(nil)
        let started = DispatchTime.now()
        let finish: (Result<Int, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            Timing.log("group", since: started)
            self.acting = false
            self.searchField.isEnabled = true
            self.retryButton.isEnabled = true
            let reopen = { (message: String) in
                self.emptyLabel.stringValue = ""
                self.footer.stringValue = message
                self.footer.toolTip = message
                self.panel.makeKeyAndOrderFront(nil)
                self.panel.makeFirstResponder(self.searchField)
            }
            switch result {
            case .success(let made) where made > 0:
                // Grouping moves tabs, so the listed positions are out of date.
                self.stores[.chrome]?.invalidate()
                self.dismiss(restoreFocus: false)
                self.stores[.chrome]?.prewarm()
            case .success: reopen("No tabs in this window belong together")
            case .failure(ChromeExtensionLink.LinkError.notConnected), .failure(ChromeExtensionLink.LinkError.windowNotFound):
                // Chrome is open, so with no profile connected the extension is gone; the setup window offers it again.
                if self.chromeLink.connectedProfiles == 0 { self.chromeExtensionAdded = false }
                self.dismiss(restoreFocus: false)
                self.showSetup(nil)
            case .failure(let error): reopen(error.localizedDescription)
            }
        }
        chromeLink.tabs(inWindow: windowID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): finish(.failure(error))
            case .success(let window):
                self.grouper.plan(window.tabs) { groups in
                    guard !groups.isEmpty else { return finish(.success(0)) }
                    self.chromeLink.group(groups, in: window, completion: finish)
                }
            }
        }
    }

    /// The tab on screen when it is empty, such as the Start Page; pages chosen in the palette open there.
    private var blankActiveTab: BrowserTab? {
        activeTab.flatMap { $0.isBlank && $0.browser == lastBrowser ? $0 : nil }
    }

    /// Logs which of the listed tabs was picked and, every few picks, relearns the ranking weights in the
    /// background. Learned weights are adopted only when they rank recent picks at least as well as the standard ones.
    private func learnRanking(typed: String, shown: [RankingFeatures], chosen: Int) {
        let query = AssistantPrompt.question(in: typed) ?? typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let impression = RankingImpression(typed: !query.isEmpty, shown: shown, chosen: chosen) else { return }
        learning.update { $0.ranking.record(impression) }
        updateRankingItem()
        guard learning.state.ranking.needsTraining, !training else { return }
        training = true
        let log = learning.state.ranking
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let started = DispatchTime.now()
            let weights = RankTrainer.improve(log)
            DispatchQueue.main.async {
                guard let self else { return }
                Timing.log("ranking training", since: started)
                self.training = false
                self.learning.update { $0.ranking.adopt(weights) }
                self.updateRankingItem()
            }
        }
    }

    private func updateRankingItem() {
        let log = learning.state.ranking
        let quality = RankTrainer.evaluate(log.impressions, weights: log.weights)
        guard quality.picks > 0 else { rankingItem?.title = "Ranking learns from your picks"; return }
        rankingItem?.title = String(format: "Ranking: your pick was first in %.0f%% of %d", quality.firstChoice * 100, quality.picks)
            + (log.isPersonalized ? ", personalized" : "")
    }

    private func rememberChoice(_ row: SearchRow, typed: String, offeredTabs: Bool) {
        let target: String? = switch row {
        case .previousTab(let tab), .tab(let tab): HistoryIdentity.url(tab.url)
        case .history(let visit): HistoryIdentity.url(visit.url)
        // Searching the typed text while tabs were offered teaches Enter to do that next time.
        case .newTab(.search), .newTab(.url): offeredTabs ? QueryAffinity.newTab : nil
        default: nil
        }
        // A "?" request is remembered without the "?", so the same words typed later lead to the same page.
        let input = AssistantPrompt.question(in: typed) ?? typed
        if let target { learning.update { $0.affinity.record(input: input, target: target, at: Date()) } }
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
        newTabFirst = false
        // A profile swiped to just before closing is still switched to.
        if let pending = profileSwitch {
            pending.cancel()
            profileSwitch = nil
            switchProfile(to: profileSwipe.target)
        }
        keepPanelUntil = nil
        listFrozen = false
        activeOverride = nil
        awaitingProfileTabs = false
        results.alphaValue = 1
        showProfiles(nil)
        if !preview { googleSuggestions.cancel() }
        remoteSuggestions = []
        resetAssistant()
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
        shownFeatures = [:]
        similarWords = [:]
        mentions = [:]
        rows = []
        searchIndex = TabSearchIndex([])
        openTabs = OpenTabLookup([])
        snapshots = [:]
        windowNumbers = [:]
        ready = false
        table?.reloadData()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Shift may have been let go while the palette was hidden, such as after Shift+Enter failed.
        guard notification.object as? NSWindow === panel else { return }
        holdShift(ResultKeyboard.holdsShiftAlone(NSEvent.modifierFlags))
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, panel.isVisible else { return }
        // Chrome takes keyboard focus as it raises a profile's window; the palette stays and takes it back.
        if let until = keepPanelUntil, Date() < until {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
                self.panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        guard !loading, !acting else { return }
        dismiss(restoreFocus: false)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the setup window gives up on adding the Chrome extension.
        guard notification.object as? NSWindow === setupWindow else { return }
        chromeProfilesBeforeAdding = nil
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
        if !enable { favicons.useLocalIcons([:]) }
        reimportHistory()
    }

    @objc private func toggleHistoryProfile(_ sender: NSMenuItem) {
        guard !preview, let id = sender.representedObject as? String else { return }
        var excluded = Self.excludedProfiles
        if excluded.remove(id) == nil { excluded.insert(id) }
        UserDefaults.standard.set(excluded.sorted(), forKey: "ExcludedHistoryProfiles")
        historyStore.discardImported()
        reimportHistory()
    }

    /// Removes imported results immediately, so a denied or superseded read cannot leave them visible, and reads
    /// history again.
    private func reimportHistory() {
        historyIndex = HistorySearchIndex(.empty)
        indexedHistory = nil
        historyLoaded = false
        historyError = nil
        if ready && panel.isVisible { updateRows(preserveSelection: true) }
        updateSetup()
        reloadHistory()
    }

    /// Runs after each import of other browser profiles, before the history it read is indexed.
    private func didImport(_ found: BrowserImport) {
        // History turned off while it was being read.
        guard safariHistoryEnabled else { return }
        historyProfiles = found.profiles
        unreadableProfiles = found.failed
        if favicons.useLocalIcons(found.icons), ready, panel.isVisible, table.numberOfRows > 0 {
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: 0))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard safariHistoryEnabled else {
            menu.addItem(withTitle: "Turn on Use Browser History first", action: nil, keyEquivalent: "")
            return
        }
        guard !historyProfiles.isEmpty else {
            menu.addItem(withTitle: historyLoaded ? "No browser profiles found" : "Looking for profiles...", action: nil, keyEquivalent: "")
            return
        }
        let excluded = Self.excludedProfiles
        for profile in historyProfiles {
            let unreadable = unreadableProfiles.contains(profile.id) || (profile.id == HistoryProfile.safariID && historyError != nil)
            let item = menu.addItem(withTitle: profile.name + (unreadable ? " (unavailable)" : ""),
                                    action: #selector(toggleHistoryProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = excluded.contains(profile.id) ? .off : .on
        }
    }

    @objc private func togglePageText(_ sender: Any?) {
        guard !preview else { return }
        let enable = !pageTextEnabled
        if enable {
            let alert = NSAlert()
            alert.messageText = "Search Page Text?"
            alert.informativeText = "Tab Scout will read the visible text of Safari and Chrome pages after you have looked at them for a few seconds, so typing finds tabs that mention your words. The text stays in memory on this Mac: it is never saved or sent, and is dropped when a tab closes or this option is turned off. Pages you have not viewed are not read. Chrome pages are read only once View > Developer > Allow JavaScript from Apple Events is on in Chrome."
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        UserDefaults.standard.set(enable, forKey: "PageTextEnabled")
        pageTextItems.forEach { $0.state = enable ? .on : .off }
        if enable {
            pageTextUnavailable = []
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
        updateRankingItem()
        googleSuggestions.clearCache()
        remoteSuggestions = []
        reloadHistory()
    }

    @objc private func toggleLogin(_ sender: Any?) {
        guard !preview else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change login settings"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginBox?.state = loginItem.state
    }

    @objc private func showSetup(_ sender: Any?) {
        guard !preview else { footer.stringValue = "Preview only"; return }
        if panel?.isVisible == true { dismiss(restoreFocus: false) }
        if setupWindow == nil { buildSetup() }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.center()
        setupWindow?.makeKeyAndOrderFront(nil)
        loginBox?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateSetup()
    }

    /// One window walks through everything Tab Scout needs; each step ticks itself off once it is done, also when
    /// that happens in System Settings or Chrome.
    private func buildSetup() {
        let height: CGFloat = 540
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tab Scout"
        window.isReleasedWhenClosed = false
        window.delegate = self
        setupWindow = window
        guard let content = window.contentView else { return }
        let heading = NSTextField(labelWithString: "Set Up Tab Scout")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.frame = NSRect(x: 28, y: height - 55, width: 220, height: 28)
        content.addSubview(heading)
        let version = NSTextField(labelWithString: versionText)
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        version.alignment = .right
        version.lineBreakMode = .byTruncatingMiddle
        version.isSelectable = true
        version.frame = NSRect(x: 252, y: height - 49, width: 200, height: 16)
        content.addSubview(version)
        for (index, step) in SetupStep.allCases.enumerated() {
            let top = height - 84 - CGFloat(index) * 70
            let icon = NSImageView(frame: NSRect(x: 28, y: top - 20, width: 18, height: 18))
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            content.addSubview(icon)
            let title = NSTextField(labelWithString: setupTitle(step))
            title.font = .systemFont(ofSize: 15, weight: .medium)
            title.frame = NSRect(x: 56, y: top - 22, width: 256, height: 22)
            content.addSubview(title)
            let detail = NSTextField(wrappingLabelWithString: "")
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.frame = NSRect(x: 56, y: top - 56, width: 256, height: 32)
            content.addSubview(detail)
            let button = NSButton(title: setupAction(step), target: self, action: #selector(runSetupStep(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 322, y: top - 44, width: 132, height: 32)
            content.addSubview(button)
            setupRows[step] = SetupRow(icon: icon, detail: detail, button: button)
        }
        let line = NSBox(frame: NSRect(x: 28, y: 96, width: 424, height: 1))
        line.boxType = .separator
        content.addSubview(line)
        let login = NSButton(checkboxWithTitle: "Start Tab Scout at login", target: self, action: #selector(toggleLogin(_:)))
        login.frame = NSRect(x: 26, y: 58, width: 280, height: 20)
        content.addSubview(login)
        loginBox = login
        setupStatus = NSTextField(labelWithString: "")
        setupStatus?.font = .systemFont(ofSize: 12)
        setupStatus?.textColor = .secondaryLabelColor
        setupStatus?.frame = NSRect(x: 28, y: 28, width: 280, height: 20)
        content.addSubview(setupStatus!)
        let search = NSButton(title: "Open Search", target: self, action: #selector(showSearch(_:)))
        search.image = symbol("magnifyingglass")
        search.imagePosition = .imageLeading
        search.bezelStyle = .rounded
        search.frame = NSRect(x: 322, y: 34, width: 132, height: 32)
        content.addSubview(search)
    }

    private func setupTitle(_ step: SetupStep) -> String {
        switch step {
        case .keyboard: return controlPermissionName
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .chromeExtension: return "Chrome Tab Groups (Optional)"
        case .history: return "Browser History (Optional)"
        }
    }

    private func setupAction(_ step: SetupStep) -> String {
        switch step {
        case .keyboard: return "Open Settings"
        case .safari, .chrome: return "Allow Access"
        case .chromeExtension: return chromeExtensionAdded ? "Add to Profile" : "Add to Chrome"
        case .history: return safariHistoryEnabled ? "Open Settings" : "Turn On"
        }
    }

    @objc private func runSetupStep(_ sender: NSButton) {
        guard SetupStep.allCases.indices.contains(sender.tag) else { return }
        switch SetupStep.allCases[sender.tag] {
        case .keyboard: openAccessibility()
        case .safari: requestAccess(.safari, from: sender)
        case .chrome: requestAccess(.chrome, from: sender)
        case .chromeExtension: addChromeExtension()
        case .history: if safariHistoryEnabled { openHistorySettings() } else { toggleSafariHistory(nil) }
        }
    }

    /// Runs every two seconds. Notes when Tab Scout's Chrome extension connects even while the window is closed,
    /// because an extension that connected once counts as added while Chrome is closed.
    private func updateSetup() {
        guard !preview else { return }
        let connected = chromeLink.connectedProfiles
        if connected > 0 { chromeExtensionAdded = true }
        if let before = chromeProfilesBeforeAdding, connected > before {
            // Back from Chrome to show the step done.
            chromeProfilesBeforeAdding = nil
            NSApp.activate(ignoringOtherApps: true)
            setupWindow?.makeKeyAndOrderFront(nil)
        }
        guard setupWindow?.isVisible == true else { return }
        // Checking trust registers the executable with macOS. Preview builds must not do that.
        let trusted = AXIsProcessTrusted()
        showStep(.keyboard, !trusted ? .needed : eventTap == nil ? .problem : .done,
                 !trusted ? "Required for Cmd+T in Safari and Chrome" : eventTap == nil ? "Access granted; shortcut unavailable" : "Allowed")
        for browser in Browser.allCases {
            // Access is otherwise known only once Tab Scout has read the browser, but macOS can tell without asking.
            if !allowedBrowsers.contains(browser) && !deniedBrowsers.contains(browser) && isRunning(browser) {
                switch automationAllowed(browser) {
                case true?: allowedBrowsers.insert(browser); stores[browser]?.prewarm()
                case false?: deniedBrowsers.insert(browser)
                case nil: break
                }
            }
            let (state, text) = accessState(browser)
            showStep(SetupStep(browser), state, text)
        }
        let chromeInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Browser.chrome.bundleID) != nil
        setupRows[.chromeExtension]?.button.isEnabled = chromeInstalled
        setupRows[.chromeExtension]?.button.title = setupAction(.chromeExtension)
        setupRows[.chromeExtension]?.detail.toolTip = chromeProfilesBeforeAdding == nil ? nil
            : "On Chrome's Extensions page, turn on Developer mode at the top right, then drag the ChromeExtension folder shown in Finder onto the page, or click Load unpacked and choose it. This step ticks itself off when the extension connects."
        let profiles = connected > 0 ? " to \(connected) Chrome profile\(connected == 1 ? "" : "s")" : ""
        if !chromeInstalled {
            showStep(.chromeExtension, .unavailable, "Needs Google Chrome")
        } else if chromeProfilesBeforeAdding != nil && chromeExtensionAdded {
            showStep(.chromeExtension, .done, "Added\(profiles); drag the folder into another profile's Extensions page")
        } else if chromeProfilesBeforeAdding != nil {
            showStep(.chromeExtension, .waiting, "In Chrome, turn on Developer mode and drag the folder from Finder onto the page")
        } else if chromeExtensionAdded {
            showStep(.chromeExtension, .done, "Added\(profiles); type `group in the palette")
        } else {
            showStep(.chromeExtension, .optional, "Lets `group sort a Chrome window's tabs into groups")
        }
        let included = historyProfiles.filter { !Self.excludedProfiles.contains($0.id) }.count
        showStep(.history, !safariHistoryEnabled ? .optional : !historyLoaded ? .waiting : historyError != nil ? .problem : .done,
                 !safariHistoryEnabled ? "Off; ranks tabs with Safari and Chrome history" : !historyLoaded ? "Checking..."
                 : historyError != nil ? "Unavailable; local choices still work"
                 : historyProfiles.count > 1 ? "Allowed; \(included) of \(historyProfiles.count) profiles used" : "Allowed")
        setupRows[.history]?.detail.toolTip = historyError?.localizedDescription
        setupRows[.history]?.button.title = setupAction(.history)
        setupStatus?.stringValue = trusted && !allowedBrowsers.isEmpty && eventTap != nil ? "Ready: press Cmd+T in Safari or Chrome" : "Permissions needed"
    }

    private func showStep(_ step: SetupStep, _ state: SetupState, _ text: String) {
        guard let row = setupRows[step] else { return }
        row.icon.image = symbol(state.symbol)
        row.icon.contentTintColor = state.color
        row.detail.stringValue = text
    }

    private func accessState(_ browser: Browser) -> (SetupState, String) {
        if allowedBrowsers.contains(browser) { return (.done, "Allowed") }
        if requestingAccess.contains(browser) { return (.waiting, "Requesting access...") }
        if deniedBrowsers.contains(browser) { return (.problem, "Not allowed; check Automation settings") }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) == nil { return (.unavailable, "Not installed") }
        return (.needed, "Needed for \(browser.name) tabs")
    }

    /// Whether macOS lets Tab Scout script a running browser, asked without prompting; nil when the user has not
    /// been asked yet or the browser is not running.
    private func automationAllowed(_ browser: Browser) -> Bool? {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleID).aeDesc else { return nil }
        switch AEDeterminePermissionToAutomateTarget(target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) {
        case noErr: return true
        case OSStatus(errAEEventNotPermitted): return false
        default: return nil
        }
    }

    private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    private func openHistorySettings() {
        let alert = NSAlert()
        alert.messageText = "Browser History Access"
        alert.informativeText = "macOS protects Safari and Chrome history with Full Disk Access, a broad permission. Tab Scout reads the history of every Safari and Chrome profile locally, never sends it to Google, and can leave out any profile under History Profiles. Add this Tab Scout.app under Privacy & Security > Full Disk Access, then restart Tab Scout. Tab search and local choices work without this permission."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    /// Chrome lets only extensions make tab groups, so grouping needs Tab Scout's own, added once to each profile.
    /// Chrome adds extensions only from its store or by hand, so this opens Chrome's Extensions page and shows the
    /// extension's folder in Finder to drag there. The step ticks itself off when the extension connects.
    private func addChromeExtension() {
        let alert = NSAlert()
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "TabScoutChromeHost"),
              let folder = Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) else {
            alert.messageText = "Chrome grouping is missing from this copy of Tab Scout"
            alert.informativeText = "Rebuild the app using build.sh."
            alert.runModal()
            return
        }
        do {
            // Chrome starts the helper for the extension only once this tells it where the helper is.
            try ChromeHostManifest.install(helper: helper)
        } catch {
            alert.messageText = "Tab Scout could not set up Chrome grouping"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        chromeProfilesBeforeAdding = chromeLink.connectedProfiles
        updateSetup()
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        bridge(.chrome).open(.url("chrome://extensions/"), windowID: tabs.first { $0.browser == .chrome }?.windowID ?? 0) { _ in }
    }

    /// Opens the browser and reads its tabs, which makes macOS ask for Automation access the first time.
    private func requestAccess(_ browser: Browser, from button: NSButton) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else { return updateSetup() }
        button.isEnabled = false
        requestingAccess.insert(browser)
        updateSetup()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil else {
                    button.isEnabled = true
                    self.requestingAccess.remove(browser)
                    self.updateSetup()
                    self.setupStatus?.stringValue = "Could not open \(browser.name)"
                    return
                }
                self.bridge(browser).list { [weak self] result in
                    guard let self else { return }
                    button.isEnabled = true
                    self.requestingAccess.remove(browser)
                    switch result {
                    case .success:
                        self.allowedBrowsers.insert(browser)
                        self.deniedBrowsers.remove(browser)
                        self.stores[browser]?.prewarm()
                        self.updateSetup()
                    case .failure(let error):
                        if case BridgeError.permission = error { self.deniedBrowsers.insert(browser) }
                        self.updateSetup()
                        self.setupStatus?.stringValue = "Check Automation settings"
                        self.setupStatus?.toolTip = self.describe(error, browser)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    self.setupWindow?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

/// The steps of the setup window, in order. Cmd+T needs the keyboard step and at least one browser.
private enum SetupStep: CaseIterable {
    case keyboard, safari, chrome, chromeExtension, history

    init(_ browser: Browser) {
        switch browser {
        case .safari: self = .safari
        case .chrome: self = .chrome
        }
    }
}

/// How far a setup step is, shown by the icon before its name.
private enum SetupState {
    case done, needed, optional, waiting, problem, unavailable

    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .needed: return "circle"
        case .optional: return "circle.dashed"
        case .waiting: return "clock"
        case .problem: return "exclamationmark.circle.fill"
        case .unavailable: return "minus.circle"
        }
    }

    var color: NSColor {
        switch self {
        case .done: return .systemGreen
        case .needed, .waiting: return .controlAccentColor
        case .optional, .unavailable: return .tertiaryLabelColor
        case .problem: return .systemOrange
        }
    }
}

private struct SetupRow {
    let icon: NSImageView
    let detail: NSTextField
    let button: NSButton
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
