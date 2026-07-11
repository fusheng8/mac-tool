import Foundation
import MacToolCore

let archiveToolSearchDirectories = ArchiveRules.toolSearchDirectories

func archiveMissingToolMessage(_ name: String) -> String {
    ArchiveRules.missingToolMessage(name)
}

enum ArchiveActionError: LocalizedError {
    case emptySelection
    case unsupportedFormat(String)
    case missingTool(String)
    case mixedSourceDirectories
    case expectedSingleRegularFile(String)
    case passwordProtectedArchive
    case passwordUnsupported(String)
    case invalidArchiveName(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection: return "没有选择文件"
        case .unsupportedFormat(let name): return "暂不支持该压缩格式：\(name)"
        case .missingTool(let name): return archiveMissingToolMessage(name)
        case .mixedSourceDirectories: return "一次压缩的文件需要位于同一目录"
        case .expectedSingleRegularFile(let format): return "\(format) 只能压缩单个普通文件"
        case .passwordProtectedArchive: return "压缩包需要密码"
        case .passwordUnsupported(let format): return "\(format) 不支持设置压缩密码，请选择 ZIP、7Z 或 RAR。"
        case .invalidArchiveName(let message): return message
        }
    }
}

struct ArchiveCompressionOptions {
    var archiveName: String
    var format: ArchiveFormat
    var stripMacMetadata: Bool
    var compressionLevel: Int
    var password: String?
    var wrapInFolder: Bool
}

final class ArchiveActionExecutor {
    struct Progress {
        let current: Int
        let total: Int
        let message: String
        let fractionCompleted: Double?
    }

    private let fileManager: FileManager
    private let progressHandler: ((Progress) -> Void)?
    private let archivePasswords: [String: String]
    private let engine: ArchiveEngine
    private let cancellation: ArchiveCancellationToken?

    init(
        progressHandler: ((Progress) -> Void)? = nil,
        archivePasswords: [String: String] = [:],
        engine: ArchiveEngine = ArchiveEngine(),
        cancellation: ArchiveCancellationToken? = nil,
        fileManager: FileManager = .default
    ) {
        self.progressHandler = progressHandler
        self.archivePasswords = archivePasswords
        self.engine = engine
        self.cancellation = cancellation
        self.fileManager = fileManager
    }

    func smartExtract(urls: [URL]) throws {
        try requireSelection(urls)
        for (index, url) in urls.enumerated() {
            report(index + 1, urls.count, "智能解压：\(url.lastPathComponent)")
            try smartExtract(url)
        }
    }

    func smartExtractAndDelete(urls: [URL]) throws {
        try smartExtract(urls: urls)
        try deleteArchiveSources(urls)
    }

    func extractHere(urls: [URL]) throws {
        try requireSelection(urls)
        for (index, url) in urls.enumerated() {
            report(index + 1, urls.count, "解压到当前目录：\(url.lastPathComponent)")
            try requireSupported(url)
            let stage = try extractToStage(url)
            defer { try? fileManager.removeItem(at: stage) }
            try mergeKeepingBoth(from: stage, into: url.deletingLastPathComponent())
        }
    }

