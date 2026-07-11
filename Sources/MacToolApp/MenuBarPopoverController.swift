import AppKit

struct MenuBarPopoverModel {
    let status: ControlCenterStatusSnapshot
    let clipboardCount: Int
    let connectedDisplayCount: Int
    let loginItemEnabled: Bool
}

final class MenuBarPopoverController: NSViewController {
    var onOpenRoute: ((ControlCenterRoute) -> Void)?
    var onOpenClipboard: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onToggleLoginItem: (() -> Void)?
    var onQuit: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var model: MenuBarPopoverModel
    private var focusableControls: [PopoverActionControl] = []

    init(model: MenuBarPopoverModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 380, height: 520)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func loadView() {
        view = MenuBarPopoverRootView()
        rebuild()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(focusableControls.first)
        (view as? MenuBarPopoverRootView)?.onEscape = { [weak self] in self?.onDismiss?() }
    }

    func update(model: MenuBarPopoverModel) {
        self.model = model
        guard isViewLoaded else { return }
        rebuild()
    }

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }
        focusableControls.removeAll()
        view.wantsLayer = true
        view.layer?.backgroundColor = MacAssistantUI.Color.content.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        stack.addArrangedSubview(header())
        stack.addArrangedSubview(separator())
        if let issue = model.status.issues.first {
            stack.addArrangedSubview(issueRow(issue))
            stack.addArrangedSubview(separator())
        }
        stack.addArrangedSubview(sectionLabel("快捷工具"))
        stack.addArrangedSubview(actionRow(
            title: "搜索剪贴板",
            detail: model.status.services.first(where: { $0.id == "clipboard" })?.detail ?? "",
            symbolName: "doc.on.clipboard",
            action: { [weak self] in self?.onOpenClipboard?() }
        ))
        stack.addArrangedSubview(actionRow(
            title: "调整显示器",
            detail: model.connectedDisplayCount > 0 ? "(model.connectedDisplayCount) 台显示器已连接" : "打开显示器控制台",
            symbolName: "display",
            action: { [weak self] in self?.onOpenRoute?(.displays) }
        ))
        stack.addArrangedSubview(actionRow(
            title: "创建压缩包",
            detail: "使用预设快速创建归档",
            symbolName: "archivebox",
            action: { [weak self] in self?.onOpenRoute?(.archive) }
        ))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel("控制中心"))
        stack.addArrangedSubview(compactActionRow(title: "打开概览", symbolName: "rectangle.grid.2x2") { [weak self] in
            self?.onOpenRoute?(.overview)
        })
        stack.addArrangedSubview(compactActionRow(title: "偏好设置", symbolName: "gearshape") { [weak self] in
            self?.onOpenRoute?(.preferences)
        })
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(footer())

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])
        configureFocusMovement()
    }

    private func header() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 82).isActive = true

        let iconBox = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.brandTint,
            cornerRadius: 10,
            borderColor: MacAssistantUI.Color.brandBorder,
            borderWidth: 1
        )
        iconBox.widthAnchor.constraint(equalToConstant: 42).isActive = true
        iconBox.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let icon = NSImageView(image: MacAssistantUI.symbol("wrench.and.screwdriver", pointSize: 20, weight: .semibold) ?? NSImage())
        icon.contentTintColor = MacAssistantUI.Color.blue
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)

        let title = MacAssistantUI.title("Mac助手", size: 15, weight: .semibold)
        let statusStack = NSStackView()
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 7
        let dot = MacStatusDotView(level: model.status.level)
        let status = MacAssistantUI.caption(model.status.headline, size: 11)
        statusStack.addArrangedSubview(dot)
        statusStack.addArrangedSubview(status)
        let text = NSStackView(views: [title, statusStack])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5
        text.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(iconBox)
        row.addSubview(text)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            iconBox.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
            iconBox.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -18),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func issueRow(_ issue: ControlCenterIssue) -> NSView {
        let row = LayerBackedView(backgroundColor: MacAssistantUI.Color.brandTint)
        row.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let icon = NSImageView(image: MacAssistantUI.symbol("exclamationmark.triangle", pointSize: 16, weight: .semibold) ?? NSImage())
        icon.contentTintColor = MacAssistantUI.Color.statusAttention
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = MacAssistantUI.title(issue.title, size: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let button = MacTextButton(title: "修复", role: .primary)
        button.target = self
        button.action = #selector(repairIssue)

        row.addSubview(icon)
        row.addSubview(title)
        row.addSubview(button)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -10),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -18),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func sectionLabel(_ text: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let label = MacAssistantUI.title(text, size: 11, weight: .medium)
        label.textColor = .tertiaryLabelColor
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func actionRow(
        title: String,
        detail: String,
        symbolName: String,
        action: @escaping () -> Void
    ) -> PopoverActionControl {
        let row = PopoverActionControl(title: title, detail: detail, symbolName: symbolName, height: 58)
        row.onActivate = action
        focusableControls.append(row)
        return row
    }

    private func compactActionRow(
        title: String,
        symbolName: String,
        action: @escaping () -> Void
    ) -> PopoverActionControl {
        let row = PopoverActionControl(title: title, detail: nil, symbolName: symbolName, height: 42)
        row.onActivate = action
        focusableControls.append(row)
        return row
    }

    private func footer() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let update = MacTextButton(title: "检查更新", role: .neutral)
        update.target = self
        update.action = #selector(checkForUpdates)
        let login = MacTextButton(title: model.loginItemEnabled ? "自启：开" : "自启：关", role: .neutral)
        login.target = self
        login.action = #selector(toggleLoginItem)
        let quit = MacTextButton(title: "退出", role: .neutral)
        quit.target = self
        quit.action = #selector(quitApplication)
        row.addSubview(update)
        row.addSubview(login)
        row.addSubview(quit)
        NSLayoutConstraint.activate([
            update.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
            update.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            login.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            login.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            quit.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -18),
            quit.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func separator() -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let line = MacAssistantUI.separator()
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 18),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -18),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)
        ])
        return wrap
    }

    private func configureFocusMovement() {
        for (index, control) in focusableControls.enumerated() {
            control.onMoveFocus = { [weak self] delta in
                guard let self, !self.focusableControls.isEmpty else { return }
                let next = (index + delta + self.focusableControls.count) % self.focusableControls.count
                self.view.window?.makeFirstResponder(self.focusableControls[next])
            }
        }
    }

    @objc private func repairIssue() {
        onOpenRoute?(model.status.issues.first?.route ?? .preferences)
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func toggleLoginItem() {
        onToggleLoginItem?()
    }

    @objc private func quitApplication() {
        onQuit?()
    }
}

