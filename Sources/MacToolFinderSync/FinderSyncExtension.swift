import AppKit
import Darwin
import FinderSync
import Foundation
import MacToolBridge
import MacToolCore
import os.log

final class FinderSyncExtension: FIFinderSync {
    private static let logger = Logger(subsystem: "com.fusheng.mac-tool.FinderSyncExtension", category: "FinderMenu")

    override init() {
        super.init()
        let urls = Self.monitoredDirectoryURLs()
        FIFinderSyncController.default().directoryURLs = urls
        Self.logger.info("FinderSync init; monitoring: \(urls.map(\.path).joined(separator: ","), privacy: .public)")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        Self.logger.info("menu(for:) called; kind: \(menuKind.rawValue, privacy: .public)")
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            Self.logger.info("menu(for:) ignored unsupported kind")
            return nil
        }
        let config = FinderContextMenuConfig.load().normalized()
        guard config.enabled else {
            Self.logger.info("menu(for:) config disabled")
            return nil
        }

        let context = menuVisibilityContext(for: menuKind, archiveConfig: FinderArchiveConfig.load())
        let menu = NSMenu(title: "")
        for item in config.items where item.enabled {
            if let menuItem = makeMenuItem(item, context: context) {
                menu.addItem(menuItem)
            }
        }
        guard !menu.items.isEmpty else {
            Self.logger.info("menu(for:) no enabled items")
            return nil
        }

        Self.logger.info("menu(for:) returning menu with \(menu.items.count, privacy: .public) items")
        return menu
    }

    private func makeMenuItem(_ item: FinderContextMenuItemConfig, context: FinderMenuVisibilityContext) -> NSMenuItem? {
        guard item.id.isVisible(in: context) else {
            return nil
        }

        if item.children.isEmpty {
            let menuItem = NSMenuItem(title: item.id.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            menuItem.tag = item.id.actionTag
            menuItem.image = NSImage(systemSymbolName: item.id.symbolName, accessibilityDescription: item.id.title)
            return menuItem
        }

        let enabledChildren = item.children.filter { $0.enabled && $0.id.isVisible(in: context) }
        guard !enabledChildren.isEmpty else {
            return nil
        }

        let menuItem = NSMenuItem(title: item.id.title, action: nil, keyEquivalent: "")
        menuItem.image = NSImage(systemSymbolName: item.id.symbolName, accessibilityDescription: item.id.title)
        let submenu = NSMenu(title: item.id.title)
        for child in enabledChildren {
            if let childItem = makeMenuItem(child, context: context) {
                submenu.addItem(childItem)
            }
        }
        menuItem.submenu = submenu
        return menuItem
    }

    private func menuVisibilityContext(for menuKind: FIMenuKind, archiveConfig: FinderArchiveConfig) -> FinderMenuVisibilityContext {
        let controller = FIFinderSyncController.default()
        let selectedURLs = menuKind == .contextualMenuForItems ? (controller.selectedItemURLs() ?? []) : []
        return FinderMenuVisibilityContext(menuKind: menuKind, selectedURLs: selectedURLs, archiveConfig: archiveConfig)
    }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard let itemID = FinderContextMenuItemID(actionTag: sender.tag) else {
            return
        }

        let urls = selectedOrTargetedURLs()
        do {
            try forwardActionToMainApp(itemID: itemID, urls: urls)
            Self.logger.info("performed action: \(itemID.rawValue, privacy: .public)")
        } catch {
            NSSound.beep()
            Self.logger.error("failed action \(itemID.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func selectedOrTargetedURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        if let targeted = controller.targetedURL() {
            return [targeted]
        }
        return [Self.accountHomeDirectory().appendingPathComponent("Desktop", isDirectory: true)]
    }

    private func forwardActionToMainApp(itemID: FinderContextMenuItemID, urls: [URL]) throws {
        let actionURL = try Self.contextMenuActionURL(itemID: itemID, urls: urls)
        if !NSWorkspace.shared.open(actionURL) {
            throw FinderActionRequestError.invalidEncoding
        }
    }

    private static func monitoredDirectoryURLs() -> Set<URL> {
        let home = accountHomeDirectory()
        let names = ["Desktop", "Documents", "Downloads"]
        var urls: Set<URL> = [
            URL(fileURLWithPath: "/", isDirectory: true),
            home
        ]
        for name in names {
            urls.insert(home.appendingPathComponent(name, isDirectory: true))
        }
        return urls
    }

    private static func accountHomeDirectory() -> URL {
        if let password = getpwuid(getuid()), let home = password.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true)
    }

    private static func contextMenuActionURL(itemID: FinderContextMenuItemID, urls: [URL]) throws -> URL {
        guard let credentialURL = FinderConfigPaths.bridgeCredentialURLs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw FinderActionRequestError.missingCredential
        }
        let key = try BridgeCredentialFile.read(at: credentialURL)
        let request = FinderActionRequest(
            action: itemID.rawValue,
            paths: Array(urls.prefix(100)).map { $0.standardizedFileURL.path }
        )
        return try FinderActionCodec.makeURL(request: request, keyData: key)
    }
}

