import AppKit
import SwiftUI

/// Everything about one place's look: its colors as dots to drag over a field, ready-made colors and blends, how
/// strongly it washes the palette, how much pattern and grain it carries and which pattern. A strip of the
/// palette's top shows the result as it changes.
struct ThemeEditor: View {
    @ObservedObject var model: SettingsModel
    /// The place as Tab Scout shows it by itself, before anything people chose.
    let place: BrowserProfile
    /// Which of the place's colors the swatches and the color well change.
    @State private var selection = 0
    @State private var page = 0
    /// The harmony the colors were last set to, until they are changed another way.
    @State private var harmony: ColorHarmony?

    private var styled: BrowserProfile { model.placeSettings.styled(place) }
    private var colors: [ProfileColor] { [styled.color] + styled.accents }
    private var selected: Int { min(selection, colors.count - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ThemePreview(place: styled)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    ColorFieldView(colors: colors, selection: selected, pick: { selection = $0 }, change: { index, color in
                        var next = colors
                        next[index] = color
                        set(next)
                    })
                    .frame(minWidth: 170)
                    .frame(height: 150)
                    dotButtons
                }
                VStack(alignment: .leading, spacing: 14) {
                    AmountSlider(title: "Strength", value: amount(\.strengths), range: PlaceSettings.strengthRange,
                                 low: "sun.min", high: "sun.max.fill")
                        .help("How strongly the colors wash the palette")
                    AmountSlider(title: "Texture", value: amount(\.textures), range: PlaceSettings.textureRange,
                                 low: "aqi.low", high: "aqi.medium")
                        .help("How much pattern and grain show")
                    patterns
                }
                .frame(width: 212)
            }
            presets
        }
    }

    // MARK: - Colors

    private func set(_ colors: [ProfileColor], in harmony: ColorHarmony? = nil) {
        model.placeSettings.colors[place.id] = Array(colors.prefix(PlaceSettings.colorLimit))
        self.harmony = harmony
    }

    /// Sets the other colors around the first in the harmony after the last one used. With a single color, a
    /// harmony brings its second.
    private func harmonize() {
        let all = ColorHarmony.allCases
        let next = all[((harmony.flatMap(all.firstIndex(of:)) ?? -1) + 1) % all.count]
        set(next.arranged(colors.count > 1 ? colors : colors + colors), in: next)
    }

    private func replaceSelected(with color: ProfileColor) {
        var next = colors
        next[selected] = color
        set(next)
    }

    private var dotButtons: some View {
        HStack(spacing: 6) {
            DotButton(title: "Add a color for the wash to blend into", symbol: "plus") {
                let next = colors + [ColorHarmony.added(to: colors)]
                set(next)
                selection = next.count - 1
            }
            .disabled(colors.count >= PlaceSettings.colorLimit)
            DotButton(title: "Remove the selected color", symbol: "minus") {
                var next = colors
                // The first color is the place's own and stays.
                next.remove(at: selected > 0 ? selected : next.count - 1)
                set(next)
                selection = min(selected, next.count - 1)
            }
            .disabled(colors.count < 2)
            DotButton(title: "Set the other colors around the first on the color wheel. Each press tries another harmony.",
                      symbol: "point.3.connected.trianglepath.dotted", action: harmonize)
            if let harmony {
                Text(harmony.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(colors[selected].hexString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .controlSize(.small)
    }

    private func isChosen(_ theme: [ProfileColor]) -> Bool {
        // By their hex, as colors are stored: a stored color is rounded to it.
        theme.count > 1 ? colors.map(\.hexString) == theme.map(\.hexString) : colors[selected].hexString == theme.first?.hexString
    }

    private var presets: some View {
        let pages = ThemePresets.pages
        return HStack(spacing: 6) {
            PageButton(symbol: "chevron.left", title: "Earlier colors") { page = (page + pages.count - 1) % pages.count }
            Text(pages[page].name).font(.caption).foregroundStyle(.secondary).frame(width: 40)
            ForEach(Array(pages[page].themes.enumerated()), id: \.offset) { _, theme in
                Swatch(colors: theme, selected: isChosen(theme)) {
                    if theme.count > 1 {
                        set(theme)
                        selection = 0
                    } else if let color = theme.first {
                        replaceSelected(with: color)
                    }
                }
            }
            PageButton(symbol: "chevron.right", title: "More colors") { page = (page + 1) % pages.count }
            Spacer(minLength: 8)
            ColorPicker("Any color", selection: Binding(get: { Color(nsColor: colors[selected].nsColor) }, set: { picked in
                guard let rgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
                replaceSelected(with: ProfileColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent))
            }), supportsOpacity: false)
            .labelsHidden()
            .help("Pick any color for the selected dot")
        }
    }

    // MARK: - Strength, texture and pattern

    /// One of the place's amounts, where 1 is what Tab Scout uses by itself and is not kept as a choice.
    private func amount(_ amounts: WritableKeyPath<PlaceSettings, [String: Double]>) -> Binding<Double> {
        Binding(get: { model.placeSettings[keyPath: amounts][place.id] ?? 1 },
                set: { model.placeSettings[keyPath: amounts][place.id] = abs($0 - 1) < 0.03 ? nil : $0 })
    }

    private var patterns: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pattern").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(ProfileMotif.allCases, id: \.self) { motif in
                    MotifChip(place: styled, motif: motif, selected: styled.motif == motif) {
                        model.placeSettings.motifs[place.id] = motif
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

/// The field of colors with a dot for each of the place's colors, the first one larger. A dot follows a drag; a
/// press elsewhere brings the selected dot there.
private struct ColorFieldView: View {
    /// Room around the colors, so a dot at an edge still shows whole.
    private static let inset: CGFloat = 16
    let colors: [ProfileColor]
    let selection: Int
    let pick: (Int) -> Void
    let change: (Int, ProfileColor) -> Void
    @State private var dragging: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.black.opacity(scheme == .dark ? 0.3 : 0.06)
                // The colors show faintly throughout and fully in a grid of dots.
                Spectrum(inset: Self.inset).opacity(0.3)
                Spectrum(inset: Self.inset).mask(DotGrid())
                // Drawn last, the first color's dot stays on top.
                ForEach(Array(colors.enumerated()).reversed(), id: \.offset) { index, color in
                    ColorDot(color: color, first: index == 0, selected: index == selection)
                        .position(position(of: color, in: size))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let index = dragging ?? grabbed(at: value.startLocation, in: size)
                    if dragging == nil {
                        dragging = index
                        pick(index)
                    }
                    change(index, color(at: value.location, in: size))
                }
                .onEnded { _ in dragging = nil })
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colors")
        .accessibilityValue(colors.map(\.hexString).joined(separator: ", "))
    }

    private func position(of color: ProfileColor, in size: CGSize) -> CGPoint {
        let point = ColorField.point(for: color)
        return CGPoint(x: Self.inset + point.x * (size.width - Self.inset * 2), y: Self.inset + point.y * (size.height - Self.inset * 2))
    }

    private func color(at location: CGPoint, in size: CGSize) -> ProfileColor {
        ColorField.color(x: (location.x - Self.inset) / max(size.width - Self.inset * 2, 1),
                         y: (location.y - Self.inset) / max(size.height - Self.inset * 2, 1))
    }

    /// The dot under a press, or the selected one, which then comes to the press.
    private func grabbed(at location: CGPoint, in size: CGSize) -> Int {
        let distance = { (index: Int) -> CGFloat in
            let point = position(of: colors[index], in: size)
            return hypot(point.x - location.x, point.y - location.y)
        }
        guard let nearest = colors.indices.min(by: { distance($0) < distance($1) }), distance(nearest) <= 20 else {
            return min(selection, colors.count - 1)
        }
        return nearest
    }
}

/// Every color of `ColorField`, laid out as the field maps them.
private struct Spectrum: View {
    let inset: CGFloat

    var body: some View {
        GeometryReader { geometry in
            // The colors start and end `inset` inside; the gradients carry their end colors on to the edges.
            let x = inset / max(geometry.size.width, 1)
            let y = inset / max(geometry.size.height, 1)
            ZStack {
                LinearGradient(colors: stride(from: 0.0, through: 360, by: 60).map { Color(nsColor: ProfileColor(hue: $0, saturation: 1, brightness: 1).nsColor) },
                               startPoint: UnitPoint(x: x, y: 0.5), endPoint: UnitPoint(x: 1 - x, y: 0.5))
                LinearGradient(stops: [.init(color: .white.opacity(1 - ColorField.paleSaturation), location: 0),
                                       .init(color: .white.opacity(0), location: 0.5),
                                       .init(color: .black.opacity(0), location: 0.5),
                                       .init(color: .black.opacity(1 - ColorField.deepBrightness), location: 1)],
                               startPoint: UnitPoint(x: 0.5, y: y), endPoint: UnitPoint(x: 0.5, y: 1 - y))
            }
        }
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let pitch: CGFloat = 7
            var dots = Path()
            var y = pitch / 2
            while y < size.height {
                var x = pitch / 2
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                    x += pitch
                }
                y += pitch
            }
            context.fill(dots, with: .color(.white))
        }
    }
}

