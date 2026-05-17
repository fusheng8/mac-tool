import Foundation

final class AppLogger {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "mac-tool.Logger")
    private let formatter: ISO8601DateFormatter

    private init() {
        formatter = ISO8601DateFormatter()
        try? AppPaths.ensureDirectories()
    }

    func info(_ message: String) {
        write(level: "信息", message)
    }

    func error(_ message: String) {
        write(level: "错误", message)
    }

    func write(level: String, _ message: String) {
        queue.async {
            let line = "\(self.formatter.string(from: Date())) [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else {
                return
            }
            if FileManager.default.fileExists(atPath: AppPaths.logURL.path) {
                if let handle = try? FileHandle(forWritingTo: AppPaths.logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: AppPaths.logURL)
            }
        }
    }

    func recentLogSummary(maxCharacters: Int = 3000) -> String {
        queue.sync {
            let url = AppPaths.logURL
            let path = url.path
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: path) else {
                return """
                路径: \(path)
                状态: 日志文件尚未创建
                最近内容: 无
                """
            }

            let attributes = try? fileManager.attributesOfItem(atPath: path)
            let fileSize = attributes?[.size] as? NSNumber
            let modifiedAt = attributes?[.modificationDate] as? Date
            let rawText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let recentText: String
            if trimmedText.isEmpty {
                recentText = "日志文件为空"
            } else if trimmedText.count > maxCharacters {
                recentText = String(trimmedText.suffix(maxCharacters))
            } else {
                recentText = trimmedText
            }

            return """
            路径: \(path)
            大小: \(fileSize.map { "\($0.intValue) 字节" } ?? "未知")
            修改时间: \(modifiedAt.map { self.formatter.string(from: $0) } ?? "未知")
            最近内容:
            \(recentText)
            """
        }
    }
}
