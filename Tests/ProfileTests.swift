import Foundation

@main
struct ProfileTests {
    static var checks = 0

    static func main() {
        localState()
        menu()
        colors()
        windows()
        swipe()
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

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
}