private enum FinderContextMenuItemID: String, Codable, CaseIterable {
    case createFolder
    case copyPath
    case open
    case openWithIDEA
    case openWithTypora
    case openWithVSCode
    case openInTerminal
    case openInWarp
    case newFile
    case newTextFile
    case newMarkdownFile
    case newJSONFile
    case newHTMLFile
    case newWordFile
    case newExcelFile
    case newPowerPointFile
    case archive
    case compressCustom
    case smartExtract
    case smartExtractAndDelete
    case extractToArchiveNameAndDelete
    case extractHere
    case extractToArchiveName
    case compressZip
    case compressTar
    case compressTarGzip
    case compressTarBzip2
    case compressTarXz
    case compressGzip
    case compressBzip2
    case compressXz
    case compressSevenZip
    case compressRar

    init?(actionTag: Int) {
        guard let item = Self.allCases.first(where: { $0.actionTag == actionTag }) else {
            return nil
        }
        self = item
    }

    var actionTag: Int {
        switch self {
        case .createFolder:
            return 1
        case .copyPath:
            return 2
        case .open:
            return 3
        case .openWithIDEA:
            return 4
        case .openWithTypora:
            return 5
        case .openWithVSCode:
            return 6
        case .openInTerminal:
            return 32
        case .openInWarp:
            return 33
        case .newFile:
            return 7
        case .newTextFile:
            return 8
        case .newMarkdownFile:
            return 9
        case .newJSONFile:
            return 10
        case .newHTMLFile:
            return 11
        case .newWordFile:
            return 12
        case .newExcelFile:
            return 13
        case .newPowerPointFile:
            return 14
        case .archive:
            return 15
        case .compressCustom:
            return 29
        case .smartExtractAndDelete:
            return 30
        case .extractToArchiveNameAndDelete:
            return 31
        case .smartExtract:
            return 16
        case .extractHere:
            return 17
        case .extractToArchiveName:
            return 18
        case .compressZip:
            return 19
        case .compressTar:
            return 20
        case .compressTarGzip:
            return 21
        case .compressTarBzip2:
            return 22
        case .compressTarXz:
            return 23
        case .compressGzip:
            return 24
        case .compressBzip2:
            return 25
        case .compressXz:
            return 26
        case .compressSevenZip:
            return 27
        case .compressRar:
            return 28
        }
    }

