import AppKit

final class OnboardingWindowController: NSWindowController {
    private struct Page {
        enum Kind { case purpose, modules, permissions, trial, upgradeClipboard, upgradeDisplay, information }
        let symbol: String
        let title: String
        let detail: String
        let kind: Kind
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
    private let secondaryOptionTitle = NSTextField(labelWithString: "")
    private let secondaryOptionDetail = NSTextField(wrappingLabelWithString: "")
    private let secondaryOptionSwitch = MacSwitchControl()
    private let purposeSelect = MacSelectControl()
    private let trialButton = MacTextButton(title: "复制测试文本", symbolName: "doc.on.doc", role: .neutral)
    private let trialStatus = NSTextField(labelWithString: "尚未完成测试")
    private let backButton = MacTextButton(title: "上一步")
    private let nextButton = MacTextButton(title: "继续", symbolName: "arrow.right", role: .primary)
    private var pageIndex = 0
    private var clipboardEnabled = true
    private var displayAutomationApproved = false
    private var trialCompleted = false

    private lazy var pages: [Page] = {
        if store.isExistingInstallation {
            return [
                Page(
                    symbol: "lock.shield",
                    title: "隐私与安全升级",
                    detail: "0.2.0 会把现有剪贴板历史迁移到本机 AES-256-GCM 加密存储。迁移校验完成前，原数据库会保留且不会开始新记录。",
                    kind: .information
                ),
                Page(
                    symbol: "doc.on.clipboard",
                    title: "剪贴板由你控制",
                    detail: "内容只保存在这台 Mac，密钥位于钥匙串且不可同步。默认保留 30 天；密码管理器和带敏感标记的内容会自动跳过。",
                    kind: .upgradeClipboard
                ),
                Page(
                    symbol: "display.2",
                    title: "重新确认显示器自动化",
                    detail: "升级后不会自动断开任何显示器。只有你在这里明确允许，并且配置同时启用时，后台软断开才会运行。",
                    kind: .upgradeDisplay
                ),
                Page(
                    symbol: "checkmark.shield",
                    title: "升级准备完成",
                    detail: "Finder 动作已加入签名与时效校验；日志和诊断仍只保存在本机。你可以随时在设置中修改这些选项。",
                    kind: .information
                )
            ]
        }
        return [
            Page(symbol: "scope", title: "你主要想解决什么？", detail: "选择最接近的用途，我们会据此安排概览页重点；所有工具之后仍可随时使用。", kind: .purpose),
            Page(symbol: "switch.2", title: "启用常用模块", detail: "剪贴板会在本机加密记录；显示器后台自动化默认关闭，手动控制始终可用。", kind: .modules),
            Page(symbol: "lock.shield", title: "权限按需申请", detail: "Finder 扩展、辅助功能和完全磁盘访问只在对应功能需要时说明。异常会集中显示在概览与偏好设置。", kind: .permissions),
            Page(symbol: "checkmark.shield", title: "完成一次真实操作", detail: "复制下面的测试文本，确认 Mac助手能执行本地快捷操作。完成后将进入为你定制的控制中心。", kind: .trial)
        ]
    }()

