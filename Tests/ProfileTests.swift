import Foundation

@main
struct ProfileTests {
    static var checks = 0

    static func main() {
        localState()
        menu()
        colors()
        windows()
        scope()
        spaces()
        swipe()
        swipeModes()
        settings()
        looks()
        print("Passed \(checks) profile checks")
    }

    static func localState() {
        let json = """
        {"profile": {"last_used": "Profile 3", "profiles_order": ["Profile 3", "Default"], "info_cache": {
            "Default": {"name": "Person 1", "is_using_default_name": true, "gaia_given_name": "Dariusz",
                        "user_name": "d@example.com", "gaia_picture_file_name": "Google Profile Picture.png"},
            "Profile 3": {"name": "Work", "is_using_default_name": false, "profile_highlight_color": -16748085},
            "Profile 9": {"name": "Guest-like", "is_ephemeral": true},
            "../escape": {"name": "Bad"}
        }}}
        """
        let parsed = ChromeLocalState.profiles(from: Data(json.utf8))
        expect(parsed.profiles.map(\.directory) == ["Profile 3", "Default"], "Profiles follow Chrome's picker order and skip ephemeral or unsafe folders")
        expect(parsed.lastUsed == "Profile 3", "The profile used last is read")
        expect(parsed.profiles[0].color == ProfileColor(hex: 0x0071CB), "Chrome's signed ARGB colors are read")
        expect(parsed.profiles[1].accountName == "Dariusz" && parsed.profiles[1].usesDefaultName, "The account's name is read")
        expect(ChromeLocalState.profiles(from: Data("{".utf8)).profiles.isEmpty, "Unreadable Local State lists no profiles")
    }

    static func menu() {
        let local = [ChromeLocalProfile(directory: "Default", name: "Person 1", usesDefaultName: true, accountName: "Dariusz",
                                        email: "d@example.com", color: nil, picture: "Google Profile Picture.png"),
                     ChromeLocalProfile(directory: "Profile 3", name: "Work", usesDefaultName: false, accountName: "Dariusz",
                                        email: "d@work.example", color: ProfileColor(hex: 0x0071CB), picture: nil)]
        let items = [ProfileMenuItem(title: "Dariusz", checked: false), ProfileMenuItem(title: "Dariusz (Work)", checked: true),
                     ProfileMenuItem(title: "", checked: false), ProfileMenuItem(title: "Add Profile…", checked: false)]
        expect(ProfileMenu.profiles(in: items).count == 2, "Only the items before the separator are profiles")
        let folder = URL(fileURLWithPath: "/Chrome")
        let state = ProfileMenu.state(menu: items, local: local, lastUsed: "Default", folder: folder)
        expect(state.current == 1, "The checked item is the current profile, whatever was used last")
        expect(state.profiles.map(\.directory) == ["Default", "Profile 3"], "Menu titles find their Local State profiles")
        expect(state.profiles.map(\.name) == ["Dariusz", "Work"], "Given names win over the account's, which the default name gives way to")
        expect(state.profiles.map(\.menuTitle) == ["Dariusz", "Dariusz (Work)"], "Switching presses the item's own title")
        expect(state.profiles[0].picture == folder.appendingPathComponent("Default/Google Profile Picture.png"), "The account picture is found")
        expect(state.profiles[1].color == ProfileColor(hex: 0x0071CB), "A profile's own vivid color is kept")

        let unread = ProfileMenu.state(menu: items, local: [], lastUsed: nil)
        expect(unread.profiles.map(\.id) == ["chrome-menu:Dariusz", "chrome-menu:Dariusz (Work)"] && unread.current == 1,
               "Without Local State, the menu alone names the profiles")
        let menuless = ProfileMenu.state(menu: [], local: local, lastUsed: "Profile 3")
        expect(menuless.profiles.count == 2 && menuless.current == 1 && menuless.profiles.allSatisfy { $0.menuTitle == nil },
               "Without the menu, Local State lists the profiles and the one used last is current")

        let twins = [ChromeLocalProfile(directory: "Default", name: "Person 1", usesDefaultName: true, accountName: "Dariusz",
                                        email: "d@home.example", color: nil, picture: nil),
                     ChromeLocalProfile(directory: "Profile 1", name: "Person 2", usesDefaultName: true, accountName: "Dariusz",
                                        email: "d@work.example", color: nil, picture: nil)]
        let both = ProfileMenu.state(menu: [ProfileMenuItem(title: "Dariusz", checked: true), ProfileMenuItem(title: "Dariusz", checked: false)],
                                     local: twins, lastUsed: nil)
        expect(both.profiles.map(\.name) == ["d@home.example", "d@work.example"], "Profiles named alike are told apart by their accounts")
        expect(both.profiles.map(\.directory) == ["Default", "Profile 1"], "Items titled alike match different profiles")
    }

