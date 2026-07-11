import Foundation
import MacToolCore

final class ProfileStore: @unchecked Sendable {
    static let onboardingVersion = 1
    static let privacyNoticeVersion = 1
    static let displayConsentVersion = 1

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSRecursiveLock()
    private let configURL: URL
    private let stateURL: URL
    private let finderSyncConfigURL: URL?

    private var storedConfig: AppConfig
    private var storedState: AppState

    let isExistingInstallation: Bool
    private(set) var recoveryNotice: String?
    private(set) var lastPersistenceError: Error?
    private(set) var lastFinderSyncError: Error?

    init(
        configURL: URL = AppPaths.configURL,
        stateURL: URL = AppPaths.stateURL,
        finderSyncConfigURL: URL? = AppPaths.finderSyncConfigURL
    ) {
        self.configURL = configURL
        self.stateURL = stateURL
        self.finderSyncConfigURL = finderSyncConfigURL
        isExistingInstallation = FileManager.default.fileExists(atPath: configURL.path)

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        do {
            try Self.ensureParentDirectory(for: configURL)
            try Self.ensureParentDirectory(for: stateURL)
        } catch {
            lastPersistenceError = error
        }
        if let finderSyncConfigURL {
            do {
                try Self.ensureParentDirectory(for: finderSyncConfigURL)
            } catch {
                lastFinderSyncError = error
            }
        }

        let loadedConfig: AppConfig
        do {
            loadedConfig = try Self.load(AppConfig.self, from: configURL, decoder: decoder) ?? .defaultValue
        } catch {
            let backupURL = Self.backupCorruptFile(at: configURL)
            recoveryNotice = backupURL.map { "配置文件损坏，已保存到 \($0.lastPathComponent)，并恢复为安全默认值。" }
                ?? "配置文件损坏，已恢复为安全默认值；损坏副本保存失败。"
            loadedConfig = .defaultValue
            lastPersistenceError = error
        }

        let normalizedConfig = loadedConfig.normalized()
        let requiresConfigMigration = ConfigurationRecoveryPolicy.requiresMigration(
            schemaVersion: loadedConfig.schemaVersion,
            currentVersion: AppConfig.currentSchemaVersion
        )
        storedConfig = normalizedConfig

        do {
            storedState = try Self.load(AppState.self, from: stateURL, decoder: decoder) ?? .empty
        } catch {
            let backupURL = Self.backupCorruptFile(at: stateURL)
            let stateNotice = backupURL.map { "运行状态损坏，已保存到 \($0.lastPathComponent)，并重置为安全状态。" }
                ?? "运行状态损坏，已重置为安全状态。"
            recoveryNotice = [recoveryNotice, stateNotice].compactMap { $0 }.joined(separator: "\n")
            storedState = .empty
            lastPersistenceError = error
        }

        // 0.2.0 升级必须重新确认显示器自动化；新 schema 已确认的用户不受影响。
        if requiresConfigMigration {
            storedState.displayAutomationConsentVersion = 0
            storedState.displayAutomationApproved = false
        }

        do {
            if !isExistingInstallation || requiresConfigMigration || recoveryNotice != nil {
                try saveConfig()
            }
            if !FileManager.default.fileExists(atPath: stateURL.path) || requiresConfigMigration || recoveryNotice != nil {
                try saveState()
            }
        } catch {
            lastPersistenceError = error
        }
        synchronizeFinderConfigBestEffort()
    }

    var config: AppConfig { withLock { storedConfig } }
    var state: AppState { withLock { storedState } }

    var profiles: [DisplayProfile] {
        get { withLock { storedConfig.profiles } }
        set { persistBestEffort { $0.profiles = newValue } }
    }

    var clipboard: ClipboardConfig {
        get { withLock { storedConfig.clipboard } }
        set { persistBestEffort { $0.clipboard = newValue } }
    }

    var archive: ArchiveConfig {
        get { withLock { storedConfig.archive } }
        set { persistBestEffort { $0.archive = newValue } }
    }

    var contextMenu: ContextMenuConfig {
        get { withLock { storedConfig.contextMenu.normalized() } }
        set { persistBestEffort { $0.contextMenu = newValue.normalized() } }
    }

    var pendingReconnects: [PendingReconnect] { withLock { storedState.pendingReconnects } }
    var lastSeenDisplays: [DisplaySnapshot] { withLock { storedState.lastSeenDisplays } }
    var backgroundTasksAllowed: Bool {
        withLock {
            storedState.onboardingVersion >= Self.onboardingVersion
                && storedState.privacyNoticeVersion >= Self.privacyNoticeVersion
        }
    }
    var displayAutomationAllowed: Bool {
        withLock {
            backgroundTasksAllowed
                && storedState.displayAutomationConsentVersion >= Self.displayConsentVersion
                && storedState.displayAutomationApproved
        }
    }

