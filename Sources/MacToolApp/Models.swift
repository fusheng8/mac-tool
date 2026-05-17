import AppKit
import Carbon.HIToolbox
import Foundation

enum MatchMode: String, Codable, CaseIterable {
    case strict
    case weighted
}

enum ManagedDisplayStatus: String, Codable {
    case unknown = "未知"
    case notDetected = "未检测到"
    case detected = "已检测到"
    case disconnecting = "正在断开"
    case disconnected = "已断开"
    case reconnectCountdown = "等待自动恢复"
    case reconnecting = "正在重新连接"
    case reconnectFailed = "重新连接失败"
}

struct DisplaySnapshot: Codable, Hashable {
    var runtimeDisplayID: UInt32
    var displayName: String
    var edidUUID: String
    var vendorId: String
    var modelId: String
    var serialNumber: String
    var manufacturer: String
    var alphanumericSerial: String
    var isBuiltIn: Bool
    var isActive: Bool
    var ioLocation: String

    var isVirtualPlaceholder: Bool {
        let normalizedVendorId = vendorId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedModelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !isBuiltIn
            && edidUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ioLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (normalizedVendorId == "0x756e6b6e" || normalizedModelId == "0x76697274")
    }

    func hasSameStableIdentity(as other: DisplaySnapshot) -> Bool {
        if normalizedIdentityValue(edidUUID) != "", normalizedIdentityValue(edidUUID) == normalizedIdentityValue(other.edidUUID) {
            return true
        }
        if normalizedIdentityValue(alphanumericSerial) != "", normalizedIdentityValue(alphanumericSerial) == normalizedIdentityValue(other.alphanumericSerial) {
            return true
        }
        if normalizedIdentityValue(vendorId) != "",
           normalizedIdentityValue(modelId) != "",
           normalizedIdentityValue(serialNumber) != "",
           normalizedIdentityValue(vendorId) == normalizedIdentityValue(other.vendorId),
           normalizedIdentityValue(modelId) == normalizedIdentityValue(other.modelId),
           normalizedIdentityValue(serialNumber) == normalizedIdentityValue(other.serialNumber) {
            return true
        }
        if normalizedIdentityValue(ioLocation) != "", normalizedIdentityValue(ioLocation) == normalizedIdentityValue(other.ioLocation) {
            return true
        }
        return normalizedIdentityValue(displayName) != ""
            && normalizedIdentityValue(displayName) == normalizedIdentityValue(other.displayName)
            && isBuiltIn == other.isBuiltIn
    }

    private func normalizedIdentityValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case runtimeDisplayID
        case displayName
        case edidUUID
        case vendorId
        case modelId
        case serialNumber
        case manufacturer
        case alphanumericSerial
        case isBuiltIn
        case isActive
        case ioLocation
    }

    init(
        runtimeDisplayID: UInt32,
        displayName: String,
        edidUUID: String,
        vendorId: String,
        modelId: String,
        serialNumber: String,
        manufacturer: String,
        alphanumericSerial: String,
        isBuiltIn: Bool,
        isActive: Bool,
        ioLocation: String
    ) {
        self.runtimeDisplayID = runtimeDisplayID
        self.displayName = displayName
        self.edidUUID = edidUUID
        self.vendorId = vendorId
        self.modelId = modelId
        self.serialNumber = serialNumber
        self.manufacturer = manufacturer
        self.alphanumericSerial = alphanumericSerial
        self.isBuiltIn = isBuiltIn
        self.isActive = isActive
        self.ioLocation = ioLocation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeDisplayID = try container.decodeIfPresent(UInt32.self, forKey: .runtimeDisplayID) ?? 0
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        edidUUID = try container.decodeIfPresent(String.self, forKey: .edidUUID) ?? ""
        vendorId = try container.decodeIfPresent(String.self, forKey: .vendorId) ?? ""
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber) ?? ""
        manufacturer = try container.decodeIfPresent(String.self, forKey: .manufacturer) ?? ""
        alphanumericSerial = try container.decodeIfPresent(String.self, forKey: .alphanumericSerial) ?? ""
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        ioLocation = try container.decodeIfPresent(String.self, forKey: .ioLocation) ?? ""
    }
}

struct DisplayMatchRule: Codable, Hashable {
    var displayName: String
    var edidUUID: String
    var vendorId: String
    var modelId: String
    var serialNumber: String
    var manufacturer: String
    var alphanumericSerial: String
    var ioLocation: String
    var matchThreshold: Int

    static let empty = DisplayMatchRule(
        displayName: "",
        edidUUID: "",
        vendorId: "",
        modelId: "",
        serialNumber: "",
        manufacturer: "",
        alphanumericSerial: "",
        ioLocation: "",
        matchThreshold: 80
    )

    enum CodingKeys: String, CodingKey {
        case displayName
        case edidUUID
        case vendorId
        case modelId
        case serialNumber
        case manufacturer
        case alphanumericSerial
        case ioLocation
        case matchThreshold
    }

