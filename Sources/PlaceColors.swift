import Foundation

/// The field a place's colors are picked from. Hue runs across it. From top to bottom a color goes from pale,
/// through vivid at the middle, to deep.
enum ColorField {
    /// The saturation left at the top edge.
    static let paleSaturation = 0.3
    /// The brightness left at the bottom edge.
    static let deepBrightness = 0.42

    /// The color at a point of the field, both coordinates from 0 to 1, `y` downward.
    static func color(x: Double, y: Double) -> ProfileColor {
        // Short of the right edge, where the hue would wrap around to the left edge's.
        let x = min(max(x, 0), 0.999)
        let y = min(max(y, 0), 1)
        return ProfileColor(hue: x * 360,
                            saturation: y < 0.5 ? paleSaturation + (1 - paleSaturation) * y * 2 : 1,
                            brightness: y < 0.5 ? 1 : 1 - (1 - deepBrightness) * (y - 0.5) * 2)
    }

    /// Where a color sits on the field. A color both paler and deeper than the field holds sits where the stronger
    /// of the two puts it.
    static func point(for color: ProfileColor) -> (x: Double, y: Double) {
        let pale = min((1 - color.saturation) / (1 - paleSaturation), 1)
        let deep = min((1 - color.brightness) / (1 - deepBrightness), 1)
        return (color.hue / 360, deep > pale ? 0.5 + deep / 2 : 0.5 - pale / 2)
    }
}

/// Ways a place's further colors can sit around its first on the color wheel.
enum ColorHarmony: CaseIterable {
    case analogous, triad, split, complement

    var name: String {
        switch self {
        case .analogous: return "Neighbors"
        case .triad: return "Triad"
        case .split: return "Split"
        case .complement: return "Opposite"
        }
    }

    /// How far around the wheel the second and third colors sit from the first, in degrees.
    var turns: [Double] {
        switch self {
        case .analogous: return [40, -40]
        case .triad: return [120, 240]
        case .split: return [150, 210]
        case .complement: return [180, 40]
        }
    }

    /// `colors` with every color after the first turned to its place around the first. Each keeps how pale or deep
    /// it was.
    func arranged(_ colors: [ProfileColor]) -> [ProfileColor] {
        guard let first = colors.first else { return colors }
        return [first] + colors.dropFirst().enumerated().map { index, color in
            ProfileColor(hue: first.hue + turns[index % turns.count], saturation: color.saturation, brightness: color.brightness)
        }
    }

    /// One more color for `colors`: a neighbor of the first, clear of the colors already there.
    static func added(to colors: [ProfileColor]) -> ProfileColor {
        guard let first = colors.first else { return ProfilePalette.colors[0] }
        let near = [40.0, -40, 80, -80].map { ProfileColor(hue: first.hue + $0, saturation: first.saturation, brightness: first.brightness) }
        return near.first { color in colors.allSatisfy { $0.hueDistance(to: color) >= 20 } } ?? near[0]
    }
}

/// Ready-made looks to pick from, a page at a time.
enum ThemePresets {
    struct Page {
        let name: String
        /// Single colors, or blends of two or three with the place's own color first.
        let themes: [[ProfileColor]]
    }

    static let pages: [Page] = [
        Page(name: "Vivid", themes: ProfilePalette.colors.map { [$0] }),
        Page(name: "Soft", themes: ProfilePalette.colors.map { [ProfileColor(hue: $0.hue, saturation: 0.46, brightness: 1)] }),
        Page(name: "Deep", themes: ProfilePalette.colors.map { [ProfileColor(hue: $0.hue, saturation: 0.92, brightness: 0.62)] }),
        // Dusk, ocean, aurora, meadow, citrus, sunset, candy and peach.
        Page(name: "Blends", themes: [[0x6E63FF, 0xD946EF], [0x3B8CF6, 0x14B8A6], [0x14B8A6, 0x6E63FF, 0xD946EF], [0x7CB518, 0x14B8A6],
                                      [0xF5A524, 0x7CB518], [0xFF7A45, 0xF43F5E, 0xF5A524], [0xF43F5E, 0xD946EF], [0xFF7A45, 0xF5A524]]
            .map { $0.map(ProfileColor.init(hex:)) })
    ]
}
