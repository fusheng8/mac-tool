import AppKit

final class OnboardingWindowController: NSWindowController {
    private struct Page {
        let symbol: String
        let title: String
        let detail: String
    }

    private let store: ProfileStore
    private let completion: () -> Void
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let optionTitle = NSTextField(labelWithString: "")
    private let optionDetail = NSTextField(wrappingLabelWithString: "")
    private let optionSwitch = MacSwitchControl()
    private let backButton = MacTextButton(title: "上一步")
    private let nextButton = MacTextButton(title: "继续", symbolName: "arrow.right", role: .primary)
    private var pageIndex = 0
    private var clipboardEnabled = true
    private var displayAutomationApproved = false

    private lazy var pages: [Page] = {
        if store.isExistingInstallation {
            return [
                Page(
                    symbol: "lock.shield",
                    title: "隐私与安全升级",
                    detail: "0.2.0 会把现有剪贴板历史迁移到本机 AES-256-GCM 加密存储。迁移校验完成前，原数据库会保留且不会开始新记录。"
                ),
                Page(
                    symbol: "doc.on.clipboard",
                    title: "剪贴板由你控制",
                    detail: "内容只保存在这台 Mac，密钥位于钥匙串且不可同步。默认保留 30 天；密码管理器和带敏感标记的内容会自动跳过。"
                ),
                Page(
                    symbol: "display.2",
                    title: "重新确认显示器自动化",
                    detail: "升级后不会自动断开任何显示器。只有你在这里明确允许，并且配置同时启用时，后台软断开才会运行。"
                ),
                Page(
                    symbol: "checkmark.shield",
                    title: "升级准备完成",
                    detail: "Finder 动作已加入签名与时效校验；日志和诊断仍只保存在本机。你可以随时在设置中修改这些选项。"
                )
            ]
        }
        return [
            Page(symbol: "macbook.and.iphone", title: "欢迎使用 Mac助手", detail: "这是一个本地优先的 macOS 工具箱。配置、日志、诊断和剪贴板数据都保存在这台 Mac，不接入第三方遥测。"),
            Page(symbol: "doc.on.clipboard", title: "剪贴板历史", detail: "默认开启并保留 30 天，使用钥匙串中的本机专用密钥加密。完成此说明前，应用不会读取或记录剪贴板。"),
            Page(symbol: "finder", title: "Finder 扩展", detail: "Finder 右键动作通过带签名、30 秒有效期的请求交给主应用。带删除的动作始终需要二次确认。"),
            Page(symbol: "display.2", title: "显示器安全", detail: "新安装没有预置显示器，也不会自动软断开。启用后仍会保护最后一块可用屏幕，并在失败时暂停重试。"),
            Page(symbol: "checkmark.shield", title: "准备就绪", detail: "需要的系统权限会在首次使用对应功能时单独说明。现在可以开始使用 Mac助手。")
        ]
    }()

    init(store: ProfileStore, completion: @escaping () -> Void) {
        self.store = store
        self.completion = completion
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac助手"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
        renderPage()
    }

    required init?(coder: NSCoder) { fatalError("未实现 init(coder:)") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = MacAssistantUI.Color.window.cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = MacAssistantUI.Color.blue

        titleLabel.font = .systemFont(ofSize: 25, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 4
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        stepLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        stepLabel.textColor = .tertiaryLabelColor

        optionTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        optionDetail.font = .systemFont(ofSize: 12)
        optionDetail.textColor = .secondaryLabelColor
        optionDetail.maximumNumberOfLines = 2
        let optionText = NSStackView(views: [optionTitle, optionDetail])
        optionText.orientation = .vertical
        optionText.alignment = .leading
        optionText.spacing = 3
        let optionRow = NSStackView(views: [optionText, optionSwitch])
        optionRow.orientation = .horizontal
        optionRow.alignment = .centerY
        optionRow.spacing = 16
        optionRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        optionRow.wantsLayer = true
        optionRow.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
        optionRow.layer?.cornerRadius = 10
        optionRow.translatesAutoresizingMaskIntoConstraints = false
        optionRow.identifier = NSUserInterfaceItemIdentifier("onboarding-option")
        optionSwitch.target = self
        optionSwitch.action = #selector(optionChanged)

        backButton.target = self
        backButton.action = #selector(goBack)
        nextButton.target = self
        nextButton.action = #selector(goNext)
        let footer = NSStackView(views: [backButton, NSView(), nextButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let stack = NSStackView(views: [stepLabel, iconView, titleLabel, detailLabel, optionRow, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 54),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -54),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 52),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -34),
            iconView.widthAnchor.constraint(equalToConstant: 62),
            iconView.heightAnchor.constraint(equalToConstant: 62),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            optionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func renderPage() {
        let page = pages[pageIndex]
        stepLabel.stringValue = "第 \(pageIndex + 1) 步，共 \(pages.count) 步"
        iconView.image = MacAssistantUI.symbol(page.symbol, pointSize: 48, weight: .regular)
        titleLabel.stringValue = page.title
        detailLabel.stringValue = page.detail
        backButton.isHidden = pageIndex == 0
        nextButton.title = pageIndex == pages.count - 1 ? "完成" : "继续"

        let isClipboardPage = page.title == "剪贴板历史" || page.title == "剪贴板由你控制"
        let isDisplayPage = page.title.contains("显示器")
        if let optionRow = window?.contentView?.subviewsRecursive.first(where: { $0.identifier?.rawValue == "onboarding-option" }) {
            optionRow.isHidden = !isClipboardPage && !isDisplayPage
        }
        if isClipboardPage {
            optionTitle.stringValue = "启用剪贴板历史"
            optionDetail.stringValue = "本地加密保存，自动清理 30 天前未收藏记录"
            optionSwitch.state = clipboardEnabled ? .on : .off
        } else if isDisplayPage {
            optionTitle.stringValue = "允许显示器后台自动化"
            optionDetail.stringValue = "默认关闭；手动控制不受影响"
            optionSwitch.state = displayAutomationApproved ? .on : .off
        }
    }

    @objc private func optionChanged() {
        let title = pages[pageIndex].title
        if title == "剪贴板历史" || title == "剪贴板由你控制" {
            clipboardEnabled = optionSwitch.state == .on
        } else if title.contains("显示器") {
            displayAutomationApproved = optionSwitch.state == .on
        }
    }

    @objc private func goBack() {
        guard pageIndex > 0 else { return }
        pageIndex -= 1
        renderPage()
    }

    @objc private func goNext() {
        guard pageIndex == pages.count - 1 else {
            pageIndex += 1
            renderPage()
            return
        }
        do {
            try store.completeOnboarding(
                clipboardEnabled: clipboardEnabled,
                displayAutomationApproved: displayAutomationApproved
            )
            window?.orderOut(nil)
            completion()
        } catch {
            detailLabel.stringValue = "无法保存引导设置：\(error.localizedDescription)"
            detailLabel.textColor = .systemRed
        }
    }
}

private extension NSView {
    var subviewsRecursive: [NSView] {
        subviews + subviews.flatMap(\.subviewsRecursive)
    }
}