private final class MenuBarPopoverRootView: NSView {
    var onEscape: (() -> Void)?

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class PopoverActionControl: NSControl {
    var onActivate: (() -> Void)?
    var onMoveFocus: ((Int) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private var trackingAreaRef: NSTrackingArea?
    private var hovered = false { didSet { updateBackground() } }
    private var pressed = false { didSet { updateBackground() } }

    init(title: String, detail: String?, symbolName: String, height: CGFloat) {
        super.init(frame: .zero)
        setup(title: title, detail: detail, symbolName: symbolName, height: height)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let activate = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if activate { onActivate?() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76: onActivate?()
        case 125: onMoveFocus?(1)
        case 126: onMoveFocus?(-1)
        default: super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 2), xRadius: 8, yRadius: 8).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    private func setup(title: String, detail: String?, symbolName: String, height: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail ?? "打开(title)")

        iconView.image = MacAssistantUI.symbol(symbolName, pointSize: 16, weight: .regular)
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.stringValue = detail ?? ""
        detailLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isHidden = detail == nil
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        let text = NSStackView(views: detail == nil ? [titleLabel] : [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        chevronView.image = MacAssistantUI.symbol("chevron.right", pointSize: 10, weight: .semibold)
        chevronView.contentTintColor = .tertiaryLabelColor
        chevronView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(text)
        addSubview(chevronView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -12),
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (pressed
                ? MacAssistantUI.Color.blue.withAlphaComponent(0.12)
                : hovered ? NSColor.labelColor.withAlphaComponent(0.055) : NSColor.clear).cgColor
        }
    }
}
