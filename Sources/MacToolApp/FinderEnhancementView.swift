import AppKit
import UniformTypeIdentifiers

final class FinderEnhancementView: NSView {
    var onSave: ((ContextMenuConfig) -> Void)?
    var onRepairExtension: (() -> Void)?

    private var config: ContextMenuConfig
    private let extensionStatus: (enabled: Bool?, detail: String)
    private var selectedItemID: ContextMenuItemID
    private let previewStack = NSStackView()
    private let inspectorContainer = NSView()
    private weak var selectedPreviewRow: FinderMenuPreviewRowControl?

    init(config: ContextMenuConfig, extensionStatus: (enabled: Bool?, detail: String)) {
        self.config = config.normalized()
        self.extensionStatus = extensionStatus
        self.selectedItemID = config.items.first?.id ?? .copyPath
        super.init(frame: .zero)
        buildUI()
        rebuildPreview()
        rebuildInspector()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    private func buildUI() {
        translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        root.addArrangedSubview(extensionBanner())
        root.addArrangedSubview(editor())

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func extensionBanner() -> NSView {
        let level: ControlCenterStatusLevel
        let statusTitle: String
        switch extensionStatus.enabled {
        case .some(true):
            level = .normal
            statusTitle = "Finder 扩展运行正常"
        case .some(false):
            level = .attention
            statusTitle = "Finder 扩展尚未启用"
        case .none:
            level = .attention
            statusTitle = "Finder 扩展状态待确认"
        }

        let banner = LayerBackedView(
            backgroundColor: level == .normal ? MacAssistantUI.Color.card : MacAssistantUI.Color.brandTint,
            cornerRadius: MacAssistantUI.Metrics.cornerRadius,
            borderColor: level == .normal ? MacAssistantUI.Color.hairline : MacAssistantUI.Color.brandBorder,
            borderWidth: 1
        )
        banner.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true

        let dot = MacStatusDotView(level: level)
        let title = MacAssistantUI.title(statusTitle, size: 13, weight: .semibold)
        let detail = MacAssistantUI.caption(extensionStatus.detail, size: 11)
        detail.maximumNumberOfLines = 2
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false

        let repair = MacTextButton(title: extensionStatus.enabled == true ? "重新检测" : "修复", role: .primary)
        repair.target = self
        repair.action = #selector(repairExtension)

        banner.addSubview(dot)
        banner.addSubview(text)
        banner.addSubview(repair)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 18),
            dot.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: repair.leadingAnchor, constant: -16),
            repair.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -18),
            repair.centerYAnchor.constraint(equalTo: banner.centerYAnchor)
        ])
        return banner
    }

    private func editor() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let previewPanel = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: MacAssistantUI.Metrics.cornerRadius,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        let inspectorPanel = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: MacAssistantUI.Metrics.cornerRadius,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )

        let previewTitle = MacAssistantUI.title("Finder 菜单预览", size: 13, weight: .semibold)
        let previewDetail = MacAssistantUI.caption("拖动调整顺序；按住 Option 后按方向键也可以排序。", size: 10.5)
        let previewHeader = NSStackView(views: [previewTitle, previewDetail])
        previewHeader.orientation = .vertical
        previewHeader.alignment = .leading
        previewHeader.spacing = 4
        previewHeader.translatesAutoresizingMaskIntoConstraints = false

        previewStack.orientation = .vertical
        previewStack.alignment = .leading
        previewStack.spacing = 0
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        let document = MacFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(previewStack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        previewPanel.addSubview(previewHeader)
        previewPanel.addSubview(scroll)
        NSLayoutConstraint.activate([
            previewHeader.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 16),
            previewHeader.trailingAnchor.constraint(lessThanOrEqualTo: previewPanel.trailingAnchor, constant: -16),
            previewHeader.topAnchor.constraint(equalTo: previewPanel.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: previewHeader.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: previewPanel.bottomAnchor, constant: -8),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: previewStack.heightAnchor),
            previewStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            previewStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            previewStack.topAnchor.constraint(equalTo: document.topAnchor),
            previewStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        inspectorContainer.translatesAutoresizingMaskIntoConstraints = false
        inspectorPanel.addSubview(inspectorContainer)
        NSLayoutConstraint.activate([
            inspectorContainer.leadingAnchor.constraint(equalTo: inspectorPanel.leadingAnchor),
            inspectorContainer.trailingAnchor.constraint(equalTo: inspectorPanel.trailingAnchor),
            inspectorContainer.topAnchor.constraint(equalTo: inspectorPanel.topAnchor),
            inspectorContainer.bottomAnchor.constraint(equalTo: inspectorPanel.bottomAnchor)
        ])

        container.addSubview(previewPanel)
        container.addSubview(inspectorPanel)
        NSLayoutConstraint.activate([
            previewPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewPanel.topAnchor.constraint(equalTo: container.topAnchor),
            previewPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            inspectorPanel.leadingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: 16),
            inspectorPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            inspectorPanel.topAnchor.constraint(equalTo: container.topAnchor),
            inspectorPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            previewPanel.widthAnchor.constraint(equalTo: inspectorPanel.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 440)
        ])
        return container
    }

    private func rebuildPreview() {
        previewStack.arrangedSubviews.forEach {
            previewStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        selectedPreviewRow = nil
        appendPreviewRows(config.items, level: 0)
    }

    private func appendPreviewRows(_ items: [ContextMenuItemConfig], level: Int) {
        for item in items {
            let availability = availability(for: item)
            let row = FinderMenuPreviewRowControl(
                item: item,
                level: level,
                selected: item.id == selectedItemID,
                availability: availability
            )
            row.onSelect = { [weak self] itemID in
                self?.selectedItemID = itemID
                self?.rebuildPreview()
                self?.rebuildInspector()
            }
            row.onMove = { [weak self] itemID, direction in
                self?.moveItem(itemID, direction: direction)
            }
            previewStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: previewStack.widthAnchor).isActive = true
            if item.id == selectedItemID { selectedPreviewRow = row }
            if !item.children.isEmpty {
                appendPreviewRows(item.children, level: level + 1)
            }
        }
    }

    private func rebuildInspector() {
        inspectorContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let item = config.item(for: selectedItemID) else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        inspectorContainer.addSubview(stack)

        let eyebrow = MacAssistantUI.title("菜单项属性", size: 11, weight: .medium)
        eyebrow.textColor = .tertiaryLabelColor
        let title = MacAssistantUI.title(item.displayTitle, size: 16, weight: .semibold)
        stack.addArrangedSubview(eyebrow)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(6, after: eyebrow)

        let enabled = MacSwitchControl()
        enabled.state = item.enabled ? .on : .off
        enabled.target = self
        enabled.action = #selector(enabledChanged(_:))
        stack.addArrangedSubview(inspectorRow(title: "启用", detail: "决定该动作是否出现在 Finder 菜单中。", control: enabled))

        let titleField = MacSearchField()
        titleField.showsSearchIcon = false
        titleField.placeholder = item.id.title
        titleField.text = item.customTitle ?? ""
        titleField.onChange = { [weak self] value in
            self?.updateSelectedItem { $0.customTitle = value }
            self?.selectedPreviewRow?.setTitle(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.id.title : value)
        }
        stack.addArrangedSubview(inspectorRow(title: "显示名称", detail: "留空时使用默认名称“\(item.id.title)”。", control: titleField))
        titleField.widthAnchor.constraint(equalToConstant: 180).isActive = true

        if item.id.supportsCustomTargetApplication {
            let target = item.targetApplication
            let targetButton = MacTextButton(title: target?.displayName.isEmpty == false ? target!.displayName : "选择应用", symbolName: "app", role: .primary)
            targetButton.target = self
            targetButton.action = #selector(chooseTargetApplication)
            stack.addArrangedSubview(inspectorRow(
                title: "目标应用",
                detail: targetApplicationDetail(item),
                control: targetButton
            ))
        } else {
            let note = MacAssistantUI.caption("此动作由系统或归档引擎处理，不能绑定任意应用。", size: 11)
            note.maximumNumberOfLines = 2
            stack.addArrangedSubview(note)
        }

        let availability = availability(for: item)
        let availabilityLabel = MacAssistantUI.caption(availability.detail, size: 11)
        availabilityLabel.textColor = availability.available ? MacAssistantUI.Color.statusGood : MacAssistantUI.Color.statusAttention
        availabilityLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(availabilityLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: inspectorContainer.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: inspectorContainer.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: inspectorContainer.topAnchor, constant: 18)
        ])
    }

    private func inspectorRow(title: String, detail: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        let titleLabel = MacAssistantUI.title(title, size: 12, weight: .semibold)
        let detailLabel = MacAssistantUI.caption(detail, size: 10.5)
        detailLabel.maximumNumberOfLines = 2
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func availability(for item: ContextMenuItemConfig) -> (available: Bool, detail: String) {
        guard item.id.supportsCustomTargetApplication else {
            return (true, "系统动作可用")
        }
        if let target = item.targetApplication {
            if resolvedApplicationURL(target) != nil {
                return (true, "目标应用已安装：\(target.displayName)")
            }
            return (false, "目标应用不可用：\(target.displayName.isEmpty ? target.bundleIdentifier : target.displayName)。配置会保留，重新安装后自动恢复。")
        }

        let defaults: [ContextMenuItemID: (String, [String])] = [
            .openWithIDEA: ("IntelliJ IDEA", ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
            .openWithTypora: ("Typora", ["abnerworks.Typora", "io.typora"]),
            .openWithVSCode: ("Visual Studio Code", ["com.microsoft.VSCode"]),
            .openInTerminal: ("终端", ["com.apple.Terminal"]),
            .openInWarp: ("Warp", ["dev.warp.Warp-Stable", "dev.warp.Warp"])
        ]
        guard let candidate = defaults[item.id] else { return (true, "动作可用") }
        let installed = candidate.1.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return installed
            ? (true, "默认应用已安装：\(candidate.0)")
            : (false, "未安装 \(candidate.0)，此菜单项暂不可用。")
    }

    private func targetApplicationDetail(_ item: ContextMenuItemConfig) -> String {
        guard let target = item.targetApplication else {
            return "未选择时使用该动作的默认应用。"
        }
        if resolvedApplicationURL(target) != nil {
            return "当前绑定 \(target.bundleIdentifier.isEmpty ? target.lastKnownPath : target.bundleIdentifier)"
        }
        return "应用当前不可用，配置已保留。"
    }

    private func resolvedApplicationURL(_ target: FinderTargetApplication) -> URL? {
        if !target.bundleIdentifier.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) {
            return url
        }
        if !target.lastKnownPath.isEmpty, FileManager.default.fileExists(atPath: target.lastKnownPath) {
            return URL(fileURLWithPath: target.lastKnownPath)
        }
        return nil
    }

    private func updateSelectedItem(_ update: (inout ContextMenuItemConfig) -> Void) {
        Self.updateItem(selectedItemID, items: &config.items, update: update)
        config = config.normalized()
        onSave?(config)
    }

    @discardableResult
    private static func updateItem(
        _ id: ContextMenuItemID,
        items: inout [ContextMenuItemConfig],
        update: (inout ContextMenuItemConfig) -> Void
    ) -> Bool {
        for index in items.indices {
            if items[index].id == id {
                update(&items[index])
                return true
            }
            if updateItem(id, items: &items[index].children, update: update) { return true }
        }
        return false
    }

    private func moveItem(_ id: ContextMenuItemID, direction: Int) {
        guard Self.moveItem(id, items: &config.items, direction: direction) else { return }
        config = config.normalized()
        onSave?(config)
        rebuildPreview()
    }

    @discardableResult
    private static func moveItem(
        _ id: ContextMenuItemID,
        items: inout [ContextMenuItemConfig],
        direction: Int
    ) -> Bool {
        if let index = items.firstIndex(where: { $0.id == id }) {
            let target = index + direction
            guard items.indices.contains(target) else { return false }
            items.swapAt(index, target)
            return true
        }
        for index in items.indices {
            if moveItem(id, items: &items[index].children, direction: direction) { return true }
        }
        return false
    }

    @objc private func enabledChanged(_ sender: MacSwitchControl) {
        updateSelectedItem { $0.enabled = sender.state == .on }
        rebuildPreview()
    }

    @objc private func chooseTargetApplication() {
        guard config.item(for: selectedItemID)?.id.supportsCustomTargetApplication == true else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Finder 菜单的目标应用"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundle = Bundle(url: url)
        let target = FinderTargetApplication(
            bundleIdentifier: bundle?.bundleIdentifier ?? "",
            displayName: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
            lastKnownPath: url.path
        )
        updateSelectedItem { $0.targetApplication = target }
        rebuildPreview()
        rebuildInspector()
    }

    @objc private func repairExtension() {
        onRepairExtension?()
    }
}

