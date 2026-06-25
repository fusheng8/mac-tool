import Foundation

let archiveToolSearchDirectories = ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"]

func archiveMissingToolMessage(_ name: String) -> String {
    let lowercased = name.lowercased()
    let requiredTools: String
    let installSuggestion: String

    if lowercased.contains("unrar") || lowercased.contains("rar") {
        requiredTools = "unrar 或 rar"
        installSuggestion = "brew install rar"
    } else if lowercased.contains("7z") || lowercased.contains("7zz") {
        requiredTools = "7zz 或 7z"
        installSuggestion = "brew install sevenzip"
    } else if lowercased.contains("xz") || lowercased.contains("unxz") {
        requiredTools = "xz 或 unxz"
        installSuggestion = "brew install xz"
    } else {
        requiredTools = name
        installSuggestion = "请通过 Homebrew 或系统工具安装 \(name)，并确认工具位于搜索路径中。"
    }

    return """
    当前系统缺少处理该格式所需的工具：\(requiredTools)
    安装建议：\(installSuggestion)
    当前搜索路径：\(archiveToolSearchDirectories.joined(separator: ", "))
    """
}

func zipExtractionShouldFallbackToSevenZip(message: String) -> Bool {
    let lowercased = message.lowercased()
    return lowercased.contains("write error")
        || lowercased.contains("continue? (y/n/^c)")
        || lowercased.contains("fchmod")
        || lowercased.contains("cannot set modif./access times")
}