    static func colors() {
        let plain = ProfilePalette.assign(ids: ["chrome:Default", "chrome:Profile 3"], chosen: [nil, nil])
        expect(plain == Array(ProfilePalette.colors.prefix(2)), "Profiles without colors take the palette in order")
        let reversed = ProfilePalette.assign(ids: ["chrome:Profile 3", "chrome:Default"], chosen: [nil, nil])
        expect(reversed == [plain[1], plain[0]], "A profile keeps its color however the menu orders it")
        let blue = ProfileColor(hex: 0x1A73E8)
        let mixed = ProfilePalette.assign(ids: ["a", "b"], chosen: [blue, nil])
        expect(mixed[0] == blue && mixed[1].hueDistance(to: blue) >= 45, "Palette colors keep clear of a profile's own color")
        let gray = ProfileColor(hex: 0x5F6368)
        expect(!gray.isVivid && ProfilePalette.assign(ids: ["a"], chosen: [gray]) == [ProfilePalette.colors[0]],
               "Gray theme colors give way to the palette")
        let many = ProfilePalette.assign(ids: (0..<10).map { "p\($0)" }, chosen: Array(repeating: nil, count: 10))
        expect(Set(many.prefix(8).map(\.hue)).count == 8, "Eight profiles get eight different colors")
        expect(ProfilePalette.motifs(ids: ["b", "a"]) == [.dots, .strands], "Patterns follow the profiles' ids too")
        expect(abs(ProfileColor(hex: 0xFF0000).hue) < 0.001 && abs(ProfileColor(hex: 0x0000FF).hue - 240) < 0.001, "Hues are in degrees")
    }

    static func windows() {
        // Owners are extension connections; 0 stands for windows no connected profile sees.
        let owners = [1: 5, 2: 6, 3: 5, 4: 0]
        expect(ProfileWindows.current(front: 1, windows: [1, 2, 3], owners: [:]) == nil, "Without any owner, profiles cannot be told apart")
        expect(ProfileWindows.current(front: 1, windows: [1, 2, 3, 4], owners: owners) == [1, 3],
               "The profile in front has the windows its extension sees")
        expect(ProfileWindows.current(front: 2, windows: [1, 2, 3, 4], owners: owners) == [2], "Another profile in front has its own")
        expect(ProfileWindows.current(front: 4, windows: [1, 2, 3, 4], owners: owners) == [4],
               "A profile without the extension has the windows no extension sees")
        expect(ProfileWindows.current(front: 1, windows: [1, 3, 9], owners: owners) == [1, 3], "A window not asked about yet is left out")
        expect(ProfileWindows.current(front: 9, windows: [1, 3, 9], owners: owners) == [9], "A new window in front lists only itself until known")
    }

