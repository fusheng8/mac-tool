import AppKit
import Foundation

enum MacAssistantNotifier {
    static func notify(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        notification.soundName = nil
        NSUserNotificationCenter.default.deliver(notification)
    }
}

enum SystemCapabilities {
    static let finderExtensionBundleIdentifier = "com.fusheng.mac-tool.FinderSyncExtension"
    static let appBundleIdentifier = "com.fusheng.mac-tool"

    static func firstAvailableTool(_ names: [String]) -> URL? {
        let searchDirectories = ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        for directory in searchDirectories {
            for name in names {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    static func toolStatus(title: String, names: [String]) -> String {
        if let url = firstAvailableTool(names) {
            return "\(title)：已安装（\(url.path)）"
        }
        return "\(title)：未找到（搜索 /usr/bin、/bin、/usr/local/bin、/opt/homebrew/bin）"
    }

    static func finderExtensionStatus() -> (enabled: Bool?, detail: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-A", "-i", finderExtensionBundleIdentifier]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (nil, "无法运行 pluginkit：\(error.localizedDescription)")
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0, !output.isEmpty else {
            return (false, "系统未返回 Finder 扩展状态，请在系统设置中确认扩展是否启用。")
        }

        if output.contains("+") {
            return (true, "Finder 扩展已启用。")
        }
        if output.contains("-") {
            return (false, "Finder 扩展已安装但未启用。")
        }
        return (nil, output)
    }

    static func registerBundledFinderExtensionIfAvailable() {
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent("mac-tool-finder-sync.appex", isDirectory: true)
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            return
        }

        let addResult = runPluginKit(arguments: ["-a", extensionURL.path])
        let enableResult = runPluginKit(arguments: ["-e", "use", "-i", finderExtensionBundleIdentifier])
        if addResult && enableResult {
            AppLogger.shared.info("Finder Sync 扩展已重新注册。")
        } else {
            AppLogger.shared.error("Finder Sync 扩展重新注册失败。")
        }
    }

    private static func runPluginKit(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            AppLogger.shared.error("无法运行 pluginkit：\(error.localizedDescription)")
            return false
        }
    }
}
