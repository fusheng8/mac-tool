import AppKit
import CoreServices
import CoreSpotlight
import Darwin
import Foundation
import UniformTypeIdentifiers

private extension Notification.Name {
    static let macToolContextMenuAction = Notification.Name("com.fusheng.mac-tool.contextMenuAction")
    static let macToolOpenSettings = Notification.Name("com.fusheng.mac-tool.openSettings")
    static let macToolOpenFiles = Notification.Name("com.fusheng.mac-tool.openFiles")
    static let macToolOpenURL = Notification.Name("com.fusheng.mac-tool.openURL")
}

private let displayRestoreWatchdogArgument = "--display-restore-watchdog"
private let parentPIDArgument = "--parent-pid"

private final class SingleInstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire() throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(
            at: AppPaths.applicationSupportDirectory,
            withIntermediateDirectories: true
        )

        let lockURL = AppPaths.applicationSupportDirectory.appendingPathComponent("app.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EACCES || lockError == EAGAIN {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }

        Darwin.ftruncate(descriptor, 0)
        let pidText = "\(getpid())\n"
        _ = pidText.withCString { pointer in
            Darwin.write(descriptor, pointer, strlen(pointer))
        }
        return SingleInstanceLock(fileDescriptor: descriptor)
    }

    deinit {
        Darwin.lockf(fileDescriptor, F_ULOCK, 0)
        Darwin.close(fileDescriptor)
    }
}

@discardableResult
private func forwardOpenURLsToExistingInstance(_ urls: [URL]) -> Bool {
    let filePaths = urls
        .filter(\.isFileURL)
        .map { $0.standardizedFileURL.path }
    let appURLs = urls
        .filter { !$0.isFileURL }
        .map(\.absoluteString)

    var didForward = false
    if !filePaths.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            .macToolOpenFiles,
            object: nil,
            userInfo: ["paths": filePaths],
            deliverImmediately: true
        )
        didForward = true
    }

    for urlString in appURLs {
        DistributedNotificationCenter.default().postNotificationName(
            .macToolOpenURL,
            object: nil,
            userInfo: ["url": urlString],
            deliverImmediately: true
        )
        didForward = true
    }
    return didForward
}