    init(
        displayName: String,
        edidUUID: String,
        vendorId: String,
        modelId: String,
        serialNumber: String,
        manufacturer: String,
        alphanumericSerial: String,
        ioLocation: String = "",
        matchThreshold: Int
    ) {
        self.displayName = displayName
        self.edidUUID = edidUUID
        self.vendorId = vendorId
        self.modelId = modelId
        self.serialNumber = serialNumber
        self.manufacturer = manufacturer
        self.alphanumericSerial = alphanumericSerial
        self.ioLocation = ioLocation
        self.matchThreshold = matchThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        edidUUID = try container.decodeIfPresent(String.self, forKey: .edidUUID) ?? ""
        vendorId = try container.decodeIfPresent(String.self, forKey: .vendorId) ?? ""
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber) ?? ""
        manufacturer = try container.decodeIfPresent(String.self, forKey: .manufacturer) ?? ""
        alphanumericSerial = try container.decodeIfPresent(String.self, forKey: .alphanumericSerial) ?? ""
        ioLocation = try container.decodeIfPresent(String.self, forKey: .ioLocation) ?? ""
        matchThreshold = try container.decodeIfPresent(Int.self, forKey: .matchThreshold) ?? 80
    }
}

struct VCPVerificationRule: Codable, Hashable, Identifiable {
    var id: UUID
    var vcpCode: String
    var expectedValue: Int

    init(id: UUID = UUID(), vcpCode: String, expectedValue: Int) {
        self.id = id
        self.vcpCode = vcpCode
        self.expectedValue = expectedValue
    }
}

struct ColorLockConfig: Codable, Hashable {
    var enabled: Bool
    var label: String
    var vcpCode: String
    var targetValue: Int
    var verify: [VCPVerificationRule]

    static let p3Default = ColorLockConfig(
        enabled: false,
        label: "P3",
        vcpCode: "0xE2",
        targetValue: 4,
        verify: [
            VCPVerificationRule(vcpCode: "0xE2", expectedValue: 4),
            VCPVerificationRule(vcpCode: "0x14", expectedValue: 5)
        ]
    )
}

struct DisconnectConfig: Codable, Hashable {
    var enabled: Bool
    var allowSoftDisconnect: Bool
    var autoReconnect: Bool
    var autoReconnectDelaySeconds: Int
    var externalOnly: Bool
    var confirmBeforeDisconnect: Bool

    static let defaultValue = DisconnectConfig(
        enabled: true,
        allowSoftDisconnect: true,
        autoReconnect: true,
        autoReconnectDelaySeconds: 30,
        externalOnly: false,
        confirmBeforeDisconnect: true
    )

    enum CodingKeys: String, CodingKey {
        case enabled
        case allowSoftDisconnect
        case autoReconnect
        case autoReconnectDelaySeconds
        case externalOnly
        case confirmBeforeDisconnect
    }

    init(
        enabled: Bool,
        allowSoftDisconnect: Bool,
        autoReconnect: Bool,
        autoReconnectDelaySeconds: Int,
        externalOnly: Bool,
        confirmBeforeDisconnect: Bool = true
    ) {
        self.enabled = enabled
        self.allowSoftDisconnect = allowSoftDisconnect
        self.autoReconnect = autoReconnect
        self.autoReconnectDelaySeconds = autoReconnectDelaySeconds
        self.externalOnly = externalOnly
        self.confirmBeforeDisconnect = confirmBeforeDisconnect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        allowSoftDisconnect = try container.decodeIfPresent(Bool.self, forKey: .allowSoftDisconnect) ?? true
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        autoReconnectDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .autoReconnectDelaySeconds) ?? 30
        externalOnly = try container.decodeIfPresent(Bool.self, forKey: .externalOnly) ?? false
        confirmBeforeDisconnect = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeDisconnect) ?? true
    }
}

struct DisplayProfile: Codable, Hashable, Identifiable {
    var id: String
    var enabled: Bool
    var name: String
    var matchMode: MatchMode
    var match: DisplayMatchRule
    var colorLock: ColorLockConfig
    var disconnect: DisconnectConfig
    var automationEnabled: Bool

    static let dm73uProDefault = DisplayProfile(
        id: "dm73u-pro",
        enabled: true,
        name: "DM73u pro",
        matchMode: .strict,
        match: DisplayMatchRule(
            displayName: "DM73u pro",
            edidUUID: "4C236527-0000-0000-0123-0104B53C2178",
            vendorId: "0x4c23",
            modelId: "0x2765",
            serialNumber: "",
            manufacturer: "SAC",
            alphanumericSerial: "",
            ioLocation: "",
            matchThreshold: 80
        ),
        colorLock: .p3Default,
        disconnect: .defaultValue,
        automationEnabled: false
    )
}

struct PendingReconnect: Codable, Hashable, Identifiable {
    var id: UUID
    var profileId: String
    var displaySnapshot: DisplaySnapshot
    var disconnectedAt: Date
    var reason: String
    var autoReconnect: Bool

