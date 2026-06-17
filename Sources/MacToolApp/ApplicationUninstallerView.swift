import AppKit
import Foundation

final class ApplicationUninstallerView: NSView {
    private enum Filter: Int, CaseIterable {
        case all
        case removable
        case homebrew
        case protected

        var title: String {
            switch self {
            case .all: return "全部应用"
            case .removable: return "可卸载"
            case .homebrew: return "Homebrew"
            case .protected: return "受保护"
            }
        }

        func includes(_ app: InstalledApplication) -> Bool {
            switch self {
            case .all:
                return true
            case .removable:
                return app.canUninstall
            case .homebrew:
                return app.source == .homebrewCask
            case .protected:
                return !app.canUninstall
            }
        }
    }

    private let uninstaller = ApplicationUninstaller()
    private let workQueue = DispatchQueue(label: "com.fusheng.mac-tool.application-uninstaller", qos: .userInitiated)
    private var applications: [InstalledApplication] = []
    private var filteredApplications: [InstalledApplication] = []
    private var selectedApplicationIDs: Set<String> = []
    private var plansByApplicationID: [String: ApplicationUninstallPlan] = [:]
    private var rowViewsByID: [String: ApplicationUninstallRowView] = [:]
    private var filter: Filter = .all
    private var isLoading = false
    private var isPreviewing = false
    private var isExecuting = false
    private var hasLoaded = false
    private var planWindowController: ApplicationUninstallPlanWindowController?
    private var historyWindowController: ApplicationUninstallHistoryWindowController?
    private var isBusy: Bool {
        isLoading || isPreviewing || isExecuting
    }