private final class FinderMenuPreviewRowControl: NSControl {
    var onSelect: ((ContextMenuItemID) -> Void)?
    var onMove: ((ContextMenuItemID, Int) -> Void)?

    private let itemID: ContextMenuItemID
    private let titleLabel = NSTextField(labelWithString: "")
    private var mouseDownPoint: NSPoint?
    private let selected: Bool

    init(
        item: ContextMenuItemConfig,
        level: Int,
        selected: Bool,
        availability: (available: Bool, detail: String)
    ) {
        self.itemID = item.id
        self.selected = selected
        super.init(frame: .zero)
        setup(item: item, level: level, availability: availability)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override var acceptsFirstResponder: Bool { true }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        let end = convert(event.locationInWindow, from: nil)
        let delta = end.y - (mouseDownPoint?.y ?? end.y)
        mouseDownPoint = nil
        if abs(delta) > 18 {
            onMove?(itemID, delta > 0 ? -1 : 1)
        } else {
            onSelect?(itemID)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), event.keyCode == 125 || event.keyCode == 126 {
            onMove?(itemID, event.keyCode == 125 ? 1 : -1)
        } else if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
            onSelect?(itemID)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected {
            MacAssistantUI.Color.sidebarSelected.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
    }

    private func setup(
        item: ContextMenuItemConfig,
        level: Int,
        availability: (available: Bool, detail: String)
    ) {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 46).isActive = true
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.displayTitle)
        setAccessibilityHelp("选择菜单项；按住 Option 使用上下方向键排序")

