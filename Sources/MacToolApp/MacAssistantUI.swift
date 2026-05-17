import AppKit

enum MacAssistantUI {
    enum Color {
        static let window = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 0.94)
        static let sidebar = NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.97, alpha: 0.70)
        static let sidebarSelected = NSColor(calibratedRed: 0.80, green: 0.86, blue: 0.98, alpha: 0.78)
        static let card = NSColor.white.withAlphaComponent(0.82)
        static let cardHover = NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.99, alpha: 0.88)
        static let separator = NSColor(calibratedRed: 0.75, green: 0.79, blue: 0.86, alpha: 0.38)
        static let hairline = NSColor(calibratedRed: 0.84, green: 0.87, blue: 0.92, alpha: 0.55)
        static let mutedText = NSColor.secondaryLabelColor
        static let subtleText = NSColor.tertiaryLabelColor
        static let blue = NSColor.systemBlue
        static let amber = NSColor.systemOrange
        static let purple = NSColor.systemPurple
        static let green = NSColor.systemGreen
    }

    static func symbol(_ name: String, pointSize: CGFloat = 15, weight: NSFont.Weight = .medium) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    static func title(_ text: String, size: CGFloat = 14, weight: NSFont.Weight = .semibold) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func caption(_ text: String, size: CGFloat = 12) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: .regular)
        label.textColor = Color.mutedText
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Color.hairline.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

}

final class LayerBackedView: NSView {
    init(
        backgroundColor: NSColor = .clear,
        cornerRadius: CGFloat = 0,
        borderColor: NSColor? = nil,
        borderWidth: CGFloat = 0
    ) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderColor = borderColor?.cgColor
        layer?.borderWidth = borderWidth
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }
}

final class MacSwitchControl: NSControl {
    var state: NSControl.StateValue = .off {
        didSet { updateLayers(animated: true) }
    }

    private let trackLayer = CALayer()
    private let thumbLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 42, height: 24)
    }

    override var isEnabled: Bool {
        didSet { updateLayers(animated: false) }
    }

    override func layout() {
        super.layout()
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2
        updateLayers(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }

    private func setup() {
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        trackLayer.addSublayer(thumbLayer)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 42).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true

        trackLayer.cornerCurve = .continuous
        thumbLayer.backgroundColor = NSColor.white.cgColor
        thumbLayer.shadowColor = NSColor.black.cgColor
        thumbLayer.shadowOpacity = 0.18
        thumbLayer.shadowRadius = 2
        thumbLayer.shadowOffset = NSSize(width: 0, height: 1)
        updateLayers(animated: false)
    }

    private func updateLayers(animated: Bool) {
        let isOn = state == .on
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.45
        let trackColor = (isOn ? MacAssistantUI.Color.green : NSColor(calibratedRed: 0.78, green: 0.80, blue: 0.84, alpha: 1))
            .withAlphaComponent(enabledAlpha)
            .cgColor
        let knobSize = max(18, bounds.height - 4)
        let knobX = isOn ? bounds.width - knobSize - 2 : 2
        let knobFrame = CGRect(x: knobX, y: 2, width: knobSize, height: knobSize)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.16)
        trackLayer.backgroundColor = trackColor
        thumbLayer.frame = knobFrame
        thumbLayer.cornerRadius = knobSize / 2
        CATransaction.commit()
    }
}

final class SidebarNavItem: NSControl {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let normalTint = NSColor.secondaryLabelColor

    init(title: String, symbolName: String) {
        super.init(frame: .zero)
        setup(title: title, symbolName: symbolName)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    func setSelected(_ selected: Bool, accentColor: NSColor) {
        layer?.backgroundColor = selected ? MacAssistantUI.Color.sidebarSelected.cgColor : NSColor.clear.cgColor
        iconView.contentTintColor = accentColor
        titleLabel.textColor = selected ? MacAssistantUI.Color.blue : normalTint
        titleLabel.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .medium)
    }

    private func setup(title: String, symbolName: String) {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        iconView.image = MacAssistantUI.symbol(symbolName, pointSize: 15, weight: .regular)
        iconView.contentTintColor = normalTint
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = normalTint
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

final class MacSearchField: NSControl, NSTextInputClient {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    var text = "" {
        didSet {
            needsDisplay = true
            onChange?(text)
        }
    }

    var onChange: ((String) -> Void)?
    var onKeyCommand: ((NSEvent) -> Bool)?
    private var isFocused = false
    private var markedText = ""
    private var markedSelectedRange = NSRange(location: 0, length: 0)
    private var showsCaret = false
    private var caretTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        caretTimer?.invalidate()
    }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        startCaretBlink()
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        markedText = ""
        inputContext?.discardMarkedText()
        stopCaretBlink()
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText(), inputContext?.handleEvent(event) == true {
            return
        }
        if onKeyCommand?(event) == true {
            return
        }
        if handleTextInput(from: event) {
            return
        }
    }

