import AppKit
import CoreFoundation
import Foundation

struct ArchiveBrowserEntry: Hashable {
    var path: String
    var size: Int64?
    var isDirectory: Bool
    var modifiedAt: Date?

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent
    }
}

enum ArchiveBrowserError: LocalizedError {
    case unsupportedArchive(String)
    case unsupportedModification(String)
    case missingTool(String)
    case passwordRequired
    case extractionFailed(String)
    case previewUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive(let name):
            return "暂不支持预览该压缩包：\(name)"
        case .unsupportedModification(let message):
            return message
        case .missingTool(let tool):
            return archiveMissingToolMessage(tool)
        case .passwordRequired:
            return "压缩包需要密码"
        case .extractionFailed(let message):
            return message
        case .previewUnavailable:
            return "该文件暂不支持预览"
        }
    }
}

final class ArchiveBrowserService {
    private let archiveURL: URL
    private let kind: ArchiveBrowserKind
    private let fileManager = FileManager.default

    init(archiveURL: URL) throws {
        self.archiveURL = archiveURL
        guard let kind = ArchiveBrowserKind(url: archiveURL) else {
            throw ArchiveBrowserError.unsupportedArchive(archiveURL.lastPathComponent)
        }
        self.kind = kind
    }

    var title: String {
        archiveURL.lastPathComponent
    }

    var supportsPassword: Bool {
        switch kind {
        case .zip, .sevenZip, .rar:
            return true
        case .tar, .tarGzip, .tarBzip2, .tarXz, .gzip, .bzip2, .xz:
            return false
        }
    }

    var canAddItems: Bool {
        switch kind {
        case .zip, .tar, .sevenZip, .rar:
            return true
        case .tarGzip, .tarBzip2, .tarXz, .gzip, .bzip2, .xz:
            return false
        }
    }

    var canDeleteItems: Bool {
        switch kind {
        case .zip, .sevenZip, .rar:
            return true
        case .tar, .tarGzip, .tarBzip2, .tarXz, .gzip, .bzip2, .xz:
            return false
        }
    }

    func requiresPassword() throws -> Bool {
        guard supportsPassword else {
            return false
        }

        do {
            return try listEntries(password: nil).mayRequirePassword
        } catch ArchiveBrowserError.passwordRequired {
            return true
        }
    }

    func validatePassword(_ password: String) throws {
        guard supportsPassword else {
            return
        }
        guard !password.isEmpty else {
            throw ArchiveBrowserError.passwordRequired
        }

        switch kind {
        case .zip:
            do {
                try run(tool: "unzip", arguments: ["-tqq", "-P", password, archiveURL.path])
            } catch ArchiveBrowserError.missingTool {
                throw ArchiveBrowserError.missingTool("unzip")
            } catch {
                throw ArchiveBrowserError.passwordRequired
            }
        case .sevenZip:
            guard let tool = firstAvailableTool(["7zz", "7z"]) else {
                throw ArchiveBrowserError.missingTool("7z/7zz")
            }
            do {
                try run(executableURL: tool, arguments: ["t", "-p\(password)", archiveURL.path])
            } catch ArchiveBrowserError.missingTool {
                throw ArchiveBrowserError.missingTool("7z/7zz")
            } catch {
                throw ArchiveBrowserError.passwordRequired
            }
        case .rar:
            if let tool = firstAvailableTool(["unrar"]) {
                do {
                    try run(executableURL: tool, arguments: ["t", "-p\(password)", archiveURL.path])
                } catch {
                    throw ArchiveBrowserError.passwordRequired
                }
                return
            }
            guard let tool = firstAvailableTool(["7zz", "7z"]) else {
                throw ArchiveBrowserError.missingTool("unrar/7z/7zz")
            }
            do {
                try run(executableURL: tool, arguments: ["t", "-p\(password)", archiveURL.path])
            } catch {
                throw ArchiveBrowserError.passwordRequired
            }
        case .tar, .tarGzip, .tarBzip2, .tarXz, .gzip, .bzip2, .xz:
            return
        }
    }

