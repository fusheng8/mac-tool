import Foundation
import MacToolCore

enum SoftDisconnectError: LocalizedError {
    case profileDisabled
    case noMatchingDisplay
    case notEnoughActiveDisplays
    case allDisplaysWouldBeClosed
    case builtInDisplayBlocked
    case missingRuntimeDisplayID
    case noBuiltInDisplay
    case backendFailed(String)
    case backendUnavailable(String)
    case circuitOpen(Date)
    case stateVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .profileDisabled:
            return "这个配置未启用软断开。"
        case .noMatchingDisplay:
            return "当前没有可用的匹配显示器。"
        case .notEnoughActiveDisplays:
            return "无法断开：当前没有其他可用显示器。"
        case .allDisplaysWouldBeClosed:
            return "无法关闭：当前配置会导致所有可用显示器都被关闭。"
        case .builtInDisplayBlocked:
            return "这个配置禁止断开内置显示器。取消勾选“只允许外接显示器”后才能断开内置屏。"
        case .missingRuntimeDisplayID:
            return "无法关闭：没有拿到系统显示器 ID。"
        case .noBuiltInDisplay:
            return "无法启用内置屏：当前没有扫描到 MacBook 内置显示器。"
        case .backendFailed(let message):
            return "关闭显示器失败：\(message)"
        case .backendUnavailable(let message):
            return "显示器软断开不可用：\(message)"
        case .circuitOpen(let until):
            return "显示器操作已暂停到 \(until.formatted(date: .omitted, time: .shortened))，避免持续重试。"
        case .stateVerificationFailed(let message):
            return message
        }
    }
}

final class SoftDisconnectController {
    private let detector: DisplayDetector
    private let backend: any DisplayBackend
    private weak var store: ProfileStore?
    private let stateLock = NSLock()
    private var circuitOpenUntil: [String: Date] = [:]
    private var lastBackendMutationAt: Date?

    init(
        detector: DisplayDetector,
        backend: any DisplayBackend = DCLDisplayBackend(),
        store: ProfileStore? = nil
    ) {
        self.detector = detector
        self.backend = backend
        self.store = store
    }

    var backendAvailability: (available: Bool, reason: String?) {
        (backend.isAvailable, backend.unavailableReason)
    }

