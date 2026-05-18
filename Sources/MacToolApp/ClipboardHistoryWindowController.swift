import AppKit
import Foundation
import QuickLookUI

final class ClipboardHistoryWindowController: NSWindowController, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private enum Layout {
        static let defaultSize = NSSize(width: 320, height: 500)
        static let minSize = NSSize(width: 300, height: 420)
        static let screenMargin: CGFloat = 36
        static let rowHeight: CGFloat = 66
        static let rowSpacing: CGFloat = 2
        static let rowOverscan = 4
        static let deferredListRebuildDelay: TimeInterval = 0.018
    }

    private enum Filter {
        static let allApplications = "__all__"
        static let favorites = "__favorites__"
    }

    private let controller: ClipboardHistoryController
    private let searchField = MacSearchField()
    private let filterScrollView = ClipboardFilterScrollView()
    private let filterDocumentView = ClipboardFlippedView()
    private let filterStack = NSStackView()
    private let clearButton = MacIconButton(symbolName: "trash")
    private let pinButton = MacIconButton(symbolName: "pin")
    private let listScrollView = NSScrollView()
    private let listStack = NSStackView()
    private let footerCountLabel = NSTextField(labelWithString: "")
    private let footerActionLabel = NSTextField(labelWithString: "")
    private var localOutsideClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?
    private var selectedApplication = Filter.allApplications
    private var selectedItemID: UUID?
    private var displayedItems: [ClipboardHistoryItem] = []
    private var rowViewsByID: [UUID: ClipboardHistoryRowView] = [:]
    private let listTopSpacer = NSView()
    private let listBottomSpacer = NSView()
    private var listTopSpacerHeightConstraint: NSLayoutConstraint?
    private var listBottomSpacerHeightConstraint: NSLayoutConstraint?
    private weak var emptyListView: NSView?
    private var renderGeneration = 0
    private var renderedRange: Range<Int> = 0..<0
    private var pendingListRebuildWorkItem: DispatchWorkItem?
    private var pendingListRebuildID = 0
    private var shortcutHintedItemIDs = Set<UUID>()
    private var isPinned = false
    private var quickLookItem: ClipboardQuickLookItem?
    private var quickLookCleanupURL: URL?
    private var quickLookKeyMonitor: Any?

    init(controller: ClipboardHistoryController) {
        self.controller = controller
        let panel = ClipboardPanel(
            contentRect: NSRect(origin: .zero, size: Layout.defaultSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.minSize = Layout.minSize
        panel.maxSize = Layout.defaultSize
        super.init(window: panel)
        panel.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        panel.onOrderOut = { [weak self] in
            self?.closeQuickLookPreview()
            self?.removeOutsideClickMonitors()
        }
        buildUI()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func showPanel() {
        resetPanelSize()
        positionAtTopRight()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(nil)
        installOutsideClickMonitors()
        clearSelection()
        window?.layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.rebuildApplicationFilter()
            self.rebuildList()
        }
    }

    func reload() {
        rebuildApplicationFilter()
        rebuildList()
    }

    func hideIfNeededAfterPaste() {
        if !isPinned {
            window?.orderOut(nil)
        }
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = MacAssistantUI.Color.window.cgColor
        contentView.layer?.cornerRadius = 14
        contentView.layer?.cornerCurve = .continuous

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        root.addArrangedSubview(buildHeader())
        root.addArrangedSubview(buildFilterBar())
        root.addArrangedSubview(buildScrollView())
        root.addArrangedSubview(buildFooter())
    }

    private func resetPanelSize() {
        guard let window else { return }
        window.setContentSize(Layout.defaultSize)
        window.layoutIfNeeded()
    }

    private func positionAtTopRight() {
        guard let window else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        var frame = window.frame
        if frame.width > visibleFrame.width - Layout.screenMargin * 2 ||
            frame.height > visibleFrame.height - Layout.screenMargin * 2 {
            let contentSize = NSSize(
                width: min(Layout.defaultSize.width, visibleFrame.width - Layout.screenMargin * 2),
                height: min(Layout.defaultSize.height, visibleFrame.height - Layout.screenMargin * 2)
            )
            window.setContentSize(contentSize)
            frame = window.frame
        }

        let targetX = visibleFrame.maxX - frame.width - Layout.screenMargin
        let targetY = visibleFrame.maxY - frame.height - Layout.screenMargin
        frame.origin.x = min(max(targetX, visibleFrame.minX + Layout.screenMargin), visibleFrame.maxX - frame.width - Layout.screenMargin)
        frame.origin.y = min(max(targetY, visibleFrame.minY + Layout.screenMargin), visibleFrame.maxY - frame.height - Layout.screenMargin)
        window.setFrame(frame, display: true)
    }

    private func buildHeader() -> NSView {
        let header = LayerBackedView(backgroundColor: NSColor.white.withAlphaComponent(0.42))
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 52).isActive = true

        searchField.placeholder = "搜索剪切板..."
        searchField.onChange = { [weak self] _ in
            self?.scheduleListRebuild()
        }
        searchField.onKeyCommand = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        header.addSubview(searchField)

        clearButton.tintColor = .secondaryLabelColor
        clearButton.style = .subtle
        clearButton.target = self
        clearButton.action = #selector(showClearMenu)
        clearButton.toolTip = "清理历史"
        header.addSubview(clearButton)

        pinButton.tintColor = .secondaryLabelColor
        pinButton.style = .subtle
        pinButton.target = self
        pinButton.action = #selector(togglePinned)
        pinButton.toolTip = "置顶面板"
        header.addSubview(pinButton)

        let divider = MacAssistantUI.separator()
        header.addSubview(divider)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            clearButton.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            pinButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            pinButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])

        return header
    }

    private func buildFilterBar() -> NSView {
        let bar = LayerBackedView(backgroundColor: NSColor.white.withAlphaComponent(0.20))
        bar.layer?.masksToBounds = true
        bar.heightAnchor.constraint(equalToConstant: 40).isActive = true

        filterScrollView.hasVerticalScroller = false
        filterScrollView.hasHorizontalScroller = false
        filterScrollView.scrollerStyle = .overlay
        filterScrollView.drawsBackground = false
        filterScrollView.autohidesScrollers = true
        filterScrollView.horizontalScrollElasticity = .allowed
        filterScrollView.verticalScrollElasticity = .none
        filterScrollView.translatesAutoresizingMaskIntoConstraints = false

        filterDocumentView.translatesAutoresizingMaskIntoConstraints = true
        filterDocumentView.frame = NSRect(x: 0, y: 0, width: Layout.defaultSize.width, height: 39)
        filterScrollView.documentView = filterDocumentView

        filterStack.orientation = .horizontal
        filterStack.alignment = .centerY
        filterStack.spacing = 8
        filterStack.translatesAutoresizingMaskIntoConstraints = false
        filterDocumentView.addSubview(filterStack)
        bar.addSubview(filterScrollView)

        let divider = MacAssistantUI.separator()
        bar.addSubview(divider)

        NSLayoutConstraint.activate([
            filterScrollView.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            filterScrollView.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            filterScrollView.topAnchor.constraint(equalTo: bar.topAnchor),
            filterScrollView.bottomAnchor.constraint(equalTo: divider.topAnchor),

            filterStack.leadingAnchor.constraint(equalTo: filterDocumentView.leadingAnchor, constant: 10),
            filterStack.trailingAnchor.constraint(equalTo: filterDocumentView.trailingAnchor, constant: -10),
            filterStack.centerYAnchor.constraint(equalTo: filterDocumentView.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
        ])
        return bar
    }

    private func buildScrollView() -> NSScrollView {
        let scrollView = listScrollView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .centerX
        listStack.spacing = Layout.rowSpacing
        listStack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        configureVirtualListSpacer(listTopSpacer, constraint: &listTopSpacerHeightConstraint)
        configureVirtualListSpacer(listBottomSpacer, constraint: &listBottomSpacerHeightConstraint)

        let documentView = ClipboardFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(listStack)
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(listScrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: listStack.heightAnchor),

            listStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
        return scrollView
    }

    private func buildFooter() -> NSView {
        let footer = NSView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.heightAnchor.constraint(equalToConstant: 32).isActive = true

        [footerCountLabel, footerActionLabel].forEach { label in
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(label)
        }
        footerCountLabel.alignment = .left
        footerActionLabel.alignment = .right

        NSLayoutConstraint.activate([
            footerCountLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            footerCountLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            footerActionLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            footerActionLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footerActionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: footerCountLabel.trailingAnchor, constant: 12)
        ])
        return footer
    }

    private func rebuildApplicationFilter() {
        let current = selectedApplication
        filterStack.arrangedSubviews.forEach { view in
            filterStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        filterStack.addArrangedSubview(filterButton(title: "全部应用", bundleId: Filter.allApplications, selected: current == Filter.allApplications))
        filterStack.addArrangedSubview(filterButton(title: "收藏", bundleId: Filter.favorites, selected: current == Filter.favorites))

        var seenAppKeys = Set<String>()
        let apps = controller.history.compactMap { item -> (String, String)? in
            let filterKey = appFilterKey(for: item)
            guard seenAppKeys.insert(filterKey).inserted else { return nil }
            return (filterKey, item.sourceApplicationName)
        }

        for (filterKey, name) in apps {
            filterStack.addArrangedSubview(filterButton(title: name, bundleId: filterKey, selected: filterKey == current))
        }

        if current != Filter.allApplications && current != Filter.favorites && !apps.contains(where: { $0.0 == current }) {
            selectedApplication = Filter.allApplications
            rebuildApplicationFilter()
            return
        }

        updateFilterDocumentWidth()
        scrollSelectedApplicationFilterToVisible()
    }

    private func updateApplicationFilterSelection() {
        for button in filterStack.arrangedSubviews.compactMap({ $0 as? AppFilterButton }) {
            button.setSelected(button.bundleId == selectedApplication)
        }
        updateFilterDocumentWidth()
        scrollSelectedApplicationFilterToVisible()
    }

    private func filterButton(title: String, bundleId: String, selected: Bool) -> AppFilterButton {
        let button = AppFilterButton(title: title, bundleId: bundleId, selected: selected, target: self, action: #selector(filterButtonPressed(_:)))
        return button
    }

    private func updateFilterDocumentWidth() {
        filterStack.layoutSubtreeIfNeeded()
        let itemWidth = filterStack.arrangedSubviews.reduce(CGFloat.zero) { total, view in
            total + view.fittingSize.width
        }
        let spacingWidth = filterStack.spacing * CGFloat(max(0, filterStack.arrangedSubviews.count - 1))
        let contentWidth = itemWidth + spacingWidth + 20
        let visibleWidth = filterScrollView.contentView.bounds.width
        let documentWidth = max(Layout.defaultSize.width, visibleWidth, contentWidth)
        let documentHeight = max(filterScrollView.contentView.bounds.height, 39)
        filterDocumentView.setFrameSize(NSSize(width: documentWidth, height: documentHeight))
        filterDocumentView.layoutSubtreeIfNeeded()

        var origin = filterScrollView.contentView.bounds.origin
        origin.x = min(origin.x, max(0, documentWidth - visibleWidth))
        filterScrollView.contentView.scroll(to: origin)
        filterScrollView.reflectScrolledClipView(filterScrollView.contentView)
    }

    private func rebuildList() {
        pendingListRebuildWorkItem?.cancel()
        pendingListRebuildWorkItem = nil
        renderGeneration += 1
        let generation = renderGeneration

        let items = filteredItems()
        displayedItems = items
        validateSelection(in: items)
        pruneReusableRows()
        updateFooter()
        if items.isEmpty {
            renderedRange = 0..<0
            if controller.isLoadingHistory {
                showEmptyList(
                    title: "正在加载剪贴板历史",
                    detail: "历史较多时会先打开面板，再在后台载入内容。",
                    symbolName: "clock"
                )
                updateVisibleShortcutHints()
                return
            }
            showEmptyList(
                title: controller.history.isEmpty ? "暂无剪贴板历史" : "没有匹配结果",
                detail: controller.history.isEmpty ? "复制内容后会出现在这里。" : "换个关键词或切换到全部应用。",
                symbolName: controller.history.isEmpty ? "doc.on.clipboard" : "magnifyingglass"
            )
        } else {
            hideEmptyList()
            scrollListToTop()
            renderRows(from: items, range: visibleRenderRange(for: items), generation: generation)
        }
        updateVisibleShortcutHints()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderGeneration == generation else { return }
            self.updateVisibleShortcutHints()
        }
    }

    private var rowStride: CGFloat {
        Layout.rowHeight + Layout.rowSpacing
    }

    private func configureVirtualListSpacer(_ spacer: NSView, constraint: inout NSLayoutConstraint?) {
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.isHidden = true
        let height = spacer.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        constraint = height
    }

    private func ensureVirtualListSpacers() {
        if listTopSpacer.superview == nil {
            listStack.insertArrangedSubview(listTopSpacer, at: 0)
        }
        if listBottomSpacer.superview == nil {
            listStack.addArrangedSubview(listBottomSpacer)
        } else if listStack.arrangedSubviews.last !== listBottomSpacer {
            listStack.removeArrangedSubview(listBottomSpacer)
            listStack.addArrangedSubview(listBottomSpacer)
        }
        listTopSpacer.isHidden = false
        listBottomSpacer.isHidden = false
    }

    private func removeVirtualListSpacers() {
        setVirtualSpacerHeights(top: 0, bottom: 0)
        for spacer in [listTopSpacer, listBottomSpacer] where spacer.superview != nil {
            listStack.removeArrangedSubview(spacer)
            spacer.removeFromSuperview()
            spacer.isHidden = true
        }
    }

    private func setVirtualSpacerHeights(top: CGFloat, bottom: CGFloat) {
        listTopSpacerHeightConstraint?.constant = max(0, top)
        listBottomSpacerHeightConstraint?.constant = max(0, bottom)
    }

    private func visibleRenderRange(for items: [ClipboardHistoryItem]) -> Range<Int> {
        guard !items.isEmpty else { return 0..<0 }
        let viewportHeight = max(
            listScrollView.contentView.bounds.height,
            Layout.defaultSize.height - 52 - 40 - 32
        )
        let visibleMinY = max(0, listScrollView.contentView.bounds.minY)
        let overscanHeight = CGFloat(Layout.rowOverscan) * rowStride
        let start = min(items.count - 1, max(0, Int(floor((visibleMinY - overscanHeight) / rowStride))))
        let end = min(items.count, Int(ceil((visibleMinY + viewportHeight + overscanHeight) / rowStride)) + 1)
        return start..<max(start + 1, end)
    }

    private func updateRenderedRowsForScroll() {
        guard !displayedItems.isEmpty else { return }
        let nextRange = visibleRenderRange(for: displayedItems)
        guard nextRange != renderedRange else { return }
        renderGeneration += 1
        renderRows(from: displayedItems, range: nextRange, generation: renderGeneration)
    }

    private func renderRows(from items: [ClipboardHistoryItem], range: Range<Int>, generation: Int) {
        guard renderGeneration == generation,
              !items.isEmpty else {
            return
        }

        let clampedStart = min(max(range.lowerBound, 0), items.count)
        let clampedEnd = min(max(range.upperBound, clampedStart), items.count)
        let clampedRange = clampedStart..<clampedEnd
        renderedRange = clampedRange
        ensureVirtualListSpacers()
        setVirtualSpacerHeights(top: CGFloat(clampedStart) * rowStride, bottom: CGFloat(items.count - clampedEnd) * rowStride)
        reconcileRows(Array(items[clampedRange]))
        updateVisibleShortcutHints()
    }

    private func constrainListItemWidth(_ view: NSView) {
        guard view.superview != nil else { return }
        if view.constraints.contains(where: { constraint in
            constraint.firstAttribute == .width && constraint.firstItem === view
        }) {
            return
        }
        view.widthAnchor.constraint(equalTo: listScrollView.contentView.widthAnchor, constant: -8).isActive = true
    }

    private func showEmptyList(title: String, detail: String, symbolName: String) {
        removeArrangedRows()
        removeVirtualListSpacers()
        clearVisibleShortcutHints()
        if let emptyListView {
            emptyListView.removeFromSuperview()
        }
        let empty = emptyState(title: title, detail: detail, symbolName: symbolName)
        emptyListView = empty
        listStack.addArrangedSubview(empty)
        constrainListItemWidth(empty)
    }

    private func hideEmptyList() {
        guard let emptyListView else { return }
        listStack.removeArrangedSubview(emptyListView)
        emptyListView.removeFromSuperview()
        self.emptyListView = nil
        ensureVirtualListSpacers()
    }

    private func removeArrangedRows() {
        for view in listStack.arrangedSubviews where view is ClipboardHistoryRowView {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func pruneReusableRows() {
        let validIDs = Set(controller.history.map(\.id))
        let staleIDs = rowViewsByID.keys.filter { !validIDs.contains($0) }
        for id in staleIDs {
            guard let row = rowViewsByID[id] else { continue }
            listStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            rowViewsByID[id] = nil
            shortcutHintedItemIDs.remove(id)
        }
    }

    private func reconcileRows(_ items: [ClipboardHistoryItem]) {
        ensureVirtualListSpacers()
        let targetIDs = Set(items.map(\.id))
        for view in listStack.arrangedSubviews {
            guard let row = view as? ClipboardHistoryRowView,
                  !targetIDs.contains(row.itemID) else {
                continue
            }
            listStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            rowViewsByID[row.itemID] = nil
            shortcutHintedItemIDs.remove(row.itemID)
        }

        for id in Array(rowViewsByID.keys) where !targetIDs.contains(id) {
            if let row = rowViewsByID[id], row.superview != nil {
                listStack.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rowViewsByID[id] = nil
            shortcutHintedItemIDs.remove(id)
        }

        for (index, item) in items.enumerated() {
            let row = reusableRow(for: item)
            row.update(item: item, selected: selectedItemID == item.id)

            let currentIndex = listStack.arrangedSubviews.firstIndex(of: row)
            let targetIndex = index + 1
            if currentIndex == targetIndex {
                continue
            }
            if currentIndex != nil {
                listStack.removeArrangedSubview(row)
            }
            let insertionIndex = min(targetIndex, max(0, listStack.arrangedSubviews.count - 1))
            listStack.insertArrangedSubview(row, at: insertionIndex)
            constrainListItemWidth(row)
        }
    }

    private func reusableRow(for item: ClipboardHistoryItem) -> ClipboardHistoryRowView {
        if let row = rowViewsByID[item.id] {
            return row
        }
        let row = makeRow(for: item)
        rowViewsByID[item.id] = row
        return row
    }

    private func makeRow(for item: ClipboardHistoryItem) -> ClipboardHistoryRowView {
        let row = ClipboardHistoryRowView(
            item: item,
            selected: selectedItemID == item.id,
            onSelect: { [weak self] selected in
                self?.selectItem(selected.id, scrollToSelection: false)
            },
            onPaste: { [weak self] selected, mode in
                self?.controller.paste(selected, mode: mode)
            },
            onToggleFavorite: { [weak self] selected in
                self?.controller.toggleFavorite(selected)
                self?.rebuildApplicationFilter()
            },
            onDelete: { [weak self] selected in
                self?.controller.delete(selected)
                self?.rebuildApplicationFilter()
            },
            thumbnailURL: { [weak self] selected in
                self?.controller.thumbnailURL(for: selected)
            },
            requestThumbnail: { [weak self] selected, completion in
                self?.controller.ensureThumbnail(for: selected, completion: completion)
            }
        )
        return row
    }

    private func scrollListToTop() {
        listScrollView.contentView.scroll(to: .zero)
        listScrollView.reflectScrolledClipView(listScrollView.contentView)
    }

    private func updateFooter() {
        let favoriteCount = controller.history.filter(\.isFavorite).count
        footerCountLabel.stringValue = favoriteCount > 0
            ? "共 \(controller.history.count) 条记录，\(favoriteCount) 条收藏"
            : "共 \(controller.history.count) 条记录"
        let shortcuts = controller.configuration.shortcuts
        let pasteBinding = shortcuts.binding(for: .pasteSelected)
        let menuBinding = shortcuts.binding(for: .showActionsMenu)
        let pasteText = pasteBinding.enabled ? "\(pasteBinding.hotKey.displayText) 粘贴" : "右键粘贴"
        let menuText = menuBinding.enabled ? "\(menuBinding.hotKey.displayText) 更多" : "右键更多"
        footerActionLabel.stringValue = "\(pasteText)  |  \(menuText)"
    }

    private func filteredItems() -> [ClipboardHistoryItem] {
        let search = searchField.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source: [ClipboardHistoryItem]
        if search.isEmpty {
            source = controller.history
        } else {
            let applicationKey = selectedApplication == Filter.allApplications || selectedApplication == Filter.favorites
                ? nil
                : selectedApplication
            source = controller.searchHistory(
                search,
                applicationKey: applicationKey,
                favoritesOnly: selectedApplication == Filter.favorites,
                limit: controller.configuration.maxHistoryCount
            )
        }
        return source.filter { item in
            if selectedApplication == Filter.favorites && !item.isFavorite {
                return false
            }
            if selectedApplication != Filter.allApplications && selectedApplication != Filter.favorites && appFilterKey(for: item) != selectedApplication {
                return false
            }
            return true
        }
    }

    private func appFilterKey(for item: ClipboardHistoryItem) -> String {
        let bundleId = item.sourceBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bundleId.isEmpty {
            return "app:\(bundleId)"
        }
        return "app-name:\(item.sourceApplicationName)"
    }

    @objc private func filterButtonPressed(_ sender: AppFilterButton) {
        selectApplicationFilter(sender.bundleId)
    }

    @objc private func listScrollViewDidScroll() {
        updateRenderedRowsForScroll()
        updateVisibleShortcutHints()
    }

    private func selectRelativeApplicationFilter(_ offset: Int) -> Bool {
        let buttons = filterStack.arrangedSubviews.compactMap { $0 as? AppFilterButton }
        guard buttons.count > 1 else { return false }

        guard let currentIndex = buttons.firstIndex(where: { $0.bundleId == selectedApplication }) else { return false }

        let targetIndex = min(max(currentIndex + offset, 0), buttons.count - 1)
        guard targetIndex != currentIndex else { return true }

        selectApplicationFilter(buttons[targetIndex].bundleId)
        return true
    }

    private func selectApplicationFilter(_ bundleId: String) {
        guard selectedApplication != bundleId else { return }
        selectedApplication = bundleId
        selectedItemID = nil
        updateApplicationFilterSelection()
        scheduleListRebuild()
        DispatchQueue.main.async { [weak self] in
            self?.scrollSelectedApplicationFilterToVisible()
        }
    }

    private func scheduleListRebuild() {
        renderGeneration += 1
        pendingListRebuildID += 1
        let rebuildID = pendingListRebuildID
        pendingListRebuildWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingListRebuildID == rebuildID,
                  self.pendingListRebuildWorkItem?.isCancelled == false else {
                return
            }
            self.pendingListRebuildWorkItem = nil
            self.rebuildList()
        }
        pendingListRebuildWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.deferredListRebuildDelay, execute: workItem)
    }

    private func flushPendingListRebuild() {
        guard let workItem = pendingListRebuildWorkItem else { return }
        workItem.cancel()
        pendingListRebuildWorkItem = nil
        rebuildList()
    }

    private func scrollSelectedApplicationFilterToVisible() {
        guard let button = filterStack.arrangedSubviews
            .compactMap({ $0 as? AppFilterButton })
            .first(where: { $0.bundleId == selectedApplication }) else {
            return
        }
        filterDocumentView.layoutSubtreeIfNeeded()
        filterStack.layoutSubtreeIfNeeded()

        let targetRect = button.convert(button.bounds.insetBy(dx: -10, dy: 0), to: filterDocumentView)
        let visibleRect = filterScrollView.contentView.bounds
        let maxX = max(0, filterDocumentView.bounds.width - visibleRect.width)
        var origin = visibleRect.origin

        if targetRect.minX < visibleRect.minX {
            origin.x = targetRect.minX
        } else if targetRect.maxX > visibleRect.maxX {
            origin.x = targetRect.maxX - visibleRect.width
        } else {
            return
        }

        origin.x = min(max(origin.x, 0), maxX)
        filterScrollView.contentView.scroll(to: origin)
        filterScrollView.reflectScrolledClipView(filterScrollView.contentView)
    }

    @objc private func togglePinned() {
        isPinned.toggle()
        (window as? NSPanel)?.hidesOnDeactivate = !isPinned
        window?.level = isPinned ? .statusBar : .floating
        pinButton.symbolName = isPinned ? "pin.fill" : "pin"
        pinButton.tintColor = isPinned ? MacAssistantUI.Color.blue : .secondaryLabelColor
    }

    @objc private func showClearMenu() {
        let menu = NSMenu()
        let clearUnfavorited = NSMenuItem(title: "只保留收藏", action: #selector(clearUnfavoritedItems), keyEquivalent: "")
        clearUnfavorited.target = self
        clearUnfavorited.isEnabled = controller.history.contains { !$0.isFavorite }
        menu.addItem(clearUnfavorited)

        for kind in ClipboardContentKind.allCases {
            let item = NSMenuItem(title: "清理\(kind.title)", action: #selector(clearKindItems(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.isEnabled = controller.countItems(kind: kind) > 0
            menu.addItem(item)
        }

        let clearAll = NSMenuItem(title: "清空全部", action: #selector(clearAllItems), keyEquivalent: "")
        clearAll.target = self
        clearAll.isEnabled = !controller.history.isEmpty
        menu.addItem(clearAll)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: clearButton.bounds.maxY + 2), in: clearButton)
    }

    @objc private func clearUnfavoritedItems() {
        controller.clearUnfavorited()
        selectedItemID = nil
        rebuildApplicationFilter()
        rebuildList()
    }

    @objc private func clearKindItems(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let kind = ClipboardContentKind(rawValue: rawValue) else {
            return
        }
        let count = controller.countItems(kind: kind)
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "清理\(kind.title)记录？"
        alert.informativeText = "将删除 \(count) 条未收藏的\(kind.title)记录，收藏会保留。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清理")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.clearItems(kind: kind)
        selectedItemID = nil
        rebuildApplicationFilter()
        rebuildList()
    }

    @objc private func clearAllItems() {
        let alert = NSAlert()
        alert.messageText = "清空全部剪切板历史？"
        alert.informativeText = "这会删除收藏和未收藏记录。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.clearAll()
        selectedItemID = nil
        rebuildApplicationFilter()
        rebuildList()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickedOutside(localEvent: event)
            return event
        }
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickedOutside(globalEvent: event)
        }
    }

    private func removeOutsideClickMonitors() {
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }
    }

    private func closeIfClickedOutside(localEvent event: NSEvent) {
        guard !isPinned, window?.isVisible == true else { return }
        if event.window !== window {
            window?.orderOut(nil)
        }
    }

    private func closeIfClickedOutside(globalEvent event: NSEvent) {
        guard !isPinned,
              let window,
              window.isVisible else { return }
        if !window.frame.contains(event.locationInWindow) {
            window.orderOut(nil)
        }
    }

    private func emptyState(title: String, detail: String, symbolName: String) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 210).isActive = true

        let icon = NSImageView(image: MacAssistantUI.symbol(symbolName, pointSize: 28, weight: .regular) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
        return view
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 {
            window?.orderOut(nil)
            return true
        }

        if event.keyCode == 51, window?.firstResponder !== searchField {
            return deleteSelectedItem()
        }

        if shortcut(.quickLook, matches: event) {
            return toggleQuickLookPreview()
        }

        if let index = visibleShortcutIndex(for: event) {
            return pasteShortcut(at: index)
        }

        if shortcut(.showActionsMenu, matches: event) {
            return showSelectedItemContextMenu()
        }
        if shortcut(.pastePlainText, matches: event) {
            return pasteSelected(mode: .plainText)
        }
        if shortcut(.pasteSelected, matches: event) {
            return pasteSelected(mode: .formatted)
        }
        if shortcut(.selectPreviousApplication, matches: event) {
            return selectRelativeApplicationFilter(-1)
        }
        if shortcut(.selectNextApplication, matches: event) {
            return selectRelativeApplicationFilter(1)
        }
        if shortcut(.selectNextItem, matches: event) {
            focusClipboardListIfNeeded()
            return selectRelative(1)
        }
        if shortcut(.selectPreviousItem, matches: event) {
            focusClipboardListIfNeeded()
            return selectRelative(-1)
        }

        return focusSearchAndHandleTextInput(event, flags: flags)
    }

    private func focusSearchAndHandleTextInput(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 51 {
            guard !searchField.text.isEmpty else { return false }
            window?.makeFirstResponder(searchField)
            return searchField.handleTextInput(from: event)
        }

        let commandFlags: NSEvent.ModifierFlags = [.command, .control, .option]
        guard flags.intersection(commandFlags).isEmpty else { return false }
        guard let characters = event.characters, !characters.isEmpty else { return false }

        let visible = String(characters.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        guard !visible.isEmpty else { return false }

        window?.makeFirstResponder(searchField)
        return searchField.handleTextInput(from: event)
    }

    private func focusClipboardListIfNeeded() {
        guard window?.firstResponder === searchField else { return }
        window?.makeFirstResponder(nil)
    }

    private func visibleShortcutIndex(for event: NSEvent) -> Int? {
        let binding = controller.configuration.shortcuts.binding(for: .pasteVisibleItem)
        guard binding.enabled,
              HotKeyFormatter.carbonModifiers(from: event.modifierFlags) == binding.hotKey.carbonModifiers else {
            return nil
        }
        switch event.keyCode {
        case 18: return 0
        case 19: return 1
        case 20: return 2
        case 21: return 3
        case 23: return 4
        case 22: return 5
        case 26: return 6
        case 28: return 7
        case 25: return 8
        default: return nil
        }
    }

    private func shortcut(_ shortcut: ClipboardShortcut, matches event: NSEvent) -> Bool {
        let binding = controller.configuration.shortcuts.binding(for: shortcut)
        guard binding.enabled,
              HotKeyFormatter.carbonModifiers(from: event.modifierFlags) == binding.hotKey.carbonModifiers else {
            return false
        }
        return keyCode(UInt32(event.keyCode), matches: binding.hotKey.keyCode)
    }

    private func keyCode(_ eventKeyCode: UInt32, matches shortcutKeyCode: UInt32) -> Bool {
        if eventKeyCode == shortcutKeyCode {
            return true
        }
        let returnKeyCodes: Set<UInt32> = [36, 76]
        return returnKeyCodes.contains(eventKeyCode) && returnKeyCodes.contains(shortcutKeyCode)
    }

    private func validateSelection(in items: [ClipboardHistoryItem]) {
        guard let selectedItemID,
              items.contains(where: { $0.id == selectedItemID }) else {
            selectedItemID = nil
            return
        }
    }

    private func pasteSelected(mode: ClipboardPasteMode) -> Bool {
        flushPendingListRebuild()
        let items = displayedItems
        validateSelection(in: items)
        guard let selectedItemID,
              let item = items.first(where: { $0.id == selectedItemID }) else {
            return false
        }
        controller.paste(item, mode: mode)
        return true
    }

    private func showSelectedItemContextMenu() -> Bool {
        flushPendingListRebuild()
        let items = displayedItems
        validateSelection(in: items)
        guard let selectedItemID else { return false }
        if let row = rowViewsByID[selectedItemID] {
            row.showContextMenu()
            return true
        }

        selectItem(selectedItemID, scrollToSelection: true)
        DispatchQueue.main.async { [weak self] in
            self?.rowViewsByID[selectedItemID]?.showContextMenu()
        }
        return true
    }

    private func deleteSelectedItem() -> Bool {
        flushPendingListRebuild()
        let items = displayedItems
        validateSelection(in: items)
        guard let selectedItemID,
              let item = items.first(where: { $0.id == selectedItemID }) else {
            return false
        }
        controller.delete(item)
        rebuildApplicationFilter()
        return true
    }

    private func pasteShortcut(at index: Int) -> Bool {
        flushPendingListRebuild()
        let items = visibleShortcutItems()
        guard items.indices.contains(index) else { return false }
        selectItem(items[index].id, scrollToSelection: true)
        controller.paste(items[index], mode: .formatted)
        return true
    }

    private func selectRelative(_ offset: Int) -> Bool {
        flushPendingListRebuild()
        let items = displayedItems
        guard !items.isEmpty else { return false }
        validateSelection(in: items)

        let targetIndex: Int
        if let currentIndex = selectedItemID.flatMap({ id in items.firstIndex(where: { $0.id == id }) }) {
            targetIndex = min(max(currentIndex + offset, 0), items.count - 1)
            guard targetIndex != currentIndex else { return true }
        } else {
            targetIndex = offset < 0 ? items.count - 1 : 0
        }

        selectItem(items[targetIndex].id, scrollToSelection: true)
        return true
    }

    private func clearSelection() {
        guard selectedItemID != nil else { return }
        selectedItemID = nil
        rowViewsByID.values.forEach { $0.setSelected(false) }
    }

    private func selectItem(_ itemID: UUID, scrollToSelection: Bool) {
        guard displayedItems.contains(where: { $0.id == itemID }) else { return }
        let previousItemID = selectedItemID
        selectedItemID = itemID
        if previousItemID != itemID {
            previousItemID.flatMap { rowViewsByID[$0] }?.setSelected(false)
            rowViewsByID[itemID]?.setSelected(true)
        }
        if scrollToSelection, let row = rowViewsByID[itemID] {
            row.scrollToVisible(row.bounds)
            updateVisibleShortcutHints()
        }
    }

    private func updateVisibleShortcutHints() {
        let showsVisibleItemShortcuts = controller.configuration.shortcuts.binding(for: .pasteVisibleItem).enabled
        guard showsVisibleItemShortcuts else {
            clearVisibleShortcutHints()
            return
        }

        let shortcutItems = visibleShortcutItems()
        let shortcutIndexesByID = Dictionary(uniqueKeysWithValues: shortcutItems.enumerated().map { ($0.element.id, $0.offset) })
        let nextHintedIDs = Set(shortcutIndexesByID.keys)
        let updateIDs = shortcutHintedItemIDs.union(nextHintedIDs)

        for id in updateIDs {
            let shortcutText = shortcutIndexesByID[id].map(visibleShortcutText)
            rowViewsByID[id]?.setShortcutText(shortcutText)
        }
        shortcutHintedItemIDs = nextHintedIDs
    }

    private func clearVisibleShortcutHints() {
        for id in shortcutHintedItemIDs {
            rowViewsByID[id]?.setShortcutText(nil)
        }
        shortcutHintedItemIDs.removeAll()
    }

    private func visibleShortcutText(for index: Int) -> String {
        let modifiers = controller.configuration.shortcuts.binding(for: .pasteVisibleItem).hotKey.carbonModifiers
        return "\(HotKeyFormatter.modifierDisplayText(modifiers))\(index + 1)"
    }

    private func visibleShortcutItems() -> [ClipboardHistoryItem] {
        guard let documentView = listScrollView.documentView else {
            return Array(displayedItems.prefix(9))
        }

        listStack.layoutSubtreeIfNeeded()
        let visibleRect = listScrollView.contentView.bounds
        let visibleItems = listStack.arrangedSubviews.compactMap { view -> (item: ClipboardHistoryItem, y: CGFloat)? in
            guard let row = view as? ClipboardHistoryRowView else {
                return nil
            }
            let rowRect = row.convert(row.bounds, to: documentView)
            guard rowRect.intersects(visibleRect) else { return nil }
            return (row.currentItem, rowRect.minY)
        }
        return visibleItems
            .sorted { $0.y < $1.y }
            .prefix(9)
            .map(\.item)
    }

    private func selectedItem() -> ClipboardHistoryItem? {
        let items = displayedItems
        validateSelection(in: items)
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    private func toggleQuickLookPreview() -> Bool {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            guard quickLookItem?.id == selectedItemID else {
                return showQuickLookPreview()
            }
            closeQuickLookPreview()
            return true
        }

        return showQuickLookPreview()
    }

    private func showQuickLookPreview() -> Bool {
        guard let item = selectedItem(),
              let previewURL = makeQuickLookURL(for: item) else {
            return false
        }

        quickLookItem = ClipboardQuickLookItem(
            id: item.id,
            url: previewURL,
            title: quickLookTitle(for: item)
        )

        guard let panel = QLPreviewPanel.shared() else { return false }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.refreshCurrentPreviewItem()
        panel.makeKeyAndOrderFront(nil)
        installQuickLookKeyMonitor()
        return true
    }

    private func closeQuickLookPreview() {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        clearQuickLookPreviewState()
    }

    private func clearQuickLookPreviewState() {
        quickLookItem = nil
        if let quickLookKeyMonitor {
            NSEvent.removeMonitor(quickLookKeyMonitor)
            self.quickLookKeyMonitor = nil
        }
        cleanupQuickLookFile()
    }

    private func installQuickLookKeyMonitor() {
        guard quickLookKeyMonitor == nil else { return }
        quickLookKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 49,
               flags.isEmpty,
               QLPreviewPanel.sharedPreviewPanelExists(),
               QLPreviewPanel.shared()?.isVisible == true {
                self?.closeQuickLookPreview()
                return nil
            }
            return event
        }
    }

    private func makeQuickLookURL(for item: ClipboardHistoryItem) -> URL? {
        cleanupQuickLookFile()

        if let path = item.metadata.sourcePaths.first,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        guard let directory = makeQuickLookDirectory() else { return nil }
        if let imageData = quickLookImageData(for: item) {
            let url = directory.appendingPathComponent("\(item.id.uuidString).\(imageData.fileExtension)")
            do {
                try imageData.data.write(to: url, options: .atomic)
                quickLookCleanupURL = url
                return url
            } catch {
                AppLogger.shared.error("剪切板预览图片写入失败：\(error.localizedDescription)")
                return nil
            }
        }

        let text = item.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? item.previewText
            : item.plainText
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let url = directory.appendingPathComponent("\(item.id.uuidString).txt")
        do {
            try trimmed.write(to: url, atomically: true, encoding: .utf8)
            quickLookCleanupURL = url
            return url
        } catch {
            AppLogger.shared.error("剪切板预览文本写入失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func makeQuickLookDirectory() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-tool-clipboard-quicklook", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            AppLogger.shared.error("剪切板预览目录创建失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func quickLookImageData(for item: ClipboardHistoryItem) -> (data: Data, fileExtension: String)? {
        for storedType in controller.storedTypes(for: item) {
            let type = storedType.type.lowercased()
            if type == NSPasteboard.PasteboardType.png.rawValue || type.contains("png") {
                return (storedType.data, "png")
            }
            if type == NSPasteboard.PasteboardType.tiff.rawValue || type.contains("tiff") {
                return (storedType.data, "tiff")
            }
            if type.contains("jpeg") || type.contains("jpg") {
                return (storedType.data, "jpg")
            }
            if type.contains("heic") {
                return (storedType.data, "heic")
            }
        }
        return nil
    }

    private func quickLookTitle(for item: ClipboardHistoryItem) -> String {
        if let fileName = item.metadata.fileNames.first, !fileName.isEmpty {
            return fileName
        }
        return ClipboardHistoryRowView.singleLineText(item.previewText, fallback: "剪切板预览")
    }

    private func cleanupQuickLookFile() {
        guard let quickLookCleanupURL else { return }
        try? FileManager.default.removeItem(at: quickLookCleanupURL)
        self.quickLookCleanupURL = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookItem == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookItem
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        clearQuickLookPreviewState()
    }
}

private final class ClipboardQuickLookItem: NSObject, QLPreviewItem {
    let id: UUID
    let url: URL
    let title: String

    init(id: UUID, url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
        super.init()
    }

    var previewItemURL: URL? {
        url
    }

    var previewItemTitle: String? {
        title
    }
}

private final class AppFilterButton: NSControl {
    let bundleId: String
    private let titleText: String
    private var selected: Bool

    init(title: String, bundleId: String, selected: Bool, target: AnyObject?, action: Selector?) {
        self.bundleId = bundleId
        self.titleText = title
        self.selected = selected
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override var intrinsicContentSize: NSSize {
        let width = (titleText as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ]).width + 18
        return NSSize(width: max(48, width), height: 24)
    }

    func setSelected(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        var lastLocation = event.locationInWindow
        let initialLocation = lastLocation
        var didDrag = false

        while true {
            guard let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                break
            }

            switch nextEvent.type {
            case .leftMouseDragged:
                let currentLocation = nextEvent.locationInWindow
                let totalDelta = hypot(currentLocation.x - initialLocation.x, currentLocation.y - initialLocation.y)
                if totalDelta > 3 {
                    didDrag = true
                }
                if didDrag, let scrollView = enclosingScrollView as? ClipboardFilterScrollView {
                    scrollView.scrollHorizontally(by: lastLocation.x - currentLocation.x)
                }
                lastLocation = currentLocation
            case .leftMouseUp:
                if !didDrag {
                    sendAction(action, to: target)
                }
                return
            default:
                break
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let enclosingScrollView {
            enclosingScrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            NSColor.white.setFill()
            path.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .medium),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let size = (titleText as NSString).size(withAttributes: attributes)
        titleText.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 0.5, width: size.width, height: size.height), withAttributes: attributes)
    }
}

private final class ClipboardPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onOrderOut: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onOrderOut?()
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        if event.keyCode == 53 {
            orderOut(nil)
            return
        }
        super.keyDown(with: event)
    }
}

