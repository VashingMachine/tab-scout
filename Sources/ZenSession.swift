import Compression
import Foundation

/// Mozilla's wrapping of an LZ4 block, which Firefox and Zen save their session files in: "mozLz40" and a zero
/// byte, the size of the contents as a 32-bit number, then the block.
enum MozLz4 {
    static let magic = Data("mozLz40\0".utf8)
    /// A session with hundreds of tabs and their icons is a few megabytes; nothing comes near this.
    static let limit = 256 << 20

    static func decode(_ data: Data) -> Data? {
        guard data.count > 12, data.prefix(8) == magic else { return nil }
        let size = data.dropFirst(8).prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard size > 0, size <= limit else { return nil }
        var contents = Data(count: size)
        let written = contents.withUnsafeMutableBytes { target -> Int in
            Data(data.dropFirst(12)).withUnsafeBytes { source -> Int in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, size, from, source.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == size ? contents : nil
    }
}

/// One of Zen's spaces as its session file describes it.
struct ZenSpace: Equatable {
    /// Zen's own identifier for the space, braces included.
    let id: String
    let name: String
    /// The emoji people gave the space. One of Zen's own drawings is left out: only Zen can show it.
    let emblem: String?
    /// The first color of the space's theme, when it has one.
    let color: ProfileColor?
    /// How Zen titles the space's item in its Spaces menu: the name, after its icon and two spaces unless the icon
    /// is one of Zen's drawings.
    let menuTitle: String

    init(id: String, name: String, emblem: String? = nil, color: ProfileColor? = nil, menuTitle: String? = nil) {
        self.id = id
        self.name = name
        self.emblem = emblem
        self.color = color
        self.menuTitle = menuTitle ?? emblem.map { $0 + "  " + name } ?? name
    }
}

/// Zen's spaces and which pages each holds, from zen-sessions.jsonlz4 in Zen's profile folder. Zen keeps the tabs of
/// the spaces not on screen to itself: an extension sees only the tabs of the space in front, so the names of the
/// spaces and where each tab belongs are only known from here.
struct ZenSession: Equatable {
    var spaces: [ZenSpace] = []
    /// The addresses open in each space, by its identifier, without the essentials every space shows.
    var pages: [String: Set<String>] = [:]

    init(spaces: [ZenSpace] = [], pages: [String: Set<String>] = [:]) {
        self.spaces = spaces
        self.pages = pages
    }

    /// From the session file's contents, once unwrapped; nil when it is not a session.
    init?(json: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let listed = root["spaces"] as? [[String: Any]] else { return nil }
        for entry in listed {
            guard let id = entry["uuid"] as? String, !id.isEmpty, !spaces.contains(where: { $0.id == id }) else { continue }
            let rawName = entry["name"] as? String ?? ""
            let rawIcon = entry["icon"] as? String ?? ""
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let icon = rawIcon.trimmingCharacters(in: .whitespacesAndNewlines)
            // An emoji is a few characters; anything with a path is one of Zen's drawings.
            let emblem = icon.isEmpty || icon.count > 4 || icon.contains("/") || icon.contains(".") ? nil : icon
            spaces.append(ZenSpace(id: id, name: String((name.isEmpty ? "Space" : name).prefix(64)), emblem: emblem,
                                   color: Self.color(ofTheme: entry["theme"]),
                                   menuTitle: rawIcon.isEmpty || rawIcon.hasSuffix(".svg") ? rawName : rawIcon + "  " + rawName))
        }
        for tab in root["tabs"] as? [[String: Any]] ?? [] {
            guard tab["zenEssential"] as? Bool != true, let space = tab["zenWorkspace"] as? String,
                  let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else { continue }
            // `index` counts the tab's history from one; the entry there is the page on screen.
            let shown = min(max((tab["index"] as? Int ?? entries.count) - 1, 0), entries.count - 1)
            guard let url = entries[shown]["url"] as? String, !BrowserTab.isBlank(url) else { continue }
            pages[space, default: []].insert(url)
        }
    }

    /// Zen keeps a theme's colors as a list, each red, green and blue from 0 to 255 or, when picked by hand, as
    /// text such as "#3b8cf6". The one marked as the main color counts, else the first.
    static func color(ofTheme theme: Any?) -> ProfileColor? {
        guard let colors = (theme as? [String: Any])?["gradientColors"] as? [[String: Any]], !colors.isEmpty else { return nil }
        let main = colors.first { $0["isPrimary"] as? Bool == true } ?? colors[0]
        if let parts = main["c"] as? [NSNumber], parts.count >= 3 {
            return ProfileColor(red: parts[0].doubleValue / 255, green: parts[1].doubleValue / 255, blue: parts[2].doubleValue / 255)
        }
        guard let text = main["c"] as? String else { return nil }
        if text.hasPrefix("#"), text.count == 7, let value = UInt32(text.dropFirst(), radix: 16) { return ProfileColor(hex: value) }
        // "rgb(59, 140, 246)", with or without an opacity after it.
        let numbers = text.split { !($0.isNumber || $0 == ".") }.compactMap { Double($0) }
        guard text.hasPrefix("rgb"), numbers.count >= 3 else { return nil }
        return ProfileColor(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255)
    }

    /// The space Zen says is in front, from the text of its prefs.js: the last one any of its windows switched to.
    static func preferredSpace(inPreferences text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { $0.contains("\"zen.workspaces.active\"") }),
              let comma = line.firstIndex(of: ",") else { return nil }
        let quoted = line[line.index(after: comma)...].split(separator: "\"")
        return quoted.count >= 2 ? String(quoted[1]) : nil
    }

    /// The space the window in front shows. The tabs Zen lists there are the tabs of that space, so it is the space
    /// holding most of their addresses; when that settles nothing, as with spaces just made or holding the same
    /// pages, it is the one Zen names as last switched to.
    func current(showing addresses: [String], preferred: String?) -> String? {
        let shown = Set(addresses.filter { !BrowserTab.isBlank($0) })
        let scores = spaces.map { pages[$0.id, default: []].intersection(shown).count }
        if let best = scores.max(), best > 0, scores.filter({ $0 == best }).count == 1, let index = scores.firstIndex(of: best) {
            return spaces[index].id
        }
        return spaces.contains { $0.id == preferred } ? preferred : nil
    }

    /// The spaces as places to swipe between, in Zen's order, each with its theme's color when that is vivid enough
    /// to tell spaces apart, else one that is. Nil with fewer than two spaces: Zen is then one place.
    func places(current: String?) -> ProfileState? {
        guard spaces.count > 1 else { return nil }
        let ids = spaces.map { "zen:" + $0.id }
        let colors = ProfilePalette.assign(ids: ids, chosen: spaces.map(\.color))
        let motifs = ProfilePalette.motifs(ids: ids)
        // Spaces named alike are told apart by their place in Zen's order.
        let names = spaces.enumerated().map { index, space in
            spaces.filter { $0.name == space.name }.count > 1 ? "\(space.name) \(index + 1)" : space.name
        }
        let profiles = spaces.indices.map { index in
            BrowserProfile(id: ids[index], browser: .zen, name: names[index], menuTitle: spaces[index].menuTitle, directory: nil,
                           color: colors[index], motif: motifs[index], picture: nil, emblem: spaces[index].emblem)
        }
        return ProfileState(profiles: profiles, current: spaces.firstIndex { $0.id == current })
    }
}

/// Zen's Spaces menu, as Accessibility lists it: its own commands first, among them the two that go to the next
/// and the previous space, then, after a separator, one item per space other than the one in front.
enum ZenSpacesMenu {
    /// Where things are in the menu's items, given their titles; a separator has none.
    struct Layout: Equatable {
        /// The item that goes to the next space, and the one after it that goes to the previous one.
        let forward: Int
        /// The items of the spaces not in front, in Zen's order.
        let spaces: Range<Int>
    }

