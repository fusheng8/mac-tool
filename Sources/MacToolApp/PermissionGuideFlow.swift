import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum PermissionGuidePane {
    case accessibility
    case automation
    case finderExtension
    case fullDiskAccess

    var title: String {
        switch self {
        case .accessibility:
            return "辅助功能"
        case .automation:
            return "自动化"
        case .finderExtension:
            return "Finder 扩展"
        case .fullDiskAccess:
            return "完全磁盘访问"
        }
    }

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        case .automation:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation")
        case .finderExtension:
            return URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")
        case .fullDiskAccess:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
        }
    }

    var supportsDragAuthorization: Bool {
        switch self {
        case .accessibility, .fullDiskAccess:
            return true
        case .automation, .finderExtension:
            return false
        }
    }

    var instruction: String {
        switch self {
        case .accessibility:
            return "把下方 Mac助手 拖到系统设置的应用列表中，并打开开关。"
        case .fullDiskAccess:
            return "把下方 Mac助手 拖到系统设置的应用列表中，并打开开关。"
        case .automation:
            return "在系统设置中查看已出现的自动化授权项；新的目标应用会在首次执行动作时由 macOS 弹窗确认。"
        case .finderExtension:
            return "在 Finder 扩展列表中启用 Mac助手 扩展，然后重启 Finder 或重新打开 Finder 窗口。"
        }
    }

    var symbolName: String {
        switch self {
        case .accessibility:
            return "accessibility"
        case .automation:
            return "gearshape.2"
        case .finderExtension:
            return "folder"
        case .fullDiskAccess:
            return "externaldrive"
        }
    }

    var authorizationGranted: Bool? {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted()
        case .automation, .finderExtension, .fullDiskAccess:
            return nil
        }
    }
}

@MainActor
final class PermissionGuideFlow {
    static let shared = PermissionGuideFlow()

    private var panel: NSPanel?
    private var completionTimer: Timer?
    private var activePane: PermissionGuidePane?

    private init() {}

    func authorize(_ pane: PermissionGuidePane, sourceView: NSView? = nil) {
        NSLog("%@", "权限引导 authorize 入口：\(pane.title)")
        let sourceFrame = sourceView?.screenFrame
        DispatchQueue.main.async { [weak self] in
            NSLog("%@", "权限引导 begin 调度执行：\(pane.title)")
            self?.beginAuthorization(pane, sourceFrame: sourceFrame)
        }
    }

    private func beginAuthorization(_ pane: PermissionGuidePane, sourceFrame: CGRect?) {
        NSLog("%@", "权限引导 begin 开始：\(pane.title)")
        AppLogger.shared.info("权限引导开始：\(pane.title)")
        closePanel()
        activePane = pane

        if pane.supportsDragAuthorization, pane.authorizationGranted != true {
            NSLog("%@", "权限引导准备显示浮窗：\(pane.title)")
            showPanel(for: pane, sourceFrame: sourceFrame)
            startCompletionMonitoring(for: pane)
        }

        if let url = pane.settingsURL {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                AppLogger.shared.info("打开系统设置权限页：\(pane.title)")
                NSWorkspace.shared.open(url)
            }
        }
    }

    func closePanel() {
        completionTimer?.invalidate()
        completionTimer = nil
        panel?.close()
        panel = nil
        activePane = nil
    }

    private func startCompletionMonitoring(for pane: PermissionGuidePane) {
        guard pane.authorizationGranted != nil else { return }
        completionTimer?.invalidate()
        completionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAuthorizationCompletion()
            }
        }
        RunLoop.main.add(completionTimer!, forMode: .common)
        checkAuthorizationCompletion()
    }

    private func checkAuthorizationCompletion() {
        guard let activePane,
              activePane.authorizationGranted == true else {
            return
        }
        completeAuthorization(for: activePane)
    }

    private func completeAuthorization(for pane: PermissionGuidePane) {
        AppLogger.shared.info("权限引导完成：\(pane.title)")
        closePanel()
        NotificationCenter.default.post(name: .permissionGuideDidComplete, object: pane)
    }

    private func showPanel(for pane: PermissionGuidePane, sourceFrame: CGRect?) {
        NSLog("%@", "权限引导 showPanel 开始：\(pane.title)")
        let appURL = Self.authorizedAppURL()
        NSLog("%@", "权限引导 appURL：\(appURL.path)")
        let content = PermissionGuidePanelView(pane: pane, appURL: appURL)
        NSLog("%@", "权限引导 content 创建完成：\(pane.title)")
        let size = NSSize(width: 318, height: 184)
        let fallbackFrame = Self.fallbackPanelFrame(size: size)
        let startFrame = sourceFrame.map { frame in
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        } ?? fallbackFrame
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: startFrame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.title = "授权 \(pane.title)"
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = MacAssistantUI.Color.window
        panel.isOpaque = true
        self.panel = panel
        panel.contentView = content
        panel.setFrame(startFrame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("%@", "权限引导 showPanel 完成：\(pane.title)")
        AppLogger.shared.info("权限引导浮窗已显示：\(pane.title)")
    }

    private static func authorizedAppURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        if let executableURL = Bundle.main.executableURL {
            return executableURL
        }
        if let launchPath = CommandLine.arguments.first, !launchPath.isEmpty {
            return URL(fileURLWithPath: launchPath)
        }
        return bundleURL
    }

    private static func fallbackPanelFrame(size: NSSize) -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? desktopFrame()
        return NSRect(
            x: visibleFrame.maxX - size.width - 28,
            y: visibleFrame.maxY - size.height - 58,
            width: size.width,
            height: size.height
        )
    }

    private static func desktopFrame() -> CGRect {
        NSScreen.screens.reduce(CGRect.null) { result, screen in
            result.union(screen.frame)
        }
    }
}

