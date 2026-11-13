import Foundation

/// How far one swipe can travel across the palette's places.
enum SwipeMode: String, CaseIterable {
    /// A flick carries on past the next place, as far as its speed takes it.
    case free
    /// One swipe moves at most one place, however fast it is.
    case single
}

/// What people chose for the places the palette swipes between: which are left out, the look they gave each over
/// the automatic one, and how swiping feels.
struct PlaceSettings: Equatable {
    static let sensitivityRange = 0.4...1.6
    /// A place's own color and the colors it blends into.
    static let colorLimit = 3
    static let strengthRange = 0.3...1.7
    static let textureRange = 0.0...2.0

    var hidden: Set<String> = []
    /// The first color is the place's own, on its dot and name; the rest are blended into its wash and badge.
    var colors: [String: [ProfileColor]] = [:]
    var motifs: [String: ProfileMotif] = [:]
    /// How strongly a place's colors wash the palette, where 1 is the usual wash.
    var strengths: [String: Double] = [:]
    /// How much pattern and grain a place shows, where 1 is the usual amount.
    var textures: [String: Double] = [:]
    var swipeMode = SwipeMode.free
    /// 1 is the default feel; lower needs more finger travel and carries a flick less far.
    var sensitivity = 1.0

    /// `state` with the chosen looks, without the hidden places. The place in front stays even when hidden, so the
    /// palette always shows where it is.
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
        if let chosen = colors[place.id], let first = chosen.first {
            place.color = first
            place.accents = Array(chosen.dropFirst().prefix(Self.colorLimit - 1))
        }
        if let motif = motifs[place.id] { place.motif = motif }
        if let strength = strengths[place.id] { place.strength = strength }
        if let texture = textures[place.id] { place.texture = texture }
        return place
    }

    /// Whether anything about the place's look was chosen rather than left to Tab Scout.
    func isCustom(_ id: String) -> Bool {
        colors[id] != nil || motifs[id] != nil || strengths[id] != nil || textures[id] != nil
    }

    /// Gives the place back the look Tab Scout picks.
    mutating func reset(_ id: String) {
        colors[id] = nil
        motifs[id] = nil
        strengths[id] = nil
        textures[id] = nil
    }

    // MARK: - Storage

    private enum Key {
        static let hidden = "HiddenPlaces"
        static let colors = "PlaceColors"
        static let motifs = "PlaceMotifs"
        static let strengths = "PlaceStrengths"
        static let textures = "PlaceTextures"
        static let mode = "SwipeMode"
        static let sensitivity = "SwipeSensitivity"
    }

    init() {}

    init(defaults: UserDefaults) {
        hidden = Set(defaults.stringArray(forKey: Key.hidden) ?? [])
        // A place's colors are kept as one text, "#6E63FF,#D946EF": a single color reads as it was stored before
        // places could blend several.
        colors = (defaults.dictionary(forKey: Key.colors) as? [String: String] ?? [:]).compactMapValues { text in
            let chosen = text.split(separator: ",").compactMap { ProfileColor(hexString: String($0)) }
            return chosen.isEmpty ? nil : Array(chosen.prefix(Self.colorLimit))
        }
        motifs = (defaults.dictionary(forKey: Key.motifs) as? [String: Int] ?? [:]).compactMapValues(ProfileMotif.init(rawValue:))
        let amounts = { (key: String, range: ClosedRange<Double>) in
            (defaults.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { min(max($0, range.lowerBound), range.upperBound) }
        }
        strengths = amounts(Key.strengths, Self.strengthRange)
        textures = amounts(Key.textures, Self.textureRange)
        swipeMode = defaults.string(forKey: Key.mode).flatMap(SwipeMode.init(rawValue:)) ?? .free
        if defaults.object(forKey: Key.sensitivity) != nil {
            sensitivity = min(max(defaults.double(forKey: Key.sensitivity), Self.sensitivityRange.lowerBound), Self.sensitivityRange.upperBound)
        }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(hidden.sorted(), forKey: Key.hidden)
        defaults.set(colors.mapValues { $0.map(\.hexString).joined(separator: ",") }, forKey: Key.colors)
        defaults.set(motifs.mapValues(\.rawValue), forKey: Key.motifs)
        defaults.set(strengths, forKey: Key.strengths)
        defaults.set(textures, forKey: Key.textures)
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
