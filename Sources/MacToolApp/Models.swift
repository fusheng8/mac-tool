import AppKit
import Carbon.HIToolbox
import Foundation
import MacToolCore

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
        if runtimeDisplayID != 0, other.runtimeDisplayID != 0, runtimeDisplayID == other.runtimeDisplayID {
            return true
        }

        let identities: [(String?, String?)] = [
            (Self.normalizedIdentity(edidUUID), Self.normalizedIdentity(other.edidUUID)),
            (Self.normalizedIdentity(alphanumericSerial), Self.normalizedIdentity(other.alphanumericSerial)),
            (vendorModelSerialIdentity, other.vendorModelSerialIdentity),
            (Self.normalizedIdentity(ioLocation), Self.normalizedIdentity(other.ioLocation))
        ]
        for (lhs, rhs) in identities {
            if let lhs, let rhs {
                return lhs == rhs
            }
        }

        let hasStrongIdentity = identities.contains { $0.0 != nil || $0.1 != nil }
        guard !hasStrongIdentity else { return false }
        return Self.normalizedIdentity(displayName) == Self.normalizedIdentity(other.displayName)
            && Self.normalizedIdentity(displayName) != nil
            && isBuiltIn == other.isBuiltIn
    }

    var vendorModelSerialIdentity: String? {
        guard let vendor = Self.normalizedIdentity(vendorId),
              let model = Self.normalizedIdentity(modelId),
              let serial = Self.normalizedIdentity(serialNumber) else { return nil }
        return "\(vendor)|\(model)|\(serial)"
    }

    static func normalizedIdentity(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let significant = normalized
            .replacingOccurrences(of: "0x", with: "")
            .filter { $0.isLetter || $0.isNumber }
        guard !significant.isEmpty, significant.contains(where: { $0 != "0" }) else { return nil }
        return normalized
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

    static func normalizedThreshold(_ value: Int) -> Int {
        min(100, max(1, value))
    }

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
        self.matchThreshold = Self.normalizedThreshold(matchThreshold)
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
        matchThreshold = Self.normalizedThreshold(
            try container.decodeIfPresent(Int.self, forKey: .matchThreshold) ?? 80
        )
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
        enabled: false,
        allowSoftDisconnect: false,
        autoReconnect: false,
        autoReconnectDelaySeconds: 30,
        externalOnly: true,
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
        self.autoReconnectDelaySeconds = Self.normalizedReconnectDelay(autoReconnectDelaySeconds)
        self.externalOnly = externalOnly
        self.confirmBeforeDisconnect = confirmBeforeDisconnect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        allowSoftDisconnect = try container.decodeIfPresent(Bool.self, forKey: .allowSoftDisconnect) ?? false
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
        autoReconnectDelaySeconds = Self.normalizedReconnectDelay(
            try container.decodeIfPresent(Int.self, forKey: .autoReconnectDelaySeconds) ?? 30
        )
        externalOnly = try container.decodeIfPresent(Bool.self, forKey: .externalOnly) ?? true
        confirmBeforeDisconnect = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeDisconnect) ?? true
    }

    static func normalizedReconnectDelay(_ value: Int) -> Int {
        min(3600, max(5, value))
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
            return "在剪贴板顶部应用筛选条中切换。"
        default:
            return "剪贴板历史面板打开时生效。"
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
    var structuredPreviewLimitKB: Int

    static let defaultValue = ClipboardConfig(
        enabled: true,
        hotKeyEnabled: true,
        hotKey: .defaultClipboard,
        shortcuts: .defaultValue,
        maxHistoryCount: 1000,
        recordingPaused: false,
        excludeKnownPasswordManagers: true,
        excludedBundleIdentifiers: [],
        retentionDays: ClipboardPrivacyPolicy.defaultRetentionDays,
        pollIntervalMilliseconds: 650,
        structuredPreviewLimitKB: 256
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
        case structuredPreviewLimitKB
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
        pollIntervalMilliseconds: Int = 650,
        structuredPreviewLimitKB: Int = 256
    ) {
        self.enabled = enabled
        self.hotKeyEnabled = hotKeyEnabled
        self.hotKey = hotKey
        self.shortcuts = shortcuts
        self.maxHistoryCount = Self.normalizedMaxHistoryCount(maxHistoryCount)
        self.recordingPaused = recordingPaused
        self.excludeKnownPasswordManagers = excludeKnownPasswordManagers
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.retentionDays = Self.normalizedRetentionDays(retentionDays)
        self.pollIntervalMilliseconds = Self.normalizedPollIntervalMilliseconds(pollIntervalMilliseconds)
        self.structuredPreviewLimitKB = Self.normalizedStructuredPreviewLimitKB(structuredPreviewLimitKB)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hotKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? true
        hotKey = try container.decodeIfPresent(HotKeyConfig.self, forKey: .hotKey) ?? .defaultClipboard
        shortcuts = try container.decodeIfPresent(ClipboardShortcutSettings.self, forKey: .shortcuts) ?? .defaultValue
        maxHistoryCount = Self.normalizedMaxHistoryCount(
            try container.decodeIfPresent(Int.self, forKey: .maxHistoryCount) ?? 1000
        )
        recordingPaused = try container.decodeIfPresent(Bool.self, forKey: .recordingPaused) ?? false
        excludeKnownPasswordManagers = try container.decodeIfPresent(Bool.self, forKey: .excludeKnownPasswordManagers) ?? true
        excludedBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .excludedBundleIdentifiers) ?? []
        retentionDays = Self.normalizedRetentionDays(
            try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? ClipboardPrivacyPolicy.defaultRetentionDays
        )
        pollIntervalMilliseconds = Self.normalizedPollIntervalMilliseconds(
            try container.decodeIfPresent(Int.self, forKey: .pollIntervalMilliseconds) ?? 650
        )
        structuredPreviewLimitKB = Self.normalizedStructuredPreviewLimitKB(
            try container.decodeIfPresent(Int.self, forKey: .structuredPreviewLimitKB) ?? 256
        )
    }

    static func normalizedPollIntervalMilliseconds(_ value: Int) -> Int {
        min(10_000, max(200, value))
    }

    static func normalizedMaxHistoryCount(_ value: Int) -> Int {
        min(10_000, max(10, value))
    }

    static func normalizedRetentionDays(_ value: Int) -> Int {
        min(365, max(0, value))
    }

    func normalized() -> ClipboardConfig {
        var result = self
        result.maxHistoryCount = Self.normalizedMaxHistoryCount(maxHistoryCount)
        result.retentionDays = Self.normalizedRetentionDays(retentionDays)
        result.pollIntervalMilliseconds = Self.normalizedPollIntervalMilliseconds(pollIntervalMilliseconds)
        result.structuredPreviewLimitKB = Self.normalizedStructuredPreviewLimitKB(structuredPreviewLimitKB)
        result.excludedBundleIdentifiers = excludedBundleIdentifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return result
    }

    static func normalizedStructuredPreviewLimitKB(_ value: Int) -> Int {
        min(4096, max(16, value))
    }

    var structuredPreviewLimitBytes: Int {
        structuredPreviewLimitKB * 1024
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

    var supportsCustomTargetApplication: Bool {
        switch self {
        case .openWithIDEA, .openWithTypora, .openWithVSCode, .openInTerminal, .openInWarp:
            return true
        default:
            return false
        }
    }
}

