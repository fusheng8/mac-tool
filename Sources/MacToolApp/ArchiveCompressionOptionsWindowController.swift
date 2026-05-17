import AppKit

final class ArchiveCompressionOptionsWindowController: NSWindowController {
    private let urls: [URL]
    private let config: ArchiveConfig
    private let completion: (ArchiveCompressionOptions) -> Void
    private let onCancel: () -> Void

    private let nameField = NSTextField()
    private let formatPopup = NSPopUpButton()
    private let stripMetadataCheckbox = NSButton(checkboxWithTitle: "去除 .DS_Store 和 macOS 元数据", target: nil, action: nil)
    private let compressionLevelSlider = NSSlider(value: 6, minValue: 0, maxValue: 9, target: nil, action: nil)
    private let compressionLevelLabel = NSTextField(labelWithString: "")
    private let passwordField = NSSecureTextField()
    private let wrapFolderCheckbox = NSButton(checkboxWithTitle: "包一层文件夹", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")

    init(
        urls: [URL],
        config: ArchiveConfig,
        completion: @escaping (ArchiveCompressionOptions) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.urls = urls
        self.config = config
        self.completion = completion
        self.onCancel = onCancel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 372),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "压缩"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "压缩参数")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        nameField.stringValue = defaultArchiveName()
        nameField.placeholderString = "压缩包文件名"

        ArchiveFormat.allCases
            .filter { config.supports($0) }
            .forEach { format in
                let item = NSMenuItem(title: format.title, action: nil, keyEquivalent: "")
                item.representedObject = format.rawValue
                formatPopup.menu?.addItem(item)
            }
        if formatPopup.numberOfItems == 0 {
            let item = NSMenuItem(title: ArchiveFormat.zip.title, action: nil, keyEquivalent: "")
            item.representedObject = ArchiveFormat.zip.rawValue
            formatPopup.menu?.addItem(item)
        }
        selectFormat(.zip)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        stripMetadataCheckbox.state = config.stripMacMetadataWhenCompressing ? .on : .off

        compressionLevelSlider.integerValue = ArchiveConfig.normalizedCompressionLevel(config.defaultCompressionLevel)
        compressionLevelSlider.numberOfTickMarks = 10
        compressionLevelSlider.allowsTickMarkValuesOnly = true
        compressionLevelSlider.controlSize = .small
        compressionLevelSlider.target = self
        compressionLevelSlider.action = #selector(compressionLevelChanged)
        compressionLevelLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        compressionLevelLabel.textColor = .secondaryLabelColor
        updateCompressionLevelLabel()

        passwordField.placeholderString = "可选，仅 ZIP / 7Z / RAR 支持"
        passwordField.isEnabled = selectedFormat.supportsCompressionPassword

        wrapFolderCheckbox.state = urls.count > 1 ? .on : .off

        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2
        updateHint()

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        let createButton = NSButton(title: "开始压缩", target: self, action: #selector(confirm))
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"

        let buttonStack = NSStackView(views: [cancelButton, createButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(row(title: "文件名", control: nameField))
        stack.addArrangedSubview(row(title: "格式", control: formatPopup))
        stack.addArrangedSubview(row(title: "压缩等级", control: compressionLevelControl()))
        stack.addArrangedSubview(row(title: "密码", control: passwordField))
        stack.addArrangedSubview(stripMetadataCheckbox)
        stack.addArrangedSubview(wrapFolderCheckbox)
        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(buttonStack)

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),

            nameField.widthAnchor.constraint(equalToConstant: 300),
            formatPopup.widthAnchor.constraint(equalToConstant: 300),
            compressionLevelSlider.widthAnchor.constraint(equalToConstant: 250),
            compressionLevelLabel.widthAnchor.constraint(equalToConstant: 42),
            passwordField.widthAnchor.constraint(equalToConstant: 300),
            hintLabel.widthAnchor.constraint(equalToConstant: 410),
            buttonStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }

    private func compressionLevelControl() -> NSView {
        let stack = NSStackView(views: [compressionLevelSlider, compressionLevelLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func row(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 64)
        ])
        return stack
    }

    @objc private func formatChanged() {
        passwordField.isEnabled = selectedFormat.supportsCompressionPassword
        if !passwordField.isEnabled {
            passwordField.stringValue = ""
        }
        compressionLevelSlider.isEnabled = selectedFormat.supportsCompressionLevel
        if selectedFormat.isSingleFileCompression {
            wrapFolderCheckbox.state = .off
        }
        wrapFolderCheckbox.isEnabled = !selectedFormat.isSingleFileCompression
        updateCompressionLevelLabel()
        updateHint()
    }

    @objc private func compressionLevelChanged() {
        updateCompressionLevelLabel()
        updateHint()
    }

    @objc private func confirm() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            return
        }
        let password = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = ArchiveCompressionOptions(
            archiveName: name,
            format: selectedFormat,
            stripMacMetadata: stripMetadataCheckbox.state == .on,
            compressionLevel: compressionLevelSlider.integerValue,
            password: password.isEmpty ? nil : password,
            wrapInFolder: wrapFolderCheckbox.state == .on
        )
        window?.close()
        completion(options)
    }

    @objc private func cancel() {
        window?.close()
        onCancel()
    }

    private var selectedFormat: ArchiveFormat {
        guard let raw = formatPopup.selectedItem?.representedObject as? String,
              let format = ArchiveFormat(rawValue: raw) else {
            return .zip
        }
        return format
    }

    private func selectFormat(_ format: ArchiveFormat) {
        for index in 0..<formatPopup.numberOfItems {
            if formatPopup.item(at: index)?.representedObject as? String == format.rawValue {
                formatPopup.selectItem(at: index)
                return
            }
        }
        formatPopup.selectItem(at: 0)
    }

    private func updateHint() {
        let count = urls.count
        let passwordHint = selectedFormat.supportsCompressionPassword ? "可设置密码。" : "该格式不支持密码。"
        let levelHint = selectedFormat.supportsCompressionLevel ? "等级 \(compressionLevelSlider.integerValue)。" : "TAR 不使用压缩等级。"
        hintLabel.stringValue = "将压缩 \(count) 项。\(levelHint)\(passwordHint)"
    }

    private func updateCompressionLevelLabel() {
        compressionLevelLabel.stringValue = selectedFormat.supportsCompressionLevel ? "\(compressionLevelSlider.integerValue)" : "无"
    }

    private func defaultArchiveName() -> String {
        guard urls.count == 1, let first = urls.first else {
            return "压缩包"
        }
        return first.lastPathComponent
    }
}
