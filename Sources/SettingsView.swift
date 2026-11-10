import AppKit
import SwiftUI

/// What the settings window shows and changes. The app delegate owns the behavior; it fills this in and is called
/// back through `actions`, then fills it in again, so a change it turns down, such as a cancelled alert, shows as
/// unchanged.
final class SettingsModel: ObservableObject {
    struct HistorySource: Identifiable, Equatable {
        let id: String
        let name: String
        let browser: String
        var enabled: Bool
        let unavailable: Bool
    }

    /// One thing Tab Scout needs or can use, as the Setup page lists it.
    struct SetupItem: Identifiable, Equatable {
        let id: SetupStep
        let title: String
        var detail: String
        /// Longer guidance shown on hover, such as how to add the Chrome extension.
        var help: String?
        var state: SetupState
        var action: String
        var actionEnabled = true
    }

    struct Actions {
        var setCapture: (Bool) -> Void = { _ in }
        var setLogin: (Bool) -> Void = { _ in }
        var setGoogle: (Bool) -> Void = { _ in }
        var setHistory: (Bool) -> Void = { _ in }
        var setHistorySource: (String, Bool) -> Void = { _, _ in }
        var setPageText: (Bool) -> Void = { _ in }
        var clearHistory: () -> Void = {}
        var runSetupStep: (SetupStep) -> Void = { _ in }
        var openSearch: () -> Void = {}
        var reloadPlaces: () -> Void = {}
        var placesChanged: (PlaceSettings) -> Void = { _ in }
    }

    @Published var capture = true
    @Published var login = false
    @Published var google = false
    @Published var history = false
    @Published var pageText = false
    @Published var historySources: [HistorySource] = []
    /// Shown instead of the history sources while there are none to list.
    @Published var historyNote: String?
    /// Every place the palette can swipe to, with the automatic colors and patterns.
    @Published var places: [BrowserProfile] = []
    @Published var placesNote: String?
    @Published var placeSettings = PlaceSettings() {
        didSet { if placeSettings != oldValue { actions.placesChanged(placeSettings) } }
    }
    @Published var page: SettingsPage? = .places
    @Published var setup: [SetupItem] = []
    @Published var ready = false
    /// What the Setup page's banner says, such as why a browser could not be reached.
    @Published var setupStatus = ""
    @Published var setupStatusHelp: String?
    @Published var version = ""
    @Published var ranking = ""
    var actions = Actions()

    /// Steps still to do while Cmd+T does not work yet, shown as a badge beside Setup. Once it works, a browser
    /// still without access is a choice rather than something missing.
    var missing: Int { ready ? 0 : setup.filter { $0.state == .needed || $0.state == .problem }.count }

    /// A binding that asks the app to make a change instead of making it.
    func request(_ value: KeyPath<SettingsModel, Bool>, _ action: @escaping (Actions) -> (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { self[keyPath: value] }, set: { [self] wanted in
            // Alerts the app shows in answer must not run inside SwiftUI's update.
            DispatchQueue.main.async { action(self.actions)(wanted) }
        })
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case setup, general, places, search, history

    var id: Self { self }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .general: return "General"
        case .places: return "Profiles & Swipe"
        case .search: return "Search"
        case .history: return "Browser History"
        }
    }

    var symbol: String {
        switch self {
        case .setup: return "checklist"
        case .general: return "gearshape"
        case .places: return "rectangle.stack.badge.person.crop"
        case .search: return "magnifyingglass"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $model.page) { page in
                Label(page.title, systemImage: page.symbol)
                    .badge(page == .setup ? model.missing : 0)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            ZStack {
                PlaceGlow(colors: model.places.map { model.placeSettings.styled($0).color })
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch model.page ?? .general {
                        case .setup: SetupPage(model: model)
                        case .general: GeneralPage(model: model)
                        case .places: PlacesPage(model: model)
                        case .search: SearchPage(model: model)
                        case .history: HistoryPage(model: model)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle((model.page ?? .general).title)
        }
        .frame(minWidth: 700, minHeight: 520)
    }
}

// MARK: - Pages

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        GlassSection("Shortcut", footer: "While off, Cmd+T opens a new tab as usual.") {
            Toggle("Capture Cmd+T in Safari and Chrome", isOn: model.request(\.capture) { $0.setCapture })
        }
        GlassSection("Startup") {
            Toggle("Start at Login", isOn: model.request(\.login) { $0.setLogin })
        }
        GlassSection("About") {
            LabeledRow("Version") { Text(model.version).textSelection(.enabled).foregroundStyle(.secondary) }
            LabeledRow("Ranking") { Text(model.ranking).foregroundStyle(.secondary) }
        }
    }
}

