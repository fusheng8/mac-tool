import Foundation
import MacToolCore

enum ArchivePresetID: String, CaseIterable {
    case universalZip
    case sourcePackage
    case encryptedArchive
    case custom
}
struct ArchivePreset: Equatable, Identifiable {
    enum Behavior: Equatable {
        case fixed(format: ArchiveFormat, compressionLevel: Int, stripMacMetadata: Bool)
        case options
    }

    let id: ArchivePresetID
    let title: String
    let detail: String
    let symbolName: String
    let behavior: Behavior

    static let all: [ArchivePreset] = [
        ArchivePreset(
            id: .universalZip,
            title: "通用 ZIP",
            detail: "跨平台 · 等级 6 · 清理 macOS 元数据",
            symbolName: "archivebox",
            behavior: .fixed(format: .zip, compressionLevel: 6, stripMacMetadata: true)
        ),
        ArchivePreset(
            id: .sourcePackage,
            title: "源码包",
            detail: "tar.gz · 等级 6 · 保留源码目录结构",
            symbolName: "chevron.left.forwardslash.chevron.right",
            behavior: .fixed(format: .tarGzip, compressionLevel: 6, stripMacMetadata: true)
        ),
        ArchivePreset(
            id: .encryptedArchive,
            title: "加密归档",
            detail: "选择支持密码的格式并进入安全参数流程",
            symbolName: "lock",
            behavior: .options
        ),
        ArchivePreset(
            id: .custom,
            title: "自定义",
            detail: "打开完整格式、等级、密码和目录选项",
            symbolName: "slider.horizontal.3",
            behavior: .options
        )
    ]

    static func preset(_ id: ArchivePresetID) -> ArchivePreset {
        all.first(where: { $0.id == id })!
    }

    func compressionOptions(archiveName: String, wrapInFolder: Bool) -> ArchiveCompressionOptions? {
        guard case let .fixed(format, compressionLevel, stripMacMetadata) = behavior else { return nil }
        return ArchiveCompressionOptions(
            archiveName: archiveName,
            format: format,
            stripMacMetadata: stripMacMetadata,
            compressionLevel: compressionLevel,
            password: nil,
            wrapInFolder: wrapInFolder
        )
    }
}
