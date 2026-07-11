import AppKit
import Foundation
import MacToolCore

struct ArchiveBrowserEntry: Hashable {
    var path: String
    var rawPath: String? = nil
    var size: Int64?
    var isDirectory: Bool
    var modifiedAt: Date?
    var isEncrypted: Bool = false
    var isSymbolicLink: Bool = false

    var displayName: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
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
        case .unsupportedArchive(let name): return "暂不支持预览该压缩包：\(name)"
        case .unsupportedModification(let message): return message
        case .missingTool(let tool): return archiveMissingToolMessage(tool)
        case .passwordRequired: return "压缩包需要密码或密码错误"
        case .extractionFailed(let message): return message
        case .previewUnavailable: return "该文件暂不支持预览"
        }
    }
}

final class ArchiveBrowserService {
    private let archiveURL: URL
    private let format: ArchiveFormat
    private let engine: ArchiveEngine
    private let fileManager: FileManager

    init(
        archiveURL: URL,
        engine: ArchiveEngine = ArchiveEngine(),
        fileManager: FileManager = .default
    ) throws {
        self.archiveURL = archiveURL
        self.engine = engine
        self.fileManager = fileManager
        guard let format = ArchiveFormatDetector.detect(url: archiveURL) else {
            throw ArchiveBrowserError.unsupportedArchive(archiveURL.lastPathComponent)
        }
        self.format = format
    }

    var title: String { archiveURL.lastPathComponent }
    var supportsPassword: Bool { format == .zip || format == .sevenZip || format == .rar }
    var canAddItems: Bool {
        format == .zip || format == .tar || format == .sevenZip || (format == .rar && ArchiveToolLocator().rarWriterURL() != nil)
    }
    var canDeleteItems: Bool {
        format == .zip || format == .sevenZip || (format == .rar && ArchiveToolLocator().rarWriterURL() != nil)
    }

    func requiresPassword() throws -> Bool {
        guard supportsPassword else { return false }
        do {
            return try engine.list(archiveURL, password: nil).contains(where: \.isEncrypted)
        } catch ArchiveEngineError.passwordRequired {
            return true
        } catch ArchiveEngineError.invalidPassword {
            return true
        } catch {
            throw translate(error)
        }
    }

    func validatePassword(_ password: String) throws {
        guard supportsPassword else { return }
        guard !password.isEmpty else { throw ArchiveBrowserError.passwordRequired }
        do {
            try engine.test(archiveURL, password: password)
        } catch ArchiveEngineError.passwordRequired {
            throw ArchiveBrowserError.passwordRequired
        } catch ArchiveEngineError.invalidPassword {
            throw ArchiveBrowserError.passwordRequired
        } catch {
            throw translate(error)
        }
    }

    func listEntries(password: String? = nil) throws -> (entries: [ArchiveBrowserEntry], mayRequirePassword: Bool) {
        do {
            let entries = try engine.list(archiveURL, password: password).map(browserEntry)
            let visible = entries.filter(isVisibleEntry)
            return (visible, entries.contains(where: \.isEncrypted))
        } catch {
            throw translate(error)
        }
    }