struct FinderTargetApplication: Codable, Hashable {
    var bundleIdentifier: String
    var displayName: String
    var lastKnownPath: String

    init(bundleIdentifier: String, displayName: String, lastKnownPath: String) {
        self.bundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastKnownPath = lastKnownPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalized: FinderTargetApplication? {
        let value = FinderTargetApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            lastKnownPath: lastKnownPath
        )
        guard !value.bundleIdentifier.isEmpty || !value.lastKnownPath.isEmpty else { return nil }
        return value
    }
}

struct ContextMenuItemConfig: Codable, Hashable, Identifiable {
    var id: ContextMenuItemID
    var enabled: Bool
    var children: [ContextMenuItemConfig]
    var customTitle: String?
    var targetApplication: FinderTargetApplication?

    init(
        id: ContextMenuItemID,
        enabled: Bool = true,
        children: [ContextMenuItemConfig] = [],
        customTitle: String? = nil,
        targetApplication: FinderTargetApplication? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.children = children
        self.customTitle = customTitle
        self.targetApplication = targetApplication
    }

    enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case children
        case customTitle
        case targetApplication
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ContextMenuItemID.self, forKey: .id)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        children = try container.decodeIfPresent([ContextMenuItemConfig].self, forKey: .children) ?? []
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        targetApplication = try container.decodeIfPresent(FinderTargetApplication.self, forKey: .targetApplication)
    }

    var displayTitle: String {
        let normalized = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? id.title : normalized
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

    func item(for id: ContextMenuItemID) -> ContextMenuItemConfig? {
        func find(in items: [ContextMenuItemConfig]) -> ContextMenuItemConfig? {
            for item in items {
                if item.id == id { return item }
                if let child = find(in: item.children) { return child }
            }
            return nil
        }
        return find(in: items)
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
                children: normalize(items: item.children, defaults: defaultItem.children),
                customTitle: normalizedTitle(item.customTitle),
                targetApplication: item.id.supportsCustomTargetApplication ? item.targetApplication?.normalized : nil
            )
        }

        for defaultItem in defaults where !normalizedItems.contains(where: { $0.id == defaultItem.id }) {
            normalizedItems.append(defaultItem)
        }
        return normalizedItems
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : String(value.prefix(60))
    }
}

