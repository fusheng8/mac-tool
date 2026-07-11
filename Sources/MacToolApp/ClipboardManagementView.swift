import AppKit

final class ClipboardManagementView: NSView {
    private enum FilterKey: Equatable {
        case all
        case favorites
        case application(String)
    }

    private let controller: ClipboardHistoryController
    private let searchField = MacSearchField()
    private let applicationFilter = MacSelectControl()
    private let favoritesButton = MacTextButton(title: "收藏", symbolName: "star", role: .neutral)
    private let listStack = NSStackView()
    private let previewContainer = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private var displayedItems: [ClipboardHistoryItem] = []
    private var selectedItemID: UUID?
    private var applicationKeys: [String?] = [nil]
    private var selectedFilter: FilterKey = .all
    private var observer: NSObjectProtocol?

    init(controller: ClipboardHistoryController) {
        self.controller = controller
        super.init(frame: .zero)
        buildUI()
        observer = NotificationCenter.default.addObserver(
            forName: .clipboardHistoryDidChange,
            object: controller,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromController()
        }
        reloadFromController()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func buildUI() {
        translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        root.addArrangedSubview(statusStrip())
        root.addArrangedSubview(toolbar())
        root.addArrangedSubview(contentSplit())

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func statusStrip() -> NSView {
        let config = controller.configuration
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let states: [(String, ControlCenterStatusLevel)] = [
            (config.enabled ? (config.recordingPaused ? "已暂停" : "正在记录") : "未启用", config.enabled && !config.recordingPaused ? .normal : .attention),
            (config.excludeKnownPasswordManagers || !config.excludedBundleIdentifiers.isEmpty ? "隐私排除生效" : "未设置隐私排除", config.excludeKnownPasswordManagers || !config.excludedBundleIdentifiers.isEmpty ? .normal : .attention),
            (controller.encryptionStatus, .normal)
        ]
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        for state in states {
            let item = NSStackView()
            item.orientation = .horizontal
            item.alignment = .centerY
            item.spacing = 7
            item.addArrangedSubview(MacStatusDotView(level: state.1))
            let label = MacAssistantUI.caption(state.0, size: 11)
            label.lineBreakMode = .byTruncatingTail
            item.addArrangedSubview(label)
            stack.addArrangedSubview(item)
        }
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func toolbar() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 38).isActive = true

        searchField.placeholder = "搜索剪贴板"
        searchField.onChange = { [weak self] _ in self?.performSearch() }
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        applicationFilter.target = self
        applicationFilter.action = #selector(applicationFilterChanged)
        favoritesButton.target = self
        favoritesButton.action = #selector(toggleFavoritesFilter)

        countLabel.font = .systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(searchField)
        row.addSubview(applicationFilter)
        row.addSubview(favoritesButton)
        row.addSubview(countLabel)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            searchField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            applicationFilter.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 10),
            applicationFilter.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            favoritesButton.leadingAnchor.constraint(equalTo: applicationFilter.trailingAnchor, constant: 8),
            favoritesButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: favoritesButton.trailingAnchor, constant: 12),
            countLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func contentSplit() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 440).isActive = true

        let listPanel = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: MacAssistantUI.Metrics.cornerRadius,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        let listHeader = MacAssistantUI.title("历史记录", size: 12, weight: .semibold)
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
        listPanel.addSubview(listHeader)
        listPanel.addSubview(scroll)

        let previewPanel = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: MacAssistantUI.Metrics.cornerRadius,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewPanel.addSubview(previewContainer)

        container.addSubview(listPanel)
        container.addSubview(previewPanel)
        NSLayoutConstraint.activate([
            listPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            listPanel.topAnchor.constraint(equalTo: container.topAnchor),
            listPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            listPanel.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.44),
            listHeader.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: 14),
            listHeader.topAnchor.constraint(equalTo: listPanel.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: listHeader.bottomAnchor, constant: 10),
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
            previewPanel.leadingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: 14),
            previewPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewPanel.topAnchor.constraint(equalTo: container.topAnchor),
            previewPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor),
            previewContainer.topAnchor.constraint(equalTo: previewPanel.topAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: previewPanel.bottomAnchor)
        ])
        return container
    }

    private func reloadFromController() {
        rebuildApplicationFilter()
        performSearch()
    }

    private func rebuildApplicationFilter() {
        var seen: Set<String> = []
        let apps = controller.history.compactMap { item -> (String, String)? in
            let key = applicationKey(for: item)
            guard seen.insert(key).inserted else { return nil }
            return (key, item.sourceApplicationName)
        }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }

        let currentKey: String?
        if case .application(let value) = selectedFilter { currentKey = value } else { currentKey = nil }
        applicationFilter.items = ["全部应用"] + apps.map(\.1)
        applicationKeys = [nil] + apps.map(\.0)
        if let currentKey, let index = applicationKeys.firstIndex(where: { $0 == currentKey }) {
            applicationFilter.selectedIndex = index
        } else {
            applicationFilter.selectedIndex = 0
            if case .application = selectedFilter { selectedFilter = .all }
        }
    }

    private func performSearch() {
        let query = searchField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let applicationKey: String?
        let favoritesOnly: Bool
        switch selectedFilter {
        case .all:
            applicationKey = nil
            favoritesOnly = false
        case .favorites:
            applicationKey = nil
            favoritesOnly = true
        case .application(let key):
            applicationKey = key
            favoritesOnly = false
        }
        controller.searchHistoryAsync(
            query,
            applicationKey: applicationKey,
            favoritesOnly: favoritesOnly
        ) { [weak self] items in
            self?.apply(items: items)
        }
    }

    private func apply(items: [ClipboardHistoryItem]) {
        displayedItems = items
        if let selectedItemID, !items.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = nil
        }
        if selectedItemID == nil { selectedItemID = items.first?.id }
        countLabel.stringValue = "(items.count) 条"
        rebuildList()
        rebuildPreview()
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if displayedItems.isEmpty {
            let empty = MacAssistantUI.caption("没有符合条件的剪贴板记录", size: 11)
            empty.alignment = .center
            listStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 80).isActive = true
            return
        }
        for (index, item) in displayedItems.enumerated() {
            if index > 0 {
                let line = MacAssistantUI.separator()
                listStack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -16).isActive = true
            }
            let row = ClipboardManagementRowControl(item: item, selected: item.id == selectedItemID)
            row.onSelect = { [weak self] id in
                self?.selectedItemID = id
                self?.rebuildList()
                self?.rebuildPreview()
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func rebuildPreview() {
        previewContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let item = displayedItems.first(where: { $0.id == selectedItemID }) else {
            let empty = ClipboardPreviewCard.emptyState(title: "选择一条记录", message: "右侧将显示完整内容和元数据。")
            previewContainer.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 14),
                empty.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -14),
                empty.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor)
            ])
            return
        }

        let descriptor = ClipboardPreviewSupport.descriptor(
            for: item,
            previewURL: controller.thumbnailURL(for: item),
            structuredTextLimitBytes: controller.configuration.structuredPreviewLimitBytes
        )
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(stack)

        stack.addArrangedSubview(previewHeader(item: item, descriptor: descriptor))
        let body = previewBody(item: item, descriptor: descriptor)
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -14)
        ])

        if descriptor.kind == .image, controller.thumbnailURL(for: item) == nil {
            controller.ensureThumbnail(for: item) { [weak self] itemID, _ in
                guard self?.selectedItemID == itemID else { return }
                self?.rebuildPreview()
            }
        }
    }

    private func previewHeader(item: ClipboardHistoryItem, descriptor: ClipboardPreviewDescriptor) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let icon = NSImageView(image: MacAssistantUI.symbol(descriptor.symbolName, pointSize: 18, weight: .medium) ?? NSImage())
        icon.contentTintColor = descriptor.tintColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = MacAssistantUI.title(descriptor.title, size: 14, weight: .semibold)
        let detail = MacAssistantUI.caption("\(item.sourceApplicationName) · \(Self.relativeDate(item.createdAt))", size: 10.5)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false
        let favorite = MacTextButton(title: item.isFavorite ? "取消收藏" : "收藏", symbolName: item.isFavorite ? "star.slash" : "star", role: .neutral)
        favorite.target = self
        favorite.action = #selector(toggleSelectedFavorite)
        let delete = MacIconButton(symbolName: "trash")
        delete.tintColor = .systemRed
        delete.target = self
        delete.action = #selector(deleteSelectedItem)
        row.addSubview(icon)
        row.addSubview(text)
        row.addSubview(favorite)
        row.addSubview(delete)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: favorite.leadingAnchor, constant: -10),
            delete.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            delete.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            favorite.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -8),
            favorite.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func previewBody(item: ClipboardHistoryItem, descriptor: ClipboardPreviewDescriptor) -> NSView {
        switch descriptor.kind {
        case .image:
            return ClipboardPreviewImageView(image: descriptor.url.flatMap(NSImage.init(contentsOf:)), title: nil)
        case .url:
            if let url = descriptor.url { return ClipboardPreviewURLCardView(url: url, title: nil) }
            return ClipboardPreviewTextView(text: descriptor.displayText ?? "", title: nil)
        case .table:
            return ClipboardPreviewTableView(rows: descriptor.tableRows, title: nil)
        case .file:
            let paths = item.metadata.sourcePaths.isEmpty
                ? item.plainText.components(separatedBy: .newlines)
                : item.metadata.sourcePaths
            return ClipboardPreviewFileListView(items: paths.map { ClipboardPreviewFileListView.Item(path: $0) }, title: nil)
        case .json, .code:
            return ClipboardPreviewTextView(
                text: descriptor.formattedJSON ?? descriptor.displayText ?? "",
                mode: .code,
                showsLineNumbers: true,
                title: nil
            )
        case .markdown, .richText, .text:
            return ClipboardPreviewTextView(text: descriptor.displayText ?? "", mode: .plain, title: nil)
        }
    }

    private func applicationKey(for item: ClipboardHistoryItem) -> String {
        let bundle = item.sourceBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return bundle.isEmpty ? item.sourceApplicationName.lowercased() : bundle
    }

    @objc private func applicationFilterChanged() {
        let index = applicationFilter.selectedIndex
        if applicationKeys.indices.contains(index), let key = applicationKeys[index] {
            selectedFilter = .application(key)
        } else {
            selectedFilter = .all
        }
        favoritesButton.title = "收藏"
        performSearch()
    }

    @objc private func toggleFavoritesFilter() {
        if selectedFilter == .favorites {
            selectedFilter = .all
            favoritesButton.title = "收藏"
        } else {
            selectedFilter = .favorites
            applicationFilter.selectedIndex = 0
            favoritesButton.title = "仅收藏"
        }
        performSearch()
    }

    @objc private func toggleSelectedFavorite() {
        guard let item = displayedItems.first(where: { $0.id == selectedItemID }) else { return }
        controller.toggleFavorite(item)
    }

    @objc private func deleteSelectedItem() {
        guard let item = displayedItems.first(where: { $0.id == selectedItemID }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这条剪贴板记录？"
        alert.informativeText = item.isFavorite ? "这条记录已收藏，删除后无法恢复。" : "删除后无法恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        selectedItemID = nil
        controller.delete(item)
    }

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
private final class ClipboardManagementRowControl: NSControl {
    var onSelect: ((UUID) -> Void)?
    private let itemID: UUID
    private let selected: Bool

    init(item: ClipboardHistoryItem, selected: Bool) {
        itemID = item.id
        self.selected = selected
        super.init(frame: .zero)
        setup(item)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect?(itemID) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 { onSelect?(itemID) }
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected {
            MacAssistantUI.Color.sidebarSelected.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
    }

    private func setup(_ item: ClipboardHistoryItem) {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 62).isActive = true
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.previewText.isEmpty ? item.metadata.contentType : item.previewText)

        let descriptor = ClipboardPreviewSupport.descriptor(for: item)
        let icon = NSImageView(image: MacAssistantUI.symbol(descriptor.symbolName, pointSize: 15, weight: .medium) ?? NSImage())
        icon.contentTintColor = descriptor.tintColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = MacAssistantUI.title(Self.oneLine(item.previewText, fallback: item.metadata.contentType), size: 11.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = MacAssistantUI.caption(item.sourceApplicationName, size: 10)
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false
        let favorite = NSImageView(image: item.isFavorite ? (MacAssistantUI.symbol("star.fill", pointSize: 10, weight: .semibold) ?? NSImage()) : NSImage())
        favorite.contentTintColor = MacAssistantUI.Color.statusAttention
        favorite.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(text)
        addSubview(favorite)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: favorite.leadingAnchor, constant: -8),
            favorite.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            favorite.centerYAnchor.constraint(equalTo: centerYAnchor),
            favorite.widthAnchor.constraint(equalToConstant: 12),
            favorite.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    private static func oneLine(_ text: String, fallback: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? fallback : line
    }
}