    func listEntries(password: String? = nil) throws -> (entries: [ArchiveBrowserEntry], mayRequirePassword: Bool) {
        switch kind {
        case .zip:
            return try listZipEntries()
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            return (try listTarEntries(), false)
        case .gzip, .bzip2, .xz:
            return ([ArchiveBrowserEntry(path: singleFileName(), size: nil, isDirectory: false)], false)
        case .sevenZip:
            return try listSevenZipEntries(password: password)
        case .rar:
            return try listRarEntries(password: password)
        }
    }

    func extract(entries: [ArchiveBrowserEntry], to destination: URL, password: String?) throws {
        let fileEntries = entries.filter { !$0.isDirectory }
        guard !fileEntries.isEmpty else { return }

        switch kind {
        case .zip:
            try extractZip(entries: fileEntries, to: destination, password: password)
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            try extractTar(entries: fileEntries, to: destination)
        case .gzip, .bzip2, .xz:
            try extractSingleFile(to: destination)
        case .sevenZip:
            try extractSevenZip(entries: fileEntries, to: destination, password: password)
        case .rar:
            try extractRar(entries: fileEntries, to: destination, password: password)
        }
    }

    func extractForPreview(entry: ArchiveBrowserEntry, password: String?) throws -> URL {
        guard !entry.isDirectory else {
            throw ArchiveBrowserError.previewUnavailable
        }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAssistantArchivePreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try extract(entries: [entry], to: tempRoot, password: password)
        let directURL = tempRoot.appendingPathComponent(entry.path)
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }
        let fallbackURL = tempRoot.appendingPathComponent(entry.displayName)
        if fileManager.fileExists(atPath: fallbackURL.path) {
            return fallbackURL
        }
        if let url = try materializedFiles(in: tempRoot).first {
            return url
        }
        throw ArchiveBrowserError.previewUnavailable
    }

    func addItems(_ urls: [URL], password: String?) throws {
        guard !urls.isEmpty else { return }
        switch kind {
        case .zip:
            let context = try modificationContext(urls: urls)
            var arguments = ["-qry"]
            if let password, !password.isEmpty {
                arguments += ["-P", password]
            }
            arguments.append(archiveURL.path)
            arguments += context.names
            try run(tool: "zip", arguments: arguments, currentDirectory: context.parent)
        case .tar:
            let context = try modificationContext(urls: urls)
            try run(tool: "tar", arguments: ["-rf", archiveURL.path, "-C", context.parent.path] + context.names)
        case .sevenZip:
            guard let tool = firstAvailableTool(["7zz", "7z"]) else {
                throw ArchiveBrowserError.missingTool("7z/7zz")
            }
            var arguments = ["a", "-y"]
            if let password, !password.isEmpty {
                arguments.append("-p\(password)")
            }
            arguments.append(archiveURL.path)
            arguments += urls.map(\.path)
            try run(executableURL: tool, arguments: arguments)
        case .rar:
            guard let tool = firstAvailableTool(["rar"]) else {
                throw ArchiveBrowserError.missingTool("rar")
            }
            try run(executableURL: tool, arguments: ["a", "-idq", archiveURL.path] + urls.map(\.path))
        case .tarGzip, .tarBzip2, .tarXz, .gzip, .bzip2, .xz:
            throw ArchiveBrowserError.unsupportedModification("该格式不支持安全地直接追加内容，请先解压后重新压缩。")
        }
    }

    func delete(entries: [ArchiveBrowserEntry], password: String?) throws {
        let paths = entries.map(\.path)
        try delete(paths: paths, password: password)
    }

    @discardableResult
    func cleanMetadata(password: String?) throws -> Int {
        let cleanupPaths = try allEntries(password: password)
            .filter(isCleanupEntry)
            .map(\.path)
        guard !cleanupPaths.isEmpty else { return 0 }
        try delete(paths: cleanupPaths, password: password)
        return cleanupPaths.count
    }

    private func listZipEntries() throws -> (entries: [ArchiveBrowserEntry], mayRequirePassword: Bool) {
        let result = try parseZipCentralDirectory()
        return (result.entries.filter(isVisibleEntry), result.hasEncryptedEntry)
    }

    private func allEntries(password: String?) throws -> [ArchiveBrowserEntry] {
        switch kind {
        case .zip:
            return try parseZipCentralDirectory().entries
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            return try listTarEntries(includeHidden: true)
        case .sevenZip, .rar:
            return try listSevenZipEntries(password: password, includeHidden: true).entries
        case .gzip, .bzip2, .xz:
            return [ArchiveBrowserEntry(path: singleFileName(), size: nil, isDirectory: false)]
        }
    }

    private func parseZipCentralDirectory() throws -> (entries: [ArchiveBrowserEntry], hasEncryptedEntry: Bool) {
        let data = try Data(contentsOf: archiveURL)
        guard
            let endOffset = findZipEndOfCentralDirectory(in: data),
            let centralDirectorySize = data.uint32LE(at: endOffset + 12),
            let centralDirectoryOffset = data.uint32LE(at: endOffset + 16)
        else {
            throw ArchiveBrowserError.extractionFailed("无法读取 ZIP 文件目录")
        }

        var offset = Int(centralDirectoryOffset)
        let end = min(data.count, offset + Int(centralDirectorySize))
        var entries: [ArchiveBrowserEntry] = []
        var hasEncryptedEntry = false

        while offset + 46 <= end, data.uint32LE(at: offset) == 0x0201_4B50 {
            guard
                let flags = data.uint16LE(at: offset + 8),
                let modifiedTime = data.uint16LE(at: offset + 12),
                let modifiedDate = data.uint16LE(at: offset + 14),
                let uncompressedSize = data.uint32LE(at: offset + 24),
                let nameLength = data.uint16LE(at: offset + 28),
                let extraLength = data.uint16LE(at: offset + 30),
                let commentLength = data.uint16LE(at: offset + 32)
            else {
                break
            }

            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)
            let entryEnd = nameEnd + Int(extraLength) + Int(commentLength)
            guard nameEnd <= data.count, entryEnd <= data.count else {
                break
            }

            let nameData = data.subdata(in: nameStart..<nameEnd)
            let path = decodeZipPath(nameData, prefersUTF8: flags & 0x0800 != 0)
            if !path.isEmpty {
                let size = uncompressedSize == UInt32.max ? nil : Int64(uncompressedSize)
                entries.append(ArchiveBrowserEntry(
                    path: path,
                    size: size,
                    isDirectory: path.hasSuffix("/"),
                    modifiedAt: dateFromDOS(date: modifiedDate, time: modifiedTime)
                ))
            }
            hasEncryptedEntry = hasEncryptedEntry || flags & 0x0001 != 0
            offset = entryEnd
        }

        return (entries, hasEncryptedEntry)
    }

    private func findZipEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let minimumOffset = max(0, data.count - 65_557)
        var offset = data.count - 22
        while offset >= minimumOffset {
            if data.uint32LE(at: offset) == 0x0605_4B50 {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    private func decodeZipPath(_ data: Data, prefersUTF8: Bool) -> String {
        if prefersUTF8, let value = String(data: data, encoding: .utf8) {
            return value
        }

        let fallbackEncodings: [String.Encoding] = [
            .utf8,
            stringEncoding(for: CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)),
            stringEncoding(for: CFStringEncoding(CFStringEncodings.big5.rawValue)),
            stringEncoding(for: CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
        ]

        for encoding in fallbackEncodings {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func stringEncoding(for cfEncoding: CFStringEncoding) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private func dateFromDOS(date: UInt16, time: UInt16) -> Date? {
        let day = Int(date & 0x1F)
        let month = Int((date >> 5) & 0x0F)
        let year = Int((date >> 9) & 0x7F) + 1980
        let second = Int(time & 0x1F) * 2
        let minute = Int((time >> 5) & 0x3F)
        let hour = Int((time >> 11) & 0x1F)
        guard day > 0, month > 0 else { return nil }
        return Calendar.current.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))
    }

    private func listTarEntries(includeHidden: Bool = false) throws -> [ArchiveBrowserEntry] {
        let output = try run(tool: "tar", arguments: ["-tvf", archiveURL.path]).stdout
        let entries = output
            .split(whereSeparator: \.isNewline)
            .compactMap { parseTarLine(String($0)) }
        return includeHidden ? entries : entries.filter(isVisibleEntry)
    }

    private func parseTarLine(_ line: String) -> ArchiveBrowserEntry? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 6 else { return nil }
        let mode = String(parts[0])
        let size = Int64(parts[2])
        let path = parts.dropFirst(5).joined(separator: " ")
        guard !path.isEmpty else { return nil }
        return ArchiveBrowserEntry(path: path, size: size, isDirectory: mode.first == "d" || path.hasSuffix("/"))
    }

    private func listSevenZipEntries(password: String?, includeHidden: Bool = false) throws -> (entries: [ArchiveBrowserEntry], mayRequirePassword: Bool) {
        guard let tool = firstAvailableTool(["7zz", "7z"]) else {
            throw ArchiveBrowserError.missingTool("7z/7zz")
        }
        var arguments = ["l", "-slt"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(archiveURL.path)
        let output = try run(executableURL: tool, arguments: arguments).stdout
        var entries: [ArchiveBrowserEntry] = []
        var currentPath: String?
        var currentSize: Int64?
        var currentAttributes = ""
        var currentModifiedAt: Date?
        var mayRequirePassword = false

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("Path = ") {
                if let currentPath, currentPath != archiveURL.path {
                    entries.append(ArchiveBrowserEntry(
                        path: currentPath,
                        size: currentSize,
                        isDirectory: currentAttributes.hasPrefix("D"),
                        modifiedAt: currentModifiedAt
                    ))
                }
                currentPath = String(line.dropFirst("Path = ".count))
                currentSize = nil
                currentAttributes = ""
                currentModifiedAt = nil
            } else if line.hasPrefix("Size = ") {
                currentSize = Int64(String(line.dropFirst("Size = ".count)))
            } else if line.hasPrefix("Modified = ") {
                currentModifiedAt = parseSevenZipDate(String(line.dropFirst("Modified = ".count)))
            } else if line.hasPrefix("Attributes = ") {
                currentAttributes = String(line.dropFirst("Attributes = ".count))
            } else if line.lowercased().contains("encrypted = +") {
                mayRequirePassword = true
            }
        }
        if let currentPath, currentPath != archiveURL.path {
            entries.append(ArchiveBrowserEntry(
                path: currentPath,
                size: currentSize,
                isDirectory: currentAttributes.hasPrefix("D"),
                modifiedAt: currentModifiedAt
            ))
        }
        return (includeHidden ? entries : entries.filter(isVisibleEntry), mayRequirePassword)
    }

    private func listRarEntries(password: String?, includeHidden: Bool = false) throws -> (entries: [ArchiveBrowserEntry], mayRequirePassword: Bool) {
        guard let tool = firstAvailableTool(["unrar"]) else {
            return try listSevenZipEntries(password: password, includeHidden: includeHidden)
        }

        var arguments = ["lt"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(archiveURL.path)
        let output = try run(executableURL: tool, arguments: arguments).stdout
        let entries = parseUnrarVerboseEntries(output)
        return (includeHidden ? entries : entries.filter(isVisibleEntry), false)
    }

    private func parseUnrarVerboseEntries(_ output: String) -> [ArchiveBrowserEntry] {
        var entries: [ArchiveBrowserEntry] = []
        var currentPath: String?
        var currentSize: Int64?
        var currentType = ""
        var currentModifiedAt: Date?

        func appendCurrentEntry() {
            guard let currentPath else { return }
            entries.append(ArchiveBrowserEntry(
                path: currentPath,
                size: currentSize,
                isDirectory: currentType == "Directory",
                modifiedAt: currentModifiedAt
            ))
        }

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Name: ") {
                appendCurrentEntry()
                currentPath = String(trimmed.dropFirst("Name: ".count))
                currentSize = nil
                currentType = ""
                currentModifiedAt = nil
            } else if trimmed.hasPrefix("Type: ") {
                currentType = String(trimmed.dropFirst("Type: ".count))
            } else if trimmed.hasPrefix("Size: ") {
                currentSize = Int64(String(trimmed.dropFirst("Size: ".count)))
            } else if trimmed.hasPrefix("mtime: ") {
                currentModifiedAt = parseUnrarDate(String(trimmed.dropFirst("mtime: ".count)))
            }
        }
        appendCurrentEntry()
        return entries
    }

    private func parseUnrarDate(_ value: String) -> Date? {
        let normalized = value
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? value
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: normalized.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func delete(paths: [String], password: String?) throws {
        let paths = Array(Set(paths)).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }

        switch kind {
        case .zip:
            try run(tool: "zip", arguments: ["-dq", archiveURL.path] + paths)
        case .sevenZip:
            guard let tool = firstAvailableTool(["7zz", "7z"]) else {
                throw ArchiveBrowserError.missingTool("7z/7zz")
            }
            var arguments = ["d", "-y"]
            if let password, !password.isEmpty {
                arguments.append("-p\(password)")
            }
            arguments.append(archiveURL.path)
            arguments += paths
            try run(executableURL: tool, arguments: arguments)
        case .rar:
            guard let tool = firstAvailableTool(["rar"]) else {
                throw ArchiveBrowserError.missingTool("rar")
            }
            try run(executableURL: tool, arguments: ["d", "-idq", archiveURL.path] + paths)
        case .tar, .tarGzip, .tarBzip2, .tarXz, .gzip, .bzip2, .xz:
            throw ArchiveBrowserError.unsupportedModification("该格式不支持安全地直接删除内容，请先解压后重新压缩。")
        }
    }

    private func parseSevenZipDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func extractZip(entries: [ArchiveBrowserEntry], to destination: URL, password: String?) throws {
        var arguments = ["-qq"]
        if let password, !password.isEmpty {
            arguments += ["-P", password]
        }
        arguments.append(archiveURL.path)
        arguments += entries.map(\.path)
        arguments += ["-d", destination.path]
        try run(tool: "unzip", arguments: arguments)
    }

    private func extractTar(entries: [ArchiveBrowserEntry], to destination: URL) throws {
        try run(tool: "tar", arguments: ["-xf", archiveURL.path, "-C", destination.path] + entries.map(\.path))
    }

    private func extractSevenZip(entries: [ArchiveBrowserEntry], to destination: URL, password: String?) throws {
        guard let tool = firstAvailableTool(["7zz", "7z"]) else {
            throw ArchiveBrowserError.missingTool("7z/7zz")
        }
        var arguments = ["x", "-y", "-o\(destination.path)"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(archiveURL.path)
        arguments += entries.map(\.path)
        try run(executableURL: tool, arguments: arguments)
    }

    private func extractRar(entries: [ArchiveBrowserEntry], to destination: URL, password: String?) throws {
        if let tool = firstAvailableTool(["unrar"]) {
            var arguments = ["x", "-idq", "-y"]
            if let password, !password.isEmpty {
                arguments.append("-p\(password)")
            }
            arguments.append(archiveURL.path)
            arguments += entries.map(\.path)
            arguments.append(destination.path)
            try run(executableURL: tool, arguments: arguments)
            return
        }

        guard let tool = firstAvailableTool(["7zz", "7z"]) else {
            throw ArchiveBrowserError.missingTool("unrar/7z/7zz")
        }
        var arguments = ["x", "-y", "-o\(destination.path)"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(archiveURL.path)
        arguments += entries.map(\.path)
        try run(executableURL: tool, arguments: arguments)
    }

    private func extractSingleFile(to destination: URL) throws {
        let outputURL = uniqueURL(in: destination, preferredName: singleFileName(), isDirectory: false)
        switch kind {
        case .gzip:
            try run(tool: "gzip", arguments: ["-dc", archiveURL.path], standardOutputFile: outputURL)
        case .bzip2:
            try run(tool: "bzip2", arguments: ["-dc", archiveURL.path], standardOutputFile: outputURL)
        case .xz:
            guard let tool = firstAvailableTool(["xz", "unxz"]) else {
                throw ArchiveBrowserError.missingTool("xz/unxz")
            }
            try run(executableURL: tool, arguments: ["-dc", archiveURL.path], standardOutputFile: outputURL)
        default:
            break
        }
    }

    private func singleFileName() -> String {
        let fileName = archiveURL.lastPathComponent
        for suffix in [".gz", ".bz2", ".xz"] where fileName.lowercased().hasSuffix(suffix) {
            return String(fileName.dropLast(suffix.count))
        }
        return archiveURL.deletingPathExtension().lastPathComponent
    }

    private func isVisibleEntry(_ entry: ArchiveBrowserEntry) -> Bool {
        let parts = entry.path.split(separator: "/").map(String.init)
        guard !parts.contains("__MACOSX") else { return false }
        let last = parts.last ?? entry.path
        return last != ".DS_Store" && !last.hasPrefix("._")
    }

    private func isCleanupEntry(_ entry: ArchiveBrowserEntry) -> Bool {
        let parts = entry.path.split(separator: "/").map(String.init)
        guard let last = parts.last else {
            return false
        }
        return parts.contains("__MACOSX") || last == ".DS_Store" || last.hasPrefix("._")
    }

    private func modificationContext(urls: [URL]) throws -> (parent: URL, names: [String]) {
        guard let first = urls.first else {
            return (archiveURL.deletingLastPathComponent(), [])
        }
        let parent = first.deletingLastPathComponent().standardizedFileURL
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == parent.path }) else {
            throw ArchiveBrowserError.unsupportedModification("一次添加的文件需要位于同一目录。")
        }
        return (parent, urls.map(\.lastPathComponent))
    }

    private func materializedFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private func uniqueURL(in directory: URL, preferredName: String, isDirectory: Bool) -> URL {
        let nameURL = URL(fileURLWithPath: preferredName)
        let fileExtension = isDirectory ? "" : nameURL.pathExtension
        let baseName = fileExtension.isEmpty ? preferredName : String(preferredName.dropLast(fileExtension.count + 1))
        func candidate(_ index: Int) -> URL {
            let name = index == 0 ? baseName : "\(baseName) \(index + 1)"
            if isDirectory || fileExtension.isEmpty {
                return directory.appendingPathComponent(name, isDirectory: isDirectory)
            }
            return directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        }
        var index = 0
        var url = candidate(index)
        while fileManager.fileExists(atPath: url.path) {
            index += 1
            url = candidate(index)
        }
        return url
    }

    @discardableResult
    private func run(
        tool: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        standardOutputFile: URL? = nil
    ) throws -> CommandResult {
        guard let executableURL = firstAvailableTool([tool]) else {
            throw ArchiveBrowserError.missingTool(tool)
        }
        return try run(executableURL: executableURL, arguments: arguments, currentDirectory: currentDirectory, standardOutputFile: standardOutputFile)
    }

    @discardableResult
    private func run(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        standardOutputFile: URL? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stdoutPipe = standardOutputFile == nil ? Pipe() : nil
        let stderrPipe = Pipe()
        if let standardOutputFile {
            fileManager.createFile(atPath: standardOutputFile.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: standardOutputFile)
        } else {
            process.standardOutput = stdoutPipe
        }
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()
        (process.standardOutput as? FileHandle)?.closeFile()

        let stdoutData = stdoutPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let result = CommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPasswordError(message) {
                throw ArchiveBrowserError.passwordRequired
            }
            throw ArchiveBrowserError.extractionFailed(message.isEmpty ? "压缩包操作失败：\(executableURL.lastPathComponent)" : message)
        }
        return result
    }

    private func firstAvailableTool(_ names: [String]) -> URL? {
        for name in names {
            for directory in archiveToolSearchDirectories {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private func isPasswordError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("password")
            || lowercased.contains("incorrect")
            || lowercased.contains("encrypted")
            || lowercased.contains("passphrase")
    }
}

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

private enum ArchiveBrowserKind {
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

    init?(url: URL) {
        let fileName = url.lastPathComponent.lowercased()
        if fileName.hasSuffix(".tar.gz") || fileName.hasSuffix(".tgz") {
            self = .tarGzip
        } else if fileName.hasSuffix(".tar.bz2") || fileName.hasSuffix(".tbz2") || fileName.hasSuffix(".tbz") {
            self = .tarBzip2
        } else if fileName.hasSuffix(".tar.xz") || fileName.hasSuffix(".txz") {
            self = .tarXz
        } else if fileName.hasSuffix(".zip") {
            self = .zip
        } else if fileName.hasSuffix(".tar") {
            self = .tar
        } else if fileName.hasSuffix(".gz") {
            self = .gzip
        } else if fileName.hasSuffix(".bz2") {
            self = .bzip2
        } else if fileName.hasSuffix(".xz") {
            self = .xz
        } else if fileName.hasSuffix(".7z") {
            self = .sevenZip
        } else if fileName.hasSuffix(".rar") {
            self = .rar
        } else {
            return nil
        }
    }
}
