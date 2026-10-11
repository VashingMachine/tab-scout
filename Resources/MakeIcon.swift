import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(srgbRed: 0.06, green: 0.43, blue: 0.40, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 976, height: 976), xRadius: 210, yRadius: 210).fill()
        let tabs = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)!
        let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium).applying(.init(paletteColors: [.white]))
        tabs.withSymbolConfiguration(config)!.draw(in: NSRect(x: 155, y: 226, width: 670, height: 570))
        NSColor(srgbRed: 1, green: 0.83, blue: 0.38, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 580, y: 108, width: 320, height: 320)).fill()
        let search = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
        let searchConfig = NSImage.SymbolConfiguration(pointSize: 205, weight: .semibold).applying(.init(paletteColors: [NSColor(srgbRed: 0.07, green: 0.22, blue: 0.20, alpha: 1)]))
        search.withSymbolConfiguration(searchConfig)!.draw(in: NSRect(x: 638, y: 165, width: 204, height: 204))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