private struct SetupPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(model.ready ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.ready ? "Ready" : model.missing == 1 ? "1 step left" : model.missing > 1 ? "\(model.missing) steps left" : "Not ready yet").font(.title3.weight(.semibold))
                Text(model.setupStatus).foregroundStyle(.secondary).help(model.setupStatusHelp ?? "")
            }
            Spacer()
            GlassButton("Open Search", symbol: "magnifyingglass") { model.actions.openSearch() }
        }
        .padding(18)
        .glassCard(tint: model.ready ? ProfileColor(hex: 0x34C759) : ProfileColor(hex: 0xFF9F0A), cornerRadius: 20)
        GlassSection("Steps", footer: "Each step ticks itself off once it is done, also when you do it in System Settings or Chrome.") {
            ForEach(model.setup) { item in
                SetupRowView(model: model, item: item)
                if item.id != model.setup.last?.id { Divider() }
            }
        }
    }
}

private struct SetupRowView: View {
    @ObservedObject var model: SettingsModel
    let item: SettingsModel.SetupItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.state.symbol)
                .font(.system(size: 17))
                .foregroundStyle(item.state.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium))
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if item.id == .history && model.history {
                    Button("Choose history sources") { model.page = .history }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .help(item.help ?? "")
            Spacer(minLength: 12)
            GlassButton(item.action) { model.actions.runSetupStep(item.id) }
                .disabled(!item.actionEnabled)
        }
        .padding(.vertical, 2)
    }
}

/// The steps of setup, in order. Cmd+T needs the keyboard step and at least one browser.
enum SetupStep: CaseIterable {
    case keyboard, safari, chrome, chromeExtension, history

    init(_ browser: Browser) {
        switch browser {
        case .safari: self = .safari
        case .chrome: self = .chrome
        }
    }
}

/// How far a setup step is, shown by the icon before its name.
enum SetupState {
    case done, needed, optional, waiting, problem, unavailable

    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .needed: return "circle"
        case .optional: return "circle.dashed"
        case .waiting: return "clock"
        case .problem: return "exclamationmark.circle.fill"
        case .unavailable: return "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .done: return .green
        case .needed, .waiting: return .accentColor
        case .optional, .unavailable: return .secondary
        case .problem: return .orange
        }
    }
}

private struct SearchPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        GlassSection("Suggestions",
                     footer: "Typed search text is sent to Google for generic suggestions. Local history is never sent.") {
            Toggle("Google Suggestions", isOn: model.request(\.google) { $0.setGoogle })
        }
        GlassSection("Page text",
                     footer: "Reads the visible text of pages you have looked at for a few seconds, so typing finds tabs that mention your words. It stays in memory on this Mac. Chrome needs View › Developer › Allow JavaScript from Apple Events.") {
            Toggle("Search Page Text", isOn: model.request(\.pageText) { $0.setPageText })
        }
        GlassSection("Tab Scout history",
                     footer: "Removes searches and tab choices Tab Scout saved, and what it learned from them. Browsers' own history is not changed.") {
            HStack {
                Text("Searches and picks")
                Spacer()
                GlassButton("Clear History…", role: .destructive) { model.actions.clearHistory() }
            }
        }
    }
}

private struct HistoryPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        GlassSection("Browser history", footer: "Pages you visited before are offered when no open tab matches.") {
            Toggle("Use Browser History", isOn: model.request(\.history) { $0.setHistory })
        }
        GlassSection("Sources", footer: model.history ? "Turn off a profile to leave its history out of results." : nil) {
            if !model.history {
                Text("Turn on Use Browser History to choose its sources.").foregroundStyle(.secondary)
            } else if let note = model.historyNote {
                Text(note).foregroundStyle(.secondary)
            } else {
                ForEach(model.historySources) { source in
                    Toggle(isOn: Binding(get: { source.enabled }, set: { wanted in
                        DispatchQueue.main.async { model.actions.setHistorySource(source.id, wanted) }
                    })) {
                        HStack(spacing: 8) {
                            Image(systemName: source.browser == "safari" ? "safari" : "globe")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(source.name)
                            if source.unavailable {
                                Text("Unavailable").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    if source.id != model.historySources.last?.id { Divider() }
                }
            }
        }
    }
}

private struct PlacesPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        GlassSection("Swipe", footer: footer) {
            Picker("A swipe moves", selection: $model.placeSettings.swipeMode) {
                Text("As far as it carries").tag(SwipeMode.free)
                Text("One place at a time").tag(SwipeMode.single)
            }
            .pickerStyle(.segmented)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Text(sensitivityLabel).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $model.placeSettings.sensitivity, in: PlaceSettings.sensitivityRange) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
                .onTapGesture(count: 2) { model.placeSettings.sensitivity = 1 }
            }
        }
        HStack(alignment: .firstTextBaseline) {
            Text("Places").font(.headline)
            Spacer()
            GlassButton("Refresh", symbol: "arrow.clockwise") { model.actions.reloadPlaces() }
        }
        .padding(.horizontal, 4)
        if let note = model.placesNote {
            Text(note).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
        ForEach(model.places, id: \.id) { place in
            PlaceCard(model: model, place: place)
        }
        Text("Hidden places are skipped when swiping. The browser and profile you are in always shows.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private var footer: String {
        switch model.placeSettings.swipeMode {
        case .free: return "A quick flick can skip over places. Lower the sensitivity if it goes too far."
        case .single: return "Each swipe stops at the next place, however fast. Sensitivity sets how far to swipe."
        }
    }

    private var sensitivityLabel: String {
        let value = model.placeSettings.sensitivity
        return abs(value - 1) < 0.05 ? "Default" : String(format: "%.0f%%", value * 100)
    }
}

