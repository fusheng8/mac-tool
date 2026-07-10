import Foundation

final class AppLogger: @unchecked Sendable {
    static let shared: AppLogger = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mac-tool-tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            return AppLogger(logURL: directory.appendingPathComponent("app.log"))
        }
        return AppLogger(logURL: AppPaths.logURL)
    }()

    private let queue = DispatchQueue(label: "mac-tool.Logger")
    private let formatter = ISO8601DateFormatter()
    private let logURL: URL
    private let maxBytes: Int
    private let retainedFiles: Int
    private let encoder = JSONEncoder()

    init(logURL: URL, maxBytes: Int = 2 * 1024 * 1024, retainedFiles: Int = 3) {
        self.logURL = logURL
        self.maxBytes = maxBytes
        self.retainedFiles = max(1, retainedFiles)
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: logURL.deletingLastPathComponent().path
            )
        } catch {
            // 日志不可用不能阻止应用启动。
        }
    }

    func info(_ message: String) { event(level: "info", name: "application", message: message) }
    func error(_ message: String) { event(level: "error", name: "application", message: message) }

    func event(level: String, name: String, message: String, fields: [String: String] = [:]) {
        queue.async {
            let record = LogRecord(
                timestamp: self.formatter.string(from: Date()),
                level: level,
                event: name,
                message: self.redact(message),
                fields: fields.mapValues(self.redact)
            )
            guard let encoded = try? self.encoder.encode(record) else { return }
            var line = encoded
            line.append(0x0A)
            do {
                try self.rotateIfNeeded(adding: line.count)
                if !FileManager.default.fileExists(atPath: self.logURL.path) {
                    try line.write(to: self.logURL, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: self.logURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.logURL.path)
            } catch {
                // 避免日志写入失败形成递归日志。
            }
        }
    }

    func recentLogSummary(maxCharacters: Int = 3000) -> String {
        queue.sync {
            let path = logURL.path
            guard FileManager.default.fileExists(atPath: path) else {
                return "路径: \(path)\n状态: 日志文件尚未创建\n最近内容: 无"
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let fileSize = attributes?[.size] as? NSNumber
            let modifiedAt = attributes?[.modificationDate] as? Date
            let rawText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let text = rawText.count > maxCharacters ? String(rawText.suffix(maxCharacters)) : rawText
            return """
            路径: \(path)
            大小: \(fileSize.map { "\($0.intValue) 字节" } ?? "未知")
            修改时间: \(modifiedAt.map { formatter.string(from: $0) } ?? "未知")
            最近内容:
            \(text.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        }
    }

    private func rotateIfNeeded(adding byteCount: Int) throws {
        let existing = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard existing + byteCount > maxBytes else { return }
        for index in stride(from: retainedFiles, through: 1, by: -1) {
            let destination = rotatedURL(index: index)
            let source = index == 1 ? logURL : rotatedURL(index: index - 1)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
    }

    private func rotatedURL(index: Int) -> URL {
        URL(fileURLWithPath: "\(logURL.path).\(index)")
    }

    private func redact(_ value: String) -> String {
        var result = value.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
        if let regex = try? NSRegularExpression(pattern: #"/Users/[^/\s]+"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "~"
            )
        }
        return result
    }
}

private struct LogRecord: Codable {
    let timestamp: String
    let level: String
    let event: String
    let message: String
    let fields: [String: String]
}