    private let searchField = MacSearchField()
    private let filterSelect = MacSelectControl()
    private let refreshButton = MacIconButton(symbolName: "arrow.clockwise")
    private let previewButton = MacTextButton(title: "预览所选", symbolName: "doc.text.magnifyingglass", role: .primary)
    private let clearButton = MacTextButton(title: "清空选择", symbolName: "xmark", role: .neutral)
    private let selectAllButton = MacTextButton(title: "选择可卸载", symbolName: "checklist", role: .neutral)
    private let historyButton = MacTextButton(title: "历史", symbolName: "clock.arrow.circlepath", role: .neutral)
    private let cancelBatchButton = MacTextButton(title: "停止队列", symbolName: "stop.circle", role: .destructive)
    private let statusLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private var adminKeepAliveTimer: DispatchSourceTimer?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        updateActions()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func refreshIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refreshApplications()
    }

    private func buildUI() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let headerView = header()
        let toolbarView = toolbar()
        let listView = listContainer()
        let summaryView = summaryPanel()
        root.addArrangedSubview(headerView)
        root.addArrangedSubview(toolbarView)
        root.addArrangedSubview(listView)
        root.addArrangedSubview(summaryView)

        NSLayoutConstraint.activate([
            headerView.widthAnchor.constraint(equalTo: root.widthAnchor),
            toolbarView.widthAnchor.constraint(equalTo: root.widthAnchor),
            listView.widthAnchor.constraint(equalTo: root.widthAnchor),
            summaryView.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func header() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let title = MacAssistantUI.title("应用卸载", size: 20, weight: .bold)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [title, statusLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .firstBaseline
        titleStack.spacing = 10
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholder = "搜索应用、Bundle ID、路径"
        searchField.onChange = { [weak self] _ in
            guard let self, !self.isBusy else { return }
            self.applyFilter()
        }
        searchField.widthAnchor.constraint(equalToConstant: 310).isActive = true

        refreshButton.target = self
        refreshButton.action = #selector(refreshAction)
        refreshButton.toolTip = "刷新应用列表"
        refreshButton.tintColor = MacAssistantUI.Color.blue

        header.addSubview(titleStack)
        header.addSubview(searchField)
        header.addSubview(refreshButton)

        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: searchField.leadingAnchor, constant: -16),

            refreshButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            searchField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        statusLabel.stringValue = "尚未扫描"
        return header
    }

    private func toolbar() -> NSView {
        let toolbar = LayerBackedView(
            backgroundColor: NSColor.white.withAlphaComponent(0.48),
            cornerRadius: 9,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        toolbar.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let label = smallLabel("范围")
        filterSelect.items = Filter.allCases.map(\.title)
        filterSelect.selectedIndex = 0
        filterSelect.target = self
        filterSelect.action = #selector(filterChanged)
        filterSelect.widthAnchor.constraint(equalToConstant: 112).isActive = true

        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllRemovable)
        clearButton.target = self
        clearButton.action = #selector(clearSelection)
        historyButton.target = self
        historyButton.action = #selector(showHistory)

        let stack = NSStackView(views: [label, filterSelect, separatorDot(), selectAllButton, clearButton, historyButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])
        return toolbar
    }

    private func listContainer() -> NSView {
        let container = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: 8,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        container.heightAnchor.constraint(equalToConstant: 420).isActive = true

        let header = ApplicationUninstallListHeaderView()
        container.addSubview(header)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        listStack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.stringValue = "点击刷新扫描应用。"
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let document = MacFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        document.addSubview(emptyLabel)
        scrollView.documentView = document
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 28),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            emptyLabel.centerYAnchor.constraint(equalTo: document.centerYAnchor)
        ])
        return container
    }

    private func summaryPanel() -> NSView {
        let panel = LayerBackedView(
            backgroundColor: NSColor.white.withAlphaComponent(0.54),
            cornerRadius: 8,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        panel.heightAnchor.constraint(equalToConstant: 76).isActive = true

        summaryLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        summaryLabel.textColor = .labelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let detail = MacAssistantUI.caption("默认移到废纸篓；系统级残留只提示，不自动删除。")

        let textStack = NSStackView(views: [summaryLabel, detail])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        previewButton.target = self
        previewButton.action = #selector(previewSelected)
        cancelBatchButton.target = self
        cancelBatchButton.action = #selector(cancelExecutingBatch)
        cancelBatchButton.isHidden = true

        let buttonStack = NSStackView(views: [cancelBatchButton, previewButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(textStack)
        panel.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -16),

            buttonStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            buttonStack.centerYAnchor.constraint(equalTo: panel.centerYAnchor)
        ])
        updateSummary()
        return panel
    }

    private func smallLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func separatorDot() -> NSView {
        let dot = LayerBackedView(backgroundColor: MacAssistantUI.Color.separator, cornerRadius: 1.5)
        dot.widthAnchor.constraint(equalToConstant: 3).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 3).isActive = true
        return dot
    }

    @objc private func refreshAction() {
        refreshApplications(force: true)
    }

    private func refreshApplications(force: Bool = false) {
        guard !isBusy else { return }
        isLoading = true
        statusLabel.stringValue = "正在扫描..."
        updateActions()
        if force {
            applications = []
            filteredApplications = []
            selectedApplicationIDs.removeAll()
            plansByApplicationID.removeAll()
            rebuildList()
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            let apps = self.uninstaller.scanApplications()
            DispatchQueue.main.async {
                self.isLoading = false
                self.refreshButton.spinOnce { [weak self] in
                    self?.updateActions()
                }
                self.applications = apps
                self.selectedApplicationIDs = self.selectedApplicationIDs.intersection(Set(apps.map(\.id)))
                self.plansByApplicationID.removeAll()
                self.applyFilter()
            }
        }
    }

    private func applyFilter() {
        let query = searchField.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filteredApplications = applications
            .filter { filter.includes($0) }
            .filter { app in
                guard !query.isEmpty else { return true }
                return [
                    app.displayName,
                    app.bundleID,
                    app.path.path,
                    app.homebrewCask ?? "",
                    app.source.rawValue
                ].contains { $0.lowercased().contains(query) }
            }
        rebuildList()
        updateSummary()
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach { view in
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViewsByID.removeAll()

        emptyLabel.isHidden = !filteredApplications.isEmpty
        if filteredApplications.isEmpty {
            emptyLabel.stringValue = applications.isEmpty ? "未扫描到应用。" : "没有符合当前筛选的应用。"
        }

        for app in filteredApplications {
            let row = ApplicationUninstallRowView(application: app)
            row.isChecked = selectedApplicationIDs.contains(app.id)
            row.isEnabled = app.canUninstall && !isBusy
            row.target = self
            row.action = #selector(rowToggled(_:))
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            rowViewsByID[app.id] = row
        }
        statusLabel.stringValue = statusText()
        updateActions()
    }

    private func statusText() -> String {
        guard !isLoading else { return "正在扫描..." }
        if applications.isEmpty { return "未发现应用" }
        let removableCount = applications.filter(\.canUninstall).count
        let protectedCount = applications.count - removableCount
        return "\(applications.count) 个应用，\(removableCount) 个可卸载，\(protectedCount) 个受保护"
    }

    private func updateSummary() {
        let selectedApps = selectedApplications()
        if selectedApps.isEmpty {
            summaryLabel.stringValue = "未选择应用"
        } else {
            let totalSize = selectedApps.reduce(Int64(0)) { $0 + $1.sizeBytes }
            summaryLabel.stringValue = "已选择 \(selectedApps.count) 个应用，应用本体约 \(ByteCountFormatter.macToolString(from: totalSize))"
        }
        updateActions()
    }

    private func updateActions() {
        let hasSelection = !selectedApplicationIDs.isEmpty
        let canInteract = !isBusy
        searchField.isEnabled = canInteract
        filterSelect.isEnabled = canInteract
        refreshButton.isEnabled = canInteract
        previewButton.isEnabled = hasSelection && canInteract
        clearButton.isEnabled = hasSelection && canInteract
        selectAllButton.isEnabled = applications.contains(where: \.canUninstall) && canInteract
        historyButton.isEnabled = canInteract
        cancelBatchButton.isHidden = !isExecuting
        cancelBatchButton.isEnabled = isExecuting && !isCancellationRequested()
        for app in filteredApplications {
            rowViewsByID[app.id]?.isEnabled = app.canUninstall && canInteract
        }
    }

    private func selectedApplications() -> [InstalledApplication] {
        applications.filter { selectedApplicationIDs.contains($0.id) && $0.canUninstall }
    }

    @objc private func filterChanged() {
        guard !isBusy else {
            filterSelect.selectedIndex = filter.rawValue
            return
        }
        filter = Filter(rawValue: filterSelect.selectedIndex) ?? .all
        applyFilter()
    }

    @objc private func rowToggled(_ sender: ApplicationUninstallRowView) {
        guard !isBusy else {
            sender.isChecked = selectedApplicationIDs.contains(sender.applicationID)
            return
        }
        guard let app = applications.first(where: { $0.id == sender.applicationID }), app.canUninstall else {
            sender.isChecked = false
            return
        }
        if sender.isChecked {
            selectedApplicationIDs.insert(app.id)
        } else {
            selectedApplicationIDs.remove(app.id)
        }
        updateSummary()
    }

    @objc private func selectAllRemovable() {
        guard !isBusy else { return }
        selectedApplicationIDs = Set(filteredApplications.filter(\.canUninstall).map(\.id))
        rebuildList()
        updateSummary()
    }

    @objc private func clearSelection() {
        guard !isBusy else { return }
        selectedApplicationIDs.removeAll()
        rebuildList()
        updateSummary()
    }

    @objc private func previewSelected() {
        let apps = selectedApplications()
        guard !apps.isEmpty, !isBusy else { return }
        isPreviewing = true
        summaryLabel.stringValue = "正在生成卸载预览..."
        updateActions()
        let cachedPlans = plansByApplicationID

        workQueue.async { [weak self] in
            guard let self else { return }
            var generatedPlans: [String: ApplicationUninstallPlan] = [:]
            let plans = apps.map { app -> ApplicationUninstallPlan in
                if let cached = cachedPlans[app.id] {
                    return cached
                }
                let plan = self.uninstaller.makePlan(for: app)
                generatedPlans[app.id] = plan
                return plan
            }
            DispatchQueue.main.async {
                guard self.isPreviewing, !self.isExecuting else { return }
                for (appID, plan) in generatedPlans {
                    self.plansByApplicationID[appID] = plan
                }
                self.updateSummary()
                self.showPreview(plans)
            }
        }
    }

    private func showPreview(_ plans: [ApplicationUninstallPlan]) {
        let controller = ApplicationUninstallPlanWindowController(
            plans: plans,
            onDryRun: { [weak self] plans in
                self?.dryRun(plans: plans)
            },
            onConfirm: { [weak self] plans, sheetWindow in
                self?.execute(plans: plans, sheetWindow: sheetWindow)
            },
            onClose: { [weak self] in
                self?.finishPreview()
            }
        )
        planWindowController = controller
        if let parent = window, let sheet = controller.window {
            parent.beginSheet(sheet)
        } else {
            controller.showWindow(nil)
        }
    }

    private func dryRun(plans: [ApplicationUninstallPlan]) {
        guard isPreviewing, !isExecuting else { return }
        summaryLabel.stringValue = "正在执行 dry-run..."
        planWindowController?.setActionsEnabled(false)
        let batchID = UUID()
        workQueue.async { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            var plannedItems = 0
            for plan in plans {
                do {
                    let result = try self.uninstaller.execute(plan: plan, options: .dryRun(batchID: batchID))
                    plannedItems += result.itemResults.count
                    if !result.succeeded {
                        failures.append(plan.application.displayName)
                    }
                } catch {
                    failures.append("\(plan.application.displayName)：\(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.summaryLabel.stringValue = "dry-run 完成，未移动文件"
                self.planWindowController?.setActionsEnabled(true)
                let message = failures.isEmpty
                    ? "已试运行 \(plans.count) 个应用，检查 \(plannedItems) 个项目；未执行外部命令，也未移动文件。"
                    : "dry-run 发现风险：\(failures.joined(separator: "、"))。未执行外部命令，也未移动文件。"
                self.showAlert(title: failures.isEmpty ? "Dry-run 完成" : "Dry-run 有风险", message: message)
            }
        }
    }

    private func execute(plans: [ApplicationUninstallPlan], sheetWindow: NSWindow) {
        guard !isExecuting else { return }
        isPreviewing = false
        isExecuting = true
        sheetWindow.isExcludedFromWindowsMenu = true
        sheetWindow.contentView?.subviews.forEach { $0.isHidden = true }
        statusLabel.stringValue = "正在卸载..."
        summaryLabel.stringValue = "正在执行卸载，请不要关闭窗口。"
        setCancellationRequested(false)
        updateActions()

        workQueue.async { [weak self] in
            guard let self else { return }
            var results: [ApplicationUninstallResult] = []
            var failures: [String] = []
            var homebrewSuccessCount = 0
            let batchID = UUID()
            self.uninstaller.recordBatchAudit(batchID: batchID, mode: .commit, status: "batch-started", message: "开始批量卸载 \(plans.count) 个应用")
            self.uninstaller.prepareAdministratorAuthorizationIfNeeded(for: plans)
            self.startAdminKeepAliveIfNeeded(for: plans)
            defer {
                self.stopAdminKeepAlive()
            }
            for plan in plans {
                if self.isCancellationRequested() {
                    failures.append("用户已停止后续队列")
                    self.uninstaller.recordBatchAudit(batchID: batchID, mode: .commit, status: "cancelled", message: "用户停止后续队列")
                    break
                }
                do {
                    let result = try self.uninstaller.execute(plan: plan, options: .commit(batchID: batchID)) { progress in
                        DispatchQueue.main.async {
                            self.statusLabel.stringValue = progress.title
                            self.summaryLabel.stringValue = progress.detail
                        }
                    }
                    results.append(result)
                    homebrewSuccessCount += result.itemResults.filter {
                        $0.success && $0.item.action == .command && $0.item.category == .homebrew
                    }.count
                    if !result.succeeded {
                        failures.append(plan.application.displayName)
                    }
                } catch {
                    failures.append("\(plan.application.displayName)：\(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                if let parent = self.window {
                    parent.endSheet(sheetWindow)
                }
                sheetWindow.orderOut(nil)
                self.planWindowController = nil
                self.selectedApplicationIDs.removeAll()
                self.plansByApplicationID.removeAll()
                self.hasLoaded = false
                self.setCancellationRequested(false)
                self.isExecuting = false
                self.updateActions()
                self.refreshApplications(force: true)

                let removedCount = results.filter(\.succeeded).count
                let trashSuccessCount = results.reduce(0) { partial, result in
                    partial + result.itemResults.filter { $0.success && $0.item.action == .moveToTrash }.count
                }
                let message: String
                if failures.isEmpty {
                    if homebrewSuccessCount > 0 {
                        message = "已处理 \(removedCount) 个应用，其中 \(homebrewSuccessCount) 个 Homebrew 项通过 brew --zap 卸载；\(trashSuccessCount) 个用户级项目已移到废纸篓，计划内状态调整已记录到历史。"
                    } else {
                        message = "已处理 \(removedCount) 个应用。\(trashSuccessCount) 个可删除项目已移到废纸篓；系统级残留仍保留为提示。"
                    }
                } else {
                    message = "成功 \(removedCount) 个，失败或部分失败：\(failures.joined(separator: "、"))。未完成项目没有被永久删除。"
                }
                self.showAlert(title: failures.isEmpty ? "卸载完成" : "卸载部分完成", message: message)
            }
        }
    }

    @objc private func cancelExecutingBatch() {
        guard isExecuting else { return }
        setCancellationRequested(true)
        updateActions()
        statusLabel.stringValue = "正在停止队列..."
        summaryLabel.stringValue = "当前应用处理结束后会停止后续卸载。"
    }

    @objc private func showHistory() {
        guard !isBusy else { return }
        historyButton.isEnabled = false
        workQueue.async { [weak self] in
            guard let self else { return }
            let entries = self.uninstaller.uninstallHistory(limit: 200)
            DispatchQueue.main.async {
                self.historyButton.isEnabled = true
                let controller = ApplicationUninstallHistoryWindowController(entries: entries)
                self.historyWindowController = controller
                controller.showWindow(nil)
            }
        }
    }

    private func setCancellationRequested(_ value: Bool) {
        cancellationLock.lock()
        cancellationRequested = value
        cancellationLock.unlock()
    }

    private func isCancellationRequested() -> Bool {
        cancellationLock.lock()
        let value = cancellationRequested
        cancellationLock.unlock()
        return value
    }

    private func finishPreview() {
        guard isPreviewing, !isExecuting else { return }
        isPreviewing = false
        planWindowController = nil
        updateSummary()
    }

    private func startAdminKeepAliveIfNeeded(for plans: [ApplicationUninstallPlan]) {
        let needsAdmin = plans.contains { plan in
            plan.trashItems.contains { $0.requiresAdmin }
        }
        guard needsAdmin else { return }
        stopAdminKeepAlive()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 45, repeating: 45)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.uninstaller.prepareAdministratorAuthorizationIfNeeded(for: plans)
        }
        adminKeepAliveTimer = timer
        timer.resume()
    }

    private func stopAdminKeepAlive() {
        adminKeepAliveTimer?.cancel()
        adminKeepAliveTimer = nil
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = title.contains("失败") || title.contains("部分") ? .warning : .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

private enum ApplicationUninstallListLayout {
    static let headerLeadingInset: CGFloat = 42
    static let rowTextLeadingInset: CGFloat = 82
    static let trailingInset: CGFloat = 10
    static let columnSpacing: CGFloat = 12
    static let appRatio: CGFloat = 0.30
    static let pathRatio: CGFloat = 0.46
    static let metaRatio: CGFloat = 0.24

    static var headerFixedWidth: CGFloat {
        headerLeadingInset + trailingInset + columnSpacing * 2
    }

    static var rowFixedWidth: CGFloat {
        rowTextLeadingInset + trailingInset + columnSpacing * 2
    }

    static func columnConstant(ratio: CGFloat, fixedWidth: CGFloat) -> CGFloat {
        -fixedWidth * ratio
    }
}

private final class ApplicationUninstallListHeaderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        let columns = [
            ("应用", ApplicationUninstallListLayout.appRatio),
            ("Bundle ID / 路径", ApplicationUninstallListLayout.pathRatio),
            ("来源 / 大小", ApplicationUninstallListLayout.metaRatio)
        ]
        var previous: NSTextField?
        for (title, ratio) in columns {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(
                    equalTo: widthAnchor,
                    multiplier: ratio,
                    constant: ApplicationUninstallListLayout.columnConstant(
                        ratio: ratio,
                        fixedWidth: ApplicationUninstallListLayout.headerFixedWidth
                    )
                )
            ])
            if let previous {
                label.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: ApplicationUninstallListLayout.columnSpacing).isActive = true
            } else {
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ApplicationUninstallListLayout.headerLeadingInset).isActive = true
            }
            previous = label
        }
        previous?.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ApplicationUninstallListLayout.trailingInset).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }
}

