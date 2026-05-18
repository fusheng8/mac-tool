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
        clipboardDirectory.appendingPathComponent("clipboard.sqlite")
    }

    static var clipboardBlobDirectory: URL {
        clipboardDirectory.appendingPathComponent("blobs", isDirectory: true)
    }

    static var clipboardThumbnailDirectory: URL {
        clipboardDirectory.appendingPathComponent("thumbnails", isDirectory: true)
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

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clipboardBlobDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clipboardThumbnailDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: finderSyncConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
