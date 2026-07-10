import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers
import UserNotifications

enum MacAssistantNotifier {
    static func notify(title: String, message: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert]) { granted, error in
                    if let error { AppLogger.shared.error("通知权限请求失败：\(error.localizedDescription)") }
                    if granted { deliver(center: center, title: title, message: message) }
                }
            } else if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                deliver(center: center, title: title, message: message)
            }
        }
    }

    private static func deliver(center: UNUserNotificationCenter, title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error { AppLogger.shared.error("本地通知发送失败：\(error.localizedDescription)") }
        }
    }
}

enum SystemCapabilities {
    static let finderExtensionBundleIdentifier = "com.fusheng.mac-tool.FinderSyncExtension"
    static let appBundleIdentifier = "com.fusheng.mac-tool"
    static let archiveDocumentContentTypeIdentifiers = [
        "public.zip-archive",
        "public.tar-archive",
        "org.gnu.gnu-zip-archive",
        "org.gnu.gnu-tar-archive",
        "org.bzip.bzip2-archive",
        "org.bzip.bzip2-tar-archive",
        "org.tukaani.xz-archive",
        "org.tukaani.xz-tar-archive",
        "org.7-zip.7-zip-archive",
        "com.rarlab.rar-archive",
        "com.rarlab.rar-archive-v4"
    ]
    private static let legacyAppBundleIdentifiers = [
        "local.fusheng.displaycolorlock"
    ]
    private static let archiveDocumentFileExtensions = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar"
    ]

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

    static func registerArchiveDocumentHandlers() {
        let bundleIdentifier = appBundleIdentifier as CFString
        for contentType in archiveDocumentContentTypes() {
            LSSetDefaultRoleHandlerForContentType(contentType as CFString, .all, bundleIdentifier)
        }
        AppLogger.shared.info("压缩包默认打开方式已注册到当前应用。")
    }

    static func migrateLegacyArchiveDocumentHandlersIfNeeded() {
        let legacyBundleIdentifiers = Set(legacyAppBundleIdentifiers.map { $0.lowercased() })
        let bundleIdentifier = appBundleIdentifier as CFString
        var migratedCount = 0

        for contentType in archiveDocumentContentTypes() {
            guard let currentHandler = LSCopyDefaultRoleHandlerForContentType(contentType as CFString, .all)?
                .takeRetainedValue() as String?,
                legacyBundleIdentifiers.contains(currentHandler.lowercased()) else {
                continue
            }
            LSSetDefaultRoleHandlerForContentType(contentType as CFString, .all, bundleIdentifier)
            migratedCount += 1
        }

        if migratedCount > 0 {
            AppLogger.shared.info("已迁移旧版压缩包默认打开方式：\(migratedCount) 项。")
        }
    }

    private static func archiveDocumentContentTypes() -> Set<String> {
        var contentTypes = Set(archiveDocumentContentTypeIdentifiers)
        for fileExtension in archiveDocumentFileExtensions {
            if let type = UTType(filenameExtension: fileExtension) {
                contentTypes.insert(type.identifier)
            }
        }
        return contentTypes
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
