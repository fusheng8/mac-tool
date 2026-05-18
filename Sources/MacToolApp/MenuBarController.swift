import AppKit
import Foundation

final class MenuBarController {
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
    private let onConfigurationChanged: () -> Void
    private let loginItems = LoginItemController()
    private var settingsWindowController: SettingsWindowController?

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
        self.onConfigurationChanged = onConfigurationChanged
        configureStatusButton()
        rebuildMenu()
    }

    func rebuildMenu() {
        statusItem.button?.title = ""
        statusItem.button?.toolTip = statusSummary()
        let menu = NSMenu()

        menu.addItem(actionItem("打开剪贴板历史", #selector(openClipboardHistory), nil))
        menu.addItem(settingsPageItem("系统概括", .systemOverview))
        menu.addItem(settingsPageItem("显示器", .displays))
        menu.addItem(settingsPageItem("剪切板", .clipboard))
        menu.addItem(settingsPageItem("压缩/解压", .archive))
        menu.addItem(settingsPageItem("右键菜单", .contextMenu))
        menu.addItem(settingsPageItem("端口管理", .portManagement))
        menu.addItem(settingsPageItem("设置", .settings))
        menu.addItem(.separator())

        let loginItem = actionItem("开机自启", #selector(toggleLoginItem), nil)
        loginItem.state = loginItems.isEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(actionItem("检查更新", #selector(checkForUpdates), nil))
        menu.addItem(.separator())
        menu.addItem(quitItem())
        statusItem.menu = menu
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
    }

    private func statusIcon() -> NSImage? {
        let sourceImage = Bundle.module.image(forResource: "StatusIconRingTemplate")
            ?? Bundle.main.image(forResource: "StatusIconRingTemplate")
            ?? Bundle.module.image(forResource: "StatusIconRingGray")
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
        openSettings(page: nil)
    }

    func openDisplaySettings() {
        openSettings(page: .displays)
    }

    func openPortManagement() {
        openSettings(page: .portManagement)
    }

    func openArchiveSettings() {
        openSettings(page: .archive)
    }

    @objc private func openClipboardHistory() {
        clipboard.showHistoryPanel()
    }

    private func openSettings(page: SettingsWindowController.SettingsPage?) {
        if page == .portManagement {
            onOpenPortManagement()
        }
        NSApp.setActivationPolicy(.regular)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: store,
                detector: detector,
                disconnect: disconnect,
                recovery: recovery,
                statuses: statuses
            ) { [weak self] in
                self?.onCheckForUpdates()
            } onSave: { [weak self] in
                self?.store.reload()
                self?.clipboard.updateConfiguration()
                self?.onConfigurationChanged()
                self?.rebuildMenu()
            } onClose: {
                NSApp.setActivationPolicy(.accessory)
            }
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
