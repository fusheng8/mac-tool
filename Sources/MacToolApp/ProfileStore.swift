import Foundation

final class ProfileStore {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var config: AppConfig
    private(set) var state: AppState

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? AppPaths.ensureDirectories()
        config = Self.load(url: AppPaths.configURL, decoder: decoder) ?? .defaultValue
        config.contextMenu = config.contextMenu.normalized()
        if config.archive.enabledFormats.isEmpty {
            config.archive = .defaultValue
        }
        state = Self.load(url: AppPaths.stateURL, decoder: decoder) ?? .empty
        try? saveConfig()
        if !FileManager.default.fileExists(atPath: AppPaths.configURL.path) {
            try? saveConfig()
        }
        if !FileManager.default.fileExists(atPath: AppPaths.stateURL.path) {
            try? saveState()
        }
    }

    var profiles: [DisplayProfile] {
        get { config.profiles }
        set {
            config.profiles = newValue
            try? saveConfig()
        }
    }

    var clipboard: ClipboardConfig {
        get { config.clipboard }
        set {
            config.clipboard = newValue
            try? saveConfig()
        }
    }

    var archive: ArchiveConfig {
        get { config.archive }
        set {
            config.archive = newValue
            try? saveConfig()
        }
    }

    var contextMenu: ContextMenuConfig {
        get { config.contextMenu.normalized() }
        set {
            config.contextMenu = newValue.normalized()
            try? saveConfig()
        }
    }

    var pendingReconnects: [PendingReconnect] {
        state.pendingReconnects
    }

    var lastSeenDisplays: [DisplaySnapshot] {
        state.lastSeenDisplays
    }

    func updateProfile(_ profile: DisplayProfile) {
        if let index = config.profiles.firstIndex(where: { $0.id == profile.id }) {
            config.profiles[index] = profile
        } else {
            config.profiles.append(profile)
        }
        try? saveConfig()
    }

    func deleteProfile(id: String) {
        config.profiles.removeAll { $0.id == id }
        state.pendingReconnects.removeAll { $0.profileId == id }
        try? saveConfig()
        try? saveState()
    }

    func addPendingReconnect(_ pending: PendingReconnect) {
        state.pendingReconnects.removeAll { $0.profileId == pending.profileId }
        state.pendingReconnects.append(pending)
        try? saveState()
    }

    func clearPendingReconnect(profileId: String) {
        state.pendingReconnects.removeAll { $0.profileId == profileId }
        try? saveState()
    }

    func clearAllPendingReconnects() {
        guard !state.pendingReconnects.isEmpty else {
            return
        }
        state.pendingReconnects.removeAll()
        try? saveState()
    }

    func rememberDisplays(_ displays: [DisplaySnapshot]) {
        var remembered = state.lastSeenDisplays
        for display in displays where display.runtimeDisplayID != 0 && !display.isVirtualPlaceholder {
            if let index = remembered.firstIndex(where: { Self.sameDisplay($0, display) }) {
                remembered[index] = display
            } else {
                remembered.append(display)
            }
        }
        state.lastSeenDisplays = remembered
        try? saveState()
    }

    func reload() {
        config = Self.load(url: AppPaths.configURL, decoder: decoder) ?? config
        state = Self.load(url: AppPaths.stateURL, decoder: decoder) ?? state
    }

    func exportConfig(to url: URL) throws {
        try saveConfig()
        guard AppPaths.configURL.standardizedFileURL != url.standardizedFileURL else {
            return
        }
        try FileManager.default.copyReplacingItem(at: AppPaths.configURL, to: url)
    }

    func importConfig(from url: URL) throws {
        let data = try Data(contentsOf: url)
        var importedConfig = try decoder.decode(AppConfig.self, from: data)
        importedConfig.contextMenu = importedConfig.contextMenu.normalized()
        if importedConfig.archive.enabledFormats.isEmpty {
            importedConfig.archive = .defaultValue
        }
        config = importedConfig
        try saveConfig()
    }

    func backupConfigToICloud() throws -> URL {
        guard let directory = AppPaths.iCloudBackupDirectory,
              let backupURL = AppPaths.iCloudConfigBackupURL else {
            throw ProfileStoreError.iCloudUnavailable
        }
        try AppPaths.ensureDirectories()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try exportConfig(to: backupURL)
        return backupURL
    }

    func syncConfigFromICloud() throws {
        guard let backupURL = AppPaths.iCloudConfigBackupURL else {
            throw ProfileStoreError.iCloudUnavailable
        }
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw ProfileStoreError.iCloudBackupMissing
        }
        try importConfig(from: backupURL)
    }

    func saveConfig() throws {
        try AppPaths.ensureDirectories()
        let data = try encoder.encode(config)
        try data.write(to: AppPaths.configURL, options: .atomic)
        try data.write(to: AppPaths.finderSyncConfigURL, options: .atomic)
    }

    func saveState() throws {
        try AppPaths.ensureDirectories()
        let data = try encoder.encode(state)
        try data.write(to: AppPaths.stateURL, options: .atomic)
    }

    private static func load<T: Decodable>(url: URL, decoder: JSONDecoder) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(T.self, from: data)
    }

    private static func sameDisplay(_ lhs: DisplaySnapshot, _ rhs: DisplaySnapshot) -> Bool {
        lhs.hasSameStableIdentity(as: rhs)
    }
}

enum ProfileStoreError: LocalizedError {
    case iCloudUnavailable
    case iCloudBackupMissing

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "当前无法访问 iCloud Drive。请确认系统已登录 Apple ID，并已启用 iCloud Drive。"
        case .iCloudBackupMissing:
            return "没有找到 iCloud 配置备份。请先在这台或另一台 Mac 上执行备份。"
        }
    }
}

private extension FileManager {
    func copyReplacingItem(at sourceURL: URL, to destinationURL: URL) throws {
        if fileExists(atPath: destinationURL.path) {
            try removeItem(at: destinationURL)
        }
        try copyItem(at: sourceURL, to: destinationURL)
    }
}