private struct PlaceCard: View {
    @ObservedObject var model: SettingsModel
    let place: BrowserProfile

    private var styled: BrowserProfile { model.placeSettings.styled(place) }
    private var shown: Bool { !model.placeSettings.hidden.contains(place.id) }
    private var customized: Bool { model.placeSettings.colors[place.id] != nil || model.placeSettings.motifs[place.id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: ProfileArt.badge(styled, diameter: 36))
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.headline)
                    Text(place.browser == .safari ? "Browser" : place.name == "Chrome" ? "All Chrome windows" : "Chrome profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show", isOn: Binding(get: { shown }, set: { show in
                    if show { model.placeSettings.hidden.remove(place.id) } else { model.placeSettings.hidden.insert(place.id) }
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(shown ? "Shown when swiping" : "Skipped when swiping")
            }
            if shown {
                HStack(spacing: 8) {
                    Text("Color").font(.subheadline).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    ForEach(ProfilePalette.colors, id: \.hexString) { color in
                        Swatch(color: color, selected: styled.color == color) { model.placeSettings.colors[place.id] = color }
                    }
                    ColorPicker("Custom color", selection: Binding(get: { Color(nsColor: styled.color.nsColor) }, set: { picked in
                        guard let rgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
                        model.placeSettings.colors[place.id] = ProfileColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                    }), supportsOpacity: false)
                    .labelsHidden()
                    .help("Pick any color")
                }
                HStack(spacing: 8) {
                    Text("Pattern").font(.subheadline).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    ForEach(ProfileMotif.allCases, id: \.self) { motif in
                        MotifChip(place: styled, motif: motif, selected: styled.motif == motif) {
                            model.placeSettings.motifs[place.id] = motif
                        }
                    }
                    Spacer()
                    if customized {
                        GlassButton("Automatic", symbol: "arrow.uturn.backward") {
                            model.placeSettings.colors[place.id] = nil
                            model.placeSettings.motifs[place.id] = nil
                        }
                        .help("Go back to the color and pattern Tab Scout picks")
                    }
                }
            }
        }
        .padding(16)
        .opacity(shown ? 1 : 0.6)
        .glassCard(tint: styled.color, cornerRadius: 20)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: shown)
    }
}

// MARK: - Pieces

private struct Swatch: View {
    let color: ProfileColor
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            Circle()
                .fill(Color(nsColor: color.nsColor).gradient)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.25), lineWidth: selected ? 2 : 0.5))
                .padding(2)
                .overlay(Circle().strokeBorder(Color(nsColor: color.nsColor).opacity(selected ? 0.9 : 0), lineWidth: 1.5))
                .scaleEffect(selected ? 1.12 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
        .help(color.hexString)
    }
}

private struct MotifChip: View {
    let place: BrowserProfile
    let motif: ProfileMotif
    let selected: Bool
    let pick: () -> Void

    /// The pattern alone, without an account picture, symbol or initial over it.
    private var sample: BrowserProfile {
        BrowserProfile(id: place.id + "#" + motif.name, browser: place.browser, name: " ", menuTitle: nil, directory: nil,
                       color: place.color, motif: motif, picture: nil)
    }

    var body: some View {
        Button(action: pick) {
            Image(nsImage: ProfileArt.badge(sample, diameter: 28))
                .padding(2)
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(selected ? 1 : 0), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(motif.name)
    }
}

extension ProfileMotif {
    var name: String {
        switch self {
        case .strands: return "Strands"
        case .dots: return "Dots"
        case .waves: return "Waves"
        case .rings: return "Ripples"
        case .weave: return "Weave"
        }
    }
}

private struct GlassSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(tint: nil, cornerRadius: 18)
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            content
        }
    }
}

private struct GlassButton: View {
    let title: String
    var symbol: String?
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.action = action
    }

    var body: some View {
        let button = Button(role: role, action: action) {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
        #else
        button.buttonStyle(.bordered)
        #endif
    }
}

/// Soft washes of the places' colors behind the glass, as the palette glows with its profile's color.
private struct PlaceGlow: View {
    let colors: [ProfileColor]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { index, color in
                    Circle()
                        .fill(Color(nsColor: color.nsColor).opacity(scheme == .dark ? 0.32 : 0.22))
                        .frame(width: geometry.size.width * 0.6)
                        .blur(radius: 80)
                        .offset(x: geometry.size.width * (index.isMultiple(of: 2) ? -0.25 : 0.3),
                                y: geometry.size.height * (CGFloat(index) * 0.3 - 0.35))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension View {
    /// Liquid Glass on macOS 26 and later, a material card before it.
    @ViewBuilder
    func glassCard(tint: ProfileColor?, cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint(Color(nsColor: $0.nsColor).opacity(0.18)) } ?? .regular
            self.glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            materialCard(cornerRadius: cornerRadius)
        }
        #else
        materialCard(cornerRadius: cornerRadius)
        #endif
    }

    func materialCard(cornerRadius: CGFloat) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}
