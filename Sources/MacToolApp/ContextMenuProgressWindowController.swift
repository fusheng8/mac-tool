import AppKit

final class ContextMenuProgressWindowController: NSWindowController {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let closeButton = MacTextButton(title: "关闭")
    private let revealButton = MacTextButton(title: "在 Finder 中显示")
    private let openButton = MacTextButton(title: "打开文件夹")
    private let copyPathButton = MacTextButton(title: "复制路径")
    private var closeWorkItem: DispatchWorkItem?
    private var actionURL: URL?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 206),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "压缩/解压"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = .clear
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func showRunning(title: String, detail: String) {
        closeWorkItem?.cancel()
        actionURL = nil
        updateIcon(symbolName: "archivebox", color: MacAssistantUI.Color.blue)
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        closeButton.isHidden = true
        setActionButtonsHidden(true)
        showCentered()
    }

    func update(detail: String) {
        detailLabel.stringValue = detail
    }

    func showSuccess(detail: String, resultURL: URL? = nil, autoClose: Bool? = nil) {
        closeWorkItem?.cancel()
        actionURL = resultURL
        updateIcon(symbolName: "checkmark.circle.fill", color: MacAssistantUI.Color.green)
        titleLabel.stringValue = "操作完成"
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        closeButton.isHidden = false
        setActionButtonsHidden(resultURL == nil)
        if autoClose ?? (resultURL == nil) {
            showCentered()
            scheduleClose()
        } else {
            showCentered()
        }
    }

    func showError(detail: String) {
        closeWorkItem?.cancel()
        actionURL = nil
        updateIcon(symbolName: "exclamationmark.triangle.fill", color: .systemRed)
        titleLabel.stringValue = "操作失败"
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        closeButton.isHidden = false
        setActionButtonsHidden(true)
        showCentered()
        NSSound.beep()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = MacAssistantUI.Color.window.cgColor
        contentView.layer?.cornerRadius = 12
        contentView.layer?.cornerCurve = .continuous

        let iconWrap = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.blue.withAlphaComponent(0.12),
            cornerRadius: 10
        )
        iconWrap.widthAnchor.constraint(equalToConstant: 42).isActive = true
        iconWrap.heightAnchor.constraint(equalToConstant: 42).isActive = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        for button in [revealButton, openButton, copyPathButton] {
            button.target = self
            button.isHidden = true
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        revealButton.action = #selector(revealPressed)
        openButton.action = #selector(openPressed)
        copyPathButton.action = #selector(copyPathPressed)

        let actionStack = NSStackView(views: [revealButton, openButton, copyPathButton, closeButton])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, detailLabel, progressIndicator])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 8
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconWrap)
        contentView.addSubview(textStack)
        contentView.addSubview(actionStack)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: iconWrap.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            iconWrap.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            iconWrap.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 32),

            textStack.leadingAnchor.constraint(equalTo: iconWrap.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 30),

            detailLabel.widthAnchor.constraint(equalToConstant: 416),
            progressIndicator.widthAnchor.constraint(equalToConstant: 416),

            actionStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            actionStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])
        updateIcon(symbolName: "archivebox", color: MacAssistantUI.Color.blue)
    }

    private func setActionButtonsHidden(_ isHidden: Bool) {
        revealButton.isHidden = isHidden
        openButton.isHidden = isHidden
        copyPathButton.isHidden = isHidden
    }

    private func updateIcon(symbolName: String, color: NSColor) {
        iconView.image = MacAssistantUI.symbol(symbolName, pointSize: 22, weight: .semibold)
        iconView.contentTintColor = color
    }

    private func showCentered() {
        guard let window else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: frame.midX - window.frame.width / 2,
                y: frame.midY - window.frame.height / 2
            ))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func scheduleClose() {
        let item = DispatchWorkItem { [weak self] in
            self?.close()
        }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    @objc private func closePressed() {
        close()
    }

    @objc private func revealPressed() {
        guard let actionURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([actionURL])
    }

    @objc private func openPressed() {
        guard let actionURL else { return }
        NSWorkspace.shared.open(actionURL)
    }

    @objc private func copyPathPressed() {
        guard let actionURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(actionURL.path, forType: .string)
        detailLabel.stringValue = "已复制路径：\(actionURL.path)"
    }
}