private final class PermissionGuidePanelView: NSView {
    init(pane: PermissionGuidePane, appURL: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = MacAssistantUI.Color.card.cgColor
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderColor = MacAssistantUI.Color.hairline.cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        let iconWrap = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.blue.withAlphaComponent(0.12),
            cornerRadius: 10
        )
        iconWrap.widthAnchor.constraint(equalToConstant: 38).isActive = true
        iconWrap.heightAnchor.constraint(equalToConstant: 38).isActive = true

        let icon = NSImageView()
        icon.image = MacAssistantUI.symbol(pane.symbolName, pointSize: 18, weight: .semibold)
        icon.contentTintColor = MacAssistantUI.Color.blue
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.addSubview(icon)

        let title = MacAssistantUI.title("授权 \(pane.title)", size: 14, weight: .bold)
        let detail = MacAssistantUI.caption(pane.instruction, size: 12)
        detail.maximumNumberOfLines = 2

        let titleStack = NSStackView(views: [title, detail])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let appDragView = PermissionAppDragView(appURL: appURL)

        let closeButton = MacIconButton(symbolName: "xmark")
        closeButton.style = .subtle
        closeButton.target = self
        closeButton.action = #selector(closePanel)

        addSubview(iconWrap)
        addSubview(titleStack)
        addSubview(appDragView)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconWrap.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            iconWrap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconWrap.topAnchor.constraint(equalTo: topAnchor, constant: 18),

            titleStack.leadingAnchor.constraint(equalTo: iconWrap.trailingAnchor, constant: 12),
            titleStack.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            titleStack.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),

            appDragView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            appDragView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            appDragView.topAnchor.constraint(equalTo: iconWrap.bottomAnchor, constant: 18),
            appDragView.heightAnchor.constraint(equalToConstant: 82)
        ])
    }

    @objc private func closePanel() {
        PermissionGuideFlow.shared.closePanel()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }
}

private final class PermissionAppDragView: NSView, NSDraggingSource {
    private let appURL: URL
    private let appIconTile = LayerBackedView(
        backgroundColor: MacAssistantUI.Color.blue,
        cornerRadius: 10
    )
    private let appIconImageView = NSImageView()

    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.74).cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderColor = MacAssistantUI.Color.hairline.cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        appIconTile.widthAnchor.constraint(equalToConstant: 46).isActive = true
        appIconTile.heightAnchor.constraint(equalToConstant: 46).isActive = true

        appIconImageView.image = Self.safeAppIcon()
        appIconImageView.contentTintColor = .white
        appIconImageView.imageScaling = .scaleProportionallyUpOrDown
        appIconImageView.translatesAutoresizingMaskIntoConstraints = false
        appIconTile.addSubview(appIconImageView)

        let title = MacAssistantUI.title(Self.appDisplayName(appURL: appURL), size: 13, weight: .semibold)
        let subtitle = MacAssistantUI.caption("拖到右侧系统设置列表", size: 12)

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        let dragIcon = NSImageView()
        dragIcon.image = MacAssistantUI.symbol("arrow.up.left.and.arrow.down.right", pointSize: 14, weight: .semibold)
        dragIcon.contentTintColor = MacAssistantUI.Color.blue
        dragIcon.translatesAutoresizingMaskIntoConstraints = false

        addSubview(appIconTile)
        addSubview(stack)
        addSubview(dragIcon)

        NSLayoutConstraint.activate([
            appIconImageView.centerXAnchor.constraint(equalTo: appIconTile.centerXAnchor),
            appIconImageView.centerYAnchor.constraint(equalTo: appIconTile.centerYAnchor),
            appIconImageView.widthAnchor.constraint(equalToConstant: 26),
            appIconImageView.heightAnchor.constraint(equalToConstant: 26),

            appIconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            appIconTile.centerYAnchor.constraint(equalTo: centerYAnchor),

            stack.leadingAnchor.constraint(equalTo: appIconTile.trailingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: dragIcon.leadingAnchor, constant: -12),

            dragIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            dragIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            dragIcon.widthAnchor.constraint(equalToConstant: 18),
            dragIcon.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    override func mouseDown(with event: NSEvent) {
    }

    override func mouseDragged(with event: NSEvent) {
        startDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        return true
    }

    private func startDrag(with event: NSEvent) {
        let draggingItem = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        let dragFrame = convert(appIconTile.bounds, from: appIconTile)
        draggingItem.setDraggingFrame(dragFrame, contents: appIconImageView.image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private static func safeAppIcon() -> NSImage? {
        let image = Bundle.main.image(forResource: "StatusIconRingGray")
            ?? MacAssistantUI.symbol("sparkles", pointSize: 24, weight: .semibold)
        image?.isTemplate = false
        return image
    }

    private static func appDisplayName(appURL: URL) -> String {
        if appURL.pathExtension == "app" {
            return appURL.deletingPathExtension().lastPathComponent
        }
        return "Mac助手"
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }
}

private extension NSView {
    var screenFrame: CGRect? {
        guard let window else { return nil }
        let frameInWindow = convert(bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}

private extension CGPoint {
    func distance(to point: CGPoint) -> CGFloat {
        hypot(x - point.x, y - point.y)
    }
}

extension Notification.Name {
    static let permissionGuideDidComplete = Notification.Name("com.fusheng.mac-tool.permissionGuideDidComplete")
}
