import AppKit
import CoreGraphics
import Foundation

final class AutomationController {
    private let store: ProfileStore
    private let disconnect: SoftDisconnectController
    private let logger: AppLogger
    private let queue = DispatchQueue(label: "com.fusheng.mac-tool.display-automation", qos: .userInitiated)
    private var pendingDisplayChangeWorkItem: DispatchWorkItem?
    private var isMonitoringDisplayChanges = false

    var onChange: (() -> Void)?

    init(
        store: ProfileStore,
        disconnect: SoftDisconnectController,
        logger: AppLogger = .shared
    ) {
        self.store = store
        self.disconnect = disconnect
        self.logger = logger
    }

    func start() {
        updateBackgroundActivity()
        applyAll(reason: "app-start")
    }

    func updateBackgroundActivity() {
        let shouldMonitor = hasBackgroundDisplayWork()
        if shouldMonitor && !isMonitoringDisplayChanges {
            startMonitoringDisplayChanges()
        } else if !shouldMonitor && isMonitoringDisplayChanges {
            stopMonitoringDisplayChanges()
        }
    }

    func stop() {
        stopMonitoringDisplayChanges()
    }

    private func startMonitoringDisplayChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        isMonitoringDisplayChanges = true
    }

    private func stopMonitoringDisplayChanges() {
        queue.async { [weak self] in
            self?.pendingDisplayChangeWorkItem?.cancel()
            self?.pendingDisplayChangeWorkItem = nil
        }
        guard isMonitoringDisplayChanges else {
            return
        }
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        NotificationCenter.default.removeObserver(self)
        isMonitoringDisplayChanges = false
    }

    func applyAll(reason: String) {
        guard hasBackgroundDisplayWork() else {
            return
        }
        let localized = localizedReason(reason)
        queue.async { [weak self] in
            guard let self else { return }
            guard self.hasBackgroundDisplayWork() else { return }
            self.disconnect.applyDesiredDisplayStates(store: self.store, reason: localized)
            self.logger.info("显示器自动化检查完成，触发来源：\(localized)")
            self.onChange?()
        }
    }

    @objc private func handleWake() {
        applyAll(reason: "wake")
    }

    fileprivate func handleDisplayReconfiguration(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard hasBackgroundDisplayWork() else {
            return
        }
        if flags.contains(.addFlag) || flags.contains(.removeFlag) || flags.contains(.setModeFlag) || flags.contains(.enabledFlag) || flags.contains(.disabledFlag) {
            queue.async { [weak self] in
                self?.debounceDisplayChange()
            }
        }
    }

    private func debounceDisplayChange() {
        guard hasBackgroundDisplayWork() else {
            return
        }
        pendingDisplayChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyAll(reason: "display-change")
        }
        pendingDisplayChangeWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func hasBackgroundDisplayWork() -> Bool {
        store.profiles.contains { disconnect.desiredCloseEnabled(profile: $0) } || !store.pendingReconnects.isEmpty
    }

    private func localizedReason(_ reason: String) -> String {
        switch reason {
        case "app-start":
            return "应用启动"
        case "wake":
            return "系统唤醒"
        case "display-change":
            return "显示器变化"
        case "manual":
            return "手动操作"
        case "manual-all":
            return "手动全部应用"
        case "reconnect":
            return "重新连接"
        case "pending-already-connected":
            return "启动恢复"
        default:
            return reason
        }
    }
}

private func displayReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else {
        return
    }
    let controller = Unmanaged<AutomationController>.fromOpaque(userInfo).takeUnretainedValue()
    controller.handleDisplayReconfiguration(display: display, flags: flags)
}