private final class ClipboardFilterScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard documentView != nil else {
            super.scrollWheel(with: event)
            return
        }

        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? -event.scrollingDeltaX
            : -event.scrollingDeltaY
        guard delta != 0 else { return }

        scrollHorizontally(by: delta)
    }

    func scrollHorizontally(by delta: CGFloat) {
        guard let documentView, delta != 0 else { return }
        let maxX = max(0, documentView.bounds.width - contentView.bounds.width)
        var origin = contentView.bounds.origin
        origin.x = min(max(origin.x + delta, 0), maxX)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

private final class ClipboardFlippedView: NSView {
    override var isFlipped: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        if let enclosingScrollView {
            enclosingScrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private final class ClipboardShortcutBadgeView: NSView {
    var text = "" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override var intrinsicContentSize: NSSize {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: max(28, ceil(width + 12)), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !text.isEmpty else { return }

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let fill = isSelected
            ? NSColor.white.withAlphaComponent(0.20)
            : NSColor.white.withAlphaComponent(0.74)
        fill.setFill()
        path.fill()

        if !isSelected {
            MacAssistantUI.Color.hairline.withAlphaComponent(0.70).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isSelected ? NSColor.white : NSColor.secondaryLabelColor
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: floor((bounds.width - textSize.width) / 2),
            y: floor((bounds.height - textSize.height) / 2),
            width: ceil(textSize.width),
            height: ceil(textSize.height)
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
}

private final class ClipboardHistoryRowView: NSView {
    private enum Metrics {
        static let accessoryColumnWidth: CGFloat = 52
        static let timeWidth: CGFloat = 44
        static let shortcutBadgeWidth: CGFloat = 38
    }

    private var item: ClipboardHistoryItem
    private let onSelect: (ClipboardHistoryItem) -> Void
    private let onPaste: (ClipboardHistoryItem, ClipboardPasteMode) -> Void
    private let onToggleFavorite: (ClipboardHistoryItem) -> Void
    private let onDelete: (ClipboardHistoryItem) -> Void
    private let thumbnailURL: (ClipboardHistoryItem) -> URL?
    private let requestThumbnail: (ClipboardHistoryItem, @escaping (UUID, URL?) -> Void) -> Void
    private var isRowSelected: Bool
    private weak var iconView: NSImageView?
    private weak var titleLabel: NSTextField?
    private weak var detailLabel: NSTextField?
    private weak var timeLabel: NSTextField?
    private weak var favoriteIcon: NSImageView?
    private weak var shortcutBadge: ClipboardShortcutBadgeView?
    private weak var thumbnailImageView: NSImageView?

    init(
        item: ClipboardHistoryItem,
        selected: Bool,
        onSelect: @escaping (ClipboardHistoryItem) -> Void,
        onPaste: @escaping (ClipboardHistoryItem, ClipboardPasteMode) -> Void,
        onToggleFavorite: @escaping (ClipboardHistoryItem) -> Void,
        onDelete: @escaping (ClipboardHistoryItem) -> Void,
        thumbnailURL: @escaping (ClipboardHistoryItem) -> URL?,
        requestThumbnail: @escaping (ClipboardHistoryItem, @escaping (UUID, URL?) -> Void) -> Void
    ) {
        self.item = item
        self.onSelect = onSelect
        self.onPaste = onPaste
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete
        self.thumbnailURL = thumbnailURL
        self.requestThumbnail = requestThumbnail
        self.isRowSelected = selected
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    var itemID: UUID {
        item.id
    }

    var currentItem: ClipboardHistoryItem {
        item
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect(item)
        if event.clickCount >= 2 {
            onPaste(item, .formatted)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(at: convert(event.locationInWindow, from: nil))
    }

    func showContextMenu(at point: NSPoint? = nil) {
        onSelect(item)
        let menu = NSMenu()

        let favoriteTitle = item.isFavorite ? "取消收藏" : "收藏"
        let favoriteItem = NSMenuItem(title: favoriteTitle, action: #selector(toggleFavorite), keyEquivalent: "")
        favoriteItem.target = self
        menu.addItem(favoriteItem)

        menu.addItem(.separator())

        let pasteItem = NSMenuItem(title: "粘贴", action: #selector(pasteFormatted), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        let plainTextItem = NSMenuItem(title: "以纯文本粘贴", action: #selector(pastePlainText), keyEquivalent: "")
        plainTextItem.target = self
        plainTextItem.isEnabled = !item.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        menu.addItem(plainTextItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "删除", action: #selector(deleteItem), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        menu.popUp(positioning: nil, at: point ?? NSPoint(x: bounds.midX, y: bounds.midY), in: self)
    }

    func setSelected(_ selected: Bool) {
        guard isRowSelected != selected else { return }
        isRowSelected = selected
        updateSelectionAppearance()
    }

    func update(item: ClipboardHistoryItem, selected: Bool) {
        self.item = item
        isRowSelected = selected
        toolTip = tooltipText()
        iconView?.image = appIcon()
        titleLabel?.stringValue = Self.singleLineText(item.previewText, fallback: "")
        detailLabel?.stringValue = Self.singleLineText(detailText(), fallback: item.sourceApplicationName)
        timeLabel?.stringValue = Self.displayDateText(for: item.createdAt)
        favoriteIcon?.image = item.isFavorite ? MacAssistantUI.symbol("star.fill", pointSize: 11, weight: .semibold) : nil
        favoriteIcon?.isHidden = !item.isFavorite
        loadPreviewThumbnailIfNeeded()
        updateSelectionAppearance()
    }

    func setShortcutText(_ text: String?) {
        let nextText = text ?? ""
        if shortcutBadge?.text != nextText {
            shortcutBadge?.text = nextText
        }
        let shouldHide = text == nil
        if shortcutBadge?.isHidden != shouldHide {
            shortcutBadge?.isHidden = shouldHide
        }
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 66).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        toolTip = tooltipText()

        let iconView = NSImageView(image: appIcon())
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 8
        iconView.layer?.cornerCurve = .continuous
        iconView.widthAnchor.constraint(equalToConstant: 32).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        addSubview(iconView)
        self.iconView = iconView

        let previewView = makePreviewView()
        previewView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewView)

        let accessoryStack = NSStackView()
        accessoryStack.orientation = .vertical
        accessoryStack.alignment = .trailing
        accessoryStack.spacing = 5
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(accessoryStack)

        let topMetaRow = NSStackView()
        topMetaRow.orientation = .horizontal
        topMetaRow.alignment = .centerY
        topMetaRow.spacing = 4
        topMetaRow.translatesAutoresizingMaskIntoConstraints = false

        let favoriteIcon = NSImageView()
        favoriteIcon.image = item.isFavorite ? MacAssistantUI.symbol("star.fill", pointSize: 10, weight: .semibold) : nil
        favoriteIcon.isHidden = !item.isFavorite
        favoriteIcon.translatesAutoresizingMaskIntoConstraints = false
        favoriteIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        favoriteIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        topMetaRow.addArrangedSubview(favoriteIcon)
        self.favoriteIcon = favoriteIcon

        let time = NSTextField(labelWithString: Self.displayDateText(for: item.createdAt))
        time.font = .systemFont(ofSize: 10, weight: .medium)
        time.alignment = .right
        time.isSelectable = false
        time.translatesAutoresizingMaskIntoConstraints = false
        time.widthAnchor.constraint(equalToConstant: Metrics.timeWidth).isActive = true
        topMetaRow.addArrangedSubview(time)
        self.timeLabel = time

        let shortcut = ClipboardShortcutBadgeView()
        shortcut.isHidden = true
        shortcut.widthAnchor.constraint(equalToConstant: Metrics.shortcutBadgeWidth).isActive = true
        accessoryStack.addArrangedSubview(topMetaRow)
        accessoryStack.addArrangedSubview(shortcut)
        self.shortcutBadge = shortcut

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            previewView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            previewView.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -10),
            previewView.centerYAnchor.constraint(equalTo: centerYAnchor),

            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            accessoryStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryStack.widthAnchor.constraint(equalToConstant: Metrics.accessoryColumnWidth)
        ])
        updateSelectionAppearance()
    }

    private func makePreviewView() -> NSView {
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: Self.singleLineText(item.previewText, fallback: ""))
        title.font = .systemFont(ofSize: 12, weight: .medium)
        configureSingleLineLabel(title, truncation: .byTruncatingTail)
        textStack.addArrangedSubview(title)
        titleLabel = title

        let detail = NSTextField(labelWithString: Self.singleLineText(detailText(), fallback: item.sourceApplicationName))
        detail.font = .systemFont(ofSize: 10.5, weight: .regular)
        configureSingleLineLabel(detail, truncation: .byTruncatingMiddle)
        textStack.addArrangedSubview(detail)
        detailLabel = detail

        if hasImagePreview() {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false

            let imageView = NSImageView(image: Self.thumbnailPlaceholderImage)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.contentTintColor = .tertiaryLabelColor
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 6
            imageView.layer?.masksToBounds = true
            imageView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.58).cgColor
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 54).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 38).isActive = true
            stack.addArrangedSubview(imageView)
            stack.addArrangedSubview(textStack)
            stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            thumbnailImageView = imageView
            loadPreviewThumbnailIfNeeded()
            return stack
        }

        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textStack
    }

    private func configureSingleLineLabel(_ label: NSTextField, truncation: NSLineBreakMode) {
        label.isSelectable = false
        label.lineBreakMode = truncation
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.isScrollable = true
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func updateSelectionAppearance() {
        let selected = isRowSelected
        layer?.backgroundColor = selected ? MacAssistantUI.Color.blue.cgColor : NSColor.clear.cgColor
        iconView?.layer?.backgroundColor = (selected ? NSColor.white.withAlphaComponent(0.18) : NSColor.white).cgColor
        titleLabel?.textColor = selected ? .white : .labelColor
        detailLabel?.textColor = selected ? NSColor.white.withAlphaComponent(0.78) : .secondaryLabelColor
        timeLabel?.textColor = selected ? NSColor.white.withAlphaComponent(0.78) : .tertiaryLabelColor
        favoriteIcon?.contentTintColor = selected ? NSColor.white.withAlphaComponent(0.90) : MacAssistantUI.Color.amber
        shortcutBadge?.isSelected = selected
    }

    private func appIcon() -> NSImage {
        let cacheKey = item.sourceBundleIdentifier.isEmpty
            ? "name:\(item.sourceApplicationName)"
            : "bundle:\(item.sourceBundleIdentifier)"
        if let cached = Self.appIconCache[cacheKey] {
            return cached
        }

        let image: NSImage
        if !item.sourceBundleIdentifier.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.sourceBundleIdentifier) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: item.sourceApplicationName) ?? NSImage()
        }
        Self.appIconCache[cacheKey] = image
        return image
    }

    private func hasImagePreview() -> Bool {
        item.metadata.contentType == "图片"
            || item.metadata.imagePixelWidth != nil
            || item.metadata.pasteboardTypes.contains { type in
                let lower = type.lowercased()
                return lower.contains("image")
                    || lower.contains("png")
                    || lower.contains("tiff")
                    || lower.contains("jpeg")
                    || lower.contains("jpg")
                    || lower.contains("heic")
            }
    }

    private func loadPreviewThumbnailIfNeeded() {
        guard let imageView = thumbnailImageView else { return }
        guard hasImagePreview() else {
            imageView.image = nil
            return
        }
        if let cached = Self.thumbnailCache[item.id] {
            imageView.image = cached
            return
        }

        if let url = thumbnailURL(item),
           let image = NSImage(contentsOf: url) {
            Self.cacheThumbnail(image, for: item.id)
            imageView.image = image
            return
        }

        imageView.image = Self.thumbnailPlaceholderImage
        imageView.contentTintColor = .tertiaryLabelColor
        Self.requestThumbnail(id: item.id, item: item, loader: requestThumbnail) { [weak self] id, image in
            guard let self,
                  self.item.id == id,
                  let image else {
                return
            }
            self.thumbnailImageView?.image = image
        }
    }

    @objc private func deleteItem() {
        onDelete(item)
    }

    @objc private func toggleFavorite() {
        onToggleFavorite(item)
    }

    @objc private func pasteFormatted() {
        onPaste(item, .formatted)
    }

    @objc private func pastePlainText() {
        onPaste(item, .plainText)
    }

    private func detailText() -> String {
        if !item.metadata.detailText.isEmpty {
            return item.metadata.detailText
        }
        if let firstType = item.metadata.pasteboardTypes.first {
            return firstType
        }
        return item.sourceApplicationName
    }

    private func tooltipText() -> String {
        var lines = [item.previewText, detailText()]
        if !item.metadata.sourcePaths.isEmpty {
            lines.append(contentsOf: item.metadata.sourcePaths.prefix(4))
        }
        if !item.metadata.pasteboardTypes.isEmpty {
            lines.append("类型：" + item.metadata.pasteboardTypes.prefix(4).joined(separator: ", "))
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func singleLineText(_ text: String, fallback: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? fallback : collapsed
    }

    private static func displayDateText(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return timeFormatter.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        if let dayBeforeYesterday = calendar.date(byAdding: .day, value: -2, to: now),
           calendar.isDate(date, inSameDayAs: dayBeforeYesterday) {
            return "前天"
        }
        return dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static var appIconCache: [String: NSImage] = [:]
    private static var thumbnailCache: [UUID: NSImage] = [:]
    private static var thumbnailCacheOrder: [UUID] = []
    private static var thumbnailRequests = Set<UUID>()
    private static let thumbnailCacheLimit = 160

    private static let thumbnailPlaceholderImage: NSImage = {
        NSImage(systemSymbolName: "photo", accessibilityDescription: "图片") ?? NSImage()
    }()

    private static func requestThumbnail(
        id: UUID,
        item: ClipboardHistoryItem,
        loader: @escaping (ClipboardHistoryItem, @escaping (UUID, URL?) -> Void) -> Void,
        completion: @escaping (UUID, NSImage?) -> Void
    ) {
        if let cached = thumbnailCache[id] {
            completion(id, cached)
            return
        }
        guard !thumbnailRequests.contains(id) else { return }
        thumbnailRequests.insert(id)

        loader(item) { resolvedID, url in
            thumbnailRequests.remove(resolvedID)
            guard resolvedID == id,
                  let url,
                  let image = NSImage(contentsOf: url) else {
                completion(resolvedID, nil)
                return
            }
            cacheThumbnail(image, for: resolvedID)
            completion(resolvedID, image)
        }
    }

    private static func cacheThumbnail(_ image: NSImage, for id: UUID) {
        thumbnailCache[id] = image
        thumbnailCacheOrder.removeAll { $0 == id }
        thumbnailCacheOrder.append(id)
        while thumbnailCacheOrder.count > thumbnailCacheLimit {
            let removed = thumbnailCacheOrder.removeFirst()
            thumbnailCache[removed] = nil
        }
    }
}
