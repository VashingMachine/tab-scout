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
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12)
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 23),
            icon.heightAnchor.constraint(equalToConstant: 23),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 13),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
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

private final class FaviconImageView: NSImageView {
    // SF Symbol alignment insets must not resize the fixed favicon container.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}
