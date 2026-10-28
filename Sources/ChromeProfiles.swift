import AppKit
import ApplicationServices
import os

/// Chrome's profiles and the one its front window belongs to. Chrome's scripting cannot tell profiles apart, but its
/// Profiles menu lists them and checks the current one, and the accessibility permission Cmd+T needs can read it.
/// Local State, readable with Full Disk Access, adds the names and colors people chose. Switching presses the
/// profile's menu item, so Chrome does what its menu does: brings the profile's window forward, or opens one.
final class ChromeProfiles {
    enum SwitchError: LocalizedError {
        case notRunning
        case unavailable

        var errorDescription: String? {
            switch self {
            case .notRunning: return "Chrome is not running"
            case .unavailable: return "Chrome did not switch profiles; check the Device Control permission"
            }
        }
    }

    private typealias MenuEntry = (item: ProfileMenuItem, element: AXUIElement)
    private static let logger = Logger(subsystem: "local.tabscout.app", category: "profiles")
    private let queue = DispatchQueue(label: "local.tabscout.profiles", qos: .userInitiated)
    private let folder: URL
    // Owned by `queue`.
    private var localState: (modified: Date, profiles: [ChromeLocalProfile], lastUsed: String?)?
    private var menuIndex: (process: pid_t, index: Int)?

    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")) {
        self.folder = folder
    }

    /// Chrome's profiles, or nil while Chrome is not running or its menu cannot be read.
    func read(completion: @escaping (ProfileState?) -> Void) {
        queue.async { [self] in
            let started = DispatchTime.now()
            let state = currentState()
            Timing.log("profiles", since: started)
            DispatchQueue.main.async { completion(state) }
        }
    }

    func switchTo(_ profile: BrowserProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let finish = { (result: Result<Void, Error>) in DispatchQueue.main.async { completion(result) } }
            guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: Browser.chrome.bundleID).first else {
                return finish(.failure(SwitchError.notRunning))
            }
            let application = AXUIElementCreateApplication(chrome.processIdentifier)
            // Chrome raises the profile's window before it answers.
            AXUIElementSetMessagingTimeout(application, 1)
            if let title = profile.menuTitle,
               let entry = profilesMenu(of: application, process: chrome.processIdentifier, local: readLocalState().profiles)?
                .prefix(while: { !$0.item.title.isEmpty }).first(where: { $0.item.title == title }) {
                let pressed = AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
                Self.logger.notice("pressed profile \(profile.id, privacy: .private): \(pressed.rawValue, privacy: .public)")
                // A press that ran out of time has usually still switched; the palette reads the menu again after.
                if pressed == .success || pressed == .cannotComplete { return finish(.success(())) }
            }
            // Without the menu, Chrome started again for the profile's folder opens a window of that profile.
            guard let directory = profile.directory,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Browser.chrome.bundleID) else {
                return finish(.failure(SwitchError.unavailable))
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--profile-directory=\(directory)"]
            Self.logger.notice("opening profile \(profile.id, privacy: .private) from its folder")
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    // MARK: - On `queue`

    private func currentState() -> ProfileState? {
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: Browser.chrome.bundleID).first else { return nil }
        let local = readLocalState()
        let application = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        let menu = profilesMenu(of: application, process: chrome.processIdentifier, local: local.profiles)?.map(\.item)
        let state = ProfileMenu.state(menu: menu ?? [], local: local.profiles, lastUsed: local.lastUsed, folder: folder)
        Self.logger.notice("\(state.profiles.count, privacy: .public) profiles, current \(state.current ?? -1, privacy: .public), menu \(menu == nil ? "unreadable" : "read", privacy: .public), Local State \(local.profiles.isEmpty ? "unreadable" : "read", privacy: .public)")
        return state
    }

    /// Chrome's menu bar is Apple, Chrome, File, Edit, View, History, Bookmarks, Profiles, Tab, Window and Help.
    /// The Profiles menu is found by its title, or by its place when its items are profiles Local State knows.
    private func profilesMenu(of application: AXUIElement, process: pid_t, local: [ChromeLocalProfile]) -> [MenuEntry]? {
        guard let bar = Self.value(application, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let menus = Self.children(bar as! AXUIElement) else { return nil }
        let titles = menus.map { Self.value($0, kAXTitleAttribute) as? String ?? "" }
        var candidates = [menuIndex?.process == process ? menuIndex?.index : nil].compactMap { $0 }
        candidates += titles.indices.filter { ProfileMenu.titles.contains(titles[$0]) } + [7, 8]
        var tried: Set<Int> = []
        for index in candidates where menus.indices.contains(index) && tried.insert(index).inserted {
            guard let entries = items(of: menus[index]) else { continue }
            let profiles = ProfileMenu.profiles(in: entries.map(\.item))
            let known = profiles.filter { ProfileMenu.match($0.title, in: local) != nil }.count
            guard !profiles.isEmpty, ProfileMenu.titles.contains(titles[index]) || (known >= 2 && known == profiles.count) else { continue }
            menuIndex = (process, index)
            return entries
        }
        return nil
    }

    private func items(of menu: AXUIElement) -> [MenuEntry]? {
        guard let list = Self.children(menu)?.first, let elements = Self.children(list) else { return nil }
        return elements.map { element in
            var values: CFArray?
            let names = [kAXTitleAttribute, kAXMenuItemMarkCharAttribute] as CFArray
            let found = AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success ? values as? [AnyObject] : nil
            let title = found?.first as? String ?? ""
            let mark = found?.last as? String ?? ""
            return (ProfileMenuItem(title: title, checked: !mark.isEmpty), element)
        }
    }

    private func readLocalState() -> (profiles: [ChromeLocalProfile], lastUsed: String?) {
        let url = folder.appendingPathComponent("Local State")
        // Without Full Disk Access macOS hides Chrome's folder, and the menu's names are used alone.
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate, (values.fileSize ?? 0) <= 16 << 20 else { return ([], nil) }
        if let cached = localState, cached.modified == modified { return (cached.profiles, cached.lastUsed) }
        guard let data = try? Data(contentsOf: url) else { return ([], nil) }
        let parsed = ChromeLocalState.profiles(from: data)
        localState = (modified, parsed.profiles, parsed.lastUsed)
        return parsed
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement]? {
        value(element, kAXChildrenAttribute) as? [AXUIElement]
    }
}