    static func spaces() {
        let chrome = ProfileMenu.state(menu: [ProfileMenuItem(title: "Personal", checked: false), ProfileMenuItem(title: "Work", checked: true)],
                                       local: [], lastUsed: nil)
        let both = BrowserSpaces.combine(safari: true, chrome: chrome, chromeRunning: true, front: .chrome)
        expect(both.profiles.map(\.name) == ["Safari", "Personal", "Work"] && both.current == 2,
               "Safari comes first, then Chrome's profiles, and the Chrome profile in front is current")
        expect(both.profiles.map(\.browser) == [.safari, .chrome, .chrome], "Each place knows its browser")
        expect(Array(both.profiles.dropFirst()) == chrome.profiles, "Chrome's profiles keep their colors and patterns beside Safari")
        let safari = both.profiles[0]
        expect(safari.symbol == "safari" && safari.motif == .rings && safari.menuTitle == nil, "Safari shows its compass and ripples")
        expect(chrome.profiles.allSatisfy { $0.color.hueDistance(to: safari.color) >= 45 }, "Safari's color keeps clear of the profiles'")
        expect(BrowserSpaces.combine(safari: true, chrome: chrome, chromeRunning: true, front: .safari).current == 0,
               "Over Safari, Safari is current")
        let lone = BrowserSpaces.combine(safari: true, chrome: nil, chromeRunning: true, front: .chrome)
        expect(lone.profiles.map(\.name) == ["Safari", "Chrome"] && lone.current == 1 && lone.profiles[1].menuTitle == nil,
               "Chrome without readable profiles is one place, named after it")
        let single = ProfileMenu.state(menu: [ProfileMenuItem(title: "Dariusz", checked: true)], local: [], lastUsed: nil)
        expect(BrowserSpaces.combine(safari: true, chrome: single, chromeRunning: true, front: .chrome).profiles.map(\.name) == ["Safari", "Chrome"],
               "Chrome with one profile is named after Chrome")
        expect(BrowserSpaces.combine(safari: false, chrome: chrome, chromeRunning: true, front: .chrome) == chrome,
               "Without Safari, only Chrome's profiles are places")
        expect(BrowserSpaces.combine(safari: true, chrome: chrome, chromeRunning: false, front: .safari).profiles.count == 1,
               "A browser that is not running is no place to go")

        let every = BrowserSpaces.combine(safari: true, chrome: chrome, chromeRunning: true, others: [.firefox, .zen], front: .zen)
        expect(every.profiles.map(\.name) == ["Safari", "Personal", "Work", "Firefox", "Zen"] && every.current == 4,
               "Firefox and Zen follow Chrome's profiles as places of their own, and the one in front is current")
        expect(every.profiles.map(\.browser) == [.safari, .chrome, .chrome, .firefox, .zen] && every.profiles.suffix(2).map(\.id) == ["firefox", "zen"]
               && every.profiles.suffix(2).map(\.symbol) == ["flame", "circle.circle"],
               "Each is one place named after its browser, with a symbol of its own")
        expect(Array(every.profiles.prefix(3)) == both.profiles, "Safari and Chrome's profiles look as they do without them")
        let colors = every.profiles.map(\.color)
        expect(colors.indices.allSatisfy { first in colors.indices.allSatisfy { first == $0 || colors[first].hueDistance(to: colors[$0]) >= 45 } },
               "Every place's color keeps clear of the others'")
        expect(Set(every.profiles.map(\.motif)).count == 5, "Every place gets a pattern of its own while there are enough")
        let alone = BrowserSpaces.combine(safari: false, chrome: nil, chromeRunning: false, others: [.zen], front: .zen)
        expect(alone.profiles.map(\.id) == ["zen"] && alone.current == 0 && alone.profiles[0].color == BrowserSpaces.zenColors[0]
               && alone.profiles[0].motif == .dots, "Alone, Zen is the only place, in its first color and its own pattern")
        expect(BrowserSpaces.combine(safari: true, chrome: nil, chromeRunning: false, others: [.firefox], front: .zen).current == nil
               && BrowserSpaces.combine(safari: true, chrome: nil, chromeRunning: false, others: [.chrome, .safari], front: .safari).profiles.count == 1,
               "A browser that is not among the places is nowhere, and only browsers reached through the extension are added this way")
        expect(PlaceScope.listing([BrowserTab(browser: .zen, windowID: 3, index: 1, title: "Calm", url: "https://zen.example/"),
                                   BrowserTab(windowID: 1, index: 1, title: "Docs", url: "https://docs.example/")],
                                  in: .zen, chromeProfiles: 2, active: nil, owners: [:])
               == PlaceScope.Listing(tabs: [BrowserTab(browser: .zen, windowID: 3, index: 1, title: "Calm", url: "https://zen.example/")], unseparated: false),
               "Over Zen only Zen's tabs are listed, however many profiles Chrome has")
    }