    init(id: UUID = UUID(), profileId: String, displaySnapshot: DisplaySnapshot, disconnectedAt: Date = Date(), reason: String, autoReconnect: Bool) {
        self.id = id
        self.profileId = profileId
        self.displaySnapshot = displaySnapshot
        self.disconnectedAt = disconnectedAt
        self.reason = reason
        self.autoReconnect = autoReconnect
    }
}

struct HotKeyConfig: Codable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var displayText: String

    static let defaultClipboard = HotKeyConfig(
        keyCode: 9,
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayText: "⇧⌘V"
    )
}

struct ClipboardShortcutBinding: Codable, Hashable {
    var enabled: Bool
    var hotKey: HotKeyConfig

    static func enabled(_ hotKey: HotKeyConfig) -> ClipboardShortcutBinding {
        ClipboardShortcutBinding(enabled: true, hotKey: hotKey)
    }
}

enum ClipboardShortcut: String, CaseIterable, Codable, Hashable {
    case pasteSelected
    case pastePlainText
    case showActionsMenu
    case quickLook
    case selectPreviousItem
    case selectNextItem
    case selectPreviousApplication
    case selectNextApplication
    case pasteVisibleItem

    var title: String {
        switch self {
        case .pasteSelected: return "粘贴选中项"
        case .pastePlainText: return "纯文本粘贴"
        case .showActionsMenu: return "更多菜单"
        case .quickLook: return "快速预览"
        case .selectPreviousItem: return "选择上一条"
        case .selectNextItem: return "选择下一条"
        case .selectPreviousApplication: return "切到左侧应用"
        case .selectNextApplication: return "切到右侧应用"
        case .pasteVisibleItem: return "快速粘贴可见项"
        }
    }

    var detail: String {
        switch self {
        case .pasteVisibleItem:
            return "录制任意数字键 1-9，用同一组修饰键快速粘贴当前可见记录。"
        case .showActionsMenu:
            return "等同于对当前选中记录点鼠标右键。"
        case .selectPreviousApplication, .selectNextApplication:
            return "在剪切板顶部应用筛选条中切换。"
        default:
            return "剪切板历史面板打开时生效。"
        }
    }

    var defaultBinding: ClipboardShortcutBinding {
        switch self {
        case .pasteSelected:
            return .enabled(HotKeyConfig(keyCode: 36, carbonModifiers: 0, displayText: "↩"))
        case .pastePlainText:
            return .enabled(HotKeyConfig(keyCode: 36, carbonModifiers: UInt32(shiftKey), displayText: "⇧↩"))
        case .showActionsMenu:
            return .enabled(HotKeyConfig(keyCode: 36, carbonModifiers: UInt32(cmdKey), displayText: "⌘↩"))
        case .quickLook:
            return .enabled(HotKeyConfig(keyCode: 49, carbonModifiers: 0, displayText: "Space"))
        case .selectPreviousItem:
            return .enabled(HotKeyConfig(keyCode: 126, carbonModifiers: 0, displayText: "↑"))
        case .selectNextItem:
            return .enabled(HotKeyConfig(keyCode: 125, carbonModifiers: 0, displayText: "↓"))
        case .selectPreviousApplication:
            return .enabled(HotKeyConfig(keyCode: 123, carbonModifiers: 0, displayText: "←"))
        case .selectNextApplication:
            return .enabled(HotKeyConfig(keyCode: 124, carbonModifiers: 0, displayText: "→"))
        case .pasteVisibleItem:
            return .enabled(HotKeyConfig(keyCode: 18, carbonModifiers: UInt32(cmdKey), displayText: "⌘1-⌘9"))
        }
    }
}

struct ClipboardShortcutSettings: Codable, Hashable {
    var bindings: [ClipboardShortcut: ClipboardShortcutBinding]

    static let defaultValue = ClipboardShortcutSettings(
        bindings: Dictionary(uniqueKeysWithValues: ClipboardShortcut.allCases.map { ($0, $0.defaultBinding) })
    )

    init(bindings: [ClipboardShortcut: ClipboardShortcutBinding]) {
        self.bindings = bindings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ClipboardShortcutCodingKey.self)
        bindings = Dictionary(uniqueKeysWithValues: ClipboardShortcut.allCases.map { shortcut in
            let key = ClipboardShortcutCodingKey(stringValue: shortcut.rawValue)!
            let binding = (try? container.decode(ClipboardShortcutBinding.self, forKey: key)) ?? shortcut.defaultBinding
            return (shortcut, binding)
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ClipboardShortcutCodingKey.self)
        for shortcut in ClipboardShortcut.allCases {
            try container.encode(binding(for: shortcut), forKey: ClipboardShortcutCodingKey(stringValue: shortcut.rawValue)!)
        }
    }

    func binding(for shortcut: ClipboardShortcut) -> ClipboardShortcutBinding {
        bindings[shortcut] ?? shortcut.defaultBinding
    }

    mutating func setBinding(_ binding: ClipboardShortcutBinding, for shortcut: ClipboardShortcut) {
        bindings[shortcut] = binding
    }
}