    /// Nil when the titles are not laid out as Zen's Spaces menu is: four commands, a separator, the two that
    /// step through spaces, and then nothing or a separator and the other spaces.
    static func layout(_ titles: [String]) -> Layout? {
        let breaks = titles.indices.filter { titles[$0].isEmpty }
        guard titles.count >= 7, breaks.first == 4, !titles[5].isEmpty, !titles[6].isEmpty else { return nil }
        if titles.count == 7 { return Layout(forward: 5, spaces: 7..<7) }
        guard breaks.count == 2, breaks[1] == 7, titles.count > 8 else { return nil }
        return Layout(forward: 5, spaces: 8..<titles.count)
    }

    /// How to get from the space in front to `target`: the item to press, and how many times. A space's own item is
    /// pressed once. When the menu does not list it, the command that steps to the next space, or the one to the
    /// previous, is pressed as often as it takes. Nil when `target` is in front already or is no space.
    static func presses(to target: Int, from current: Int?, spaces: [ZenSpace], titles: [String], layout: Layout) -> (item: Int, times: Int)? {
        guard spaces.indices.contains(target), target != current else { return nil }
        let others = Array(layout.spaces)
        // The menu lists the spaces in Zen's order without the one in front, so the target's place there is known.
        if let current, spaces.indices.contains(current), others.count == spaces.count - 1 {
            let place = others[target < current ? target : target - 1]
            if titles[place] == spaces[target].menuTitle { return (place, 1) }
        }
        let named = others.filter { titles[$0] == spaces[target].menuTitle }
        if named.count == 1 { return (named[0], 1) }
        // Zen may be set not to go round from its last space to its first, so the steps never count on that.
        guard let current, spaces.indices.contains(current) else { return nil }
        return target > current ? (layout.forward, target - current) : (layout.forward + 1, current - target)
    }
}
