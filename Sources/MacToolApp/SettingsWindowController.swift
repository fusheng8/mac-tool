import AppKit
import ApplicationServices
import CoreGraphics
import CoreServices
import Foundation
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private enum Layout {
        static let sidebarWidth: CGFloat = 192
        static let sidebarHorizontalInset: CGFloat = 13
        static let contentWidth: CGFloat = 660
        static let rowWidth: CGFloat = 620
    }

    enum SettingsPage: Int {
        case systemOverview
        case settings
        case displays
        case clipboard
        case archive
        case contextMenu
        case portManagement
        case appUninstall
        case permissions
    }

    private enum GeneralSettingsAction: Int {
        case checkForUpdates
        case exportConfig
        case importConfig
        case iCloudBackup
        case iCloudSync
        case retryClipboardKey
        case clearUndecryptableClipboard
    }

    private enum PermissionAction: Int {
        case accessibility
        case automation
        case finderExtension
        case fullDiskAccess
        case refresh
        case copyDiagnostics
        case exportDiagnostics
        case displayRecovery
        case finderExtensionTest
    }

    private enum DDCQuickSetting: Int, CaseIterable {
        case brightness
        case contrast
        case volume

        var title: String {
            switch self {
            case .brightness: return "亮度"
            case .contrast: return "对比度"
            case .volume: return "音量"
            }
        }

        var detail: String {
            switch self {
            case .brightness: return "VCP 0x10，常见外接显示器支持。"
            case .contrast: return "VCP 0x12，部分显示器会禁用该项。"
            case .volume: return "VCP 0x62，仅带音频输出的显示器可用。"
            }
        }

        var vcpCode: String {
            switch self {
            case .brightness: return "0x10"
            case .contrast: return "0x12"
            case .volume: return "0x62"
            }
        }

        var defaultValue: Int {
            switch self {
            case .brightness, .contrast: return 50
            case .volume: return 30
            }
        }
    }

    private struct DisplayModeOption {
        let mode: CGDisplayMode
        let title: String
        let isCurrent: Bool
        let isHiDPI: Bool
    }

    private struct PendingDisplayModeConfirmation {
        let displayID: CGDirectDisplayID
        let previousMode: CGDisplayMode
        let previousTitle: String
        let appliedTitle: String
    }

    private let store: ProfileStore
    private let detector: DisplayDetector
    private let disconnect: SoftDisconnectController
    private let recovery: RecoveryManager
    private let statuses: RuntimeStatusStore
    private let clipboardController: ClipboardHistoryController
    private let ddc = DDCController()
    private let ddcWriteQueue = DispatchQueue(label: "app.mac-tool.ddc-write", qos: .userInitiated)
    private let ddcWriteThrottleInterval: TimeInterval = 0.12
    private let onSave: () -> Void
    private let onClose: () -> Void
    private let onCheckForUpdates: () -> Void

    private var profiles: [DisplayProfile]
    private var scannedDisplays: [DisplaySnapshot] = []
    private var selectedDisplayIndex = 0
    private var selectedSettingsPage: SettingsPage = .systemOverview
    private var isReloadingUI = false

    private let displayTabsStack = NSStackView()
    private let contentStack = NSStackView()
    private let pageTitleLabel = NSTextField(labelWithString: "")
    private let sidebarSearchField = MacSearchField()
    private let refreshDisplaysButton = MacIconButton(symbolName: "arrow.clockwise")
    private let systemOverviewSidebarButton = SidebarNavItem(title: "系统概览", symbolName: "desktopcomputer")
    private let settingsSidebarButton = SidebarNavItem(title: "设置", symbolName: "gearshape")
    private let displaySidebarButton = SidebarNavItem(title: "显示器", symbolName: "display")
    private let clipboardSidebarButton = SidebarNavItem(title: "剪贴板", symbolName: "doc.on.clipboard")
    private let archiveSidebarButton = SidebarNavItem(title: "压缩/解压", symbolName: "archivebox")
    private let contextMenuSidebarButton = SidebarNavItem(title: "右键菜单", symbolName: "cursorarrow.click.2")
    private let portManagementSidebarButton = SidebarNavItem(title: "端口管理", symbolName: "network")
    private let appUninstallSidebarButton = SidebarNavItem(title: "应用卸载", symbolName: "trash")
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeDisplaySwitch = MacSwitchControl()
    private let clipboardEnabledSwitch = MacSwitchControl()
    private let clipboardPausedSwitch = MacSwitchControl()
    private let clipboardExcludePasswordManagersSwitch = MacSwitchControl()
    private let clipboardRetentionDaysControl = MacNumberControl()
    private let clipboardPollIntervalControl = MacNumberControl()
    private let clipboardStructuredPreviewLimitControl = MacNumberControl()
    private let clipboardExcludedAppsField = MacSearchField()
    private let contextMenuEnabledSwitch = MacSwitchControl()
    private let archiveStripMacMetadataSwitch = MacSwitchControl()
    private let archiveDefaultOpenerSwitch = MacSwitchControl()
    private let archiveAutoCloseExtractionProgressSwitch = MacSwitchControl()
    private let archiveCompressionLevelControl = MacNumberControl()
    private let displayAutoReconnectSwitch = MacSwitchControl()
    private let displayReconnectDelayControl = MacNumberControl()
    private let displayConfirmCloseSwitch = MacSwitchControl()
    private var archiveFormatSwitches: [ArchiveFormat: MacSwitchControl] = [:]
    private let maxHistoryCountControl = MacNumberControl()
    private let portManagementView = PortManagementView()
    private let applicationUninstallerView = ApplicationUninstallerView()
    private let resolutionPopup = MacSelectControl()
    private var portManagementWidthConstraint: NSLayoutConstraint?
    private var applicationUninstallerWidthConstraint: NSLayoutConstraint?
    private var displayModeOptions: [DisplayModeOption] = []
    private weak var resolutionStatusLabel: NSTextField?
    private var pendingDisplayModeConfirmation: PendingDisplayModeConfirmation?
    private var displayModeConfirmationTimer: Timer?
    private var ddcSliders: [DDCQuickSetting: MacSliderControl] = [:]
    private var ddcValueLabels: [DDCQuickSetting: NSTextField] = [:]
    private var pendingDDCWriteWorkItems: [DDCQuickSetting: DispatchWorkItem] = [:]
    private var ddcWriteRequestIDs: [DDCQuickSetting: UUID] = [:]
    private var pendingDDCWriteValues: [DDCQuickSetting: Int] = [:]
    private var ddcWriteInFlight: Set<DDCQuickSetting> = []
    private var ddcLastWriteTimes: [DDCQuickSetting: Date] = [:]
    private var pendingDisplayStateRefreshWorkItem: DispatchWorkItem?
    private weak var ddcStatusLabel: NSTextField?
    private var systemOverviewTimer: Timer?
    private let systemOverviewQueue = DispatchQueue(label: "com.fusheng.mac-tool.system-overview", qos: .utility)
    private var isSystemOverviewSampling = false
    private var previousSystemProcessorTicks: SystemProcessorTicks?
    private var systemBasicInfoValueLabels: [String: NSTextField] = [:]
    private weak var systemCPUChartView: SystemMetricChartView?
    private weak var systemLoadChartView: SystemMetricChartView?
    private weak var systemMemoryChartView: SystemMetricChartView?
    private weak var systemDiskChartView: SystemMetricChartView?
    private var hotKeyRecorder: HotKeyRecorderView!
    private let clipboardHotKeyEnabledSwitch = MacSwitchControl()
    private var clipboardShortcutSwitches: [ClipboardShortcut: MacSwitchControl] = [:]
    private var clipboardShortcutRecorders: [ClipboardShortcut: HotKeyRecorderView] = [:]

    init(
        store: ProfileStore,
        detector: DisplayDetector,
        disconnect: SoftDisconnectController,
        recovery: RecoveryManager,
        statuses: RuntimeStatusStore,
        clipboardController: ClipboardHistoryController,
        onCheckForUpdates: @escaping () -> Void = {},
        onSave: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.detector = detector
        self.disconnect = disconnect
        self.recovery = recovery
        self.statuses = statuses
        self.clipboardController = clipboardController
        self.onCheckForUpdates = onCheckForUpdates
        self.onSave = onSave
        self.onClose = onClose
        self.profiles = store.profiles

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac助手"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 820, height: 480)
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionGuideDidComplete(_:)),
            name: .permissionGuideDidComplete,
            object: nil
        )

        hotKeyRecorder = HotKeyRecorderView(hotKey: store.clipboard.hotKey)
        hotKeyRecorder.onChange = { [weak self] hotKey in
            self?.saveClipboardConfig(hotKey: hotKey)
        }
        configureClipboardShortcutControls()
        configureMaxHistoryControls()
        configureClipboardRetentionControls()
        configureClipboardPollIntervalControl()
        configureClipboardStructuredPreviewLimitControl()
        configureDisplayReconnectDelayControl()
        configureArchiveCompressionLevelControl()
        buildUI()
        refreshDisplays()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    deinit {
        stopSystemOverviewTimer()
        pendingDisplayStateRefreshWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func selectPage(_ page: SettingsPage) {
        guard selectedSettingsPage != page else {
            return
        }
        selectedSettingsPage = page
        reloadCurrentPage()
    }

    func refreshAfterDisplayChange() {
        profiles = store.profiles
        refreshDisplays()
    }

    func windowWillClose(_ notification: Notification) {
        stopSystemOverviewTimer()
        isSystemOverviewSampling = false
        pendingDisplayStateRefreshWorkItem?.cancel()
        cancelPendingDDCWrites()
        if pendingDisplayModeConfirmation != nil {
            restorePendingDisplayMode(reason: "设置窗口关闭")
        }
        onClose()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updateSystemOverviewTimer()
    }

    @objc private func permissionGuideDidComplete(_ notification: Notification) {
        guard selectedSettingsPage == .settings || selectedSettingsPage == .permissions else { return }
        reloadCurrentPage()
    }

    private func configureMaxHistoryControls() {
        maxHistoryCountControl.minValue = 10
        maxHistoryCountControl.maxValue = 10000
        maxHistoryCountControl.increment = 10
        maxHistoryCountControl.onChange = { [weak self] _ in
            self?.saveClipboardConfig()
        }
    }

    private func configureClipboardShortcutControls() {
        clipboardHotKeyEnabledSwitch.target = self
        clipboardHotKeyEnabledSwitch.action = #selector(clipboardHotKeyEnabledChanged)

        for shortcut in ClipboardShortcut.allCases {
            let binding = store.clipboard.shortcuts.binding(for: shortcut)
            let enabledSwitch = MacSwitchControl()
            enabledSwitch.target = self
            enabledSwitch.action = #selector(clipboardShortcutEnabledChanged(_:))

            let recorder = HotKeyRecorderView(hotKey: binding.hotKey)
            recorder.allowsModifierless = true
            recorder.onChange = { [weak self] hotKey in
                self?.saveClipboardShortcut(shortcut, hotKey: hotKey)
            }

            clipboardShortcutSwitches[shortcut] = enabledSwitch
            clipboardShortcutRecorders[shortcut] = recorder
        }
    }

    private func configureClipboardRetentionControls() {
        clipboardRetentionDaysControl.minValue = 0
        clipboardRetentionDaysControl.maxValue = 365
        clipboardRetentionDaysControl.increment = 1
        clipboardRetentionDaysControl.onChange = { [weak self] _ in
            self?.saveClipboardConfig()
        }
        clipboardExcludedAppsField.placeholder = "排除的 Bundle ID"
        clipboardExcludedAppsField.onChange = { [weak self] _ in self?.saveClipboardConfig() }
    }

    private func configureClipboardPollIntervalControl() {
        clipboardPollIntervalControl.minValue = 200
        clipboardPollIntervalControl.maxValue = 10_000
        clipboardPollIntervalControl.increment = 100
        clipboardPollIntervalControl.onChange = { [weak self] _ in
            self?.saveClipboardConfig()
        }
    }

    private func configureClipboardStructuredPreviewLimitControl() {
        clipboardStructuredPreviewLimitControl.minValue = 16
        clipboardStructuredPreviewLimitControl.maxValue = 4096
        clipboardStructuredPreviewLimitControl.increment = 64
        clipboardStructuredPreviewLimitControl.onChange = { [weak self] _ in
            self?.saveClipboardConfig()
        }
    }

    private func configureDisplayReconnectDelayControl() {
        displayReconnectDelayControl.minValue = 5
        displayReconnectDelayControl.maxValue = 3600
        displayReconnectDelayControl.increment = 5
        displayReconnectDelayControl.onChange = { [weak self] _ in
            _ = self?.saveSelectedProfile()
        }
    }

    private func configureArchiveCompressionLevelControl() {
        archiveCompressionLevelControl.minValue = 0
        archiveCompressionLevelControl.maxValue = 9
        archiveCompressionLevelControl.increment = 1
        archiveCompressionLevelControl.onChange = { [weak self] _ in
            self?.saveArchiveOptions()
        }
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = MacAssistantUI.Color.window.cgColor

        let root = NSStackView()
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        root.addArrangedSubview(buildSidebar())
        root.addArrangedSubview(buildMainArea())
    }

    private func buildSidebar() -> NSView {
        let sidebar = LayerBackedView(backgroundColor: MacAssistantUI.Color.sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth).isActive = true

        sidebarSearchField.placeholder = "搜索"
        sidebarSearchField.onChange = { [weak self] _ in
            self?.updateSidebarSearchResults()
        }

        configureSidebarButton(systemOverviewSidebarButton, page: .systemOverview)
        configureSidebarButton(settingsSidebarButton, page: .settings)
        configureSidebarButton(displaySidebarButton, page: .displays)
        configureSidebarButton(clipboardSidebarButton, page: .clipboard)
        configureSidebarButton(archiveSidebarButton, page: .archive)
        configureSidebarButton(contextMenuSidebarButton, page: .contextMenu)
        configureSidebarButton(portManagementSidebarButton, page: .portManagement)
        configureSidebarButton(appUninstallSidebarButton, page: .appUninstall)

        let stack = NSStackView(views: [sidebarSearchField, systemOverviewSidebarButton, displaySidebarButton, clipboardSidebarButton, archiveSidebarButton, contextMenuSidebarButton, portManagementSidebarButton, appUninstallSidebarButton, settingsSidebarButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: Layout.sidebarHorizontalInset),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -Layout.sidebarHorizontalInset),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 52),
            sidebarSearchField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateSidebarSelection()
        updateSidebarSearchResults()
        return sidebar
    }

    private func configureSidebarButton(_ button: SidebarNavItem, page: SettingsPage) {
        button.target = self
        button.action = #selector(selectSidebarPage(_:))
        button.tag = page.rawValue
        button.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth - Layout.sidebarHorizontalInset * 2).isActive = true
    }

    private func buildMainArea() -> NSView {
        let main = LayerBackedView(backgroundColor: NSColor.white.withAlphaComponent(0.56))
        main.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        let scrollView = buildScrollView()
        main.addSubview(header)
        main.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            header.topAnchor.constraint(equalTo: main.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),

            scrollView.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: main.bottomAnchor)
        ])

        return main
    }

    private func buildHeader() -> NSView {
        let header = LayerBackedView(backgroundColor: NSColor.white.withAlphaComponent(0.44))
        header.wantsLayer = true
        header.layer?.borderColor = MacAssistantUI.Color.hairline.cgColor
        header.layer?.borderWidth = 0
        header.translatesAutoresizingMaskIntoConstraints = false

        displayTabsStack.orientation = .horizontal
        displayTabsStack.alignment = .centerY
        displayTabsStack.distribution = .fillEqually
        displayTabsStack.spacing = 4
        displayTabsStack.translatesAutoresizingMaskIntoConstraints = false

        pageTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        pageTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(pageTitleLabel)

        refreshDisplaysButton.target = self
        refreshDisplaysButton.action = #selector(refreshDisplaysAction)
        refreshDisplaysButton.toolTip = "刷新显示器"
        header.addSubview(refreshDisplaysButton)

        NSLayoutConstraint.activate([
            pageTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            pageTitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            refreshDisplaysButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            refreshDisplaysButton.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        updateHeader()
        return header
    }

    private func buildScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 24
        contentStack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: contentStack.heightAnchor),

            contentStack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            contentStack.widthAnchor.constraint(lessThanOrEqualTo: documentView.widthAnchor, constant: -48)
        ])
        return scrollView
    }

    private func refreshDisplays() {
        let liveDisplays = detector.onlineDisplays()
        store.rememberDisplays(liveDisplays)
        scannedDisplays = mergedDisplayList(liveDisplays: liveDisplays)
        selectedDisplayIndex = min(selectedDisplayIndex, max(0, scannedDisplays.count - 1))
        rebuildDisplayTabs()
        reloadCurrentPage()
    }

    private func refreshDisplaysAfterStateChange() {
        refreshDisplays()

        pendingDisplayStateRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshDisplays()
        }
        pendingDisplayStateRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func mergedDisplayList(liveDisplays: [DisplaySnapshot]) -> [DisplaySnapshot] {
        var displays = liveDisplays.filter { !$0.isVirtualPlaceholder }
        let cachedDisplays = (store.lastSeenDisplays + store.pendingReconnects.map(\.displaySnapshot))
            .filter { !$0.isVirtualPlaceholder }
        for cached in cachedDisplays where !displays.contains(where: { sameDisplay($0, cached) }) {
            var display = cached
            display.isActive = false
            displays.append(display)
        }
        return displays.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive
            }
            if lhs.isBuiltIn != rhs.isBuiltIn {
                return !lhs.isBuiltIn
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func sameDisplay(_ lhs: DisplaySnapshot, _ rhs: DisplaySnapshot) -> Bool {
        lhs.hasSameStableIdentity(as: rhs)
    }

    private func reloadCurrentPage() {
        updateSidebarSelection()
        updateHeader()
        switch selectedSettingsPage {
        case .systemOverview:
            reloadSystemOverviewSettings()
        case .settings, .permissions:
            reloadGeneralSettings()
        case .displays:
            reloadSelectedDisplay()
        case .clipboard:
            reloadClipboardSettings()
        case .archive:
            reloadArchiveSettings()
        case .contextMenu:
            reloadContextMenuSettings()
        case .portManagement:
            reloadPortManagementSettings()
        case .appUninstall:
            reloadApplicationUninstallerSettings()
        }
        updateSystemOverviewTimer()
    }

    private func updateHeader() {
        let isDisplaysPage = selectedSettingsPage == .displays
        refreshDisplaysButton.isHidden = !isDisplaysPage
        pageTitleLabel.isHidden = false
        switch selectedSettingsPage {
        case .systemOverview:
            pageTitleLabel.stringValue = "系统概览"
        case .settings, .permissions:
            pageTitleLabel.stringValue = "设置"
        case .displays:
            pageTitleLabel.stringValue = "显示器设置"
        case .clipboard:
            pageTitleLabel.stringValue = "剪贴板历史"
        case .archive:
            pageTitleLabel.stringValue = "压缩/解压"
        case .contextMenu:
            pageTitleLabel.stringValue = "Finder 右键菜单扩展"
        case .portManagement:
            pageTitleLabel.stringValue = "端口管理"
        case .appUninstall:
            pageTitleLabel.stringValue = "应用卸载"
        }
    }

    private func updateSidebarSelection() {
        styleSidebarButton(systemOverviewSidebarButton, selected: selectedSettingsPage == .systemOverview)
        styleSidebarButton(settingsSidebarButton, selected: selectedSettingsPage == .settings || selectedSettingsPage == .permissions)
        styleSidebarButton(displaySidebarButton, selected: selectedSettingsPage == .displays)
        styleSidebarButton(clipboardSidebarButton, selected: selectedSettingsPage == .clipboard)
        styleSidebarButton(archiveSidebarButton, selected: selectedSettingsPage == .archive)
        styleSidebarButton(contextMenuSidebarButton, selected: selectedSettingsPage == .contextMenu)
        styleSidebarButton(portManagementSidebarButton, selected: selectedSettingsPage == .portManagement)
        styleSidebarButton(appUninstallSidebarButton, selected: selectedSettingsPage == .appUninstall)
    }

    private func updateSidebarSearchResults() {
        let query = sidebarSearchField.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items: [(SidebarNavItem, SettingsPage, [String])] = [
            (systemOverviewSidebarButton, .systemOverview, ["系统", "概览", "电脑", "信息", "负载", "内存", "磁盘", "cpu", "system", "overview", "load", "memory", "disk"]),
            (displaySidebarButton, .displays, ["显示器", "显示", "屏幕", "display", "monitor"]),
            (clipboardSidebarButton, .clipboard, ["剪贴板", "剪切", "复制", "粘贴", "clipboard"]),
            (archiveSidebarButton, .archive, ["压缩", "解压", "归档", "zip", "tar", "rar", "7z", "archive", "extract", "compress"]),
            (contextMenuSidebarButton, .contextMenu, ["右键菜单", "右键", "菜单", "finder", "context", "menu"]),
            (portManagementSidebarButton, .portManagement, ["端口管理", "端口", "占用", "进程", "应用", "路径", "port", "pid", "process"]),
            (appUninstallSidebarButton, .appUninstall, ["应用卸载", "卸载", "应用", "残留", "废纸篓", "bundle", "app", "application", "uninstall", "trash"]),
            (settingsSidebarButton, .settings, ["设置", "通用", "配置", "导入", "导出", "备份", "同步", "icloud", "权限", "授权", "辅助功能", "自动化", "扩展", "完全磁盘访问", "privacy", "permission", "accessibility", "automation", "full disk", "files"])
        ]

        let matches = items.map { item, page, keywords -> (SidebarNavItem, SettingsPage, Bool) in
            let matched = query.isEmpty || keywords.contains { $0.lowercased().contains(query) }
            item.isHidden = !matched
            return (item, page, matched)
        }

        if !matches.contains(where: { $0.1 == selectedSettingsPage && $0.2 }),
           let firstMatch = matches.first(where: { $0.2 }) {
            selectedSettingsPage = firstMatch.1
            reloadCurrentPage()
        }
    }

    private func styleSidebarButton(_ button: SidebarNavItem, selected: Bool) {
        let tint: NSColor
        switch SettingsPage(rawValue: button.tag) {
        case .systemOverview:
            tint = MacAssistantUI.Color.green
        case .settings:
            tint = MacAssistantUI.Color.blue
        case .displays:
            tint = MacAssistantUI.Color.blue
        case .clipboard:
            tint = MacAssistantUI.Color.amber
        case .archive:
            tint = MacAssistantUI.Color.purple
        case .contextMenu:
            tint = MacAssistantUI.Color.purple
        case .portManagement:
            tint = MacAssistantUI.Color.blue
        case .appUninstall:
            tint = NSColor.systemRed
        case .permissions:
            tint = MacAssistantUI.Color.green
        case .none:
            tint = MacAssistantUI.Color.blue
        }
        button.setSelected(selected, accentColor: tint)
    }

    private func rebuildDisplayTabs() {
        displayTabsStack.arrangedSubviews.forEach { view in
            displayTabsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, display) in scannedDisplays.enumerated() {
            let title = display.isBuiltIn ? "内置显示屏" : (display.displayName.isEmpty ? "外接显示器" : display.displayName)
            let subtype = display.isBuiltIn ? "MacBook" : "外接"
            let subtitle = display.isActive ? subtype : "已关闭"
            displayTabsStack.addArrangedSubview(displayTabButton(
                title: title,
                subtitle: subtitle,
                symbolName: display.isBuiltIn ? "laptopcomputer" : "display",
                index: index,
                selected: index == selectedDisplayIndex
            ))
        }
    }

    private func displayTabButton(title: String, subtitle: String, symbolName: String, index: Int, selected: Bool) -> MacSegmentButton {
        let button = MacSegmentButton(title: title)
        button.selected = selected
        button.target = self
        button.action = #selector(selectDisplayTab(_:))
        button.tag = index
        button.toolTip = subtitle
        return button
    }

    private func displaySelector() -> NSView {
        let wrap = LayerBackedView(
            backgroundColor: NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.94, alpha: 0.62),
            cornerRadius: 8,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.heightAnchor.constraint(equalToConstant: 34).isActive = true

        displayTabsStack.removeFromSuperview()
        wrap.addSubview(displayTabsStack)
        NSLayoutConstraint.activate([
            displayTabsStack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 3),
            displayTabsStack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -3),
            displayTabsStack.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 3),
            displayTabsStack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -3)
        ])
        return wrap
    }

    private func reloadSelectedDisplay() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard scannedDisplays.indices.contains(selectedDisplayIndex) else {
            contentStack.addArrangedSubview(emptyState())
            return
        }

        let display = scannedDisplays[selectedDisplayIndex]
        let profile = existingProfile(for: display) ?? makeProfile(for: display)

        isReloadingUI = true
        defer { isReloadingUI = false }

        titleLabel.stringValue = ""
        contentStack.addArrangedSubview(displaySelector())
        contentStack.addArrangedSubview(displaySummary(display: display, profile: profile))
        contentStack.addArrangedSubview(displayDetailsSection(display: display, profile: profile))
        contentStack.addArrangedSubview(settingsSection(display: display))

        loadControls(profile: profile, display: display)
    }

    private func displaySummary(display: DisplaySnapshot, profile: DisplayProfile) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Layout.contentWidth).isActive = true

        let monitor = LayerBackedView(
            backgroundColor: NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.24, alpha: display.isActive ? 1 : 0.45),
            cornerRadius: display.isBuiltIn ? 8 : 5,
            borderColor: NSColor(calibratedRed: 0.60, green: 0.66, blue: 0.76, alpha: 0.9),
            borderWidth: display.isBuiltIn ? 4 : 2
        )
        monitor.widthAnchor.constraint(equalToConstant: display.isBuiltIn ? 192 : 224).isActive = true
        monitor.heightAnchor.constraint(equalToConstant: display.isBuiltIn ? 128 : 144).isActive = true

        let monitorText = NSTextField(labelWithString: display.isActive ? (display.isBuiltIn ? "Built-in Display" : "External Display") : "Display Off")
        monitorText.font = .systemFont(ofSize: 12, weight: .semibold)
        monitorText.textColor = NSColor(calibratedRed: 0.58, green: 0.63, blue: 0.72, alpha: 1)
        monitorText.translatesAutoresizingMaskIntoConstraints = false
        monitor.addSubview(monitorText)
        NSLayoutConstraint.activate([
            monitorText.centerXAnchor.constraint(equalTo: monitor.centerXAnchor),
            monitorText.centerYAnchor.constraint(equalTo: monitor.centerYAnchor)
        ])

        let name = MacAssistantUI.title(suggestedProfileName(for: display), size: 15, weight: .bold)
        name.alignment = .center
        let statusText = "状态：\(runtimeStatusText(profile: profile, display: display))"
        let status = MacAssistantUI.caption(statusText, size: 12)
        status.alignment = .center

        stack.addArrangedSubview(monitor)
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(status)
        return stack
    }

    private func reloadSystemOverviewSettings() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        systemBasicInfoValueLabels.removeAll()
        previousSystemProcessorTicks = nil

        let snapshot = SystemInfoProvider.snapshot()
        contentStack.addArrangedSubview(systemBasicInfoSection(snapshot: snapshot))
        contentStack.addArrangedSubview(systemChartsSection())
        applySystemOverviewSnapshot(snapshot)
        updateSystemOverviewTimer()
    }

    private func reloadClipboardSettings() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        loadClipboardControls()
        contentStack.addArrangedSubview(clipboardSection())
        contentStack.addArrangedSubview(clipboardShortcutSection())
    }

    private func reloadArchiveSettings() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        archiveFormatSwitches.removeAll()
        contentStack.addArrangedSubview(archiveOptionsSection())
        contentStack.addArrangedSubview(archiveFormatsSection())
        contentStack.addArrangedSubview(archiveContextMenuSection())
    }

    private func reloadGeneralSettings() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        contentStack.addArrangedSubview(versionSection())
        contentStack.addArrangedSubview(configManagementSection())
        contentStack.addArrangedSubview(iCloudSettingsSection())
        contentStack.addArrangedSubview(permissionsSection())
        contentStack.addArrangedSubview(diagnosticsSection())
        contentStack.addArrangedSubview(permissionHintSection())
    }

    private func reloadPermissionsSettings() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        contentStack.addArrangedSubview(permissionsSection())
        contentStack.addArrangedSubview(diagnosticsSection())
        contentStack.addArrangedSubview(permissionHintSection())
    }

    private func reloadContextMenuSettings() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        loadContextMenuControls()
        contentStack.addArrangedSubview(contextMenuGeneralSection())
        contentStack.addArrangedSubview(contextMenuItemsSection())
    }

    private func reloadPortManagementSettings() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if portManagementWidthConstraint == nil {
            portManagementWidthConstraint = portManagementView.widthAnchor.constraint(equalToConstant: Layout.contentWidth)
            portManagementWidthConstraint?.isActive = true
        }
        contentStack.addArrangedSubview(portManagementView)
        portManagementView.refreshIfNeeded()
    }

    private func reloadApplicationUninstallerSettings() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if applicationUninstallerWidthConstraint == nil {
            applicationUninstallerWidthConstraint = applicationUninstallerView.widthAnchor.constraint(equalToConstant: Layout.contentWidth)
            applicationUninstallerWidthConstraint?.isActive = true
        }
        contentStack.addArrangedSubview(applicationUninstallerView)
        applicationUninstallerView.refreshIfNeeded()
    }

    private func emptyState() -> NSView {
        let label = NSTextField(labelWithString: "没有扫描到显示器。请确认显示器已连接，然后点击“刷新显示器”。")
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func settingsSection(display: DisplaySnapshot) -> NSView {
        var rows: [NSView] = [
            switchRow(title: "关闭此显示器", detail: "开关显示当前实际关闭状态；安全兜底时会临时保持打开。", control: closeDisplaySwitch),
            switchRow(title: "关闭前二次确认", detail: "避免误触导致屏幕短暂黑屏。", control: displayConfirmCloseSwitch),
            switchRow(title: "自动恢复", detail: "关闭显示器后按设定时间自动重新打开。", control: displayAutoReconnectSwitch),
            controlRow(title: "恢复倒计时", detail: "自动恢复开启时生效，单位秒。", control: secondsControl(displayReconnectDelayControl)),
            displayTestCloseRow(display: display),
            recoveryStatusRow(display: display),
            displayRecoveryFallbackRow()
        ]
        rows.append(contentsOf: resolutionControlRows(display: display))
        rows.append(contentsOf: ddcQuickControlRows(display: display))
        return section(title: "显示器控制", rows: rows)
    }

    private func displayDetailsSection(display: DisplaySnapshot, profile: DisplayProfile) -> NSView {
        return section(title: "显示器详情", rows: [
            detailGridRow(display: display, profile: profile),
            detailActionsRow(display: display)
        ])
    }

    private func detailGridRow(display: DisplaySnapshot, profile: DisplayProfile) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true

        let fields: [(String, String)] = [
            ("名称", suggestedProfileName(for: display)),
            ("类型", display.isBuiltIn ? "内置显示屏" : "外接显示器"),
            ("连接状态", display.isActive ? "在线" : "已关闭/离线"),
            ("系统 ID", display.runtimeDisplayID == 0 ? "未知" : "\(display.runtimeDisplayID)"),
            ("EDID UUID", normalizedDetail(display.edidUUID)),
            ("厂商 ID", normalizedDetail(display.vendorId)),
            ("型号 ID", normalizedDetail(display.modelId)),
            ("序列号", normalizedDetail(display.serialNumber == "0" ? "" : display.serialNumber)),
            ("厂商", normalizedDetail(display.manufacturer)),
            ("字母序列号", normalizedDetail(display.alphanumericSerial)),
            ("IO 位置", normalizedDetail(display.ioLocation)),
            ("当前模式", currentDisplayModeDescription(display: display)),
            ("运行状态", runtimeStatusText(profile: profile, display: display))
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        for pair in fields.chunked(into: 2) {
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .top
            line.spacing = 12
            line.translatesAutoresizingMaskIntoConstraints = false
            for field in pair {
                line.addArrangedSubview(detailItem(title: field.0, value: field.1))
            }
            stack.addArrangedSubview(line)
        }

        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14)
        ])
        return row
    }

    private func detailItem(title: String, value: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.maximumNumberOfLines = 2
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: (Layout.rowWidth - 12) / 2).isActive = true
        return stack
    }

    private func detailActionsRow(display: DisplaySnapshot) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let hint = MacAssistantUI.caption("DDC 控制依赖外接显示器的 EDID 和 DDC/CI 支持；内置屏通常不可用。", size: 12)
        let button = PermissionActionButton(title: "复制详情", target: self, action: #selector(copyDisplayDetails(_:)))

        row.addSubview(hint)
        row.addSubview(button)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            hint.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func ddcQuickControlRows(display: DisplaySnapshot) -> [NSView] {
        cancelPendingDDCWrites()
        ddcSliders.removeAll()
        ddcValueLabels.removeAll()

        var rows = DDCQuickSetting.allCases.map { ddcQuickControlRow(setting: $0, display: display) }
        rows.append(ddcProbeRow(display: display))
        let status = MacAssistantUI.caption(ddcAvailabilityMessage(display: display), size: 12)
        ddcStatusLabel = status
        rows.append(statusRow(status))
        return rows
    }

    private func resolutionControlRows(display: DisplaySnapshot) -> [NSView] {
        displayModeOptions = displayModeOptions(for: display)
        let status = MacAssistantUI.caption(resolutionAvailabilityMessage(display: display), size: 12)
        resolutionStatusLabel = status
        return [
            resolutionControlRow(display: display),
            statusRow(status)
        ]
    }

    private func resolutionControlRow(display: DisplaySnapshot) -> NSView {
        resolutionPopup.isEnabled = !displayModeOptions.isEmpty
        resolutionPopup.translatesAutoresizingMaskIntoConstraints = false
        resolutionPopup.widthAnchor.constraint(equalToConstant: 268).isActive = true

        if displayModeOptions.isEmpty {
            resolutionPopup.items = ["没有可用模式"]
        } else {
            resolutionPopup.items = displayModeOptions.map(\.title)
            if let currentIndex = displayModeOptions.firstIndex(where: \.isCurrent) {
                resolutionPopup.selectedIndex = currentIndex
            }
        }

        let applyButton = PermissionActionButton(title: "应用", target: self, action: #selector(applyDisplayMode(_:)))
        applyButton.isEnabled = !displayModeOptions.isEmpty

        let stack = NSStackView(views: [resolutionPopup, applyButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        return controlRow(
            title: "分辨率",
            detail: "切换系统已暴露的桌面显示模式；带 HiDPI 标记的是 Retina 缩放模式。",
            control: stack
        )
    }

    private func ddcQuickControlRow(setting: DDCQuickSetting, display: DisplaySnapshot) -> NSView {
        let slider = MacSliderControl(value: Double(setting.defaultValue), minValue: 0, maxValue: 100, target: self, action: #selector(ddcSliderChanged(_:)))
        slider.tag = setting.rawValue
        slider.isEnabled = canUseDDC(display: display)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let value = NSTextField(labelWithString: "--")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 34).isActive = true

        let readButton = PermissionActionButton(title: "读取", target: self, action: #selector(readDDCQuickValue(_:)))
        readButton.tag = setting.rawValue
        readButton.isEnabled = canUseDDC(display: display)

        let stack = NSStackView(views: [slider, value, readButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        ddcSliders[setting] = slider
        ddcValueLabels[setting] = value
        return controlRow(title: setting.title, detail: setting.detail, control: stack)
    }

    private func ddcProbeRow(display: DisplaySnapshot) -> NSView {
        let button = PermissionActionButton(title: "检测 DDC 能力", target: self, action: #selector(probeSelectedDDC))
        button.isEnabled = canUseDDC(display: display)
        return controlRow(title: "DDC 能力检测", detail: "读取亮度 VCP 0x10，不写入显示器；成功后再使用滑块更稳妥。", control: button)
    }

    private func statusRow(_ label: NSTextField) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 38).isActive = true
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func systemBasicInfoSection(snapshot: SystemInfoSnapshot) -> NSView {
        return section(title: "电脑基本信息", rows: [
            systemInfoGridRow(items: [
                ("computerName", "电脑名称", snapshot.computerName),
                ("modelIdentifier", "机型标识", snapshot.modelIdentifier),
                ("cpuBrand", "CPU", snapshot.cpuBrand),
                ("processorCount", "核心", "\(snapshot.activeProcessorCount) 可用 / \(snapshot.processorCount) 总数"),
                ("physicalMemory", "内存", formatBytes(snapshot.physicalMemoryBytes)),
                ("operatingSystem", "macOS", snapshot.operatingSystem),
                ("hostName", "主机名", snapshot.hostName),
                ("uptime", "运行时间", formatUptime(snapshot.uptimeSeconds))
            ])
        ])
    }

    private func systemChartsSection() -> NSView {
        let cpuChart = SystemMetricChartView(title: "CPU 使用率", tintColor: MacAssistantUI.Color.blue)
        let loadChart = SystemMetricChartView(title: "系统负载", tintColor: MacAssistantUI.Color.amber)
        let memoryChart = SystemMetricChartView(title: "内存压力", tintColor: MacAssistantUI.Color.purple)
        let diskChart = SystemMetricChartView(title: "系统磁盘", tintColor: MacAssistantUI.Color.green)
        systemCPUChartView = cpuChart
        systemLoadChartView = loadChart
        systemMemoryChartView = memoryChart
        systemDiskChartView = diskChart

        return section(title: "实时负载", rows: [
            systemChartGridRow(charts: [cpuChart, loadChart, memoryChart, diskChart])
        ])
    }

    private func systemInfoGridRow(items: [(String, String, String)]) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        for pair in items.chunked(into: 2) {
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .top
            line.spacing = 10
            line.translatesAutoresizingMaskIntoConstraints = false
            for item in pair {
                line.addArrangedSubview(systemBasicInfoCard(identifier: item.0, title: item.1, value: item.2))
            }
            grid.addArrangedSubview(line)
        }

        row.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            grid.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14)
        ])
        return row
    }

    private func systemBasicInfoCard(identifier: String, title: String, value: String) -> NSView {
        let card = LayerBackedView(
            backgroundColor: NSColor.white.withAlphaComponent(0.70),
            cornerRadius: 8,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        card.widthAnchor.constraint(equalToConstant: (Layout.rowWidth - 10) / 2).isActive = true
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true

        let titleLabel = MacAssistantUI.caption(title, size: 11)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.maximumNumberOfLines = 2
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        systemBasicInfoValueLabels[identifier] = valueLabel

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])
        return card
    }

    private func systemChartGridRow(charts: [SystemMetricChartView]) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        for pair in charts.chunked(into: 2) {
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .top
            line.spacing = 10
            line.translatesAutoresizingMaskIntoConstraints = false
            for chart in pair {
                line.addArrangedSubview(chart)
            }
            grid.addArrangedSubview(line)
        }

        row.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            grid.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14)
        ])
        return row
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days) 天 \(hours) 小时"
        }
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分钟"
        }
        return "\(minutes) 分钟"
    }

    private func updateSystemOverviewTimer() {
        if selectedSettingsPage == .systemOverview && window?.isVisible == true {
            startSystemOverviewTimer()
        } else {
            stopSystemOverviewTimer()
        }
    }

    private func startSystemOverviewTimer() {
        guard systemOverviewTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshCurrentSystemOverviewSample()
        }
        systemOverviewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSystemOverviewTimer() {
        systemOverviewTimer?.invalidate()
        systemOverviewTimer = nil
    }

    private func refreshCurrentSystemOverviewSample() {
        guard selectedSettingsPage == .systemOverview, window?.isVisible == true else {
            stopSystemOverviewTimer()
            return
        }
        guard !isSystemOverviewSampling else {
            return
        }
        isSystemOverviewSampling = true
        systemOverviewQueue.async { [weak self] in
            let snapshot = SystemInfoProvider.snapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSystemOverviewSampling = false
                guard self.selectedSettingsPage == .systemOverview, self.window?.isVisible == true else {
                    self.stopSystemOverviewTimer()
                    return
                }
                self.applySystemOverviewSnapshot(snapshot)
            }
        }
    }

    private func applySystemOverviewSnapshot(_ snapshot: SystemInfoSnapshot) {
        updateSystemBasicInfoLabels(snapshot)

        let cpuPercent = SystemInfoProvider.cpuUsagePercent(
            previous: previousSystemProcessorTicks,
            current: snapshot.processorTicks
        ) ?? normalizedLoadPercent(snapshot: snapshot)
        previousSystemProcessorTicks = snapshot.processorTicks

        let loadValue = snapshot.loadAverage.first
        let loadPercent = normalizedLoadPercent(snapshot: snapshot)
        let memoryPercent = snapshot.memory.map { Double($0.usedBytes) / Double(max(1, snapshot.physicalMemoryBytes)) * 100 }
        let diskPercent = snapshot.disk.map { Double($0.usedBytes) / Double(max(1, $0.totalBytes)) * 100 }

        systemCPUChartView?.append(
            sample: cpuPercent,
            valueText: formatChartPercent(cpuPercent),
            detailText: "当前 CPU 使用率"
        )
        systemLoadChartView?.append(
            sample: loadPercent,
            valueText: loadValue.map { String(format: "%.2f", $0) } ?? "--",
            detailText: "1 分钟负载 / \(snapshot.activeProcessorCount) 核"
        )
        systemMemoryChartView?.append(
            sample: memoryPercent,
            valueText: formatChartPercent(memoryPercent),
            detailText: snapshot.memory.map { "\(formatBytes($0.usedBytes)) / \(formatBytes(snapshot.physicalMemoryBytes))" } ?? "无法读取内存统计"
        )
        systemDiskChartView?.append(
            sample: diskPercent,
            valueText: formatChartPercent(diskPercent),
            detailText: snapshot.disk.map { "\(formatBytes($0.freeBytes)) 可用" } ?? "无法读取根卷容量"
        )
    }

    private func updateSystemBasicInfoLabels(_ snapshot: SystemInfoSnapshot) {
        systemBasicInfoValueLabels["computerName"]?.stringValue = snapshot.computerName
        systemBasicInfoValueLabels["modelIdentifier"]?.stringValue = snapshot.modelIdentifier
        systemBasicInfoValueLabels["cpuBrand"]?.stringValue = snapshot.cpuBrand
        systemBasicInfoValueLabels["processorCount"]?.stringValue = "\(snapshot.activeProcessorCount) 可用 / \(snapshot.processorCount) 总数"
        systemBasicInfoValueLabels["physicalMemory"]?.stringValue = formatBytes(snapshot.physicalMemoryBytes)
        systemBasicInfoValueLabels["operatingSystem"]?.stringValue = snapshot.operatingSystem
        systemBasicInfoValueLabels["hostName"]?.stringValue = snapshot.hostName
        systemBasicInfoValueLabels["uptime"]?.stringValue = formatUptime(snapshot.uptimeSeconds)
    }

    private func normalizedLoadPercent(snapshot: SystemInfoSnapshot) -> Double? {
        guard let load = snapshot.loadAverage.first else {
            return nil
        }
        let cores = max(1, snapshot.activeProcessorCount)
        return min(100, max(0, load / Double(cores) * 100))
    }

    private func formatChartPercent(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }
        return String(format: "%.0f%%", value)
    }

    private func clipboardSection() -> NSView {
        return section(title: "", rows: [
            switchRow(title: "启用剪贴板历史", detail: "后台记录复制的内容，按格式或纯文本粘贴。", control: clipboardEnabledSwitch),
            switchRow(title: "暂停记录", detail: "保留快捷键和历史面板，但不再记录新复制内容。", control: clipboardPausedSwitch),
            switchRow(title: "排除常见密码管理器", detail: "自动跳过 1Password、Bitwarden、KeePassXC 等应用。", control: clipboardExcludePasswordManagersSwitch),
            controlRow(title: "呼出快捷键", detail: "在任意位置快速调出剪贴板历史面板。", control: shortcutControl(enabledSwitch: clipboardHotKeyEnabledSwitch, recorder: hotKeyRecorder)),
            controlRow(title: "监听间隔", detail: "剪贴板变更检测频率，数值越小越及时，也会更频繁唤醒应用。", control: millisecondsControl(clipboardPollIntervalControl)),
            controlRow(title: "最多保留条数", detail: "范围 10 到 10000 条。", control: maxHistoryControl()),
            controlRow(title: "自动清理天数", detail: "默认 30 天；收藏记录会保留。", control: daysControl(clipboardRetentionDaysControl)),
            controlRow(title: "结构化预览上限", detail: "JSON、Markdown、CSV/TSV、代码等超过该大小时直接显示原始文本，避免预览卡顿。", control: kilobytesControl(clipboardStructuredPreviewLimitControl)),
            controlRow(title: "排除 App", detail: "输入 Bundle ID，多个用逗号或换行分隔；浏览器隐私窗口无法稳定识别，建议排除整个浏览器。", control: excludedAppsControl()),
            settingsActionRow(
                title: "加密存储",
                detail: "\(clipboardController.encryptionStatus) · \(formatBytes(UInt64(max(0, clipboardController.storageSize))))",
                buttons: [
                    settingsActionButton(title: "重试访问", symbolName: "key", action: .retryClipboardKey),
                    settingsActionButton(title: "清空历史", symbolName: "trash", action: .clearUndecryptableClipboard)
                ]
            ),
            hintRow("数据位置：\(clipboardController.dataLocation)"),
            hintRow("默认按格式粘贴；在历史记录中右键可以选择按格式或原文本粘贴。", compact: true)
        ])
    }

    private func clipboardShortcutSection() -> NSView {
        let rows = ClipboardShortcut.allCases.map { shortcut in
            controlRow(
                title: shortcut.title,
                detail: shortcut.detail,
                control: shortcutControl(
                    enabledSwitch: clipboardShortcutSwitches[shortcut] ?? MacSwitchControl(),
                    recorder: clipboardShortcutRecorders[shortcut] ?? HotKeyRecorderView(hotKey: shortcut.defaultBinding.hotKey)
                )
            )
        }
        return section(title: "剪贴板面板快捷键", rows: rows)
    }

    private func configManagementSection() -> NSView {
        return section(title: "配置", rows: [
            settingsActionRow(
                title: "配置导入导出",
                detail: "导出当前配置为 JSON，或从已有 JSON 配置恢复显示器、剪贴板、压缩和右键菜单设置。",
                buttons: [
                    settingsActionButton(title: "导出", symbolName: "square.and.arrow.up", action: .exportConfig),
                    settingsActionButton(title: "导入", symbolName: "square.and.arrow.down", action: .importConfig)
                ]
            ),
            hintRow("当前配置文件：\(AppPaths.configURL.path)")
        ])
    }

    private func versionSection() -> NSView {
        return section(title: "版本", rows: [
            settingsActionRow(
                title: "当前版本",
                detail: currentVersionText(),
                buttons: [
                    settingsActionButton(title: "检测更新", symbolName: "arrow.clockwise", action: .checkForUpdates)
                ]
            )
        ])
    }

    private func currentVersionText() -> String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        return "Mac助手 \(version) (\(build))"
    }

    private func iCloudSettingsSection() -> NSView {
        return section(title: "iCloud", rows: [
            settingsActionRow(
                title: "iCloud 配置备份",
                detail: "备份包含版本和时间戳，不包含剪贴板密钥、历史内容或 Finder 桥接密钥。",
                buttons: [
                    settingsActionButton(title: "备份到 iCloud", symbolName: "icloud.and.arrow.up", action: .iCloudBackup),
                    settingsActionButton(title: "从 iCloud 恢复", symbolName: "icloud.and.arrow.down", action: .iCloudSync)
                ]
            ),
            hintRow(iCloudBackupStatusText())
        ])
    }

    private func permissionsSection() -> NSView {
        let accessibilityGranted = AXIsProcessTrusted()
        return section(title: "权限管理", rows: [
            permissionRow(
                symbolName: "accessibility",
                accentColor: MacAssistantUI.Color.blue,
                title: "辅助功能",
                detail: "受影响：剪贴板双击粘贴、快捷键粘贴、自动向当前应用发送粘贴快捷键。",
                statusTitle: accessibilityGranted ? "已授权" : "未授权",
                statusKind: accessibilityGranted ? .granted : .needed,
                buttonTitle: accessibilityGranted ? "打开设置" : "引导授权",
                action: .accessibility
            ),
            permissionRow(
                symbolName: "gearshape.2",
                accentColor: MacAssistantUI.Color.amber,
                title: "自动化",
                detail: "受影响：后续 Finder 或系统应用联动动作；macOS 会按目标应用逐项确认。",
                statusTitle: "系统确认",
                statusKind: .manual,
                buttonTitle: "打开设置",
                action: .automation
            ),
            permissionRow(
                symbolName: "folder",
                accentColor: MacAssistantUI.Color.purple,
                title: "Finder 扩展",
                detail: "受影响：Finder 右键菜单、压缩/解压、复制路径、新建文件等入口显示。",
                statusTitle: finderExtensionStatusTitle(),
                statusKind: finderExtensionStatusKind(),
                buttonTitle: "打开扩展",
                action: .finderExtension
            ),
            finderExtensionTestRow(),
            permissionRow(
                symbolName: "externaldrive",
                accentColor: MacAssistantUI.Color.green,
                title: "完全磁盘访问",
                detail: "受影响：双击打开桌面、文稿、下载、外置磁盘中的压缩包时，减少反复确认文件夹访问。",
                statusTitle: "需手动开启",
                statusKind: .manual,
                buttonTitle: "引导授权",
                action: .fullDiskAccess
            ),
            permissionRefreshRow()
        ])
    }

    private func permissionHintSection() -> NSView {
        return section(title: "", rows: [
            hintRow("点击“引导授权”会打开对应系统设置页；辅助功能和完全磁盘访问会显示可拖拽的 Mac助手 面板。授权后回到此页点击“重新检测”。")
        ])
    }

    private func diagnosticsSection() -> NSView {
        return section(title: "诊断", rows: [
            diagnosticsCopyRow(),
            hintRow("诊断信息会复制应用状态、配置路径、权限状态、显示器摘要和最近日志摘要，方便反馈问题。", compact: true)
        ])
    }

    private func contextMenuGeneralSection() -> NSView {
        return section(title: "", rows: [
            switchRow(title: "启用自定义右键菜单", detail: "在 Finder 空白处或文件上右键，显示增强功能。", control: contextMenuEnabledSwitch),
            hintRow("菜单配置会保存到本地配置文件；Finder 右键入口需要后续 Finder Sync 扩展或快捷指令调用当前应用的动作入口。")
        ])
    }

    private func archiveOptionsSection() -> NSView {
        archiveStripMacMetadataSwitch.state = store.archive.stripMacMetadataWhenCompressing ? .on : .off
        archiveStripMacMetadataSwitch.target = self
        archiveStripMacMetadataSwitch.action = #selector(controlChanged(_:))
        archiveDefaultOpenerSwitch.state = store.archive.registerAsDefaultArchiveOpener ? .on : .off
        archiveDefaultOpenerSwitch.target = self
        archiveDefaultOpenerSwitch.action = #selector(controlChanged(_:))
        archiveAutoCloseExtractionProgressSwitch.state = store.archive.autoCloseProgressWindowAfterExtraction ? .on : .off
        archiveAutoCloseExtractionProgressSwitch.target = self
        archiveAutoCloseExtractionProgressSwitch.action = #selector(controlChanged(_:))
        archiveCompressionLevelControl.value = ArchiveConfig.normalizedCompressionLevel(store.archive.defaultCompressionLevel)
        return section(title: "压缩/解压选项", rows: [
            switchRow(
                title: "压缩时自动去除 .DS_Store",
                detail: "创建压缩包时跳过 Finder 生成的 .DS_Store，并排除常见 macOS 元数据文件。",
                control: archiveStripMacMetadataSwitch
            ),
            switchRow(
                title: "解压完成后自动关闭弹窗",
                detail: "解压成功后短暂停留完成状态，然后自动收起进度弹窗。",
                control: archiveAutoCloseExtractionProgressSwitch
            ),
            switchRow(
                title: "设为压缩包默认打开方式",
                detail: "关闭后不会继续接管 ZIP、7Z、RAR 等文件；已被系统记录的默认应用需在 Finder 显示简介中改回。",
                control: archiveDefaultOpenerSwitch
            ),
            controlRow(
                title: "默认压缩等级",
                detail: "自定义压缩默认使用的等级，范围 0 到 9；0 更快，9 压缩率更高。",
                control: archiveCompressionLevelControl
            ),
            archiveDependencySummaryRow()
        ])
    }

    private func archiveFormatsSection() -> NSView {
        let rows = ArchiveFormat.allCases.map { archiveFormatRow(format: $0) }
        return section(title: "支持格式", rows: rows)
    }

    private func archiveFormatRow(format: ArchiveFormat) -> NSView {
        let control = MacSwitchControl()
        control.state = store.archive.supports(format) ? .on : .off
        control.target = self
        control.action = #selector(controlChanged(_:))
        archiveFormatSwitches[format] = control
        return controlRow(title: format.title, detail: format.detail, control: control)
    }

    private func archiveContextMenuSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(contextMenuHeaderRow())

        let config = store.contextMenu.normalized()
        guard let archiveItem = config.items.first(where: { $0.id == .archive }) else {
            return section(title: "右键菜单", rows: [hintRow("压缩/解压右键菜单配置缺失，重新打开设置后会自动补齐。")])
        }

        stack.addArrangedSubview(contextMenuRow(
            item: archiveItem,
            level: 0,
            parentEnabled: config.enabled,
            isFirst: true,
            isLast: true
        ))
        for (childIndex, child) in archiveItem.children.enumerated() {
            stack.addArrangedSubview(contextMenuRow(
                item: child,
                level: 1,
                parentEnabled: config.enabled && archiveItem.enabled,
                isFirst: childIndex == 0,
                isLast: childIndex == archiveItem.children.count - 1
            ))
        }

        return section(title: "右键菜单", rows: [
            hintRow("这些选项只在 Finder 选中文件或文件夹时显示；智能解压还会按上方格式开关过滤。", compact: true),
            stack
        ])
    }

    private func contextMenuItemsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = contextMenuHeaderRow()
        stack.addArrangedSubview(header)

        let config = store.contextMenu.normalized()
        let visibleItems = config.items.filter { $0.id != .archive }
        for (index, item) in visibleItems.enumerated() {
            stack.addArrangedSubview(contextMenuRow(
                item: item,
                level: 0,
                parentEnabled: config.enabled,
                isFirst: index == 0,
                isLast: index == visibleItems.count - 1
            ))
            for (childIndex, child) in item.children.enumerated() {
                stack.addArrangedSubview(contextMenuRow(
                    item: child,
                    level: 1,
                    parentEnabled: config.enabled && item.enabled,
                    isFirst: childIndex == 0,
                    isLast: childIndex == item.children.count - 1
                ))
            }
        }

        return section(title: "菜单项", rows: [stack])
    }

    private func contextMenuHeaderRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let name = headerLabel("菜单名称")
        let order = headerLabel("顺序")
        let enabled = headerLabel("启用")
        row.addSubview(name)
        row.addSubview(order)
        row.addSubview(enabled)

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            order.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -74),
            order.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            enabled.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            enabled.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func headerLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func contextMenuRow(item: ContextMenuItemConfig, level: Int, parentEnabled: Bool, isFirst: Bool, isLast: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let icon = NSImageView()
        icon.image = MacAssistantUI.symbol(item.id.symbolName, pointSize: level == 0 ? 15 : 14, weight: .regular)
        icon.contentTintColor = level == 0 ? .systemBlue : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.id.title)
        title.font = .systemFont(ofSize: 13, weight: level == 0 ? .semibold : .regular)
        title.textColor = parentEnabled ? .labelColor : .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let upButton = ContextMenuActionButton(
            symbolName: "chevron.up",
            itemID: item.id,
            actionKind: .moveUp,
            target: self,
            action: #selector(contextMenuActionButtonPressed(_:))
        )
        upButton.isEnabled = parentEnabled && !isFirst

        let downButton = ContextMenuActionButton(
            symbolName: "chevron.down",
            itemID: item.id,
            actionKind: .moveDown,
            target: self,
            action: #selector(contextMenuActionButtonPressed(_:))
        )
        downButton.isEnabled = parentEnabled && !isLast

        let enabledSwitch = ContextMenuToggleButton(
            itemID: item.id,
            actionKind: .toggle,
            target: self,
            action: #selector(contextMenuActionButtonPressed(_:))
        )
        enabledSwitch.state = item.enabled ? .on : .off
        enabledSwitch.isEnabled = parentEnabled

        row.addSubview(icon)
        row.addSubview(title)
        row.addSubview(upButton)
        row.addSubview(downButton)
        row.addSubview(enabledSwitch)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: CGFloat(level) * 24),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: upButton.leadingAnchor, constant: -16),

            upButton.trailingAnchor.constraint(equalTo: downButton.leadingAnchor, constant: -8),
            upButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            upButton.widthAnchor.constraint(equalToConstant: 24),
            upButton.heightAnchor.constraint(equalToConstant: 24),

            downButton.trailingAnchor.constraint(equalTo: enabledSwitch.leadingAnchor, constant: -38),
            downButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            downButton.widthAnchor.constraint(equalToConstant: 24),
            downButton.heightAnchor.constraint(equalToConstant: 24),

            enabledSwitch.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            enabledSwitch.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            enabledSwitch.widthAnchor.constraint(equalToConstant: 16),
            enabledSwitch.heightAnchor.constraint(equalToConstant: 16)
        ])
        return row
    }

    private func permissionRow(
        symbolName: String,
        accentColor: NSColor,
        title: String,
        detail: String,
        statusTitle: String,
        statusKind: PermissionStatusPill.Kind,
        buttonTitle: String,
        action: PermissionAction
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 94).isActive = true

        let iconWrap = LayerBackedView(
            backgroundColor: accentColor.withAlphaComponent(0.13),
            cornerRadius: 8
        )
        iconWrap.widthAnchor.constraint(equalToConstant: 34).isActive = true
        iconWrap.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let icon = NSImageView()
        icon.image = MacAssistantUI.symbol(symbolName, pointSize: 16, weight: .semibold)
        icon.contentTintColor = accentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = MacAssistantUI.caption(detail, size: 12)
        detailLabel.maximumNumberOfLines = 3
        detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let status = PermissionStatusPill(title: statusTitle, kind: statusKind)
        let button = PermissionActionButton(title: buttonTitle, target: self, action: #selector(permissionActionPressed(_:)))
        button.tag = action.rawValue

        let rightStack = NSStackView(views: [status, button])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(iconWrap)
        row.addSubview(textStack)
        row.addSubview(rightStack)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconWrap.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            iconWrap.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconWrap.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: iconWrap.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -16),

            rightStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            rightStack.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func diagnosticsCopyRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let label = MacAssistantUI.caption("一键复制当前诊断信息，用于定位权限、显示器和配置问题。", size: 12)
        let copyButton = PermissionActionButton(title: "复制", target: self, action: #selector(permissionActionPressed(_:)))
        copyButton.tag = PermissionAction.copyDiagnostics.rawValue
        let exportButton = PermissionActionButton(title: "导出文件", target: self, action: #selector(permissionActionPressed(_:)))
        exportButton.tag = PermissionAction.exportDiagnostics.rawValue
        let buttons = NSStackView(views: [copyButton, exportButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(label)
        row.addSubview(buttons)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func displayRecoveryFallbackRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 74).isActive = true

        let label = MacAssistantUI.caption("备份并清除 WindowServer 显示布局缓存，然后重启图形服务。需要管理员授权，屏幕会短暂中断。", size: 12)
        label.maximumNumberOfLines = 2
        let button = PermissionActionButton(title: "兜底恢复显示器", target: self, action: #selector(permissionActionPressed(_:)))
        button.tag = PermissionAction.displayRecovery.rawValue

        row.addSubview(label)
        row.addSubview(button)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func displayTestCloseRow(display: DisplaySnapshot) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let label = MacAssistantUI.caption("短暂关闭当前显示器，10 秒后自动恢复，用于确认设备兼容性。", size: 12)
        let button = PermissionActionButton(title: "测试关闭 10 秒", target: self, action: #selector(testCloseSelectedDisplay))
        button.isEnabled = display.isActive && display.runtimeDisplayID != 0

        row.addSubview(label)
        row.addSubview(button)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func permissionRefreshRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let label = MacAssistantUI.caption("完成系统授权后，回到这里重新检测权限状态。", size: 12)
        let button = PermissionActionButton(title: "重新检测", target: self, action: #selector(permissionActionPressed(_:)))
        button.tag = PermissionAction.refresh.rawValue

        row.addSubview(label)
        row.addSubview(button)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func finderExtensionTestRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let label = MacAssistantUI.caption("打开下载目录后，在 Finder 空白处或文件上右键，确认能看到 Mac助手菜单项。", size: 12)
        let button = PermissionActionButton(title: "打开测试目录", target: self, action: #selector(permissionActionPressed(_:)))
        button.tag = PermissionAction.finderExtensionTest.rawValue

        row.addSubview(label)
        row.addSubview(button)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func maxHistoryControl() -> NSView {
        let unit = NSTextField(labelWithString: "条")
        unit.font = .systemFont(ofSize: 13)
        unit.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [maxHistoryCountControl, unit])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func daysControl(_ control: MacNumberControl) -> NSView {
        let unit = NSTextField(labelWithString: "天")
        unit.font = .systemFont(ofSize: 13)
        unit.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [control, unit])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func kilobytesControl(_ control: MacNumberControl) -> NSView {
        let unit = NSTextField(labelWithString: "KB")
        unit.font = .systemFont(ofSize: 13)
        unit.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [control, unit])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func millisecondsControl(_ control: MacNumberControl) -> NSView {
        let unit = NSTextField(labelWithString: "毫秒")
        unit.font = .systemFont(ofSize: 13)
        unit.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [control, unit])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func secondsControl(_ control: MacNumberControl) -> NSView {
        let unit = NSTextField(labelWithString: "秒")
        unit.font = .systemFont(ofSize: 13)
        unit.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [control, unit])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func excludedAppsControl() -> NSView {
        clipboardExcludedAppsField.translatesAutoresizingMaskIntoConstraints = false
        clipboardExcludedAppsField.widthAnchor.constraint(equalToConstant: 268).isActive = true
        return clipboardExcludedAppsField
    }

    private func shortcutControl(enabledSwitch: MacSwitchControl, recorder: HotKeyRecorderView) -> NSView {
        let stack = NSStackView(views: [enabledSwitch, recorder])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func recoveryStatusRow(display: DisplaySnapshot) -> NSView {
        let message: String
        if let (_, profile) = selectedDisplayAndProfile(),
           let remaining = recovery.remainingSeconds(profileId: profile.id) {
            message = "自动恢复倒计时：\(remaining) 秒。"
        } else if !display.isActive {
            message = "当前显示器已关闭；如未开启自动恢复，需要手动关闭开关恢复。"
        } else {
            message = "测试关闭会短暂关闭当前显示器并自动恢复，适合先确认设备兼容性。"
        }
        return statusRow(MacAssistantUI.caption(message, size: 12))
    }

    private func archiveDependencySummaryRow() -> NSView {
        let tools = [
            ("ZIP", ["zip", "unzip"]),
            ("TAR", ["tar"]),
            ("XZ", ["xz", "unxz"]),
            ("7Z/RAR 读取", ["7zz", "7z"]),
            ("RAR 写入", ["rar"])
        ]

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = MacAssistantUI.title("命令行工具状态", size: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)

        for tool in tools {
            stack.addArrangedSubview(archiveDependencyStatusLine(title: tool.0, names: tool.1))
        }

        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12)
        ])
        return row
    }

    private func archiveDependencyStatusLine(title: String, names: [String]) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: 84).isActive = true

        let executableURL = SystemCapabilities.firstAvailableTool(names)
        let status = PermissionStatusPill(
            title: executableURL == nil ? "未找到" : "已安装",
            kind: executableURL == nil ? .needed : .granted
        )

        let detailText = executableURL?.path ?? "搜索 /usr/bin、/bin、/usr/local/bin、/opt/homebrew/bin"
        let detailLabel = MacAssistantUI.caption(detailText, size: 11)
        detailLabel.maximumNumberOfLines = 2
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addSubview(titleLabel)
        row.addSubview(status)
        row.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
            status.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            status.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            detailLabel.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 10),
            detailLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
            detailLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    private func section(title: String, rows: [NSView]) -> NSView {
        let box = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: 8,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        box.widthAnchor.constraint(equalToConstant: Layout.contentWidth).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: title.isEmpty ? 0 : 12, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        if !title.isEmpty {
            let label = MacAssistantUI.title(title, size: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
            stack.addArrangedSubview(label)
        }

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = MacAssistantUI.separator()
                separator.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
                stack.addArrangedSubview(separator)
            }
            stack.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        return box
    }

    private func switchRow(title: String, detail: String? = nil, control: MacSwitchControl) -> NSView {
        control.target = self
        control.action = #selector(controlChanged(_:))
        return controlRow(title: title, detail: detail, control: control)
    }

    private func popupRow(title: String, popup: MacSelectControl) -> NSView {
        popup.target = self
        popup.action = #selector(controlChanged(_:))
        return controlRow(title: title, detail: nil, control: popup)
    }

    private func hintRow(_ text: String, compact: Bool = false) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: compact ? 36 : 52).isActive = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = compact ? 1 : 2
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func settingsActionButton(title: String, symbolName: String, action: GeneralSettingsAction) -> MacTextButton {
        let button = MacTextButton(title: title, symbolName: symbolName, role: .primary)
        button.target = self
        button.action = #selector(generalSettingsActionPressed(_:))
        button.tag = action.rawValue
        return button
    }

    private func settingsActionRow(title: String, detail: String, buttons: [MacTextButton]) -> NSView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return controlRow(title: title, detail: detail, control: stack)
    }

    private func controlRow(title: String, detail: String? = nil, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: detail == nil ? 52 : 74).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        if let accessibleControl = control as? NSControl {
            accessibleControl.setAccessibilityLabel(title)
            if let detail {
                accessibleControl.setAccessibilityHelp(detail)
            }
        }

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(label)
        if let detail {
            let detailLabel = MacAssistantUI.caption(detail, size: 12)
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
            textStack.addArrangedSubview(detailLabel)
        }

        row.addSubview(textStack)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -18)
        ])
        return row
    }

    private func loadControls(profile: DisplayProfile, display: DisplaySnapshot) {
        closeDisplaySwitch.state = display.isActive ? .off : .on
        closeDisplaySwitch.isEnabled = display.runtimeDisplayID != 0 && disconnect.backendAvailability.available
        if let reason = disconnect.backendAvailability.reason, !disconnect.backendAvailability.available {
            closeDisplaySwitch.setAccessibilityHelp(reason)
        }
        displayAutoReconnectSwitch.state = profile.disconnect.autoReconnect ? .on : .off
        displayReconnectDelayControl.value = max(5, profile.disconnect.autoReconnectDelaySeconds)
        displayConfirmCloseSwitch.state = profile.disconnect.confirmBeforeDisconnect ? .on : .off
    }

    private func loadClipboardControls() {
        clipboardEnabledSwitch.state = store.clipboard.enabled ? .on : .off
        clipboardPausedSwitch.state = store.clipboard.recordingPaused ? .on : .off
        clipboardExcludePasswordManagersSwitch.state = store.clipboard.excludeKnownPasswordManagers ? .on : .off
        clipboardHotKeyEnabledSwitch.state = store.clipboard.hotKeyEnabled ? .on : .off
        hotKeyRecorder.setHotKey(store.clipboard.hotKey)
        hotKeyRecorder.isRecorderEnabled = store.clipboard.hotKeyEnabled
        for shortcut in ClipboardShortcut.allCases {
            let binding = store.clipboard.shortcuts.binding(for: shortcut)
            clipboardShortcutSwitches[shortcut]?.state = binding.enabled ? .on : .off
            clipboardShortcutRecorders[shortcut]?.setHotKey(binding.hotKey)
            clipboardShortcutRecorders[shortcut]?.isRecorderEnabled = binding.enabled
        }
        maxHistoryCountControl.value = store.clipboard.maxHistoryCount
        clipboardRetentionDaysControl.value = store.clipboard.retentionDays
        clipboardPollIntervalControl.value = store.clipboard.pollIntervalMilliseconds
        clipboardStructuredPreviewLimitControl.value = store.clipboard.structuredPreviewLimitKB
        clipboardExcludedAppsField.text = store.clipboard.excludedBundleIdentifiers.joined(separator: ", ")
    }

    private func loadContextMenuControls() {
        contextMenuEnabledSwitch.state = store.contextMenu.enabled ? .on : .off
    }

    @discardableResult
    private func saveSelectedProfile(reload: Bool = true) -> DisplayProfile? {
        guard !isReloadingUI, scannedDisplays.indices.contains(selectedDisplayIndex) else {
            return nil
        }
        let display = scannedDisplays[selectedDisplayIndex]
        let existing = existingProfile(for: display) ?? makeProfile(for: display)
        let closeEnabled = closeDisplaySwitch.state == .on
        var colorLock = existing.colorLock
        colorLock.enabled = false

        let updated = DisplayProfile(
            id: existing.id,
            enabled: closeEnabled,
            name: suggestedProfileName(for: display),
            matchMode: .strict,
            match: matchRule(for: display),
            colorLock: colorLock,
            disconnect: DisconnectConfig(
                enabled: closeEnabled,
                allowSoftDisconnect: closeEnabled,
                autoReconnect: displayAutoReconnectSwitch.state == .on,
                autoReconnectDelaySeconds: displayReconnectDelayControl.value,
                externalOnly: true,
                confirmBeforeDisconnect: displayConfirmCloseSwitch.state == .on
            ),
            automationEnabled: false
        )

        if let index = profiles.firstIndex(where: { $0.id == updated.id }) {
            profiles[index] = updated
        } else {
            profiles.append(updated)
        }
        store.profiles = profiles
        onSave()
        if reload {
            reloadSelectedDisplay()
        }
        return updated
    }

    private func setCloseSwitch(_ isOn: Bool) {
        isReloadingUI = true
        closeDisplaySwitch.state = isOn ? .on : .off
        isReloadingUI = false
    }

    private func saveClipboardConfig(hotKey: HotKeyConfig? = nil) {
        var config = store.clipboard
        config.enabled = clipboardEnabledSwitch.state == .on
        config.hotKeyEnabled = clipboardHotKeyEnabledSwitch.state == .on
        config.recordingPaused = clipboardPausedSwitch.state == .on
        config.excludeKnownPasswordManagers = clipboardExcludePasswordManagersSwitch.state == .on
        config.retentionDays = clipboardRetentionDaysControl.value
        config.pollIntervalMilliseconds = ClipboardConfig.normalizedPollIntervalMilliseconds(clipboardPollIntervalControl.value)
        config.structuredPreviewLimitKB = ClipboardConfig.normalizedStructuredPreviewLimitKB(clipboardStructuredPreviewLimitControl.value)
        config.excludedBundleIdentifiers = parsedExcludedBundleIdentifiers()
        config.maxHistoryCount = normalizedMaxHistoryCount()
        if let hotKey {
            config.hotKey = hotKey
        }
        store.clipboard = config
        onSave()
    }

    private func saveClipboardShortcut(_ shortcut: ClipboardShortcut, hotKey: HotKeyConfig? = nil, enabled: Bool? = nil) {
        var config = store.clipboard
        var binding = config.shortcuts.binding(for: shortcut)
        if let hotKey {
            binding.hotKey = hotKey
        }
        if let enabled {
            binding.enabled = enabled
        }
        config.shortcuts.setBinding(binding, for: shortcut)
        store.clipboard = config
        clipboardShortcutRecorders[shortcut]?.isRecorderEnabled = binding.enabled
        onSave()
    }

    private func saveArchiveFormat(_ format: ArchiveFormat, enabled: Bool) {
        var config = store.archive
        if enabled {
            config.enabledFormats.insert(format)
        } else {
            config.enabledFormats.remove(format)
        }
        store.archive = config
        onSave()
    }

    private func saveArchiveOptions() {
        var config = store.archive
        config.stripMacMetadataWhenCompressing = archiveStripMacMetadataSwitch.state == .on
        config.defaultCompressionLevel = ArchiveConfig.normalizedCompressionLevel(archiveCompressionLevelControl.value)
        config.registerAsDefaultArchiveOpener = archiveDefaultOpenerSwitch.state == .on
        config.autoCloseProgressWindowAfterExtraction = archiveAutoCloseExtractionProgressSwitch.state == .on
        store.archive = config
        if config.registerAsDefaultArchiveOpener {
            registerArchiveDocumentHandlers()
        }
        onSave()
    }

    private func registerArchiveDocumentHandlers() {
        SystemCapabilities.registerArchiveDocumentHandlers()
    }

    private func parsedExcludedBundleIdentifiers() -> [String] {
        clipboardExcludedAppsField.text
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func saveContextMenuEnabled() {
        var config = store.contextMenu.normalized()
        config.enabled = contextMenuEnabledSwitch.state == .on
        store.contextMenu = config
        onSave()
        reloadContextMenuSettings()
    }

    private func updateContextMenuItem(_ itemID: ContextMenuItemID, update: (inout ContextMenuItemConfig) -> Void) {
        var config = store.contextMenu.normalized()
        _ = Self.updateContextMenuItem(itemID, items: &config.items, update: update)
        store.contextMenu = config
        onSave()
        reloadContextMenuSettings()
    }

    private func moveContextMenuItem(_ itemID: ContextMenuItemID, direction: ContextMenuMoveDirection) {
        var config = store.contextMenu.normalized()
        _ = Self.moveContextMenuItem(itemID, items: &config.items, direction: direction)
        store.contextMenu = config
        onSave()
        reloadContextMenuSettings()
    }

    private static func updateContextMenuItem(_ itemID: ContextMenuItemID, items: inout [ContextMenuItemConfig], update: (inout ContextMenuItemConfig) -> Void) -> Bool {
        for index in items.indices {
            if items[index].id == itemID {
                update(&items[index])
                return true
            }
            if updateContextMenuItem(itemID, items: &items[index].children, update: update) {
                return true
            }
        }
        return false
    }

    private static func moveContextMenuItem(_ itemID: ContextMenuItemID, items: inout [ContextMenuItemConfig], direction: ContextMenuMoveDirection) -> Bool {
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            switch direction {
            case .up where index > items.startIndex:
                items.swapAt(index, items.index(before: index))
            case .down where index < items.index(before: items.endIndex):
                items.swapAt(index, items.index(after: index))
            default:
                break
            }
            return true
        }

        for index in items.indices {
            if moveContextMenuItem(itemID, items: &items[index].children, direction: direction) {
                return true
            }
        }
        return false
    }

    private func normalizedMaxHistoryCount() -> Int {
        let value = maxHistoryCountControl.value
        return min(10000, max(10, value))
    }

    private func handleCloseDisplayChanged() {
        guard scannedDisplays.indices.contains(selectedDisplayIndex) else {
            return
        }

        let selectedDisplay = scannedDisplays[selectedDisplayIndex]

        guard let profile = saveSelectedProfile(reload: false) else {
            return
        }

        if closeDisplaySwitch.state == .on {
            if profile.disconnect.confirmBeforeDisconnect,
               !confirmCloseDisplay(profile: profile, display: selectedDisplay) {
                setCloseSwitch(false)
                _ = saveSelectedProfile(reload: false)
                reloadSelectedDisplay()
                return
            }
            do {
                let display = try disconnect.disconnect(profile: profile, allProfiles: profiles) { [weak self] display in
                    self?.store.addPendingReconnect(PendingReconnect(
                        profileId: profile.id,
                        displaySnapshot: display,
                        reason: "user_requested_disconnect",
                        autoReconnect: profile.disconnect.autoReconnect
                    ))
                }
                store.rememberDisplays([display])
                if profile.disconnect.autoReconnect {
                    recovery.beginCountdown(profile: profile, display: display)
                } else {
                    statuses.set(.disconnected, profileId: profile.id, message: "已断开")
                }
            } catch {
                store.clearPendingReconnect(profileId: profile.id)
                statuses.set(.disconnecting, profileId: profile.id, message: error.localizedDescription)
                AppLogger.shared.error("\(profile.name) 关闭显示器失败：\(error.localizedDescription)")
                showAlert(title: "无法关闭显示器", message: error.localizedDescription)
                setCloseSwitch(false)
                if !shouldPreserveDesiredClose(after: error) {
                    _ = saveSelectedProfile(reload: false)
                }
            }
        } else {
            recovery.cancelCountdown(profileId: profile.id)
            do {
                try disconnect.reconnect(profile: profile, fallbackDisplay: selectedDisplay)
                statuses.set(.detected, profileId: profile.id, message: "已打开")
            } catch {
                statuses.set(.reconnectFailed, profileId: profile.id, message: error.localizedDescription)
                AppLogger.shared.error("\(profile.name) 打开显示器失败：\(error.localizedDescription)")
                showAlert(title: "无法打开显示器", message: error.localizedDescription)
            }
        }

        onSave()
        refreshDisplaysAfterStateChange()
    }

    private func confirmCloseDisplay(profile: DisplayProfile, display: DisplaySnapshot) -> Bool {
        let alert = NSAlert()
        alert.messageText = "关闭 \(suggestedProfileName(for: display))？"
        let recoveryText = profile.disconnect.autoReconnect
            ? "会在 \(profile.disconnect.autoReconnectDelaySeconds) 秒后自动尝试恢复。"
            : "未开启自动恢复，需要手动重新打开。"
        alert.informativeText = "屏幕可能会短暂黑屏。Mac助手会检查至少保留一台可用显示器；\(recoveryText)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "关闭显示器")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func testCloseSelectedDisplay() {
        guard let (display, profile) = selectedDisplayAndProfile() else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "测试关闭 \(suggestedProfileName(for: display))？"
        alert.informativeText = "会短暂关闭当前显示器，并在 10 秒后自动尝试恢复。请确认还有其他可用显示器。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "开始测试")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let testProfile = DisplayProfile(
            id: profile.id,
            enabled: true,
            name: profile.name,
            matchMode: profile.matchMode,
            match: profile.match,
            colorLock: profile.colorLock,
            disconnect: DisconnectConfig(
                enabled: true,
                allowSoftDisconnect: true,
                autoReconnect: true,
                autoReconnectDelaySeconds: 10,
                externalOnly: false,
                confirmBeforeDisconnect: false
            ),
            automationEnabled: false
        )

        do {
            let closedDisplay = try disconnect.disconnect(profile: testProfile, allProfiles: profiles)
            statuses.set(.reconnectCountdown, profileId: testProfile.id, message: "测试关闭，10 秒后恢复")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self else { return }
                do {
                    try self.disconnect.reconnect(profile: testProfile, fallbackDisplay: closedDisplay)
                    self.statuses.set(.detected, profileId: testProfile.id, message: "测试恢复完成")
                    self.refreshDisplaysAfterStateChange()
                } catch {
                    self.statuses.set(.reconnectFailed, profileId: testProfile.id, message: error.localizedDescription)
                    self.showAlert(title: "测试恢复失败", message: error.localizedDescription)
                    self.refreshDisplaysAfterStateChange()
                }
            }
            refreshDisplaysAfterStateChange()
        } catch {
            showAlert(title: "无法测试关闭显示器", message: error.localizedDescription)
            refreshDisplaysAfterStateChange()
        }
    }

    private func shouldPreserveDesiredClose(after error: Error) -> Bool {
        guard let disconnectError = error as? SoftDisconnectError else {
            return false
        }
        switch disconnectError {
        case .notEnoughActiveDisplays, .allDisplaysWouldBeClosed:
            return true
        default:
            return false
        }
    }

    private func existingProfile(for display: DisplaySnapshot) -> DisplayProfile? {
        profiles.first { detector.matchScore(display: display, profile: $0).matches }
    }

    private func makeProfile(for display: DisplaySnapshot) -> DisplayProfile {
        DisplayProfile(
            id: profileId(for: display),
            enabled: false,
            name: suggestedProfileName(for: display),
            matchMode: .strict,
            match: matchRule(for: display),
            colorLock: .p3Default,
            disconnect: DisconnectConfig.defaultValue.disabled(),
            automationEnabled: false
        )
    }

    private func matchRule(for display: DisplaySnapshot) -> DisplayMatchRule {
        DisplayMatchRule(
            displayName: display.displayName,
            edidUUID: display.edidUUID,
            vendorId: display.vendorId,
            modelId: display.modelId,
            serialNumber: display.serialNumber == "0" ? "" : display.serialNumber,
            manufacturer: display.manufacturer,
            alphanumericSerial: display.alphanumericSerial,
            ioLocation: display.ioLocation,
            matchThreshold: 80
        )
    }

    private func profileId(for display: DisplaySnapshot) -> String {
        let raw: String
        if !display.edidUUID.isEmpty {
            raw = display.edidUUID
        } else if !display.alphanumericSerial.isEmpty {
            raw = display.alphanumericSerial
        } else if display.serialNumber != "0", !display.vendorId.isEmpty, !display.modelId.isEmpty, !display.serialNumber.isEmpty {
            raw = "\(display.vendorId)-\(display.modelId)-\(display.serialNumber)"
        } else if !display.ioLocation.isEmpty {
            raw = display.ioLocation
        } else {
            raw = "\(display.displayName)-\(display.isBuiltIn ? "built-in" : "external")"
        }
        let safe = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return "display-\(String(safe))"
    }

    private func suggestedProfileName(for display: DisplaySnapshot) -> String {
        if display.isBuiltIn {
            return "MacBook 内置显示器"
        }
        return display.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "外接显示器" : display.displayName
    }

    private func normalizedDetail(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "--" : trimmed
    }

    private func runtimeStatusText(profile: DisplayProfile, display: DisplaySnapshot) -> String {
        let wantsClosed = disconnect.desiredCloseEnabled(profile: profile)
        if !display.isActive {
            return wantsClosed ? "已按设置关闭" : "已关闭/离线"
        }
        if wantsClosed && !disconnect.canSafelyClose(display: display) {
            return "安全兜底打开，接入其他显示器后会按设置关闭"
        }
        if wantsClosed {
            return "等待按设置关闭"
        }
        let status = statuses.status(for: profile.id)
        if status.status == .unknown {
            return "正常运行"
        }
        return status.message.isEmpty ? status.status.rawValue : "\(status.status.rawValue)：\(status.message)"
    }

    private func currentDisplayModeDescription(display: DisplaySnapshot) -> String {
        guard display.runtimeDisplayID != 0,
              let mode = CGDisplayCopyDisplayMode(display.runtimeDisplayID) else {
            return "--"
        }
        return displayModeTitle(mode: mode, current: false)
    }

    private func canUseDisplayModes(display: DisplaySnapshot) -> Bool {
        display.isActive && display.runtimeDisplayID != 0
    }

    private func resolutionAvailabilityMessage(display: DisplaySnapshot) -> String {
        if !display.isActive {
            return "显示器当前不在线，无法切换分辨率。"
        }
        if display.runtimeDisplayID == 0 {
            return "没有拿到系统显示器 ID，无法枚举分辨率。"
        }
        if displayModeOptions.isEmpty {
            return "系统没有返回可用桌面显示模式。"
        }
        let hidpiCount = displayModeOptions.filter(\.isHiDPI).count
        return "共 \(displayModeOptions.count) 个可用模式，其中 \(hidpiCount) 个 HiDPI 模式。切换后 macOS 可能会短暂黑屏。"
    }

    private func displayModeOptions(for display: DisplaySnapshot) -> [DisplayModeOption] {
        guard canUseDisplayModes(display: display) else {
            return []
        }
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display.runtimeDisplayID, options) as? [CGDisplayMode] else {
            return []
        }
        let currentMode = CGDisplayCopyDisplayMode(display.runtimeDisplayID)
        var seen = Set<String>()

        return modes
            .filter { $0.isUsableForDesktopGUI() }
            .compactMap { mode -> DisplayModeOption? in
                let key = displayModeKey(mode)
                guard seen.insert(key).inserted else {
                    return nil
                }
                let current = currentMode.map { displayModeKey($0) == key } ?? false
                return DisplayModeOption(
                    mode: mode,
                    title: displayModeTitle(mode: mode, current: current),
                    isCurrent: current,
                    isHiDPI: isHiDPIMode(mode)
                )
            }
            .sorted { lhs, rhs in
                let lhsArea = lhs.mode.width * lhs.mode.height
                let rhsArea = rhs.mode.width * rhs.mode.height
                if lhsArea != rhsArea {
                    return lhsArea > rhsArea
                }
                if lhs.isHiDPI != rhs.isHiDPI {
                    return lhs.isHiDPI
                }
                return lhs.mode.refreshRate > rhs.mode.refreshRate
            }
    }

    private func displayModeKey(_ mode: CGDisplayMode) -> String {
        let refresh = Int((mode.refreshRate * 100).rounded())
        return "\(mode.width)x\(mode.height)@\(mode.pixelWidth)x\(mode.pixelHeight)@\(refresh)"
    }

    private func displayModeTitle(mode: CGDisplayMode, current: Bool) -> String {
        let logical = "\(mode.width) x \(mode.height)"
        let pixel = "\(mode.pixelWidth) x \(mode.pixelHeight)"
        let refresh = mode.refreshRate > 0 ? " @ \(formatRefreshRate(mode.refreshRate))Hz" : ""
        let hidpi = isHiDPIMode(mode) ? " HiDPI" : ""
        let currentText = current ? " 当前" : ""
        return "\(logical)\(refresh)\(hidpi) (\(pixel))\(currentText)"
    }

    private func isHiDPIMode(_ mode: CGDisplayMode) -> Bool {
        mode.pixelWidth > mode.width || mode.pixelHeight > mode.height
    }

    private func formatRefreshRate(_ refreshRate: Double) -> String {
        let rounded = refreshRate.rounded()
        if abs(refreshRate - rounded) < 0.01 {
            return "\(Int(rounded))"
        }
        return String(format: "%.2f", refreshRate)
    }

    private func canUseDDC(display: DisplaySnapshot) -> Bool {
        !display.isBuiltIn && display.isActive && !display.edidUUID.isEmpty
    }

    private func ddcAvailabilityMessage(display: DisplaySnapshot) -> String {
        if display.isBuiltIn {
            return "内置显示屏不支持 DDC/CI 快捷控制。"
        }
        if !display.isActive {
            return "显示器当前不在线，无法读取或写入 DDC。"
        }
        if display.edidUUID.isEmpty {
            return "没有读取到 EDID UUID，无法定位 DDC 目标显示器。"
        }
        return "拖动滑块时会实时写入对应 VCP 值，方便预览；如果显示器不支持该 VCP，会在这里显示错误。"
    }

    private func selectedDisplayAndProfile() -> (DisplaySnapshot, DisplayProfile)? {
        guard scannedDisplays.indices.contains(selectedDisplayIndex) else {
            return nil
        }
        let display = scannedDisplays[selectedDisplayIndex]
        return (display, existingProfile(for: display) ?? makeProfile(for: display))
    }

    private func diagnosticText(display: DisplaySnapshot, profile: DisplayProfile) -> String {
        [
            "名称: \(suggestedProfileName(for: display))",
            "类型: \(display.isBuiltIn ? "内置显示屏" : "外接显示器")",
            "连接状态: \(display.isActive ? "在线" : "已关闭/离线")",
            "系统 ID: \(display.runtimeDisplayID == 0 ? "未知" : "\(display.runtimeDisplayID)")",
            "EDID UUID: \(normalizedDetail(display.edidUUID))",
            "厂商 ID: \(normalizedDetail(display.vendorId))",
            "型号 ID: \(normalizedDetail(display.modelId))",
            "序列号: \(normalizedDetail(display.serialNumber == "0" ? "" : display.serialNumber))",
            "厂商: \(normalizedDetail(display.manufacturer))",
            "字母序列号: \(normalizedDetail(display.alphanumericSerial))",
            "IO 位置: \(normalizedDetail(display.ioLocation))",
            "运行状态: \(runtimeStatusText(profile: profile, display: display))"
        ].joined(separator: "\n")
    }

    private func fullDiagnosticText() -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        let processInfo = ProcessInfo.processInfo

        return """
        Mac助手诊断信息
        生成时间: \(now)

        应用状态
        版本: \(version) (\(build))
        进程 ID: \(processInfo.processIdentifier)
        macOS: \(processInfo.operatingSystemVersionString)
        当前设置页: \(pageTitleLabel.stringValue)
        显示器配置数: \(profiles.count)
        等待恢复显示器数: \(store.pendingReconnects.count)
        剪贴板历史: \(store.clipboard.enabled ? "已启用" : "已关闭")，最多 \(store.clipboard.maxHistoryCount) 条，快捷键 \(store.clipboard.hotKey.displayText)
        Finder 右键菜单: \(store.contextMenu.enabled ? "已启用" : "已关闭")
        压缩/解压格式: \(store.archive.enabledFormats.map(\.title).sorted().joined(separator: ", "))

        配置路径
        应用支持目录: \(pathDiagnostic(AppPaths.applicationSupportDirectory))
        配置文件: \(pathDiagnostic(AppPaths.configURL))
        状态文件: \(pathDiagnostic(AppPaths.stateURL))
        剪贴板加密库: \(pathDiagnostic(AppPaths.clipboardDatabaseURL))
        Finder 扩展配置: \(pathDiagnostic(AppPaths.finderSyncConfigURL))
        日志目录: \(pathDiagnostic(AppPaths.logsDirectory))

        权限状态
        辅助功能: \(AXIsProcessTrusted() ? "已授权" : "未授权")。影响剪贴板双击粘贴、快捷键粘贴、自动粘贴。
        自动化: 需在系统设置中按目标应用确认。影响 Finder 或系统应用联动动作。
        Finder 扩展: 需在系统设置中启用。影响 Finder 右键菜单、压缩/解压、复制路径、新建文件入口。
        完全磁盘访问: 需在系统设置中手动开启。影响双击打开受保护目录或外置磁盘中的压缩包。

        显示器摘要
        \(displayDiagnosticsSummary())

        最近日志
        \(AppLogger.shared.recentLogSummary())
        """
    }

    private func pathDiagnostic(_ url: URL) -> String {
        "\(url.path) (\(FileManager.default.fileExists(atPath: url.path) ? "存在" : "不存在"))"
    }

    private func displayDiagnosticsSummary() -> String {
        guard !scannedDisplays.isEmpty else {
            return "未扫描到显示器。"
        }
        return scannedDisplays.enumerated().map { index, display in
            let profile = existingProfile(for: display) ?? makeProfile(for: display)
            return """
            #\(index + 1) \(suggestedProfileName(for: display))
              类型: \(display.isBuiltIn ? "内置" : "外接")
              状态: \(display.isActive ? "在线" : "已关闭/离线")
              系统 ID: \(display.runtimeDisplayID == 0 ? "未知" : "\(display.runtimeDisplayID)")
              当前模式: \(currentDisplayModeDescription(display: display))
              EDID UUID: \(normalizedDetail(display.edidUUID))
              厂商/型号/序列号: \(normalizedDetail(display.vendorId)) / \(normalizedDetail(display.modelId)) / \(normalizedDetail(display.serialNumber == "0" ? "" : display.serialNumber))
              IO 位置: \(normalizedDetail(display.ioLocation))
              运行状态: \(runtimeStatusText(profile: profile, display: display))
            """
        }.joined(separator: "\n")
    }

    private func setDDCStatus(_ message: String, isError: Bool = false) {
        ddcStatusLabel?.stringValue = message
        ddcStatusLabel?.textColor = isError ? NSColor.systemRed : NSColor.secondaryLabelColor
    }

    private func updateDDCValueLabel(_ value: Int, setting: DDCQuickSetting) {
        ddcValueLabels[setting]?.stringValue = "\(value)"
        ddcValueLabels[setting]?.textColor = .labelColor
    }

    private func applyDDCValue(_ value: Int, setting: DDCQuickSetting) {
        ddcSliders[setting]?.integerValue = value
        updateDDCValueLabel(value, setting: setting)
    }

    private func readDDCValue(setting: DDCQuickSetting, display: DisplaySnapshot) {
        do {
            let value = try ddc.readVCP(display: display, code: setting.vcpCode)
            applyDDCValue(value, setting: setting)
            setDDCStatus("已读取 \(setting.title)：\(value)")
        } catch {
            setDDCStatus("\(setting.title) 读取失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func writeDDCValue(setting: DDCQuickSetting, display: DisplaySnapshot, value: Int) {
        let clampedValue = min(max(value, 0), 100)
        updateDDCValueLabel(clampedValue, setting: setting)
        pendingDDCWriteValues[setting] = clampedValue
        scheduleDDCWriteIfNeeded(setting: setting, display: display)
    }

    private func scheduleDDCWriteIfNeeded(setting: DDCQuickSetting, display: DisplaySnapshot) {
        guard pendingDDCWriteWorkItems[setting] == nil,
              !ddcWriteInFlight.contains(setting),
              pendingDDCWriteValues[setting] != nil else {
            return
        }

        let lastWriteTime = ddcLastWriteTimes[setting] ?? .distantPast
        let elapsed = Date().timeIntervalSince(lastWriteTime)
        let delay = max(0, ddcWriteThrottleInterval - elapsed)

        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self, !workItem.isCancelled else { return }
            self.pendingDDCWriteWorkItems[setting] = nil
            self.startPendingDDCWrite(setting: setting, display: display)
        }
        pendingDDCWriteWorkItems[setting] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @objc private func probeSelectedDDC() {
        guard let (display, _) = selectedDisplayAndProfile() else {
            return
        }
        setDDCStatus("正在检测 DDC 能力...")
        DispatchQueue.global(qos: .userInitiated).async { [ddc] in
            let result = Result { try ddc.probe(display: display) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isSelectedDDCTarget(display) else { return }
                switch result {
                case .success(let brightness):
                    self.applyDDCValue(brightness, setting: .brightness)
                    self.setDDCStatus("DDC 可用，已读取亮度：\(brightness)。")
                case .failure(let error):
                    self.setDDCStatus("DDC 检测失败：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func startPendingDDCWrite(setting: DDCQuickSetting, display: DisplaySnapshot) {
        guard let value = pendingDDCWriteValues.removeValue(forKey: setting),
              isSelectedDDCTarget(display) else {
            return
        }

        ddcWriteInFlight.insert(setting)
        let requestID = UUID()
        ddcWriteRequestIDs[setting] = requestID

        ddcWriteQueue.async { [weak self] in
            let result = Result {
                try self?.ddc.writeVCP(display: display, code: setting.vcpCode, value: value)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.ddcWriteRequestIDs[setting] == requestID else {
                    return
                }

                self.ddcWriteInFlight.remove(setting)
                self.ddcLastWriteTimes[setting] = Date()

                if self.isSelectedDDCTarget(display) {
                    switch result {
                    case .success:
                        self.updateDDCValueLabel(value, setting: setting)
                        self.setDDCStatus("已写入 \(setting.title)：\(value)")
                    case .failure(let error):
                        self.setDDCStatus("\(setting.title) 写入失败：\(error.localizedDescription)", isError: true)
                    }

                    if self.pendingDDCWriteValues[setting] != nil {
                        self.scheduleDDCWriteIfNeeded(setting: setting, display: display)
                    } else {
                        self.ddcWriteRequestIDs[setting] = nil
                    }
                } else {
                    self.ddcWriteRequestIDs[setting] = nil
                }
            }
        }
    }

    private func cancelPendingDDCWrites() {
        pendingDDCWriteWorkItems.values.forEach { $0.cancel() }
        pendingDDCWriteWorkItems.removeAll()
        ddcWriteRequestIDs.removeAll()
        pendingDDCWriteValues.removeAll()
        ddcWriteInFlight.removeAll()
    }

    private func isSelectedDDCTarget(_ display: DisplaySnapshot) -> Bool {
        guard let (selectedDisplay, _) = selectedDisplayAndProfile() else {
            return false
        }
        return selectedDisplay.hasSameStableIdentity(as: display)
    }

    private func setResolutionStatus(_ message: String, isError: Bool = false) {
        resolutionStatusLabel?.stringValue = message
        resolutionStatusLabel?.textColor = isError ? NSColor.systemRed : NSColor.secondaryLabelColor
    }

    private func displayModeConfirmationMessage(remainingSeconds: Int, confirmation: PendingDisplayModeConfirmation) -> String {
        """
        已切换到：\(confirmation.appliedTitle)
        原模式：\(confirmation.previousTitle)

        如果画面显示正常，请点击“保留”。\(remainingSeconds) 秒后未确认将自动恢复原模式。
        """
    }

    private func beginDisplayModeConfirmation(_ confirmation: PendingDisplayModeConfirmation) {
        pendingDisplayModeConfirmation = confirmation
        displayModeConfirmationTimer?.invalidate()
        displayModeConfirmationTimer = nil

        guard let window else {
            restorePendingDisplayMode(reason: "无法显示确认窗口")
            return
        }

        let alert = NSAlert()
        alert.messageText = "保留这个显示模式？"
        alert.informativeText = displayModeConfirmationMessage(remainingSeconds: 15, confirmation: confirmation)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保留")
        alert.addButton(withTitle: "恢复")

        var remainingSeconds = 15
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak alert] timer in
            guard let self, let alert else {
                timer.invalidate()
                return
            }
            remainingSeconds -= 1
            if remainingSeconds <= 0 {
                timer.invalidate()
                window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
            } else {
                alert.informativeText = self.displayModeConfirmationMessage(remainingSeconds: remainingSeconds, confirmation: confirmation)
            }
        }
        displayModeConfirmationTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.displayModeConfirmationTimer?.invalidate()
            self.displayModeConfirmationTimer = nil

            if response == .alertFirstButtonReturn {
                self.pendingDisplayModeConfirmation = nil
                self.setResolutionStatus("已保留：\(confirmation.appliedTitle)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.refreshDisplays()
                }
            } else {
                self.restorePendingDisplayMode(reason: remainingSeconds <= 0 ? "倒计时结束" : "用户选择恢复")
            }
        }
    }

    private func restorePendingDisplayMode(reason: String) {
        guard let confirmation = pendingDisplayModeConfirmation else {
            return
        }
        pendingDisplayModeConfirmation = nil
        displayModeConfirmationTimer?.invalidate()
        displayModeConfirmationTimer = nil

        let error = CGDisplaySetDisplayMode(confirmation.displayID, confirmation.previousMode, nil)
        if error == .success {
            setResolutionStatus("已恢复原显示模式：\(confirmation.previousTitle)（\(reason)）")
            AppLogger.shared.info("显示模式已恢复：displayID=\(confirmation.displayID), reason=\(reason)")
        } else {
            setResolutionStatus("自动恢复显示模式失败：\(error.rawValue)。请在系统设置中手动恢复。", isError: true)
            AppLogger.shared.error("显示模式自动恢复失败：displayID=\(confirmation.displayID), reason=\(reason), error=\(error.rawValue)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.refreshDisplays()
        }
    }

    @objc private func refreshDisplaysAction() {
        guard refreshDisplaysButton.isEnabled else { return }
        refreshDisplaysButton.isEnabled = false
        refreshDisplays()
        refreshDisplaysButton.spinOnce { [weak self] in
            self?.refreshDisplaysButton.isEnabled = true
        }
    }

    @objc private func generalSettingsActionPressed(_ sender: MacTextButton) {
        guard let action = GeneralSettingsAction(rawValue: sender.tag) else { return }
        switch action {
        case .checkForUpdates:
            onCheckForUpdates()
        case .exportConfig:
            exportConfig()
        case .importConfig:
            importConfig()
        case .iCloudBackup:
            backupConfigToICloud()
        case .iCloudSync:
            syncConfigFromICloud()
        case .retryClipboardKey:
            clipboardController.retryEncryptionAccess()
            reloadCurrentPage()
        case .clearUndecryptableClipboard:
            guard confirmClipboardHistoryClear() else { return }
            clipboardController.clearUndecryptableHistory()
            reloadCurrentPage()
        }
    }

    private func confirmClipboardHistoryClear() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空全部剪贴板历史？"
        alert.informativeText = "这会删除当前加密库、blob 和缩略图，无法撤销。不会删除应用配置。"
        alert.addButton(withTitle: "清空历史")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.title = "导出配置"
        panel.nameFieldStringValue = "Mac助手配置.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.store.exportConfig(to: url)
                self.showAlert(title: "配置已导出", message: "已导出到：\(url.path)")
            } catch {
                self.showAlert(title: "导出配置失败", message: error.localizedDescription)
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.title = "导入配置"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard self.confirmSettingsImport() else { return }
            do {
                try self.store.importConfig(from: url)
                self.reloadAfterExternalConfigChange()
                self.showAlert(title: "配置已导入", message: "已从所选 JSON 配置恢复。")
            } catch {
                self.showAlert(title: "导入配置失败", message: error.localizedDescription)
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func backupConfigToICloud() {
        do {
            let backupURL = try store.backupConfigToICloud()
            reloadGeneralSettings()
            showAlert(title: "iCloud 备份完成", message: "已备份到：\(backupURL.path)")
        } catch {
            showAlert(title: "iCloud 备份失败", message: error.localizedDescription)
        }
    }

    private func syncConfigFromICloud() {
        do {
            let difference = try store.iCloudBackupDifferenceSummary()
            guard confirmSettingsImport(additionalMessage: difference) else { return }
            try store.syncConfigFromICloud()
            reloadAfterExternalConfigChange()
            showAlert(title: "iCloud 同步完成", message: "已从 iCloud 备份同步配置到本机。")
        } catch {
            showAlert(title: "iCloud 同步失败", message: error.localizedDescription)
        }
    }

    private func confirmSettingsImport(additionalMessage: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = "覆盖当前配置？"
        alert.informativeText = [
            additionalMessage,
            "导入或恢复会替换当前显示器、剪贴板、压缩和右键菜单配置。建议先导出当前配置作为备份。"
        ].compactMap { $0 }.joined(separator: "\n\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func reloadAfterExternalConfigChange() {
        profiles = store.profiles
        onSave()
        refreshDisplays()
    }

    private func iCloudBackupStatusText() -> String {
        guard let backupURL = AppPaths.iCloudConfigBackupURL else {
            return "iCloud Drive 当前不可用；请确认系统已登录 Apple ID，并已启用 iCloud Drive。"
        }
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            return "iCloud 备份位置：\(backupURL.path)。当前还没有备份。"
        }
        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: backupURL.path)[.modificationDate]) as? Date
        let dateText = modifiedAt.map(formatSettingsDate) ?? "未知时间"
        return "iCloud 备份位置：\(backupURL.path)。最近备份：\(dateText)。"
    }

    private func formatSettingsDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    @objc private func permissionActionPressed(_ sender: PermissionActionButton) {
        guard let action = PermissionAction(rawValue: sender.tag) else { return }
        let message = "权限按钮点击：\(action)"
        NSLog("%@", message)
        switch action {
        case .accessibility:
            PermissionGuideFlow.shared.authorize(.accessibility)
        case .automation:
            PermissionGuideFlow.shared.authorize(.automation)
        case .finderExtension:
            PermissionGuideFlow.shared.authorize(.finderExtension)
        case .fullDiskAccess:
            PermissionGuideFlow.shared.authorize(.fullDiskAccess)
        case .refresh:
            reloadCurrentPage()
        case .copyDiagnostics:
            copyDiagnosticsToPasteboard()
        case .exportDiagnostics:
            exportDiagnostics()
        case .displayRecovery:
            runDisplayRecoveryFallback()
        case .finderExtensionTest:
            openFinderExtensionTestDirectory()
        }
    }

    @objc private func clipboardExcludedAppsChanged() {
        saveClipboardConfig()
    }

    @objc private func clipboardHotKeyEnabledChanged() {
        hotKeyRecorder.isRecorderEnabled = clipboardHotKeyEnabledSwitch.state == .on
        saveClipboardConfig()
    }

    @objc private func clipboardShortcutEnabledChanged(_ sender: MacSwitchControl) {
        guard let shortcut = clipboardShortcutSwitches.first(where: { $0.value === sender })?.key else { return }
        saveClipboardShortcut(shortcut, enabled: sender.state == .on)
    }

    private func openFinderExtensionTestDirectory() {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        NSWorkspace.shared.open(downloads)
        showAlert(title: "测试 Finder 右键菜单", message: "已打开下载目录。请在 Finder 空白处或任意文件上右键，确认能看到 Mac助手菜单项；如果没有，请在系统设置中启用 Finder 扩展。")
    }

    private func finderExtensionStatusTitle() -> String {
        switch SystemCapabilities.finderExtensionStatus().enabled {
        case .some(true):
            return "已启用"
        case .some(false):
            return "未启用"
        case .none:
            return "需确认"
        }
    }

    private func finderExtensionStatusKind() -> PermissionStatusPill.Kind {
        switch SystemCapabilities.finderExtensionStatus().enabled {
        case .some(true):
            return .granted
        case .some(false):
            return .needed
        case .none:
            return .manual
        }
    }

    private func runDisplayRecoveryFallback() {
        let alert = NSAlert()
        alert.messageText = "执行兜底恢复显示器？"
        alert.informativeText = "将备份并清除 WindowServer 的显示布局缓存，然后重启图形服务。macOS 会要求管理员授权，当前屏幕会短暂黑屏或回到登录界面。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "执行")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let byHostDirectory = shellQuoted(NSHomeDirectory() + "/Library/Preferences/ByHost")
        let command = """
        timestamp=$(date +%Y%m%d-%H%M%S)
        for f in \(byHostDirectory)/com.apple.windowserver.displays.*.plist; do
            if [ -f "$f" ]; then
                mv "$f" "$f.disabled-$timestamp"
            fi
        done
        if [ -f /Library/Preferences/com.apple.windowserver.displays.plist ]; then
            mv /Library/Preferences/com.apple.windowserver.displays.plist /Library/Preferences/com.apple.windowserver.displays.plist.disabled-$timestamp
        fi
        killall cfprefsd
        killall WindowServer
        """
        let scriptSource = "do shell script \(appleScriptStringLiteral(command)) with administrator privileges"
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: scriptSource)?.executeAndReturnError(&errorInfo)
        if result == nil, let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
            AppLogger.shared.error("兜底恢复显示器失败：\(message)")
            showAlert(title: "兜底恢复失败", message: message)
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    @objc private func selectDisplayTab(_ sender: MacSegmentButton) {
        selectedDisplayIndex = sender.tag
        rebuildDisplayTabs()
        reloadSelectedDisplay()
    }

    @objc private func selectSidebarPage(_ sender: SidebarNavItem) {
        guard let page = SettingsPage(rawValue: sender.tag), selectedSettingsPage != page else {
            return
        }
        selectedSettingsPage = page
        reloadCurrentPage()
    }

    @objc private func copyDisplayDetails(_ sender: PermissionActionButton) {
        guard let (display, profile) = selectedDisplayAndProfile() else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticText(display: display, profile: profile), forType: .string)
        setDDCStatus("显示器详情已复制到剪贴板。")
    }

    private func copyDiagnosticsToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullDiagnosticText(), forType: .string)
        showAlert(title: "诊断信息已复制", message: "已复制应用状态、配置路径、权限状态、显示器摘要和最近日志摘要。")
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "导出本地诊断"
        panel.nameFieldStringValue = "Mac助手诊断.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.fullDiagnosticText().write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                self.showAlert(title: "诊断已导出", message: "诊断文件仅保存在本机：\(url.path)")
            } catch {
                self.showAlert(title: "诊断导出失败", message: error.localizedDescription)
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc private func applyDisplayMode(_ sender: PermissionActionButton) {
        guard let (display, _) = selectedDisplayAndProfile() else {
            return
        }
        guard pendingDisplayModeConfirmation == nil else {
            setResolutionStatus("请先在弹窗中确认保留或恢复当前显示模式。", isError: true)
            return
        }
        guard canUseDisplayModes(display: display) else {
            setResolutionStatus(resolutionAvailabilityMessage(display: display), isError: true)
            return
        }
        guard let previousMode = CGDisplayCopyDisplayMode(display.runtimeDisplayID) else {
            setResolutionStatus("无法读取当前显示模式，已取消切换以避免无法恢复。", isError: true)
            return
        }
        let index = resolutionPopup.selectedIndex
        guard displayModeOptions.indices.contains(index) else {
            setResolutionStatus("请选择一个有效的显示模式。", isError: true)
            return
        }

        let option = displayModeOptions[index]
        let previousKey = displayModeKey(previousMode)
        guard previousKey != displayModeKey(option.mode) else {
            setResolutionStatus("当前已经是所选显示模式。")
            return
        }

        let error = CGDisplaySetDisplayMode(display.runtimeDisplayID, option.mode, nil)
        guard error == .success else {
            setResolutionStatus("分辨率切换失败：\(error.rawValue)", isError: true)
            return
        }
        setResolutionStatus("已临时应用：\(option.title)。请在弹窗中确认保留。")
        AppLogger.shared.info("显示模式已临时切换：displayID=\(display.runtimeDisplayID), from=\(displayModeTitle(mode: previousMode, current: false)), to=\(option.title)")
        beginDisplayModeConfirmation(PendingDisplayModeConfirmation(
            displayID: display.runtimeDisplayID,
            previousMode: previousMode,
            previousTitle: displayModeTitle(mode: previousMode, current: false),
            appliedTitle: option.title
        ))
    }

    @objc private func readDDCQuickValue(_ sender: PermissionActionButton) {
        guard let setting = DDCQuickSetting(rawValue: sender.tag),
              let (display, _) = selectedDisplayAndProfile() else {
            return
        }
        guard canUseDDC(display: display) else {
            setDDCStatus(ddcAvailabilityMessage(display: display), isError: true)
            return
        }
        readDDCValue(setting: setting, display: display)
    }

    @objc private func ddcSliderChanged(_ sender: MacSliderControl) {
        guard let setting = DDCQuickSetting(rawValue: sender.tag),
              let (display, _) = selectedDisplayAndProfile() else {
            return
        }
        guard canUseDDC(display: display) else {
            setDDCStatus(ddcAvailabilityMessage(display: display), isError: true)
            return
        }
        writeDDCValue(setting: setting, display: display, value: sender.integerValue)
    }

    @objc private func contextMenuActionButtonPressed(_ sender: Any) {
        if let toggle = sender as? ContextMenuToggleButton {
            updateContextMenuItem(toggle.itemID) { item in
                item.enabled = toggle.state == .on
            }
            return
        }
        guard let button = sender as? ContextMenuActionButton else { return }
        switch button.actionKind {
        case .toggle:
            break
        case .moveUp:
            moveContextMenuItem(button.itemID, direction: .up)
        case .moveDown:
            moveContextMenuItem(button.itemID, direction: .down)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func controlChanged(_ sender: Any?) {
        if sender as? MacSwitchControl === closeDisplaySwitch {
            handleCloseDisplayChanged()
        } else if sender as? MacSwitchControl === clipboardEnabledSwitch
            || sender as? MacSwitchControl === clipboardPausedSwitch
            || sender as? MacSwitchControl === clipboardExcludePasswordManagersSwitch {
            saveClipboardConfig()
        } else if sender as? MacSwitchControl === contextMenuEnabledSwitch {
            saveContextMenuEnabled()
        } else if sender as? MacSwitchControl === archiveStripMacMetadataSwitch {
            saveArchiveOptions()
        } else if sender as? MacSwitchControl === archiveDefaultOpenerSwitch {
            saveArchiveOptions()
        } else if sender as? MacSwitchControl === archiveAutoCloseExtractionProgressSwitch {
            saveArchiveOptions()
        } else if let switchControl = sender as? MacSwitchControl,
                  let format = archiveFormatSwitches.first(where: { $0.value === switchControl })?.key {
            saveArchiveFormat(format, enabled: switchControl.state == .on)
        } else {
            saveSelectedProfile()
        }
    }

}

private enum ContextMenuMoveDirection {
    case up
    case down
}

private final class SystemMetricChartView: NSView {
    private let title: String
    private let tintColor: NSColor
    private var samples: [Double] = []
    private var valueText = "--"
    private var detailText = ""
    private let maxSampleCount = 60

    init(title: String, tintColor: NSColor) {
        self.title = title
        self.tintColor = tintColor
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 305).isActive = true
        heightAnchor.constraint(equalToConstant: 154).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func append(sample: Double?, valueText: String, detailText: String) {
        self.valueText = valueText
        self.detailText = detailText
        if let sample {
            samples.append(min(100, max(0, sample)))
            if samples.count > maxSampleCount {
                samples.removeFirst(samples.count - maxSampleCount)
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.70).setFill()
        card.fill()
        MacAssistantUI.Color.hairline.setStroke()
        card.lineWidth = 1
        card.stroke()

        drawText(title, rect: NSRect(x: 12, y: bounds.height - 25, width: bounds.width - 24, height: 15), font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        drawText(valueText, rect: NSRect(x: 12, y: bounds.height - 54, width: bounds.width - 24, height: 24), font: .monospacedDigitSystemFont(ofSize: 22, weight: .semibold), color: .labelColor)
        drawText(detailText, rect: NSRect(x: 12, y: 12, width: bounds.width - 24, height: 14), font: .systemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)

        let plotRect = NSRect(x: 12, y: 34, width: bounds.width - 24, height: 54)
        drawGrid(in: plotRect)
        drawSamples(in: plotRect)
    }

    private func drawGrid(in rect: NSRect) {
        MacAssistantUI.Color.hairline.withAlphaComponent(0.55).setStroke()
        for index in 0...2 {
            let y = rect.minY + rect.height * CGFloat(index) / 2
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: y))
            line.line(to: NSPoint(x: rect.maxX, y: y))
            line.lineWidth = 1
            line.stroke()
        }
    }

    private func drawSamples(in rect: NSRect) {
        guard !samples.isEmpty else {
            drawText("等待采样", rect: rect, font: .systemFont(ofSize: 11, weight: .regular), color: .tertiaryLabelColor, alignment: .center)
            return
        }

        let step = samples.count > 1 ? rect.width / CGFloat(samples.count - 1) : 0
        let line = NSBezierPath()
        let fill = NSBezierPath()

        for (index, sample) in samples.enumerated() {
            let x = samples.count == 1 ? rect.midX : rect.minX + CGFloat(index) * step
            let y = rect.minY + rect.height * CGFloat(sample / 100)
            let point = NSPoint(x: x, y: y)
            if index == 0 {
                line.move(to: point)
                fill.move(to: NSPoint(x: x, y: rect.minY))
                fill.line(to: point)
            } else {
                line.line(to: point)
                fill.line(to: point)
            }
        }

        let lastX = samples.count == 1 ? rect.midX : rect.maxX
        fill.line(to: NSPoint(x: lastX, y: rect.minY))
        fill.close()
        tintColor.withAlphaComponent(0.12).setFill()
        fill.fill()

        tintColor.setStroke()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.stroke()
    }

    private func drawText(
        _ text: String,
        rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect, withAttributes: attributes)
    }
}

private final class PermissionStatusPill: NSView {
    enum Kind {
        case granted
        case needed
        case manual
    }

    private let title: String
    private let kind: Kind

    init(title: String, kind: Kind) {
        self.title = title
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width + 18
        return NSSize(width: max(54, width), height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tint: NSColor
        switch kind {
        case .granted:
            tint = MacAssistantUI.Color.green
        case .needed:
            tint = MacAssistantUI.Color.amber
        case .manual:
            tint = MacAssistantUI.Color.blue
        }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        tint.withAlphaComponent(0.14).setFill()
        path.fill()
        tint.withAlphaComponent(0.38).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: tint
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        title.draw(
            in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 0.5, width: size.width, height: size.height),
            withAttributes: attributes
        )
    }
}

private final class PermissionActionButton: NSControl {
    private let title: String
    private var isPressed = false {
        didSet {
            if oldValue != isPressed {
                needsDisplay = true
            }
        }
    }

    init(title: String, target: AnyObject?, action: Selector?) {
        self.title = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 66).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 22
        return NSSize(width: max(66, width), height: 26)
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
        let localPoint = convert(event.locationInWindow, from: nil)
        isPressed = bounds.contains(localPoint)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        let shouldSendAction = isPressed && bounds.contains(localPoint)
        isPressed = false
        if shouldSendAction {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pressed = isEnabled && isPressed
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        let fillColor = pressed
            ? MacAssistantUI.Color.blue.withAlphaComponent(0.16)
            : NSColor.white.withAlphaComponent(isEnabled ? 0.88 : 0.44)
        fillColor.setFill()
        path.fill()
        let borderColor = pressed
            ? MacAssistantUI.Color.blue.withAlphaComponent(0.58)
            : MacAssistantUI.Color.hairline.withAlphaComponent(isEnabled ? 1 : 0.55)
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: (isEnabled ? MacAssistantUI.Color.blue.withAlphaComponent(pressed ? 0.88 : 1) : NSColor.tertiaryLabelColor)
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        title.draw(
            in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 0.5, width: size.width, height: size.height),
            withAttributes: attributes
        )
    }
}