private struct ClipboardShortcutCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

struct ClipboardConfig: Codable, Hashable {
    var enabled: Bool
    var hotKeyEnabled: Bool
    var hotKey: HotKeyConfig
    var shortcuts: ClipboardShortcutSettings
    var maxHistoryCount: Int
    var recordingPaused: Bool
    var excludeKnownPasswordManagers: Bool
    var excludedBundleIdentifiers: [String]
    var retentionDays: Int
    var pollIntervalMilliseconds: Int

    static let defaultValue = ClipboardConfig(
        enabled: true,
        hotKeyEnabled: true,
        hotKey: .defaultClipboard,
        shortcuts: .defaultValue,
        maxHistoryCount: 1000,
        recordingPaused: false,
        excludeKnownPasswordManagers: true,
        excludedBundleIdentifiers: [],
        retentionDays: 0,
        pollIntervalMilliseconds: 650
    )

    enum CodingKeys: String, CodingKey {
        case enabled
        case hotKeyEnabled
        case hotKey
        case shortcuts
        case maxHistoryCount
        case recordingPaused
        case excludeKnownPasswordManagers
        case excludedBundleIdentifiers
        case retentionDays
        case pollIntervalMilliseconds
    }

    init(
        enabled: Bool,
        hotKeyEnabled: Bool = true,
        hotKey: HotKeyConfig,
        shortcuts: ClipboardShortcutSettings = .defaultValue,
        maxHistoryCount: Int,
        recordingPaused: Bool,
        excludeKnownPasswordManagers: Bool,
        excludedBundleIdentifiers: [String],
        retentionDays: Int,
        pollIntervalMilliseconds: Int = 650
    ) {
        self.enabled = enabled
        self.hotKeyEnabled = hotKeyEnabled
        self.hotKey = hotKey
        self.shortcuts = shortcuts
        self.maxHistoryCount = maxHistoryCount
        self.recordingPaused = recordingPaused
        self.excludeKnownPasswordManagers = excludeKnownPasswordManagers
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.retentionDays = max(0, retentionDays)
        self.pollIntervalMilliseconds = Self.normalizedPollIntervalMilliseconds(pollIntervalMilliseconds)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hotKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? true
        hotKey = try container.decodeIfPresent(HotKeyConfig.self, forKey: .hotKey) ?? .defaultClipboard
        shortcuts = try container.decodeIfPresent(ClipboardShortcutSettings.self, forKey: .shortcuts) ?? .defaultValue
        maxHistoryCount = try container.decodeIfPresent(Int.self, forKey: .maxHistoryCount) ?? 1000
        recordingPaused = try container.decodeIfPresent(Bool.self, forKey: .recordingPaused) ?? false
        excludeKnownPasswordManagers = try container.decodeIfPresent(Bool.self, forKey: .excludeKnownPasswordManagers) ?? true
        excludedBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .excludedBundleIdentifiers) ?? []
        retentionDays = max(0, try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 0)
        pollIntervalMilliseconds = Self.normalizedPollIntervalMilliseconds(
            try container.decodeIfPresent(Int.self, forKey: .pollIntervalMilliseconds) ?? 650
        )
    }

    static func normalizedPollIntervalMilliseconds(_ value: Int) -> Int {
        min(10_000, max(200, value))
    }
}

enum ClipboardContentKind: String, CaseIterable {
    case text
    case image
    case file
    case richText

    var title: String {
        switch self {
        case .text:
            return "文本"
        case .image:
            return "图片"
        case .file:
            return "文件"
        case .richText:
            return "富文本"
        }
    }
}

enum ArchiveFormat: String, Codable, CaseIterable {
    case zip
    case tar
    case tarGzip
    case tarBzip2
    case tarXz
    case gzip
    case bzip2
    case xz
    case sevenZip
    case rar

    var title: String {
        switch self {
        case .zip:
            return "ZIP"
        case .tar:
            return "TAR"
        case .tarGzip:
            return "tar.gz / tgz"
        case .tarBzip2:
            return "tar.bz2 / tbz"
        case .tarXz:
            return "tar.xz / txz"
        case .gzip:
            return "GZIP"
        case .bzip2:
            return "BZIP2"
        case .xz:
            return "XZ"
        case .sevenZip:
            return "7Z"
        case .rar:
            return "RAR"
        }
    }

    var detail: String {
        switch self {
        case .zip:
            return "macOS 自带支持，适合通用文件交换。"
        case .tar:
            return "Unix tar 归档，不带压缩。"
        case .tarGzip:
            return "常见源码包格式，macOS 自带支持。"
        case .tarBzip2:
            return "bzip2 压缩的 tar 归档。"
        case .tarXz:
            return "xz 压缩的 tar 归档，需要系统可用 xz。"
        case .gzip:
            return "单文件 gzip 压缩。"
        case .bzip2:
            return "单文件 bzip2 压缩。"
        case .xz:
            return "单文件 xz 压缩，需要系统可用 xz。"
        case .sevenZip:
            return "需要安装 7z 或 7zz。"
        case .rar:
            return "需要安装 7z 或 7zz。"
        }
    }