    @discardableResult
    func handleTextInput(from event: NSEvent) -> Bool {
        if hasMarkedText(), inputContext?.handleEvent(event) == true {
            return true
        }
        if event.keyCode == 51 {
            guard !text.isEmpty else { return true }
            text.removeLast()
            return true
        }
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return true
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            text = ""
            return true
        }
        if inputContext?.handleEvent(event) == true {
            return true
        }
        guard let characters = event.characters, !characters.isEmpty else { return false }
        let scalarSet = CharacterSet.controlCharacters
        let visible = String(characters.unicodeScalars.filter { !scalarSet.contains($0) })
        guard !visible.isEmpty else { return false }
        text += visible
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.white.withAlphaComponent(0.70).setFill()
        path.fill()
        (isFocused ? MacAssistantUI.Color.blue.withAlphaComponent(0.70) : NSColor(calibratedRed: 0.66, green: 0.69, blue: 0.74, alpha: 0.86)).setStroke()
        path.lineWidth = 1
        path.stroke()

        if let icon = MacAssistantUI.symbol("magnifyingglass", pointSize: 13, weight: .medium) {
            let tintedIcon = NSImage(size: icon.size)
            tintedIcon.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: icon.size), from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.secondaryLabelColor.setFill()
            NSRect(origin: .zero, size: icon.size).fill(using: .sourceAtop)
            tintedIcon.unlockFocus()