    static func swipe() {
        var swipe = ProfileSwipe(count: 3, index: 0)
        swipe.touch()
        expect(!swipe.scroll(dx: 0.5, dy: 0.5, time: 0), "A tiny first movement decides nothing")
        expect(!swipe.scroll(dx: 1, dy: 6, time: 0.01) && swipe.axis == .upright, "Mostly vertical scrolling stays with the results")
        expect(!swipe.scroll(dx: -40, dy: 0, time: 0.02), "A gesture that started upright stays upright")
        expect(!swipe.release(time: 0.03) && swipe.target == 0, "Releasing an upright gesture moves no profile")

        swipe.touch()
        expect(swipe.scroll(dx: -8, dy: 2, time: 0), "Mostly sideways scrolling belongs to the swipe")
        for step in 1...8 { _ = swipe.scroll(dx: -8, dy: 0, time: Double(step) * 0.016) }
        expect(abs(swipe.position - 72.0 / ProfileSwipe.pageTravel) < 0.001, "Moving the fingers left brings the next profile in")
        expect(swipe.release(time: 9 * 0.016) && swipe.target == 1 && swipe.swallowsMomentum, "Letting go past the threshold moves on")
        var frames = 0
        while swipe.advance(by: 1.0 / 120) { frames += 1 }
        expect(swipe.position == 1 && swipe.isSettled && frames < 120, "The spring settles on the profile within a second")

        swipe.touch()
        _ = swipe.scroll(dx: 20, dy: 0, time: 1)
        _ = swipe.scroll(dx: 20, dy: 0, time: 1.5)
        expect(swipe.release(time: 2) && swipe.target == 1, "A slow drag short of the threshold returns")

        swipe.touch()
        for step in 0..<4 { _ = swipe.scroll(dx: -12, dy: 0, time: 3 + Double(step) * 0.008) }
        _ = swipe.release(time: 3.04)
        expect(swipe.target == 2, "A quick flick moves on even when the fingers travel little")

        swipe.touch()
        for step in 0..<40 { _ = swipe.scroll(dx: -30, dy: 0, time: 4 + Double(step) * 0.5) }
        expect(swipe.position > 2 && swipe.position < 2 + ProfileSwipe.stretch, "Past the last profile the swipe only stretches")
        _ = swipe.release(time: 30)
        expect(swipe.target == 2, "The last profile stays the last")

        var wheel = ProfileSwipe(count: 2, index: 0)
        expect(!wheel.step(dx: 0, dy: -3, time: 0), "An upright wheel turn is left to the results")
        expect(wheel.step(dx: -1, dy: 0, time: 0) && wheel.target == 1, "A sideways wheel turn moves one profile")
        expect(wheel.step(dx: -1, dy: 0, time: 0.1) && wheel.target == 1, "Repeats of the same turn are absorbed")
        expect(wheel.step(dx: -1, dy: 0, time: 0.5) && wheel.target == 1 && !wheel.isSettled, "Past the end it bumps and stays")
        expect(wheel.step(dx: 1, dy: 0, time: 1) && wheel.target == 0, "Turning back returns")

        var moved = ProfileSwipe(count: 4, index: 3)
        moved.move(to: 0)
        while moved.advance(by: 1.0 / 60) {}
        expect(moved.position == 0 && moved.target == 0, "A click jumps to any profile")
        expect(ProfileSwipe(count: 2, index: 5).target == 1, "A current profile out of range is clamped")
    }

