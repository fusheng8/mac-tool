import DDCBackend
import Foundation

enum SoftDisconnectError: LocalizedError {
    case profileDisabled
    case noMatchingDisplay
    case notEnoughActiveDisplays
    case allDisplaysWouldBeClosed
    case builtInDisplayBlocked
    case missingRuntimeDisplayID
    case noBuiltInDisplay
    case backendFailed(String)
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
        case .stateVerificationFailed(let message):
            return message
        }
    }
}

final class SoftDisconnectController {
    private let detector: DisplayDetector

    init(detector: DisplayDetector) {
        self.detector = detector
    }

    func validateCanDisconnect(profile: DisplayProfile, allProfiles: [DisplayProfile]) throws -> DisplaySnapshot {
        guard profile.disconnect.enabled, profile.disconnect.allowSoftDisconnect else {
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
        guard leavesAtLeastOneDisplayAfterClosing(profile: profile, allProfiles: allProfiles) else {
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
        store.rememberDisplays(detector.onlineDisplays())
        forceAllDisplaysOpen(store: store, reason: reason)
        if detector.activeDisplayCount() == 0 {
            AppLogger.shared.error("恢复显示器默认状态后仍未检测到可用亮屏，触发来源：\(reason)。")
        }
    }

    func reconnect(profile: DisplayProfile, fallbackDisplay: DisplaySnapshot? = nil) throws {
        guard let display = fallbackDisplay ?? detector.findDisplay(for: profile) else {
            throw SoftDisconnectError.noMatchingDisplay
        }
        guard display.runtimeDisplayID != 0 else {
            throw SoftDisconnectError.missingRuntimeDisplayID
        }
        try setDisplay(display, enabled: true, verificationProfile: profile)
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
        profile.disconnect.enabled && profile.disconnect.allowSoftDisconnect
    }

    private func applyConfiguredDisconnects(store: ProfileStore, reason: String) {
        for profile in store.profiles where desiredCloseEnabled(profile: profile) {
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
                store.rememberDisplays([display])
                AppLogger.shared.info("\(profile.name) 已按用户设置关闭，触发来源：\(reason)。")
            } catch {
                AppLogger.shared.error("\(profile.name) 按用户设置关闭失败，触发来源：\(reason)：\(error.localizedDescription)")
            }
        }
    }

    private func leavesAtLeastOneDisplayAfterClosing(profile: DisplayProfile, allProfiles: [DisplayProfile]) -> Bool {
        let displays = detector.onlineDisplays().filter(\.isActive)
        guard !displays.isEmpty else {
            return false
        }

        var profiles = allProfiles.filter { $0.id != profile.id }
        profiles.append(profile)
        let idsToClose = runtimeDisplayIDsToClose(from: profiles)
        return displays.contains { !idsToClose.contains($0.runtimeDisplayID) }
    }

    private func openBuiltInDisplayIfNeeded(profile: DisplayProfile, allProfiles: [DisplayProfile]) throws {
        guard !leavesAtLeastOneDisplayAfterClosing(profile: profile, allProfiles: allProfiles) else {
            return
        }
        try enableBuiltInDisplay()
        Thread.sleep(forTimeInterval: 0.35)
        guard leavesAtLeastOneDisplayAfterClosing(profile: profile, allProfiles: allProfiles) else {
            throw SoftDisconnectError.allDisplaysWouldBeClosed
        }
    }

    private func displaySafetyNeedsForcedOpen(profiles: [DisplayProfile]) -> Bool {
        let displays = detector.onlineDisplays().filter(\.isActive)
        if displays.isEmpty {
            return true
        }
        let idsToClose = runtimeDisplayIDsToClose(from: profiles)
        guard !idsToClose.isEmpty else {
            return false
        }
        return displays.allSatisfy { idsToClose.contains($0.runtimeDisplayID) }
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
            let status = DCLSetDisplayEnabled(display.runtimeDisplayID, true)
            if status == DCLStatusOK {
                AppLogger.shared.error("已强制打开显示器 \(display.displayName)，触发来源：\(reason)。")
            } else {
                AppLogger.shared.error("强制打开显示器 \(display.displayName) 失败，触发来源：\(reason)：\(String(cString: DCLStatusDescription(status)))")
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
        let status = DCLSetDisplayEnabled(builtIn.runtimeDisplayID, true)
        guard status == DCLStatusOK else {
            throw SoftDisconnectError.backendFailed(String(cString: DCLStatusDescription(status)))
        }
    }

    private func setDisplay(_ display: DisplaySnapshot, enabled: Bool, verificationProfile profile: DisplayProfile) throws {
        var lastStatus = DCLStatusOK
        for attempt in 1...3 {
            lastStatus = DCLSetDisplayEnabled(display.runtimeDisplayID, enabled)
            guard lastStatus == DCLStatusOK else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            Thread.sleep(forTimeInterval: 0.45)
            if displayStateMatches(display: display, profile: profile, enabled: enabled) {
                return
            }
            AppLogger.shared.error("\(profile.name) 显示器\(enabled ? "打开" : "关闭")状态验证未通过，第 \(attempt) 次重试")
        }

        if lastStatus != DCLStatusOK {
            throw SoftDisconnectError.backendFailed(String(cString: DCLStatusDescription(lastStatus)))
        }
        throw SoftDisconnectError.stateVerificationFailed(
            "系统已接受\(enabled ? "打开" : "关闭")请求，但扫描结果显示这台显示器仍未进入目标状态。"
        )
    }

    private func displayStateMatches(display: DisplaySnapshot, profile: DisplayProfile, enabled: Bool) -> Bool {
        let liveDisplay = detector.findDisplay(for: profile)
            ?? detector.onlineDisplays().first { $0.runtimeDisplayID == display.runtimeDisplayID }
        if enabled {
            return liveDisplay?.isActive == true
        }
        return liveDisplay == nil || liveDisplay?.isActive == false
    }

    private func runtimeDisplayIDsToClose(from profiles: [DisplayProfile]) -> Set<UInt32> {
        var ids = Set<UInt32>()
        for profile in profiles where desiredCloseEnabled(profile: profile) {
            if let display = detector.findDisplay(for: profile), display.runtimeDisplayID != 0 {
                ids.insert(display.runtimeDisplayID)
            }
        }
        return ids
    }

    private func sameRuntimeOrStableIdentity(_ lhs: DisplaySnapshot, _ rhs: DisplaySnapshot) -> Bool {
        if lhs.runtimeDisplayID != 0 && rhs.runtimeDisplayID != 0 {
            return lhs.runtimeDisplayID == rhs.runtimeDisplayID
        }
        return lhs.hasSameStableIdentity(as: rhs)
    }
}