    var archiveExtension: String {
        switch self {
        case .zip:
            return "zip"
        case .tar:
            return "tar"
        case .tarGzip:
            return "tar.gz"
        case .tarBzip2:
            return "tar.bz2"
        case .tarXz:
            return "tar.xz"
        case .gzip:
            return "gz"
        case .bzip2:
            return "bz2"
        case .xz:
            return "xz"
        case .sevenZip:
            return "7z"
        case .rar:
            return "rar"
        }
    }

    var supportsCompressionPassword: Bool {
        switch self {
        case .zip, .sevenZip, .rar:
            return true
        case .tar, .tarGzip, .tarBzip2, .tarXz, .gzip, .bzip2, .xz:
            return false
        }
    }

    var isSingleFileCompression: Bool {
        switch self {
        case .gzip, .bzip2, .xz:
            return true
        case .zip, .tar, .tarGzip, .tarBzip2, .tarXz, .sevenZip, .rar:
            return false
        }
    }

    var supportsCompressionLevel: Bool {
        self != .tar
    }
}

struct ArchiveConfig: Codable, Hashable {
    var enabledFormats: Set<ArchiveFormat>
    var stripMacMetadataWhenCompressing: Bool
    var defaultCompressionLevel: Int
    var registerAsDefaultArchiveOpener: Bool
    var autoCloseProgressWindowAfterExtraction: Bool

    static let defaultValue = ArchiveConfig(
        enabledFormats: Set(ArchiveFormat.allCases),
        stripMacMetadataWhenCompressing: true,
        defaultCompressionLevel: 6,
        registerAsDefaultArchiveOpener: false,
        autoCloseProgressWindowAfterExtraction: true
    )

    func supports(_ format: ArchiveFormat) -> Bool {
        enabledFormats.contains(format)
    }

    enum CodingKeys: String, CodingKey {
        case enabledFormats
        case stripMacMetadataWhenCompressing
        case defaultCompressionLevel
        case registerAsDefaultArchiveOpener
        case autoCloseProgressWindowAfterExtraction
    }

    init(
        enabledFormats: Set<ArchiveFormat>,
        stripMacMetadataWhenCompressing: Bool,
        defaultCompressionLevel: Int,
        registerAsDefaultArchiveOpener: Bool = false,
        autoCloseProgressWindowAfterExtraction: Bool = true
    ) {
        self.enabledFormats = enabledFormats
        self.stripMacMetadataWhenCompressing = stripMacMetadataWhenCompressing
        self.defaultCompressionLevel = Self.normalizedCompressionLevel(defaultCompressionLevel)
        self.registerAsDefaultArchiveOpener = registerAsDefaultArchiveOpener
        self.autoCloseProgressWindowAfterExtraction = autoCloseProgressWindowAfterExtraction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledFormats = try container.decodeIfPresent(Set<ArchiveFormat>.self, forKey: .enabledFormats) ?? Set(ArchiveFormat.allCases)
        stripMacMetadataWhenCompressing = try container.decodeIfPresent(Bool.self, forKey: .stripMacMetadataWhenCompressing) ?? true
        defaultCompressionLevel = Self.normalizedCompressionLevel(try container.decodeIfPresent(Int.self, forKey: .defaultCompressionLevel) ?? 6)
        registerAsDefaultArchiveOpener = try container.decodeIfPresent(Bool.self, forKey: .registerAsDefaultArchiveOpener) ?? false
        autoCloseProgressWindowAfterExtraction = try container.decodeIfPresent(Bool.self, forKey: .autoCloseProgressWindowAfterExtraction) ?? true
    }

    static func normalizedCompressionLevel(_ level: Int) -> Int {
        min(9, max(0, level))
    }
}

enum ContextMenuItemID: String, Codable, CaseIterable {
    case createFolder
    case copyPath
    case open
    case openWithIDEA
    case openWithTypora
    case openWithVSCode
    case openInTerminal
    case openInWarp
    case newFile
    case newTextFile
    case newMarkdownFile
    case newJSONFile
    case newHTMLFile
    case newWordFile
    case newExcelFile
    case newPowerPointFile
    case archive
    case compressCustom
    case smartExtract
    case smartExtractAndDelete
    case extractToArchiveNameAndDelete
    case extractHere
    case extractToArchiveName
    case compressZip
    case compressTar
    case compressTarGzip
    case compressTarBzip2
    case compressTarXz
    case compressGzip
    case compressBzip2
    case compressXz
    case compressSevenZip
    case compressRar