private struct ColorDot: View {
    let color: ProfileColor
    let first: Bool
    let selected: Bool

    var body: some View {
        let size: CGFloat = first ? 28 : 20
        Circle()
            .fill(Color(nsColor: color.nsColor))
            .overlay(Circle().strokeBorder(.white.opacity(selected ? 1 : 0.85), lineWidth: selected ? 3 : 2))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.4), radius: selected ? 5 : 3, y: 1)
            .scaleEffect(selected ? 1.12 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
    }
}

/// The top of the palette as the place colors it: its wash, pattern and grain behind the search field, and its
/// name at the end.
private struct ThemePreview: View {
    /// The search field's row and how far down the palette's wash reaches.
    private static let header: CGFloat = 58
    private static let depth: CGFloat = 250
    let place: BrowserProfile
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    /// As wide as the palette makes the pill for this name.
    private var pillWidth: CGFloat {
        let name = (place.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        return 4 + 22 + 7 + min(ceil(name), 132) + 12
    }

    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        GeometryReader { geometry in
            let width = geometry.size.width
            // The wash glows from behind the badge, as in the palette.
            let focus = CGPoint(x: width - 14 - pillWidth + 15, y: Self.depth - Self.header / 2)
            ZStack(alignment: .top) {
                // Plain gray stands in for the palette's glass.
                Color(white: dark ? 0.2 : 0.93)
                if let wash = ProfileArt.aura(place, size: CGSize(width: width, height: Self.depth), focus: focus, scale: displayScale, dark: dark) {
                    Image(decorative: wash, scale: displayScale)
                        .frame(width: width, height: geometry.size.height, alignment: .top)
                }
                VStack(spacing: 0) {
                    searchRow(dark: dark).frame(height: Self.header)
                    Divider()
                    resultRow.padding(.top, 12)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 104)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("How the palette looks in \(place.name)")
    }

    private func searchRow(dark: Bool) -> some View {
        let tint = Color(nsColor: place.color.nsColor)
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 19)).foregroundStyle(.secondary)
            Text("Search tabs or enter an address").font(.system(size: 19)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Image(nsImage: ProfileArt.badge(place, diameter: 22))
                Text(place.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .frame(width: pillWidth, height: 30)
            .background(Capsule().fill(tint.opacity(dark ? 0.26 : 0.16)))
            .overlay(Capsule().strokeBorder(tint.opacity(dark ? 0.55 : 0.42), lineWidth: 1))
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
    }

    /// A result, as bars where its icon, title and address go.
    private var resultRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.22)).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(.primary.opacity(0.3)).frame(width: 170, height: 7)
                Capsule().fill(.primary.opacity(0.16)).frame(width: 110, height: 6)
            }
            Spacer()
        }
        .padding(.leading, 26)
    }
}

/// A slider for an amount around 1, which a double click goes back to.
private struct AmountSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(abs(value - 1) < 0.03 ? "Default" : String(format: "%.0f%%", value * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: low).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: high).foregroundStyle(.secondary)
            }
            .labelsHidden()
            .controlSize(.small)
            .onTapGesture(count: 2) { value = 1 }
        }
    }
}

/// A small button under the field, the same size whatever its symbol.
private struct DotButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 14, height: 14)
        }
        .glassButton()
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct PageButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