enum ArchiveActionError: LocalizedError {
    case emptySelection
    case expectedSingleArchive
    case unsupportedFormat(String)
    case missingTool(String)
    case mixedSourceDirectories
    case expectedSingleRegularFile(String)
    case passwordProtectedArchive
    case commandFailed(String)
    case noExtractedContent
    case passwordUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "没有选择文件"
        case .expectedSingleArchive:
            return "智能解压一次只能处理一个压缩包"
        case .unsupportedFormat(let name):
            return "暂不支持该压缩格式：\(name)"
        case .missingTool(let name):
            return archiveMissingToolMessage(name)
        case .mixedSourceDirectories:
            return "一次压缩的文件需要位于同一目录"
        case .expectedSingleRegularFile(let format):
            return "\(format) 只能压缩单个普通文件"
        case .passwordProtectedArchive:
            return "暂不支持带密码的压缩包"
        case .commandFailed(let message):
            return message
        case .noExtractedContent:
            return "压缩包内没有可解压的内容"
        case .passwordUnsupported(let format):
            return "\(format) 不支持设置压缩密码，请选择 ZIP、7Z 或 RAR。"
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
    }

    private let fileManager = FileManager.default
    private let progressHandler: ((Progress) -> Void)?
    private let archivePasswords: [String: String]

    init(progressHandler: ((Progress) -> Void)? = nil, archivePasswords: [String: String] = [:]) {
        self.progressHandler = progressHandler
        self.archivePasswords = archivePasswords
    }

    func smartExtract(urls: [URL]) throws {
        guard !urls.isEmpty else {
            throw ArchiveActionError.emptySelection
        }

        for (index, archiveURL) in urls.enumerated() {
            report(current: index + 1, total: urls.count, message: "智能解压：\(archiveURL.lastPathComponent)")
            try smartExtract(archiveURL: archiveURL)
        }
    }

    func smartExtractAndDelete(urls: [URL]) throws {
        try smartExtract(urls: urls)
        try deleteArchiveSources(urls)
    }

    private func smartExtract(archiveURL: URL) throws {
        let kind = try ArchiveKind(url: archiveURL)
        guard archiveConfig().supports(kind.format) else {
            throw ArchiveActionError.unsupportedFormat(kind.format.title)
        }
        let parent = archiveURL.deletingLastPathComponent()

        if kind.isSingleFileCompression {
            let outputURL = uniqueURL(in: parent, preferredName: archiveBaseName(for: archiveURL), isDirectory: false)
            do {
                try extractSingleFileCompression(archiveURL, kind: kind, to: outputURL)
            } catch {
                try? fileManager.removeItem(at: outputURL)
                throw error
            }
            return
        }

        let password = password(for: archiveURL)
        let entries = try contentEntries(in: archiveURL, kind: kind, password: password)
        guard !entries.isEmpty else {
            throw ArchiveActionError.noExtractedContent
        }

        if isSingleFileArchive(entries) {
            let tempURL = parent.appendingPathComponent(".\(archiveBaseName(for: archiveURL)).extract.\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: tempURL, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: tempURL) }

            try extractArchive(archiveURL, kind: kind, to: tempURL, password: password)
            guard let extractedFile = try singleMaterializedFile(in: tempURL) else {
                try moveExtractedDirectoryContents(from: tempURL, to: uniqueDirectory(in: parent, baseName: archiveBaseName(for: archiveURL)))
                return
            }

            let outputURL = uniqueURL(in: parent, preferredName: extractedFile.lastPathComponent, isDirectory: false)
            try fileManager.moveItem(at: extractedFile, to: outputURL)
            return
        }

        let destination = uniqueDirectory(in: parent, baseName: archiveBaseName(for: archiveURL))
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try extractArchive(archiveURL, kind: kind, to: destination, password: password)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func extractHere(urls: [URL]) throws {
        guard !urls.isEmpty else {
            throw ArchiveActionError.emptySelection
        }
        for (index, archiveURL) in urls.enumerated() {
            report(current: index + 1, total: urls.count, message: "解压到当前目录：\(archiveURL.lastPathComponent)")
            let kind = try supportedArchiveKind(for: archiveURL)
            let parent = archiveURL.deletingLastPathComponent()
            if kind.isSingleFileCompression {
                let outputURL = uniqueURL(in: parent, preferredName: archiveBaseName(for: archiveURL), isDirectory: false)
                try extractSingleFileCompression(archiveURL, kind: kind, to: outputURL)
            } else {
                try extractArchive(archiveURL, kind: kind, to: parent, password: password(for: archiveURL))
            }
        }
    }

    func extractToArchiveName(urls: [URL]) throws {
        guard !urls.isEmpty else {
            throw ArchiveActionError.emptySelection
        }
        for (index, archiveURL) in urls.enumerated() {
            report(current: index + 1, total: urls.count, message: "解压到压缩包名称：\(archiveURL.lastPathComponent)")
            let kind = try supportedArchiveKind(for: archiveURL)
            let destination = uniqueDirectory(in: archiveURL.deletingLastPathComponent(), baseName: archiveBaseName(for: archiveURL))
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            do {
                if kind.isSingleFileCompression {
                    let outputURL = uniqueURL(in: destination, preferredName: archiveBaseName(for: archiveURL), isDirectory: false)
                    try extractSingleFileCompression(archiveURL, kind: kind, to: outputURL)
                } else {
                    try extractArchive(archiveURL, kind: kind, to: destination, password: password(for: archiveURL))
                }
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

    private func supportedArchiveKind(for archiveURL: URL) throws -> ArchiveKind {
        let kind = try ArchiveKind(url: archiveURL)
        guard archiveConfig().supports(kind.format) else {
            throw ArchiveActionError.unsupportedFormat(kind.format.title)
        }
        return kind
    }

    func compress(urls: [URL], options: ArchiveCompressionOptions) throws {
        guard !urls.isEmpty else {
            throw ArchiveActionError.emptySelection
        }
        guard archiveConfig().supports(options.format) else {
            throw ArchiveActionError.unsupportedFormat(options.format.title)
        }
        if let password = options.password, !password.isEmpty, !options.format.supportsCompressionPassword {
            throw ArchiveActionError.passwordUnsupported(options.format.title)
        }
        if options.wrapInFolder && options.format.isSingleFileCompression {
            throw ArchiveActionError.expectedSingleRegularFile(options.format.title)
        }
        let compressionLevel = ArchiveConfig.normalizedCompressionLevel(options.compressionLevel)

        reportCompression(format: options.format.title, urls: urls)
        let context = try customCompressionContext(urls: urls, options: options)
        defer { context.cleanup() }

        switch options.format {
        case .zip:
            var arguments = ["-qry", "-\(compressionLevel)"]
            if let password = options.password, !password.isEmpty {
                arguments += ["-P", password]
            }
            arguments.append(context.destination.path)
            arguments += context.names
            arguments += zipMetadataExclusions(stripMacMetadata: options.stripMacMetadata)
            try run(tool: "zip", arguments: arguments, currentDirectory: context.parent)
        case .tar:
            try run(tool: "tar", arguments: ["-cf", context.destination.path] + tarMetadataExclusions(stripMacMetadata: options.stripMacMetadata) + ["-C", context.parent.path] + context.names)
        case .tarGzip:
            try run(
                tool: "tar",
                arguments: ["-czf", context.destination.path, "--options", "gzip:compression-level=\(minimumCompressionLevel(from: compressionLevel))"] + tarMetadataExclusions(stripMacMetadata: options.stripMacMetadata) + ["-C", context.parent.path] + context.names
            )
        case .tarBzip2:
            try run(
                tool: "tar",
                arguments: ["-cjf", context.destination.path, "--options", "bzip2:compression-level=\(minimumCompressionLevel(from: compressionLevel))"] + tarMetadataExclusions(stripMacMetadata: options.stripMacMetadata) + ["-C", context.parent.path] + context.names
            )
        case .tarXz:
            try run(
                tool: "tar",
                arguments: ["-cJf", context.destination.path, "--options", "xz:compression-level=\(compressionLevel)"] + tarMetadataExclusions(stripMacMetadata: options.stripMacMetadata) + ["-C", context.parent.path] + context.names
            )
        case .gzip:
            let source = try singleRegularFile(urls: urls, formatTitle: options.format.title)
            try run(tool: "gzip", arguments: ["-\(minimumCompressionLevel(from: compressionLevel))", "-c", source.path], standardOutputFile: context.destination)
        case .bzip2:
            let source = try singleRegularFile(urls: urls, formatTitle: options.format.title)
            try run(tool: "bzip2", arguments: ["-\(minimumCompressionLevel(from: compressionLevel))", "-c", source.path], standardOutputFile: context.destination)
        case .xz:
            let source = try singleRegularFile(urls: urls, formatTitle: options.format.title)
            guard let tool = firstAvailableTool(["xz"]) else {
                throw ArchiveActionError.missingTool("xz")
            }
            try run(executableURL: tool, arguments: ["-\(compressionLevel)", "-c", source.path], standardOutputFile: context.destination)
        case .sevenZip:
            guard let tool = firstAvailableTool(["7zz", "7z"]) else {
                throw ArchiveActionError.missingTool("7z/7zz")
            }
            var arguments = ["a", "-y", "-mx=\(compressionLevel)"]
            if let password = options.password, !password.isEmpty {
                arguments.append("-p\(password)")
            }
            arguments.append(context.destination.path)
            arguments += sevenZipMetadataExclusions(stripMacMetadata: options.stripMacMetadata)
            arguments += context.names
            try run(executableURL: tool, arguments: arguments, currentDirectory: context.parent)
        case .rar:
            guard let tool = firstAvailableTool(["rar"]) else {
                throw ArchiveActionError.missingTool("rar")
            }
            var arguments = ["a", "-idq", "-m\(rarCompressionLevel(from: compressionLevel))"]
            if let password = options.password, !password.isEmpty {
                arguments.append("-p\(password)")
            }
            arguments += rarMetadataExclusions(stripMacMetadata: options.stripMacMetadata)
            arguments.append(context.destination.path)
            arguments += context.names
            try run(executableURL: tool, arguments: arguments, currentDirectory: context.parent)
        }
    }

    func compressZip(urls: [URL]) throws {
        reportCompression(format: "ZIP", urls: urls)
        let config = archiveConfig()
        let (parent, names, destination) = try compressionContext(urls: urls, archiveExtension: "zip")
        if !config.stripMacMetadataWhenCompressing, urls.count == 1, let source = urls.first {
            try run(tool: "ditto", arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path])
            return
        }
        try run(
            tool: "zip",
            arguments: ["-qry", destination.path] + names + zipMetadataExclusions(stripMacMetadata: config.stripMacMetadataWhenCompressing),
            currentDirectory: parent
        )
    }

    func compressTarGzip(urls: [URL]) throws {
        reportCompression(format: "tar.gz", urls: urls)
        let config = archiveConfig()
        let (parent, names, destination) = try compressionContext(urls: urls, archiveExtension: "tar.gz")
        try run(tool: "tar", arguments: ["-czf", destination.path] + tarMetadataExclusions(stripMacMetadata: config.stripMacMetadataWhenCompressing) + ["-C", parent.path] + names)
    }

    func compressTar(urls: [URL]) throws {
        reportCompression(format: "TAR", urls: urls)
        let config = archiveConfig()
        let (parent, names, destination) = try compressionContext(urls: urls, archiveExtension: "tar")
        try run(tool: "tar", arguments: ["-cf", destination.path] + tarMetadataExclusions(stripMacMetadata: config.stripMacMetadataWhenCompressing) + ["-C", parent.path] + names)
    }

    func compressTarBzip2(urls: [URL]) throws {
        reportCompression(format: "tar.bz2", urls: urls)
        let config = archiveConfig()
        let (parent, names, destination) = try compressionContext(urls: urls, archiveExtension: "tar.bz2")
        try run(tool: "tar", arguments: ["-cjf", destination.path] + tarMetadataExclusions(stripMacMetadata: config.stripMacMetadataWhenCompressing) + ["-C", parent.path] + names)
    }

    func compressTarXz(urls: [URL]) throws {
        reportCompression(format: "tar.xz", urls: urls)
        let config = archiveConfig()
        let (parent, names, destination) = try compressionContext(urls: urls, archiveExtension: "tar.xz")
        try run(tool: "tar", arguments: ["-cJf", destination.path] + tarMetadataExclusions(stripMacMetadata: config.stripMacMetadataWhenCompressing) + ["-C", parent.path] + names)
    }

    func compressGzip(urls: [URL]) throws {
        reportCompression(format: "GZIP", urls: urls)
        let (source, destination) = try singleFileCompressionContext(urls: urls, archiveExtension: "gz", formatTitle: "GZIP")
        try run(tool: "gzip", arguments: ["-c", source.path], standardOutputFile: destination)
    }

    func compressBzip2(urls: [URL]) throws {
        reportCompression(format: "BZIP2", urls: urls)
        let (source, destination) = try singleFileCompressionContext(urls: urls, archiveExtension: "bz2", formatTitle: "BZIP2")
        try run(tool: "bzip2", arguments: ["-c", source.path], standardOutputFile: destination)
    }

    func compressXz(urls: [URL]) throws {
        reportCompression(format: "XZ", urls: urls)
        let (source, destination) = try singleFileCompressionContext(urls: urls, archiveExtension: "xz", formatTitle: "XZ")
        guard let tool = firstAvailableTool(["xz"]) else {
            throw ArchiveActionError.missingTool("xz")
        }
        try run(executableURL: tool, arguments: ["-c", source.path], standardOutputFile: destination)
    }

    func compressSevenZip(urls: [URL]) throws {
        reportCompression(format: "7Z", urls: urls)
        let config = archiveConfig()
        let (parent, names, destination) = try compressionContext(urls: urls, archiveExtension: "7z")
        guard let tool = firstAvailableTool(["7zz", "7z"]) else {
            throw ArchiveActionError.missingTool("7z/7zz")
        }
        try run(executableURL: tool, arguments: ["a", "-y", destination.path] + sevenZipMetadataExclusions(stripMacMetadata: config.stripMacMetadataWhenCompressing) + names, currentDirectory: parent)
    }

    func compressRar(urls: [URL]) throws {
        reportCompression(format: "RAR", urls: urls)
        let config = archiveConfig()
        let (parent, names, destination) = try compressionContext(urls: urls, archiveExtension: "rar")
        guard let tool = firstAvailableTool(["rar"]) else {
            throw ArchiveActionError.missingTool("rar")
        }
        try run(executableURL: tool, arguments: ["a", "-idq"] + rarMetadataExclusions(stripMacMetadata: config.stripMacMetadataWhenCompressing) + [destination.path] + names, currentDirectory: parent)
    }

    private func compressionContext(urls: [URL], archiveExtension: String) throws -> (parent: URL, names: [String], destination: URL) {
        guard let first = urls.first else {
            throw ArchiveActionError.emptySelection
        }

        let parent = first.deletingLastPathComponent().standardizedFileURL
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == parent.path }) else {
            throw ArchiveActionError.mixedSourceDirectories
        }

        let baseName = urls.count == 1 ? first.lastPathComponent : "压缩包"
        let destination = uniqueURL(in: parent, preferredName: "\(baseName).\(archiveExtension)", isDirectory: false)
        return (parent, urls.map(\.lastPathComponent), destination)
    }

    private func customCompressionContext(
        urls: [URL],
        options: ArchiveCompressionOptions
    ) throws -> (parent: URL, names: [String], destination: URL, cleanup: () -> Void) {
        guard let first = urls.first else {
            throw ArchiveActionError.emptySelection
        }

        let parent = first.deletingLastPathComponent().standardizedFileURL
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == parent.path }) else {
            throw ArchiveActionError.mixedSourceDirectories
        }

        let destination = uniqueURL(
            in: parent,
            preferredName: archiveFileName(name: options.archiveName, format: options.format),
            isDirectory: false
        )

        guard options.wrapInFolder else {
            return (parent, urls.map(\.lastPathComponent), destination, {})
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAssistantCompression", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folderName = folderLayerName(from: options.archiveName, format: options.format)
        let folderURL = tempRoot.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for url in urls {
            try fileManager.copyItem(at: url, to: folderURL.appendingPathComponent(url.lastPathComponent))
        }
        return (tempRoot, [folderName], destination, { try? self.fileManager.removeItem(at: tempRoot) })
    }

    private func archiveFileName(name: String, format: ArchiveFormat) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "压缩包" : trimmed
        let archiveExtension = format.archiveExtension
        return fallback.lowercased().hasSuffix(".\(archiveExtension)") ? fallback : "\(fallback).\(archiveExtension)"
    }

    private func deleteArchiveSources(_ urls: [URL]) throws {
        for (index, url) in urls.enumerated() {
            report(current: index + 1, total: urls.count, message: "删除压缩包：\(url.lastPathComponent)")
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private func folderLayerName(from archiveName: String, format: ArchiveFormat) -> String {
        let fileName = archiveFileName(name: archiveName, format: format)
        let suffix = ".\(format.archiveExtension)"
        if fileName.lowercased().hasSuffix(suffix) {
            return String(fileName.dropLast(suffix.count))
        }
        return fileName
    }

    private func singleRegularFile(urls: [URL], formatTitle: String) throws -> URL {
        guard urls.count == 1, let source = urls.first else {
            throw ArchiveActionError.expectedSingleRegularFile(formatTitle)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ArchiveActionError.expectedSingleRegularFile(formatTitle)
        }
        return source
    }

    private func zipMetadataExclusions(stripMacMetadata: Bool) -> [String] {
        guard stripMacMetadata else { return [] }
        return [
            "-x",
            ".DS_Store",
            "*/.DS_Store",
            "__MACOSX/*",
            "*/__MACOSX/*",
            "._*",
            "*/._*"
        ]
    }

    private func tarMetadataExclusions(stripMacMetadata: Bool) -> [String] {
        guard stripMacMetadata else { return [] }
        return [
            "--exclude=.DS_Store",
            "--exclude=*/.DS_Store",
            "--exclude=__MACOSX",
            "--exclude=*/__MACOSX",
            "--exclude=._*",
            "--exclude=*/._*"
        ]
    }

    private func sevenZipMetadataExclusions(stripMacMetadata: Bool) -> [String] {
        guard stripMacMetadata else { return [] }
        return [
            "-xr!.DS_Store",
            "-xr!__MACOSX",
            "-xr!._*"
        ]
    }

    private func rarMetadataExclusions(stripMacMetadata: Bool) -> [String] {
        guard stripMacMetadata else { return [] }
        return [
            "-x.DS_Store",
            "-x*/.DS_Store",
            "-x__MACOSX",
            "-x*/__MACOSX",
            "-x._*",
            "-x*/._*"
        ]
    }

    private func rarCompressionLevel(from level: Int) -> Int {
        min(5, max(0, Int((Double(ArchiveConfig.normalizedCompressionLevel(level)) / 9.0 * 5.0).rounded())))
    }

    private func minimumCompressionLevel(from level: Int) -> Int {
        max(1, ArchiveConfig.normalizedCompressionLevel(level))
    }

    private func singleFileCompressionContext(urls: [URL], archiveExtension: String, formatTitle: String) throws -> (source: URL, destination: URL) {
        guard urls.count == 1, let source = urls.first else {
            throw ArchiveActionError.expectedSingleRegularFile(formatTitle)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ArchiveActionError.expectedSingleRegularFile(formatTitle)
        }
        let destination = uniqueURL(
            in: source.deletingLastPathComponent(),
            preferredName: "\(source.lastPathComponent).\(archiveExtension)",
            isDirectory: false
        )
        return (source, destination)
    }

    private func contentEntries(in archiveURL: URL, kind: ArchiveKind, password: String?) throws -> [String] {
        let output: String
        switch kind {
        case .zip:
            output = try run(tool: "zipinfo", arguments: ["-1", archiveURL.path]).stdout
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            output = try run(tool: "tar", arguments: ["-tf", archiveURL.path]).stdout
        case .sevenZip:
            output = try sevenZipEntries(in: archiveURL, password: password)
        case .rar:
            output = try rarEntries(in: archiveURL, password: password)
        case .gzip, .bzip2, .xz:
            return [archiveBaseName(for: archiveURL)]
        }

        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter(isMaterialArchiveEntry)
    }

    private func sevenZipEntries(in archiveURL: URL, password: String?) throws -> String {
        guard let tool = firstAvailableTool(["7zz", "7z"]) else {
            throw ArchiveActionError.missingTool("7z/7zz")
        }
        var arguments = ["l", "-slt"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(archiveURL.path)
        let output = try run(executableURL: tool, arguments: arguments).stdout
        let paths = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap { line -> String? in
                guard line.hasPrefix("Path = ") else { return nil }
                let path = String(line.dropFirst("Path = ".count))
                return path == archiveURL.path ? nil : path
            }
            .filter(isMaterialArchiveEntry)
        return paths.joined(separator: "\n")
    }

    private func rarEntries(in archiveURL: URL, password: String?) throws -> String {
        if let tool = firstAvailableTool(["unrar"]) {
            var arguments = ["lb"]
            if let password, !password.isEmpty {
                arguments.append("-p\(password)")
            }
            arguments.append(archiveURL.path)
            return try run(executableURL: tool, arguments: arguments).stdout
        }
        return try sevenZipEntries(in: archiveURL, password: password)
    }

    private func extractArchive(_ archiveURL: URL, kind: ArchiveKind, to destination: URL, password: String?) throws {
        switch kind {
        case .zip:
            var arguments = ["-qq", "-o"]
            if let password, !password.isEmpty {
                arguments += ["-P", password]
            }
            arguments += [archiveURL.path, "-d", destination.path]
            do {
                try run(tool: "unzip", arguments: arguments)
            } catch ArchiveActionError.commandFailed(let message) where zipExtractionShouldFallbackToSevenZip(message: message) {
                try extractZipArchiveWithSevenZip(archiveURL, to: destination, password: password)
            }
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            try run(tool: "tar", arguments: ["-xf", archiveURL.path, "-C", destination.path])
        case .sevenZip:
            guard let tool = firstAvailableTool(["7zz", "7z"]) else {
                throw ArchiveActionError.missingTool("7z/7zz")
            }
            var arguments = ["x", "-y", "-o\(destination.path)"]
            if let password, !password.isEmpty {
                arguments.append("-p\(password)")
            }
            arguments.append(archiveURL.path)
            try run(executableURL: tool, arguments: arguments)
        case .rar:
            try extractRarArchive(archiveURL, to: destination, password: password)
        case .gzip, .bzip2, .xz:
            throw ArchiveActionError.unsupportedFormat(archiveURL.lastPathComponent)
        }
    }

    private func extractZipArchiveWithSevenZip(_ archiveURL: URL, to destination: URL, password: String?) throws {
        guard let tool = firstAvailableTool(["7zz", "7z"]) else {
            throw ArchiveActionError.missingTool("7z/7zz")
        }
        var arguments = ["x", "-y", "-o\(destination.path)"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(archiveURL.path)
        try run(executableURL: tool, arguments: arguments)
    }

    private func extractRarArchive(_ archiveURL: URL, to destination: URL, password: String?) throws {
        if let tool = firstAvailableTool(["unrar"]) {
            var arguments = ["x", "-idq", "-y"]
            if let password, !password.isEmpty {
                arguments.append("-p\(password)")
            }
            arguments += [archiveURL.path, destination.path]
            try run(executableURL: tool, arguments: arguments)
            return
        }

        guard let tool = firstAvailableTool(["7zz", "7z"]) else {
            throw ArchiveActionError.missingTool("unrar/7z/7zz")
        }
        var arguments = ["x", "-y", "-o\(destination.path)"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(archiveURL.path)
        try run(executableURL: tool, arguments: arguments)
    }

    private func extractSingleFileCompression(_ archiveURL: URL, kind: ArchiveKind, to destination: URL) throws {
        switch kind {
        case .gzip:
            try run(tool: "gzip", arguments: ["-dc", archiveURL.path], standardOutputFile: destination)
        case .bzip2:
            try run(tool: "bzip2", arguments: ["-dc", archiveURL.path], standardOutputFile: destination)
        case .xz:
            guard let tool = firstAvailableTool(["xz", "unxz"]) else {
                throw ArchiveActionError.missingTool("xz/unxz")
            }
            try run(executableURL: tool, arguments: ["-dc", archiveURL.path], standardOutputFile: destination)
        default:
            throw ArchiveActionError.unsupportedFormat(archiveURL.lastPathComponent)
        }
    }

    private func isSingleFileArchive(_ entries: [String]) -> Bool {
        entries.filter { !$0.hasSuffix("/") }.count == 1
    }

    private func singleMaterializedFile(in directory: URL) throws -> URL? {
        let files = try materializedFileURLs(in: directory)
        return files.count == 1 ? files[0] : nil
    }

    private func materializedFileURLs(in directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard isMaterialFileURL(url, root: directory) else {
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isDirectory == true {
                continue
            }
            if values.isRegularFile == true || values.isSymbolicLink == true {
                files.append(url)
            }
        }
        return files
    }

    private func isMaterialArchiveEntry(_ entry: String) -> Bool {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let parts = trimmed.split(separator: "/").map(String.init)
        guard !parts.contains("__MACOSX") else {
            return false
        }
        let last = parts.last ?? trimmed
        return last != ".DS_Store" && !last.hasPrefix("._")
    }

    private func isMaterialFileURL(_ url: URL, root: URL) -> Bool {
        let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return isMaterialArchiveEntry(relative)
    }

    private func moveExtractedDirectoryContents(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for child in children where isMaterialFileURL(child, root: source) {
            try fileManager.moveItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
        }
    }

    private func archiveBaseName(for url: URL) -> String {
        let fileName = url.lastPathComponent
        let lowercased = fileName.lowercased()
        let suffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".tbz", ".txz", ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar"]
        for suffix in suffixes where lowercased.hasSuffix(suffix) {
            return String(fileName.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func uniqueDirectory(in directory: URL, baseName: String) -> URL {
        uniqueURL(in: directory, preferredName: baseName, isDirectory: true)
    }

    private func uniqueURL(in directory: URL, preferredName: String, isDirectory: Bool) -> URL {
        let nameURL = URL(fileURLWithPath: preferredName)
        let fileExtension = isDirectory ? "" : nameURL.pathExtension
        let baseName: String
        if fileExtension.isEmpty {
            baseName = preferredName
        } else {
            baseName = String(preferredName.dropLast(fileExtension.count + 1))
        }

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
            throw ArchiveActionError.missingTool(tool)
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
        var outputHandle: FileHandle?
        var stdoutData = Data()
        var stderrData = Data()
        let outputGroup = DispatchGroup()

        if let stdoutPipe {
            outputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                outputGroup.leave()
            }
        }

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        if let standardOutputFile {
            fileManager.createFile(atPath: standardOutputFile.path, contents: nil)
            outputHandle = try FileHandle(forWritingTo: standardOutputFile)
            process.standardOutput = outputHandle
        } else {
            process.standardOutput = stdoutPipe
        }
        process.standardError = stderrPipe

        do {
            try launchProcessSafely(process, executableURL: executableURL)
        } catch {
            throw ArchiveActionError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        try outputHandle?.close()
        outputGroup.wait()

        let result = CommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPasswordProtectedError(message) {
                throw ArchiveActionError.passwordProtectedArchive
            }
            throw ArchiveActionError.commandFailed(message.isEmpty ? "压缩/解压命令执行失败：\(executableURL.lastPathComponent)" : message)
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

    private func reportCompression(format: String, urls: [URL]) {
        let target = urls.count == 1 ? (urls.first?.lastPathComponent ?? "") : "\(urls.count) 项"
        report(current: 1, total: 1, message: "压缩为 \(format)：\(target)")
    }

    private func report(current: Int, total: Int, message: String) {
        progressHandler?(Progress(current: current, total: total, message: message))
    }

    private func password(for archiveURL: URL) -> String? {
        archivePasswords[archiveURL.standardizedFileURL.path] ?? archivePasswords[archiveURL.path]
    }

    private func isPasswordProtectedError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("password")
            || lowercased.contains("passphrase")
            || lowercased.contains("encrypted")
            || lowercased.contains("encryption")
            || lowercased.contains("unsupported encryption")
    }

    private func archiveConfig() -> ArchiveConfig {
        guard let data = try? Data(contentsOf: AppPaths.configURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .defaultValue
        }
        return config.archive.enabledFormats.isEmpty ? .defaultValue : config.archive
    }
}

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private enum ArchiveKind {
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

    init(url: URL) throws {
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
            throw ArchiveActionError.unsupportedFormat(url.lastPathComponent)
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

    var format: ArchiveFormat {
        switch self {
        case .zip:
            return .zip
        case .tar:
            return .tar
        case .tarGzip:
            return .tarGzip
        case .tarBzip2:
            return .tarBzip2
        case .tarXz:
            return .tarXz
        case .gzip:
            return .gzip
        case .bzip2:
            return .bzip2
        case .xz:
            return .xz
        case .sevenZip:
            return .sevenZip
        case .rar:
            return .rar
        }
    }
}
