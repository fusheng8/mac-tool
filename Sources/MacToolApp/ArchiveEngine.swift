import CoreFoundation
import Foundation
import MacToolCore

enum ArchiveEngineError: LocalizedError {
    case unsupportedFormat(String)
    case bundledToolMissing
    case passwordRequired
    case invalidPassword
    case unsupportedPasswordCharacters
    case corruptedArchive(String)
    case unsafeEntry(String)
    case commandFailed(String)
    case cancelled
    case timedOut
    case outputTooLarge
    case insufficientDiskSpace(required: Int64, available: Int64)
    case noExtractedContent
    case unsupportedMutation(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name): return "暂不支持该压缩格式：\(name)"
        case .bundledToolMissing: return "内置压缩引擎缺失或不可执行，请重新安装 Mac助手。"
        case .passwordRequired: return "压缩包需要密码"
        case .invalidPassword: return "压缩包密码错误"
        case .unsupportedPasswordCharacters: return "macOS 版内置归档引擎暂不支持非 ASCII 密码，请使用英文、数字或常用半角符号。"
        case .corruptedArchive(let message): return message.isEmpty ? "压缩包已损坏或格式不受支持" : message
        case .unsafeEntry(let path): return "压缩包包含不安全路径，已停止解压：\(path)"
        case .commandFailed(let message): return message
        case .cancelled: return "操作已取消"
        case .timedOut: return "压缩包操作超时"
        case .outputTooLarge: return "压缩包条目过多，目录输出超过安全限制"
        case .insufficientDiskSpace(let required, let available):
            return "磁盘空间不足：预计需要 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))，当前可用 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))。"
        case .noExtractedContent: return "压缩包内没有可解压的内容"
        case .unsupportedMutation(let message): return message
        }
    }
}

struct ArchiveEntry: Hashable, Sendable {
    let id: Int
    let path: String
    let rawPath: String
    let size: Int64?
    let packedSize: Int64?
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let linkTarget: String?
    let modifiedAt: Date?
    let isEncrypted: Bool

    var displayName: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }
}

struct ArchiveDescriptor: Sendable {
    let format: ArchiveFormat
    let entries: [ArchiveEntry]
    let isEncrypted: Bool
}

struct ArchiveExtractionRequest {
    let archiveURL: URL
    let destinationURL: URL
    let paths: [String]?
    let password: String?
}

struct ArchiveCreationRequest {
    let sourceParent: URL
    let sourceNames: [String]
    let destinationURL: URL
    let format: ArchiveFormat
    let compressionLevel: Int
    let password: String?
    let stripMacMetadata: Bool
}

final class ArchiveCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

final class ArchiveCommandRunner {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var exceeded = false
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ data: Data) {
            lock.withLock {
                guard storage.count < limit else { exceeded = true; return }
                let remaining = limit - storage.count
                storage.append(data.prefix(remaining))
                exceeded = exceeded || data.count > remaining
            }
        }

        func snapshot() -> (Data, Bool) { lock.withLock { (storage, exceeded) } }
    }

    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 60 * 60,
        outputLimit: Int = 64 * 1_024 * 1_024,
        cancellation: ArchiveCancellationToken? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ArchiveEngineError.bundledToolMissing
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C.UTF-8"
        environment["LC_ALL"] = "C.UTF-8"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = Accumulator(limit: outputLimit)
        let stderr = Accumulator(limit: outputLimit)
        let readers = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: stdout, group: readers, progressHandler: progressHandler)
        drain(stderrPipe.fileHandleForReading, into: stderr, group: readers, progressHandler: progressHandler)

        do {
            try launchProcessSafely(process, executableURL: executableURL)
        } catch {
            throw ArchiveEngineError.commandFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if cancellation?.isCancelled == true {
                process.terminate()
                process.waitUntilExit()
                readers.wait()
                throw ArchiveEngineError.cancelled
            }
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                readers.wait()
                throw ArchiveEngineError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        readers.wait()

        let out = stdout.snapshot()
        let err = stderr.snapshot()
        if out.1 || err.1 { throw ArchiveEngineError.outputTooLarge }
        return Result(status: process.terminationStatus, stdout: out.0, stderr: err.0)
    }

    private func drain(
        _ handle: FileHandle,
        into accumulator: Accumulator,
        group: DispatchGroup,
        progressHandler: ((Double) -> Void)?
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                accumulator.append(data)
                for progress in Self.progressValues(in: data) { progressHandler?(progress) }
            }
        }
    }

    private static func progressValues(in data: Data) -> [Double] {
        let bytes = [UInt8](data)
        var result: [Double] = []
        for percentIndex in bytes.indices where bytes[percentIndex] == 0x25 {
            var start = percentIndex
            while start > bytes.startIndex, (0x30...0x39).contains(bytes[bytes.index(before: start)]) {
                start = bytes.index(before: start)
            }
            guard start < percentIndex,
                  let text = String(bytes: bytes[start..<percentIndex], encoding: .ascii),
                  let value = Int(text),
                  (0...100).contains(value) else { continue }
            result.append(Double(value) / 100.0)
        }
        return result
    }
}