            let iconRect = NSRect(x: 11, y: floor((bounds.height - 14) / 2), width: 14, height: 14)
            tintedIcon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let displayText = text + markedText
        let isPlaceholderVisible = displayText.isEmpty
        let value = isPlaceholderVisible ? placeholder : displayText
        let color = isPlaceholderVisible ? NSColor.secondaryLabelColor : NSColor.labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: color
        ]
        let textSize = (value as NSString).size(withAttributes: attributes)
        let textRect = NSRect(x: 34, y: floor((bounds.height - textSize.height) / 2), width: bounds.width - 44, height: ceil(textSize.height))
        if markedText.isEmpty || isPlaceholderVisible {
            value.draw(in: textRect, withAttributes: attributes)
        } else {
            let attributedValue = NSMutableAttributedString(string: value, attributes: attributes)
            attributedValue.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: (text as NSString).length, length: (markedText as NSString).length)
            )
            attributedValue.draw(in: textRect)
        }

        if isFocused && showsCaret {
            let width = min((value as NSString).size(withAttributes: attributes).width, textRect.width)
            let caretX = displayText.isEmpty ? textRect.minX : textRect.minX + width + 1
            let caret = NSBezierPath()
            caret.move(to: NSPoint(x: caretX, y: textRect.minY + 2))
            caret.line(to: NSPoint(x: caretX, y: textRect.maxY - 2))
            MacAssistantUI.Color.blue.setStroke()
            caret.lineWidth = 1
            caret.stroke()
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 31).isActive = true
    }

    private func startCaretBlink() {
        caretTimer?.invalidate()
        showsCaret = true
        let timer = Timer(timeInterval: 0.52, repeats: true) { [weak self] _ in
            guard let self, self.isFocused else { return }
            self.showsCaret.toggle()
            self.needsDisplay = true
        }
        caretTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopCaretBlink() {
        caretTimer?.invalidate()
        caretTimer = nil
        showsCaret = false
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let inserted = plainString(from: string)
        markedText = ""
        markedSelectedRange = NSRange(location: 0, length: 0)
        if replacementRange.location != NSNotFound {
            text = replacingDisplayText(in: replacementRange, with: inserted)
        } else {
            text += inserted
        }
    }

    override func doCommand(by selector: Selector) {
        switch NSStringFromSelector(selector) {
        case "deleteBackward:":
            guard !text.isEmpty else { return }
            text.removeLast()
        case "cancelOperation:":
            markedText = ""
            markedSelectedRange = NSRange(location: 0, length: 0)
            needsDisplay = true
        default:
            break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let replacement = plainString(from: string)
        if replacementRange.location != NSNotFound {
            text = replacingDisplayText(in: replacementRange, with: "")
        }
        markedText = replacement
        markedSelectedRange = selectedRange
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        markedSelectedRange = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    func selectedRange() -> NSRange {
        NSRange(location: (text as NSString).length + markedSelectedRange.location, length: markedSelectedRange.length)
    }

    func markedRange() -> NSRange {
        guard hasMarkedText() else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: (text as NSString).length, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let nsString = (text + markedText) as NSString
        let validRange = NSIntersectionRange(range, NSRange(location: 0, length: nsString.length))
        guard validRange.length > 0 else { return nil }
        actualRange?.pointee = validRange
        return NSAttributedString(string: nsString.substring(with: validRange))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let rect = caretRect()
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        ((text + markedText) as NSString).length
    }

    private func plainString(from value: Any) -> String {
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return value as? String ?? ""
    }

    private func replacingDisplayText(in range: NSRange, with replacement: String) -> String {
        let nsString = (text + markedText) as NSString
        let validRange = NSIntersectionRange(range, NSRange(location: 0, length: nsString.length))
        return nsString.replacingCharacters(in: validRange, with: replacement)
    }

    private func caretRect() -> NSRect {
        let displayText = text + markedText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        let measuredText = displayText.isEmpty ? " " : displayText
        let height = ceil((measuredText as NSString).size(withAttributes: attributes).height)
        let textRect = NSRect(x: 34, y: floor((bounds.height - height) / 2), width: bounds.width - 44, height: height)
        let width = min((displayText as NSString).size(withAttributes: attributes).width, textRect.width)
        let x = displayText.isEmpty ? textRect.minX : textRect.minX + width + 1
        return NSRect(x: x, y: textRect.minY, width: 1, height: textRect.height)
    }
}

final class MacIconButton: NSControl {
    enum Style {
        case filled
        case subtle
    }

    var symbolName: String {
        didSet { needsDisplay = true }
    }
    var tintColor = NSColor.secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    var style: Style = .filled {
        didSet { needsDisplay = true }
    }
    private var rotationAngle: CGFloat = 0
    private var spinTimer: Timer?
    private var spinStartTime: TimeInterval = 0
    private var spinDuration: TimeInterval = 0.55
    private var spinCompletion: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    init(symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let shouldSendAction = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldSendAction {
            sendAction(action, to: target)
        }
    }

    func spinOnce(duration: TimeInterval = 0.55, completion: (() -> Void)? = nil) {
        spinTimer?.invalidate()
        spinDuration = duration
        spinStartTime = Date.timeIntervalSinceReferenceDate
        spinCompletion = completion
        rotationAngle = 0

        spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = Date.timeIntervalSinceReferenceDate - self.spinStartTime
            let progress = min(1, elapsed / self.spinDuration)
            let eased = 1 - pow(1 - progress, 3)
            self.rotationAngle = CGFloat(eased * .pi * 2)
            self.needsDisplay = true

            if progress >= 1 {
                timer.invalidate()
                self.spinTimer = nil
                self.rotationAngle = 0
                self.needsDisplay = true
                let completion = self.spinCompletion
                self.spinCompletion = nil
                completion?()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let icon = MacAssistantUI.symbol(symbolName, pointSize: 14, weight: .semibold) else { return }
        let chrome = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        switch style {
        case .filled:
            (isPressed ? MacAssistantUI.Color.blue.withAlphaComponent(0.13) : NSColor.white.withAlphaComponent(0.78)).setFill()
            chrome.fill()
            MacAssistantUI.Color.hairline.withAlphaComponent(isEnabled ? 1 : 0.45).setStroke()
            chrome.lineWidth = 1
            chrome.stroke()
        case .subtle:
            if isPressed || isHovered {
                (isPressed ? MacAssistantUI.Color.blue.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
                chrome.fill()
            }
        }

        let rect = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byRadians: rotationAngle)
        transform.translateX(by: -bounds.midX, yBy: -bounds.midY)
        transform.concat()
        drawTintedIcon(icon, in: rect, tint: tintColor, fraction: isEnabled ? 1 : 0.35)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func drawTintedIcon(_ icon: NSImage, in rect: NSRect, tint: NSColor, fraction: CGFloat) {
        let image = NSImage(size: rect.size)
        image.lockFocus()
        icon.draw(
            in: NSRect(origin: .zero, size: rect.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        tint.setFill()
        NSRect(origin: .zero, size: rect.size).fill(using: .sourceIn)
        image.unlockFocus()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
    }
}

final class MacTextButton: NSControl {
    enum Role {
        case neutral
        case primary
        case destructive
    }

    var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var symbolName: String? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var role: Role {
        didSet { needsDisplay = true }
    }

    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    init(title: String, symbolName: String? = nil, role: Role = .neutral) {
        self.title = title
        self.symbolName = symbolName
        self.role = role
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let iconWidth: CGFloat = symbolName == nil ? 0 : 18
        return NSSize(width: max(64, ceil(textWidth + iconWidth + 24)), height: 30)
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                isPressed = false
            }
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let shouldSendAction = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldSendAction {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tint = roleTint
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.42
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)

        switch role {
        case .neutral:
            (isPressed ? tint.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.84 * enabledAlpha)).setFill()
        case .primary, .destructive:
            (isPressed ? tint.withAlphaComponent(0.22) : tint.withAlphaComponent(0.11 * enabledAlpha)).setFill()
        }
        path.fill()
        (isPressed ? tint.withAlphaComponent(0.52) : MacAssistantUI.Color.hairline.withAlphaComponent(enabledAlpha)).setStroke()
        path.lineWidth = 1
        path.stroke()

        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textColor = isEnabled ? tint : NSColor.tertiaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let iconSize: CGFloat = symbolName == nil ? 0 : 14
        let gap: CGFloat = symbolName == nil ? 0 : 6
        let totalWidth = iconSize + gap + textSize.width
        var x = floor((bounds.width - totalWidth) / 2)

        if let symbolName, let icon = MacAssistantUI.symbol(symbolName, pointSize: 12, weight: .semibold) {
            let iconRect = NSRect(x: x, y: floor((bounds.height - 14) / 2), width: 14, height: 14)
            let tintedIcon = NSImage(size: iconRect.size)
            tintedIcon.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: iconRect.size), from: .zero, operation: .sourceOver, fraction: 1)
            textColor.withAlphaComponent(isEnabled ? 1 : 0.42).setFill()
            NSRect(origin: .zero, size: iconRect.size).fill(using: .sourceIn)
            tintedIcon.unlockFocus()
            tintedIcon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            x += iconSize + gap
        }

        title.draw(
            in: NSRect(x: x, y: floor((bounds.height - textSize.height) / 2) - 0.5, width: textSize.width, height: textSize.height),
            withAttributes: attributes
        )
    }

    private var roleTint: NSColor {
        switch role {
        case .neutral:
            return NSColor.labelColor
        case .primary:
            return MacAssistantUI.Color.blue
        case .destructive:
            return NSColor.systemRed
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
}

final class MacSegmentButton: NSControl {
    var title: String {
        didSet { needsDisplay = true }
    }

    var selected = false {
        didSet { needsDisplay = true }
    }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.white.setFill()
            path.fill()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .medium),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail

        var drawingAttributes = attributes
        drawingAttributes[.paragraphStyle] = paragraphStyle
        let textHeight = (title as NSString).size(withAttributes: attributes).height
        let rect = bounds.insetBy(dx: 8, dy: max(0, (bounds.height - textHeight) / 2 - 0.5))
        title.draw(in: rect, withAttributes: drawingAttributes)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
    }
}

final class MacSelectControl: NSControl {
    var items: [String] = [] {
        didSet { selectedIndex = min(selectedIndex, max(0, items.count - 1)); needsDisplay = true }
    }

    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    var selectedTitle: String {
        guard items.indices.contains(selectedIndex) else { return "" }
        return items[selectedIndex]
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    private var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func select(title: String) {
        if let index = items.firstIndex(of: title) {
            selectedIndex = index
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !items.isEmpty else { return }
        showMenu()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(isEnabled ? 0.85 : 0.45).setFill()
        path.fill()
        MacAssistantUI.Color.hairline.withAlphaComponent(isEnabled ? 1 : 0.45).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let textSize = (selectedTitle as NSString).size(withAttributes: attributes)
        selectedTitle.draw(
            in: NSRect(x: 10, y: floor((bounds.height - textSize.height) / 2) - 0.5, width: bounds.width - 38, height: ceil(textSize.height)),
            withAttributes: attributes
        )

        if let icon = MacAssistantUI.symbol("chevron.up.chevron.down", pointSize: 11, weight: .semibold) {
            let iconRect = NSRect(x: bounds.width - 24, y: floor((bounds.height - 14) / 2), width: 14, height: 14)
            let iconTint = isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor
            let tintedIcon = NSImage(size: iconRect.size)
            tintedIcon.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: iconRect.size), from: .zero, operation: .sourceOver, fraction: 1)
            iconTint.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
            NSRect(origin: .zero, size: iconRect.size).fill(using: .sourceIn)
            tintedIcon.unlockFocus()
            tintedIcon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func showMenu() {
        popover?.close()

        let menuView = MacSelectMenuView(items: items, selectedIndex: selectedIndex) { [weak self] index in
            guard let self else { return }
            self.selectedIndex = index
            self.popover?.close()
            self.sendAction(self.action, to: self.target)
        }
        let controller = NSViewController()
        controller.view = menuView

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: max(bounds.width, 120), height: CGFloat(items.count * 30 + 8))
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

private final class MacSelectMenuView: NSView {
    init(items: [String], selectedIndex: Int, onSelect: @escaping (Int) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 140, height: CGFloat(items.count * 30 + 8)))
        wantsLayer = true
        layer?.backgroundColor = MacAssistantUI.Color.card.cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderColor = MacAssistantUI.Color.hairline.cgColor
        layer?.borderWidth = 1

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (index, item) in items.enumerated() {
            let row = MacSelectMenuItemControl(title: item, selected: index == selectedIndex) {
                onSelect(index)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }
}

private final class MacSelectMenuItemControl: NSControl {
    private let title: String
    private let selected: Bool
    private let onSelect: () -> Void
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    init(title: String, selected: Bool, onSelect: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.onSelect = onSelect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let shouldSelect = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldSelect {
            onSelect()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected || isPressed {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            MacAssistantUI.Color.blue.withAlphaComponent(isPressed ? 0.15 : 0.10).setFill()
            path.fill()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .medium),
            .foregroundColor: selected ? MacAssistantUI.Color.blue : NSColor.labelColor
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        title.draw(
            in: NSRect(x: 10, y: floor((bounds.height - textSize.height) / 2) - 0.5, width: bounds.width - 32, height: textSize.height),
            withAttributes: attributes
        )

        if selected, let icon = MacAssistantUI.symbol("checkmark", pointSize: 11, weight: .bold) {
            let rect = NSRect(x: bounds.width - 20, y: floor((bounds.height - 12) / 2), width: 12, height: 12)
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            MacAssistantUI.Color.blue.setFill()
            rect.fill(using: .sourceAtop)
        }
    }
}

final class MacNumberControl: NSControl {
    var value = 1000 {
        didSet {
            value = min(maxValue, max(minValue, value))
            needsDisplay = true
            if oldValue != value { onChange?(value) }
        }
    }

    var minValue = 10
    var maxValue = 10000
    var increment = 10
    var onChange: ((Int) -> Void)?
    private var isFocused = false
    private var showsCaret = false
    private var caretTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        caretTimer?.invalidate()
    }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        startCaretBlink()
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        stopCaretBlink()
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if point.x > bounds.width - 22 {
            value += point.y > bounds.midY ? increment : -increment
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51:
            value /= 10
        case 126:
            value += increment
        case 125:
            value -= increment
        default:
            guard let chars = event.characters else { return }
            let digits = chars.filter(\.isNumber)
            guard !digits.isEmpty else { return }
            let candidate = "\(value)\(digits)"
            if let parsed = Int(candidate) {
                value = parsed
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.85).setFill()
        path.fill()
        (isFocused ? MacAssistantUI.Color.blue.withAlphaComponent(0.65) : MacAssistantUI.Color.hairline).setStroke()
        path.lineWidth = isFocused ? 1.5 : 1
        path.stroke()

        let text = "\(value)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: bounds.width - 30 - size.width,
            y: (bounds.height - size.height) / 2 - 0.5,
            width: size.width,
            height: size.height
        )
        text.draw(in: textRect, withAttributes: attributes)

        if isFocused && showsCaret {
            let caretX = min(textRect.maxX + 2, bounds.width - 24)
            let caret = NSBezierPath()
            caret.move(to: NSPoint(x: caretX, y: textRect.minY + 2))
            caret.line(to: NSPoint(x: caretX, y: textRect.maxY - 2))
            MacAssistantUI.Color.blue.setStroke()
            caret.lineWidth = 1
            caret.stroke()
        }

        if let icon = MacAssistantUI.symbol("chevron.up.chevron.down", pointSize: 10, weight: .semibold) {
            icon.draw(in: NSRect(x: bounds.width - 18, y: (bounds.height - 12) / 2, width: 12, height: 12))
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 84).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func startCaretBlink() {
        caretTimer?.invalidate()
        showsCaret = true
        let timer = Timer(timeInterval: 0.52, repeats: true) { [weak self] _ in
            guard let self, self.isFocused else { return }
            self.showsCaret.toggle()
            self.needsDisplay = true
        }
        caretTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopCaretBlink() {
        caretTimer?.invalidate()
        caretTimer = nil
        showsCaret = false
    }
}