struct ClipboardStoredType: Codable, Hashable {
    var type: String
    var data: Data
    var itemIndex: Int

    init(type: String, data: Data, itemIndex: Int = 0) {
        self.type = type
        self.data = data
        self.itemIndex = max(0, itemIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case itemIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        data = try container.decode(Data.self, forKey: .data)
        itemIndex = max(0, try container.decodeIfPresent(Int.self, forKey: .itemIndex) ?? 0)
    }
}

struct ClipboardContentMetadata: Codable, Hashable {
    var contentType: String
    var detailText: String
    var sourcePaths: [String]
    var fileNames: [String]
    var pasteboardTypes: [String]
    var imagePixelWidth: Int?
    var imagePixelHeight: Int?
    var thumbnailFileName: String?
    var contentByteCount: Int?

    static let empty = ClipboardContentMetadata(
        contentType: "",
        detailText: "",
        sourcePaths: [],
        fileNames: [],
        pasteboardTypes: [],
        imagePixelWidth: nil,
        imagePixelHeight: nil,
        thumbnailFileName: nil,
        contentByteCount: nil
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
    static let currentSchemaVersion = 4

    var schemaVersion: Int
    var profiles: [DisplayProfile]
    var clipboard: ClipboardConfig
    var archive: ArchiveConfig
    var contextMenu: ContextMenuConfig

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profiles
        case clipboard
        case archive
        case contextMenu
    }

    init(
        schemaVersion: Int = AppConfig.currentSchemaVersion,
        profiles: [DisplayProfile],
        clipboard: ClipboardConfig,
        archive: ArchiveConfig,
        contextMenu: ContextMenuConfig
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.clipboard = clipboard
        self.archive = archive
        self.contextMenu = contextMenu
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        profiles = try container.decode([DisplayProfile].self, forKey: .profiles)
        clipboard = try container.decodeIfPresent(ClipboardConfig.self, forKey: .clipboard) ?? .defaultValue
        archive = try container.decodeIfPresent(ArchiveConfig.self, forKey: .archive) ?? .defaultValue
        contextMenu = try container.decodeIfPresent(ContextMenuConfig.self, forKey: .contextMenu)?.normalized() ?? .defaultValue
    }