    func shouldSuppressDisplayEvent(now: Date = Date()) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return DisplaySafetyPolicy.shouldSuppressEvent(lastMutation: lastBackendMutationAt, now: now)
    }

    func validateCanDisconnect(profile: DisplayProfile, allProfiles _: [DisplayProfile]) throws -> DisplaySnapshot {
        guard backend.isAvailable else {
            throw SoftDisconnectError.backendUnavailable(backend.unavailableReason ?? "当前系统不支持此能力")
        }
        guard profile.enabled, profile.disconnect.enabled, profile.disconnect.allowSoftDisconnect else {
            throw SoftDisconnectError.profileDisabled
        }
        guard let display = detector.findDisplay(for: profile) else {
            throw SoftDisconnectError.noMatchingDisplay
        }
        guard detector.activeDisplayCount() >= 2 else {
            throw SoftDisconnectError.notEnoughActiveDisplays
        }
        if profile.disconnect.externalOnly && display.isBuiltIn {
            throw SoftDisconnectError.builtInDisplayBlocked
        }
        guard display.runtimeDisplayID != 0 else {
            throw SoftDisconnectError.missingRuntimeDisplayID
        }
        guard leavesAtLeastOneActiveDisplayAfterClosing(profile: profile) else {
            throw SoftDisconnectError.allDisplaysWouldBeClosed
        }
        return display
    }

    func disconnect(
        profile: DisplayProfile,
        allProfiles: [DisplayProfile],
        beforeDisconnect: (DisplaySnapshot) -> Void = { _ in }
    ) throws -> DisplaySnapshot {
        try openBuiltInDisplayIfNeeded(profile: profile, allProfiles: allProfiles)
        let display = try validateCanDisconnect(profile: profile, allProfiles: allProfiles)
        beforeDisconnect(display)
        try setDisplay(display, enabled: false, verificationProfile: profile)
        try? store?.rememberAppDisconnectedDisplay(display.runtimeDisplayID)
        return display
    }

    func enforceDisplaySafety(store: ProfileStore, reason: String) {
        store.rememberDisplays(detector.onlineDisplays())
        guard displaySafetyNeedsForcedOpen(profiles: store.profiles) else {
            return
        }

        forceAllDisplaysOpen(store: store, reason: reason)
        if displaySafetyNeedsForcedOpen(profiles: store.profiles) {
            AppLogger.shared.error("显示器强制打开后仍未检测到可用亮屏，触发来源：\(reason)。")
        }
    }

    func applyDesiredDisplayStates(store: ProfileStore, reason: String) {
        guard store.displayAutomationAllowed else {
            AppLogger.shared.info("显示器自动化尚未获得隐私与安全确认，已跳过：\(reason)。")
            return
        }
        guard backend.isAvailable else {
            AppLogger.shared.error("显示器软断开不可用：\(backend.unavailableReason ?? "未知原因")")
            return
        }
        store.rememberDisplays(detector.onlineDisplays())

        if displaySafetyNeedsForcedOpen(profiles: store.profiles) {
            forceAllDisplaysOpen(store: store, reason: reason)
        }

        applyConfiguredDisconnects(store: store, reason: reason)
    }

    func sanitizeUnsafeStartupDisconnects(store: ProfileStore) {
        applyDesiredDisplayStates(store: store, reason: "应用启动")
    }

    func restoreDefaultDisplayState(store: ProfileStore, reason: String) {
        let ids = store.state.appDisconnectedDisplayIDs
        guard !ids.isEmpty else { return }
        let liveDisplays = detector.onlineDisplays()
        for displayID in ids {
            let rememberedDisplay = store.lastSeenDisplays.first { $0.runtimeDisplayID == displayID }
            let liveDisplay = liveDisplays.first { $0.runtimeDisplayID == displayID }
                ?? rememberedDisplay.flatMap { remembered in
                    let matches = liveDisplays.filter { $0.hasSameStableIdentity(as: remembered) }
                    return matches.count == 1 ? matches[0] : nil
                }
            if liveDisplay?.isActive == true {
                forgetDisconnectedOwnership(
                    displayIDs: [displayID, liveDisplay?.runtimeDisplayID],
                    explicitStore: store
                )
                AppLogger.shared.info(
                    "显示器 \(liveDisplay?.displayName ?? String(displayID)) 已处于打开状态，"
                        + "无需重复恢复，触发来源：\(reason)。"
                )
                continue
            }
            let currentDisplayID = liveDisplay?.runtimeDisplayID ?? displayID
            do {
                try backend.setDisplayEnabled(currentDisplayID, enabled: true)
                noteBackendMutation()
                forgetDisconnectedOwnership(
                    displayIDs: [displayID, currentDisplayID],
                    explicitStore: store
                )
                AppLogger.shared.info("已恢复本应用断开的显示器 \(currentDisplayID)，触发来源：\(reason)。")
            } catch {
                AppLogger.shared.error(
                    "恢复本应用断开的显示器 \(currentDisplayID) 失败，"
                        + "触发来源：\(reason)：\(error.localizedDescription)"
                )
            }
        }
    }

    func reconnect(profile: DisplayProfile, fallbackDisplay: DisplaySnapshot? = nil) throws {
        let liveDisplay = detector.findDisplay(for: profile)
        guard let display = liveDisplay ?? fallbackDisplay else {
            throw SoftDisconnectError.noMatchingDisplay
        }
        guard display.runtimeDisplayID != 0 else {
            throw SoftDisconnectError.missingRuntimeDisplayID
        }
        if liveDisplay?.isActive == true {
            forgetDisconnectedOwnership(displayIDs: [
                liveDisplay?.runtimeDisplayID,
                fallbackDisplay?.runtimeDisplayID
            ])
            return
        }
        try setDisplay(display, enabled: true, verificationProfile: profile)
        forgetDisconnectedOwnership(displayIDs: [
            display.runtimeDisplayID,
            fallbackDisplay?.runtimeDisplayID
        ])
    }

    func isDisconnected(profile: DisplayProfile) -> Bool {
        detector.findDisplay(for: profile)?.isActive != true
    }

    func canSafelyClose(display: DisplaySnapshot) -> Bool {
        let displays = detector.onlineDisplays().filter(\.isActive)
        guard displays.contains(where: { sameRuntimeOrStableIdentity($0, display) }) else {
            return false
        }
        return displays.contains { !sameRuntimeOrStableIdentity($0, display) }
    }

    func desiredCloseEnabled(profile: DisplayProfile) -> Bool {
        DisplaySafetyPolicy.isAutomationEligible(
            profileEnabled: profile.enabled,
            disconnectEnabled: profile.disconnect.enabled,
            allowSoftDisconnect: profile.disconnect.allowSoftDisconnect
        )
    }

    private func applyConfiguredDisconnects(store: ProfileStore, reason: String) {
        for profile in store.profiles where desiredCloseEnabled(profile: profile) {
            guard !isCircuitOpen(profileID: profile.id) else { continue }
            guard let display = detector.findDisplay(for: profile), display.runtimeDisplayID != 0 else {
                continue
            }
            guard display.isActive else {
                continue
            }
            guard canSafelyClose(display: display) else {
                AppLogger.shared.info("\(profile.name) 保持打开，触发来源：\(reason)：关闭后没有其他可用显示器。")
                continue
            }

            do {
                try setDisplay(display, enabled: false, verificationProfile: profile)
                try? store.rememberAppDisconnectedDisplay(display.runtimeDisplayID)
                store.rememberDisplays([display])
                AppLogger.shared.info("\(profile.name) 已按用户设置关闭，触发来源：\(reason)。")
            } catch {
                openCircuit(profileID: profile.id)
                AppLogger.shared.error("\(profile.name) 按用户设置关闭失败，触发来源：\(reason)：\(error.localizedDescription)")
            }
        }
    }

    private func leavesAtLeastOneActiveDisplayAfterClosing(profile: DisplayProfile) -> Bool {
        guard let display = detector.findDisplay(for: profile) else { return false }
        return canSafelyClose(display: display)
    }

    private func openBuiltInDisplayIfNeeded(profile: DisplayProfile, allProfiles _: [DisplayProfile]) throws {
        guard !leavesAtLeastOneActiveDisplayAfterClosing(profile: profile) else {
            return
        }
        try enableBuiltInDisplay()
        Thread.sleep(forTimeInterval: 0.35)
        guard leavesAtLeastOneActiveDisplayAfterClosing(profile: profile) else {
            throw SoftDisconnectError.allDisplaysWouldBeClosed
        }
    }

    private func displaySafetyNeedsForcedOpen(profiles _: [DisplayProfile]) -> Bool {
        !detector.onlineDisplays().contains(where: \.isActive)
    }

    private func forceAllDisplaysOpen(store: ProfileStore, reason: String) {
        enableKnownDisplays(store: store, reason: reason)
        Thread.sleep(forTimeInterval: 0.45)
    }

    private func enableKnownDisplays(store: ProfileStore, reason: String) {
        let displays = uniqueDisplays(detector.onlineDisplays() + store.lastSeenDisplays)
            .filter { $0.runtimeDisplayID != 0 && !$0.isVirtualPlaceholder }
        guard !displays.isEmpty else {
            AppLogger.shared.error("无法强制打开显示器，触发来源：\(reason)：系统当前没有返回可用显示器。")
            return
        }

        for display in displays {
            if display.isActive {
                continue
            }
            do {
                try backend.setDisplayEnabled(display.runtimeDisplayID, enabled: true)
                noteBackendMutation()
                AppLogger.shared.info("已强制打开显示器 \(display.displayName)，触发来源：\(reason)。")
            } catch {
                AppLogger.shared.error("强制打开显示器 \(display.displayName) 失败，触发来源：\(reason)：\(error.localizedDescription)")
            }
        }
    }

    private func uniqueDisplays(_ displays: [DisplaySnapshot]) -> [DisplaySnapshot] {
        var unique: [DisplaySnapshot] = []
        for display in displays where !unique.contains(where: { $0.hasSameStableIdentity(as: display) }) {
            unique.append(display)
        }
        return unique
    }

    private func enableBuiltInDisplay() throws {
        guard let builtIn = detector.onlineDisplays().first(where: \.isBuiltIn) else {
            throw SoftDisconnectError.noBuiltInDisplay
        }
        guard builtIn.runtimeDisplayID != 0 else {
            throw SoftDisconnectError.missingRuntimeDisplayID
        }
        if builtIn.isActive {
            return
        }
        try backend.setDisplayEnabled(builtIn.runtimeDisplayID, enabled: true)
        noteBackendMutation()
    }

    private func setDisplay(_ display: DisplaySnapshot, enabled: Bool, verificationProfile profile: DisplayProfile) throws {
        for attempt in 1...DisplaySafetyPolicy.maximumAttempts {
            do {
                try backend.setDisplayEnabled(display.runtimeDisplayID, enabled: enabled)
                noteBackendMutation()
            } catch {
                if attempt == DisplaySafetyPolicy.maximumAttempts { throw error }
                Thread.sleep(forTimeInterval: DisplaySafetyPolicy.retryDelay(afterAttempt: attempt))
                continue
            }
            Thread.sleep(forTimeInterval: 0.45)
            if displayStateMatches(display: display, profile: profile, enabled: enabled) {
                return
            }
            AppLogger.shared.error("\(profile.name) 显示器\(enabled ? "打开" : "关闭")状态验证未通过，第 \(attempt) 次重试")
        }

        throw SoftDisconnectError.stateVerificationFailed(
            "系统已接受\(enabled ? "打开" : "关闭")请求，但扫描结果显示这台显示器仍未进入目标状态。"
        )
    }

    private func noteBackendMutation() {
        stateLock.lock()
        lastBackendMutationAt = Date()
        stateLock.unlock()
    }

    private func forgetDisconnectedOwnership(
        displayIDs: [UInt32?],
        explicitStore: ProfileStore? = nil
    ) {
        let targetStore = explicitStore ?? store
        for displayID in Set(displayIDs.compactMap { $0 }.filter { $0 != 0 }) {
            try? targetStore?.forgetAppDisconnectedDisplay(displayID)
        }
    }

    private func isCircuitOpen(profileID: String, now: Date = Date()) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let until = circuitOpenUntil[profileID] else { return false }
        if until <= now {
            circuitOpenUntil.removeValue(forKey: profileID)
            return false
        }
        return true
    }

    private func openCircuit(profileID: String) {
        stateLock.lock()
        circuitOpenUntil[profileID] = DisplaySafetyPolicy.circuitOpenUntil(failureDate: Date())
        stateLock.unlock()
    }

    private func displayStateMatches(display: DisplaySnapshot, profile: DisplayProfile, enabled: Bool) -> Bool {
        let liveDisplay = detector.findDisplay(for: profile)
            ?? detector.onlineDisplays().first { $0.runtimeDisplayID == display.runtimeDisplayID }
        if enabled {
            return liveDisplay?.isActive == true
        }
        return liveDisplay == nil || liveDisplay?.isActive == false
    }

    private func sameRuntimeOrStableIdentity(_ lhs: DisplaySnapshot, _ rhs: DisplaySnapshot) -> Bool {
        if lhs.runtimeDisplayID != 0 && rhs.runtimeDisplayID != 0 {
            return lhs.runtimeDisplayID == rhs.runtimeDisplayID
        }
        return lhs.hasSameStableIdentity(as: rhs)
    }
}