    var title: String {
        switch self {
        case .createFolder:
            return "新建文件夹"
        case .copyPath:
            return "拷贝路径"
        case .open:
            return "打开"
        case .openWithIDEA:
            return "IDEA"
        case .openWithTypora:
            return "Typora"
        case .openWithVSCode:
            return "VS Code"
        case .openInTerminal:
            return "在终端打开"
        case .openInWarp:
            return "在 Warp 打开"
        case .newFile:
            return "新建"
        case .newTextFile:
            return "TXT"
        case .newMarkdownFile:
            return "Markdown"
        case .newJSONFile:
            return "JSON"
        case .newHTMLFile:
            return "HTML"
        case .newWordFile:
            return "Word"
        case .newExcelFile:
            return "Excel"
        case .newPowerPointFile:
            return "PPT"
        case .archive:
            return "压缩/解压"
        case .compressCustom:
            return "自定义压缩"
        case .smartExtract:
            return "智能解压"
        case .smartExtractAndDelete:
            return "智能解压并删除"
        case .extractToArchiveNameAndDelete:
            return "解压到压缩包名称并删除"
        case .extractHere:
            return "解压到当前目录"
        case .extractToArchiveName:
            return "解压到压缩包名称"
        case .compressZip:
            return "压缩为 ZIP"
        case .compressTar:
            return "压缩为 TAR"
        case .compressTarGzip:
            return "压缩为 tar.gz"
        case .compressTarBzip2:
            return "压缩为 tar.bz2"
        case .compressTarXz:
            return "压缩为 tar.xz"
        case .compressGzip:
            return "压缩为 GZIP"
        case .compressBzip2:
            return "压缩为 BZIP2"
        case .compressXz:
            return "压缩为 XZ"
        case .compressSevenZip:
            return "压缩为 7Z"
        case .compressRar:
            return "压缩为 RAR"
        }
    }

    var symbolName: String {
        switch self {
        case .createFolder:
            return "folder.badge.plus"
        case .copyPath:
            return "doc.on.doc"
        case .open:
            return "arrow.up.right.square"
        case .openWithIDEA:
            return "hammer"
        case .openWithTypora:
            return "textformat"
        case .openWithVSCode:
            return "chevron.left.forwardslash.chevron.right"
        case .openInTerminal:
            return "terminal"
        case .openInWarp:
            return "terminal.fill"
        case .newFile:
            return "doc.badge.plus"
        case .newTextFile:
            return "doc.plaintext"
        case .newMarkdownFile:
            return "doc.text"
        case .newJSONFile:
            return "curlybraces"
        case .newHTMLFile:
            return "globe"
        case .newWordFile:
            return "doc.richtext"
        case .newExcelFile:
            return "tablecells"
        case .newPowerPointFile:
            return "rectangle.on.rectangle"
        case .archive:
            return "archivebox"
        case .compressCustom:
            return "slider.horizontal.3"
        case .smartExtract:
            return "archivebox.fill"
        case .smartExtractAndDelete:
            return "archivebox.fill"
        case .extractToArchiveNameAndDelete:
            return "trash"
        case .extractHere:
            return "arrow.down.doc"
        case .extractToArchiveName:
            return "folder.badge.gearshape"
        case .compressZip, .compressTar, .compressTarGzip, .compressTarBzip2, .compressTarXz, .compressGzip, .compressBzip2, .compressXz, .compressSevenZip, .compressRar:
            return "doc.zipper"
        }
    }

    var isArchiveAction: Bool {
        switch self {
        case .smartExtract, .smartExtractAndDelete, .extractHere, .extractToArchiveName, .extractToArchiveNameAndDelete, .compressCustom, .compressZip, .compressTar, .compressTarGzip, .compressTarBzip2, .compressTarXz, .compressGzip, .compressBzip2, .compressXz, .compressSevenZip, .compressRar:
            return true
        case .createFolder, .copyPath, .open, .openWithIDEA, .openWithTypora, .openWithVSCode, .openInTerminal, .openInWarp, .newFile, .newTextFile, .newMarkdownFile, .newJSONFile, .newHTMLFile, .newWordFile, .newExcelFile, .newPowerPointFile, .archive:
            return false
        }
    }
}

struct ContextMenuItemConfig: Codable, Hashable, Identifiable {
    var id: ContextMenuItemID
    var enabled: Bool
    var children: [ContextMenuItemConfig]

    init(id: ContextMenuItemID, enabled: Bool = true, children: [ContextMenuItemConfig] = []) {
        self.id = id
        self.enabled = enabled
        self.children = children
    }
}

struct ContextMenuConfig: Codable, Hashable {
    var enabled: Bool
    var items: [ContextMenuItemConfig]