    static func swipeModes() {
        func flick(_ swipe: inout ProfileSwipe, by points: Double) {
            swipe.touch()
            var time = 0.0
            _ = swipe.scroll(dx: -20, dy: 0, time: time)
            for _ in 0..<Int(points / 20) {
                time += 0.008
                _ = swipe.scroll(dx: -20, dy: 0, time: time)
            }
            _ = swipe.release(time: time)
            while swipe.advance(by: 1.0 / 60) {}
        }
        var free = ProfileSwipe(count: 5, index: 0)
        flick(&free, by: 400)
        expect(free.target >= 2, "A fast flick carries past the next place in free mode")
        var single = ProfileSwipe(count: 5, index: 0, mode: .single)
        flick(&single, by: 400)
        expect(single.target == 1 && single.position == 1, "A single-step swipe stops at the next place however fast")
        flick(&single, by: 400)
        expect(single.target == 2, "The next single-step swipe moves one more")
        var held = ProfileSwipe(count: 5, index: 2, mode: .single)
        held.touch()
        _ = held.scroll(dx: -3, dy: 0, time: 0)
        _ = held.scroll(dx: -900, dy: 0, time: 0.5)
        expect(held.position < 3.4, "Pulling past the next place in single-step mode stretches like an end")

        var gentle = ProfileSwipe(count: 5, index: 0, sensitivity: 0.5)
        var normal = ProfileSwipe(count: 5, index: 0)
        gentle.touch()
        normal.touch()
        _ = gentle.scroll(dx: -100, dy: 0, time: 0)
        _ = normal.scroll(dx: -100, dy: 0, time: 0)
        expect(abs(gentle.position * 2 - normal.position) < 0.0001, "Lower sensitivity needs more finger travel per place")
        var slow = ProfileSwipe(count: 5, index: 0, sensitivity: 0.5)
        flick(&slow, by: 400)
        var quick = ProfileSwipe(count: 5, index: 0, sensitivity: 1.6)
        flick(&quick, by: 400)
        expect(slow.target < quick.target, "Lower sensitivity carries the same flick less far")
    }

    static func scope() {
        let safari = [BrowserTab(windowID: 1, index: 1, title: "News", url: "https://news.example/"),
                      BrowserTab(windowID: 1, index: 2, title: "Mail", url: "https://mail.example/")]
        let work = [BrowserTab(browser: .chrome, windowID: 7, index: 1, title: "Meet", url: "https://meet.example/"),
                    BrowserTab(browser: .chrome, windowID: 8, index: 1, title: "Code", url: "https://code.example/")]
        let personal = [BrowserTab(browser: .chrome, windowID: 9, index: 1, title: "Shop", url: "https://shop.example/")]
        let all = work + safari + personal
        let owners = [7: 1, 8: 1, 9: 2]
        for profiles in [0, 1, 3] {
            let listing = PlaceScope.listing(all, in: .safari, chromeProfiles: profiles, active: safari[0], owners: owners)
            expect(listing.tabs == safari && !listing.unseparated,
                   "Over Safari only Safari's tabs are listed, however many profiles Chrome has (\(profiles))")
        }
        expect(PlaceScope.listing(work + personal, in: .safari, chromeProfiles: 3, active: nil, owners: owners).tabs.isEmpty,
               "Chrome's tabs arriving before Safari's never stand in for them")
        expect(PlaceScope.listing(all, in: .chrome, chromeProfiles: 1, active: work[0], owners: [:]).tabs == work + personal,
               "Over Chrome with one profile every Chrome tab is listed, and no Safari tab")
        expect(PlaceScope.listing(all, in: .chrome, chromeProfiles: 3, active: work[0], owners: owners).tabs == work,
               "With several profiles only the windows of the profile in front are listed")
        expect(PlaceScope.listing(all, in: .chrome, chromeProfiles: 3, active: safari[0], owners: owners).tabs == work,
               "Without a Chrome tab on screen, the first Chrome window listed is the one in front")
        let unknown = PlaceScope.listing(all, in: .chrome, chromeProfiles: 3, active: work[0], owners: [:])
        expect(unknown.tabs == work + personal && unknown.unseparated,
               "Without the extension the profiles cannot be told apart, which the footer then says")
        expect(PlaceScope.listing([], in: .chrome, chromeProfiles: 3, active: nil, owners: owners) == .init(tabs: [], unseparated: false),
               "No tabs is not a failure to tell profiles apart")
    }