    func updateConfig(_ mutation: (inout AppConfig) throws -> Void) throws {
        try withLock {
            var candidate = storedConfig
            try mutation(&candidate)
            try commitConfig(candidate)
        }
    }

    func updateState(_ mutation: (inout AppState) throws -> Void) throws {
        try withLock {
            var candidate = storedState
            try mutation(&candidate)
            let data = try encoder.encode(candidate)
            try Self.secureAtomicWrite(data, to: stateURL)
            storedState = candidate
            lastPersistenceError = nil
        }
    }

    func completeOnboarding(clipboardEnabled: Bool, displayAutomationApproved: Bool) throws {
        try updateConfig { $0.clipboard.enabled = clipboardEnabled }
        try updateState {
            $0.onboardingVersion = Self.onboardingVersion
            $0.privacyNoticeVersion = Self.privacyNoticeVersion
            $0.displayAutomationConsentVersion = Self.displayConsentVersion
            $0.displayAutomationApproved = displayAutomationApproved
        }
    }

    @discardableResult
    func markApplicationStarted() throws -> Bool {
        let wasUnclean = withLock { !storedState.lastCleanShutdown }
        try updateState { $0.lastCleanShutdown = false }
        return wasUnclean
    }

    func markApplicationStoppedCleanly() throws {
        try updateState { $0.lastCleanShutdown = true }
    }

    func rememberAppDisconnectedDisplay(_ displayID: UInt32) throws {
        try updateState {
            if !$0.appDisconnectedDisplayIDs.contains(displayID) {
                $0.appDisconnectedDisplayIDs.append(displayID)
            }
        }
    }

    func forgetAppDisconnectedDisplay(_ displayID: UInt32) throws {
        try updateState { $0.appDisconnectedDisplayIDs.removeAll { $0 == displayID } }
    }

    func updateProfile(_ profile: DisplayProfile) {
        persistBestEffort {
            if let index = $0.profiles.firstIndex(where: { $0.id == profile.id }) {
                $0.profiles[index] = profile
            } else {
                $0.profiles.append(profile)
            }
        }
    }

    func deleteProfile(id: String) {
        do {
            try updateConfig { $0.profiles.removeAll { $0.id == id } }
            try updateState { $0.pendingReconnects.removeAll { $0.profileId == id } }
        } catch { record(error) }
    }

    func addPendingReconnect(_ pending: PendingReconnect) {
        persistStateBestEffort {
            $0.pendingReconnects.removeAll { $0.profileId == pending.profileId }
            $0.pendingReconnects.append(pending)
        }
    }

    func clearPendingReconnect(profileId: String) {
        persistStateBestEffort { $0.pendingReconnects.removeAll { $0.profileId == profileId } }
    }

    func clearAllPendingReconnects() {
        guard !pendingReconnects.isEmpty else { return }
        persistStateBestEffort { $0.pendingReconnects.removeAll() }
    }

    func rememberDisplays(_ displays: [DisplaySnapshot]) {
        persistStateBestEffort { state in
            for display in displays where display.runtimeDisplayID != 0 && !display.isVirtualPlaceholder {
                if let index = state.lastSeenDisplays.firstIndex(where: { $0.hasSameStableIdentity(as: display) }) {
                    state.lastSeenDisplays[index] = display
                } else {
                    state.lastSeenDisplays.append(display)
                }
            }
        }
    }

    func reload() {
        do {
            if let config = try Self.load(AppConfig.self, from: configURL, decoder: decoder) {
                withLock {
                    storedConfig = config.normalized()
                    synchronizeFinderConfigBestEffortLocked()
                }
            }
            if let state = try Self.load(AppState.self, from: stateURL, decoder: decoder) {
                withLock { storedState = state }
            }
        } catch { record(error) }
    }

    func exportConfig(to url: URL) throws {
        let data = try withLock { try encoder.encode(storedConfig) }
        try Self.secureAtomicWrite(data, to: url)
    }

    func importConfig(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let importedConfig = try decoder.decode(AppConfig.self, from: data)
        guard ConfigurationRecoveryPolicy.canImport(
            schemaVersion: importedConfig.schemaVersion,
            currentVersion: AppConfig.currentSchemaVersion
        ) else {
            throw ProfileStoreError.unsupportedSchema(importedConfig.schemaVersion)
        }
        try updateConfig { $0 = importedConfig.normalized() }
    }