    func extractToArchiveName(urls: [URL]) throws {
        try requireSelection(urls)
        for (index, url) in urls.enumerated() {
            report(index + 1, urls.count, "解压到压缩包名称：\(url.lastPathComponent)")
            try requireSupported(url)
            let stage = try extractToStage(url)
            defer { try? fileManager.removeItem(at: stage) }
            let destination = uniqueURL(
                in: url.deletingLastPathComponent(),
                preferredName: archiveBaseName(url),
                isDirectory: true
            )
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            do {
                try moveChildren(from: stage, into: destination)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
    }

    func extractToArchiveNameAndDelete(urls: [URL]) throws {
        try extractToArchiveName(urls: urls)
        try deleteArchiveSources(urls)
    }

    func compress(urls: [URL], options: ArchiveCompressionOptions) throws {
        try requireSelection(urls)
        guard archiveConfig().supports(options.format) else {
            throw ArchiveActionError.unsupportedFormat(options.format.title)
        }
        if let password = options.password, !password.isEmpty, !options.format.supportsCompressionPassword {
            throw ArchiveActionError.passwordUnsupported(options.format.title)
        }
        if options.format.isSingleFileCompression {
            _ = try singleRegularFile(urls, format: options.format.title)
            if options.wrapInFolder { throw ArchiveActionError.expectedSingleRegularFile(options.format.title) }
        }

        report(1, 1, "压缩为 \(options.format.title)：\(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 项")")
        let context = try compressionContext(urls: urls, options: options)
        defer { context.cleanup() }
        try engine.create(ArchiveCreationRequest(
            sourceParent: context.parent,
            sourceNames: context.names,
            destinationURL: context.destination,
            format: options.format,
            compressionLevel: ArchiveConfig.normalizedCompressionLevel(options.compressionLevel),
            password: options.password,
            stripMacMetadata: options.stripMacMetadata
        ), cancellation: cancellation, progress: engineProgress(message: "正在压缩"))
    }

    func compressZip(urls: [URL]) throws { try compressDefault(urls, format: .zip) }
    func compressTar(urls: [URL]) throws { try compressDefault(urls, format: .tar) }
    func compressTarGzip(urls: [URL]) throws { try compressDefault(urls, format: .tarGzip) }
    func compressTarBzip2(urls: [URL]) throws { try compressDefault(urls, format: .tarBzip2) }
    func compressTarXz(urls: [URL]) throws { try compressDefault(urls, format: .tarXz) }
    func compressGzip(urls: [URL]) throws { try compressDefault(urls, format: .gzip) }
    func compressBzip2(urls: [URL]) throws { try compressDefault(urls, format: .bzip2) }
    func compressXz(urls: [URL]) throws { try compressDefault(urls, format: .xz) }
    func compressSevenZip(urls: [URL]) throws { try compressDefault(urls, format: .sevenZip) }
    func compressRar(urls: [URL]) throws { try compressDefault(urls, format: .rar) }

    private func smartExtract(_ archiveURL: URL) throws {
        try requireSupported(archiveURL)
        let stage = try extractToStage(archiveURL)
        defer { try? fileManager.removeItem(at: stage) }
        try removeMacMetadata(in: stage)

        let materialFiles = try materializedFiles(in: stage)
        guard !materialFiles.isEmpty else { throw ArchiveEngineError.noExtractedContent }
        let children = try fileManager.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !isMacMetadata($0) }

        if materialFiles.count == 1, let file = materialFiles.first {
            let destination = uniqueURL(
                in: archiveURL.deletingLastPathComponent(),
                preferredName: file.lastPathComponent,
                isDirectory: false
            )
            try fileManager.moveItem(at: file, to: destination)
            return
        }

        if children.count == 1, let only = children.first,
           (try only.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            let destination = uniqueURL(
                in: archiveURL.deletingLastPathComponent(),
                preferredName: only.lastPathComponent,
                isDirectory: true
            )
            try fileManager.moveItem(at: only, to: destination)
            return
        }

        let destination = uniqueURL(
            in: archiveURL.deletingLastPathComponent(),
            preferredName: archiveBaseName(archiveURL),
            isDirectory: true
        )
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try moveChildren(from: stage, into: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func extractToStage(_ archiveURL: URL) throws -> URL {
        let stage = fileManager.temporaryDirectory
            .appendingPathComponent("MacAssistantExtraction-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            try engine.extract(ArchiveExtractionRequest(
                archiveURL: archiveURL,
                destinationURL: stage,
                paths: nil,
                password: password(for: archiveURL)
            ), cancellation: cancellation, progress: engineProgress(message: "正在解压"))
            return stage
        } catch {
            try? fileManager.removeItem(at: stage)
            throw error
        }
    }

    private func compressDefault(_ urls: [URL], format: ArchiveFormat) throws {
        let name = urls.count == 1 ? urls[0].lastPathComponent : "压缩包"
        try compress(urls: urls, options: ArchiveCompressionOptions(
            archiveName: name,
            format: format,
            stripMacMetadata: archiveConfig().stripMacMetadataWhenCompressing,
            compressionLevel: archiveConfig().defaultCompressionLevel,
            password: nil,
            wrapInFolder: false
        ))
    }

    private func compressionContext(
        urls: [URL],
        options: ArchiveCompressionOptions
    ) throws -> (parent: URL, names: [String], destination: URL, cleanup: () -> Void) {
        let first = urls[0]
        let parent = first.deletingLastPathComponent().standardizedFileURL
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent }) else {
            throw ArchiveActionError.mixedSourceDirectories
        }
        let archiveFileName = try Self.validatedArchiveFileName(
            options.archiveName,
            format: options.format,
            parent: parent
        )
        let destination = uniqueURL(
            in: parent,
            preferredName: archiveFileName,
            isDirectory: false
        )
        guard options.wrapInFolder else { return (parent, urls.map(\.lastPathComponent), destination, {}) }

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacAssistantCompression-\(UUID().uuidString)", isDirectory: true)
        let folderName = archiveBaseName(URL(fileURLWithPath: archiveFileName))
        let folder = tempRoot.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in urls { try fileManager.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent)) }
        return (tempRoot, [folderName], destination, { try? self.fileManager.removeItem(at: tempRoot) })
    }

    private func mergeKeepingBoth(from source: URL, into destination: URL) throws {
        for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            if !fileManager.fileExists(atPath: target.path) {
                try fileManager.moveItem(at: child, to: target)
                continue
            }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            var targetIsDirectory: ObjCBool = false
            let existingIsDirectory = fileManager.fileExists(atPath: target.path, isDirectory: &targetIsDirectory) && targetIsDirectory.boolValue
            if values.isDirectory == true && existingIsDirectory {
                try mergeKeepingBoth(from: child, into: target)
                try? fileManager.removeItem(at: child)
            } else {
                let unique = uniqueURL(in: destination, preferredName: child.lastPathComponent, isDirectory: values.isDirectory == true)
                try fileManager.moveItem(at: child, to: unique)
            }
        }
    }

    private func moveChildren(from source: URL, into destination: URL) throws {
        for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try fileManager.moveItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
        }
    }

    private func materializedFiles(in root: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where !isMacMetadata(url) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true || values.isSymbolicLink == true { result.append(url) }
        }
        return result
    }

    private func removeMacMetadata(in root: URL) throws {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        let matches = enumerator.compactMap { $0 as? URL }.filter(isMacMetadata).sorted { $0.path.count > $1.path.count }
        for url in matches { try? fileManager.removeItem(at: url) }
    }

    private func isMacMetadata(_ url: URL) -> Bool {
        let parts = url.pathComponents
        return parts.contains("__MACOSX") || url.lastPathComponent == ".DS_Store" || url.lastPathComponent.hasPrefix("._")
    }

    private func requireSelection(_ urls: [URL]) throws {
        if urls.isEmpty { throw ArchiveActionError.emptySelection }
    }

    private func requireSupported(_ url: URL) throws {
        guard let format = ArchiveFormatDetector.detect(url: url), archiveConfig().supports(format) else {
            throw ArchiveActionError.unsupportedFormat(url.lastPathComponent)
        }
    }

    private func singleRegularFile(_ urls: [URL], format: String) throws -> URL {
        guard urls.count == 1, let source = urls.first else { throw ArchiveActionError.expectedSingleRegularFile(format) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ArchiveActionError.expectedSingleRegularFile(format)
        }
        return source
    }

    static func validatedArchiveFileName(_ name: String, format: ArchiveFormat, parent: URL) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ArchiveActionError.invalidArchiveName("压缩包文件名不能为空。")
        }
        guard trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArchiveActionError.invalidArchiveName("压缩包文件名不能包含路径分隔符、控制字符或相对路径。")
        }
        let suffix = ".\(format.archiveExtension)"
        let fileName = trimmed.lowercased().hasSuffix(suffix) ? trimmed : trimmed + suffix
        let standardizedParent = parent.standardizedFileURL
        let destination = standardizedParent.appendingPathComponent(fileName).standardizedFileURL
        guard destination.deletingLastPathComponent() == standardizedParent,
              destination.lastPathComponent == fileName else {
            throw ArchiveActionError.invalidArchiveName("压缩包文件名必须是当前目录中的单个文件名。")
        }
        return fileName
    }

    private func archiveBaseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".tbz", ".txz", ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar"]
        where name.lowercased().hasSuffix(suffix) {
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

    private func deleteArchiveSources(_ urls: [URL]) throws {
        for (index, url) in urls.enumerated() {
            report(index + 1, urls.count, "删除压缩包：\(url.lastPathComponent)")
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private func password(for url: URL) -> String? {
        archivePasswords[url.standardizedFileURL.path] ?? archivePasswords[url.path]
    }

    private func report(_ current: Int, _ total: Int, _ message: String) {
        progressHandler?(Progress(current: current, total: total, message: message, fractionCompleted: nil))
    }

    private func engineProgress(message: String) -> (Double) -> Void {
        { [weak self] fraction in
            self?.progressHandler?(Progress(
                current: Int((fraction * 100).rounded()),
                total: 100,
                message: message,
                fractionCompleted: fraction
            ))
        }
    }

    private func archiveConfig() -> ArchiveConfig {
        guard let data = try? Data(contentsOf: AppPaths.configURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else { return .defaultValue }
        return config.archive.enabledFormats.isEmpty ? .defaultValue : config.archive
    }
}
