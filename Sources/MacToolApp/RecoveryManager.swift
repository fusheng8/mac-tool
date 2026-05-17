import Foundation

final class RecoveryManager {
    private let store: ProfileStore
    private let disconnect: SoftDisconnectController
    private let automation: AutomationController
    private let statuses: RuntimeStatusStore
    private let logger: AppLogger
    private var timers: [String: DispatchSourceTimer] = [:]
    private var deadlines: [String: Date] = [:]
    private let queue = DispatchQueue(label: "mac-tool.Recovery")

    var onCountdownTick: (() -> Void)?

    init(
        store: ProfileStore,
        disconnect: SoftDisconnectController,
        automation: AutomationController,
        statuses: RuntimeStatusStore,
        logger: AppLogger = .shared
    ) {
        self.store = store
        self.disconnect = disconnect
        self.automation = automation
        self.statuses = statuses
        self.logger = logger
    }

    func recoverPendingOnLaunch() {
        guard !store.pendingReconnects.isEmpty else {
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            for pending in self.store.pendingReconnects {
                guard let profile = self.store.profiles.first(where: { $0.id == pending.profileId }) else {
                    self.store.clearPendingReconnect(profileId: pending.profileId)
                    continue
                }
                if !self.disconnect.isDisconnected(profile: profile) {
                    self.store.clearPendingReconnect(profileId: profile.id)
                } else if profile.disconnect.autoReconnect && pending.autoReconnect {
                    self.attemptReconnect(profile: profile, maxAttempts: 6)
                } else {
                    self.statuses.set(.disconnected, profileId: profile.id, message: "已断开")
                }
            }
        }
    }

    func beginCountdown(profile: DisplayProfile, display: DisplaySnapshot) {
        guard profile.disconnect.autoReconnect else {
            return
        }
        let pending = PendingReconnect(
            profileId: profile.id,
            displaySnapshot: display,
            reason: "user_requested_disconnect",
            autoReconnect: true
        )
        store.addPendingReconnect(pending)
        let delay = max(1, profile.disconnect.autoReconnectDelaySeconds)
        deadlines[profile.id] = Date().addingTimeInterval(TimeInterval(delay))
        statuses.set(.reconnectCountdown, profileId: profile.id, message: "\(delay) 秒")
        logger.info("\(profile.name) 已开始重新连接倒计时")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let remaining = self.remainingSeconds(profileId: profile.id) ?? 0
            if remaining <= 0 {
                self.attemptReconnect(profile: profile, maxAttempts: 6)
            } else {
                self.statuses.set(.reconnectCountdown, profileId: profile.id, message: "\(remaining) 秒")
                DispatchQueue.main.async { self.onCountdownTick?() }
            }
        }
        timers[profile.id]?.cancel()
        timers[profile.id] = timer
        timer.resume()
        onCountdownTick?()
    }

    func cancelCountdown(profileId: String) {
        timers[profileId]?.cancel()
        timers.removeValue(forKey: profileId)
        deadlines.removeValue(forKey: profileId)
        store.clearPendingReconnect(profileId: profileId)
        statuses.set(.disconnected, profileId: profileId, message: "已取消自动恢复")
        onCountdownTick?()
    }

    func remainingSeconds(profileId: String) -> Int? {
        guard let deadline = deadlines[profileId] else {
            return nil
        }
        return max(0, Int(ceil(deadline.timeIntervalSinceNow)))
    }

    func attemptReconnect(profile: DisplayProfile, maxAttempts: Int = 1) {
        timers[profile.id]?.cancel()
        timers.removeValue(forKey: profile.id)
        deadlines.removeValue(forKey: profile.id)
        statuses.set(.reconnecting, profileId: profile.id)
        onCountdownTick?()

        queue.async { [weak self] in
            guard let self else { return }
            for attempt in 1...maxAttempts {
                do {
                    let fallbackDisplay = self.store.pendingReconnects.first { $0.profileId == profile.id }?.displaySnapshot
                    try self.disconnect.reconnect(profile: profile, fallbackDisplay: fallbackDisplay)
                    self.store.clearPendingReconnect(profileId: profile.id)
                    self.statuses.set(.detected, profileId: profile.id, message: "已重新连接")
                    self.logger.info("\(profile.name) 重新连接成功")
                    DispatchQueue.main.async { self.onCountdownTick?() }
                    return
                } catch {
                    self.statuses.set(.reconnectFailed, profileId: profile.id, message: error.localizedDescription)
                    self.logger.error("\(profile.name) 重新连接失败，第 \(attempt) 次尝试：\(error.localizedDescription)")
                    DispatchQueue.main.async { self.onCountdownTick?() }
                    Thread.sleep(forTimeInterval: 5)
                }
            }
        }
    }
}
