import Foundation

enum AppPaths {
    static let appName = "mac-tool"

    static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    static var configURL: URL {
        applicationSupportDirectory.appendingPathComponent("config.json")
    }

    static var finderSyncConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent("com.fusheng.mac-tool.FinderSyncExtension", isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("config.json")
    }

    static var finderBridgeCredentialURL: URL {
        finderSyncConfigURL.deletingLastPathComponent().appendingPathComponent("bridge.key")
    }

    static var stateURL: URL {
        applicationSupportDirectory.appendingPathComponent("state.json")
    }

    static var clipboardHistoryURL: URL {
        applicationSupportDirectory.appendingPathComponent("clipboard-history.json")
    }

    static var clipboardDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Clipboard", isDirectory: true)
    }

    static var clipboardDatabaseURL: URL {
        clipboardDirectory.appendingPathComponent("clipboard-v2.sqlite")
    }

    static var legacyClipboardDatabaseURL: URL {
        clipboardDirectory.appendingPathComponent("clipboard.sqlite")
    }

    static var clipboardBlobDirectory: URL {
        clipboardDirectory.appendingPathComponent("encrypted-blobs", isDirectory: true)
    }

    static var clipboardThumbnailDirectory: URL {
        clipboardDirectory.appendingPathComponent("encrypted-thumbnails", isDirectory: true)
    }

    static var clipboardThumbnailCacheDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("com.fusheng.mac-tool", isDirectory: true)
            .appendingPathComponent("clipboard-thumbnails", isDirectory: true)
    }

    static var recoveryDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }

    static var iCloudBackupDirectory: URL? {
        if let ubiquityDocuments = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Mac助手", isDirectory: true) {
            return ubiquityDocuments
        }

        let cloudDocsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cloudDocsDirectory.path) else {
            return nil
        }
        return cloudDocsDirectory.appendingPathComponent("Mac助手", isDirectory: true)
    }

    static var iCloudConfigBackupURL: URL? {
        iCloudBackupDirectory?.appendingPathComponent("config-backup.json")
    }

    static var logURL: URL {
        logsDirectory.appendingPathComponent("app.log")
    }

    static var uninstallAuditLogURL: URL {
        logsDirectory.appendingPathComponent("uninstall-audit.log")
    }

    static func ensureDirectories() throws {
        let directories = [
            applicationSupportDirectory,
            logsDirectory,
            clipboardDirectory,
            clipboardBlobDirectory,
            clipboardThumbnailDirectory,
            recoveryDirectory,
            finderSyncConfigURL.deletingLastPathComponent()
        ]
        for directory in directories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    static func secureFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