    static func settings() {
        let chrome = ProfileMenu.state(menu: [ProfileMenuItem(title: "Personal", checked: false), ProfileMenuItem(title: "Work", checked: true),
                                              ProfileMenuItem(title: "Side", checked: false)], local: [], lastUsed: nil)
        let places = BrowserSpaces.combine(safari: true, chrome: chrome, chromeRunning: true, front: .chrome)
        var chosen = PlaceSettings()
        chosen.hidden = [places.profiles[1].id, places.profiles[2].id]
        chosen.colors[places.profiles[3].id] = [ProfileColor(hex: 0x112233)]
        chosen.colors["safari"] = [0x14B8A6, 0x6E63FF, 0xD946EF, 0xFF7A45].map(ProfileColor.init(hex:))
        chosen.motifs["safari"] = .weave
        chosen.strengths["safari"] = 1.4
        chosen.textures["safari"] = 0
        let applied = chosen.apply(to: places)
        expect(applied.profiles.map(\.name) == ["Safari", "Work", "Side"] && applied.current == 1,
               "Hidden places are left out, except the one in front")
        expect(applied.profiles[2].color == ProfileColor(hex: 0x112233) && applied.profiles[0].motif == .weave,
               "Chosen colors and patterns replace the automatic ones")
        expect(applied.profiles[0].color == ProfileColor(hex: 0x14B8A6)
               && applied.profiles[0].accents == [ProfileColor(hex: 0x6E63FF), ProfileColor(hex: 0xD946EF)],
               "The first chosen color is the place's own and two more are blended in")
        expect(applied.profiles[0].strength == 1.4 && applied.profiles[0].texture == 0, "A chosen strength and texture are the place's")
        expect(applied.profiles[2].accents.isEmpty && applied.profiles[2].strength == 1 && applied.profiles[2].texture == 1,
               "A place given one color keeps the usual wash and texture")
        expect(chosen.isCustom("safari") && !chosen.isCustom(places.profiles[1].id), "A place with anything chosen counts as customized")
        var cleared = chosen
        cleared.reset("safari")
        expect(!cleared.isCustom("safari") && cleared.styled(places.profiles[0]) == places.profiles[0] && cleared.hidden == chosen.hidden,
               "Going back to automatic drops every choice about the look and nothing else")

        let defaults = UserDefaults(suiteName: "ProfileTests-\(UUID().uuidString)")!
        chosen.swipeMode = .single
        chosen.sensitivity = 0.7
        chosen.save(to: defaults)
        chosen.colors["safari"]?.removeLast()
        expect(PlaceSettings(defaults: defaults) == chosen, "Place settings survive a save and load, with no more colors than a place shows")
        defaults.set(["safari": "#3B8CF6", "zen": "nonsense"], forKey: "PlaceColors")
        defaults.set(["safari": 9.0], forKey: "PlaceStrengths")
        defaults.set(["safari": -1.0], forKey: "PlaceTextures")
        let stored = PlaceSettings(defaults: defaults)
        expect(stored.colors == ["safari": [ProfileColor(hex: 0x3B8CF6)]], "A single color stored by an earlier version still reads, and nonsense is dropped")
        expect(stored.strengths["safari"] == PlaceSettings.strengthRange.upperBound && stored.textures["safari"] == 0,
               "Stored strengths and textures are kept in range")
        defaults.set(9.0, forKey: "SwipeSensitivity")
        expect(PlaceSettings(defaults: defaults).sensitivity == PlaceSettings.sensitivityRange.upperBound, "A stored sensitivity is kept in range")
        expect(ProfileColor(hexString: ProfileColor(hex: 0x3B8CF6).hexString) == ProfileColor(hex: 0x3B8CF6), "Colors round-trip through hex")
    }