private final class ApplicationUninstallRowView: NSControl {
    let applicationID: String
    private let checkbox = MacCheckboxControl()
    private var selectedBackground = false {
        didSet { needsDisplay = true }
    }

    var isChecked: Bool {
        get { checkbox.state == .on }
        set {
            checkbox.state = newValue ? .on : .off
            selectedBackground = newValue
        }
    }

    override var isEnabled: Bool {
        didSet {
            checkbox.isEnabled = isEnabled
            needsDisplay = true
        }
    }

    init(application: InstalledApplication) {
        self.applicationID = application.id
        super.init(frame: .zero)
        setup(application)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isChecked.toggle()
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        if selectedBackground {
            MacAssistantUI.Color.blue.withAlphaComponent(isEnabled ? 0.08 : 0.035).setFill()
        } else {
            NSColor.white.withAlphaComponent(isEnabled ? 0.38 : 0.18).setFill()
        }
        path.fill()
        MacAssistantUI.Color.hairline.withAlphaComponent(isEnabled ? (selectedBackground ? 1 : 0.55) : 0.32).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func setup(_ application: InstalledApplication) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 68).isActive = true
        isEnabled = application.canUninstall

        checkbox.target = self
        checkbox.action = #selector(checkboxChanged)
        checkbox.isEnabled = application.canUninstall
        addSubview(checkbox)

