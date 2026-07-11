import Foundation

public enum ArchiveFormat: String, Codable, CaseIterable, Hashable, Sendable {
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

    public var title: String {
        switch self {
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .tarGzip: return "tar.gz / tgz"
        case .tarBzip2: return "tar.bz2 / tbz"
        case .tarXz: return "tar.xz / txz"
        case .gzip: return "GZIP"
        case .bzip2: return "BZIP2"
        case .xz: return "XZ"
        case .sevenZip: return "7Z"
        case .rar: return "RAR"
        }
    }

    public var detail: String {
        switch self {
        case .zip: return "跨平台 ZIP，支持加密压缩与解压。"
        case .tar: return "Unix tar 归档，不带压缩。"
        case .tarGzip: return "gzip 压缩的 tar 归档。"
        case .tarBzip2: return "bzip2 压缩的 tar 归档。"
        case .tarXz: return "xz 压缩的 tar 归档。"
        case .gzip: return "单文件 gzip 压缩。"
        case .bzip2: return "单文件 bzip2 压缩。"
        case .xz: return "单文件 xz 压缩。"
        case .sevenZip: return "内置引擎支持读取、解压和创建。"
        case .rar: return "内置引擎支持读取和解压；创建需要额外安装 rar。"
        }
    }

    public var archiveExtension: String {
        switch self {
        case .zip: return "zip"
        case .tar: return "tar"
        case .tarGzip: return "tar.gz"
        case .tarBzip2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .gzip: return "gz"
        case .bzip2: return "bz2"
        case .xz: return "xz"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        }
    }

    public var supportsCompressionPassword: Bool {
        self == .zip || self == .sevenZip || self == .rar
    }

    public var isSingleFileCompression: Bool {
        self == .gzip || self == .bzip2 || self == .xz
    }

    public var supportsCompressionLevel: Bool { self != .tar }
}

public enum ArchiveFormatDetector {
    public static func detect(url: URL) -> ArchiveFormat? {
        if let signature = try? readPrefix(of: url, count: 560), let detected = detect(signature: signature) {
            return refineContainerFormat(detected, fileName: url.lastPathComponent)
        }
        return detect(fileName: url.lastPathComponent)
    }

    public static func detect(fileName: String) -> ArchiveFormat? {
        let name = fileName.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGzip }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") { return .tarBzip2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar") { return .tar }
        if name.hasSuffix(".gz") { return .gzip }
        if name.hasSuffix(".bz2") { return .bzip2 }
        if name.hasSuffix(".xz") { return .xz }
        if name.hasSuffix(".7z") { return .sevenZip }
        if name.hasSuffix(".rar") { return .rar }
        return nil
    }

    public static func detect(signature data: Data) -> ArchiveFormat? {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) ||
            bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) ||
            bytes.starts(with: [0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if bytes.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }
        if bytes.starts(with: [0x1F, 0x8B]) { return .gzip }
        if bytes.starts(with: [0x42, 0x5A, 0x68]) { return .bzip2 }
        if bytes.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if bytes.count >= 262, String(bytes: bytes[257..<262], encoding: .ascii) == "ustar" { return .tar }
        return nil
    }

    private static func refineContainerFormat(_ format: ArchiveFormat, fileName: String) -> ArchiveFormat {
        guard format == .gzip || format == .bzip2 || format == .xz else { return format }
        let byName = detect(fileName: fileName)
        switch (format, byName) {
        case (.gzip, .tarGzip): return .tarGzip
        case (.bzip2, .tarBzip2): return .tarBzip2
        case (.xz, .tarXz): return .tarXz
        default: return format
        }
    }

    private static func readPrefix(of url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }
}
