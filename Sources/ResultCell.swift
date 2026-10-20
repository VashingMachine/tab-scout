import AppKit

final class ResultCell: NSTableCellView {
    var representedURL: String?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let icon = FaviconImageView()

    var faviconView: NSImageView { icon }
    var titleTextField: NSTextField { titleLabel }
    var detailTextField: NSTextField { detailLabel }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("resultCell")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, titleLabel, detailLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = titleLabel
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, detail: String, url: String?, image: NSImage?, tint: NSColor?) {
        representedURL = url
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        setIcon(image, tint: tint)
        toolTip = title + "\n" + detail
    }

    func setIcon(_ image: NSImage?, tint: NSColor?) {
        icon.image = image
        icon.contentTintColor = tint
    }

    @discardableResult
    func applyFavicon(_ image: NSImage?, for url: String) -> Bool {
        guard representedURL == url, let image else { return false }
        setIcon(image, tint: nil)
        return true
    }
}

/// A section heading, set on the left edge of the result icons and close to the results it introduces.
/// Headings are ordinary rows: as group rows, the inset table style adds a large gap above each one and floats the first.
final class SectionHeaderCell: NSTableCellView {
    static let height: CGFloat = 26
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("section")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
}

private final class FaviconImageView: NSImageView {
    // SF Symbol alignment insets must not resize the fixed favicon container.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}