private final class ContextMenuActionButton: NSControl {
    enum ActionKind {
        case toggle
        case moveUp
        case moveDown
    }

    let itemID: ContextMenuItemID
    let actionKind: ActionKind
    private let symbolName: String

    init(symbolName: String, itemID: ContextMenuItemID, actionKind: ActionKind, target: AnyObject?, action: Selector?) {
        self.itemID = itemID
        self.actionKind = actionKind
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.34
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.72).setFill()
        path.fill()
        MacAssistantUI.Color.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()

        if symbolName == "chevron.up" || symbolName == "chevron.down" {
            drawMoveArrow(up: symbolName == "chevron.up")
        } else if let icon = MacAssistantUI.symbol(symbolName, pointSize: 12, weight: .semibold) {
            icon.draw(in: NSRect(x: (bounds.width - 12) / 2, y: (bounds.height - 12) / 2, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.45)
        }
    }

    private func drawMoveArrow(up: Bool) {
        let centerX = bounds.midX
        let arrow = NSBezierPath()
        arrow.lineWidth = 2.25
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round

        if up {
            arrow.move(to: NSPoint(x: centerX, y: bounds.midY - 4.8))
            arrow.line(to: NSPoint(x: centerX, y: bounds.midY + 5.1))
            arrow.move(to: NSPoint(x: centerX - 3.4, y: bounds.midY + 1.5))
            arrow.line(to: NSPoint(x: centerX, y: bounds.midY + 5.1))
            arrow.line(to: NSPoint(x: centerX + 3.4, y: bounds.midY + 1.5))
        } else {
            arrow.move(to: NSPoint(x: centerX, y: bounds.midY + 4.8))
            arrow.line(to: NSPoint(x: centerX, y: bounds.midY - 5.1))
            arrow.move(to: NSPoint(x: centerX - 3.4, y: bounds.midY - 1.5))
            arrow.line(to: NSPoint(x: centerX, y: bounds.midY - 5.1))
            arrow.line(to: NSPoint(x: centerX + 3.4, y: bounds.midY - 1.5))
        }

        (isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
        arrow.stroke()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }
}

private final class ContextMenuToggleButton: NSControl {
    let itemID: ContextMenuItemID
    let actionKind: ContextMenuActionButton.ActionKind

