import Foundation
import os
import SQLite3

/// A browser profile whose history Tab Scout can search: Safari's own, each further Safari profile and each
/// Chrome, Firefox and Zen profile. Its id stays the same across launches, so a profile turned off stays off.
struct HistoryProfile: Hashable {
    enum Kind: String { case safari, chrome, firefox, zen }
    static let safariID = "safari"

    let kind: Kind
    let id: String
    let name: String
    let history: URL
    /// Chrome's or Firefox's icon database beside its history. Safari's icon cache has no documented format.
    let icons: URL?
}

/// What one import found: the history of every profile read, the browsers' own icons by site, and every profile
/// there is.
struct BrowserImport {
    var snapshot = HistorySnapshot.empty
    var icons: [String: Data] = [:]
    var profiles: [HistoryProfile] = []
    /// Profiles that exist but could not be read.
    var failed: Set<String> = []
}

/// Finds browser profiles and reads their history. macOS lets Tab Scout see them only with Full Disk Access.
/// Only HistoryStore's worker queue uses it.
final class BrowserHistory {
    static let maximumIcons = 4_000
    /// Chrome counts microseconds from 1601, 11,644,473,600 seconds before 1970.
    private static let chromeEpoch: TimeInterval = -11_644_473_600
    private static let logger = Logger(subsystem: "local.tabscout.app", category: "history")
    private let home: URL
    private let scratch: URL
    private var iconCache: [String: (read: Date, icons: [String: Data])] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("TabScout-history", isDirectory: true)) {
        self.home = home
        self.scratch = scratch
        // Copies left behind by a read that never finished, such as when Tab Scout quit during one.
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Every profile found, Safari's own first. Profiles in folders macOS will not let Tab Scout list are missing.
    func profiles() -> [HistoryProfile] {
        [HistoryProfile(kind: .safari, id: HistoryProfile.safariID, name: "Safari",
                        history: home.appendingPathComponent("Library/Safari/History.db"), icons: nil)]
            + safariProfiles() + chromeProfiles()
            + firefoxProfiles(.firefox, folder: "Firefox") + firefoxProfiles(.zen, folder: "zen")
    }

    /// Reads every profile except Safari's own, which HistoryStore reads itself, and those in `excluded`.
    func read(excluding excluded: Set<String>, now: Date) -> BrowserImport {
        var result = BrowserImport()
        result.profiles = profiles()
        let count = { (kind: HistoryProfile.Kind) in result.profiles.filter { $0.kind == kind }.count }
        Self.logger.notice("found \(count(.safari) - 1, privacy: .public) more Safari profiles, \(count(.chrome), privacy: .public) Chrome, \(count(.firefox), privacy: .public) Firefox and \(count(.zen), privacy: .public) Zen profiles")
        for (number, profile) in result.profiles.enumerated() where profile.id != HistoryProfile.safariID && !excluded.contains(profile.id) {
            let started = DispatchTime.now()
            do {
                let history: HistorySnapshot
                switch profile.kind {
                case .safari: history = try HistoryStore.readSafari(at: profile.history, now: now)
                case .chrome: history = try readChrome(at: profile.history, now: now)
                case .firefox, .zen: history = try readFirefox(at: profile.history, now: now)
                }
                result.snapshot = HistoryStore.merge(result.snapshot, history, now: now, additive: true)
                let icons = profile.icons.map { self.icons(for: profile, at: $0, now: now) } ?? [:]
                result.icons.merge(icons) { first, _ in first }
                let milliseconds = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                Self.logger.notice("\(profile.kind.rawValue, privacy: .public) profile \(number, privacy: .public): \(history.visits.count, privacy: .public) pages, \(icons.count, privacy: .public) icons in \(milliseconds, privacy: .public) ms")
            } catch {
                result.failed.insert(profile.id)
                Self.logger.error("\(profile.kind.rawValue, privacy: .public) profile \(number, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        return result
    }

    /// Safari keeps each further profile's history in a folder named by the profile's identifier.
    private func safariProfiles() -> [HistoryProfile] {
        let container = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari")
        let names = safariProfileNames(container.appendingPathComponent("SafariTabs.db"))
        var result: [HistoryProfile] = []
        for root in [container.appendingPathComponent("Profiles"), home.appendingPathComponent("Library/Safari/Profiles")] {
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for folder in folders.sorted() where folder != "DefaultProfile" {
                let history = root.appendingPathComponent(folder).appendingPathComponent("History.db")
                let id = "safari:" + folder.uppercased()
                guard FileManager.default.fileExists(atPath: history.path), !result.contains(where: { $0.id == id }) else { continue }
                let name = names[folder.uppercased()] ?? "Profile \(result.count + 2)"
                result.append(HistoryProfile(kind: .safari, id: id, name: "Safari – " + name, history: history, icons: nil))
            }
        }
        return result
    }

    /// Safari lists its profiles among its bookmarks, by the identifier their folders are named after.
    private func safariProfileNames(_ url: URL) -> [String: String] {
        var names: [String: String] = [:]
        try? HistoryStore.query(url, sql: """
            SELECT external_uuid, title FROM bookmarks WHERE subtype = 2 AND external_uuid IS NOT NULL AND title IS NOT NULL
            """, bind: { _ in }, row: { statement in
            guard let id = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) else { return }
            let name = String(cString: title).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names[String(cString: id).uppercased()] = String(name.prefix(64)) }
        })
        return names
    }

    /// Chrome names its profile folders Default and Profile 1, 2 and so on, and the names people gave them are
    /// in its Local State file. A folder can outlive its profile, so only listed folders with history count.
    private func chromeProfiles() -> [HistoryProfile] {
        let root = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        var names: [String: String] = [:]
        var order: [String] = []
        let stateURL = root.appendingPathComponent("Local State")
        if let size = try? stateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 << 20,
           let data = try? Data(contentsOf: stateURL),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = state["profile"] as? [String: Any] {
            for (folder, info) in profile["info_cache"] as? [String: Any] ?? [:] {
                if let name = (info as? [String: Any])?["name"] as? String { names[folder] = name }
            }
            order = profile["profiles_order"] as? [String] ?? []
        }
        let folders = names.isEmpty ? ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") } : Array(names.keys)
        var result: [HistoryProfile] = []
        for folder in order + folders.sorted() where !result.contains(where: { $0.id == "chrome:" + folder }) {
            guard !folder.isEmpty, !folder.contains("/"), folder != ".", folder != "..",
                  names.isEmpty || names[folder] != nil else { continue }
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            let history = directory.appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: history.path) else { continue }
            let name = String((names[folder] ?? folder).prefix(64))
            result.append(HistoryProfile(kind: .chrome, id: "chrome:" + folder, name: "Chrome – " + name,
                                         history: history, icons: directory.appendingPathComponent("Favicons")))
        }
        return result
    }

    /// Firefox, and Zen in a folder of its own, list their profiles in profiles.ini: a name and a folder each, the
    /// folder mostly inside the browser's own. Only profiles with history count.
    private func firefoxProfiles(_ kind: HistoryProfile.Kind, folder: String) -> [HistoryProfile] {
        let root = home.appendingPathComponent("Library/Application Support/" + folder)
        let label = kind == .zen ? "Zen" : "Firefox"
        var listed: [(name: String, directory: URL)] = []
        if let size = try? root.appendingPathComponent("profiles.ini").resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1 << 20,
           let text = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) {
            listed = Self.firefoxProfiles(inList: text).map { entry in
                (entry.name, entry.relative ? root.appendingPathComponent(entry.path, isDirectory: true) : URL(fileURLWithPath: entry.path, isDirectory: true))
            }
        }
        if listed.isEmpty {
            // Without the list, the folders themselves: "x7k2abcd.default-release" is the profile default-release.
            let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
            listed = ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []).sorted().map { name in
                (name.split(separator: ".", maxSplits: 1).last.map(String.init) ?? name, profiles.appendingPathComponent(name, isDirectory: true))
            }
        }
        var result: [HistoryProfile] = []
        for (name, directory) in listed {
            let id = kind.rawValue + ":" + directory.lastPathComponent
            let history = directory.appendingPathComponent("places.sqlite")
            guard FileManager.default.fileExists(atPath: history.path), !result.contains(where: { $0.id == id }) else { continue }
            result.append(HistoryProfile(kind: kind, id: id, name: label + " – " + String(name.prefix(64)),
                                         history: history, icons: directory.appendingPathComponent("favicons.sqlite")))
        }
        return result
    }

    /// The profiles in the text of a profiles.ini: each [Profile…] section's name and folder, and whether the folder
    /// is given from the browser's own. Sections about installations are skipped.
    static func firefoxProfiles(inList text: String) -> [(name: String, path: String, relative: Bool)] {
        var result: [(name: String, path: String, relative: Bool)] = []
        var section: [String: String]?
        func close() {
            guard let section, let path = section["Path"], !path.isEmpty else { return }
            let relative = section["IsRelative"] != "0"
            // A folder given from the browser's own never leaves it.
            guard !relative || !path.split(separator: "/").contains("..") else { return }
            result.append((section["Name"] ?? URL(fileURLWithPath: path).lastPathComponent, path, relative))
        }
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") {
                close()
                section = line.hasPrefix("[Profile") ? [:] : nil
            } else if section != nil, let equals = line.firstIndex(of: "=") {
                section?[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        close()
        return result
    }

    /// Firefox counts microseconds from 1970. Pages it hides, such as those only passed through on the way to
    /// another, downloads, and pages loaded inside frames are not pages the person visited.
    func readFirefox(at url: URL, now: Date) throws -> HistorySnapshot {
        try withCopy(of: url) { copy in
            let sql = """
            SELECT moz_places.url, COALESCE(moz_places.title, ''), moz_historyvisits.visit_date
            FROM moz_historyvisits JOIN moz_places ON moz_places.id = moz_historyvisits.place_id
            WHERE moz_historyvisits.visit_date >= ? AND moz_historyvisits.visit_date <= ?
                  AND moz_places.hidden = 0 AND moz_historyvisits.visit_type NOT IN (4, 7, 8)
            ORDER BY moz_historyvisits.visit_date DESC, moz_historyvisits.id DESC LIMIT ?
            """
            var rows = HistorySnapshot.empty
            try HistoryStore.query(copy, readOnly: false, sql: sql, bind: { statement in
                sqlite3_bind_int64(statement, 1, Self.firefoxTime(now.addingTimeInterval(-HistoryStore.retention)))
                sqlite3_bind_int64(statement, 2, Self.firefoxTime(now))
                sqlite3_bind_int(statement, 3, Int32(HistoryStore.maximumProfileRows))
            }, row: { statement in
                guard let rawURL = sqlite3_column_text(statement, 0), let rawTitle = sqlite3_column_text(statement, 1) else { return }
                let time = sqlite3_column_int64(statement, 2)
                rows.add(url: String(cString: rawURL), title: String(cString: rawTitle),
                         at: Date(timeIntervalSince1970: Double(time / 1_000_000) + Double(time % 1_000_000) / 1_000_000))
            })
            return HistoryStore.merge(rows, .empty, now: now, additive: true)
        }
    }

    static func firefoxTime(_ date: Date) -> Int64 {
        let whole = date.timeIntervalSince1970.rounded(.down)
        return Int64(whole) * 1_000_000 + Int64(((date.timeIntervalSince1970 - whole) * 1_000_000).rounded())
    }

    func readChrome(at url: URL, now: Date) throws -> HistorySnapshot {
        try withCopy(of: url) { copy in
            // Pages loaded inside frames of another page are not pages the person visited.
            let sql = """
            SELECT urls.url, COALESCE(urls.title, ''), visits.visit_time
            FROM visits JOIN urls ON urls.id = visits.url
            WHERE visits.visit_time >= ? AND visits.visit_time <= ? AND (visits.transition & 255) NOT IN (3, 4)
            ORDER BY visits.visit_time DESC, visits.id DESC LIMIT ?
            """
            var rows = HistorySnapshot.empty
            try HistoryStore.query(copy, readOnly: false, sql: sql, bind: { statement in
                sqlite3_bind_int64(statement, 1, Self.chromeTime(now.addingTimeInterval(-HistoryStore.retention)))
                sqlite3_bind_int64(statement, 2, Self.chromeTime(now))
                sqlite3_bind_int(statement, 3, Int32(HistoryStore.maximumProfileRows))
            }, row: { statement in
                guard let rawURL = sqlite3_column_text(statement, 0), let rawTitle = sqlite3_column_text(statement, 1) else { return }
                rows.add(url: String(cString: rawURL), title: String(cString: rawTitle),
                         at: Self.date(chromeTime: sqlite3_column_int64(statement, 2)))
            })
            return HistoryStore.merge(rows, .empty, now: now, additive: true)
        }
    }

    // Microseconds since 1601 need more digits than a Double holds, so whole seconds are converted apart.
    static func chromeTime(_ date: Date) -> Int64 {
        let seconds = date.timeIntervalSince1970 - chromeEpoch
        let whole = seconds.rounded(.down)
        return Int64(whole) * 1_000_000 + Int64(((seconds - whole) * 1_000_000).rounded())
    }

    static func date(chromeTime: Int64) -> Date {
        Date(timeIntervalSince1970: Double(chromeTime / 1_000_000) + chromeEpoch + Double(chromeTime % 1_000_000) / 1_000_000)
    }

    /// Icons change far less often than history, so they are read again at most every ten minutes.
    private func icons(for profile: HistoryProfile, at url: URL, now: Date) -> [String: Data] {
        if let cached = iconCache[profile.id], now >= cached.read, now.timeIntervalSince(cached.read) < 600 { return cached.icons }
        let read = profile.kind == .chrome ? Self.readChromeIcons : Self.readFirefoxIcons
        let icons = (try? withCopy(of: url, read)) ?? iconCache[profile.id]?.icons ?? [:]
        iconCache[profile.id] = (now, icons)
        return icons
    }

    /// The icon Firefox shows for each site, as PNG data by origin: the one most of the site's pages use, in the
    /// size closest to 32 pixels, or the icon at the site's root when no page names one. Firefox keeps one row per
    /// size; drawings, which have no size, are left out.
    static func readFirefoxIcons(at url: URL) throws -> [String: Data] {
        var bitmaps: [Int64: (width: Int32, png: Data)] = [:]
        var roots: [String: Int64] = [:]
        let nearer = { (first: Int32, second: Int32) in abs(first - 32) < abs(second - 32) || (abs(first - 32) == abs(second - 32) && first > second) }
        try HistoryStore.query(url, readOnly: false, sql: """
            SELECT id, width, data, root, icon_url FROM moz_icons WHERE width BETWEEN 1 AND 1024 AND length(data) BETWEEN 1 AND 65536
            """, bind: { _ in }, row: { statement in
            guard let bytes = sqlite3_column_blob(statement, 2) else { return }
            let icon = sqlite3_column_int64(statement, 0)
            let width = sqlite3_column_int(statement, 1)
            bitmaps[icon] = (width, Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2))))
            guard sqlite3_column_int(statement, 3) == 1, let address = sqlite3_column_text(statement, 4),
                  let origin = origin(of: String(cString: address)) else { return }
            if let kept = roots[origin].flatMap({ bitmaps[$0] }), !nearer(width, kept.width) { return }
            roots[origin] = icon
        })
        var uses: [String: [Int64: Int]] = [:]
        try HistoryStore.query(url, readOnly: false, sql: """
            SELECT moz_pages_w_icons.page_url, moz_icons_to_pages.icon_id
            FROM moz_icons_to_pages JOIN moz_pages_w_icons ON moz_pages_w_icons.id = moz_icons_to_pages.page_id
            """, bind: { _ in }, row: { statement in
            let icon = sqlite3_column_int64(statement, 1)
            guard bitmaps[icon] != nil, let page = sqlite3_column_text(statement, 0),
                  let origin = origin(of: String(cString: page)) else { return }
            uses[origin, default: [:]][icon, default: 0] += 1
        })
        for (origin, icon) in roots where uses[origin] == nil { uses[origin] = [icon: 0] }
        let busiest = uses.sorted { first, second in
            let (a, b) = (first.value.values.reduce(0, +), second.value.values.reduce(0, +))
            return a == b ? first.key < second.key : a > b
        }
        var icons: [String: Data] = [:]
        for (origin, counts) in busiest.prefix(maximumIcons) {
            let best = counts.max { first, second in
                if first.value != second.value { return first.value < second.value }
                guard let a = bitmaps[first.key]?.width, let b = bitmaps[second.key]?.width, a != b else { return first.key < second.key }
                return nearer(b, a)
            }
            if let best { icons[origin] = bitmaps[best.key]?.png }
        }
        return icons
    }

    /// The icon Chrome shows for each site, as PNG data by origin: the one most of the site's pages use, in the
    /// size closest to 32 pixels. Touch icons and app icons are left out.
    static func readChromeIcons(at url: URL) throws -> [String: Data] {
        var bitmaps: [Int64: (width: Int32, png: Data)] = [:]
        try HistoryStore.query(url, readOnly: false, sql: """
            SELECT favicon_bitmaps.icon_id, favicon_bitmaps.width, favicon_bitmaps.image_data
            FROM favicon_bitmaps JOIN favicons ON favicons.id = favicon_bitmaps.icon_id
            WHERE favicons.icon_type = 1 AND length(favicon_bitmaps.image_data) BETWEEN 1 AND 65536
            """, bind: { _ in }, row: { statement in
            guard let bytes = sqlite3_column_blob(statement, 2) else { return }
            let icon = sqlite3_column_int64(statement, 0)
            let width = sqlite3_column_int(statement, 1)
            if let kept = bitmaps[icon], abs(kept.width - 32) < abs(width - 32) || (abs(kept.width - 32) == abs(width - 32) && kept.width >= width) {
                return
            }
            bitmaps[icon] = (width, Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2))))
        })
        var uses: [String: [Int64: Int]] = [:]
        try HistoryStore.query(url, readOnly: false, sql: "SELECT page_url, icon_id FROM icon_mapping", bind: { _ in }, row: { statement in
            let icon = sqlite3_column_int64(statement, 1)
            guard bitmaps[icon] != nil, let page = sqlite3_column_text(statement, 0),
                  let origin = origin(of: String(cString: page)) else { return }
            uses[origin, default: [:]][icon, default: 0] += 1
        })
        let busiest = uses.sorted { first, second in
            let (a, b) = (first.value.values.reduce(0, +), second.value.values.reduce(0, +))
            return a == b ? first.key < second.key : a > b
        }
        var icons: [String: Data] = [:]
        for (origin, counts) in busiest.prefix(maximumIcons) {
            guard let icon = counts.max(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value })?.key else { continue }
            icons[origin] = bitmaps[icon]?.png
        }
        return icons
    }

    static func origin(of address: String) -> String? {
        guard let components = URLComponents(string: address), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) ? nil : components.port
        return origin.string
    }

    /// Chrome and Firefox lock their databases while they run, so they are read from a private copy, which APFS
    /// makes as a clone that takes no time or space. The journal or write-ahead log beside the file is copied too,
    /// so the copy opens as the browser last saved it. The copy is deleted after reading.
    private func withCopy<T>(of url: URL, _ read: (URL) throws -> T) throws -> T {
        let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw HistoryError.unavailable }
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: copy) } catch let error as NSError {
            if error.code == NSFileReadNoSuchFileError { throw HistoryError.unavailable }
            throw error.code == NSFileReadNoPermissionError ? HistoryError.needsPermission : HistoryError.unavailable
        }
        for suffix in ["-journal", "-wal"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try? FileManager.default.copyItem(atPath: url.path + suffix, toPath: copy.path + suffix)
        }
        return try read(copy)
    }
}