final class ArchiveToolLocator {
    private let fileManager = FileManager.default

    func sevenZipURL() throws -> URL {
        let bundleCandidate = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz")
        let workspaceCandidate = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Vendor/7zip/7zz")
        let executableCandidate = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("7zz")
        for candidate in [bundleCandidate, workspaceCandidate, executableCandidate].compactMap({ $0 }) {
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw ArchiveEngineError.bundledToolMissing
    }

    func rarWriterURL() -> URL? {
        for directory in ArchiveRules.toolSearchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("rar")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

final class ArchiveEngine {
    private let runner: ArchiveCommandRunner
    private let locator: ArchiveToolLocator
    private let fileManager: FileManager

    init(
        runner: ArchiveCommandRunner = ArchiveCommandRunner(),
        locator: ArchiveToolLocator = ArchiveToolLocator(),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.locator = locator
        self.fileManager = fileManager
    }

    func probe(_ url: URL, password: String? = nil) throws -> ArchiveDescriptor {
        let format = try detectedFormat(for: url)
        let entries = try list(url, password: password)
        return ArchiveDescriptor(format: format, entries: entries, isEncrypted: entries.contains(where: \.isEncrypted))
    }

    func list(_ url: URL, password: String? = nil) throws -> [ArchiveEntry] {
        try validatePasswordCharacters(password)
        let format = try detectedFormat(for: url)
        return try withPreparedArchive(url, format: format) { preparedURL in
            var arguments = ["l", "-slt", "-ba", "-sccUTF-8"]
            appendPassword(password, to: &arguments)
            arguments.append(preparedURL.path)
            let result = try runSevenZip(arguments)
            try validate(result)
            var entries = parseTechnicalList(result.stdoutString)
            if entries.isEmpty, format == .bzip2 || format == .xz {
                entries = [ArchiveEntry(
                    id: 0,
                    path: archiveBaseName(url),
                    rawPath: archiveBaseName(url),
                    size: nil,
                    packedSize: nil,
                    isDirectory: false,
                    isSymbolicLink: false,
                    linkTarget: nil,
                    modifiedAt: nil,
                    isEncrypted: false
                )]
            }
            try validateEntryPaths(entries)
            return entries
        }
    }

    func test(_ url: URL, password: String?) throws {
        try validatePasswordCharacters(password)
        let format = try detectedFormat(for: url)
        try withPreparedArchive(url, format: format) { preparedURL in
            var arguments = ["t", "-y", "-sccUTF-8"]
            appendPassword(password, to: &arguments)
            arguments.append(preparedURL.path)
            try validate(runSevenZip(arguments), passwordWasProvided: password?.isEmpty == false)
        }
    }

    func extract(
        _ request: ArchiveExtractionRequest,
        cancellation: ArchiveCancellationToken? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws {
        let format = try detectedFormat(for: request.archiveURL)
        let listed = try list(request.archiveURL, password: request.password)
        let selected = request.paths.map(Set.init)
        let selectedEntries = selected == nil ? listed : listed.filter { selected!.contains($0.rawPath) }
        try validateEntryPaths(selectedEntries)
        try validateDiskSpace(for: selectedEntries, at: request.destinationURL)
        try fileManager.createDirectory(at: request.destinationURL, withIntermediateDirectories: true)

        try withPreparedArchive(request.archiveURL, format: format) { preparedURL in
            var arguments = ["x", "-y", "-aoa", "-bsp1", "-sccUTF-8", "-o\(request.destinationURL.path)"]
            appendPassword(request.password, to: &arguments)
            arguments.append(preparedURL.path)
            if let paths = request.paths, !paths.isEmpty, format != .bzip2, format != .xz {
                arguments.append("--")
                arguments += paths
            }
            try validate(runSevenZip(arguments, cancellation: cancellation, progress: progress), passwordWasProvided: request.password?.isEmpty == false)
        }
        try normalizeMaterializedNames(at: request.destinationURL)
        try validateMaterializedTree(at: request.destinationURL)
    }

    func create(
        _ request: ArchiveCreationRequest,
        cancellation: ArchiveCancellationToken? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws {
        if request.format == .rar {
            try createRar(request, cancellation: cancellation)
            return
        }
        try validatePasswordCharacters(request.password)
        if request.format == .tarGzip || request.format == .tarBzip2 || request.format == .tarXz {
            try createCompressedTar(request, cancellation: cancellation, progress: progress)
            return
        }

        var arguments = ["a", "-y", "-bsp1", "-sccUTF-8", typeSwitch(for: request.format)]
        if request.format.supportsCompressionLevel {
            arguments.append("-mx=\(min(9, max(0, request.compressionLevel)))")
        }
        appendPassword(request.password, to: &arguments)
        arguments += metadataExclusions(enabled: request.stripMacMetadata)
        arguments.append(request.destinationURL.path)
        arguments.append("--")
        arguments += request.sourceNames
        try validate(runSevenZip(arguments, currentDirectory: request.sourceParent, cancellation: cancellation, progress: progress))
    }

    func add(urls: [URL], to archiveURL: URL, password: String?) throws {
        let format = try detectedFormat(for: archiveURL)
        guard format == .zip || format == .tar || format == .sevenZip || format == .rar else {
            throw ArchiveEngineError.unsupportedMutation("该格式不支持直接添加内容，请解压后重新压缩。")
        }
        guard let first = urls.first else { return }
        let parent = first.deletingLastPathComponent().standardizedFileURL
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent }) else {
            throw ArchiveEngineError.unsupportedMutation("一次添加的文件需要位于同一目录。")
        }
        if format == .rar {
            guard let rar = locator.rarWriterURL() else {
                throw ArchiveEngineError.unsupportedMutation("修改 RAR 需要额外安装 rar。")
            }
            var arguments = ["a", "-idq"]
            if let password, !password.isEmpty { arguments.append("-p\(password)") }
            arguments.append(archiveURL.path)
            arguments += urls.map(\.lastPathComponent)
            try validate(runner.run(executableURL: rar, arguments: arguments, currentDirectory: parent), passwordWasProvided: password?.isEmpty == false)
            return
        }
        try validatePasswordCharacters(password)
        var arguments = ["a", "-y", "-sccUTF-8"]
        appendPassword(password, to: &arguments)
        arguments.append(archiveURL.path)
        arguments.append("--")
        arguments += urls.map(\.lastPathComponent)
        try validate(runSevenZip(arguments, currentDirectory: parent), passwordWasProvided: password?.isEmpty == false)
    }

    func delete(paths: [String], from archiveURL: URL, password: String?) throws {
        let format = try detectedFormat(for: archiveURL)
        guard format == .zip || format == .sevenZip || format == .rar else {
            throw ArchiveEngineError.unsupportedMutation("该格式不支持直接删除内容，请解压后重新压缩。")
        }
        if format == .rar {
            guard let rar = locator.rarWriterURL() else {
                throw ArchiveEngineError.unsupportedMutation("修改 RAR 需要额外安装 rar。")
            }
            var arguments = ["d", "-idq"]
            if let password, !password.isEmpty { arguments.append("-p\(password)") }
            arguments.append(archiveURL.path)
            arguments += paths
            try validate(runner.run(executableURL: rar, arguments: arguments), passwordWasProvided: password?.isEmpty == false)
            return
        }
        try validatePasswordCharacters(password)
        var arguments = ["d", "-y", "-sccUTF-8"]
        appendPassword(password, to: &arguments)
        arguments.append(archiveURL.path)
        arguments.append("--")
        arguments += paths
        try validate(runSevenZip(arguments), passwordWasProvided: password?.isEmpty == false)
    }

    private func detectedFormat(for url: URL) throws -> ArchiveFormat {
        guard let format = ArchiveFormatDetector.detect(url: url) else {
            throw ArchiveEngineError.unsupportedFormat(url.lastPathComponent)
        }
        return format
    }

    private func runSevenZip(
        _ arguments: [String],
        currentDirectory: URL? = nil,
        cancellation: ArchiveCancellationToken? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> ArchiveCommandRunner.Result {
        try runner.run(
            executableURL: locator.sevenZipURL(),
            arguments: arguments,
            currentDirectory: currentDirectory,
            cancellation: cancellation,
            progressHandler: progress
        )
    }

    private func validate(_ result: ArchiveCommandRunner.Result, passwordWasProvided: Bool = false) throws {
        guard result.status == 0 else {
            let message = [result.stderrString, result.stdoutString]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = message.lowercased()
            if lower.contains("wrong password") || lower.contains("password is incorrect") {
                throw passwordWasProvided ? ArchiveEngineError.invalidPassword : ArchiveEngineError.passwordRequired
            }
            if lower.contains("password") || lower.contains("encrypted") {
                throw ArchiveEngineError.passwordRequired
            }
            if lower.contains("can not open the file as archive") || lower.contains("unexpected end of data") {
                throw ArchiveEngineError.corruptedArchive(message)
            }
            throw ArchiveEngineError.commandFailed(message.isEmpty ? "压缩包操作失败" : message)
        }
    }

    private func appendPassword(_ password: String?, to arguments: inout [String]) {
        if let password, !password.isEmpty { arguments.append("-p\(password)") }
        else { arguments.append("-p-") }
    }

    private func validatePasswordCharacters(_ password: String?) throws {
        guard let password, !password.isEmpty else { return }
        if password.unicodeScalars.contains(where: { !$0.isASCII }) {
            throw ArchiveEngineError.unsupportedPasswordCharacters
        }
    }

    private func parseTechnicalList(_ output: String) -> [ArchiveEntry] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var records: [[String: String]] = []
        var current: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty {
                if !current.isEmpty { records.append(current); current = [:] }
                continue
            }
            guard let range = line.range(of: " = ") else { continue }
            current[String(line[..<range.lowerBound])] = String(line[range.upperBound...])
        }
        if !current.isEmpty { records.append(current) }

        return records.enumerated().compactMap { index, fields in
            guard let rawPath = fields["Path"], !rawPath.isEmpty else { return nil }
            let path = decodeEscapedArchivePath(rawPath)
            let attributes = fields["Attributes"] ?? ""
            let linkTarget = fields["Symbolic Link"] ?? fields["Hard Link"]
            let modified = fields["Modified"].flatMap { value -> Date? in
                let base = String(value.prefix(19))
                return formatter.date(from: base)
            }
            return ArchiveEntry(
                id: index,
                path: path,
                rawPath: rawPath,
                size: fields["Size"].flatMap(Int64.init),
                packedSize: fields["Packed Size"].flatMap(Int64.init),
                isDirectory: fields["Folder"] == "+" || attributes.hasPrefix("D") || path.hasSuffix("/"),
                isSymbolicLink: linkTarget != nil || attributes.first == "l",
                linkTarget: linkTarget,
                modifiedAt: modified,
                isEncrypted: fields["Encrypted"] == "+"
            )
        }
    }

    private func decodeEscapedArchivePath(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { (0xEF00...0xEFFF).contains($0.value) }) else { return value }
        var bytes = Data()
        for scalar in value.unicodeScalars {
            if (0xEF00...0xEFFF).contains(scalar.value) {
                bytes.append(UInt8(scalar.value & 0xFF))
            } else {
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        let encodings: [String.Encoding] = [
            .utf8,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        ]
        for encoding in encodings {
            if let decoded = String(data: bytes, encoding: encoding) { return decoded }
        }
        return value
    }

    func validateEntryPaths(_ entries: [ArchiveEntry]) throws {
        for entry in entries {
            let normalized = entry.path.replacingOccurrences(of: "\\", with: "/")
            let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
            if normalized.hasPrefix("/") || normalized.hasPrefix("~") ||
                (normalized.count >= 2 && normalized[normalized.index(after: normalized.startIndex)] == ":") ||
                parts.contains("..") {
                throw ArchiveEngineError.unsafeEntry(entry.path)
            }
            if let target = entry.linkTarget {
                let targetParts = target.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
                if target.hasPrefix("/") || targetParts.contains("..") {
                    throw ArchiveEngineError.unsafeEntry(entry.path)
                }
            }
        }
    }

    func validateMaterializedTree(at root: URL) throws {
        let rootPath = root.standardizedFileURL.path + "/"
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL.path
            guard standardized == root.standardizedFileURL.path || standardized.hasPrefix(rootPath) else {
                throw ArchiveEngineError.unsafeEntry(url.lastPathComponent)
            }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                let resolved = destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination).standardizedFileURL
                    : url.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL
                if !resolved.path.hasPrefix(rootPath) {
                    throw ArchiveEngineError.unsafeEntry(url.lastPathComponent)
                }
            }
        }
    }