    var title: String {
        switch self {
        case .createFolder:
            return "新建文件夹"
        case .copyPath:
            return "拷贝路径"
        case .open:
            return "打开"
        case .openWithIDEA:
            return "IDEA"
        case .openWithTypora:
            return "Typora"
        case .openWithVSCode:
            return "VS Code"
        case .openInTerminal:
            return "在终端打开"
        case .openInWarp:
            return "在 Warp 打开"
        case .newFile:
            return "新建"
        case .newTextFile:
            return "TXT"
        case .newMarkdownFile:
            return "Markdown"
        case .newJSONFile:
            return "JSON"
        case .newHTMLFile:
            return "HTML"
        case .newWordFile:
            return "Word"
        case .newExcelFile:
            return "Excel"
        case .newPowerPointFile:
            return "PPT"
        case .archive:
            return "压缩/解压"
        case .compressCustom:
            return "自定义压缩"
        case .smartExtract:
            return "智能解压"
        case .smartExtractAndDelete:
            return "智能解压并删除"
        case .extractToArchiveNameAndDelete:
            return "解压到压缩包名称并删除"
        case .extractHere:
            return "解压到当前目录"
        case .extractToArchiveName:
            return "解压到压缩包名称"
        case .compressZip:
            return "压缩为 ZIP"
        case .compressTar:
            return "压缩为 TAR"
        case .compressTarGzip:
            return "压缩为 tar.gz"
        case .compressTarBzip2:
            return "压缩为 tar.bz2"
        case .compressTarXz:
            return "压缩为 tar.xz"
        case .compressGzip:
            return "压缩为 GZIP"
        case .compressBzip2:
            return "压缩为 BZIP2"
        case .compressXz:
            return "压缩为 XZ"
        case .compressSevenZip:
            return "压缩为 7Z"
        case .compressRar:
            return "压缩为 RAR"
        }
    }

    var symbolName: String {
        switch self {
        case .createFolder:
            return "folder.badge.plus"
        case .copyPath:
            return "doc.on.doc"
        case .open:
            return "arrow.up.right.square"
        case .openWithIDEA:
            return "hammer"
        case .openWithTypora:
            return "textformat"
        case .openWithVSCode:
            return "chevron.left.forwardslash.chevron.right"
        case .openInTerminal:
            return "terminal"
        case .openInWarp:
            return "terminal.fill"
        case .newFile:
            return "doc.badge.plus"
        case .newTextFile:
            return "doc.plaintext"
        case .newMarkdownFile:
            return "doc.text"
        case .newJSONFile:
            return "curlybraces"
        case .newHTMLFile:
            return "globe"
        case .newWordFile:
            return "doc.richtext"
        case .newExcelFile:
            return "tablecells"
        case .newPowerPointFile:
            return "rectangle.on.rectangle"
        case .archive:
            return "archivebox"
        case .compressCustom:
            return "slider.horizontal.3"
        case .smartExtract:
            return "archivebox.fill"
        case .smartExtractAndDelete:
            return "archivebox.fill"
        case .extractToArchiveNameAndDelete:
            return "trash"
        case .extractHere:
            return "arrow.down.doc"
        case .extractToArchiveName:
            return "folder.badge.gearshape"
        case .compressZip, .compressTar, .compressTarGzip, .compressTarBzip2, .compressTarXz, .compressGzip, .compressBzip2, .compressXz, .compressSevenZip, .compressRar:
            return "doc.zipper"
        }
    }

    func isVisible(in context: FinderMenuVisibilityContext) -> Bool {
        switch self {
        case .copyPath, .openWithIDEA, .openWithTypora, .openWithVSCode:
            return context.hasSelection
        case .open:
            return context.hasSelection || context.isContainerMenu
        case .openInTerminal, .openInWarp:
            return context.isContainerMenu || context.isSingleSelectedDirectory
        case .newFile:
            return context.isContainerMenu || context.isSingleSelectedDirectory
        case .createFolder, .newTextFile, .newMarkdownFile, .newJSONFile, .newHTMLFile, .newWordFile, .newExcelFile, .newPowerPointFile:
            return context.isContainerMenu || context.isSingleSelectedDirectory
        case .archive:
            return context.hasSelection
        case .smartExtract, .smartExtractAndDelete, .extractHere, .extractToArchiveName, .extractToArchiveNameAndDelete:
            return context.canSmartExtract
        case .compressCustom, .compressZip, .compressTar, .compressTarGzip, .compressTarBzip2, .compressTarXz, .compressSevenZip, .compressRar:
            return context.canCompress
        case .compressGzip, .compressBzip2, .compressXz:
            return context.canSingleFileCompress
        }
    }
}

