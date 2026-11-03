import Foundation

/// How far one swipe can travel across the palette's places.
enum SwipeMode: String, CaseIterable {
    /// A flick carries on past the next place, as far as its speed takes it.
    case free
    /// One swipe moves at most one place, however fast it is.
    case single
}

/// What people chose for the places the palette swipes between: which are left out, the colors and patterns they
/// picked over the automatic ones, and how swiping feels.
struct PlaceSettings: Equatable {
    static let sensitivityRange = 0.4...1.6

    var hidden: Set<String> = []
    var colors: [String: ProfileColor] = [:]
    var motifs: [String: ProfileMotif] = [:]
    var swipeMode = SwipeMode.free
    /// 1 is the default feel; lower needs more finger travel and carries a flick less far.
    var sensitivity = 1.0

    /// `state` with the chosen colors and patterns, without the hidden places. The place in front stays even when
    /// hidden, so the palette always shows where it is.
    func apply(to state: ProfileState) -> ProfileState {
        var current: Int?
        var places: [BrowserProfile] = []
        for (index, place) in state.profiles.enumerated() where !hidden.contains(place.id) || index == state.current {
            if index == state.current { current = places.count }
            places.append(styled(place))
        }
        return ProfileState(profiles: places, current: current)
    }

    func styled(_ place: BrowserProfile) -> BrowserProfile {
        var place = place
        if let color = colors[place.id] { place.color = color }
        if let motif = motifs[place.id] { place.motif = motif }
        return place
    }

    // MARK: - Storage

    private enum Key {
        static let hidden = "HiddenPlaces"
        static let colors = "PlaceColors"
        static let motifs = "PlaceMotifs"
        static let mode = "SwipeMode"
        static let sensitivity = "SwipeSensitivity"
    }

    init() {}

    init(defaults: UserDefaults) {
        hidden = Set(defaults.stringArray(forKey: Key.hidden) ?? [])
        colors = (defaults.dictionary(forKey: Key.colors) as? [String: String] ?? [:]).compactMapValues(ProfileColor.init(hexString:))
        motifs = (defaults.dictionary(forKey: Key.motifs) as? [String: Int] ?? [:]).compactMapValues(ProfileMotif.init(rawValue:))
        swipeMode = defaults.string(forKey: Key.mode).flatMap(SwipeMode.init(rawValue:)) ?? .free
        if defaults.object(forKey: Key.sensitivity) != nil {
            sensitivity = min(max(defaults.double(forKey: Key.sensitivity), Self.sensitivityRange.lowerBound), Self.sensitivityRange.upperBound)
        }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(hidden.sorted(), forKey: Key.hidden)
        defaults.set(colors.mapValues(\.hexString), forKey: Key.colors)
        defaults.set(motifs.mapValues(\.rawValue), forKey: Key.motifs)
        defaults.set(swipeMode.rawValue, forKey: Key.mode)
        defaults.set(sensitivity, forKey: Key.sensitivity)
    }
}

extension ProfileColor {
    var hexString: String {
        let part = { (value: Double) in String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded())) }
        return "#" + part(red) + part(green) + part(blue)
    }

    init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
