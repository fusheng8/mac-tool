import Foundation

final class RecoveryCountdownRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [String: DispatchSourceTimer] = [:]
    private var deadlines: [String: Date] = [:]
    private var tokens: [String: UUID] = [:]

    func install(profileID: String, deadline: Date, timer: DispatchSourceTimer, token: UUID) -> DispatchSourceTimer? {
        lock.lock()
        defer { lock.unlock() }
        timer.resume()
        let previous = timers.updateValue(timer, forKey: profileID)
        deadlines[profileID] = deadline
        tokens[profileID] = token
        return previous
    }

    func isCurrent(profileID: String, token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokens[profileID] == token
    }

    func remove(profileID: String) -> DispatchSourceTimer? {
        lock.lock()
        defer { lock.unlock() }
        deadlines.removeValue(forKey: profileID)
        tokens.removeValue(forKey: profileID)
        return timers.removeValue(forKey: profileID)
    }

    func deadline(profileID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return deadlines[profileID]
    }

    func removeAll() -> [DispatchSourceTimer] {
        lock.lock()
        defer { lock.unlock() }
        let active = Array(timers.values)
        timers.removeAll()
        deadlines.removeAll()
        tokens.removeAll()
        return active
    }
}

final class RecoveryManager {
    private let store: ProfileStore
    private let disconnect: SoftDisconnectController
    private let automation: AutomationController
    private let statuses: RuntimeStatusStore
    private let logger: AppLogger
    private let countdowns = RecoveryCountdownRegistry()
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

    deinit {
        countdowns.removeAll().forEach { $0.cancel() }
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
        let deadline = Date().addingTimeInterval(TimeInterval(delay))
        statuses.set(.reconnectCountdown, profileId: profile.id, message: "\(delay) 秒")
        logger.info("\(profile.name) 已开始重新连接倒计时")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let timerToken = UUID()
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.countdowns.isCurrent(profileID: profile.id, token: timerToken) else { return }
            let remaining = self.remainingSeconds(profileId: profile.id) ?? 0
            if remaining <= 0 {
                self.attemptReconnect(profile: profile, maxAttempts: 6)
            } else {
                self.statuses.set(.reconnectCountdown, profileId: profile.id, message: "\(remaining) 秒")
                DispatchQueue.main.async { self.onCountdownTick?() }
            }
        }
        countdowns.install(profileID: profile.id, deadline: deadline, timer: timer, token: timerToken)?.cancel()
        onCountdownTick?()
    }

    func cancelCountdown(profileId: String) {
        countdowns.remove(profileID: profileId)?.cancel()
        store.clearPendingReconnect(profileId: profileId)
        statuses.set(.disconnected, profileId: profileId, message: "已取消自动恢复")
        onCountdownTick?()
    }

    func remainingSeconds(profileId: String) -> Int? {
        guard let deadline = countdowns.deadline(profileID: profileId) else {
            return nil
        }
        return max(0, Int(ceil(deadline.timeIntervalSinceNow)))
    }

    func attemptReconnect(profile: DisplayProfile, maxAttempts: Int = 1) {
        countdowns.remove(profileID: profile.id)?.cancel()
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
