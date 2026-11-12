import AppKit
import ApplicationServices
import os

/// Zen's spaces as places in the palette. Zen shows an extension only the tabs of the space in front and tells it
/// nothing about spaces, so their names, colors and order are read from the session file Zen keeps in its profile
/// folder, which needs Full Disk Access as browser history does. Switching presses the space's item in Zen's Spaces
/// menu through the accessibility permission Cmd+T needs, so Zen does what its own menu does.
final class ZenSpaces {
    enum SwitchError: LocalizedError {
        case notRunning
        case unavailable

        var errorDescription: String? {
            switch self {
            case .notRunning: return "Zen is not running"
            case .unavailable: return "Zen did not switch spaces; check the Device Control permission"
            }
        }
    }

    private static let logger = Logger(subsystem: "local.tabscout.app", category: "spaces")
    private let queue = DispatchQueue(label: "local.tabscout.spaces", qos: .userInitiated)
    private let folder: URL
    // Owned by `queue`.
    private var cached: (file: URL, modified: Date, session: ZenSession)?
    /// The spaces as last read and the one in front then, which a switch starts from.
    private var last: (session: ZenSession, current: String?)?
    private var menuIndex: (process: pid_t, index: Int)?

    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/zen")) {
        self.folder = folder
    }

    /// Zen's spaces and the one in front, given the addresses of the tabs Zen lists in its front window. Nil when
    /// Zen has one space, or its session cannot be read: Zen is then a single place.
    func read(showing addresses: [String], completion: @escaping (ProfileState?) -> Void) {
        queue.async { [self] in
            let started = DispatchTime.now()
            let state = currentState(showing: addresses)
            Timing.log("spaces", since: started)
            DispatchQueue.main.async { completion(state) }
        }
    }

    /// Has Zen go to the space `place` stands for, as choosing it in Zen's Spaces menu does.
    func switchTo(_ place: BrowserProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let finish = { (result: Result<Void, Error>) in DispatchQueue.main.async { completion(result) } }
            guard let zen = NSRunningApplication.runningApplications(withBundleIdentifier: Browser.zen.bundleID).first else {
                return finish(.failure(SwitchError.notRunning))
            }
            guard let known = last ?? readSession().map({ ($0.session, $0.preferred) }),
                  let target = known.session.spaces.firstIndex(where: { "zen:" + $0.id == place.id }) else {
                return finish(.failure(SwitchError.unavailable))
            }
            let spaces = known.session.spaces
            let current = spaces.firstIndex { $0.id == known.current }
            // Already there, as when a page is sent to the space Zen is in.
            if current == target { return finish(.success(())) }
            let application = AXUIElementCreateApplication(zen.processIdentifier)
            // Zen animates to the space before it answers.
            AXUIElementSetMessagingTimeout(application, 1)
            guard let menu = spacesMenu(of: application, process: zen.processIdentifier, spaces: spaces.count),
                  let plan = ZenSpacesMenu.presses(to: target, from: current, spaces: spaces, titles: menu.titles, layout: menu.layout) else {
                Self.logger.notice("no way to space \(target, privacy: .public) of \(spaces.count, privacy: .public) from \(current ?? -1, privacy: .public)")
                return finish(.failure(SwitchError.unavailable))
            }
            var pressed = AXError.success
            for press in 0..<plan.times {
                // Zen takes each step from the space it is in by then, which it has settled on a moment after the last.
                if press > 0 { Thread.sleep(forTimeInterval: 0.15) }
                pressed = AXUIElementPerformAction(menu.items[plan.item], kAXPressAction as CFString)
                // A press that ran out of time has usually still switched.
                guard pressed == .success || pressed == .cannotComplete else { break }
            }
            Self.logger.notice("to space \(target, privacy: .public) from \(current ?? -1, privacy: .public): item \(plan.item, privacy: .public) of \(menu.titles.count, privacy: .public), \(plan.times, privacy: .public) presses, result \(pressed.rawValue, privacy: .public)")
            guard pressed == .success || pressed == .cannotComplete else { return finish(.failure(SwitchError.unavailable)) }
            last = (known.session, spaces[target].id)
            finish(.success(()))
        }
    }

    /// Notes in the log how Zen's Spaces menu is laid out, as counts and shapes only, so a switch that fails can
    /// be traced to a menu Tab Scout could not read.
    func noteMenu() {
        queue.async { [self] in
            guard AXIsProcessTrusted(),
                  let zen = NSRunningApplication.runningApplications(withBundleIdentifier: Browser.zen.bundleID).first else { return }
            let application = AXUIElementCreateApplication(zen.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.5)
            let count = readSession()?.session.spaces.count ?? 0
            let found = spacesMenu(of: application, process: zen.processIdentifier, spaces: count)
            Self.logger.notice("Spaces menu \(found == nil ? "not found" : "found", privacy: .public) with \(found?.layout.spaces.count ?? 0, privacy: .public) spaces listed; the session has \(count, privacy: .public)")
        }
    }

    // MARK: - On `queue`

    private func currentState(showing addresses: [String]) -> ProfileState? {
        guard let read = readSession() else {
            last = nil
            return nil
        }
        let current = read.session.current(showing: addresses, preferred: read.preferred)
        last = (read.session, current)
        let state = read.session.places(current: current)
        Self.logger.notice("\(read.session.spaces.count, privacy: .public) spaces, current \(state?.current ?? -1, privacy: .public), Zen names \(read.preferred == nil ? "none" : "one", privacy: .public)")
        return state
    }

    /// The session of the Zen profile in use: the one whose session file changed last. Also the space its prefs.js
    /// names as last switched to. Nil without Full Disk Access, which hides Zen's folder, or before Zen saved one.
    private func readSession() -> (session: ZenSession, preferred: String?)? {
        let profiles = folder.appendingPathComponent("Profiles", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []).compactMap { name -> (URL, Date)? in
            let file = profiles.appendingPathComponent(name).appendingPathComponent("zen-sessions.jsonlz4")
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, (values.fileSize ?? 0) <= 64 << 20 else { return nil }
            return (file, modified)
        }
        guard let (file, modified) = files.max(by: { $0.1 < $1.1 }) else { return nil }
        let session: ZenSession
        if let cached, cached.file == file, cached.modified == modified {
            session = cached.session
        } else {
            guard let data = try? Data(contentsOf: file), let json = MozLz4.decode(data), let parsed = ZenSession(json: json) else { return nil }
            session = parsed
            cached = (file, modified, parsed)
        }
        let preferences = file.deletingLastPathComponent().appendingPathComponent("prefs.js")
        let preferred = (try? preferences.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { size -> String? in
            guard size <= 16 << 20, let text = try? String(contentsOf: preferences, encoding: .utf8) else { return nil }
            return ZenSession.preferredSpace(inPreferences: text)
        }
        return (session, preferred)
    }

    /// Zen's menu bar is Apple, Zen, File, Edit, View, Spaces, History and so on. The Spaces menu is known by how it
    /// is laid out rather than by its title, which follows Zen's language; its usual place is tried first.
    private func spacesMenu(of application: AXUIElement, process: pid_t, spaces: Int) -> (items: [AXUIElement], titles: [String], layout: ZenSpacesMenu.Layout)? {
        guard let bar = Self.value(application, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let menus = Self.children(bar as! AXUIElement) else { return nil }
        var candidates = [menuIndex?.process == process ? menuIndex?.index : nil].compactMap { $0 } + [5]
        candidates += Array(menus.indices.dropFirst(2))
        var tried: Set<Int> = []
        for index in candidates where menus.indices.contains(index) && tried.insert(index).inserted {
            guard let list = Self.children(menus[index])?.first, let items = Self.children(list) else { continue }
            let titles = items.map { Self.value($0, kAXTitleAttribute) as? String ?? "" }
            guard let layout = ZenSpacesMenu.layout(titles) else { continue }
            // Elsewhere than its usual place, the menu must also list as many spaces as Zen can have listed.
            guard index == 5 || index == menuIndex?.index || (spaces > 1 && layout.spaces.count == spaces - 1) else { continue }
            menuIndex = (process, index)
            return (items, titles, layout)
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement]? {
        value(element, kAXChildrenAttribute) as? [AXUIElement]
    }
}