    var state: NSControl.StateValue = .off {
        didSet { updateAppearance() }
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    init(itemID: ContextMenuItemID, actionKind: ContextMenuActionButton.ActionKind, target: AnyObject?, action: Selector?) {
        self.itemID = itemID
        self.actionKind = actionKind
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }

    private func updateAppearance() {
        let checked = state == .on
        layer?.backgroundColor = checked ? MacAssistantUI.Color.blue.cgColor : NSColor.white.cgColor
        layer?.borderColor = (checked ? MacAssistantUI.Color.blue : MacAssistantUI.Color.hairline).cgColor
        alphaValue = isEnabled ? 1 : 0.38

        subviews.forEach { $0.removeFromSuperview() }
        guard checked else { return }
        let mark = NSTextField(labelWithString: "✓")
        mark.font = .systemFont(ofSize: 13, weight: .bold)
        mark.textColor = .white
        mark.alignment = .center
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5)
        ])
    }
}

private extension DisconnectConfig {
    func disabled() -> DisconnectConfig {
        DisconnectConfig(
            enabled: false,
            allowSoftDisconnect: false,
            autoReconnect: autoReconnect,
            autoReconnectDelaySeconds: autoReconnectDelaySeconds,
            externalOnly: false,
            confirmBeforeDisconnect: confirmBeforeDisconnect
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { index in
            Array(self[index..<Swift.min(index + size, count)])
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
