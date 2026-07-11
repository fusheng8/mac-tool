import AppKit

final class DisplayDeviceCardControl: NSControl {
    private let selected: Bool
    private var pressed = false { didSet { needsDisplay = true } }

    init(
        title: String,
        subtitle: String,
        symbolName: String,
        statusText: String,
        statusLevel: ControlCenterStatusLevel,
        selected: Bool
    ) {
        self.selected = selected
        super.init(frame: .zero)
        setup(
            title: title,
            subtitle: subtitle,
            symbolName: symbolName,
            statusText: statusText,
            statusLevel: statusLevel
        )
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let activate = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if activate { sendAction(action, to: target) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 { sendAction(action, to: target) }
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        let fill = selected
            ? MacAssistantUI.Color.brandTint
            : pressed ? MacAssistantUI.Color.blue.withAlphaComponent(0.08) : MacAssistantUI.Color.card
        fill.setFill()
        path.fill()
        (selected ? MacAssistantUI.Color.brandBorder : MacAssistantUI.Color.hairline).setStroke()
        path.lineWidth = selected ? 1.5 : 1
        path.stroke()
    }

    private func setup(
        title: String,
        subtitle: String,
        symbolName: String,
        statusText: String,
        statusLevel: ControlCenterStatusLevel
    ) {
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 254).isActive = true
        heightAnchor.constraint(equalToConstant: 86).isActive = true
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityHelp("选择(title)")
        setAccessibilityValue(selected)

        let iconBox = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.controlSurface,
            cornerRadius: 9,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        iconBox.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconBox.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let icon = NSImageView(image: MacAssistantUI.symbol(symbolName, pointSize: 21, weight: .regular) ?? NSImage())
        icon.contentTintColor = selected ? MacAssistantUI.Color.blue : .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)

        let titleLabel = MacAssistantUI.title(title, size: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        let subtitleLabel = MacAssistantUI.caption(subtitle, size: 10.5)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let status = NSStackView()
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 6
        status.addArrangedSubview(MacStatusDotView(level: statusLevel))
        status.addArrangedSubview(MacAssistantUI.caption(statusText, size: 10))
        let text = NSStackView(views: [titleLabel, subtitleLabel, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconBox)
        addSubview(text)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            iconBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}