    init(store: ProfileStore, completion: @escaping () -> Void) {
        self.store = store
        self.completion = completion
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
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

        secondaryOptionTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        secondaryOptionDetail.font = .systemFont(ofSize: 12)
        secondaryOptionDetail.textColor = .secondaryLabelColor
        secondaryOptionDetail.maximumNumberOfLines = 2
        let secondaryText = NSStackView(views: [secondaryOptionTitle, secondaryOptionDetail])
        secondaryText.orientation = .vertical
        secondaryText.alignment = .leading
        secondaryText.spacing = 3
        let secondaryOptionRow = NSStackView(views: [secondaryText, secondaryOptionSwitch])
        secondaryOptionRow.orientation = .horizontal
        secondaryOptionRow.alignment = .centerY
        secondaryOptionRow.spacing = 16
        secondaryOptionRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        secondaryOptionRow.wantsLayer = true
        secondaryOptionRow.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
        secondaryOptionRow.layer?.cornerRadius = 10
        secondaryOptionRow.identifier = NSUserInterfaceItemIdentifier("onboarding-secondary-option")
        secondaryOptionSwitch.target = self
        secondaryOptionSwitch.action = #selector(optionChanged)

        purposeSelect.items = ["日常效率", "开发工作", "系统维护"]
        purposeSelect.selectedIndex = 0
        purposeSelect.identifier = NSUserInterfaceItemIdentifier("onboarding-purpose")
        purposeSelect.widthAnchor.constraint(equalToConstant: 260).isActive = true

        trialButton.target = self
        trialButton.action = #selector(runTrial)
        trialStatus.font = .systemFont(ofSize: 12, weight: .medium)
        trialStatus.textColor = .secondaryLabelColor
        let trialRow = NSStackView(views: [trialButton, trialStatus])
        trialRow.orientation = .horizontal
        trialRow.alignment = .centerY
        trialRow.spacing = 12
        trialRow.identifier = NSUserInterfaceItemIdentifier("onboarding-trial")

        backButton.target = self
        backButton.action = #selector(goBack)
        nextButton.target = self
        nextButton.action = #selector(goNext)
        let footer = NSStackView(views: [backButton, NSView(), nextButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let stack = NSStackView(views: [stepLabel, iconView, titleLabel, detailLabel, purposeSelect, optionRow, secondaryOptionRow, trialRow, footer])
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
            secondaryOptionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

        let optionRow = window?.contentView?.subviewsRecursive.first { $0.identifier?.rawValue == "onboarding-option" }
        let secondaryRow = window?.contentView?.subviewsRecursive.first { $0.identifier?.rawValue == "onboarding-secondary-option" }
        let purpose = window?.contentView?.subviewsRecursive.first { $0.identifier?.rawValue == "onboarding-purpose" }
        let trial = window?.contentView?.subviewsRecursive.first { $0.identifier?.rawValue == "onboarding-trial" }
        optionRow?.isHidden = ![Page.Kind.modules, .upgradeClipboard, .upgradeDisplay].contains(page.kind)
        secondaryRow?.isHidden = page.kind != .modules
        purpose?.isHidden = page.kind != .purpose
        trial?.isHidden = page.kind != .trial

        if page.kind == .modules || page.kind == .upgradeClipboard {
            optionTitle.stringValue = "启用剪贴板历史"
            optionDetail.stringValue = "本地加密保存，自动清理 30 天前未收藏记录"
            optionSwitch.state = clipboardEnabled ? .on : .off
        } else if page.kind == .upgradeDisplay {
            optionTitle.stringValue = "允许显示器后台自动化"
            optionDetail.stringValue = "默认关闭；手动控制不受影响"
            optionSwitch.state = displayAutomationApproved ? .on : .off
        }
        if page.kind == .modules {
            secondaryOptionTitle.stringValue = "允许显示器后台自动化"
            secondaryOptionDetail.stringValue = "高风险操作仍需确认，并保留最后屏幕保护"
            secondaryOptionSwitch.state = displayAutomationApproved ? .on : .off
        }
        nextButton.isEnabled = page.kind != .trial || trialCompleted
    }

    @objc private func optionChanged() {
        let page = pages[pageIndex]
        if page.kind == .modules {
            clipboardEnabled = optionSwitch.state == .on
            displayAutomationApproved = secondaryOptionSwitch.state == .on
        } else if page.kind == .upgradeClipboard {
            clipboardEnabled = optionSwitch.state == .on
        } else if page.kind == .upgradeDisplay {
            displayAutomationApproved = optionSwitch.state == .on
        }
    }

    @objc private func runTrial() {
        NSPasteboard.general.clearContents()
        let succeeded = NSPasteboard.general.setString("Mac助手已准备就绪", forType: .string)
        trialCompleted = succeeded
        trialStatus.stringValue = succeeded ? "已复制，可继续" : "复制失败，请重试"
        trialStatus.textColor = succeeded ? MacAssistantUI.Color.green : .systemRed
        nextButton.isEnabled = succeeded
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
            UserDefaults.standard.set(purposeSelect.selectedIndex, forKey: "controlCenter.primaryPurpose")
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
