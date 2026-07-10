import AppKit
import UniformTypeIdentifiers

final class ArchiveBrowserWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let modified = NSUserInterfaceItemIdentifier("modified")
        static let kind = NSUserInterfaceItemIdentifier("kind")
    }

    private enum FilterMode: Int {
        case all
        case files
        case folders
    }

    private enum SortMode: Int {
        case name
        case size
        case modified
        case kind
    }

    private final class Node: NSObject {
        let name: String
        let path: String
        var entry: ArchiveBrowserEntry?
        var children: [Node] = []

        init(name: String, path: String, entry: ArchiveBrowserEntry? = nil) {
            self.name = name
            self.path = path
            self.entry = entry
        }

        var isDirectory: Bool {
            entry?.isDirectory ?? !children.isEmpty
        }
    }

    private enum PreviewResult {
        case image(NSImage)
        case text(String)
        case fallback
        case passwordRequired
        case failure(String)
    }

    private enum ArchiveOperationResult {
        case success(String?)
        case passwordRequired
        case failure(Error)
    }

    private final class SidebarRowView: NSTableRowView {
        override func drawBackground(in dirtyRect: NSRect) {
            NSColor.clear.setFill()
            dirtyRect.fill()
        }

        override func drawSelection(in dirtyRect: NSRect) {
            guard selectionHighlightStyle != .none else { return }
            let selectedRect = bounds.insetBy(dx: 2, dy: 3)
            MacAssistantUI.Color.sidebarSelected.setFill()
            NSBezierPath(roundedRect: selectedRect, xRadius: 7, yRadius: 7).fill()
        }
    }

    private final class ArchiveToolbarButton: NSControl {
        private let iconView = NSImageView()
        private let titleLabel = NSTextField(labelWithString: "")
        private var tintColor: NSColor = .controlAccentColor
        private var isPressed = false
        private var usesSubtleBackground = false

        override var isEnabled: Bool {
            didSet { updateAppearance() }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        func configure(title: String, image: NSImage, tint: NSColor) {
            titleLabel.stringValue = title
            titleLabel.isHidden = title.isEmpty
            iconView.image = image
            tintColor = tint
            toolTip = title.isEmpty ? nil : title
            updateAppearance()
        }

        func setTitle(_ title: String) {
            titleLabel.stringValue = title
            titleLabel.isHidden = title.isEmpty
            toolTip = title.isEmpty ? toolTip : title
        }

        func setImage(_ image: NSImage) {
            iconView.image = image
        }

        func setTint(_ tint: NSColor) {
            tintColor = tint
            updateAppearance()
        }

        func setSubtleBackground(_ subtle: Bool) {
            usesSubtleBackground = subtle
            updateAppearance()
        }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            setPressed(true)

            var shouldSendAction = true
            while let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let point = convert(nextEvent.locationInWindow, from: nil)
                let isInside = bounds.contains(point)
                if nextEvent.type == .leftMouseDragged {
                    setPressed(isInside)
                } else {
                    shouldSendAction = isInside
                    break
                }
            }

            setPressed(false)
            if shouldSendAction {
                sendAction(action, to: target)
            }
        }

        private func setup() {
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 1

            iconView.imageScaling = .scaleProportionallyDown
            iconView.translatesAutoresizingMaskIntoConstraints = false

            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            titleLabel.alignment = .center
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            let contentStack = NSStackView(views: [iconView, titleLabel])
            contentStack.orientation = .horizontal
            contentStack.alignment = .centerY
            contentStack.spacing = 8
            contentStack.translatesAutoresizingMaskIntoConstraints = false

            addSubview(contentStack)
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),

                contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
                contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
                contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
                contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
            ])

            updateAppearance()
        }

        private func setPressed(_ pressed: Bool) {
            guard isPressed != pressed else { return }
            isPressed = pressed
            updateAppearance()
        }

        private func updateAppearance() {
            let activeTint = isEnabled ? tintColor : tintColor.withAlphaComponent(0.36)
            if usesSubtleBackground {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(isPressed ? 0.95 : 0.78).cgColor
            } else {
                let backgroundAlpha: CGFloat
                if !isEnabled {
                    backgroundAlpha = 0.07
                } else if isPressed {
                    backgroundAlpha = 0.28
                } else {
                    backgroundAlpha = 0.18
                }
                layer?.backgroundColor = tintColor.withAlphaComponent(backgroundAlpha).cgColor
            }

            layer?.borderColor = MacAssistantUI.Color.hairline.cgColor
            iconView.contentTintColor = activeTint
            titleLabel.textColor = isEnabled ? tintColor : tintColor.withAlphaComponent(0.45)
            alphaValue = isEnabled ? 1 : 0.92
        }
    }

    private let service: ArchiveBrowserService
    private let archiveURL: URL
    private let entryLoadQueue = DispatchQueue(label: "com.fusheng.mac-tool.archive-browser.entries", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "com.fusheng.mac-tool.archive-browser.preview", qos: .utility)
    private let operationQueue = DispatchQueue(label: "com.fusheng.mac-tool.archive-browser.operation", qos: .userInitiated)
    private var entries: [ArchiveBrowserEntry] = []
    private var rootNodes: [Node] = []
    private var visibleNodes: [Node] = []
    private var mayRequirePassword = false
    private var archivePassword: String?
    private var filterMode: FilterMode = .all
    private var sortMode: SortMode = .name
    private var searchQuery = ""
    private var isExpanded = false
    private var sidebarRootNode: Node?
    private var selectedDirectoryPath: String?
    private var entryLoadGeneration = 0
    private var previewGeneration = 0
    private var isLoadingEntries = false
    private var isArchiveOperationRunning = false

    private let outlineView = NSOutlineView()
    private let sidebarOutlineView = NSOutlineView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let addButton = ArchiveToolbarButton()
    private let addLabel = NSTextField(labelWithString: "增加")
    private let extractButton = ArchiveToolbarButton()
    private let extractLabel = NSTextField(labelWithString: "提取")
    private let deleteButton = ArchiveToolbarButton()
    private let deleteLabel = NSTextField(labelWithString: "删除")
    private let cleanButton = ArchiveToolbarButton()
    private let cleanLabel = NSTextField(labelWithString: "清理")
    private let expandButton = ArchiveToolbarButton()
    private let expandLabel = NSTextField(labelWithString: "全部展开")
    private let filterPopup = MacSelectControl()
    private let sortPopup = MacSelectControl()
    private let searchField = MacSearchField()
    private let previewImageView = NSImageView()
    private let previewTextView = NSTextView()
    private let previewTextScrollView = NSScrollView()
    private let previewTitleLabel = NSTextField(labelWithString: "选择文件查看详情")
    private let previewSubtitleLabel = NSTextField(wrappingLabelWithString: "左侧选择目录，中央选择文件后，这里会显示缩略图和属性。")
    private let previewSizeValue = NSTextField(labelWithString: "--")
    private let previewPathValue = NSTextField(labelWithString: "--")
    private let previewKindValue = NSTextField(labelWithString: "--")
    private let previewModifiedValue = NSTextField(labelWithString: "--")
    private var compactRows = false

    init(archiveURL: URL, password: String? = nil) throws {
        self.service = try ArchiveBrowserService(archiveURL: archiveURL)
        self.archiveURL = archiveURL
        self.archivePassword = password
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = archiveURL.path
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 1100, height: 560)
        super.init(window: window)
        buildUI()
        reload()
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
        contentView.layer?.backgroundColor = MacAssistantUI.Color.window.cgColor

        let toolbar = makeToolbar()
        let content = makeContentView()
        let footer = makeFooter()

        contentView.addSubview(toolbar)
        contentView.addSubview(content)
        contentView.addSubview(footer)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 104),

            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),

            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func makeToolbar() -> NSView {
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 0.96).cgColor

        let eyebrowLabel = NSTextField(labelWithString: "浏览 / 提取压缩包内容")
        eyebrowLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        eyebrowLabel.textColor = MacAssistantUI.Color.mutedText
        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: archiveURL.lastPathComponent)
        titleLabel.font = .systemFont(ofSize: 21, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: archiveURL.path)
        pathLabel.font = .systemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = MacAssistantUI.Color.mutedText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [eyebrowLabel, titleLabel, pathLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let addItem = makeToolbarAction(
            title: "增加",
            symbol: "plus",
            tint: .systemGreen,
            button: addButton,
            label: addLabel,
            action: #selector(addItems),
            enabled: true
        )
        let extractItem = makeToolbarAction(
            title: "提取",
            symbol: "arrow.right.doc.on.clipboard",
            tint: .systemPurple,
            button: extractButton,
            label: extractLabel,
            action: #selector(extractSelected),
            enabled: false
        )
        let extractAllButton = ArchiveToolbarButton()
        let extractAllItem = makeToolbarAction(
            title: "全部解压",
            symbol: "archivebox.fill",
            tint: .systemOrange,
            button: extractAllButton,
            action: #selector(extractAll)
        )
        let deleteItem = makeToolbarAction(
            title: "删除",
            symbol: "xmark",
            tint: .systemRed,
            button: deleteButton,
            label: deleteLabel,
            action: #selector(deleteItems),
            enabled: false
        )
        let cleanItem = makeToolbarAction(
            title: "清理",
            symbol: "paintbrush",
            tint: .systemTeal,
            button: cleanButton,
            label: cleanLabel,
            action: #selector(cleanItems),
            enabled: true
        )
        let expandItem = makeToolbarAction(
            title: "全部展开",
            symbol: "chevron.right",
            tint: .systemBlue,
            button: expandButton,
            label: expandLabel,
            action: #selector(toggleExpandAll)
        )

        let buttonStack = NSStackView(views: [addItem, extractItem, extractAllItem, deleteItem, cleanItem, expandItem])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let filterLabel = NSTextField(labelWithString: "过滤器：")
        filterLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        filterLabel.textColor = MacAssistantUI.Color.mutedText
        filterLabel.translatesAutoresizingMaskIntoConstraints = false

        filterPopup.items = ["全部", "文件", "文件夹"]
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        filterPopup.translatesAutoresizingMaskIntoConstraints = false

        sortPopup.items = ["按名称", "按大小", "按修改日期", "按类型"]
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)
        sortPopup.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholder = "搜索文件"
        searchField.onChange = { [weak self] _ in self?.searchChanged() }
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let viewButton = smallToolbarIcon("list.bullet", action: #selector(toggleListDensity))
        let settingsButton = smallToolbarIcon("gearshape", action: #selector(openArchiveSettings))
        let aboutButton = smallToolbarIcon("a.circle", action: #selector(showArchiveInfo))
        let rightStack = NSStackView(views: [buttonStack, filterLabel, filterPopup, sortPopup, searchField, viewButton, settingsButton, aboutButton])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 10
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = MacAssistantUI.Color.hairline.cgColor

        toolbar.addSubview(titleStack)
        toolbar.addSubview(rightStack)
        toolbar.addSubview(separator)

        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 28),
            titleStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: 6),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -24),

            rightStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -20),
            rightStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: 8),

            separator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])

        return toolbar
    }

    private func makeToolbarAction(
        title: String,
        symbol: String,
        tint: NSColor,
        button: ArchiveToolbarButton,
        label: NSTextField? = nil,
        action: Selector,
        enabled: Bool = true
    ) -> ArchiveToolbarButton {
        let stateLabel = label ?? NSTextField(labelWithString: title)
        stateLabel.stringValue = title
        button.target = self
        button.action = action
        button.isEnabled = enabled
        button.translatesAutoresizingMaskIntoConstraints = false
        button.configure(title: title, image: configuredSymbol(named: symbol, pointSize: 14, weight: .semibold), tint: tint)
        setToolbarItem(button: button, label: stateLabel, tint: tint, enabled: enabled)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 36),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: title.count > 2 ? 92 : 76)
        ])
        return button
    }

    private func smallToolbarIcon(_ symbol: String, action: Selector) -> ArchiveToolbarButton {
        let button = ArchiveToolbarButton()
        button.configure(
            title: "",
            image: configuredSymbol(named: symbol, pointSize: 13, weight: .medium),
            tint: MacAssistantUI.Color.mutedText
        )
        button.setSubtleBackground(true)
        button.target = self
        button.action = action
        button.isEnabled = true
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 34)
        ])
        return button
    }

    private func makeContentView() -> NSView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = makeSidebarView()
        let list = makeListContainer()
        let inspector = makeInspectorView()

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(list)
        splitView.addArrangedSubview(inspector)
        splitView.setHoldingPriority(.init(260), forSubviewAt: 0)
        splitView.setHoldingPriority(.init(260), forSubviewAt: 2)

        NSLayoutConstraint.activate([
            sidebar.widthAnchor.constraint(equalToConstant: 260),
            inspector.widthAnchor.constraint(equalToConstant: 304)
        ])
        return splitView
    }

    private func makeSidebarView() -> NSView {
        let container = panelView()
        let titleLabel = panelTitle("目录")
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = sidebarOutlineView

        sidebarOutlineView.delegate = self
        sidebarOutlineView.dataSource = self
        sidebarOutlineView.headerView = nil
        sidebarOutlineView.backgroundColor = .clear
        sidebarOutlineView.rowHeight = 30
        sidebarOutlineView.indentationPerLevel = 12
        sidebarOutlineView.intercellSpacing = .zero
        sidebarOutlineView.style = .plain
        sidebarOutlineView.selectionHighlightStyle = .regular
        sidebarOutlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: Column.name)
        column.title = ""
        column.minWidth = 180
        column.width = 236
        sidebarOutlineView.addTableColumn(column)
        sidebarOutlineView.outlineTableColumn = column

        container.addSubview(titleLabel)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 13),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        return container
    }

    private func makeListContainer() -> NSView {
        let container = panelView()
        let scrollView = makeOutlineScrollView()
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeInspectorView() -> NSView {
        let container = panelView()
        let titleLabel = panelTitle("预览与信息")

        let previewWell = LayerBackedView(
            backgroundColor: NSColor(calibratedRed: 0.93, green: 0.96, blue: 1.0, alpha: 0.78),
            cornerRadius: 10,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        previewImageView.imageScaling = .scaleProportionallyDown
        previewImageView.contentTintColor = MacAssistantUI.Color.blue
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewWell.addSubview(previewImageView)

        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.drawsBackground = false
        previewTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewTextView.textColor = .labelColor
        previewTextView.textContainerInset = NSSize(width: 10, height: 10)
        previewTextScrollView.hasVerticalScroller = true
        previewTextScrollView.autohidesScrollers = true
        previewTextScrollView.drawsBackground = false
        previewTextScrollView.borderType = .noBorder
        previewTextScrollView.documentView = previewTextView
        previewTextScrollView.isHidden = true
        previewTextScrollView.translatesAutoresizingMaskIntoConstraints = false
        previewWell.addSubview(previewTextScrollView)

        previewTitleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        previewTitleLabel.textColor = .labelColor
        previewTitleLabel.lineBreakMode = .byTruncatingMiddle
        previewTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        previewSubtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        previewSubtitleLabel.textColor = MacAssistantUI.Color.mutedText
        previewSubtitleLabel.lineBreakMode = .byWordWrapping
        previewSubtitleLabel.maximumNumberOfLines = 3
        previewSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailsStack = NSStackView(views: [
            detailRow(title: "大小", value: previewSizeValue),
            detailRow(title: "路径", value: previewPathValue),
            detailRow(title: "类型", value: previewKindValue),
            detailRow(title: "修改日期", value: previewModifiedValue)
        ])
        detailsStack.orientation = .vertical
        detailsStack.spacing = 0
        detailsStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(previewWell)
        container.addSubview(previewTitleLabel)
        container.addSubview(previewSubtitleLabel)
        container.addSubview(detailsStack)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 13),

            previewWell.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            previewWell.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            previewWell.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            previewWell.heightAnchor.constraint(equalToConstant: 190),

            previewImageView.leadingAnchor.constraint(equalTo: previewWell.leadingAnchor, constant: 18),
            previewImageView.trailingAnchor.constraint(equalTo: previewWell.trailingAnchor, constant: -18),
            previewImageView.topAnchor.constraint(equalTo: previewWell.topAnchor, constant: 18),
            previewImageView.bottomAnchor.constraint(equalTo: previewWell.bottomAnchor, constant: -18),

            previewTextScrollView.leadingAnchor.constraint(equalTo: previewWell.leadingAnchor, constant: 10),
            previewTextScrollView.trailingAnchor.constraint(equalTo: previewWell.trailingAnchor, constant: -10),
            previewTextScrollView.topAnchor.constraint(equalTo: previewWell.topAnchor, constant: 10),
            previewTextScrollView.bottomAnchor.constraint(equalTo: previewWell.bottomAnchor, constant: -10),

            previewTitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            previewTitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            previewTitleLabel.topAnchor.constraint(equalTo: previewWell.bottomAnchor, constant: 18),

            previewSubtitleLabel.leadingAnchor.constraint(equalTo: previewTitleLabel.leadingAnchor),
            previewSubtitleLabel.trailingAnchor.constraint(equalTo: previewTitleLabel.trailingAnchor),
            previewSubtitleLabel.topAnchor.constraint(equalTo: previewTitleLabel.bottomAnchor, constant: 8),

            detailsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            detailsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            detailsStack.topAnchor.constraint(equalTo: previewSubtitleLabel.bottomAnchor, constant: 18)
        ])

        updatePreviewPlaceholder()
        return container
    }

    private func panelView() -> NSView {
        LayerBackedView(
            backgroundColor: NSColor.white.withAlphaComponent(0.82),
            cornerRadius: 10,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
    }

    private func panelTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = MacAssistantUI.Color.mutedText
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func detailRow(title: String, value: NSTextField) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = MacAssistantUI.Color.mutedText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        value.font = .systemFont(ofSize: 12, weight: .semibold)
        value.textColor = .labelColor
        value.alignment = .right
        value.lineBreakMode = .byTruncatingMiddle
        value.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = MacAssistantUI.Color.hairline.cgColor

        row.addSubview(titleLabel)
        row.addSubview(value)
        row.addSubview(separator)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 38),

            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            value.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            value.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            value.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            value.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
        return row
    }

    private func makeOutlineScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView

        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.allowsMultipleSelection = true
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.rowHeight = 34
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.backgroundColor = .clear
        outlineView.gridStyleMask = [.solidHorizontalGridLineMask]
        outlineView.gridColor = MacAssistantUI.Color.hairline
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.target = self
        outlineView.doubleAction = #selector(openSelected)

        let nameColumn = NSTableColumn(identifier: Column.name)
        nameColumn.title = "名称"
        nameColumn.minWidth = 220
        nameColumn.width = 300
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn

        let sizeColumn = NSTableColumn(identifier: Column.size)
        sizeColumn.title = "大小"
        sizeColumn.minWidth = 72
        sizeColumn.width = 80
        outlineView.addTableColumn(sizeColumn)

        let modifiedColumn = NSTableColumn(identifier: Column.modified)
        modifiedColumn.title = "修改日期"
        modifiedColumn.minWidth = 116
        modifiedColumn.width = 128
        outlineView.addTableColumn(modifiedColumn)

        let kindColumn = NSTableColumn(identifier: Column.kind)
        kindColumn.title = "种类"
        kindColumn.minWidth = 92
        kindColumn.width = 104
        outlineView.addTableColumn(kindColumn)

        return scrollView
    }

    private func makeFooter() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

        footer.addSubview(separator)
        footer.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        return footer
    }

    private func reload(successMessage: String? = nil) {
        entryLoadGeneration += 1
        let generation = entryLoadGeneration
        let password = password
        let sortMode = sortMode
        showLoadingState()

        entryLoadQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<(entries: [ArchiveBrowserEntry], mayRequirePassword: Bool, rootNodes: [Node]), Error> = Result {
                let listed = try self.service.listEntries(password: password)
                return (
                    entries: listed.entries,
                    mayRequirePassword: listed.mayRequirePassword,
                    rootNodes: self.buildTree(from: listed.entries, sortMode: sortMode)
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.entryLoadGeneration == generation else { return }
                self.applyLoadResult(result, successMessage: successMessage)
            }
        }
    }

    private func showLoadingState() {
        isLoadingEntries = true
        previewGeneration += 1
        statusLabel.stringValue = "正在读取压缩包列表..."
        entries = []
        rootNodes = []
        visibleNodes = []
        selectedDirectoryPath = nil
        sidebarRootNode = nil
        outlineView.reloadData()
        sidebarOutlineView.reloadData()
        updateSelectionState()
    }

    private func applyLoadResult(
        _ result: Result<(entries: [ArchiveBrowserEntry], mayRequirePassword: Bool, rootNodes: [Node]), Error>,
        successMessage: String?
    ) {
        isLoadingEntries = false
        switch result {
        case .success(let loaded):
            entries = loaded.entries
            mayRequirePassword = loaded.mayRequirePassword
            rootNodes = loaded.rootNodes
            refreshSidebar()
            applyFilter()
            if let successMessage {
                statusLabel.stringValue = successMessage
            } else {
                updateFooter()
            }
        case .failure(ArchiveBrowserError.passwordRequired):
            guard requestPassword() else {
                statusLabel.stringValue = "已取消输入密码"
                return
            }
            reload(successMessage: successMessage)
        case .failure(let error):
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func buildTree(from entries: [ArchiveBrowserEntry], sortMode: SortMode? = nil) -> [Node] {
        let root = Node(name: "", path: "")
        var directories: [String: Node] = ["": root]

        let sortMode = sortMode ?? self.sortMode
        for entry in entries.sorted(by: { compareEntries($0, $1, sortMode: sortMode) }) {
            let normalized = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.isEmpty else { continue }
            let components = normalized.split(separator: "/").map(String.init)
            var current = root
            var currentPath = ""

            for (index, component) in components.enumerated() {
                currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                let isLast = index == components.count - 1
                if isLast {
                    let node = directories[currentPath] ?? Node(name: component, path: currentPath, entry: entry)
                    node.entry = entry
                    if !current.children.contains(where: { $0 === node }) {
                        current.children.append(node)
                    }
                    if entry.isDirectory {
                        directories[currentPath] = node
                    }
                } else {
                    let node = directories[currentPath] ?? Node(name: component, path: currentPath)
                    directories[currentPath] = node
                    if !current.children.contains(where: { $0 === node }) {
                        current.children.append(node)
                    }
                    current = node
                }
            }
        }

        return sortedNodes(root.children, sortMode: sortMode)
    }

    private func sortedNodes(_ nodes: [Node], sortMode: SortMode? = nil) -> [Node] {
        let sortMode = sortMode ?? self.sortMode
        return nodes.sorted(by: { compareNodes($0, $1, sortMode: sortMode) }).map { node in
            node.children = sortedNodes(node.children, sortMode: sortMode)
            return node
        }
    }

    private func applyFilter() {
        guard !isLoadingEntries else {
            return
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            visibleNodes = entriesForSelectedDirectory()
                .filter { entryMatchesFilter($0) }
                .filter { $0.path.localizedCaseInsensitiveContains(query) || $0.displayName.localizedCaseInsensitiveContains(query) }
                .sorted(by: compareEntries)
                .map { Node(name: $0.displayName, path: $0.path, entry: $0) }
        } else {
            let scopedNodes = sortedNodes(nodesForSelectedDirectory())
            switch filterMode {
            case .all:
                visibleNodes = scopedNodes
            case .files:
                visibleNodes = entriesForSelectedDirectory()
                    .filter { !$0.isDirectory }
                    .sorted(by: compareEntries)
                    .map { Node(name: $0.displayName, path: $0.path, entry: $0) }
            case .folders:
                visibleNodes = flattenedDirectories(in: scopedNodes).sorted(by: compareNodes)
            }
        }
        outlineView.reloadData()
        if isExpanded {
            expandAll()
        }
        updateSelectionState()
    }

    private func entryMatchesFilter(_ entry: ArchiveBrowserEntry) -> Bool {
        switch filterMode {
        case .all:
            return true
        case .files:
            return !entry.isDirectory
        case .folders:
            return entry.isDirectory
        }
    }

    private func refreshSidebar() {
        if let selectedDirectoryPath, !selectedDirectoryPath.isEmpty, node(forPath: selectedDirectoryPath, in: rootNodes) == nil {
            self.selectedDirectoryPath = nil
        }

        let root = Node(name: archiveURL.lastPathComponent, path: "")
        root.children = rootNodes
        sidebarRootNode = root
        sidebarOutlineView.reloadData()
        sidebarOutlineView.expandItem(root)

        let selectedNode: Node? = {
            guard let selectedDirectoryPath, !selectedDirectoryPath.isEmpty else { return root }
            return node(forPath: selectedDirectoryPath, in: rootNodes) ?? root
        }()
        if let selectedNode {
            let row = sidebarOutlineView.row(forItem: selectedNode)
            if row >= 0 {
                sidebarOutlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    private func nodesForSelectedDirectory() -> [Node] {
        guard let selectedDirectoryPath, !selectedDirectoryPath.isEmpty else {
            return rootNodes
        }
        return node(forPath: selectedDirectoryPath, in: rootNodes)?.children ?? []
    }

    private func entriesForSelectedDirectory() -> [ArchiveBrowserEntry] {
        guard let selectedDirectoryPath, !selectedDirectoryPath.isEmpty else {
            return entries
        }
        let prefix = selectedDirectoryPath.hasSuffix("/") ? selectedDirectoryPath : "\(selectedDirectoryPath)/"
        return entries.filter { $0.path.hasPrefix(prefix) }
    }

    private func directoryChildren(of node: Node) -> [Node] {
        node.children.filter(\.isDirectory)
    }

    private func node(forPath path: String, in nodes: [Node]) -> Node? {
        for node in nodes {
            if node.path == path {
                return node
            }
            if let found = self.node(forPath: path, in: node.children) {
                return found
            }
        }
        return nil
    }

    private func flattenedDirectories(in nodes: [Node]) -> [Node] {
        var result: [Node] = []
        for node in nodes {
            if node.isDirectory {
                result.append(Node(name: node.name, path: node.path, entry: node.entry))
                result += flattenedDirectories(in: node.children)
            }
        }
        return result
    }

    private func compareNodes(_ left: Node, _ right: Node) -> Bool {
        compareNodes(left, right, sortMode: sortMode)
    }

    private func compareNodes(_ left: Node, _ right: Node, sortMode: SortMode) -> Bool {
        if left.isDirectory != right.isDirectory {
            return left.isDirectory && !right.isDirectory
        }
        if let leftEntry = left.entry, let rightEntry = right.entry {
            return compareEntries(leftEntry, rightEntry, sortMode: sortMode)
        }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    private func compareEntries(_ left: ArchiveBrowserEntry, _ right: ArchiveBrowserEntry) -> Bool {
        compareEntries(left, right, sortMode: sortMode)
    }

    private func compareEntries(_ left: ArchiveBrowserEntry, _ right: ArchiveBrowserEntry, sortMode: SortMode) -> Bool {
        if left.isDirectory != right.isDirectory {
            return left.isDirectory && !right.isDirectory
        }
        switch sortMode {
        case .name:
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        case .size:
            return (left.size ?? -1, left.path) < (right.size ?? -1, right.path)
        case .modified:
            return (left.modifiedAt ?? .distantPast, left.path) < (right.modifiedAt ?? .distantPast, right.path)
        case .kind:
            let leftKind = kindTitle(for: left)
            let rightKind = kindTitle(for: right)
            if leftKind != rightKind {
                return leftKind.localizedStandardCompare(rightKind) == .orderedAscending
            }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if outlineView === sidebarOutlineView {
            guard let item = item as? Node else {
                return sidebarRootNode == nil ? 0 : 1
            }
            return directoryChildren(of: item).count
        }
        return (item as? Node)?.children.count ?? visibleNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if outlineView === sidebarOutlineView {
            guard let item = item as? Node else {
                return sidebarRootNode!
            }
            return directoryChildren(of: item)[index]
        }
        return ((item as? Node)?.children ?? visibleNodes)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if outlineView === sidebarOutlineView {
            guard let node = item as? Node else { return false }
            return !directoryChildren(of: node).isEmpty
        }
        return (item as? Node)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        outlineView === sidebarOutlineView ? SidebarRowView() : nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let tableColumn else { return nil }
        if outlineView === sidebarOutlineView {
            return sidebarCell(for: node)
        }

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text(for: node, column: tableColumn.identifier))
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = tableColumn.identifier == Column.name ? .byTruncatingMiddle : .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        if tableColumn.identifier == Column.name {
            let imageView = NSImageView(image: icon(for: node))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),

                label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSOutlineView === sidebarOutlineView {
            guard let node = sidebarOutlineView.item(atRow: sidebarOutlineView.selectedRow) as? Node else { return }
            selectedDirectoryPath = node.path.isEmpty ? nil : node.path
            applyFilter()
            return
        }
        updateSelectionState()
    }

    private func sidebarCell(for node: Node) -> NSView {
        let cell = NSTableCellView()
        let imageView = NSImageView(image: configuredSymbol(
            named: node.path.isEmpty ? "archivebox.fill" : "folder.fill",
            pointSize: 14,
            weight: .semibold
        ))
        imageView.contentTintColor = node.path.isEmpty ? MacAssistantUI.Color.blue : MacAssistantUI.Color.amber
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: node.name)
        label.font = .systemFont(ofSize: 13, weight: node.path.isEmpty ? .semibold : .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func updateInspector() {
        let nodes = selectedNodes()
        if nodes.isEmpty {
            updatePreviewPlaceholder()
            return
        }
        if nodes.count > 1 {
            updatePreviewForMultipleSelection(nodes)
            return
        }
        updatePreview(for: nodes[0])
    }

    private func updatePreviewPlaceholder() {
        showPreviewImage(configuredSymbol(named: "archivebox.fill", pointSize: 64, weight: .regular), tint: MacAssistantUI.Color.blue)
        previewImageView.contentTintColor = MacAssistantUI.Color.blue
        previewTitleLabel.stringValue = "选择文件查看详情"
        previewSubtitleLabel.stringValue = "左侧选择目录，中央选择文件后，这里会显示缩略图和属性。"
        previewSizeValue.stringValue = "--"
        previewPathValue.stringValue = selectedDirectoryPath ?? archiveURL.lastPathComponent
        previewKindValue.stringValue = "ZIP 归档"
        previewModifiedValue.stringValue = "--"
    }

    private func updatePreviewForMultipleSelection(_ nodes: [Node]) {
        let selected = selectedEntries()
        let totalSize = selected.compactMap(\.size).reduce(Int64(0), +)
        showPreviewImage(configuredSymbol(named: "checklist", pointSize: 64, weight: .regular), tint: MacAssistantUI.Color.green)
        previewTitleLabel.stringValue = "已选中 \(nodes.count) 项"
        previewSubtitleLabel.stringValue = "可以批量提取或删除所选文件；选中文件夹时会包含其中的所有文件。"
        previewSizeValue.stringValue = selected.isEmpty ? "--" : ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        previewPathValue.stringValue = selectedDirectoryPath ?? archiveURL.lastPathComponent
        previewKindValue.stringValue = "\(selected.count) 个文件"
        previewModifiedValue.stringValue = "--"
    }

    private func updatePreview(for node: Node) {
        previewGeneration += 1
        let containedFiles = fileEntries(containedIn: node)
        let totalSize = containedFiles.compactMap(\.size).reduce(Int64(0), +)
        previewTitleLabel.stringValue = node.name
        previewSubtitleLabel.stringValue = node.isDirectory
            ? "文件夹包含 \(containedFiles.count) 个文件，双击可展开或折叠。"
            : "双击可临时解压并打开，也可以直接拖拽到 Finder。"
        previewSizeValue.stringValue = node.isDirectory
            ? (containedFiles.isEmpty ? "--" : ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
            : text(for: node, column: Column.size)
        previewPathValue.stringValue = node.path.isEmpty ? archiveURL.lastPathComponent : node.path
        previewKindValue.stringValue = kindTitle(for: node)
        previewModifiedValue.stringValue = text(for: node, column: Column.modified).isEmpty ? "--" : text(for: node, column: Column.modified)

        if node.isDirectory {
            showPreviewImage(configuredSymbol(named: "folder.fill", pointSize: 70, weight: .regular), tint: MacAssistantUI.Color.amber)
            return
        }

        guard let entry = node.entry else {
            previewSubtitleLabel.stringValue = "可双击临时解压并使用系统默认应用打开。"
            showPreviewImage(icon(for: node), tint: nil)
            return
        }

        guard isImageEntry(entry) || isTextEntry(entry) else {
            previewSubtitleLabel.stringValue = "可双击临时解压并使用系统默认应用打开。"
            showPreviewImage(icon(for: node), tint: nil)
            return
        }

        let generation = previewGeneration
        let password = password
        previewSubtitleLabel.stringValue = "正在生成预览..."
        showPreviewImage(icon(for: node), tint: nil)
        previewQueue.async { [weak self] in
            guard let self else { return }
            let result = self.makePreviewResult(entry: entry, password: password)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewGeneration == generation else { return }
                self.applyPreviewResult(result)
            }
        }
    }

    private func makePreviewResult(entry: ArchiveBrowserEntry, password: String?) -> PreviewResult {
        do {
            let url = try service.extractForPreview(entry: entry, password: password)
            if isImageEntry(entry), let image = NSImage(contentsOf: url) {
                return .image(image)
            }
            if isTextEntry(entry) {
                return .text(try textPreview(from: url))
            }
            return .fallback
        } catch ArchiveBrowserError.passwordRequired {
            return .passwordRequired
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func applyPreviewResult(_ result: PreviewResult) {
        switch result {
        case .image(let image):
            showPreviewImage(image, tint: nil)
            previewSubtitleLabel.stringValue = "已显示图片预览，双击可临时解压并打开完整文件。"
        case .text(let preview):
            showPreviewText(preview)
            previewSubtitleLabel.stringValue = preview.isEmpty
                ? "文本文件为空，双击可用默认应用打开。"
                : "已显示文本预览，双击可临时解压并打开完整文件。"
        case .fallback:
            previewSubtitleLabel.stringValue = "可双击临时解压并使用系统默认应用打开。"
        case .passwordRequired:
            previewSubtitleLabel.stringValue = "该文件需要密码，执行打开或解压时会提示输入。"
        case .failure(let message):
            previewSubtitleLabel.stringValue = message
        }
    }

    private func showPreviewImage(_ image: NSImage, tint: NSColor?) {
        previewTextScrollView.isHidden = true
        previewImageView.isHidden = false
        previewImageView.image = image
        previewImageView.contentTintColor = tint
        previewTextView.string = ""
    }

    private func showPreviewText(_ text: String) {
        previewImageView.isHidden = true
        previewTextScrollView.isHidden = false
        previewTextView.string = text
    }

    private func fileEntries(containedIn node: Node) -> [ArchiveBrowserEntry] {
        if let entry = node.entry, !entry.isDirectory {
            return [entry]
        }
        let prefix = node.path.hasSuffix("/") ? node.path : "\(node.path)/"
        return entries.filter { !$0.isDirectory && $0.path.hasPrefix(prefix) }
    }

    private func isImageEntry(_ entry: ArchiveBrowserEntry) -> Bool {
        let ext = URL(fileURLWithPath: entry.displayName).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    private func isTextEntry(_ entry: ArchiveBrowserEntry) -> Bool {
        let ext = URL(fileURLWithPath: entry.displayName).pathExtension
        guard let type = UTType(filenameExtension: ext) else {
            return ["txt", "md", "json", "xml", "csv", "log", "yaml", "yml", "swift", "js", "ts", "html", "css"].contains(ext.lowercased())
        }
        return type.conforms(to: .plainText)
            || type.conforms(to: .sourceCode)
            || type.conforms(to: .json)
            || type.conforms(to: .xml)
            || type.conforms(to: .commaSeparatedText)
    }

    private func textPreview(from url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let limit = min(data.count, 200_000)
        let sample = data.prefix(limit)
        let text = String(data: sample, encoding: .utf8)
            ?? String(data: sample, encoding: .utf16)
            ?? String(data: sample, encoding: .isoLatin1)
            ?? ""
        return data.count > limit ? "\(text)\n\n...（仅显示前 \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))）" : text
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard outlineView === self.outlineView else { return nil }
        guard let node = item as? Node, let entry = firstFileEntry(for: node) else { return nil }
        do {
            let url = try service.extractForPreview(entry: entry, password: password)
            return url as NSURL
        } catch {
            statusLabel.stringValue = error.localizedDescription
            return nil
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard outlineView === self.outlineView, service.canAddItems, !fileURLs(from: info).isEmpty else {
            return []
        }
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard outlineView === self.outlineView else { return false }
        let urls = fileURLs(from: info)
        guard !urls.isEmpty else { return false }
        performArchiveMutation(successMessage: "已添加 \(urls.count) 项") { [service] password in
            try service.addItems(urls, password: password)
            return nil
        }
        return true
    }

    private func fileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let pasteboard = draggingInfo.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        return objects.compactMap { $0 as URL }
    }

    @objc private func extractSelected() {
        let selected = selectedEntries()
        guard !selected.isEmpty else { return }
        chooseDestination { [weak self] destination in
            self?.extract(entries: selected, to: destination)
        }
    }

    @objc private func extractAll() {
        let allFiles = entries.filter { !$0.isDirectory }
        guard !allFiles.isEmpty else { return }
        chooseDestination { [weak self] destination in
            self?.extract(entries: allFiles, to: destination)
        }
    }

    @objc private func openSelected() {
        guard let node = selectedNodes().first else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
            return
        }
        guard let entry = node.entry, !entry.isDirectory else { return }
        let password = password
        statusLabel.stringValue = "正在临时解压并打开..."
        operationQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<URL, Error> = Result {
                try self.service.extractForPreview(entry: entry, password: password)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let url):
                    NSWorkspace.shared.open(url)
                    self.statusLabel.stringValue = "已打开 \(entry.displayName)"
                case .failure(ArchiveBrowserError.passwordRequired):
                    guard self.requestPassword() else { return }
                    self.openSelected()
                case .failure(let error):
                    self.statusLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func toggleExpandAll() {
        isExpanded.toggle()
        if isExpanded {
            expandAll()
            setToolbarButtonSymbol(expandButton, named: "chevron.down", pointSize: 14, weight: .semibold)
            expandLabel.stringValue = "全部折叠"
        } else {
            outlineView.collapseItem(nil, collapseChildren: true)
            setToolbarButtonSymbol(expandButton, named: "chevron.right", pointSize: 14, weight: .semibold)
            expandLabel.stringValue = "全部展开"
        }
    }

    @objc private func filterChanged() {
        filterMode = FilterMode(rawValue: filterPopup.selectedIndex) ?? .all
        applyFilter()
    }

    @objc private func sortChanged() {
        sortMode = SortMode(rawValue: sortPopup.selectedIndex) ?? .name
        guard !isLoadingEntries else { return }
        rootNodes = buildTree(from: entries)
        refreshSidebar()
        applyFilter()
    }

    @objc private func searchChanged() {
        searchQuery = searchField.text
        applyFilter()
    }

    @objc private func addItems() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "添加"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let self else { return }
            let urls = panel.urls
            self.performArchiveMutation(successMessage: "已添加 \(urls.count) 项") { [service = self.service] password in
                try service.addItems(urls, password: password)
                return nil
            }
        }
    }

    @objc private func deleteItems() {
        let selected = selectedEntries()
        guard !selected.isEmpty else { return }
        confirm(
            title: "删除所选内容？",
            message: "将从压缩包中删除 \(selected.count) 个文件，此操作会直接修改压缩包。"
        ) { [weak self] in
            guard let self else { return }
            self.performArchiveMutation(successMessage: "已删除 \(selected.count) 个文件") { [service = self.service] password in
                try service.delete(entries: selected, password: password)
                return nil
            }
        }
    }

    @objc private func cleanItems() {
        performArchiveMutation(successMessage: nil) { [service] password in
            let count = try service.cleanMetadata(password: password)
            return count == 0 ? "没有需要清理的系统元数据" : "已清理 \(count) 个系统元数据项"
        }
    }

    @objc private func toggleListDensity() {
        compactRows.toggle()
        outlineView.rowHeight = compactRows ? 24 : 32
        statusLabel.stringValue = compactRows ? "已切换为紧凑列表" : "已切换为舒展列表"
    }

    @objc private func openArchiveSettings() {
        if let url = URL(string: "macassistant://open?page=archive") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showArchiveInfo() {
        let fileCount = entries.filter { !$0.isDirectory }.count
        let folderCount = flattenedDirectories(in: rootNodes).count
        let sizeText = archiveFileSize().map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "--"
        showInfo(
            title: "压缩包信息",
            message: """
            路径：\(archiveURL.path)
            大小：\(sizeText)
            文件：\(fileCount) 个
            文件夹：\(folderCount) 个
            加密：\(mayRequirePassword ? "是" : "否")
            """
        )
    }

    private func chooseDestination(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到这里"
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let destination = panel.url else { return }
            completion(destination)
        }
    }

    private func extract(entries: [ArchiveBrowserEntry], to destination: URL) {
        guard !isArchiveOperationRunning else { return }
        isArchiveOperationRunning = true
        let password = password
        statusLabel.stringValue = "正在解压 \(entries.count) 个文件..."
        operationQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<Void, Error> = Result {
                try self.service.extract(entries: entries, to: destination, password: password)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isArchiveOperationRunning = false
                switch result {
                case .success:
                    self.statusLabel.stringValue = "已解压 \(entries.count) 个文件"
                case .failure(ArchiveBrowserError.passwordRequired):
                    guard self.requestPassword() else { return }
                    self.extract(entries: entries, to: destination)
                case .failure(let error):
                    self.statusLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func performArchiveMutation(successMessage: String?, operation: @escaping (String?) throws -> String?) {
        guard !isArchiveOperationRunning else { return }
        isArchiveOperationRunning = true
        let password = password
        statusLabel.stringValue = "正在修改压缩包..."
        operationQueue.async { [weak self] in
            guard let self else { return }
            let result: ArchiveOperationResult
            do {
                let operationMessage = try operation(password)
                result = .success(operationMessage ?? successMessage)
            } catch ArchiveBrowserError.passwordRequired {
                result = .passwordRequired
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isArchiveOperationRunning = false
                switch result {
                case .success(let message):
                    self.reload(successMessage: message)
                case .passwordRequired:
                    guard self.requestPassword() else { return }
                    self.performArchiveMutation(successMessage: successMessage, operation: operation)
                case .failure(let error):
                    self.showError(error)
                }
            }
        }
    }

    private func confirm(title: String, message: String, confirmed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { response in
            if response == .alertFirstButtonReturn {
                confirmed()
            }
        }
    }

    private func showError(_ error: Error) {
        statusLabel.stringValue = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = "压缩包操作失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func selectedNodes() -> [Node] {
        outlineView.selectedRowIndexes.compactMap { row in
            outlineView.item(atRow: row) as? Node
        }
    }

    private func selectedEntries() -> [ArchiveBrowserEntry] {
        var result: [ArchiveBrowserEntry] = []
        for node in selectedNodes() {
            if node.isDirectory {
                let prefix = node.path.hasSuffix("/") ? node.path : "\(node.path)/"
                result += entries.filter { !$0.isDirectory && $0.path.hasPrefix(prefix) }
            } else if let entry = node.entry, !entry.isDirectory {
                result.append(entry)
            }
        }
        return Array(Set(result)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func firstFileEntry(for node: Node) -> ArchiveBrowserEntry? {
        if let entry = node.entry, !entry.isDirectory {
            return entry
        }
        let prefix = node.path.hasSuffix("/") ? node.path : "\(node.path)/"
        return entries.first { !$0.isDirectory && $0.path.hasPrefix(prefix) }
    }

    private var password: String? {
        archivePassword
    }

    private func requestPassword() -> Bool {
        do {
            guard let password = try ArchivePasswordPrompt.requestPassword(for: archiveURL, validator: { [service] password in
                try service.validatePassword(password)
            }) else {
                return false
            }
            archivePassword = password
            return true
        } catch {
            statusLabel.stringValue = error.localizedDescription
            return false
        }
    }

    private func updateSelectionState() {
        let hasSelection = !selectedEntries().isEmpty
        setToolbarItem(
            button: extractButton,
            label: extractLabel,
            tint: .systemPurple,
            enabled: hasSelection
        )
        setToolbarItem(
            button: deleteButton,
            label: deleteLabel,
            tint: .systemRed,
            enabled: hasSelection
        )
        updateInspector()
    }

    private func updateFooter() {
        let fileCount = entries.filter { !$0.isDirectory }.count
        let folderCount = flattenedDirectories(in: rootNodes).count
        let sizeText = archiveFileSize().map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "--"
        statusLabel.stringValue = "压缩包大小：\(sizeText)，共 \(fileCount) 个文件，\(folderCount) 个文件夹" + (mayRequirePassword ? "，已加密" : "")
    }

    private func archiveFileSize() -> Int64? {
        (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private func text(for node: Node, column: NSUserInterfaceItemIdentifier) -> String {
        switch column {
        case Column.name:
            return node.name
        case Column.size:
            guard !node.isDirectory, let size = node.entry?.size else { return "--" }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        case Column.modified:
            guard let date = node.entry?.modifiedAt else { return "" }
            return Self.dateFormatter.string(from: date)
        case Column.kind:
            return kindTitle(for: node)
        default:
            return ""
        }
    }

    private func kindTitle(for node: Node) -> String {
        if node.isDirectory {
            return "文件夹"
        }
        let ext = URL(fileURLWithPath: node.name).pathExtension
        if let type = UTType(filenameExtension: ext), let description = type.localizedDescription {
            return description
        }
        return ext.isEmpty ? "文件" : "\(ext.uppercased()) 文件"
    }

    private func kindTitle(for entry: ArchiveBrowserEntry) -> String {
        if entry.isDirectory {
            return "文件夹"
        }
        let ext = URL(fileURLWithPath: entry.displayName).pathExtension
        if let type = UTType(filenameExtension: ext), let description = type.localizedDescription {
            return description
        }
        return ext.isEmpty ? "文件" : "\(ext.uppercased()) 文件"
    }

    private func icon(for node: Node) -> NSImage {
        if node.isDirectory {
            return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage()
        }
        let ext = URL(fileURLWithPath: node.name).pathExtension
        if let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
    }

    private func expandAll() {
        for node in visibleNodes {
            outlineView.expandItem(node, expandChildren: true)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func setToolbarItem(button: ArchiveToolbarButton, label: NSTextField, tint: NSColor, enabled: Bool) {
        button.isEnabled = enabled
        button.setTint(tint)
        button.setTitle(label.stringValue)
    }

    private func setToolbarButtonSymbol(_ button: ArchiveToolbarButton, named name: String, pointSize: CGFloat, weight: NSFont.Weight) {
        button.setImage(configuredSymbol(named: name, pointSize: pointSize, weight: weight))
    }

    private func configuredSymbol(named name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        if #available(macOS 11.0, *) {
            return image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) ?? image
        }
        return image
    }
}
