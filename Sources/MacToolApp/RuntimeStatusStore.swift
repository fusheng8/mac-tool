import Foundation

final class RuntimeStatusStore {
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private var statuses: [String: ProfileRuntimeStatus] = [:]

    func status(for profileId: String) -> ProfileRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        return statuses[profileId] ?? .unknown
    }

    func set(_ status: ManagedDisplayStatus, profileId: String, message: String = "") {
        lock.lock()
        statuses[profileId] = ProfileRuntimeStatus(status: status, message: message, updatedAt: Date())
        lock.unlock()
        onChange?()
    }

    func summary(profiles: [DisplayProfile], pendingReconnects: [PendingReconnect]) -> String {
        if let pending = pendingReconnects.first, let profile = profiles.first(where: { $0.id == pending.profileId }) {
            return "\(profile.name)：等待重新连接"
        }
        let enabled = profiles.filter(\.enabled)
        guard !enabled.isEmpty else {
            return "没有显示器配置"
        }
        if enabled.count == 1 {
            let profile = enabled[0]
            let status = self.status(for: profile.id)
            return "\(profile.name)：\(status.status.rawValue)"
        }
        let disconnected = enabled.filter { status(for: $0.id).status == .disconnected }.count
        return "\(enabled.count) 个配置，\(disconnected) 个已关闭"
    }
}
