import AppKit
import ApplicationServices
import Foundation
import ImageIO

enum ClipboardPasteMode {
    case formatted
    case plainText
}

final class ClipboardHistoryController {
    private static let knownPasswordManagerBundleIdentifiers: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.dashlane.dashlanephonefinal",
        "io.enpass.Enpass",
        "com.lastpass.LastPass",
        "com.nordsec.nordpass",
        "com.roboform.mac"
    ]

    private let store: ProfileStore
    private let historyStore: ClipboardHistoryStore
    private let processingQueue = DispatchQueue(label: "com.fusheng.mac-tool.clipboard.processing", qos: .utility)
    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int
    private var isWritingForPaste = false
    private var hasLoadedHistory = false
    private(set) var isLoadingHistory = false
    private var historyLoadCompletions: [() -> Void] = []
    private var hotKeyManager: GlobalHotKeyManager?
    private var targetApplication: NSRunningApplication?
    private var windowController: ClipboardHistoryWindowController?

    private(set) var history: [ClipboardHistoryItem] = [] {
        didSet {
            windowController?.reload()
        }
    }

    var configuration: ClipboardConfig {
        store.clipboard
    }

    private struct CapturedPasteboardItem {
        let sourceApplicationName: String
        let sourceBundleIdentifier: String
        let plainText: String
        let storedTypes: [ClipboardStoredType]
    }

    init(store: ProfileStore) {
        self.store = store
        self.historyStore = ClipboardHistoryStore()
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard store.clipboard.enabled else {
            hotKeyManager?.unregister()
            return
        }
        configureHotKey()
        loadHistoryIfNeeded { [weak self] in
            guard let self, self.store.clipboard.enabled else { return }
            self.pruneExpiredHistory()
            self.scheduleClipboardTimer()
        }
    }

    private func scheduleClipboardTimer() {
        timer?.invalidate()
        let interval = TimeInterval(ClipboardConfig.normalizedPollIntervalMilliseconds(store.clipboard.pollIntervalMilliseconds)) / 1000
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hotKeyManager?.unregister()
    }

    func updateConfiguration() {
        hotKeyManager?.unregister()
        timer?.invalidate()
        timer = nil
        guard store.clipboard.enabled else {
            return
        }
        configureHotKey()
        loadHistoryIfNeeded { [weak self] in
            guard let self, self.store.clipboard.enabled else { return }
            self.pruneExpiredHistory()
            self.trimHistoryToConfiguredLimit()
            self.scheduleClipboardTimer()
        }
    }

    func showHistoryPanel() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = app
        }
        if windowController == nil {
            windowController = ClipboardHistoryWindowController(controller: self)
        }
        windowController?.showPanel()
        loadHistoryIfNeeded { [weak self] in
            self?.windowController?.reload()
        }
    }

    func paste(_ item: ClipboardHistoryItem, mode: ClipboardPasteMode) {
        isWritingForPaste = true
        pasteboard.clearContents()
        switch mode {
        case .formatted:
            let pasteboardItem = NSPasteboardItem()
            for storedType in storedTypes(for: item) {
                pasteboardItem.setData(storedType.data, forType: NSPasteboard.PasteboardType(storedType.type))
            }
            pasteboard.writeObjects([pasteboardItem])
        case .plainText:
            pasteboard.setString(item.plainText, forType: .string)
        }
        lastChangeCount = pasteboard.changeCount

        windowController?.hideIfNeededAfterPaste()
        let app = targetApplication
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            app?.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.sendPasteShortcut()
                self.isWritingForPaste = false
            }
        }
    }

    func copyBackToPasteboard(_ item: ClipboardHistoryItem, mode: ClipboardPasteMode) {
        isWritingForPaste = true
        pasteboard.clearContents()
        if mode == .plainText {
            pasteboard.setString(item.plainText, forType: .string)
        } else {
            let pasteboardItem = NSPasteboardItem()
            for storedType in storedTypes(for: item) {
                pasteboardItem.setData(storedType.data, forType: NSPasteboard.PasteboardType(storedType.type))
            }
            pasteboard.writeObjects([pasteboardItem])
        }
        lastChangeCount = pasteboard.changeCount
        isWritingForPaste = false
    }

    func delete(_ item: ClipboardHistoryItem) {
        updateHistoryFromStore { try $0.delete(item.id) }
    }

    func toggleFavorite(_ item: ClipboardHistoryItem) {
        updateHistoryFromStore { try $0.toggleFavorite(item.id) }
    }

    func clearUnfavorited() {
        updateHistoryFromStore { try $0.clearUnfavorited() }
    }

    func clearAll() {
        updateHistoryFromStore { try $0.clearAll() }
    }

    func clearItems(kind: ClipboardContentKind) {
        updateHistoryFromStore { try $0.clearItems(kind: kind) }
    }

    func countItems(kind: ClipboardContentKind) -> Int {
        (try? historyStore.countItems(kind: kind)) ?? history.filter { contentKind(for: $0) == kind && !$0.isFavorite }.count
    }

    func searchHistory(
        _ query: String,
        applicationKey: String? = nil,
        favoritesOnly: Bool = false,
        limit: Int? = nil
    ) -> [ClipboardHistoryItem] {
        let resolvedLimit = limit ?? store.clipboard.maxHistoryCount
        do {
            return try historyStore.search(
                query,
                filter: ClipboardHistorySearchFilter(applicationKey: applicationKey, favoritesOnly: favoritesOnly),
                limit: resolvedLimit
            )
        } catch {
            AppLogger.shared.error("剪切板搜索失败：\(error.localizedDescription)")
            return []
        }
    }

    func storedTypes(for item: ClipboardHistoryItem) -> [ClipboardStoredType] {
        do {
            let storedTypes = try historyStore.loadStoredTypes(itemID: item.id)
            return storedTypes.isEmpty ? item.storedTypes : storedTypes
        } catch {
            AppLogger.shared.error("剪切板内容读取失败：\(error.localizedDescription)")
            return item.storedTypes
        }
    }

    func thumbnailURL(for item: ClipboardHistoryItem) -> URL? {
        historyStore.thumbnailURL(for: item)
    }

    func ensureThumbnail(for item: ClipboardHistoryItem, completion: @escaping (UUID, URL?) -> Void) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            let url: URL?
            do {
                url = try self.historyStore.ensureThumbnail(for: item.id)
            } catch {
                AppLogger.shared.error("剪切板缩略图生成失败：\(error.localizedDescription)")
                url = nil
            }
            DispatchQueue.main.async {
                completion(item.id, url)
            }
        }
    }

    private func trimHistoryToConfiguredLimit() {
        reloadHistoryFromStore()
    }

    private func pruneExpiredHistory() {
        reloadHistoryFromStore()
    }

    private func configureHotKey() {
        guard store.clipboard.hotKeyEnabled else {
            hotKeyManager?.unregister()
            return
        }
        if hotKeyManager == nil {
            hotKeyManager = GlobalHotKeyManager { [weak self] in
                self?.showHistoryPanel()
            }
        }
        hotKeyManager?.register(store.clipboard.hotKey)
    }

    private func pollPasteboard() {
        guard store.clipboard.enabled, pasteboard.changeCount != lastChangeCount else { return }
        guard hasLoadedHistory else {
            loadHistoryIfNeeded()
            return
        }
        lastChangeCount = pasteboard.changeCount
        guard !isWritingForPaste else { return }
        guard !store.clipboard.recordingPaused else { return }
        let sourceApp = NSWorkspace.shared.frontmostApplication
        guard shouldRecordClipboard(from: sourceApp),
              let capturedItem = capturePasteboardItem(sourceApp: sourceApp) else { return }

        let maxHistoryCount = store.clipboard.maxHistoryCount
        let retentionDays = store.clipboard.retentionDays

        processingQueue.async { [weak self] in
            guard let self,
                  let item = self.makeHistoryItem(from: capturedItem) else { return }
            let updatedHistory: [ClipboardHistoryItem]
            do {
                updatedHistory = try self.historyStore.insert(item, maxHistoryCount: maxHistoryCount, retentionDays: retentionDays)
            } catch {
                AppLogger.shared.error("剪切板历史写入失败：\(error.localizedDescription)")
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.history = updatedHistory
            }
        }
    }

    private func shouldRecordClipboard(from app: NSRunningApplication?) -> Bool {
        guard let bundleIdentifier = app?.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return true
        }
        let excluded = Set(store.clipboard.excludedBundleIdentifiers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        if excluded.contains(bundleIdentifier.lowercased()) {
            return false
        }
        if store.clipboard.excludeKnownPasswordManagers,
           Self.knownPasswordManagerBundleIdentifiers.contains(bundleIdentifier.lowercased()) {
            return false
        }
        return true
    }

    private func capturePasteboardItem(sourceApp: NSRunningApplication?) -> CapturedPasteboardItem? {
        guard let pasteboardItem = pasteboard.pasteboardItems?.first else { return nil }
        let storedTypes = pasteboardItem.types.compactMap { type -> ClipboardStoredType? in
            guard let data = pasteboardItem.data(forType: type), data.count <= 2_000_000 else { return nil }
            return ClipboardStoredType(type: type.rawValue, data: data)
        }
        guard !storedTypes.isEmpty else { return nil }

        let plainText = pasteboardItem.string(forType: .string) ?? ""
        return CapturedPasteboardItem(
            sourceApplicationName: sourceApp?.localizedName ?? "未知应用",
            sourceBundleIdentifier: sourceApp?.bundleIdentifier ?? "",
            plainText: plainText,
            storedTypes: storedTypes
        )
    }

    private func makeHistoryItem(from capturedItem: CapturedPasteboardItem) -> ClipboardHistoryItem? {
        let metadata = makeMetadata(plainText: capturedItem.plainText, storedTypes: capturedItem.storedTypes)
        let preview = previewText(
            plainText: capturedItem.plainText,
            types: capturedItem.storedTypes.map(\.type),
            metadata: metadata
        )
        guard !preview.isEmpty else { return nil }

        return ClipboardHistoryItem(
            sourceApplicationName: capturedItem.sourceApplicationName,
            sourceBundleIdentifier: capturedItem.sourceBundleIdentifier,
            plainText: capturedItem.plainText,
            previewText: preview,
            storedTypes: capturedItem.storedTypes,
            metadata: metadata
        )
    }

    private func contentKind(for item: ClipboardHistoryItem) -> ClipboardContentKind {
        switch item.metadata.contentType {
        case "图片":
            return .image
        case "文件":
            return .file
        case "富文本":
            return .richText
        default:
            return .text
        }
    }

    private func previewText(plainText: String, types: [String], metadata: ClipboardContentMetadata) -> String {
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(220))
        }
        if !metadata.fileNames.isEmpty {
            return metadata.fileNames.prefix(3).joined(separator: ", ")
        }
        if types.contains(where: { $0.contains("image") || $0.contains("tiff") || $0.contains("png") }) {
            return "图片"
        }
        if types.contains(where: { $0.contains("file-url") || $0.contains("filename") }) {
            return "文件"
        }
        return ""
    }

    private func makeMetadata(
        plainText: String,
        storedTypes: [ClipboardStoredType]
    ) -> ClipboardContentMetadata {
        let typeNames = storedTypes.map(\.type)
        let lowercasedTypes = typeNames.map { $0.lowercased() }
        let fileURLs = extractFileURLs(from: storedTypes, plainText: plainText)
        let imageSize = imagePixelSize(from: storedTypes)
        let hasImage = imageSize != nil || lowercasedTypes.contains {
            $0.contains("image") || $0.contains("png") || $0.contains("tiff") || $0.contains("jpeg") || $0.contains("jpg") || $0.contains("heic")
        }
        let hasRichText = lowercasedTypes.contains { type in
            type.contains("rtf") || type.contains("html") || type.contains("webarchive")
        }
        let hasFiles = !fileURLs.isEmpty || lowercasedTypes.contains { $0.contains("file-url") || $0.contains("filename") }

        let contentType: String
        if hasFiles {
            contentType = "文件"
        } else if hasImage {
            contentType = "图片"
        } else if hasRichText {
            contentType = "富文本"
        } else {
            contentType = "文本"
        }

        let fileNames = fileURLs.map { $0.lastPathComponent }.filter { !$0.isEmpty }
        let sourcePaths = fileURLs.map(\.path).filter { !$0.isEmpty }
        let detailText = metadataDetail(
            contentType: contentType,
            fileNames: fileNames,
            sourcePaths: sourcePaths,
            imageSize: imageSize,
            typeNames: typeNames
        )

        return ClipboardContentMetadata(
            contentType: contentType,
            detailText: detailText,
            sourcePaths: sourcePaths,
            fileNames: fileNames,
            pasteboardTypes: typeNames,
            imagePixelWidth: imageSize?.width,
            imagePixelHeight: imageSize?.height,
            thumbnailFileName: nil,
            contentByteCount: storedTypes.reduce(0) { $0 + $1.data.count }
        )
    }

    private func metadataDetail(
        contentType: String,
        fileNames: [String],
        sourcePaths: [String],
        imageSize: (width: Int, height: Int)?,
        typeNames: [String]
    ) -> String {
        var parts: [String] = [contentType]
        if let imageSize {
            parts.append("\(imageSize.width)x\(imageSize.height)")
        }
        if !fileNames.isEmpty {
            let countText = fileNames.count == 1 ? fileNames[0] : "\(fileNames.count) 个文件"
            parts.append(countText)
        }
        if let firstPath = sourcePaths.first {
            parts.append(firstPath)
        } else if let firstType = typeNames.first {
            parts.append(friendlyPasteboardType(firstType))
        }
        return parts.joined(separator: " · ")
    }

    private func friendlyPasteboardType(_ type: String) -> String {
        switch type {
        case NSPasteboard.PasteboardType.string.rawValue:
            return "纯文本"
        case NSPasteboard.PasteboardType.rtf.rawValue:
            return "RTF"
        case NSPasteboard.PasteboardType.html.rawValue:
            return "HTML"
        case NSPasteboard.PasteboardType.png.rawValue:
            return "PNG"
        case NSPasteboard.PasteboardType.tiff.rawValue:
            return "TIFF"
        case NSPasteboard.PasteboardType.fileURL.rawValue:
            return "文件 URL"
        default:
            return type
        }
    }

    private func extractFileURLs(from storedTypes: [ClipboardStoredType], plainText: String) -> [URL] {
        var urls: [URL] = []
        let candidateTypes = storedTypes.filter { storedType in
            let rawValue = storedType.type.lowercased()
            return rawValue.contains("file-url") || rawValue.contains("filename")
        }

        for storedType in candidateTypes {
            if let string = String(data: storedType.data, encoding: .utf8),
               let url = fileURL(from: string) {
                urls.append(url)
            } else if let fileURLs = fileURLs(from: storedType.data),
                      !fileURLs.isEmpty {
                urls.append(contentsOf: fileURLs)
            }
        }

        for line in plainText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = fileURL(from: trimmed) {
                urls.append(url)
            }
        }

        var seen = Set<String>()
        return urls.filter { url in
            let key = url.path
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func fileURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.isFileURL {
            return url
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return nil
    }

    private func fileURLs(from data: Data) -> [URL]? {
        if let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let paths = propertyList as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return nil
    }

    private func imagePixelSize(from storedTypes: [ClipboardStoredType]) -> (width: Int, height: Int)? {
        for storedType in storedTypes where storedType.type.lowercased().contains("image")
            || storedType.type == NSPasteboard.PasteboardType.png.rawValue
            || storedType.type == NSPasteboard.PasteboardType.tiff.rawValue
            || storedType.type.lowercased().contains("jpeg")
            || storedType.type.lowercased().contains("jpg")
            || storedType.type.lowercased().contains("heic") {
            guard let source = CGImageSourceCreateWithData(storedType.data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                continue
            }
            if let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
               let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                return (width.intValue, height.intValue)
            }
        }
        return nil
    }

    private func sendPasteShortcut() {
        guard AXIsProcessTrusted() else {
            showAccessibilityAlert()
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func showAccessibilityAlert() {
        Task { @MainActor in
            let previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            PermissionGuideFlow.shared.authorize(.accessibility)

            if previousPolicy == .accessory {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    private func loadHistoryIfNeeded(completion: (() -> Void)? = nil) {
        if hasLoadedHistory {
            completion?()
            return
        }
        if let completion {
            historyLoadCompletions.append(completion)
        }
        guard !isLoadingHistory else { return }

        isLoadingHistory = true
        windowController?.reload()
        let retentionDays = store.clipboard.retentionDays
        let maxHistoryCount = store.clipboard.maxHistoryCount
        processingQueue.async { [weak self] in
            guard let self else { return }
            let loaded: [ClipboardHistoryItem]
            do {
                loaded = try self.historyStore.loadHistory(maxHistoryCount: maxHistoryCount, retentionDays: retentionDays)
            } catch {
                AppLogger.shared.error("剪切板历史加载失败：\(error.localizedDescription)")
                loaded = []
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLoadingHistory = false
                self.hasLoadedHistory = true
                self.history = loaded
                let completions = self.historyLoadCompletions
                self.historyLoadCompletions.removeAll()
                completions.forEach { $0() }
            }
        }
    }

    private func updateHistoryFromStore(_ operation: @escaping (ClipboardHistoryStore) throws -> [ClipboardHistoryItem]) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            let updatedHistory: [ClipboardHistoryItem]
            do {
                updatedHistory = try operation(self.historyStore)
            } catch {
                AppLogger.shared.error("剪切板历史更新失败：\(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.history = updatedHistory
            }
        }
    }

    private func reloadHistoryFromStore() {
        let maxHistoryCount = store.clipboard.maxHistoryCount
        let retentionDays = store.clipboard.retentionDays
        processingQueue.async { [weak self] in
            guard let self else { return }
            let loaded: [ClipboardHistoryItem]
            do {
                loaded = try self.historyStore.loadHistory(maxHistoryCount: maxHistoryCount, retentionDays: retentionDays)
            } catch {
                AppLogger.shared.error("剪切板历史刷新失败：\(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.history = loaded
            }
        }
    }
}
