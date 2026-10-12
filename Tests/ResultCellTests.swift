import AppKit

@main
struct ResultCellTests {
    static var checks = 0
    static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 44), styleMask: .borderless, backing: .buffered, defer: false)
        let cell = ResultCell(frame: NSRect(x: 0, y: 0, width: 640, height: 44))
        window.contentView = cell
        let fallback = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
        let favicon = NSImage(size: NSSize(width: 32, height: 16), flipped: false) { _ in
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            NSColor.green.setFill()
            NSRect(x: 16, y: 0, width: 16, height: 16).fill()
            return true
        }
        cell.configure(title: String(repeating: "Long title ", count: 30), detail: "https://example.com/a?b=c | Window 1",
                       url: "https://example.com/a", image: fallback, tint: .systemTeal)
        cell.layoutSubtreeIfNeeded()
        expect(cell.faviconView.frame.size == NSSize(width: 20, height: 20), "Icon has fixed dimensions independent of image aspect")
        expect(cell.faviconView.imageScaling == .scaleProportionallyUpOrDown, "Favicon preserves its aspect ratio")
        expect(cell.titleTextField.lineBreakMode == .byTruncatingTail, "Long titles truncate within the row")
        expect(cell.titleTextField.alignmentRect(forFrame: cell.titleTextField.frame).maxX <= 630, "Title text fits within row bounds")
        expect(!cell.applyFavicon(favicon, for: "https://other.example"), "Late icon for another row is rejected")
        expect(cell.faviconView.image === fallback, "Rejected icon does not alter fallback")
        expect(cell.applyFavicon(favicon, for: "https://example.com/a"), "Matching icon applies")
        expect(cell.faviconView.image === favicon && cell.faviconView.contentTintColor == nil, "Website icon is not tinted")
        cell.layoutSubtreeIfNeeded()
        expect(cell.faviconView.frame.size == NSSize(width: 20, height: 20), "Loading a favicon cannot resize the icon container")
        expect(favicon.isTemplate == false, "Colored favicon remains a non-template image")
        checkFaviconPixels(cell.faviconView)
        checkLabelLayout(cell, width: 640)
        window.setContentSize(NSSize(width: 320, height: 44))
        cell.layoutSubtreeIfNeeded()
        checkLabelLayout(cell, width: 320)
        expect(cell.faviconView.frame.size == NSSize(width: 20, height: 20), "A narrow result row retains fixed icon dimensions")
        cell.configure(title: "New tab", detail: "New Safari tab", url: nil, image: fallback, tint: .systemBlue)
        expect(cell.representedURL == nil && cell.faviconView.contentTintColor == .systemBlue, "Reuse resets identity and tint")
        expect(!cell.applyFavicon(favicon, for: "https://example.com/a"), "A new-tab command cannot inherit an old favicon")
        expect(!cell.applyFavicon(nil, for: "https://example.com/a"), "Missing favicon retains fallback")
        print("Passed \(checks) result-cell rendering checks")
    }

    static func checkLabelLayout(_ cell: ResultCell, width: CGFloat) {
        expect(cell.bounds.width == width, "Long labels cannot expand the result row")
        let title = cell.titleTextField.alignmentRect(forFrame: cell.titleTextField.frame)
        let detail = cell.detailTextField.alignmentRect(forFrame: cell.detailTextField.frame)
        expect(title.minX >= cell.faviconView.frame.maxX + 10, "Title stays clear of the favicon")
        expect(title.maxX <= width - 10 && detail.maxX <= width - 10, "Both labels retain the row's trailing inset")
        expect(title.minX == detail.minX && title.width == detail.width, "Title and detail align in a stable text column")
        expect(!title.intersects(detail), "The two text lines do not overlap")
        expect(title.minY >= 0 && detail.minY >= 0 && title.maxY <= 44 && detail.maxY <= 44, "Both text lines fit vertically")
        expect(cell.detailTextField.lineBreakMode == .byTruncatingMiddle, "Long URLs truncate within their allocated width")
    }

    static func checkFaviconPixels(_ view: NSImageView) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            preconditionFailure("The favicon view must be rasterizable")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var redPixels = [(Int, Int)]()
        var greenPixels = [(Int, Int)]()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.7 else { continue }
                // Offscreen rendering is color-managed using the attached display profile.
                if color.redComponent > 0.6 && color.redComponent > color.greenComponent * 1.8 && color.redComponent > color.blueComponent * 2 { redPixels.append((x, y)) }
                if color.greenComponent > 0.6 && color.greenComponent > color.redComponent * 1.8 && color.greenComponent > color.blueComponent * 2 { greenPixels.append((x, y)) }
            }
        }
        expect(!redPixels.isEmpty && !greenPixels.isEmpty, "Rasterized favicon preserves both original colors without a tint")
        let pixels = redPixels + greenPixels
        let minX = pixels.map(\.0).min()!
        let maxX = pixels.map(\.0).max()!
        let minY = pixels.map(\.1).min()!
        let maxY = pixels.map(\.1).max()!
        let ratio = Double(maxX - minX + 1) / Double(maxY - minY + 1)
        expect(abs(ratio - 2) < 0.25, "Rasterized rectangular favicon preserves its 2:1 aspect ratio")
        expect(minY > 0 && maxY < bitmap.pixelsHigh - 1, "A wide favicon is vertically letterboxed instead of stretched")
        let redCenter = Double(redPixels.map(\.0).reduce(0, +)) / Double(redPixels.count)
        let greenCenter = Double(greenPixels.map(\.0).reduce(0, +)) / Double(greenPixels.count)
        expect(redCenter < greenCenter, "Rasterized favicon retains its left-to-right orientation")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
}