    static let defaultValue = ContextMenuConfig(
        enabled: true,
        items: [
            ContextMenuItemConfig(id: .copyPath),
            ContextMenuItemConfig(
                id: .open,
                children: [
                    ContextMenuItemConfig(id: .openWithIDEA),
                    ContextMenuItemConfig(id: .openWithTypora),
                    ContextMenuItemConfig(id: .openWithVSCode),
                    ContextMenuItemConfig(id: .openInTerminal),
                    ContextMenuItemConfig(id: .openInWarp)
                ]
            ),
            ContextMenuItemConfig(
                id: .newFile,
                children: [
                    ContextMenuItemConfig(id: .createFolder),
                    ContextMenuItemConfig(id: .newTextFile),
                    ContextMenuItemConfig(id: .newMarkdownFile),
                    ContextMenuItemConfig(id: .newJSONFile),
                    ContextMenuItemConfig(id: .newHTMLFile),
                    ContextMenuItemConfig(id: .newWordFile),
                    ContextMenuItemConfig(id: .newExcelFile),
                    ContextMenuItemConfig(id: .newPowerPointFile)
                ]
            ),
            ContextMenuItemConfig(
                id: .archive,
                children: [
                    ContextMenuItemConfig(id: .smartExtract),
                    ContextMenuItemConfig(id: .smartExtractAndDelete),
                    ContextMenuItemConfig(id: .extractToArchiveNameAndDelete, enabled: false),
                    ContextMenuItemConfig(id: .extractHere, enabled: false),
                    ContextMenuItemConfig(id: .extractToArchiveName, enabled: false),
                    ContextMenuItemConfig(id: .compressCustom),
                    ContextMenuItemConfig(id: .compressZip),
                    ContextMenuItemConfig(id: .compressTar, enabled: false),
                    ContextMenuItemConfig(id: .compressTarGzip, enabled: false),
                    ContextMenuItemConfig(id: .compressTarBzip2, enabled: false),
                    ContextMenuItemConfig(id: .compressTarXz, enabled: false),
                    ContextMenuItemConfig(id: .compressGzip, enabled: false),
                    ContextMenuItemConfig(id: .compressBzip2, enabled: false),
                    ContextMenuItemConfig(id: .compressXz, enabled: false),
                    ContextMenuItemConfig(id: .compressSevenZip, enabled: false),
                    ContextMenuItemConfig(id: .compressRar, enabled: false)
                ]
            )
        ]
    )

    func normalized() -> ContextMenuConfig {
        ContextMenuConfig(
            enabled: enabled,
            items: Self.normalize(items: Self.migrateLegacyItems(items), defaults: Self.defaultValue.items)
        )
    }

    private static func migrateLegacyItems(_ items: [ContextMenuItemConfig]) -> [ContextMenuItemConfig] {
        guard let createFolderItem = items.first(where: { $0.id == .createFolder }) else {
            return migrateLegacyArchiveItems(items)
        }

        var migratedItems = items.filter { $0.id != .createFolder }
        guard let newFileIndex = migratedItems.firstIndex(where: { $0.id == .newFile }),
              !migratedItems[newFileIndex].children.contains(where: { $0.id == .createFolder }) else {
            return migrateLegacyArchiveItems(migratedItems)
        }

        migratedItems[newFileIndex].children.insert(createFolderItem, at: 0)
        return migrateLegacyArchiveItems(migratedItems)
    }

    private static func migrateLegacyArchiveItems(_ items: [ContextMenuItemConfig]) -> [ContextMenuItemConfig] {
        var migratedItems = items
        guard let archiveIndex = migratedItems.firstIndex(where: { $0.id == .archive }) else {
            return migratedItems
        }
        if let smartExtractIndex = migratedItems[archiveIndex].children.firstIndex(where: { $0.id == .smartExtract }) {
            var insertionIndex = smartExtractIndex + 1
            if !migratedItems[archiveIndex].children.contains(where: { $0.id == .smartExtractAndDelete }) {
                migratedItems[archiveIndex].children.insert(ContextMenuItemConfig(id: .smartExtractAndDelete), at: insertionIndex)
                insertionIndex += 1
            }
            if !migratedItems[archiveIndex].children.contains(where: { $0.id == .extractToArchiveNameAndDelete }) {
                migratedItems[archiveIndex].children.insert(ContextMenuItemConfig(id: .extractToArchiveNameAndDelete, enabled: false), at: insertionIndex)
            }
        }
        let childIDs = migratedItems[archiveIndex].children.map(\.id)
        guard childIDs.count <= 5,
              childIDs.contains(.smartExtract),
              childIDs.contains(.compressZip),
              childIDs.contains(.compressTarGzip),
              let tarGzipIndex = migratedItems[archiveIndex].children.firstIndex(where: { $0.id == .compressTarGzip }) else {
            return migratedItems
        }
        migratedItems[archiveIndex].children[tarGzipIndex].enabled = false
        return migratedItems
    }

    private static func normalize(items: [ContextMenuItemConfig], defaults: [ContextMenuItemConfig]) -> [ContextMenuItemConfig] {
        var normalizedItems = items.compactMap { item -> ContextMenuItemConfig? in
            guard let defaultItem = defaults.first(where: { $0.id == item.id }) else {
                return nil
            }
            return ContextMenuItemConfig(
                id: item.id,
                enabled: item.enabled,
                children: normalize(items: item.children, defaults: defaultItem.children)
            )
        }

        for defaultItem in defaults where !normalizedItems.contains(where: { $0.id == defaultItem.id }) {
            normalizedItems.append(defaultItem)
        }
        return normalizedItems
    }
}

struct ClipboardStoredType: Codable, Hashable {
    var type: String
    var data: Data
}

