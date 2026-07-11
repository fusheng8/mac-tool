import AppKit
import Foundation

final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: ProfileStore
    private let detector: DisplayDetector
    private let automation: AutomationController
    private let disconnect: SoftDisconnectController
    private let recovery: RecoveryManager
    private let statuses: RuntimeStatusStore
    private let clipboard: ClipboardHistoryController
    private let onOpenPortManagement: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onStartArchivePreset: (ArchivePresetID) -> Void
    private let onConfigurationChanged: () -> Void
    private let loginItems = LoginItemController()
    private var settingsWindowController: SettingsWindowController?
    private let popover = NSPopover()
    private var popoverController: MenuBarPopoverController?

    init(
        store: ProfileStore,
        detector: DisplayDetector,
        automation: AutomationController,
        disconnect: SoftDisconnectController,
        recovery: RecoveryManager,
        statuses: RuntimeStatusStore,
        clipboard: ClipboardHistoryController,
        onOpenPortManagement: @escaping () -> Void = {},
        onCheckForUpdates: @escaping () -> Void = {},
        onStartArchivePreset: @escaping (ArchivePresetID) -> Void = { _ in },
        onConfigurationChanged: @escaping () -> Void = {}
    ) {
        self.store = store
        self.detector = detector
        self.automation = automation
        self.disconnect = disconnect
        self.recovery = recovery
        self.statuses = statuses
        self.clipboard = clipboard
        self.onOpenPortManagement = onOpenPortManagement
        self.onCheckForUpdates = onCheckForUpdates
        self.onStartArchivePreset = onStartArchivePreset
        self.onConfigurationChanged = onConfigurationChanged
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        configureStatusButton()
        rebuildMenu()
    }

    func rebuildMenu() {
        statusItem.button?.title = ""
        statusItem.button?.toolTip = statusSummary()
        statusItem.menu = nil
        popoverController?.update(model: makePopoverModel())
    }

    func refreshAfterDisplayChange() {
        rebuildMenu()
        if settingsWindowController?.window?.isVisible == true {
            settingsWindowController?.refreshAfterDisplayChange()
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        statusItem.length = NSStatusItem.squareLength
        button.title = ""
        button.image = statusIcon()
        button.imagePosition = .imageOnly
        button.toolTip = statusSummary()
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func statusIcon() -> NSImage? {
        let sourceImage = Bundle.main.image(forResource: "StatusIconRingTemplate")
            ?? Bundle.main.image(forResource: "StatusIconRingGray")
            ?? NSImage(contentsOf: URL(fileURLWithPath: "Resources/StatusIconRingGray.png"))
        let image = sourceImage?.copy() as? NSImage
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private func statusSummary() -> String {
        let clipboardText: String
        if !store.clipboard.enabled {
            clipboardText = "剪贴板关闭"
        } else if store.clipboard.recordingPaused {
            clipboardText = "剪贴板暂停记录"
        } else {
            clipboardText = "剪贴板 \(clipboard.history.count) 条"
        }
        let finderText = store.contextMenu.enabled ? "右键菜单已启用" : "右键菜单关闭"
        let pendingText = store.pendingReconnects.isEmpty ? nil : "\(store.pendingReconnects.count) 个显示器等待恢复"
        return ([clipboardText, finderText] + [pendingText].compactMap { $0 }).joined(separator: " · ")
    }

    private func makeStatusSnapshot() -> ControlCenterStatusSnapshot {
        let clipboardConfig = store.clipboard
        return ControlCenterStatusSnapshot.make(input: ControlCenterStatusInput(
            clipboardEnabled: clipboardConfig.enabled,
            clipboardPaused: clipboardConfig.recordingPaused,
            clipboardPrivacyExclusionsActive: clipboardConfig.excludeKnownPasswordManagers || !clipboardConfig.excludedBundleIdentifiers.isEmpty,
            finderFeatureEnabled: store.contextMenu.enabled,
            finderExtensionEnabled: SystemCapabilities.finderExtensionStatus().enabled,
            connectedDisplayCount: detector.onlineDisplays().filter(\.isActive).count,
            pendingDisplayRecoveryCount: store.pendingReconnects.count,
            archiveFormatCount: store.archive.enabledFormats.count
        ))
    }

    private func makePopoverModel() -> MenuBarPopoverModel {
        MenuBarPopoverModel(
            status: makeStatusSnapshot(),
            clipboardCount: clipboard.history.count,
            connectedDisplayCount: detector.onlineDisplays().filter(\.isActive).count,
            loginItemEnabled: loginItems.isEnabled
        )
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        let controller = popoverController ?? makePopoverController()
        controller.update(model: makePopoverModel())
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func makePopoverController() -> MenuBarPopoverController {
        let controller = MenuBarPopoverController(model: makePopoverModel())
        controller.onOpenRoute = { [weak self] route in
            self?.popover.performClose(nil)
            self?.openSettings(route: route)
        }
        controller.onOpenClipboard = { [weak self] in
            self?.popover.performClose(nil)
            self?.clipboard.showHistoryPanel()
        }
        controller.onCheckForUpdates = { [weak self] in
            self?.popover.performClose(nil)
            self?.onCheckForUpdates()
        }
        controller.onToggleLoginItem = { [weak self] in
            guard let self else { return }
            self.toggleLoginItem()
            self.popoverController?.update(model: self.makePopoverModel())
        }
        controller.onQuit = { [weak self] in
            self?.popover.performClose(nil)
            NSApp.terminate(nil)
        }
        controller.onDismiss = { [weak self] in self?.popover.performClose(nil) }
        popoverController = controller
        return controller
    }

    private func actionItem(_ title: String, _ selector: Selector, _ representedObject: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        return item
    }

    private func settingsPageItem(_ title: String, _ page: SettingsWindowController.SettingsPage) -> NSMenuItem {
        actionItem(title, #selector(openSettingsPage(_:)), page)
    }

    private func quitItem() -> NSMenuItem {
        let item = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.target = NSApp
        return item
    }

    @objc private func openSettingsPage(_ sender: NSMenuItem) {
        let page = sender.representedObject as? SettingsWindowController.SettingsPage ?? .displays
        openSettings(page: page)
    }

    func openSettingsWindow() {
        openSettings(route: .overview)
    }

    func openSystemOverview() {
        openSettings(route: .overview)
    }

    func openDisplaySettings() {
        openSettings(route: .displays)
    }

    func openPortManagement() {
        openSettings(route: .ports)
    }

    func openApplicationUninstaller() {
        openSettings(route: .uninstall)
    }

    func openArchiveSettings() {
        openSettings(route: .archive)
    }

    func openControlCenter(_ route: ControlCenterRoute) {
        openSettings(route: route)
    }

    @objc private func openClipboardHistory() {
        clipboard.showHistoryPanel()
    }

    private func openSettings(page: SettingsWindowController.SettingsPage?) {
        if page == .portManagement {
            onOpenPortManagement()
        }
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: store,
                detector: detector,
                disconnect: disconnect,
                recovery: recovery,
                statuses: statuses,
                clipboardController: clipboard,
                onCheckForUpdates: { [weak self] in
                    self?.onCheckForUpdates()
                },
                onStartArchivePreset: { [weak self] presetID in
                    self?.onStartArchivePreset(presetID)
                },
                onSave: { [weak self] in
                    self?.store.reload()
                    self?.clipboard.updateConfiguration()
                    self?.onConfigurationChanged()
                    self?.rebuildMenu()
                },
                onClose: {}
            )
        }
        if let page {
            settingsWindowController?.selectPage(page)
        }
        let shouldCenterWindow = settingsWindowController?.window?.isVisible != true
        if shouldCenterWindow {
            settingsWindowController?.window?.center()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings(route: ControlCenterRoute) {
        openSettings(page: SettingsWindowController.SettingsPage(route: route))
    }

    @objc private func toggleLoginItem() {
        do {
            try loginItems.setEnabled(!loginItems.isEnabled)
        } catch {
            showAlert(title: "登录启动设置失败", message: error.localizedDescription)
        }
        rebuildMenu()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
