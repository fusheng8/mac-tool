import AppKit

final class ControlCenterOverviewView: NSView {
    private enum Action: Int {
        case clipboard
        case finder
        case archive
        case displays
        case ports
        case uninstall
        case repairIssue
    }

    var onOpenRoute: ((ControlCenterRoute) -> Void)?
    var onOpenClipboardPanel: (() -> Void)?

    private let snapshot: ControlCenterStatusSnapshot
    private let systemSnapshot: SystemInfoSnapshot

    init(snapshot: ControlCenterStatusSnapshot, systemSnapshot: SystemInfoSnapshot) {
        self.snapshot = snapshot
        self.systemSnapshot = systemSnapshot
        super.init(frame: .zero)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    private func buildUI() {
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stack.addArrangedSubview(statusLine())
        if let issue = snapshot.issues.first {
            let banner = issueBanner(issue)
            stack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let workspace = toolWorkspace()
        stack.addArrangedSubview(workspace)
        workspace.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let systemInformation = systemInformationDisclosure()
        stack.addArrangedSubview(systemInformation)
        systemInformation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func statusLine() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let dot = MacStatusDotView(level: snapshot.level)
        let label = MacAssistantUI.caption(snapshot.headline, size: 13)
        label.textColor = snapshot.level == .normal ? MacAssistantUI.Color.statusGood : MacAssistantUI.Color.statusAttention
        label.font = .systemFont(ofSize: 13, weight: .medium)

        row.addSubview(dot)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func issueBanner(_ issue: ControlCenterIssue) -> NSView {
        let banner = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.brandTint,
            cornerRadius: MacAssistantUI.Metrics.cornerRadius,
            borderColor: MacAssistantUI.Color.brandBorder,
            borderWidth: 1
        )
        banner.heightAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true

        let icon = NSImageView(image: MacAssistantUI.symbol("folder.badge.questionmark", pointSize: 28, weight: .medium) ?? NSImage())
        icon.contentTintColor = MacAssistantUI.Color.blue
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = MacAssistantUI.title("待处理：\(issue.title)", size: 14, weight: .semibold)
        let detail = MacAssistantUI.caption(issue.detail, size: 12)
        detail.maximumNumberOfLines = 2
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5
        text.translatesAutoresizingMaskIntoConstraints = false

        let button = MacTextButton(title: "修复", role: .primary)
        button.target = self
        button.action = #selector(handleAction(_:))
        button.tag = Action.repairIssue.rawValue

        banner.addSubview(icon)
        banner.addSubview(text)
        banner.addSubview(button)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            text.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -18),
            button.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -18),
            button.centerYAnchor.constraint(equalTo: banner.centerYAnchor)
        ])
        return banner
    }

    private func toolWorkspace() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let heading = MacAssistantUI.title("现在可以做什么", size: 17, weight: .semibold)
        let efficiencyTitle = groupTitle("效率工具")
        let systemTitle = groupTitle("系统工具")
        let divider = LayerBackedView(backgroundColor: MacAssistantUI.Color.separator)
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        let left = toolColumn([
            toolRow(symbol: "doc.on.clipboard", title: "搜索剪贴板", detail: "快速搜索并管理历史剪贴板内容。", buttonTitle: "打开", action: .clipboard),
            toolRow(symbol: "folder", title: "管理 Finder 菜单", detail: "自定义右键菜单、顺序和目标应用。", buttonTitle: "管理", action: .finder),
            toolRow(symbol: "archivebox", title: "创建压缩包", detail: "使用预设快速压缩文件或文件夹。", buttonTitle: "创建", action: .archive)
        ])
        let right = toolColumn([
            toolRow(symbol: "display", title: "调整显示器", detail: "管理亮度、音量、分辨率与恢复。", buttonTitle: "调整", action: .displays),
            toolRow(symbol: "network", title: "检查端口", detail: "查看本机监听端口和对外暴露风险。", buttonTitle: "检查", action: .ports),
            toolRow(symbol: "trash", title: "卸载应用", detail: "检查应用本体与残留项后安全清理。", buttonTitle: "卸载", action: .uninstall)
        ])

        container.addSubview(heading)
        container.addSubview(efficiencyTitle)
        container.addSubview(systemTitle)
        container.addSubview(left)
        container.addSubview(divider)
        container.addSubview(right)

        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            heading.topAnchor.constraint(equalTo: container.topAnchor),
            efficiencyTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            efficiencyTitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 30),
            systemTitle.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 34),
            systemTitle.topAnchor.constraint(equalTo: efficiencyTitle.topAnchor),
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            left.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -34),
            left.topAnchor.constraint(equalTo: efficiencyTitle.bottomAnchor, constant: 12),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            divider.topAnchor.constraint(equalTo: efficiencyTitle.topAnchor),
            divider.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 34),
            right.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            right.topAnchor.constraint(equalTo: systemTitle.bottomAnchor, constant: 12),
            right.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            left.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])
        return container
    }

    private func groupTitle(_ text: String) -> NSTextField {
        let label = MacAssistantUI.title(text, size: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func toolColumn(_ rows: [NSView]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = MacAssistantUI.separator()
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func toolRow(
        symbol: String,
        title: String,
        detail: String,
        buttonTitle: String,
        action: Action
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let iconBox = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.controlSurface,
            cornerRadius: 9,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        iconBox.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconBox.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let icon = NSImageView(image: MacAssistantUI.symbol(symbol, pointSize: 20, weight: .regular) ?? NSImage())
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)

        let titleLabel = MacAssistantUI.title(title, size: 13, weight: .semibold)
        let detailLabel = MacAssistantUI.caption(detail, size: 11)
        detailLabel.maximumNumberOfLines = 2
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false

        let button = MacTextButton(title: buttonTitle, role: .primary)
        button.target = self
        button.action = #selector(handleAction(_:))
        button.tag = action.rawValue

        row.addSubview(iconBox)
        row.addSubview(text)
        row.addSubview(button)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            iconBox.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconBox.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 14),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func systemInformationDisclosure() -> NSView {
        let info = MacDisclosureSection(
            title: "系统状态与本机信息",
            detail: "查看 Mac 基本信息与当前运行状态",
            symbolName: "info.circle"
        )
        info.setContent(systemInformationContent())
        return info
    }

    private func systemInformationContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let fields = [
            ("机型", systemSnapshot.modelIdentifier),
            ("处理器", systemSnapshot.cpuBrand),
            ("内存", ByteCountFormatter.string(fromByteCount: Int64(systemSnapshot.physicalMemoryBytes), countStyle: .memory)),
            ("系统", systemSnapshot.operatingSystem)
        ]
        for field in fields {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            let title = MacAssistantUI.caption(field.0, size: 11)
            title.widthAnchor.constraint(equalToConstant: 62).isActive = true
            let value = MacAssistantUI.title(field.1, size: 12, weight: .regular)
            value.lineBreakMode = .byTruncatingMiddle
            row.addArrangedSubview(title)
            row.addArrangedSubview(value)
            stack.addArrangedSubview(row)
        }
        return stack
    }

    @objc private func handleAction(_ sender: MacTextButton) {
        guard let action = Action(rawValue: sender.tag) else { return }
        switch action {
        case .clipboard:
            onOpenClipboardPanel?()
        case .finder:
            onOpenRoute?(.finder)
        case .archive:
            onOpenRoute?(.archive)
        case .displays:
            onOpenRoute?(.displays)
        case .ports:
            onOpenRoute?(.ports)
        case .uninstall:
            onOpenRoute?(.uninstall)
        case .repairIssue:
            onOpenRoute?(snapshot.issues.first?.route ?? .preferences)
        }
    }
}