private struct FinderMenuVisibilityContext {
    let menuKind: FIMenuKind
    let selectedURLs: [URL]
    let archiveConfig: FinderArchiveConfig

    var isContainerMenu: Bool {
        menuKind == .contextualMenuForContainer
    }

    var hasSelection: Bool {
        !selectedURLs.isEmpty
    }

    var canCompress: Bool {
        hasSelection && selectedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    var canSingleFileCompress: Bool {
        guard selectedURLs.count == 1, let url = selectedURLs.first else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    var canSmartExtract: Bool {
        guard !selectedURLs.isEmpty else {
            return false
        }

        for url in selectedURLs {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return false
            }
            guard let format = ArchiveFormatDetector.detect(url: url), archiveConfig.supports(format) else {
                return false
            }
        }
        return true
    }

    var isSingleSelectedDirectory: Bool {
        guard selectedURLs.count == 1, let url = selectedURLs.first else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private struct FinderArchiveConfig: Codable, Hashable {
    var enabledFormats: Set<ArchiveFormat>

    static let defaultValue = FinderArchiveConfig(enabledFormats: Set(ArchiveFormat.allCases))

    static func load() -> FinderArchiveConfig {
        for url in FinderConfigPaths.urls {
            if let data = try? Data(contentsOf: url),
               let appConfig = try? JSONDecoder().decode(FinderAppConfig.self, from: data),
               let archive = appConfig.archive {
                return archive.enabledFormats.isEmpty ? .defaultValue : archive
            }
        }
        return .defaultValue
    }

    func supports(_ format: ArchiveFormat) -> Bool {
        enabledFormats.contains(format)
    }
}

private struct FinderContextMenuItemConfig: Codable, Hashable {
    var id: FinderContextMenuItemID
    var enabled: Bool
    var children: [FinderContextMenuItemConfig]

    init(id: FinderContextMenuItemID, enabled: Bool = true, children: [FinderContextMenuItemConfig] = []) {
        self.id = id
        self.enabled = enabled
        self.children = children
    }
}

private struct FinderContextMenuConfig: Codable, Hashable {
    var enabled: Bool
    var items: [FinderContextMenuItemConfig]

    static func load() -> FinderContextMenuConfig {
        for url in FinderConfigPaths.urls {
            if let data = try? Data(contentsOf: url),
               let appConfig = try? JSONDecoder().decode(FinderAppConfig.self, from: data) {
                return appConfig.contextMenu ?? .defaultValue
            }
        }
        return .defaultValue
    }

    func normalized() -> FinderContextMenuConfig {
        FinderContextMenuConfig(
            enabled: enabled,
            items: Self.normalize(items: Self.migrateLegacyItems(items), defaults: Self.defaultValue.items)
        )
    }

    private static func migrateLegacyItems(_ items: [FinderContextMenuItemConfig]) -> [FinderContextMenuItemConfig] {
        guard let createFolderItem = items.first(where: { $0.id == .createFolder }) else {
            return migrateLegacyArchiveItems(items)
        }

        var migratedItems = items.filter { $0.id != .createFolder }
        guard let newFileIndex = migratedItems.firstIndex(where: { $0.id == .newFile }),
              !migratedItems[newFileIndex].children.contains(where: { $0.id == .createFolder }) else {
            return migrateLegacyArchiveItems(migratedItems)
        }

        migratedItems[newFileIndex].children.insert(createFolderItem, at: 0)
        return migrateLegacyArchiveItems(migratedItems)
    }

    private static func migrateLegacyArchiveItems(_ items: [FinderContextMenuItemConfig]) -> [FinderContextMenuItemConfig] {
        var migratedItems = items
        guard let archiveIndex = migratedItems.firstIndex(where: { $0.id == .archive }) else {
            return migratedItems
        }
        if let smartExtractIndex = migratedItems[archiveIndex].children.firstIndex(where: { $0.id == .smartExtract }) {
            var insertionIndex = smartExtractIndex + 1
            if !migratedItems[archiveIndex].children.contains(where: { $0.id == .smartExtractAndDelete }) {
                migratedItems[archiveIndex].children.insert(FinderContextMenuItemConfig(id: .smartExtractAndDelete), at: insertionIndex)
                insertionIndex += 1
            }
            if !migratedItems[archiveIndex].children.contains(where: { $0.id == .extractToArchiveNameAndDelete }) {
                migratedItems[archiveIndex].children.insert(FinderContextMenuItemConfig(id: .extractToArchiveNameAndDelete, enabled: false), at: insertionIndex)
            }
        }
        let childIDs = migratedItems[archiveIndex].children.map(\.id)
        guard childIDs.count <= 5,
              childIDs.contains(.smartExtract),
              childIDs.contains(.compressZip),
              childIDs.contains(.compressTarGzip),
              let tarGzipIndex = migratedItems[archiveIndex].children.firstIndex(where: { $0.id == .compressTarGzip }) else {
            return migratedItems
        }
        migratedItems[archiveIndex].children[tarGzipIndex].enabled = false
        return migratedItems
    }

    private static func normalize(items: [FinderContextMenuItemConfig], defaults: [FinderContextMenuItemConfig]) -> [FinderContextMenuItemConfig] {
        var normalizedItems = items.compactMap { item -> FinderContextMenuItemConfig? in
            guard let defaultItem = defaults.first(where: { $0.id == item.id }) else {
                return nil
            }
            return FinderContextMenuItemConfig(
                id: item.id,
                enabled: item.enabled,
                children: normalize(items: item.children, defaults: defaultItem.children)
            )
        }

        for defaultItem in defaults where !normalizedItems.contains(where: { $0.id == defaultItem.id }) {
            normalizedItems.append(defaultItem)
        }
        return normalizedItems
    }

    static let defaultValue = FinderContextMenuConfig(
        enabled: true,
        items: [
            FinderContextMenuItemConfig(id: .copyPath),
            FinderContextMenuItemConfig(
                id: .open,
                children: [
                    FinderContextMenuItemConfig(id: .openWithIDEA),
                    FinderContextMenuItemConfig(id: .openWithTypora),
                    FinderContextMenuItemConfig(id: .openWithVSCode),
                    FinderContextMenuItemConfig(id: .openInTerminal),
                    FinderContextMenuItemConfig(id: .openInWarp)
                ]
            ),
            FinderContextMenuItemConfig(
                id: .newFile,
                children: [
                    FinderContextMenuItemConfig(id: .createFolder),
                    FinderContextMenuItemConfig(id: .newTextFile),
                    FinderContextMenuItemConfig(id: .newMarkdownFile),
                    FinderContextMenuItemConfig(id: .newJSONFile),
                    FinderContextMenuItemConfig(id: .newHTMLFile),
                    FinderContextMenuItemConfig(id: .newWordFile),
                    FinderContextMenuItemConfig(id: .newExcelFile),
                    FinderContextMenuItemConfig(id: .newPowerPointFile)
                ]
            ),
            FinderContextMenuItemConfig(
                id: .archive,
                children: [
                    FinderContextMenuItemConfig(id: .smartExtract),
                    FinderContextMenuItemConfig(id: .smartExtractAndDelete),
                    FinderContextMenuItemConfig(id: .extractToArchiveNameAndDelete, enabled: false),
                    FinderContextMenuItemConfig(id: .extractHere, enabled: false),
                    FinderContextMenuItemConfig(id: .extractToArchiveName, enabled: false),
                    FinderContextMenuItemConfig(id: .compressCustom),
                    FinderContextMenuItemConfig(id: .compressZip),
                    FinderContextMenuItemConfig(id: .compressTar, enabled: false),
                    FinderContextMenuItemConfig(id: .compressTarGzip, enabled: false),
                    FinderContextMenuItemConfig(id: .compressTarBzip2, enabled: false),
                    FinderContextMenuItemConfig(id: .compressTarXz, enabled: false),
                    FinderContextMenuItemConfig(id: .compressGzip, enabled: false),
                    FinderContextMenuItemConfig(id: .compressBzip2, enabled: false),
                    FinderContextMenuItemConfig(id: .compressXz, enabled: false),
                    FinderContextMenuItemConfig(id: .compressSevenZip, enabled: false),
                    FinderContextMenuItemConfig(id: .compressRar, enabled: false)
                ]
            )
        ]
    )
}

private extension Array where Element == URL {
    func uniquedByPath() -> [URL] {
        var seen: Set<String> = []
        return filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else {
                return false
            }
            seen.insert(path)
            return true
        }
    }
}

private enum FinderConfigPaths {
    static var urls: [URL] {
        let sandboxHome = FileManager.default.homeDirectoryForCurrentUser
        let accountHome = accountHomeDirectory()
        let containerHome = accountHome
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent("com.fusheng.mac-tool.FinderSyncExtension", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)

        return [
            configURL(home: sandboxHome),
            configURL(home: containerHome),
            configURL(home: accountHome)
        ].uniquedByPath()
    }

    static var bridgeCredentialURLs: [URL] {
        urls.map { $0.deletingLastPathComponent().appendingPathComponent("bridge.key") }
    }

    private static func configURL(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("mac-tool", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private static func accountHomeDirectory() -> URL {
        if let password = getpwuid(getuid()), let home = password.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true)
    }
}

private struct FinderAppConfig: Decodable {
    var contextMenu: FinderContextMenuConfig?
    var archive: FinderArchiveConfig?
}

private enum FinderContextMenuActionError: LocalizedError {
    case unsupportedAction(FinderContextMenuItemID)
    case applicationNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAction(let itemID):
            return "不支持执行菜单项：\(itemID.title)"
        case .applicationNotFound(let appName):
            return "找不到应用：\(appName)"
        }
    }
}

private final class FinderContextMenuActionExecutor {
    func perform(itemID: FinderContextMenuItemID, urls: [URL]) throws {
        switch itemID {
        case .createFolder:
            try createFolder(in: targetDirectory(from: urls))
        case .copyPath:
            copyPath(urls)
        case .openWithIDEA:
            try open(urls: urls, app: .idea)
        case .openWithTypora:
            try open(urls: urls, app: .typora)
        case .openWithVSCode:
            try open(urls: urls, app: .vscode)
        case .openInTerminal:
            try openTerminalWorkspace(urls: urls, app: .terminal)
        case .openInWarp:
            try openWarpWorkspace(urls: urls)
        case .newTextFile:
            try createTextFile(named: "新建文本文档", extension: "txt", contents: Data(), in: targetDirectory(from: urls))
        case .newMarkdownFile:
            try createTextFile(named: "新建 Markdown", extension: "md", contents: Data(), in: targetDirectory(from: urls))
        case .newJSONFile:
            try createTextFile(named: "新建 JSON", extension: "json", contents: Data("{\n  \n}\n".utf8), in: targetDirectory(from: urls))
        case .newHTMLFile:
            try createTextFile(named: "新建 HTML", extension: "html", contents: Data(Self.defaultHTML.utf8), in: targetDirectory(from: urls))
        case .newWordFile:
            try createOfficeFile(named: "新建 Word", extension: "docx", entries: FinderOfficeTemplate.word, in: targetDirectory(from: urls))
        case .newExcelFile:
            try createOfficeFile(named: "新建 Excel", extension: "xlsx", entries: FinderOfficeTemplate.excel, in: targetDirectory(from: urls))
        case .newPowerPointFile:
            try createPowerPointFile(in: targetDirectory(from: urls))
        case .open, .newFile, .archive, .smartExtract, .smartExtractAndDelete, .extractHere, .extractToArchiveName, .extractToArchiveNameAndDelete, .compressCustom, .compressZip, .compressTar, .compressTarGzip, .compressTarBzip2, .compressTarXz, .compressGzip, .compressBzip2, .compressXz, .compressSevenZip, .compressRar:
            throw FinderContextMenuActionError.unsupportedAction(itemID)
        }
    }