        let iconView = NSImageView()
        iconView.image = NSWorkspace.shared.icon(forFile: application.path.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let nameLabel = text(application.displayName, size: 13, weight: .semibold, color: application.canUninstall ? .labelColor : .secondaryLabelColor)
        let versionText = application.version.map { "版本 \($0)" } ?? "版本未知"
        let stateText = application.canUninstall ? versionText : (application.protectedReason ?? application.officialUninstallerVendor.map { "需使用 \($0) 官方卸载器" } ?? "受保护")
        let stateLabel = text(stateText, size: 11, weight: .regular, color: application.canUninstall ? .secondaryLabelColor : NSColor.systemRed)

        let bundleLabel = text(application.bundleID, size: 12, weight: .medium, color: .labelColor)
        let pathLabel = text(application.path.path, size: 11, weight: .regular, color: .secondaryLabelColor)

        let sourceLabel = badge(application.source == .homebrewCask ? "Homebrew" : "App", color: application.source == .homebrewCask ? MacAssistantUI.Color.amber : MacAssistantUI.Color.blue)
        let sizeLabel = text(ByteCountFormatter.macToolString(from: application.sizeBytes), size: 12, weight: .semibold, color: .secondaryLabelColor)
        let adminLabel = badge(application.requiresAdmin ? "需授权" : "用户权限", color: application.requiresAdmin ? NSColor.systemRed : MacAssistantUI.Color.green)

        let appStack = NSStackView(views: [nameLabel, stateLabel])
        appStack.orientation = .vertical
        appStack.alignment = .leading
        appStack.spacing = 4
        appStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(appStack)

        let pathStack = NSStackView(views: [bundleLabel, pathLabel])
        pathStack.orientation = .vertical
        pathStack.alignment = .leading
        pathStack.spacing = 4
        pathStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathStack)

