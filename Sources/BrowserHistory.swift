import Foundation
import os
import SQLite3

/// A browser profile whose history Tab Scout can search: Safari's own, each further Safari profile and each
/// Chrome profile. Its id stays the same across launches, so a profile turned off stays off.
struct HistoryProfile: Hashable {
    enum Kind: String { case safari, chrome }
    static let safariID = "safari"

    let kind: Kind
    let id: String
    let name: String
    let history: URL
    /// Chrome's icon database beside its history. Safari's icon cache has no documented format.
    let icons: URL?
}

/// What one import found: the history of every profile read, Chrome's icons by site, and every profile there is.
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
    }

    /// Reads every profile except Safari's own, which HistoryStore reads itself, and those in `excluded`.
    func read(excluding excluded: Set<String>, now: Date) -> BrowserImport {
        var result = BrowserImport()
        result.profiles = profiles()
        Self.logger.notice("found \(result.profiles.filter { $0.kind == .safari }.count - 1, privacy: .public) more Safari profiles, \(result.profiles.filter { $0.kind == .chrome }.count, privacy: .public) Chrome profiles")
        for (number, profile) in result.profiles.enumerated() where profile.id != HistoryProfile.safariID && !excluded.contains(profile.id) {
            let started = DispatchTime.now()
            do {
                let history = profile.kind == .chrome ? try readChrome(at: profile.history, now: now)
                    : try HistoryStore.readSafari(at: profile.history, now: now)
                result.snapshot = HistoryStore.merge(result.snapshot, history, now: now, additive: true)
                let icons = profile.icons.map { self.icons(for: profile.id, at: $0, now: now) } ?? [:]
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
    private func icons(for profile: String, at url: URL, now: Date) -> [String: Data] {
        if let cached = iconCache[profile], now >= cached.read, now.timeIntervalSince(cached.read) < 600 { return cached.icons }
        let icons = (try? withCopy(of: url, Self.readChromeIcons)) ?? iconCache[profile]?.icons ?? [:]
        iconCache[profile] = (now, icons)
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

    /// Chrome locks its databases while it runs, so they are read from a private copy, which APFS makes as a clone
    /// that takes no time or space. The journal or write-ahead log beside the file is copied too, so the copy
    /// opens as Chrome last saved it. The copy is deleted after reading.
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