    private func targetDirectory(from urls: [URL]) throws -> URL {
        if let first = urls.first {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return first
            }
            return first.deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func createFolder(in directory: URL) throws {
        let url = uniqueURL(in: directory, baseName: "新建文件夹", extension: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    private func copyPath(_ urls: [URL]) {
        let paths = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    private func createTextFile(named baseName: String, extension fileExtension: String, contents: Data, in directory: URL) throws {
        let url = uniqueURL(in: directory, baseName: baseName, extension: fileExtension)
        try contents.write(to: url, options: .withoutOverwriting)
    }

    private func createOfficeFile(named baseName: String, extension fileExtension: String, entries: [FinderZipEntry], in directory: URL) throws {
        let url = uniqueURL(in: directory, baseName: baseName, extension: fileExtension)
        let data = FinderZipWriter.archive(entries: entries)
        try data.write(to: url, options: .withoutOverwriting)
    }

    private func createPowerPointFile(in directory: URL) throws {
        let url = uniqueURL(in: directory, baseName: "新建 PPT", extension: "pptx")
        let data = FinderZipWriter.archive(entries: FinderOfficeTemplate.powerPoint)
        try data.write(to: url, options: .withoutOverwriting)
    }

    private func open(urls: [URL], app: FinderExternalApp) throws {
        guard let appURL = app.url else {
            throw FinderContextMenuActionError.applicationNotFound(app.displayName)
        }
        let targets = urls.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : urls
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(targets, withApplicationAt: appURL, configuration: configuration)
    }

    private func openTerminalWorkspace(urls: [URL], app: FinderExternalApp) throws {
        guard let appURL = app.url else {
            throw FinderContextMenuActionError.applicationNotFound(app.displayName)
        }
        let directory = try targetDirectory(from: urls)
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: configuration)
    }

    private func openWarpWorkspace(urls: [URL]) throws {
        guard FinderExternalApp.warp.url != nil else {
            throw FinderContextMenuActionError.applicationNotFound(FinderExternalApp.warp.displayName)
        }
        var components = URLComponents()
        components.scheme = "warp"
        components.host = "action"
        components.path = "/new_window"
        components.queryItems = [URLQueryItem(name: "path", value: try targetDirectory(from: urls).path)]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            throw FinderContextMenuActionError.applicationNotFound(FinderExternalApp.warp.displayName)
        }
    }

    private func uniqueURL(in directory: URL, baseName: String, extension fileExtension: String?) -> URL {
        func candidate(_ index: Int) -> URL {
            let name = index == 0 ? baseName : "\(baseName) \(index + 1)"
            if let fileExtension {
                return directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
            }
            return directory.appendingPathComponent(name, isDirectory: true)
        }

        var index = 0
        var url = candidate(index)
        while FileManager.default.fileExists(atPath: url.path) {
            index += 1
            url = candidate(index)
        }
        return url
    }

    private static let defaultHTML = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <title>新建 HTML</title>
    </head>
    <body>
    </body>
    </html>
    """

}

private struct FinderExternalApp {
    let displayName: String
    let bundleIdentifiers: [String]
    let fallbackPaths: [String]

    var url: URL? {
        for bundleIdentifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url
            }
        }
        for path in fallbackPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static let idea = FinderExternalApp(
        displayName: "IntelliJ IDEA",
        bundleIdentifiers: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"],
        fallbackPaths: ["/Applications/IntelliJ IDEA.app", "/Applications/IntelliJ IDEA CE.app"]
    )

    static let typora = FinderExternalApp(
        displayName: "Typora",
        bundleIdentifiers: ["abnerworks.Typora", "io.typora"],
        fallbackPaths: ["/Applications/Typora.app"]
    )

    static let vscode = FinderExternalApp(
        displayName: "Visual Studio Code",
        bundleIdentifiers: ["com.microsoft.VSCode"],
        fallbackPaths: ["/Applications/Visual Studio Code.app"]
    )

    static let terminal = FinderExternalApp(
        displayName: "Terminal",
        bundleIdentifiers: ["com.apple.Terminal"],
        fallbackPaths: ["/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app"]
    )

    static let warp = FinderExternalApp(
        displayName: "Warp",
        bundleIdentifiers: ["dev.warp.Warp-Stable", "dev.warp.Warp"],
        fallbackPaths: ["/Applications/Warp.app"]
    )
}
private struct FinderZipEntry {
    let path: String
    let data: Data
}

private enum FinderZipWriter {
    static func archive(entries: [FinderZipEntry]) -> Data {
        var data = Data()
        var centralDirectory = Data()

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            let crc = FinderCRC32.checksum(entry.data)
            let localHeaderOffset = UInt32(data.count)

            data.appendUInt32LE(0x04034b50)
            data.appendUInt16LE(20)
            data.appendUInt16LE(0)
            data.appendUInt16LE(0)
            data.appendUInt16LE(0)
            data.appendUInt16LE(0)
            data.appendUInt32LE(crc)
            data.appendUInt32LE(UInt32(entry.data.count))
            data.appendUInt32LE(UInt32(entry.data.count))
            data.appendUInt16LE(UInt16(pathData.count))
            data.appendUInt16LE(0)
            data.append(pathData)
            data.append(entry.data)

            centralDirectory.appendUInt32LE(0x02014b50)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(crc)
            centralDirectory.appendUInt32LE(UInt32(entry.data.count))
            centralDirectory.appendUInt32LE(UInt32(entry.data.count))
            centralDirectory.appendUInt16LE(UInt16(pathData.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(pathData)
        }

        let centralDirectoryOffset = UInt32(data.count)
        data.append(centralDirectory)
        data.appendUInt32LE(0x06054b50)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(UInt16(entries.count))
        data.appendUInt16LE(UInt16(entries.count))
        data.appendUInt32LE(UInt32(centralDirectory.count))
        data.appendUInt32LE(centralDirectoryOffset)
        data.appendUInt16LE(0)

        return data
    }
}

private enum FinderCRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            var current = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                current = (current & 1) == 1 ? (0xedb88320 ^ (current >> 1)) : (current >> 1)
            }
            crc = (crc >> 8) ^ current
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}

private enum FinderOfficeTemplate {
    static let word = [
        FinderZipEntry(path: "[Content_Types].xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """.utf8)),
        FinderZipEntry(path: "_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """.utf8)),
        FinderZipEntry(path: "word/document.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p/><w:sectPr/></w:body></w:document>
        """.utf8))
    ]

    static let excel = [
        FinderZipEntry(path: "[Content_Types].xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """.utf8)),
        FinderZipEntry(path: "_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8)),
        FinderZipEntry(path: "xl/workbook.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """.utf8)),
        FinderZipEntry(path: "xl/_rels/workbook.xml.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """.utf8)),
        FinderZipEntry(path: "xl/worksheets/sheet1.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>
        """.utf8))
    ]

    static let powerPoint = [
        FinderZipEntry(path: "[Content_Types].xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/></Types>
        """.utf8)),
        FinderZipEntry(path: "_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>
        """.utf8)),
        FinderZipEntry(path: "ppt/presentation.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/></p:presentation>
        """.utf8))
    ]
}