        let metaStack = NSStackView(views: [sourceLabel, sizeLabel, adminLabel])
        metaStack.orientation = .vertical
        metaStack.alignment = .leading
        metaStack.spacing = 5
        metaStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metaStack)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),

            appStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            appStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            appStack.widthAnchor.constraint(
                equalTo: widthAnchor,
                multiplier: ApplicationUninstallListLayout.appRatio,
                constant: ApplicationUninstallListLayout.columnConstant(
                    ratio: ApplicationUninstallListLayout.appRatio,
                    fixedWidth: ApplicationUninstallListLayout.rowFixedWidth
                )
            ),

            pathStack.leadingAnchor.constraint(equalTo: appStack.trailingAnchor, constant: ApplicationUninstallListLayout.columnSpacing),
            pathStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathStack.widthAnchor.constraint(
                equalTo: widthAnchor,
                multiplier: ApplicationUninstallListLayout.pathRatio,
                constant: ApplicationUninstallListLayout.columnConstant(
                    ratio: ApplicationUninstallListLayout.pathRatio,
                    fixedWidth: ApplicationUninstallListLayout.rowFixedWidth
                )
            ),

            metaStack.leadingAnchor.constraint(equalTo: pathStack.trailingAnchor, constant: ApplicationUninstallListLayout.columnSpacing),
            metaStack.widthAnchor.constraint(
                equalTo: widthAnchor,
                multiplier: ApplicationUninstallListLayout.metaRatio,
                constant: ApplicationUninstallListLayout.columnConstant(
                    ratio: ApplicationUninstallListLayout.metaRatio,
                    fixedWidth: ApplicationUninstallListLayout.rowFixedWidth
                )
            ),
            metaStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ApplicationUninstallListLayout.trailingInset),
            metaStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func checkboxChanged() {
        selectedBackground = checkbox.state == .on
        sendAction(action, to: target)
    }

    private func text(_ value: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func badge(_ value: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

private final class ApplicationUninstallPlanWindowController: NSWindowController, NSWindowDelegate {
    private let plans: [ApplicationUninstallPlan]
    private let onDryRun: ([ApplicationUninstallPlan]) -> Void
    private let onConfirm: ([ApplicationUninstallPlan], NSWindow) -> Void
    private let onClose: () -> Void
    private let dryRunButton = MacTextButton(title: "试运行", symbolName: "checkmark.shield", role: .neutral)
    private let confirmButton = MacTextButton(title: "确认移到废纸篓", symbolName: "trash", role: .destructive)
    private let cancelButton = MacTextButton(title: "取消", symbolName: "xmark", role: .neutral)
    private var didNotifyClose = false
    private var hasCommandItems: Bool {
        plans.contains { !$0.commandItems.isEmpty }
    }

    init(
        plans: [ApplicationUninstallPlan],
        onDryRun: @escaping ([ApplicationUninstallPlan]) -> Void,
        onConfirm: @escaping ([ApplicationUninstallPlan], NSWindow) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.plans = plans
        self.onDryRun = onDryRun
        self.onConfirm = onConfirm
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "卸载预览"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = MacAssistantUI.Color.window.cgColor

        let title = MacAssistantUI.title("卸载预览", size: 20, weight: .bold)
        let subtitleText = hasCommandItems
            ? "命令项会按下方清单执行，不经过废纸篓；其余用户级项目移到废纸篓，系统级残留仅提示。"
            : "确认后会按下方清单移动到废纸篓；系统级残留默认保留为提示。"
        let subtitle = MacAssistantUI.caption(subtitleText)
        let headerStack = NSStackView(views: [title, subtitle])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 16, right: 4)
        list.translatesAutoresizingMaskIntoConstraints = false

        for plan in plans {
            let section = planSection(plan)
            list.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        let document = MacFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scrollView.documentView = document

        confirmButton.target = self
        confirmButton.action = #selector(confirm)
        if hasCommandItems {
            confirmButton.title = "确认卸载并执行清单命令"
            confirmButton.symbolName = "exclamationmark.triangle"
        }
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        dryRunButton.target = self
        dryRunButton.action = #selector(dryRun)
        let buttonStack = NSStackView(views: [cancelButton, dryRunButton, confirmButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(headerStack)
        contentView.addSubview(scrollView)
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            headerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            headerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -16),

            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),

            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    private func planSection(_ plan: ApplicationUninstallPlan) -> NSView {
        let box = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: 8,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )

        let title = MacAssistantUI.title(plan.application.displayName, size: 14, weight: .bold)
        let detail = MacAssistantUI.caption("\(plan.application.bundleID)  ·  \(plan.application.path.path)", size: 11)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 1
        let commandText = plan.commandItems.isEmpty ? "" : "；执行命令 \(plan.commandItems.count) 项"
        let summary = MacAssistantUI.caption("将移到废纸篓 \(plan.trashItems.count) 项，约 \(ByteCountFormatter.macToolString(from: plan.estimatedRecoverableBytes))；系统级提示 \(plan.reviewOnlyItems.count) 项\(commandText)。", size: 12)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(summary)

        for warning in plan.warnings {
            stack.addArrangedSubview(itemLine("提示：\(warning)", color: NSColor.systemOrange))
        }

        if !plan.commandItems.isEmpty {
            stack.addArrangedSubview(groupLabel("将执行命令，不经过废纸篓"))
            for item in plan.commandItems {
                let detail = item.detail.map { "  \($0)" } ?? ""
                stack.addArrangedSubview(itemLine("\(item.category.rawValue)：\(item.displayName)\(detail)", color: NSColor.systemRed))
            }
        }

        if !plan.trashItems.isEmpty {
            stack.addArrangedSubview(groupLabel("移到废纸篓"))
            for item in plan.trashItems {
                stack.addArrangedSubview(itemLine("\(item.category.rawValue)：\(item.displayName)  \(ByteCountFormatter.macToolString(from: item.sizeBytes))", color: .labelColor))
            }
        }

        if !plan.reviewOnlyItems.isEmpty {
            stack.addArrangedSubview(groupLabel("仅提示，不删除"))
            for item in plan.reviewOnlyItems {
                stack.addArrangedSubview(itemLine("\(item.category.rawValue)：\(item.displayName)", color: .secondaryLabelColor))
            }
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        return box
    }

    private func groupLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = MacAssistantUI.Color.blue
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func itemLine(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    @objc private func confirm() {
        guard let window else { return }
        didNotifyClose = true
        setActionsEnabled(false)
        onConfirm(plans, window)
    }

    @objc private func dryRun() {
        setActionsEnabled(false)
        onDryRun(plans)
    }

    @objc private func cancel() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        }
        window.orderOut(nil)
        notifyClose()
    }

    func setActionsEnabled(_ enabled: Bool) {
        dryRunButton.isEnabled = enabled
        confirmButton.isEnabled = enabled
        cancelButton.isEnabled = enabled
    }

    func windowWillClose(_ notification: Notification) {
        notifyClose()
    }

    private func notifyClose() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose()
    }
}

private final class ApplicationUninstallHistoryWindowController: NSWindowController {
    private let entries: [ApplicationUninstallAuditEntry]
    private let closeButton = MacTextButton(title: "关闭", symbolName: "xmark", role: .neutral)

    init(entries: [ApplicationUninstallAuditEntry]) {
        self.entries = entries
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "卸载历史"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = MacAssistantUI.Color.window.cgColor

        let title = MacAssistantUI.title("卸载历史", size: 20, weight: .bold)
        let subtitle = MacAssistantUI.caption(entries.isEmpty ? "暂无卸载审计记录。" : "最近 \(entries.count) 条审计记录，包含 dry-run、跳过、失败和已移动状态。")
        let headerStack = NSStackView(views: [title, subtitle])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 16, right: 4)
        list.translatesAutoresizingMaskIntoConstraints = false
        for entry in entries {
            let row = historyRow(entry)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        let document = MacFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scrollView.documentView = document

        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(headerStack)
        contentView.addSubview(scrollView)
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            headerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            headerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -16),

            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            closeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    private func historyRow(_ entry: ApplicationUninstallAuditEntry) -> NSView {
        let box = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: 7,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        let status = entry.status ?? "unknown"
        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.font = .systemFont(ofSize: 11, weight: .bold)
        statusLabel.textColor = color(for: status)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleText = [entry.app, entry.itemCategory, entry.itemAction]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let title = MacAssistantUI.title(titleText.isEmpty ? "批量记录" : titleText, size: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail

        let detailText = [
            entry.message,
            entry.path ?? entry.appPath,
            entry.time
        ].compactMap { $0 }.joined(separator: "  ·  ")
        let detail = MacAssistantUI.caption(detailText, size: 11)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 2

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(statusLabel)
        box.addSubview(stack)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            statusLabel.widthAnchor.constraint(equalToConstant: 112),

            stack.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)
        ])
        return box
    }

    private func color(for status: String) -> NSColor {
        if status.contains("failed") || status.contains("cancelled") {
            return NSColor.systemRed
        }
        if status.contains("dry-run") || status.contains("planned") {
            return MacAssistantUI.Color.blue
        }
        if status.contains("trashed") || status.contains("ok") {
            return MacAssistantUI.Color.green
        }
        return .secondaryLabelColor
    }

    @objc private func closeWindow() {
        window?.close()
    }
}

private extension ByteCountFormatter {
    static func macToolString(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