@discardableResult
private func forwardLaunchArgumentsToExistingInstance() -> Bool {
    let urls = CommandLine.arguments.dropFirst().compactMap { argument -> URL? in
        if argument.hasPrefix("-psn_") || argument.hasPrefix("--") {
            return nil
        }
        if let url = URL(string: argument), url.scheme == "macassistant" {
            return url
        }

        let path = (argument as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
    return forwardOpenURLsToExistingInstance(urls)
}

private func processExists(pid: pid_t) -> Bool {
    guard pid > 1 else {
        return false
    }
    if Darwin.kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}

private func runDisplayRestoreWatchdog(parentPID: pid_t) {
    while getppid() == parentPID && processExists(pid: parentPID) {
        Thread.sleep(forTimeInterval: 0.5)
    }
    Thread.sleep(forTimeInterval: 0.5)

    let store = ProfileStore()
    let detector = DisplayDetector()
    let disconnect = SoftDisconnectController(detector: detector)
    disconnect.restoreDefaultDisplayState(store: store, reason: "应用被强制关闭")
}

private func startDisplayRestoreWatchdog() {
    guard let executableURL = Bundle.main.executableURL else {
        AppLogger.shared.error("显示器恢复守护进程启动失败：没有找到当前可执行文件。")
        return
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
        displayRestoreWatchdogArgument,
        parentPIDArgument,
        String(getpid())
    ]

    if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
        process.standardOutput = nullOutput
        process.standardError = nullOutput
    }

    do {
        try process.run()
        AppLogger.shared.info("显示器恢复守护进程已启动。")
    } catch {
        AppLogger.shared.error("显示器恢复守护进程启动失败：\(error.localizedDescription)")
    }
}

if CommandLine.arguments.contains(displayRestoreWatchdogArgument) {
    guard let pidArgumentIndex = CommandLine.arguments.firstIndex(of: parentPIDArgument) else {
        fputs("缺少父进程 PID\n", stderr)
        exit(2)
    }
    let valueIndex = CommandLine.arguments.index(after: pidArgumentIndex)
    guard CommandLine.arguments.indices.contains(valueIndex),
          let parentPID = pid_t(CommandLine.arguments[valueIndex]),
          parentPID > 1 else {
        fputs("父进程 PID 无效\n", stderr)
        exit(2)
    }

    runDisplayRestoreWatchdog(parentPID: parentPID)
    exit(0)
}

if CommandLine.arguments.contains("--list-displays") {
    let detector = DisplayDetector()
    for display in detector.onlineDisplays() {
        let location = display.isBuiltIn ? "内置" : "外接"
        print("\(location) | id=\(display.runtimeDisplayID) | \(display.displayName) | \(display.vendorId) | \(display.modelId) | serial=\(display.serialNumber) | edid=\(display.edidUUID)")
    }
    exit(0)
}

if let actionIndex = CommandLine.arguments.firstIndex(of: "--context-menu-action") {
    let nextIndex = CommandLine.arguments.index(after: actionIndex)
    guard CommandLine.arguments.indices.contains(nextIndex),
          let itemID = ContextMenuItemID(rawValue: CommandLine.arguments[nextIndex]) else {
        fputs("缺少有效的右键菜单动作 ID\n", stderr)
        exit(2)
    }

    let pathStartIndex = CommandLine.arguments.index(after: nextIndex)
    let urls = CommandLine.arguments[pathStartIndex...].map { URL(fileURLWithPath: $0) }
    do {
        try ContextMenuActionExecutor().perform(itemID: itemID, urls: urls)
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private enum AppRuntime {
    static var isSecondaryInstance = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ProfileStore()
    private let detector = DisplayDetector()
    private let statuses = RuntimeStatusStore()

    private var automation: AutomationController!
    private var disconnect: SoftDisconnectController!
    private var recovery: RecoveryManager!
    private var menuBar: MenuBarController!
    private var clipboard: ClipboardHistoryController!
    private let spotlightIndexer = SpotlightActionIndexer()
    private var didIndexSpotlightActions = false
    private var didStartDisplayRestoreWatchdog = false
    private var progressWindowController: ContextMenuProgressWindowController?
    private var compressionOptionsWindowController: ArchiveCompressionOptionsWindowController?
    private var archiveWindows: [ArchiveBrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isSecondaryInstance else {
            forwardLaunchArgumentsToExistingInstance()
            terminateSecondaryInstanceSoon()
            return
        }

        NSApp.setActivationPolicy(.accessory)
        try? AppPaths.ensureDirectories()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleContextMenuActionNotification(_:)),
            name: .macToolContextMenuAction,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenSettingsNotification(_:)),
            name: .macToolOpenSettings,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenFilesNotification(_:)),
            name: .macToolOpenFiles,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenURLNotification(_:)),
            name: .macToolOpenURL,
            object: nil
        )

        disconnect = SoftDisconnectController(detector: detector)
        automation = AutomationController(store: store, disconnect: disconnect)
        recovery = RecoveryManager(store: store, disconnect: disconnect, automation: automation, statuses: statuses)
        clipboard = ClipboardHistoryController(store: store)
        menuBar = MenuBarController(
            store: store,
            detector: detector,
            automation: automation,
            disconnect: disconnect,
            recovery: recovery,
            statuses: statuses,
            clipboard: clipboard,
            onOpenPortManagement: { [weak self] in
                self?.indexSpotlightActionsIfNeeded()
            },
            onConfigurationChanged: { [weak self] in
                self?.automation.updateBackgroundActivity()
                self?.startDisplayRestoreWatchdogIfNeeded()
            }
        )
        startDisplayRestoreWatchdogIfNeeded()

        statuses.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.startDisplayRestoreWatchdogIfNeeded()
                self?.menuBar.rebuildMenu()
            }
        }
        automation.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.menuBar.refreshAfterDisplayChange()
            }
        }
        recovery.onCountdownTick = { [weak self] in
            DispatchQueue.main.async {
                self?.menuBar.rebuildMenu()
            }
        }

        automation.start()
        clipboard.start()
        recovery.recoverPendingOnLaunch()
        AppLogger.shared.info("Mac助手已启动")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        if hasDisplayBackgroundWork() {
            disconnect?.restoreDefaultDisplayState(store: store, reason: "应用退出")
        }
        automation?.stop()
        clipboard?.stop()
        AppLogger.shared.info("Mac助手已退出")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !AppRuntime.isSecondaryInstance else {
            terminateSecondaryInstanceSoon()
            return false
        }

        menuBar.openSettingsWindow()
        return false
    }

    @objc private func handleContextMenuActionNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let rawAction = userInfo["action"] as? String,
              let itemID = ContextMenuItemID(rawValue: rawAction) else {
            return
        }
        let paths = userInfo["paths"] as? [String] ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }
        performContextMenuAction(itemID: itemID, rawAction: rawAction, urls: urls)
    }

    @objc private func handleOpenSettingsNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.menuBar.openSettingsWindow()
        }
    }

    @objc private func handleOpenFilesNotification(_ notification: Notification) {
        let paths = notification.userInfo?["paths"] as? [String] ?? []
        for path in paths {
            openArchiveBrowser(URL(fileURLWithPath: path))
        }
    }

    @objc private func handleOpenURLNotification(_ notification: Notification) {
        guard let urlString = notification.userInfo?["url"] as? String,
              let url = URL(string: urlString) else {
            return
        }
        handleURL(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !AppRuntime.isSecondaryInstance else {
            forwardOpenURLsToExistingInstance(urls)
            terminateSecondaryInstanceSoon()
            return
        }

        for url in urls {
            if url.isFileURL {
                openArchiveBrowser(url)
            } else {
                handleURL(url)
            }
        }
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard !AppRuntime.isSecondaryInstance else {
            terminateSecondaryInstanceSoon()
            return false
        }

        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return false
        }

        switch identifier {
        case SpotlightActionIdentifier.portManagement:
            DispatchQueue.main.async { [weak self] in
                self?.menuBar.openPortManagement()
            }
            return true
        default:
            return false
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "macassistant" else {
            return
        }

        if url.host == "open",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let page = components.queryItems?.first(where: { $0.name == "page" })?.value {
            switch page {
            case "displays":
                menuBar.openDisplaySettings()
            case "port-management":
                indexSpotlightActionsIfNeeded()
                menuBar.openPortManagement()
            case "archive":
                menuBar.openArchiveSettings()
            default:
                break
            }
            return
        }

        handleContextMenuActionURL(url)
    }

    private func openArchiveBrowser(_ url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                NSApp.setActivationPolicy(.regular)
                let password: String?
                switch try self.passwordPreflight(for: url) {
                case .notRequired:
                    password = nil
                case .provided(let value):
                    password = value
                case .cancelled:
                    return
                }
                let controller = try ArchiveBrowserWindowController(archiveURL: url, password: password)
                self.archiveWindows.append(controller)
                controller.window?.delegate = self
                controller.show()
            } catch {
                self.showArchiveOpenError(error)
            }
        }
    }

    private func indexSpotlightActionsIfNeeded() {
        guard !didIndexSpotlightActions else {
            return
        }
        didIndexSpotlightActions = true
        spotlightIndexer.indexActions()
    }

    private func startDisplayRestoreWatchdogIfNeeded() {
        guard !didStartDisplayRestoreWatchdog, hasDisplayBackgroundWork() else {
            return
        }
        didStartDisplayRestoreWatchdog = true
        startDisplayRestoreWatchdog()
    }

    private func hasDisplayBackgroundWork() -> Bool {
        store.profiles.contains { $0.disconnect.enabled && $0.disconnect.allowSoftDisconnect } || !store.pendingReconnects.isEmpty
    }

    private func showArchiveOpenError(_ error: Error) {
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "无法打开压缩包"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func registerArchiveDocumentHandlers() {
        let bundleIdentifier = "com.fusheng.mac-tool" as CFString
        for fileExtension in ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar"] {
            guard let type = UTType(filenameExtension: fileExtension) else {
                continue
            }
            LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, .all, bundleIdentifier)
        }
    }

    private func handleContextMenuActionURL(_ url: URL) {
        guard url.scheme == "macassistant",
              url.host == "context-menu",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawAction = components.queryItems?.first(where: { $0.name == "action" })?.value,
              let itemID = ContextMenuItemID(rawValue: rawAction) else {
            return
        }
        let urls = components.queryItems?
            .filter { $0.name == "path" }
            .compactMap(\.value)
            .map { URL(fileURLWithPath: $0) } ?? []
        performContextMenuAction(itemID: itemID, rawAction: rawAction, urls: urls)
    }

    private func performContextMenuAction(itemID: ContextMenuItemID, rawAction: String, urls: [URL]) {
        if itemID == .compressCustom {
            showCompressionOptions(urls: urls)
            return
        }

        let archivePasswords: [String: String]
        do {
            guard let passwords = try passwordsIfRequired(itemID: itemID, urls: urls) else {
                return
            }
            archivePasswords = passwords
        } catch {
            showArchivePasswordError(error)
            return
        }

        if itemID.isArchiveAction {
            showArchiveProgress(title: itemID.title, detail: "准备处理 \(max(urls.count, 1)) 项")
        }
        let resultURL = archiveResultLocation(itemID: itemID, urls: urls)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let executor = ContextMenuActionExecutor(progressHandler: { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.updateArchiveProgress(progress)
                    }
                }, archivePasswords: archivePasswords)
                try executor.perform(itemID: itemID, urls: urls)
                AppLogger.shared.info("右键菜单动作执行成功：\(rawAction)")
                DispatchQueue.main.async {
                    MacAssistantNotifier.notify(title: "\(itemID.title)完成", message: self.archiveSuccessMessage(itemID: itemID, count: urls.count, resultURL: resultURL))
                }
                if itemID.isArchiveAction {
                    DispatchQueue.main.async { [weak self] in
                        self?.showArchiveSuccess(itemID: itemID, count: urls.count, resultURL: resultURL)
                    }
                }
            } catch {
                AppLogger.shared.error("右键菜单动作执行失败：\(rawAction)：\(error.localizedDescription)")
                DispatchQueue.main.async {
                    MacAssistantNotifier.notify(title: "\(itemID.title)失败", message: error.localizedDescription)
                }
                if itemID.isArchiveAction {
                    DispatchQueue.main.async { [weak self] in
                        self?.showArchiveError(error)
                    }
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    private func showCompressionOptions(urls: [URL]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.setActivationPolicy(.regular)
            let controller = ArchiveCompressionOptionsWindowController(
                urls: urls,
                config: self.store.archive,
                completion: { [weak self] options in
                    self?.compressionOptionsWindowController = nil
                    self?.performCustomCompression(urls: urls, options: options)
                },
                onCancel: { [weak self] in
                    self?.compressionOptionsWindowController = nil
                    NSApp.setActivationPolicy(.accessory)
                }
            )
            self.compressionOptionsWindowController = controller
            controller.show()
        }
    }

    private func performCustomCompression(urls: [URL], options: ArchiveCompressionOptions) {
        showArchiveProgress(title: "压缩", detail: "准备处理 \(max(urls.count, 1)) 项")
        let resultURL = urls.first?.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let executor = ArchiveActionExecutor { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.updateArchiveProgress(progress)
                    }
                }
                try executor.compress(urls: urls, options: options)
                DispatchQueue.main.async { [weak self] in
                    self?.showArchiveSuccess(title: "压缩", count: urls.count, resultURL: resultURL)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showArchiveError(error)
                }
            }
        }
    }

    private func showArchiveProgress(title: String, detail: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.setActivationPolicy(.regular)
            let controller = self.progressWindowController ?? ContextMenuProgressWindowController()
            self.progressWindowController = controller
            controller.showRunning(title: title, detail: detail)
        }
    }

    private func updateArchiveProgress(_ progress: ArchiveActionExecutor.Progress) {
        let detail = progress.total > 1
            ? "\(progress.message)（\(progress.current)/\(progress.total)）"
            : progress.message
        progressWindowController?.update(detail: detail)
    }

    private func showArchiveSuccess(itemID: ContextMenuItemID, count: Int, resultURL: URL?) {
        progressWindowController?.showSuccess(
            detail: "\(itemID.title) 已完成，共处理 \(max(count, 1)) 项",
            resultURL: resultURL,
            autoClose: itemID.isExtractionAction ? store.archive.autoCloseProgressWindowAfterExtraction : nil
        )
    }

    private func archiveSuccessMessage(itemID: ContextMenuItemID, count: Int, resultURL: URL?) -> String {
        let location = resultURL.map { "，位置：\($0.path)" } ?? ""
        return "共处理 \(max(count, 1)) 项\(location)"
    }

    private func showArchiveSuccess(title: String, count: Int, resultURL: URL?) {
        progressWindowController?.showSuccess(
            detail: "\(title) 已完成，共处理 \(max(count, 1)) 项",
            resultURL: resultURL
        )
    }

    private func showArchiveError(_ error: Error) {
        progressWindowController?.showError(detail: error.localizedDescription)
    }

    private func archiveResultLocation(itemID: ContextMenuItemID, urls: [URL]) -> URL? {
        guard itemID.isArchiveAction else {
            return nil
        }
        switch itemID {
        case .smartExtract, .smartExtractAndDelete, .extractHere, .extractToArchiveName, .extractToArchiveNameAndDelete,
             .compressZip, .compressTar, .compressTarGzip, .compressTarBzip2,
             .compressTarXz, .compressGzip, .compressBzip2, .compressXz,
             .compressSevenZip, .compressRar:
            return urls.first?.deletingLastPathComponent()
        case .compressCustom:
            return urls.first?.deletingLastPathComponent()
        case .createFolder, .copyPath, .open, .openWithIDEA, .openWithTypora,
             .openWithVSCode, .openInTerminal, .openInWarp, .newFile, .newTextFile, .newMarkdownFile,
             .newJSONFile, .newHTMLFile, .newWordFile, .newExcelFile,
             .newPowerPointFile, .archive:
            return nil
        }
    }

    private func passwordsIfRequired(itemID: ContextMenuItemID, urls: [URL]) throws -> [String: String]? {
        guard itemID.requiresArchivePasswordPreflight else {
            return [:]
        }

        var passwords: [String: String] = [:]
        for url in urls {
            switch try passwordPreflight(for: url) {
            case .notRequired:
                continue
            case .provided(let password):
                passwords[url.standardizedFileURL.path] = password
            case .cancelled:
                return nil
            }
        }
        return passwords
    }

    private func passwordPreflight(for url: URL) throws -> ArchivePasswordPreflightResult {
        let service = try ArchiveBrowserService(archiveURL: url)
        guard try service.requiresPassword() else {
            return .notRequired
        }
        guard let password = try ArchivePasswordPrompt.requestPassword(for: url, validator: { password in
            try service.validatePassword(password)
        }) else {
            return .cancelled
        }
        return .provided(password)
    }

    private func showArchivePasswordError(_ error: Error) {
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "无法处理压缩包"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func terminateSecondaryInstanceSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.terminate(nil)
        }
    }
}