    static func looks() {
        for color in ProfilePalette.colors {
            expect(ProfileColor(hue: color.hue, saturation: color.saturation, brightness: color.brightness).hexString == color.hexString,
                   "A color is the same again from its hue, saturation and brightness")
        }
        expect(ProfileColor(hue: -120, saturation: 1, brightness: 1).hexString == "#0000FF"
               && ProfileColor(hue: 480, saturation: 1, brightness: 1).hexString == "#00FF00", "Hue wraps around both ways")
        expect(!ProfilePalette.motifs(ids: (0..<12).map(String.init)).contains(.plain), "No place is given the grain-only pattern by itself")

        for (x, y) in [(0.1, 0.2), (0.5, 0.5), (0.8, 0.9), (0.0, 0.0), (0.33, 1.0)] {
            let point = ColorField.point(for: ColorField.color(x: x, y: y))
            expect(abs(point.x - x) < 0.001 && abs(point.y - y) < 0.001, "A color picked on the field sits where it was picked")
        }
        let pale = ColorField.color(x: 0.5, y: 0)
        let deep = ColorField.color(x: 0.5, y: 1)
        expect(abs(pale.saturation - ColorField.paleSaturation) < 0.001 && pale.brightness == 1
               && abs(deep.brightness - ColorField.deepBrightness) < 0.001 && abs(deep.saturation - 1) < 0.001,
               "The field runs from pale at the top to deep at the bottom")
        expect(ColorField.color(x: 1, y: 0.5).hue > 350, "The right edge stops short of the left edge's red")
        expect(ColorField.color(x: -3, y: 9) == ColorField.color(x: 0, y: 1), "A point outside the field counts as its edge")
        expect(ColorField.point(for: ProfileColor(hex: 0x14B8A6)).y > 0.5 && ColorField.point(for: ProfileColor(hex: 0x6E63FF)).y < 0.5,
               "A deep color sits below the middle and a pale one above")

        let base = [ProfileColor(hex: 0x3B8CF6), ProfileColor(hue: 10, saturation: 0.5, brightness: 0.9), ProfileColor(hex: 0x7CB518)]
        let triad = ColorHarmony.triad.arranged(base)
        expect(triad[0] == base[0] && abs(triad[1].hueDistance(to: base[0]) - 120) < 0.5 && abs(triad[2].hueDistance(to: base[0]) - 120) < 0.5
               && abs(triad[1].hueDistance(to: triad[2]) - 120) < 0.5, "A triad spreads the other colors evenly around the first")
        expect(abs(triad[1].saturation - 0.5) < 0.001 && abs(triad[1].brightness - 0.9) < 0.001, "A harmony keeps how pale or deep each color was")
        expect(abs(ColorHarmony.complement.arranged(Array(base.prefix(2)))[1].hueDistance(to: base[0]) - 180) < 0.5,
               "The opposite of a color is across the wheel")
        expect(ColorHarmony.split.arranged([base[0]]) == [base[0]], "A single color has nothing to arrange")
        let second = ColorHarmony.added(to: [base[0]])
        let third = ColorHarmony.added(to: [base[0], second])
        expect(second.hueDistance(to: base[0]) >= 20 && third.hueDistance(to: base[0]) >= 20 && third.hueDistance(to: second) >= 20,
               "An added color is a neighbor of the first, clear of the colors already there")
        expect(ThemePresets.pages.count == 4 && ThemePresets.pages.allSatisfy { page in
            page.themes.count == 8 && page.themes.allSatisfy { (1...PlaceSettings.colorLimit).contains($0.count) }
        }, "Every page of ready-made looks holds eight, none with more colors than a place shows")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
}