    private func validateDiskSpace(for entries: [ArchiveEntry], at destination: URL) throws {
        let required = entries.reduce(Int64(0)) { partial, entry in
            let size = max(0, entry.size ?? 0)
            let (sum, overflow) = partial.addingReportingOverflow(size)
            return overflow ? Int64.max : sum
        }
        guard required > 0 else { return }
        let probeURL = fileManager.fileExists(atPath: destination.path)
            ? destination
            : destination.deletingLastPathComponent()
        let values = try? probeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage, required > available else { return }
        throw ArchiveEngineError.insufficientDiskSpace(required: required, available: available)
    }

    private func normalizeMaterializedNames(at root: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return }
        let urls = enumerator.compactMap { $0 as? URL }.sorted { $0.pathComponents.count > $1.pathComponents.count }
        for url in urls {
            let decodedName = decodeEscapedArchivePath(url.lastPathComponent)
            guard decodedName != url.lastPathComponent, !decodedName.isEmpty else { continue }
            var destination = url.deletingLastPathComponent().appendingPathComponent(decodedName)
            if fileManager.fileExists(atPath: destination.path) {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                destination = uniqueURL(in: url.deletingLastPathComponent(), preferredName: decodedName, isDirectory: values.isDirectory == true)
            }
            try fileManager.moveItem(at: url, to: destination)
        }
    }

    private func withPreparedArchive<T>(_ url: URL, format: ArchiveFormat, body: (URL) throws -> T) throws -> T {
        guard format == .tarGzip || format == .tarBzip2 || format == .tarXz else { return try body(url) }
        let temp = fileManager.temporaryDirectory.appendingPathComponent("MacAssistantNestedArchive-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }
        let arguments = ["x", "-y", "-aoa", "-sccUTF-8", "-o\(temp.path)", "-p-", url.path]
        try validate(runSevenZip(arguments))
        let children = try fileManager.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
        guard let tar = children.first(where: { $0.pathExtension.lowercased() == "tar" }) ?? children.first else {
            throw ArchiveEngineError.noExtractedContent
        }
        return try body(tar)
    }

    private func createCompressedTar(
        _ request: ArchiveCreationRequest,
        cancellation: ArchiveCancellationToken?,
        progress: ((Double) -> Void)?
    ) throws {
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("MacAssistantCreateTar-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }
        let base = archiveBaseName(request.destinationURL)
        let tarURL = tempRoot.appendingPathComponent("\(base).tar")
        let tarRequest = ArchiveCreationRequest(
            sourceParent: request.sourceParent,
            sourceNames: request.sourceNames,
            destinationURL: tarURL,
            format: .tar,
            compressionLevel: request.compressionLevel,
            password: nil,
            stripMacMetadata: request.stripMacMetadata
        )
        try create(tarRequest, cancellation: cancellation, progress: { progress?($0 * 0.65) })
        let filterType: String
        switch request.format {
        case .tarGzip: filterType = "-tgzip"
        case .tarBzip2: filterType = "-tbzip2"
        case .tarXz: filterType = "-txz"
        default: fatalError("Unexpected compressed tar format")
        }
        let arguments = ["a", "-y", "-bsp1", "-sccUTF-8", filterType, "-mx=\(min(9, max(0, request.compressionLevel)))", request.destinationURL.path, tarURL.path]
        try validate(runSevenZip(arguments, cancellation: cancellation, progress: { progress?(0.65 + $0 * 0.35) }))
    }

    private func createRar(_ request: ArchiveCreationRequest, cancellation: ArchiveCancellationToken?) throws {
        guard let rar = locator.rarWriterURL() else {
            throw ArchiveEngineError.unsupportedMutation("创建 RAR 需要额外安装 rar；读取和解压 RAR 无需安装。")
        }
        var arguments = ["a", "-idq", "-m\(min(5, max(0, Int((Double(request.compressionLevel) / 9.0 * 5.0).rounded()))))"]
        if let password = request.password, !password.isEmpty { arguments.append("-p\(password)") }
        arguments.append(request.destinationURL.path)
        arguments += request.sourceNames
        let result = try runner.run(executableURL: rar, arguments: arguments, currentDirectory: request.sourceParent, cancellation: cancellation)
        try validate(result, passwordWasProvided: request.password?.isEmpty == false)
    }

    private func typeSwitch(for format: ArchiveFormat) -> String {
        switch format {
        case .zip: return "-tzip"
        case .tar: return "-ttar"
        case .gzip: return "-tgzip"
        case .bzip2: return "-tbzip2"
        case .xz: return "-txz"
        case .sevenZip: return "-t7z"
        case .tarGzip, .tarBzip2, .tarXz, .rar: return ""
        }
    }

    private func metadataExclusions(enabled: Bool) -> [String] {
        guard enabled else { return [] }
        return ["-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"]
    }

    private func archiveBaseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func uniqueURL(in directory: URL, preferredName: String, isDirectory: Bool) -> URL {
        let nameURL = URL(fileURLWithPath: preferredName)
        let ext = isDirectory ? "" : nameURL.pathExtension
        let base = ext.isEmpty ? preferredName : String(preferredName.dropLast(ext.count + 1))
        var index = 0
        while true {
            let numbered = index == 0 ? base : "\(base) \(index + 1)"
            let candidate = ext.isEmpty || isDirectory
                ? directory.appendingPathComponent(numbered, isDirectory: isDirectory)
                : directory.appendingPathComponent(numbered).appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