    static let defaultValue = AppConfig(
        profiles: [],
        clipboard: .defaultValue,
        archive: .defaultValue,
        contextMenu: .defaultValue
    )

    func normalized() -> AppConfig {
        let requiresPersistentDisplayCloseMigration = schemaVersion < 4
        var result = self
        result.schemaVersion = Self.currentSchemaVersion
        result.clipboard = clipboard.normalized()
        result.contextMenu = contextMenu.normalized()
        if result.archive.enabledFormats.isEmpty {
            result.archive = .defaultValue
        } else {
            result.archive.defaultCompressionLevel = ArchiveConfig.normalizedCompressionLevel(
                result.archive.defaultCompressionLevel
            )
        }
        result.profiles = profiles.map { profile in
            var normalizedProfile = profile
            normalizedProfile.match.matchThreshold = DisplayMatchRule.normalizedThreshold(profile.match.matchThreshold)
            if requiresPersistentDisplayCloseMigration {
                normalizedProfile.disconnect.autoReconnect = false
            }
            normalizedProfile.disconnect.autoReconnectDelaySeconds = DisconnectConfig.normalizedReconnectDelay(
                profile.disconnect.autoReconnectDelaySeconds
            )
            return normalizedProfile
        }
        return result
    }
}

struct AppState: Codable {
    var pendingReconnects: [PendingReconnect]
    var lastSeenDisplays: [DisplaySnapshot]
    var onboardingVersion: Int
    var privacyNoticeVersion: Int
    var displayAutomationConsentVersion: Int
    var displayAutomationApproved: Bool
    var appDisconnectedDisplayIDs: [UInt32]
    var lastCleanShutdown: Bool

    enum CodingKeys: String, CodingKey {
        case pendingReconnects
        case lastSeenDisplays
        case onboardingVersion
        case privacyNoticeVersion
        case displayAutomationConsentVersion
        case displayAutomationApproved
        case appDisconnectedDisplayIDs
        case lastCleanShutdown
    }

    init(
        pendingReconnects: [PendingReconnect],
        lastSeenDisplays: [DisplaySnapshot],
        onboardingVersion: Int = 0,
        privacyNoticeVersion: Int = 0,
        displayAutomationConsentVersion: Int = 0,
        displayAutomationApproved: Bool = false,
        appDisconnectedDisplayIDs: [UInt32] = [],
        lastCleanShutdown: Bool = true
    ) {
        self.pendingReconnects = pendingReconnects
        self.lastSeenDisplays = lastSeenDisplays
        self.onboardingVersion = onboardingVersion
        self.privacyNoticeVersion = privacyNoticeVersion
        self.displayAutomationConsentVersion = displayAutomationConsentVersion
        self.displayAutomationApproved = displayAutomationApproved
        self.appDisconnectedDisplayIDs = appDisconnectedDisplayIDs
        self.lastCleanShutdown = lastCleanShutdown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pendingReconnects = try container.decodeIfPresent([PendingReconnect].self, forKey: .pendingReconnects) ?? []
        lastSeenDisplays = try container.decodeIfPresent([DisplaySnapshot].self, forKey: .lastSeenDisplays) ?? []
        onboardingVersion = try container.decodeIfPresent(Int.self, forKey: .onboardingVersion) ?? 0
        privacyNoticeVersion = try container.decodeIfPresent(Int.self, forKey: .privacyNoticeVersion) ?? 0
        displayAutomationConsentVersion = try container.decodeIfPresent(Int.self, forKey: .displayAutomationConsentVersion) ?? 0
        displayAutomationApproved = try container.decodeIfPresent(Bool.self, forKey: .displayAutomationApproved) ?? false
        appDisconnectedDisplayIDs = try container.decodeIfPresent([UInt32].self, forKey: .appDisconnectedDisplayIDs) ?? []
        lastCleanShutdown = try container.decodeIfPresent(Bool.self, forKey: .lastCleanShutdown) ?? true
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