    func backupConfigToICloud() throws -> URL {
        guard let directory = AppPaths.iCloudBackupDirectory,
              let backupURL = AppPaths.iCloudConfigBackupURL else {
            throw ProfileStoreError.iCloudUnavailable
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let envelope = ConfigurationBackupEnvelope(
            version: AppConfig.currentSchemaVersion,
            createdAt: Date(),
            config: config
        )
        let data = try encoder.encode(envelope)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: backupURL, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try Self.secureAtomicWrite(data, to: coordinatedURL) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        return backupURL
    }

    func syncConfigFromICloud() throws {
        guard let backupURL = AppPaths.iCloudConfigBackupURL else { throw ProfileStoreError.iCloudUnavailable }
        guard FileManager.default.fileExists(atPath: backupURL.path) else { throw ProfileStoreError.iCloudBackupMissing }
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: backupURL, options: [], error: &coordinationError) { coordinatedURL in
            readResult = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let data = try readResult?.get() else { throw ProfileStoreError.iCloudBackupMissing }
        let envelope = try decoder.decode(ConfigurationBackupEnvelope.self, from: data)
        guard envelope.version <= AppConfig.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedSchema(envelope.version)
        }
        guard ConfigurationRecoveryPolicy.canImport(
            schemaVersion: envelope.config.schemaVersion,
            currentVersion: AppConfig.currentSchemaVersion
        ) else {
            throw ProfileStoreError.unsupportedSchema(envelope.config.schemaVersion)
        }
        try updateConfig { $0 = envelope.config.normalized() }
    }

    func iCloudBackupDifferenceSummary() throws -> String {
        guard let backupURL = AppPaths.iCloudConfigBackupURL,
              FileManager.default.fileExists(atPath: backupURL.path) else {
            throw ProfileStoreError.iCloudBackupMissing
        }
        let envelope = try decoder.decode(ConfigurationBackupEnvelope.self, from: Data(contentsOf: backupURL))
        let current = config
        let formatter = ISO8601DateFormatter()
        return """
        备份时间：\(formatter.string(from: envelope.createdAt))
        显示器配置：当前 \(current.profiles.count) 项 → 备份 \(envelope.config.profiles.count) 项
        剪贴板：\(current.clipboard.enabled ? "开启" : "关闭") / \(current.clipboard.retentionDays) 天 → \(envelope.config.clipboard.enabled ? "开启" : "关闭") / \(envelope.config.clipboard.retentionDays) 天
        Finder 菜单：\(current.contextMenu.enabled ? "开启" : "关闭") → \(envelope.config.contextMenu.enabled ? "开启" : "关闭")
        """
    }

    func saveConfig() throws {
        try withLock {
            try commitConfig(storedConfig)
        }
    }

    func saveState() throws {
        try withLock { try Self.secureAtomicWrite(encoder.encode(storedState), to: stateURL) }
    }

    private func persistBestEffort(_ mutation: (inout AppConfig) -> Void) {
        do { try updateConfig(mutation) } catch { record(error) }
    }

    private func persistStateBestEffort(_ mutation: (inout AppState) -> Void) {
        do { try updateState(mutation) } catch { record(error) }
    }

    private func record(_ error: Error) {
        withLock { lastPersistenceError = error }
        AppLogger.shared.error("配置保存失败：\(error.localizedDescription)")
    }

    private func commitConfig(_ candidate: AppConfig) throws {
        let normalized = candidate.normalized()
        let data = try encoder.encode(normalized)
        do {
            try Self.secureAtomicWrite(data, to: configURL)
        } catch {
            lastPersistenceError = error
            throw error
        }
        storedConfig = normalized
        lastPersistenceError = nil
        synchronizeFinderConfigBestEffortLocked(data: data)
    }

    private func synchronizeFinderConfigBestEffort() {
        withLock { synchronizeFinderConfigBestEffortLocked() }
    }

    private func synchronizeFinderConfigBestEffortLocked(data: Data? = nil) {
        guard let finderSyncConfigURL else {
            lastFinderSyncError = nil
            return
        }
        do {
            let payload: Data
            if let data {
                payload = data
            } else {
                payload = try encoder.encode(storedConfig.normalized())
            }
            try Self.secureAtomicWrite(payload, to: finderSyncConfigURL)
            lastFinderSyncError = nil
        } catch {
            lastFinderSyncError = error
            AppLogger.shared.error("Finder 配置副本同步失败，将在下次保存或启动时重试：\(error.localizedDescription)")
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private static func ensureParentDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func secureAtomicWrite(_ data: Data, to url: URL) throws {
        try ensureParentDirectory(for: url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func backupCorruptFile(at url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(formatter.string(from: Date()))"
        )
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            return backupURL
        } catch {
            return nil
        }
    }
}

private struct ConfigurationBackupEnvelope: Codable {
    let version: Int
    let createdAt: Date
    let config: AppConfig
}

enum ProfileStoreError: LocalizedError {
    case iCloudUnavailable
    case iCloudBackupMissing
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "当前无法访问 iCloud Drive。请确认系统已登录 Apple ID，并已启用 iCloud Drive。"
        case .iCloudBackupMissing:
            return "没有找到 iCloud 配置备份。请先在这台或另一台 Mac 上执行备份。"
        case .unsupportedSchema(let version):
            return "备份格式版本 \(version) 高于当前应用支持的版本，已取消恢复。"
        }
    }
}