struct ClipboardContentMetadata: Codable, Hashable {
    var contentType: String
    var detailText: String
    var sourcePaths: [String]
    var fileNames: [String]
    var pasteboardTypes: [String]
    var imagePixelWidth: Int?
    var imagePixelHeight: Int?

    static let empty = ClipboardContentMetadata(
        contentType: "",
        detailText: "",
        sourcePaths: [],
        fileNames: [],
        pasteboardTypes: [],
        imagePixelWidth: nil,
        imagePixelHeight: nil
    )
}

struct ClipboardHistoryItem: Codable, Hashable, Identifiable {
    var id: UUID
    var createdAt: Date
    var sourceApplicationName: String
    var sourceBundleIdentifier: String
    var plainText: String
    var previewText: String
    var storedTypes: [ClipboardStoredType]
    var isFavorite: Bool
    var metadata: ClipboardContentMetadata

    var hasFormattedContent: Bool {
        storedTypes.contains { $0.type != NSPasteboard.PasteboardType.string.rawValue }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case sourceApplicationName
        case sourceBundleIdentifier
        case plainText
        case previewText
        case storedTypes
        case isFavorite
        case metadata
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceApplicationName: String,
        sourceBundleIdentifier: String,
        plainText: String,
        previewText: String,
        storedTypes: [ClipboardStoredType],
        isFavorite: Bool = false,
        metadata: ClipboardContentMetadata = .empty
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceApplicationName = sourceApplicationName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.plainText = plainText
        self.previewText = previewText
        self.storedTypes = storedTypes
        self.isFavorite = isFavorite
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sourceApplicationName = try container.decodeIfPresent(String.self, forKey: .sourceApplicationName) ?? "未知应用"
        sourceBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier) ?? ""
        plainText = try container.decodeIfPresent(String.self, forKey: .plainText) ?? ""
        previewText = try container.decodeIfPresent(String.self, forKey: .previewText) ?? ""
        storedTypes = try container.decodeIfPresent([ClipboardStoredType].self, forKey: .storedTypes) ?? []
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        metadata = try container.decodeIfPresent(ClipboardContentMetadata.self, forKey: .metadata) ?? .empty
    }
}

struct AppConfig: Codable {
    var profiles: [DisplayProfile]
    var clipboard: ClipboardConfig
    var archive: ArchiveConfig
    var contextMenu: ContextMenuConfig

    enum CodingKeys: String, CodingKey {
        case profiles
        case clipboard
        case archive
        case contextMenu
    }

    init(profiles: [DisplayProfile], clipboard: ClipboardConfig, archive: ArchiveConfig, contextMenu: ContextMenuConfig) {
        self.profiles = profiles
        self.clipboard = clipboard
        self.archive = archive
        self.contextMenu = contextMenu
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decode([DisplayProfile].self, forKey: .profiles)
        clipboard = try container.decodeIfPresent(ClipboardConfig.self, forKey: .clipboard) ?? .defaultValue
        archive = try container.decodeIfPresent(ArchiveConfig.self, forKey: .archive) ?? .defaultValue
        contextMenu = try container.decodeIfPresent(ContextMenuConfig.self, forKey: .contextMenu)?.normalized() ?? .defaultValue
    }

    static let defaultValue = AppConfig(
        profiles: [.dm73uProDefault],
        clipboard: .defaultValue,
        archive: .defaultValue,
        contextMenu: .defaultValue
    )
}

struct AppState: Codable {
    var pendingReconnects: [PendingReconnect]
    var lastSeenDisplays: [DisplaySnapshot]

    enum CodingKeys: String, CodingKey {
        case pendingReconnects
        case lastSeenDisplays
    }

    init(pendingReconnects: [PendingReconnect], lastSeenDisplays: [DisplaySnapshot]) {
        self.pendingReconnects = pendingReconnects
        self.lastSeenDisplays = lastSeenDisplays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pendingReconnects = try container.decodeIfPresent([PendingReconnect].self, forKey: .pendingReconnects) ?? []
        lastSeenDisplays = try container.decodeIfPresent([DisplaySnapshot].self, forKey: .lastSeenDisplays) ?? []
    }

    static let empty = AppState(pendingReconnects: [], lastSeenDisplays: [])
}

struct ProfileRuntimeStatus {
    var status: ManagedDisplayStatus
    var message: String
    var updatedAt: Date

    static let unknown = ProfileRuntimeStatus(status: .unknown, message: "", updatedAt: Date())
}

enum VCPCodeParser {
    static func parse(_ text: String) -> UInt8? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: UInt64?
        if trimmed.lowercased().hasPrefix("0x") {
            value = UInt64(trimmed.dropFirst(2), radix: 16)
        } else {
            value = UInt64(trimmed, radix: 10)
        }
        guard let value, value <= UInt8.max else {
            return nil
        }
        return UInt8(value)
    }

    static func normalizeHex(_ value: String) -> String {
        guard let parsed = parse(value) else {
            return value
        }
        return String(format: "0x%02X", parsed)
    }
}
