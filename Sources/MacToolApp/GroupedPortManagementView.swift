import AppKit

final class GroupedPortManagementView: NSView {
    private enum ProtocolFilter: Int, CaseIterable {
        case all
        case tcp
        case udp

        var title: String {
            switch self {
            case .all: return "全部协议"
            case .tcp: return "TCP"
            case .udp: return "UDP"
            }
        }

        func includes(_ usage: PortUsage) -> Bool {
            switch self {
            case .all: return true
            case .tcp: return usage.protocolName == "TCP"
            case .udp: return usage.protocolName == "UDP"
            }
        }
    }

    private enum ScopeFilter: Int, CaseIterable {
        case all
        case local
        case network

        var title: String {
            switch self {
            case .all: return "全部范围"
            case .local: return "仅本机"
            case .network: return "局域网/对外"
            }
        }

        func includes(_ usage: PortUsage) -> Bool {
            switch self {
            case .all: return true
            case .local: return usage.addressScope == .loopback
            case .network: return usage.addressScope == .network
            }
        }
    }

    private let manager = PortManager()
    private let searchField = MacSearchField()
    private let protocolSelect = MacSelectControl()
    private let scopeSelect = MacSelectControl()
    private let refreshButton = MacIconButton(symbolName: "arrow.clockwise")
    private let statusLabel = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private let detailContainer = NSView()
    private var usages: [PortUsage] = []
    private var groups: [PortProcessGroup] = []
    private var selectedGroupID: String?
    private var hasLoaded = false
    private var loading = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func refreshIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refresh()
    }

    private func buildUI() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        root.addArrangedSubview(toolbar())
        root.addArrangedSubview(content())
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func toolbar() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        searchField.placeholder = "搜索端口、应用、PID、地址或路径"
        searchField.onChange = { [weak self] _ in self?.applyFilter() }
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        protocolSelect.items = ProtocolFilter.allCases.map(\.title)
        protocolSelect.target = self
        protocolSelect.action = #selector(filterChanged)
        scopeSelect.items = ScopeFilter.allCases.map(\.title)
        scopeSelect.target = self
        scopeSelect.action = #selector(filterChanged)
        refreshButton.target = self
        refreshButton.action = #selector(refreshAction)
        refreshButton.tintColor = MacAssistantUI.Color.blue
        refreshButton.toolTip = "刷新端口"
        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(searchField)
        row.addSubview(protocolSelect)
        row.addSubview(scopeSelect)
        row.addSubview(statusLabel)
        row.addSubview(refreshButton)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            searchField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            protocolSelect.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 10),
            protocolSelect.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            scopeSelect.leadingAnchor.constraint(equalTo: protocolSelect.trailingAnchor, constant: 8),
            scopeSelect.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scopeSelect.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func content() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 460).isActive = true
        let listPanel = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: MacAssistantUI.Metrics.cornerRadius,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        let header = portListHeader()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = MacFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        scroll.documentView = document
        listPanel.addSubview(header)
        listPanel.addSubview(scroll)

        let detailPanel = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: MacAssistantUI.Metrics.cornerRadius,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.addSubview(detailContainer)

        container.addSubview(listPanel)
        container.addSubview(detailPanel)
        NSLayoutConstraint.activate([
            listPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            listPanel.topAnchor.constraint(equalTo: container.topAnchor),
            listPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            listPanel.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.58),
            header.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: listPanel.topAnchor, constant: 8),
            header.heightAnchor.constraint(equalToConstant: 32),
            scroll.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: listPanel.bottomAnchor, constant: -6),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: listStack.heightAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            detailPanel.leadingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: 12),
            detailPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailPanel.topAnchor.constraint(equalTo: container.topAnchor),
            detailPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: detailPanel.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: detailPanel.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: detailPanel.bottomAnchor)
        ])
        return container
    }

    private func portListHeader() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let app = headerLabel("应用")
        let ports = headerLabel("端口 / 协议")
        let scope = headerLabel("范围")
        row.addSubview(app)
        row.addSubview(ports)
        row.addSubview(scope)
        NSLayoutConstraint.activate([
            app.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            app.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ports.centerXAnchor.constraint(equalTo: row.centerXAnchor, constant: 34),
            ports.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            scope.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            scope.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func headerLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func refresh() {
        guard !loading else { return }
        loading = true
        refreshButton.isEnabled = false
        statusLabel.stringValue = "正在扫描…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.manager.listListeningPorts() }
            DispatchQueue.main.async {
                self.loading = false
                self.refreshButton.spinOnce { [weak self] in self?.refreshButton.isEnabled = true }
                switch result {
                case .success(let usages):
                    self.usages = usages
                    self.applyFilter()
                case .failure(let error):
                    self.usages = []
                    self.groups = []
                    self.statusLabel.stringValue = "扫描失败"
                    self.showAlert(title: "端口查询失败", message: error.localizedDescription)
                    self.rebuildList()
                    self.rebuildDetail()
                }
            }
        }
    }

    private func applyFilter() {
        let protocolFilter = ProtocolFilter(rawValue: protocolSelect.selectedIndex) ?? .all
        let scopeFilter = ScopeFilter(rawValue: scopeSelect.selectedIndex) ?? .all
        let query = searchField.text
        let visibleUsages = usages
            .filter(protocolFilter.includes)
            .filter(scopeFilter.includes)
        groups = PortProcessGroup.grouped(visibleUsages).filter { $0.matches(query) }
        if let selectedGroupID, !groups.contains(where: { $0.id == selectedGroupID }) {
            self.selectedGroupID = nil
        }
        if selectedGroupID == nil { selectedGroupID = groups.first?.id }
        statusLabel.stringValue = "\(groups.count) 个进程 · \(visibleUsages.count) 个端口"
        rebuildList()
        rebuildDetail()
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if groups.isEmpty {
            let label = MacAssistantUI.caption("未发现符合条件的监听端口", size: 11)
            label.alignment = .center
            listStack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            label.heightAnchor.constraint(equalToConstant: 90).isActive = true
            return
        }
        for (index, group) in groups.enumerated() {
            if index > 0 {
                let line = MacAssistantUI.separator()
                listStack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -12).isActive = true
            }
            let row = PortProcessGroupRow(group: group, selected: group.id == selectedGroupID)
            row.onSelect = { [weak self] id in
                self?.selectedGroupID = id
                self?.rebuildList()
                self?.rebuildDetail()
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func rebuildDetail() {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let group = groups.first(where: { $0.id == selectedGroupID }) else {
            let empty = ClipboardPreviewCard.emptyState(title: "选择一个进程", message: "这里会显示 PID、地址、路径和停止操作。", symbolName: "network")
            detailContainer.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 14),
                empty.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -14),
                empty.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor)
            ])
            return
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = MacAssistantUI.title(group.displayName, size: 16, weight: .semibold)
        let scope = PortScopeBadge(scope: group.addressScope)
        let titleRow = NSStackView(views: [title, scope])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        stack.addArrangedSubview(titleRow)
        stack.addArrangedSubview(detailLine("端口", group.ports.map(String.init).joined(separator: ", ")))
        stack.addArrangedSubview(detailLine("协议", group.protocols.joined(separator: " / ")))
        stack.addArrangedSubview(detailLine("PID", "\(group.pid)"))
        stack.addArrangedSubview(detailLine("地址", group.endpoints.joined(separator: "\n"), multiline: true))
        stack.addArrangedSubview(detailLine("路径", group.displayPath, multiline: true))

        let method = MacSelectControl()
        method.items = PortStopMethod.allCases.map(\.displayName)
        method.selectedIndex = 0
        method.setAccessibilityLabel("停止方式")
        method.tag = Int(group.pid)
        let stop = MacTextButton(title: "停止进程", symbolName: "stop.circle", role: .destructive)
        stop.target = self
        stop.action = #selector(stopSelectedProcess(_:))
        let controls = NSStackView(views: [method, stop])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.setAccessibilityLabel("停止进程")
        stop.identifier = NSUserInterfaceItemIdentifier("\(method.selectedIndex)")
        stack.addArrangedSubview(controls)
        stop.toolTip = "停止方式可在左侧选择"
        stop.tag = method.selectedIndex
        method.target = self
        method.action = #selector(stopMethodChanged(_:))

        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 18)
        ])
    }

    private func detailLine(_ title: String, _ value: String, multiline: Bool = false) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        let label = MacAssistantUI.caption(title, size: 10)
        let valueLabel = MacAssistantUI.title(value, size: 11.5, weight: .regular)
        valueLabel.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingMiddle
        valueLabel.maximumNumberOfLines = multiline ? 3 : 1
        row.addArrangedSubview(label)
        row.addArrangedSubview(valueLabel)
        return row
    }

    @objc private func refreshAction() { refresh() }
    @objc private func filterChanged() { applyFilter() }

    @objc private func stopMethodChanged(_ sender: MacSelectControl) {
        guard let controls = sender.superview as? NSStackView,
              let button = controls.arrangedSubviews.compactMap({ $0 as? MacTextButton }).first else { return }
        button.tag = sender.selectedIndex
    }

    @objc private func stopSelectedProcess(_ sender: MacTextButton) {
        guard let group = groups.first(where: { $0.id == selectedGroupID }) else { return }
        let method = PortStopMethod.allCases.indices.contains(sender.tag) ? PortStopMethod.allCases[sender.tag] : .graceful
        let alert = NSAlert()
        alert.alertStyle = method == .kill ? .critical : (method == .terminate ? .warning : .informational)
        alert.messageText = "停止 \(group.displayName)？"
        alert.informativeText = "\(method.riskDescription)\n\n将影响 PID \(group.pid) 及端口：\(group.ports.map(String.init).joined(separator: ", "))。"
        alert.addButton(withTitle: method.displayName)
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try manager.stop(group.primaryUsage, method: method)
            DispatchQueue.main.asyncAfter(deadline: .now() + (method == .graceful ? 1.2 : 0.5)) { [weak self] in self?.refresh() }
        } catch {
            showAlert(title: "停止失败", message: error.localizedDescription)
            refresh()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
private final class PortProcessGroupRow: NSControl {
    var onSelect: ((String) -> Void)?
    private let groupID: String
    private let selected: Bool

    init(group: PortProcessGroup, selected: Bool) {
        groupID = group.id
        self.selected = selected
        super.init(frame: .zero)
        setup(group)
    }

    required init?(coder: NSCoder) { fatalError("未实现 init(coder:)") }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect?(groupID) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 { onSelect?(groupID) }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected {
            MacAssistantUI.Color.sidebarSelected.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
    }

    private func setup(_ group: PortProcessGroup) {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 58).isActive = true
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(group.displayName)，端口 \(group.ports.map(String.init).joined(separator: ", "))")
        let icon = NSImageView(image: MacAssistantUI.symbol("app", pointSize: 15, weight: .medium) ?? NSImage())
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = MacAssistantUI.title(group.displayName, size: 11.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let ports = MacAssistantUI.caption("\(group.ports.map(String.init).joined(separator: ", ")) · \(group.protocols.joined(separator: "/"))", size: 10)
        ports.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, ports])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false
        let scope = PortScopeBadge(scope: group.addressScope)
        addSubview(icon)
        addSubview(text)
        addSubview(scope)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: scope.leadingAnchor, constant: -8),
            scope.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scope.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class PortScopeBadge: NSView {
    private let scope: PortAddressScope
    init(scope: PortAddressScope) {
        self.scope = scope
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: scope == .loopback ? 48 : 78).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(scope.displayName)
    }
    required init?(coder: NSCoder) { fatalError("未实现 init(coder:)") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tint = scope == .loopback ? NSColor.secondaryLabelColor : MacAssistantUI.Color.statusAttention
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        tint.withAlphaComponent(0.10).setFill()
        path.fill()
        tint.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 1
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: tint
        ]
        let size = (scope.displayName as NSString).size(withAttributes: attributes)
        scope.displayName.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