        let drag = NSImageView(image: MacAssistantUI.symbol("line.3.horizontal", pointSize: 11, weight: .medium) ?? NSImage())
        drag.contentTintColor = .tertiaryLabelColor
        drag.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: MacAssistantUI.symbol(item.id.symbolName, pointSize: 14, weight: .regular) ?? NSImage())
        icon.contentTintColor = item.enabled ? .labelColor : .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = item.displayTitle
        titleLabel.font = .systemFont(ofSize: 12, weight: level == 0 ? .semibold : .regular)
        titleLabel.textColor = item.enabled ? .labelColor : .tertiaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let status = NSTextField(labelWithString: availability.available ? "" : "不可用")
        status.font = .systemFont(ofSize: 9.5, weight: .medium)
        status.textColor = MacAssistantUI.Color.statusAttention
        status.isHidden = availability.available
        status.translatesAutoresizingMaskIntoConstraints = false

        addSubview(drag)
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(status)
        NSLayoutConstraint.activate([
            drag.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10 + CGFloat(level) * 18),
            drag.centerYAnchor.constraint(equalTo: centerYAnchor),
            drag.widthAnchor.constraint(equalToConstant: 13),
            drag.heightAnchor.constraint(equalToConstant: 13),
            icon.leadingAnchor.constraint(equalTo: drag.trailingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -8),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            status.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}
