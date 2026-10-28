import AppKit

extension ProfileColor {
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1) }

    func mixed(with other: ProfileColor, _ share: Double) -> ProfileColor {
        let share = min(max(share, 0), 1)
        return ProfileColor(red: red + (other.red - red) * share, green: green + (other.green - green) * share,
                            blue: blue + (other.blue - blue) * share)
    }

    /// The color lit differently: its hue turned by degrees, its saturation and brightness scaled.
    func lit(hue turn: Double = 0, saturation: Double = 1, brightness: Double = 1) -> NSColor {
        let hue = ((self.hue + turn).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return NSColor(hue: CGFloat(hue / 360), saturation: CGFloat(min(self.saturation * saturation, 1)),
                       brightness: CGFloat(min(self.brightness * brightness, 1)), alpha: 1)
    }
}

private extension NSView {
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// The images that give each profile its look: a lit disc of its color woven with its pattern, and a wash of it for
/// the top of the palette. Both carry fine grain, so the color reads as a material rather than a flat fill.
enum ProfileArt {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static var grains: [String: CGImage] = [:]
    private static var badges: [String: NSImage] = [:]

    /// Light and dark specks, mostly faint, the same every time.
    static func grain(width: Int, height: Int) -> CGImage? {
        let key = "\(width)x\(height)"
        if let cached = grains[key] { return cached }
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 0x2545_F491
        func next() -> Double {
            seed ^= seed << 13
            seed ^= seed >> 17
            seed ^= seed << 5
            return Double(seed) / Double(UInt32.max)
        }
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            // Two draws averaged make most specks faint and a few strong, like film grain.
            let value = (next() + next()) / 2
            let alpha = UInt8(min(abs(value - 0.5) * 2, 1) * 255)
            let light = value > 0.5 ? alpha : 0
            pixels[offset] = light
            pixels[offset + 1] = light
            pixels[offset + 2] = light
            pixels[offset + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        if grains.count > 8 { grains.removeAll() }
        grains[key] = image
        return image
    }

    /// Draws into a new bitmap `size` points large at `scale` pixels per point, with the origin at the bottom left.
    static func render(_ size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(context)
        return context.makeImage()
    }

    /// Draws `motif` over `rect` in the context's stroke and fill colors, `spacing` apart. Rings spread from `center`.
    static func draw(_ motif: ProfileMotif, in context: CGContext, rect: CGRect, spacing: CGFloat, line: CGFloat, center: CGPoint) {
        context.setLineWidth(line)
        context.setLineCap(.round)
        func diagonals(rising: Bool, spacing: CGFloat) {
            var offset = -rect.height
            while offset < rect.width + rect.height {
                let x = rect.minX + offset
                context.move(to: CGPoint(x: x, y: rising ? rect.minY : rect.maxY))
                context.addLine(to: CGPoint(x: x + rect.height, y: rising ? rect.maxY : rect.minY))
                offset += spacing
            }
        }
        switch motif {
        case .strands:
            // Fine threads running one way, like brushed silk.
            diagonals(rising: true, spacing: spacing * 0.7)
            context.strokePath()
        case .dots:
            var row = 0
            var y = rect.minY
            while y < rect.maxY + spacing {
                var x = rect.minX + (row % 2 == 0 ? 0 : spacing / 2)
                while x < rect.maxX + spacing {
                    context.addEllipse(in: CGRect(x: x - line, y: y - line, width: line * 2, height: line * 2))
                    x += spacing
                }
                y += spacing * 0.866
                row += 1
            }
            context.fillPath()
        case .waves:
            var y = rect.minY
            while y < rect.maxY + spacing {
                context.move(to: CGPoint(x: rect.minX, y: y))
                var x = rect.minX
                while x < rect.maxX {
                    x += max(spacing / 8, 0.5)
                    context.addLine(to: CGPoint(x: x, y: y + sin(x / spacing * .pi) * spacing * 0.24))
                }
                y += spacing * 0.8
            }
            context.strokePath()
        case .rings:
            // Ripples spreading from one point, like a stone dropped in water.
            let reach = hypot(max(abs(center.x - rect.minX), abs(rect.maxX - center.x)), max(abs(center.y - rect.minY), abs(rect.maxY - center.y)))
            var radius = spacing * 0.8
            while radius < reach {
                context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                radius += spacing * 0.8
            }
            context.strokePath()
        case .weave:
            // Threads crossing both ways, like linen.
            diagonals(rising: true, spacing: spacing)
            diagonals(rising: false, spacing: spacing)
            context.strokePath()
        }
    }

    /// A disc of the profile's color lit from the top left, woven with its pattern, holding its initial or the
    /// account's picture.
    static func badge(_ profile: BrowserProfile, diameter: CGFloat) -> NSImage {
        let key = "\(profile.id)|\(profile.name)|\(profile.color)|\(diameter)"
        if let cached = badges[key] { return cached }
        let picture = profile.picture.flatMap { NSImage(contentsOf: $0) }
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let disc = rect.insetBy(dx: 0.5, dy: 0.5)
            context.saveGState()
            context.addEllipse(in: disc)
            context.clip()
            let colors = [profile.color.lit(hue: -14, saturation: 0.78, brightness: 1.25), profile.color.nsColor,
                          profile.color.lit(hue: 14, saturation: 1.12, brightness: 0.66)].map(\.cgColor) as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.48, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
            }
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.26).cgColor)
            context.setFillColor(NSColor.white.withAlphaComponent(0.32).cgColor)
            draw(profile.motif, in: context, rect: disc, spacing: diameter / 4.5, line: max(diameter / 36, 0.5),
                 center: CGPoint(x: disc.maxX, y: disc.minY))
            if let grain = grain(width: 96, height: 96) {
                context.setBlendMode(.overlay)
                context.setAlpha(0.7)
                context.draw(grain, in: disc)
                context.setAlpha(1)
                context.setBlendMode(.normal)
            }
            let sheen = CGPoint(x: disc.minX + disc.width * 0.3, y: disc.maxY - disc.height * 0.25)
            if let gradient = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.42).cgColor,
                                                                      NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
                context.drawRadialGradient(gradient, startCenter: sheen, startRadius: 0, endCenter: sheen, endRadius: diameter * 0.62, options: [])
            }
            context.restoreGState()
            if let picture {
                let inner = disc.insetBy(dx: diameter * 0.11, dy: diameter * 0.11)
                context.saveGState()
                context.addEllipse(in: inner)
                context.clip()
                picture.draw(in: inner)
                context.restoreGState()
            } else {
                let font = NSFont.systemFont(ofSize: (diameter * 0.48).rounded(), weight: .bold)
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
                shadow.shadowOffset = NSSize(width: 0, height: -0.5)
                shadow.shadowBlurRadius = 1.2
                let text = NSAttributedString(string: profile.initial, attributes: [.font: font, .foregroundColor: NSColor.white, .shadow: shadow])
                let width = text.size().width
                // Centers the capital letter itself rather than its line, which leaves room for descenders.
                text.draw(at: NSPoint(x: rect.midX - width / 2, y: rect.midY - font.capHeight / 2 + font.descender))
            }
            context.setLineWidth(0.75)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.38).cgColor)
            context.strokeEllipse(in: disc.insetBy(dx: 0.7, dy: 0.7))
            context.setLineWidth(0.5)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
            context.strokeEllipse(in: disc)
            return true
        }
        if badges.count > 32 { badges.removeAll() }
        badges[key] = image
        return image
    }

    /// The wash for the top of the palette: the profile's color fading downward, a glow around `focus` where the
    /// profile is named, its pattern faintly around the glow, and grain wherever there is color.
    static func aura(_ profile: BrowserProfile, size: CGSize, focus: CGPoint, scale: CGFloat, dark: Bool) -> CGImage? {
        render(size, scale: scale) { context in
            let strength: CGFloat = dark ? 0.34 : 0.24
            let base = profile.color.nsColor
            let top = CGPoint(x: 0, y: size.height)
            let bottom = CGPoint.zero
            if let wash = CGGradient(colorsSpace: space, colors: [strength, strength * 0.55, strength * 0.18, 0]
                .map { base.withAlphaComponent($0).cgColor } as CFArray, locations: [0, 0.24, 0.58, 1]) {
                context.drawLinearGradient(wash, start: top, end: bottom, options: [])
            }
            let light = profile.color.lit(hue: -8, saturation: 0.85, brightness: 1.3)
            if let glow = CGGradient(colorsSpace: space, colors: [light.withAlphaComponent(strength * 1.05).cgColor,
                                                                  light.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
                context.drawRadialGradient(glow, startCenter: focus, startRadius: 0, endCenter: focus, endRadius: 250, options: [])
            }
            let fade = { (inner: CGFloat, outer: CGFloat) in
                if let gradient = CGGradient(colorsSpace: space, colors: [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray,
                                             locations: [0, 1]) {
                    // Drawn beyond both ends too, so the clear outer edge also clears everything outside it.
                    context.drawRadialGradient(gradient, startCenter: focus, startRadius: inner, endCenter: focus, endRadius: outer,
                                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
            // The pattern shows around the glow and fades out before the results.
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let thread = dark ? profile.color.lit(saturation: 0.55, brightness: 1.5).withAlphaComponent(0.2)
                : profile.color.lit(saturation: 1.1, brightness: 0.6).withAlphaComponent(0.2)
            context.setStrokeColor(thread.cgColor)
            context.setFillColor(thread.cgColor)
            draw(profile.motif, in: context, rect: CGRect(origin: .zero, size: size), spacing: 14, line: 0.8, center: focus)
            context.setBlendMode(.destinationIn)
            fade(40, 300)
            if let downward = CGGradient(colorsSpace: space, colors: [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray,
                                         locations: [0.2, 0.8]) {
                context.drawLinearGradient(downward, start: top, end: bottom, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.endTransparencyLayer()
            context.restoreGState()
            if let grain = grain(width: Int(size.width * scale), height: Int(size.height * scale)) {
                context.saveGState()
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.setAlpha(dark ? 0.2 : 0.16)
                context.draw(grain, in: CGRect(origin: .zero, size: size))
                context.setAlpha(1)
                context.setBlendMode(.destinationIn)
                if let shape = CGGradient(colorsSpace: space, colors: [1, 0.55, 0].map { NSColor.black.withAlphaComponent($0).cgColor } as CFArray,
                                          locations: [0, 0.35, 0.85]) {
                    context.drawLinearGradient(shape, start: top, end: bottom, options: [])
                }
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
    }
}

/// The current profile's color washed across the top of the palette, glowing where the profile is named. While
/// swiping, one profile's wash slides aside and fades into the next.
final class ProfileAuraView: NSView {
    /// How far down from the top the wash reaches.
    private static let depth: CGFloat = 250
    /// Room on each side, so a wash sliding aside never shows its edge.
    private static let overhang: CGFloat = 120
    var position = 0.0 { didSet { arrange() } }
    private var profiles: [BrowserProfile] = []
    /// Where each profile is named, in this view's coordinates.
    private var focus: [CGPoint] = []
    private var washes: [CALayer] = []
    private var builtSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows a wash for each profile, glowing from the matching point of `glowing`.
    func show(_ profiles: [BrowserProfile], glowing: [CGPoint]) {
        guard profiles != self.profiles || glowing != focus else { return }
        self.profiles = profiles
        focus = glowing
        rebuild()
    }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    private func rebuild() {
        washes.forEach { $0.removeFromSuperlayer() }
        washes = []
        builtSize = bounds.size
        guard profiles.count > 1, focus.count == profiles.count, bounds.width > 0, let layer else { return }
        let size = CGSize(width: bounds.width + Self.overhang * 2, height: min(Self.depth, bounds.height))
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (profile, point) in zip(profiles, focus) {
            let wash = CALayer()
            wash.frame = CGRect(x: -Self.overhang, y: bounds.height - size.height, width: size.width, height: size.height)
            let local = CGPoint(x: point.x + Self.overhang, y: point.y - (bounds.height - size.height))
            wash.contents = ProfileArt.aura(profile, size: size, focus: local, scale: scale, dark: isDark)
            layer.addSublayer(wash)
            washes.append(wash)
        }
        CATransaction.commit()
        arrange()
    }

    private func arrange() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, wash) in washes.enumerated() {
            let distance = Double(index) - position
            wash.opacity = Float(max(0, 1 - abs(distance)))
            wash.setAffineTransform(CGAffineTransform(translationX: CGFloat(distance) * 90, y: 0))
        }
        CATransaction.commit()
    }
}

/// Names the current profile at the end of the search field: its badge and name on a capsule of its color. While
/// swiping, the next profile's name slides in as the capsule takes on its color and width. A click moves on.
final class ProfilePillView: NSView {
    static let height: CGFloat = 30
    private static let badgeSize: CGFloat = 22
    private static let slide: CGFloat = 64
    var onPress: (() -> Void)?
    var position = 0.0 { didSet { arrange() } }
    private var profiles: [BrowserProfile] = []
    private var pages: [(view: NSView, width: CGFloat)] = []
    private let capsule = NSView()
    private let grain = CALayer()
    private var cursorFrame = NSRect.zero
    private var hovering = false { didSet { arrange() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        capsule.wantsLayer = true
        capsule.layer?.masksToBounds = true
        capsule.layer?.cornerRadius = Self.height / 2
        capsule.layer?.borderWidth = 1
        grain.zPosition = -1
        capsule.layer?.addSublayer(grain)
        addSubview(capsule)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        toolTip = "Swipe sideways with two fingers, or click, to switch Chrome profiles"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Switches to the next Chrome profile. Swiping sideways with two fingers over the palette switches too.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Hidden, it takes no room from the search field.
    override var isHidden: Bool { didSet { invalidateIntrinsicContentSize() } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: isHidden || profiles.count < 2 ? 0 : pages.map(\.width).max() ?? 0, height: Self.height)
    }

    func show(_ profiles: [BrowserProfile]) {
        guard profiles != self.profiles else { return }
        self.profiles = profiles
        pages.forEach { $0.view.removeFromSuperview() }
        pages = profiles.map { profile in
            let page = NSView()
            let badge = NSImageView(image: ProfileArt.badge(profile, diameter: Self.badgeSize))
            badge.frame = NSRect(x: 4, y: (Self.height - Self.badgeSize) / 2, width: Self.badgeSize, height: Self.badgeSize)
            let label = NSTextField(labelWithString: profile.name)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.lineBreakMode = .byTruncatingTail
            // The fitting size includes the padding the label's cell keeps on both sides.
            let size = label.fittingSize
            let textWidth = min(ceil(size.width), 132)
            label.frame = NSRect(x: 4 + Self.badgeSize + 7, y: ((Self.height - size.height) / 2).rounded(), width: textWidth, height: size.height)
            page.addSubview(badge)
            page.addSubview(label)
            capsule.addSubview(page)
            return (page, 4 + Self.badgeSize + 7 + textWidth + 12)
        }
        isHidden = profiles.count < 2
        needsLayout = true
        applyGrain()
        arrange()
    }

    override func layout() {
        super.layout()
        arrange()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGrain()
        arrange()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyGrain()
    }

    private func applyGrain() {
        let scale = window?.backingScaleFactor ?? 2
        grain.contents = ProfileArt.grain(width: Int(220 * scale), height: Int(Self.height * scale))
        grain.contentsGravity = .topLeft
        grain.contentsScale = scale
        grain.opacity = isDark ? 0.35 : 0.25
    }

    /// Where the profile's badge sits once the capsule has settled on it, in this view's coordinates.
    func badgeCenter(_ index: Int) -> NSPoint {
        guard pages.indices.contains(index) else { return NSPoint(x: bounds.maxX, y: bounds.midY) }
        return NSPoint(x: bounds.width - pages[index].width + 4 + Self.badgeSize / 2, y: bounds.midY)
    }

    private func arrange() {
        guard !pages.isEmpty, profiles.count == pages.count else { return }
        let clamped = min(max(position, 0), Double(pages.count - 1))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, pages.count - 1)
        let share = clamped - Double(lower)
        // Pulled past either end, the capsule gives a little, like the content inside it.
        let width = pages[lower].width + (pages[upper].width - pages[lower].width) * CGFloat(share) + CGFloat(abs(position - clamped)) * 18
        let color = profiles[lower].color.mixed(with: profiles[upper].color, share).nsColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = NSRect(x: bounds.width - width, y: ((bounds.height - Self.height) / 2).rounded(), width: width, height: Self.height)
        capsule.layer?.backgroundColor = color.withAlphaComponent((isDark ? 0.26 : 0.16) + (hovering ? 0.08 : 0)).cgColor
        capsule.layer?.borderColor = color.withAlphaComponent(isDark ? 0.55 : 0.42).cgColor
        grain.frame = capsule.bounds
        for (index, page) in pages.enumerated() {
            let distance = CGFloat(Double(index) - position)
            page.view.frame = NSRect(x: distance * Self.slide, y: 0, width: page.width, height: Self.height)
            // One name has nearly left before the next arrives, so they never read as one.
            page.view.alphaValue = max(0, 1 - abs(distance) * 2.1)
        }
        CATransaction.commit()
        let name = "Chrome profile: " + profiles[Int(clamped.rounded())].name
        if accessibilityLabel() != name { setAccessibilityLabel(name) }
        if capsule.frame != cursorFrame {
            cursorFrame = capsule.frame
            window?.invalidateCursorRects(for: self)
        }
    }

    // The whole capsule is one button: its badge and name must not take the click or drag the palette.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && capsule.frame.contains(convert(point, from: superview)) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if capsule.frame.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(capsule.frame, cursor: .pointingHand) }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// One dot per profile in its color. The current one is larger and stretches toward the next while swiping: its
/// leading edge arrives first and its trailing edge follows. A click on a dot goes to that profile.
final class ProfileDotsView: NSView {
    private static let dot: CGFloat = 5
    private static let active: CGFloat = 7
    private static let pitch: CGFloat = 14
    var onSelect: ((Int) -> Void)?
    var position = 0.0 { didSet { needsDisplay = true } }
    var colors: [ProfileColor] = [] {
        didSet {
            isHidden = colors.count < 2
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: colors.count < 2 ? 0 : CGFloat(colors.count - 1) * Self.pitch + 20, height: 18)
    }

    private func center(_ index: Int) -> CGPoint {
        CGPoint(x: bounds.midX + (CGFloat(index) - CGFloat(colors.count - 1) / 2) * Self.pitch, y: bounds.midY)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard colors.count > 1 else { return }
        for (index, color) in colors.enumerated() {
            let point = center(index)
            color.nsColor.withAlphaComponent(isDark ? 0.5 : 0.45).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - Self.dot / 2, y: point.y - Self.dot / 2, width: Self.dot, height: Self.dot)).fill()
        }
        let clamped = min(max(position, 0), Double(colors.count - 1))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, colors.count - 1)
        let share = CGFloat(clamped - Double(lower))
        let head = min(1, share * 2)
        let tail = max(0, share * 2 - 1)
        // Past either end, the dot squeezes against it.
        let squeeze = min(CGFloat(abs(position - clamped)) * 6, 2.5)
        let start = center(lower)
        var rect = NSRect(x: start.x - Self.active / 2 + tail * Self.pitch, y: start.y - Self.active / 2,
                          width: Self.active + (head - tail) * Self.pitch, height: Self.active)
        rect = rect.insetBy(dx: squeeze / 2, dy: -squeeze / 4)
        let color = colors[lower].mixed(with: colors[upper], Double(share)).nsColor
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.7)
        glow.shadowBlurRadius = 5
        glow.set()
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard colors.count > 1 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let index = Int(((x - center(0).x) / Self.pitch).rounded())
        onSelect?(min(max(index, 0), colors.count - 1))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
