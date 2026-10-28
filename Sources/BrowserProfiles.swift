import Foundation

/// A color as Chrome stores it and the palette draws it, each part from 0 to 1.
struct ProfileColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Chrome keeps colors in Local State as signed 32-bit ARGB numbers.
    init(chrome value: Int) {
        self.init(hex: UInt32(truncatingIfNeeded: value) & 0xFF_FFFF)
    }

    private var extremes: (high: Double, low: Double) { (max(red, green, blue), min(red, green, blue)) }

    /// Degrees from 0 to 360.
    var hue: Double {
        let (high, low) = extremes
        guard high > low else { return 0 }
        let spread = high - low
        let sector: Double
        if high == red { sector = ((green - blue) / spread).truncatingRemainder(dividingBy: 6) }
        else if high == green { sector = (blue - red) / spread + 2 }
        else { sector = (red - green) / spread + 4 }
        return (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    var saturation: Double {
        let (high, low) = extremes
        return high == 0 ? 0 : (high - low) / high
    }

    var brightness: Double { extremes.high }

    /// A color too gray, dark or pale to tell profiles apart, like the default theme's.
    var isVivid: Bool { saturation >= 0.28 && brightness >= 0.35 }

    func hueDistance(to other: ProfileColor) -> Double {
        let difference = abs(hue - other.hue)
        return min(difference, 360 - difference)
    }
}

/// The fine pattern woven into a profile's color, so profiles differ by more than hue, also for people who see
/// some colors alike.
enum ProfileMotif: Int, CaseIterable {
    case strands, dots, waves, rings, weave
}

struct BrowserProfile: Equatable {
    /// "chrome:" and Chrome's folder for the profile, or its menu title when Local State cannot be read.
    let id: String
    let name: String
    /// The profile's item in Chrome's Profiles menu, which switches to it.
    let menuTitle: String?
    /// Chrome's folder for the profile, such as "Profile 3", which Chrome can also be started with.
    let directory: String?
    let color: ProfileColor
    let motif: ProfileMotif
    let picture: URL?

    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
}

/// A browser's profiles, in the order its own menu lists them, and the one its front window belongs to.
struct ProfileState: Equatable {
    let profiles: [BrowserProfile]
    let current: Int?
}

/// One profile as Chrome's Local State describes it.
struct ChromeLocalProfile: Equatable {
    let directory: String
    let name: String
    /// Chrome named the profile itself, such as "Person 1", and shows the account's name instead.
    let usesDefaultName: Bool
    let accountName: String?
    let email: String?
    let color: ProfileColor?
    /// The account picture's file inside the profile's folder.
    let picture: String?
}

enum ChromeLocalState {
    /// Every profile, in the order of Chrome's profile picker, and the one used last.
    static func profiles(from data: Data) -> (profiles: [ChromeLocalProfile], lastUsed: String?) {
        guard let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = state["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return ([], nil) }
        let order = profile["profiles_order"] as? [String] ?? []
        var result: [ChromeLocalProfile] = []
        for folder in order + cache.keys.sorted() where !result.contains(where: { $0.directory == folder }) {
            guard let info = cache[folder] as? [String: Any], !folder.isEmpty, !folder.contains("/"),
                  folder != ".", folder != "..", info["is_ephemeral"] as? Bool != true else { continue }
            let text = { (key: String) -> String? in
                (info[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String($0.prefix(64)) }
            }
            // A theme's color comes first; the default avatar's fill is what Chrome shows without one.
            let color = (info["profile_highlight_color"] as? Int ?? info["default_avatar_fill_color"] as? Int).map(ProfileColor.init(chrome:))
            result.append(ChromeLocalProfile(directory: folder, name: text("name") ?? folder,
                                             usesDefaultName: info["is_using_default_name"] as? Bool ?? false,
                                             accountName: text("gaia_given_name") ?? text("gaia_name"), email: text("user_name"),
                                             color: color, picture: text("gaia_picture_file_name")))
        }
        return (result, profile["last_used"] as? String)
    }
}

/// One item of Chrome's Profiles menu: a profile until the first separator, then commands such as Add Profile.
struct ProfileMenuItem: Equatable {
    let title: String
    let checked: Bool
}

enum ProfileMenu {
    /// Chrome's Profiles menu in the languages it is most likely shown in; its items confirm it otherwise.
    static let titles: Set<String> = ["Profiles", "Profile", "Profil", "Profils", "Perfiles", "Perfis", "Profili",
                                      "Profielen", "Profiler", "Profiilit", "Профили", "Профілі", "プロファイル", "프로필", "个人资料", "設定檔"]

    /// The profiles the menu lists, before its first separator, which has no title.
    static func profiles(in items: [ProfileMenuItem]) -> [ProfileMenuItem] {
        Array(items.prefix { !$0.title.isEmpty })
    }

    /// The Local State profile a menu title names. Chrome titles an item by the profile's name, by the account's
    /// name while the profile keeps the name Chrome gave it, or "Account (Profile)" when both are needed.
    static func match(_ title: String, in local: [ChromeLocalProfile]) -> ChromeLocalProfile? {
        local.first { $0.name == title }
            ?? local.first { $0.accountName == title }
            ?? local.first { title.hasSuffix(" (\($0.name))") }
            ?? local.first { $0.email == title }
    }

    /// Joins what the menu shows with what Local State knows. Without the menu, Local State alone lists the
    /// profiles and the one used last stands for the current one.
    static func state(menu: [ProfileMenuItem], local: [ChromeLocalProfile], lastUsed: String?,
                      folder: URL? = nil) -> ProfileState {
        var remaining = local
        var entries: [(title: String?, local: ChromeLocalProfile?)] = []
        var current: Int?
        for item in profiles(in: menu) {
            let found = match(item.title, in: remaining)
            if let found { remaining.removeAll { $0.directory == found.directory } }
            if item.checked && current == nil { current = entries.count }
            entries.append((item.title, found))
        }
        if entries.isEmpty {
            entries = local.map { (nil, $0) }
            current = local.firstIndex { $0.directory == lastUsed }
        }
        let ids = entries.map { entry in entry.local.map { "chrome:" + $0.directory } ?? "chrome-menu:" + (entry.title ?? "") }
        let colors = ProfilePalette.assign(ids: ids, chosen: entries.map { $0.local?.color })
        let motifs = ProfilePalette.motifs(ids: ids)
        let names = displayNames(entries)
        let profiles = entries.indices.map { index -> BrowserProfile in
            let local = entries[index].local
            let picture = local.flatMap { profile in
                profile.picture.flatMap { file in folder?.appendingPathComponent(profile.directory).appendingPathComponent(file) }
            }
            return BrowserProfile(id: ids[index], name: names[index], menuTitle: entries[index].title, directory: local?.directory,
                                  color: colors[index], motif: motifs[index], picture: picture)
        }
        return ProfileState(profiles: profiles, current: current)
    }

    /// The name people gave a profile, like Work, rather than the account's, which is often the same for every
    /// profile. Names still alike fall back on Chrome's menu titles, then on the account's address.
    private static func displayNames(_ entries: [(title: String?, local: ChromeLocalProfile?)]) -> [String] {
        var names = entries.map { entry -> String in
            guard let local = entry.local else { return entry.title ?? "Profile" }
            if local.usesDefaultName, let account = local.accountName { return account }
            return local.name
        }
        for fallback in [{ (index: Int) in entries[index].title }, { (index: Int) in entries[index].local?.email }] {
            let repeated = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
            for index in names.indices where repeated.contains(names[index]) {
                if let other = fallback(index), !other.isEmpty { names[index] = other }
            }
        }
        return names
    }
}

/// Tells the Chrome windows of one profile from another's by which profile's extension can see each window.
enum ProfileWindows {
    /// The windows of the profile `front` belongs to, among `windows`: those whose owner is the front window's.
    /// When that profile's extension is not connected, its windows are the ones no connected profile sees. Windows
    /// not asked about yet are left out. Nil when no owner is known, so profiles cannot be told apart.
    static func current(front: Int, windows: [Int], owners: [Int: Int]) -> Set<Int>? {
        guard !owners.isEmpty, let owner = owners[front] else { return owners.isEmpty ? nil : [front] }
        return Set(windows.filter { owners[$0] == owner } + [front])
    }
}

enum ProfilePalette {
    /// Colors for profiles without a vivid one of their own, picked to read on light and dark glass alike:
    /// iris, ember, lagoon, orchid, sky, moss, rose and amber.
    static let colors: [ProfileColor] = [0x6E63FF, 0xFF7A45, 0x14B8A6, 0xD946EF, 0x3B8CF6, 0x7CB518, 0xF43F5E, 0xF5A524]
        .map(ProfileColor.init(hex:))

    /// Each profile's own vivid color is kept; the others get the palette's colors in order, skipping any close
    /// in hue to a color already taken. Profiles are served in the order of their ids, so a profile keeps its
    /// color however Chrome orders its menu.
    static func assign(ids: [String], chosen: [ProfileColor?]) -> [ProfileColor] {
        var result = chosen.map { $0.flatMap { $0.isVivid ? $0 : nil } }
        for index in ids.indices.sorted(by: { ids[$0] < ids[$1] }) where result[index] == nil {
            let taken = result.compactMap { $0 }
            let nearest = { (color: ProfileColor) in taken.map { color.hueDistance(to: $0) }.min() ?? 360 }
            result[index] = colors.first { !taken.contains($0) && nearest($0) >= 45 }
                ?? colors.max { nearest($0) < nearest($1) } ?? colors[0]
        }
        return result.map { $0 ?? colors[0] }
    }

    static func motifs(ids: [String]) -> [ProfileMotif] {
        let order = ids.indices.sorted { ids[$0] < ids[$1] }
        var result = Array(repeating: ProfileMotif.strands, count: ids.count)
        for (rank, index) in order.enumerated() { result[index] = ProfileMotif.allCases[rank % ProfileMotif.allCases.count] }
        return result
    }
}