    func extract(entries: [ArchiveBrowserEntry], to destination: URL, password: String?) throws {
        guard !entries.isEmpty else { return }
        let stage = fileManager.temporaryDirectory
            .appendingPathComponent("MacAssistantPartialExtraction-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stage) }
        do {
            try engine.extract(ArchiveExtractionRequest(
                archiveURL: archiveURL,
                destinationURL: stage,
                paths: entries.map { $0.rawPath ?? $0.path },
                password: password
            ))
            try mergeKeepingBoth(from: stage, into: destination)
        } catch {
            throw translate(error)
        }
    }

    func extractForPreview(entry: ArchiveBrowserEntry, password: String?) throws -> URL {
        guard !entry.isDirectory else { throw ArchiveBrowserError.previewUnavailable }
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacAssistantArchivePreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        do {
            try engine.extract(ArchiveExtractionRequest(
                archiveURL: archiveURL,
                destinationURL: tempRoot,
                paths: [entry.rawPath ?? entry.path],
                password: password
            ))
            let direct = tempRoot.appendingPathComponent(entry.path)
            if fileManager.fileExists(atPath: direct.path) { return direct }
            if let first = try materializedFiles(in: tempRoot).first { return first }
            throw ArchiveBrowserError.previewUnavailable
        } catch {
            try? fileManager.removeItem(at: tempRoot)
            throw translate(error)
        }
    }

    func addItems(_ urls: [URL], password: String?) throws {
        guard !urls.isEmpty else { return }
        do {
            try engine.add(urls: urls, to: archiveURL, password: password)
        } catch { throw translate(error) }
    }

    func delete(entries: [ArchiveBrowserEntry], password: String?) throws {
        do {
            try engine.delete(paths: entries.map { $0.rawPath ?? $0.path }, from: archiveURL, password: password)
        } catch { throw translate(error) }
    }

    @discardableResult
    func cleanMetadata(password: String?) throws -> Int {
        let all: [ArchiveBrowserEntry]
        do { all = try engine.list(archiveURL, password: password).map(browserEntry) }
        catch { throw translate(error) }
        let paths = all.filter(isCleanupEntry).map { $0.rawPath ?? $0.path }
        guard !paths.isEmpty else { return 0 }
        do { try engine.delete(paths: paths, from: archiveURL, password: password) }
        catch { throw translate(error) }
        return paths.count
    }

    private func browserEntry(_ entry: ArchiveEntry) -> ArchiveBrowserEntry {
        ArchiveBrowserEntry(
            path: entry.path,
            rawPath: entry.rawPath,
            size: entry.size,
            isDirectory: entry.isDirectory,
            modifiedAt: entry.modifiedAt,
            isEncrypted: entry.isEncrypted,
            isSymbolicLink: entry.isSymbolicLink
        )
    }

    private func isVisibleEntry(_ entry: ArchiveBrowserEntry) -> Bool {
        let parts = entry.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.contains("__MACOSX") else { return false }
        let last = parts.last ?? entry.path
        return last != ".DS_Store" && !last.hasPrefix("._")
    }

    private func isCleanupEntry(_ entry: ArchiveBrowserEntry) -> Bool {
        let parts = entry.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard let last = parts.last else { return false }
        return parts.contains("__MACOSX") || last == ".DS_Store" || last.hasPrefix("._")
    }

    private func mergeKeepingBoth(from source: URL, into destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            if !fileManager.fileExists(atPath: target.path) {
                try fileManager.moveItem(at: child, to: target)
                continue
            }
            let sourceIsDirectory = try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            var existingDirectory: ObjCBool = false
            let targetIsDirectory = fileManager.fileExists(atPath: target.path, isDirectory: &existingDirectory) && existingDirectory.boolValue
            if sourceIsDirectory && targetIsDirectory {
                try mergeKeepingBoth(from: child, into: target)
                try? fileManager.removeItem(at: child)
            } else {
                try fileManager.moveItem(at: child, to: uniqueURL(in: destination, preferredName: child.lastPathComponent, isDirectory: sourceIsDirectory))
            }
        }
    }

    private func materializedFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(url) }
        }
        return files
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

    private func translate(_ error: Error) -> Error {
        switch error {
        case ArchiveEngineError.passwordRequired, ArchiveEngineError.invalidPassword:
            return ArchiveBrowserError.passwordRequired
        case ArchiveEngineError.bundledToolMissing:
            return ArchiveBrowserError.extractionFailed(error.localizedDescription)
        case ArchiveEngineError.unsupportedFormat:
            return ArchiveBrowserError.unsupportedArchive(archiveURL.lastPathComponent)
        case ArchiveEngineError.unsupportedMutation(let message):
            return ArchiveBrowserError.unsupportedModification(message)
        default:
            return error is ArchiveBrowserError ? error : ArchiveBrowserError.extractionFailed(error.localizedDescription)
        }
    }
}