private enum ArchivePasswordPreflightResult {
    case notRequired
    case provided(String)
    case cancelled
}

private extension ContextMenuItemID {
    var isExtractionAction: Bool {
        switch self {
        case .smartExtract, .smartExtractAndDelete, .extractHere, .extractToArchiveName, .extractToArchiveNameAndDelete:
            return true
        default:
            return false
        }
    }

    var requiresArchivePasswordPreflight: Bool {
        switch self {
        case .smartExtract, .smartExtractAndDelete, .extractHere, .extractToArchiveName, .extractToArchiveNameAndDelete:
            return true
        case .createFolder, .copyPath, .open, .openWithIDEA, .openWithTypora, .openWithVSCode, .openInTerminal, .openInWarp, .newFile, .newTextFile, .newMarkdownFile, .newJSONFile, .newHTMLFile, .newWordFile, .newExcelFile, .newPowerPointFile, .archive, .compressCustom, .compressZip, .compressTar, .compressTarGzip, .compressTarBzip2, .compressTarXz, .compressGzip, .compressBzip2, .compressXz, .compressSevenZip, .compressRar:
            return false
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        archiveWindows.removeAll { $0.window === notification.object as? NSWindow }
    }
}

private let singleInstanceLock: SingleInstanceLock?
do {
    if let acquiredLock = try SingleInstanceLock.acquire() {
        singleInstanceLock = acquiredLock
        AppRuntime.isSecondaryInstance = false
    } else {
        singleInstanceLock = nil
        AppRuntime.isSecondaryInstance = true
    }
} catch {
    singleInstanceLock = nil
    AppRuntime.isSecondaryInstance = false
    fputs("无法创建单实例锁：\(error.localizedDescription)\n", stderr)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
