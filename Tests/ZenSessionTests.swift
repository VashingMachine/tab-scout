import Compression
import Foundation

/// Covers what Tab Scout reads of Zen's spaces: the session file's wrapping and contents, which space is in front,
/// the spaces as places, and how Zen's Spaces menu is used to switch. No file of Zen's is read.
@main
struct ZenSessionTests {
    static var checks = 0

    static func main() {
        wrapping()
        session()
        current()
        places()
        menu()
        print("Passed \(checks) Zen session checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    /// `contents` as Firefox and Zen save it.
    static func wrap(_ contents: Data) -> Data {
        var block = Data(count: contents.count + 64)
        let written = block.withUnsafeMutableBytes { target in
            contents.withUnsafeBytes { source in
                compression_encode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, target.count,
                                          source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        precondition(written > 0, "The fixture could not be compressed")
        let size = UInt32(contents.count)
        return MozLz4.magic + Data([UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)]) + block.prefix(written)
    }

    static func wrapping() {
        let text = Data(String(repeating: "{\"spaces\":[],\"tabs\":[]} zen zen zen ", count: 200).utf8)
        let wrapped = wrap(text)
        expect(wrapped.count < text.count / 4 && MozLz4.decode(wrapped) == text, "A session file unwraps to what was saved")
        expect(MozLz4.decode(Data("mozLz40\0".utf8)) == nil && MozLz4.decode(Data()) == nil, "A file that ends after its heading is no session")
        expect(MozLz4.decode(Data("notLz40\0".utf8) + wrapped.dropFirst(8)) == nil, "A file with another heading is not unwrapped")
        expect(MozLz4.decode(wrapped.dropLast(20)) == nil, "A file cut short is refused rather than half read")
        var lying = wrapped
        lying[8] = lying[8] &+ 1
        expect(MozLz4.decode(lying) == nil, "Contents of another size than the heading says are refused")
        expect(MozLz4.decode(MozLz4.magic + Data([0xFF, 0xFF, 0xFF, 0x7F]) + wrapped.dropFirst(12)) == nil, "A heading claiming gigabytes is refused")
    }

    static let saved = """
    {"lastCollected": 1, "spaces": [
      {"uuid": "{home}", "name": "Home", "icon": "🏠", "containerTabId": 0,
       "theme": {"type": "gradient", "gradientColors": [{"c": [200, 200, 200], "isPrimary": false}, {"c": [59, 140, 246], "isPrimary": true}]}},
      {"uuid": "{work}", "name": " Work ", "icon": "chrome://browser/skin/zen-icons/selectable/briefcase.svg",
       "theme": {"type": "gradient", "gradientColors": [{"c": "#F43F5E", "isCustom": true}]}},
      {"uuid": "{side}", "name": "", "theme": {"type": "gradient", "gradientColors": []}},
      {"uuid": "{rgb}", "name": "Work", "icon": "", "theme": {"gradientColors": [{"c": "rgb(20, 184, 166)", "isCustom": true}]}},
      {"uuid": "{home}", "name": "Again"}, {"name": "No identifier"}
    ], "tabs": [
      {"zenWorkspace": "{home}", "index": 2, "entries": [{"url": "https://old.example/"}, {"url": "https://news.example/", "title": "News"}]},
      {"zenWorkspace": "{home}", "entries": [{"url": "https://mail.example/"}]},
      {"zenWorkspace": "{work}", "index": 1, "entries": [{"url": "https://jira.example/T-1"}, {"url": "https://later.example/"}]},
      {"zenWorkspace": "{work}", "index": 9, "entries": [{"url": "https://docs.example/plan"}]},
      {"zenWorkspace": "{work}", "zenEssential": true, "entries": [{"url": "https://chat.example/"}]},
      {"zenWorkspace": "{side}", "entries": [{"url": "about:newtab"}]},
      {"zenWorkspace": "{side}", "entries": []},
      {"entries": [{"url": "https://nowhere.example/"}]}
    ], "folders": [], "groups": []}
    """

    static func session() {
        guard let session = ZenSession(json: Data(saved.utf8)) else { fatalError("The session did not parse") }
        expect(session.spaces.map(\.id) == ["{home}", "{work}", "{side}", "{rgb}"], "Spaces are read in Zen's order; one listed twice or without an identifier is skipped")
        expect(session.spaces.map(\.name) == ["Home", "Work", "Space", "Work"], "Names are tidied, and a space without one is called Space as Zen calls it")
        expect(session.spaces.map(\.emblem) == ["🏠", nil, nil, nil], "An emoji is kept for the badge; one of Zen's drawings is not")
        expect(session.spaces.map(\.menuTitle) == ["🏠  Home", " Work ", "", "Work"],
               "The menu title is the name as Zen has it, after the emoji and two spaces, as Zen writes its Spaces menu")
        expect(session.spaces[0].color == ProfileColor(red: 59 / 255, green: 140 / 255, blue: 246 / 255), "The theme's main color is the space's")
        expect(session.spaces[1].color == ProfileColor(hex: 0xF43F5E) && session.spaces[3].color == ProfileColor(red: 20 / 255, green: 184 / 255, blue: 166 / 255),
               "A color picked by hand is read from its text, either way Zen writes it")
        expect(session.spaces[2].color == nil, "A theme without colors gives none")
        expect(session.pages == ["{home}": ["https://news.example/", "https://mail.example/"],
                                 "{work}": ["https://jira.example/T-1", "https://docs.example/plan"]],
               "Each space holds the page each of its tabs shows now; essentials, empty tabs and tabs of no space are left out")
        expect(ZenSession(json: Data("[]".utf8)) == nil && ZenSession(json: Data("{\"tabs\": []}".utf8)) == nil && ZenSession(json: Data("zen".utf8)) == nil,
               "Anything that is not a session with spaces is none")
        expect(ZenSpace(id: "{x}", name: "Trips", emblem: "✈️").menuTitle == "✈️  Trips" && ZenSpace(id: "{y}", name: "Plain").menuTitle == "Plain",
               "A space made by hand gets the title Zen would give it")
    }

    static func current() {
        let session = ZenSession(json: Data(saved.utf8))!
        expect(session.current(showing: ["https://jira.example/T-1", "https://new.example/", "about:newtab"], preferred: "{home}") == "{work}",
               "The space holding the tabs Zen lists is the one in front, whatever Zen last wrote down")
        expect(session.current(showing: ["https://news.example/", "https://mail.example/", "https://jira.example/T-1"], preferred: nil) == "{home}",
               "With tabs of two spaces known, as after one was moved, the space holding more of them counts")
        expect(session.current(showing: ["https://news.example/", "https://jira.example/T-1"], preferred: "{side}") == "{side}",
               "When the tabs settle nothing, the space Zen names as last switched to is in front")
        expect(session.current(showing: [], preferred: "{rgb}") == "{rgb}" && session.current(showing: ["https://new.example/"], preferred: "{gone}") == nil
               && session.current(showing: ["about:blank"], preferred: nil) == nil,
               "An empty space is known by Zen's word alone, and a space Zen names but no longer has is not believed")
        let preferences = """
        user_pref("zen.workspaces.active", "{old}");
        user_pref("zen.welcome-screen.seen", true);
        user_pref("zen.workspaces.active", "{3e7460be-1897-4072-8ded-94ddee5ad590}");
        user_pref("zen.workspaces.continue-where-left-off", true);
        """
        expect(ZenSession.preferredSpace(inPreferences: preferences) == "{3e7460be-1897-4072-8ded-94ddee5ad590}", "Zen's own note of the space in front is read from its preferences")
        expect(ZenSession.preferredSpace(inPreferences: "user_pref(\"zen.workspaces.active.other\", \"x\");\n") == nil
               && ZenSession.preferredSpace(inPreferences: "") == nil, "Without that note there is none")
    }

    static func places() {
        let session = ZenSession(json: Data(saved.utf8))!
        guard let state = session.places(current: "{work}") else { fatalError("Four spaces gave no places") }
        expect(state.profiles.map(\.id) == ["zen:{home}", "zen:{work}", "zen:{side}", "zen:{rgb}"] && state.current == 1,
               "Each space is a place of Zen's, named by Zen's identifier, and the one in front is current")
        expect(state.profiles.map(\.name) == ["Home", "Work 2", "Space", "Work 4"], "Spaces named alike are told apart by their place")
        expect(state.profiles.allSatisfy { $0.browser == .zen && $0.symbol == nil && $0.directory == nil }
               && state.profiles.map(\.menuTitle) == ["🏠  Home", " Work ", "", "Work"], "A space knows its item in Zen's menu")
        expect(state.profiles[0].initial == "🏠" && state.profiles[1].initial == "W", "Its badge shows its emoji, else its initial")
        expect(state.profiles[0].color == session.spaces[0].color && state.profiles[1].color == ProfileColor(hex: 0xF43F5E)
               && state.profiles[2].color.isVivid && Set(state.profiles.map(\.motif)).count == 4,
               "A vivid theme color is kept, a space without one gets a color, and each has its own pattern")
        expect(session.places(current: "{gone}")?.current == nil, "A space that is not Zen's is not current")
        expect(ZenSession(spaces: [ZenSpace(id: "{only}", name: "Space")]).places(current: "{only}") == nil && ZenSession().places(current: nil) == nil,
               "With one space, or none read, Zen is a single place")

        let chrome = ProfileMenu.state(menu: [ProfileMenuItem(title: "Personal", checked: true), ProfileMenuItem(title: "Work", checked: false)], local: [], lastUsed: nil)
        let all = BrowserSpaces.combine(safari: true, chrome: chrome, chromeRunning: true, others: [.firefox, .zen], spaces: [.zen: state], front: .zen)
        expect(all.profiles.map(\.name) == ["Safari", "Personal", "Work", "Firefox", "Home", "Work 2", "Space", "Work 4"] && all.current == 5,
               "Zen's spaces stand where Zen would, after the other browsers, and the space in front is current")
        expect(Array(all.profiles.suffix(4)) == state.profiles, "The spaces keep their own colors and patterns")
        let single = all.profiles.prefix(4).filter { $0.browser != .chrome }
        expect(single.allSatisfy { place in state.profiles.allSatisfy { $0.color.hueDistance(to: place.color) >= 20 } },
               "Safari's and Firefox's colors keep clear of the spaces' where the palette allows")
        expect(BrowserSpaces.combine(safari: true, chrome: nil, chromeRunning: false, others: [.zen], spaces: [.zen: state], front: .safari).current == 0
               && BrowserSpaces.combine(safari: false, chrome: nil, chromeRunning: false, others: [.zen],
                                        spaces: [.zen: ProfileState(profiles: state.profiles, current: nil)], front: .zen).current == 0,
               "Over Safari, Safari is current; over Zen with no space known to be in front, its first one is")
        expect(BrowserSpaces.combine(safari: true, chrome: nil, chromeRunning: false, others: [.firefox], spaces: [.zen: state], front: .firefox).profiles.map(\.id) == ["safari", "firefox"]
               && BrowserSpaces.combine(safari: true, chrome: nil, chromeRunning: false, others: [.zen],
                                        spaces: [.zen: ProfileState(profiles: [state.profiles[0]], current: 0)], front: .zen).profiles.map(\.id) == ["safari", "zen"],
               "Spaces of a browser that is not running are no places, and a single space leaves Zen one place")
    }

    static func menu() {
        let fixed = ["Create Space", "Theme…", "Change Name…", "Change Icon…", "", "Next Space", "Previous Space"]
        expect(ZenSpacesMenu.layout(fixed) == ZenSpacesMenu.Layout(forward: 5, spaces: 7..<7), "With one space the menu has only its commands")
        expect(ZenSpacesMenu.layout(fixed + ["", "Work", "Side"]) == ZenSpacesMenu.Layout(forward: 5, spaces: 8..<10), "The other spaces follow a second separator")
        expect(ZenSpacesMenu.layout(["Neuer Space", "Thema…", "Name ändern…", "Symbol ändern…", "", "Nächster", "Vorheriger", "", "Arbeit"])?.spaces == 8..<9,
               "The menu is known by its layout, in whatever language")
        for other in [["Undo", "Redo", "", "Cut", "Copy", "Paste"], ["New Tab", "New Window", "", "Close"], fixed + [""], fixed + ["Work"],
                      fixed + ["", "Work", "", "More"], ["A", "B", "C", "D", "E", "F", "G"], []] {
            expect(ZenSpacesMenu.layout(other) == nil, "Another menu is not taken for it: \(other)")
        }

        let spaces = [ZenSpace(id: "{a}", name: "Home", emblem: "🏠"), ZenSpace(id: "{b}", name: "Work"), ZenSpace(id: "{c}", name: "Side"), ZenSpace(id: "{d}", name: "Work")]
        func presses(_ target: Int, from current: Int?, _ listed: [String]) -> [Int]? {
            let titles = fixed + (listed.isEmpty ? [] : [""] + listed)
            guard let layout = ZenSpacesMenu.layout(titles) else { fatalError("The fixture is no Spaces menu") }
            return ZenSpacesMenu.presses(to: target, from: current, spaces: spaces, titles: titles, layout: layout).map { [$0.item, $0.times] }
        }
        // In Home, Zen lists the other three in its order.
        let inHome = ["Work", "Side", "Work"]
        expect(presses(1, from: 0, inHome) == [8, 1] && presses(3, from: 0, inHome) == [10, 1] && presses(2, from: 0, inHome) == [9, 1],
               "A space's own item is pressed once, and two spaces named alike are told apart by their place")
        expect(presses(0, from: 2, ["🏠  Home", "Work", "Work"]) == [8, 1], "A space before the one in front keeps its place in the menu")
        expect(presses(0, from: 0, inHome) == nil && presses(7, from: 0, inHome) == nil, "The space in front, or one that is none, needs no press")
        // A menu last filled while Side was in front lists Home, Work and Work, although Zen is in Home by now.
        let stale = ["🏠  Home", "Work", "Work"]
        expect(presses(2, from: 0, stale) == [5, 2], "A space the menu does not list is reached by stepping forward")
        expect(presses(0, from: 2, ["Work", "Side", "Work"]) == [6, 2], "Or by stepping back, never round the end")
        expect(presses(1, from: 0, stale) == [5, 1], "A name the menu lists twice, neither where the space should be, is not guessed at; steps are counted instead")
        expect(presses(3, from: 0, stale) == [10, 1], "A space still listed where it should be is pressed directly")
        expect(presses(2, from: nil, inHome) == [9, 1] && presses(1, from: nil, inHome) == nil,
               "Without knowing the space in front, a name listed once is still pressed, and nothing else")
        expect(presses(2, from: 0, []) == [5, 2] && presses(0, from: 3, []) == [6, 3] && presses(2, from: nil, []) == nil,
               "A menu not yet filled with spaces still steps, given the space in front")
    }
}
