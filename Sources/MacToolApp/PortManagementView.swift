import AppKit
import Foundation

final class PortManagementView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum ColumnID {
        static let favorite = NSUserInterfaceItemIdentifier("favorite")
        static let port = NSUserInterfaceItemIdentifier("port")
        static let proto = NSUserInterfaceItemIdentifier("protocol")
        static let app = NSUserInterfaceItemIdentifier("app")
        static let pid = NSUserInterfaceItemIdentifier("pid")
        static let endpoint = NSUserInterfaceItemIdentifier("endpoint")
        static let path = NSUserInterfaceItemIdentifier("path")
    }

    private enum ProtocolFilter: Int, CaseIterable {
        case all
        case tcp
        case udp

        var title: String {
            switch self {
            case .all: return "全部协议"
            case .tcp: return "TCP"
            case .udp: return "UDP"
            }
        }

        func includes(_ usage: PortUsage) -> Bool {
            switch self {
            case .all:
                return true
            case .tcp:
                return usage.protocolName == "TCP"
            case .udp:
                return usage.protocolName == "UDP"
            }
        }
    }

    private enum ScopeFilter: Int, CaseIterable {
        case all
        case loopback
        case network

        var title: String {
            switch self {
            case .all: return "全部地址"
            case .loopback: return "仅本机"
            case .network: return "局域网/对外"
            }
        }

        func includes(_ usage: PortUsage) -> Bool {
            switch self {
            case .all:
                return true
            case .loopback:
                return usage.addressScope == .loopback
            case .network:
                return usage.addressScope == .network
            }
        }
    }

    private enum SortField: String, CaseIterable {
        case port
        case app
        case pid
        case proto
        case endpoint
        case path

        var title: String {
            switch self {
            case .port: return "端口"
            case .app: return "应用"
            case .pid: return "PID"
            case .proto: return "协议"
            case .endpoint: return "监听地址"
            case .path: return "路径"
            }
        }
    }

    private let manager = PortManager()
    private var usages: [PortUsage] = []
    private var filteredUsages: [PortUsage] = []
    private var isLoading = false
    private var favoritePorts: Set<Int> = []
    private var protocolFilter: ProtocolFilter = .all
    private var scopeFilter: ScopeFilter = .all
    private var sortField: SortField = .port
    private var sortAscending = true

    private let searchField = MacSearchField()
    private let protocolSelect = MacSelectControl()
    private let scopeSelect = MacSelectControl()
    private let sortSelect = MacSelectControl()
    private let refreshButton = MacIconButton(symbolName: "arrow.clockwise")
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let tableHeaderView = PortTableHeaderView()
    private var hasLoaded = false
    private static let favoritePortsKey = "PortManagementView.favoritePorts"

    override func layout() {
        super.layout()
        updateColumnWidths()
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        favoritePorts = Set(UserDefaults.standard.array(forKey: Self.favoritePortsKey) as? [Int] ?? [])
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refreshIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refresh()
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
        let filterView = filterToolbar()
        let tableViewContainer = tableContainer()
        root.addArrangedSubview(headerView)
        root.addArrangedSubview(filterView)
        root.addArrangedSubview(tableViewContainer)

        NSLayoutConstraint.activate([
            headerView.widthAnchor.constraint(equalTo: root.widthAnchor),
            filterView.widthAnchor.constraint(equalTo: root.widthAnchor),
            tableViewContainer.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func header() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let title = MacAssistantUI.title("监听端口", size: 20, weight: .bold)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [title, statusLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .firstBaseline
        titleStack.spacing = 10
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholder = "搜索端口、应用、PID 或路径"
        searchField.onChange = { [weak self] _ in
            self?.applyFilter()
        }
        searchField.widthAnchor.constraint(equalToConstant: 314).isActive = true

        refreshButton.target = self
        refreshButton.action = #selector(refreshAction)
        refreshButton.toolTip = "刷新端口"
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
            searchField.leadingAnchor.constraint(greaterThanOrEqualTo: header.leadingAnchor),
            searchField.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return header
    }

    private func filterToolbar() -> NSView {
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.48).cgColor
        toolbar.layer?.cornerRadius = 9
        toolbar.layer?.cornerCurve = .continuous
        toolbar.layer?.borderColor = MacAssistantUI.Color.hairline.withAlphaComponent(0.85).cgColor
        toolbar.layer?.borderWidth = 1
        toolbar.heightAnchor.constraint(equalToConstant: 46).isActive = true

        configureSelect(protocolSelect, titles: ProtocolFilter.allCases.map(\.title), action: #selector(protocolFilterChanged))
        configureSelect(scopeSelect, titles: ScopeFilter.allCases.map(\.title), action: #selector(scopeFilterChanged))
        configureSelect(sortSelect, titles: SortField.allCases.map { "按\($0.title)" }, action: #selector(sortFieldChanged))

        let filterLabel = smallLabel("筛选")

        let filterStack = NSStackView(views: [
            filterLabel,
            protocolSelect,
            scopeSelect,
            separatorDot(),
            sortSelect
        ])
        filterStack.orientation = .horizontal
        filterStack.alignment = .centerY
        filterStack.spacing = 8
        filterStack.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(filterStack)

        NSLayoutConstraint.activate([
            filterStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            filterStack.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor, constant: -12),
            filterStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            protocolSelect.widthAnchor.constraint(equalToConstant: 112),
            scopeSelect.widthAnchor.constraint(equalToConstant: 126),
            sortSelect.widthAnchor.constraint(equalToConstant: 102)
        ])

        return toolbar
    }

    private func smallLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func separatorDot() -> NSView {
        let dot = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.separator,
            cornerRadius: 1.5
        )
        dot.widthAnchor.constraint(equalToConstant: 3).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 3).isActive = true
        return dot
    }

    private func configureSelect(_ select: MacSelectControl, titles: [String], action: Selector) {
        select.items = titles
        select.selectedIndex = 0
        select.target = self
        select.action = action
        select.translatesAutoresizingMaskIntoConstraints = false
    }

    private func tableContainer() -> NSView {
        let container = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: 8,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        container.heightAnchor.constraint(equalToConstant: 420).isActive = true
        tableHeaderView.translatesAutoresizingMaskIntoConstraints = false
        tableHeaderView.onColumnClick = { [weak self] identifier in
            self?.sortByHeader(identifier: identifier)
        }
        container.addSubview(tableHeaderView)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.gridColor = MacAssistantUI.Color.hairline
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.target = self
        tableView.doubleAction = #selector(showSelectedPortDetails)

        addColumn(identifier: ColumnID.favorite, title: "常用", width: 54)
        addColumn(identifier: ColumnID.port, title: "端口", width: 70, sortField: .port)
        addColumn(identifier: ColumnID.proto, title: "协议", width: 62, sortField: .proto)
        addColumn(identifier: ColumnID.app, title: "应用", width: 130, sortField: .app)
        addColumn(identifier: ColumnID.pid, title: "PID", width: 70, sortField: .pid)
        addColumn(identifier: ColumnID.endpoint, title: "监听地址", width: 150, sortField: .endpoint)
        addColumn(identifier: ColumnID.path, title: "路径", width: 240, sortField: .path)
        updateSortDescriptors()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableClipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            tableHeaderView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tableHeaderView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            tableHeaderView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            tableHeaderView.heightAnchor.constraint(equalToConstant: 30),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: tableHeaderView.bottomAnchor, constant: 5),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        return container
    }

    private func addColumn(identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, sortField: SortField? = nil) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = min(width, 64)
        column.resizingMask = [.userResizingMask]
        if let sortField {
            column.sortDescriptorPrototype = NSSortDescriptor(key: sortField.rawValue, ascending: true)
        }
        tableView.addTableColumn(column)
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        refreshButton.isEnabled = false
        statusLabel.stringValue = "正在刷新..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.manager.listListeningPorts() }
            DispatchQueue.main.async {
                self.isLoading = false
                self.refreshButton.spinOnce { [weak self] in
                    self?.refreshButton.isEnabled = true
                }

                switch result {
                case .success(let usages):
                    self.usages = usages
                    self.applyFilter()
                case .failure(let error):
                    self.usages = []
                    self.filteredUsages = []
                    self.tableView.reloadData()
                    self.statusLabel.stringValue = "查询失败"
                    self.showAlert(title: "端口查询失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func applyFilter() {
        let query = searchField.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filteredUsages = usages
            .filter { protocolFilter.includes($0) }
            .filter { scopeFilter.includes($0) }
            .filter { usage in
                guard !query.isEmpty else { return true }
                return [
                    "\(usage.port)",
                    usage.protocolName,
                    usage.addressScope.displayName,
                    usage.displayName,
                    usage.command,
                    "\(usage.pid)",
                    usage.endpoint,
                    usage.displayPath,
                    usage.user,
                    favoritePorts.contains(usage.port) ? "常用 收藏 favorite" : ""
                ].contains { $0.lowercased().contains(query) }
            }
        sortFilteredUsages()
        updateColumnWidths()
        tableView.reloadData()
        statusLabel.stringValue = filteredUsages.isEmpty
            ? "未发现监听端口"
            : "\(filteredUsages.count)/\(usages.count) 个监听端口"
    }

    private func sortFilteredUsages() {
        filteredUsages.sort { lhs, rhs in
            let result: ComparisonResult
            switch sortField {
            case .port:
                result = compare(lhs.port, rhs.port)
            case .app:
                result = lhs.displayName.localizedStandardCompare(rhs.displayName)
            case .pid:
                result = compare(lhs.pid, rhs.pid)
            case .proto:
                result = lhs.protocolName.localizedStandardCompare(rhs.protocolName)
            case .endpoint:
                result = lhs.endpoint.localizedStandardCompare(rhs.endpoint)
            case .path:
                result = lhs.displayPath.localizedStandardCompare(rhs.displayPath)
            }

            if result == .orderedSame {
                return tieBreak(lhs, rhs)
            }
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func tieBreak(_ lhs: PortUsage, _ rhs: PortUsage) -> Bool {
        let lhsFavorite = favoritePorts.contains(lhs.port)
        let rhsFavorite = favoritePorts.contains(rhs.port)
        if lhsFavorite != rhsFavorite {
            return lhsFavorite
        }
        if lhs.port != rhs.port {
            return lhs.port < rhs.port
        }
        if lhs.protocolName != rhs.protocolName {
            return lhs.protocolName.localizedStandardCompare(rhs.protocolName) == .orderedAscending
        }
        if lhs.displayName != rhs.displayName {
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        return lhs.pid < rhs.pid
    }

    private func updateColumnWidths() {
        let contentWidth = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : bounds.width - 16
        let availableWidth = max(1060, floor(contentWidth))
        let favoriteWidth: CGFloat = 46
        let portWidth: CGFloat = 92
        let protoWidth: CGFloat = 80
        let pidWidth: CGFloat = 82
        let fixedWidth = favoriteWidth + portWidth + protoWidth + pidWidth
        let appWidth = min(220, max(160, floor(availableWidth * 0.18)))
        let endpointWidth = min(300, max(230, floor(availableWidth * 0.25)))
        let pathWidth = max(360, availableWidth - fixedWidth - appWidth - endpointWidth)
        let tableWidth = fixedWidth + appWidth + endpointWidth + pathWidth
        let widths: [NSUserInterfaceItemIdentifier: CGFloat] = [
            ColumnID.favorite: favoriteWidth,
            ColumnID.port: portWidth,
            ColumnID.proto: protoWidth,
            ColumnID.app: appWidth,
            ColumnID.pid: pidWidth,
            ColumnID.endpoint: endpointWidth,
            ColumnID.path: pathWidth
        ]

        for column in tableView.tableColumns {
            guard let width = widths[column.identifier] else { continue }
            column.width = width
        }
        tableHeaderView.columns = tableView.tableColumns.map { column in
            PortTableHeaderView.Column(
                identifier: column.identifier,
                title: headerTitle(for: column.identifier),
                width: column.width,
                centered: column.identifier == ColumnID.favorite || column.identifier == ColumnID.proto
            )
        }

        tableView.setFrameSize(NSSize(width: tableWidth, height: max(tableView.frame.height, scrollView.contentSize.height)))
    }

    @objc private func tableClipViewBoundsDidChange(_ notification: Notification) {
        tableHeaderView.horizontalOffset = scrollView.contentView.bounds.origin.x
    }

    private func headerTitle(for identifier: NSUserInterfaceItemIdentifier) -> String {
        let title: String
        let field: SortField?
        switch identifier {
        case ColumnID.favorite:
            title = "常用"
            field = nil
        case ColumnID.port:
            title = "端口"
            field = .port
        case ColumnID.proto:
            title = "协议"
            field = .proto
        case ColumnID.app:
            title = "应用"
            field = .app
        case ColumnID.pid:
            title = "PID"
            field = .pid
        case ColumnID.endpoint:
            title = "监听地址"
            field = .endpoint
        case ColumnID.path:
            title = "路径"
            field = .path
        default:
            title = ""
            field = nil
        }

        guard field == sortField else { return title }
        return "\(title) \(sortAscending ? "↑" : "↓")"
    }

    private func measuredWidth(title: String, values: [String], minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let titleWidth = width(of: title, font: titleFont)
        let valueWidth = values.reduce(titleWidth) { current, value in
            max(current, width(of: value, font: font))
        }
        return min(maxWidth, max(minWidth, ceil(valueWidth + 44)))
    }

    private func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredUsages.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredUsages.indices.contains(row), let identifier = tableColumn?.identifier else {
            return nil
        }
        let usage = filteredUsages[row]

        switch identifier {
        case ColumnID.favorite:
            let button = PortFavoriteButton(port: usage.port, isFavorite: favoritePorts.contains(usage.port))
            button.target = self
            button.action = #selector(toggleFavoriteFromButton)
            button.toolTip = favoritePorts.contains(usage.port) ? "取消常用端口 \(usage.port)" : "标记为常用端口 \(usage.port)"
            return centeredCell(button, leading: 0, trailing: 0, centerHorizontally: true)
        case ColumnID.port:
            return textCell("\(usage.port)", weight: .bold, color: .labelColor)
        case ColumnID.proto:
            return badgeCell(usage.protocolName, tint: usage.protocolName == "TCP" ? MacAssistantUI.Color.blue : MacAssistantUI.Color.green)
        case ColumnID.app:
            let cell = textCell(usage.displayName, weight: .medium)
            cell.toolTip = usage.command
            return cell
        case ColumnID.pid:
            return textCell("\(usage.pid)", color: .secondaryLabelColor)
        case ColumnID.endpoint:
            return textCell(usage.endpoint, color: .secondaryLabelColor)
        case ColumnID.path:
            let cell = textCell(usage.displayPath, color: .secondaryLabelColor)
            cell.toolTip = usage.displayPath
            return cell
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PortTableRowView()
    }

    private func textCell(_ text: String, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTableCellView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = centeredCell(label)
        cell.textField = label
        return cell
    }

    private func badgeCell(_ text: String, tint: NSColor) -> NSTableCellView {
        let badge = PortBadgeView(title: text, tint: tint)
        return centeredCell(badge, leading: 10, trailing: 10)
    }

    private func centeredCell(_ contentView: NSView, leading: CGFloat = 10, trailing: CGFloat = 10, centerHorizontally: Bool = false) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(contentView)

        var constraints = [
            contentView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            contentView.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: 2),
            contentView.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -2)
        ]

        if centerHorizontally {
            constraints.append(contentView.centerXAnchor.constraint(equalTo: cell.centerXAnchor))
            constraints.append(contentView.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor, constant: leading))
            constraints.append(contentView.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -trailing))
        } else {
            constraints.append(contentView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading))
            constraints.append(contentView.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -trailing))
        }

        NSLayoutConstraint.activate(constraints)
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let field = SortField(rawValue: key) else {
            return
        }
        sortField = field
        sortAscending = descriptor.ascending
        sortSelect.selectedIndex = SortField.allCases.firstIndex(of: field) ?? 0
        applyFilter()
    }

    @objc private func refreshAction() {
        refresh()
    }

    @objc private func protocolFilterChanged() {
        protocolFilter = ProtocolFilter(rawValue: protocolSelect.selectedIndex) ?? .all
        applyFilter()
    }

    @objc private func scopeFilterChanged() {
        scopeFilter = ScopeFilter(rawValue: scopeSelect.selectedIndex) ?? .all
        applyFilter()
    }

    @objc private func sortFieldChanged() {
        let index = sortSelect.selectedIndex
        sortField = SortField.allCases.indices.contains(index) ? SortField.allCases[index] : .port
        updateSortDescriptors()
        applyFilter()
    }

    @objc private func toggleFavoriteFromButton(_ sender: PortFavoriteButton) {
        toggleFavoritePort(sender.port)
    }

    @objc private func showSelectedPortDetails() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard filteredUsages.indices.contains(row) else { return }
        showDetails(for: filteredUsages[row])
    }

    private func showDetails(for usage: PortUsage) {
        let controller = PortDetailWindowController(usage: usage, manager: manager)
        if case .stop(let method) = controller.runModal(parentWindow: window) {
            stop(usage, method: method)
        }
    }

    private func stop(_ usage: PortUsage, method: PortStopMethod) {
        guard confirmStop(usage, method: method) else {
            return
        }

        do {
            try manager.stop(usage, method: method)
            AppLogger.shared.info("已请求停止端口进程：method=\(method.displayName), port=\(usage.port), pid=\(usage.pid), app=\(usage.displayName)")
            DispatchQueue.main.asyncAfter(deadline: .now() + (method == .graceful ? 1.2 : 0.5)) { [weak self] in
                self?.refresh()
            }
        } catch {
            showAlert(title: "停止失败", message: error.localizedDescription)
            if error is PortManagerError {
                refresh()
            }
        }
    }

    private func confirmStop(_ usage: PortUsage, method: PortStopMethod) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确认使用「\(method.displayName)」停止 \(usage.displayName)？"
        alert.informativeText = "\(method.riskDescription)\n\n目标：PID \(usage.pid)，端口 \(usage.port)，监听地址 \(usage.endpoint)。"
        alert.alertStyle = method == .kill ? .critical : (method == .terminate ? .warning : .informational)
        alert.addButton(withTitle: method.displayName)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func toggleFavoritePort(_ port: Int) {
        if favoritePorts.contains(port) {
            favoritePorts.remove(port)
        } else {
            favoritePorts.insert(port)
        }
        UserDefaults.standard.set(Array(favoritePorts).sorted(), forKey: Self.favoritePortsKey)
        applyFilter()
    }

    private func updateSortDescriptors() {
        let descriptor = NSSortDescriptor(key: sortField.rawValue, ascending: sortAscending)
        if tableView.sortDescriptors != [descriptor] {
            tableView.sortDescriptors = [descriptor]
        }
    }

    private func sortByHeader(identifier: NSUserInterfaceItemIdentifier) {
        guard let field = sortField(for: identifier) else { return }
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = true
        }
        sortSelect.selectedIndex = SortField.allCases.firstIndex(of: sortField) ?? 0
        updateSortDescriptors()
        applyFilter()
    }

    private func sortField(for identifier: NSUserInterfaceItemIdentifier) -> SortField? {
        switch identifier {
        case ColumnID.port:
            return .port
        case ColumnID.proto:
            return .proto
        case ColumnID.app:
            return .app
        case ColumnID.pid:
            return .pid
        case ColumnID.endpoint:
            return .endpoint
        case ColumnID.path:
            return .path
        default:
            return nil
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

private final class PortTableRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        (isSelected ? MacAssistantUI.Color.blue.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.58)).setFill()
        path.fill()

        if !isSelected {
            MacAssistantUI.Color.hairline.withAlphaComponent(0.62).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        MacAssistantUI.Color.blue.withAlphaComponent(0.12).setFill()
        path.fill()
        MacAssistantUI.Color.blue.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class PortTableHeaderView: NSView {
    struct Column {
        let identifier: NSUserInterfaceItemIdentifier
        let title: String
        let width: CGFloat
        let centered: Bool
    }

    var columns: [Column] = [] {
        didSet { needsDisplay = true }
    }

    var horizontalOffset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    var onColumnClick: ((NSUserInterfaceItemIdentifier) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderColor = MacAssistantUI.Color.hairline.withAlphaComponent(0.78).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let targetX = point.x + horizontalOffset
        var x: CGFloat = 0
        for column in columns {
            let range = x..<(x + column.width)
            if range.contains(targetX) {
                onColumnClick?(column.identifier)
                return
            }
            x += column.width
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x: CGFloat = -horizontalOffset
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        for (index, column) in columns.enumerated() {
            let rect = NSRect(x: x, y: 0, width: column.width, height: bounds.height)
            guard rect.maxX >= 0, rect.minX <= bounds.width else {
                x += column.width
                continue
            }
            let textSize = (column.title as NSString).size(withAttributes: attributes)
            let textX = column.centered ? rect.midX - textSize.width / 2 : rect.minX + 12
            column.title.draw(
                in: NSRect(x: textX, y: floor((bounds.height - textSize.height) / 2) - 0.5, width: min(textSize.width + 2, rect.width - 16), height: textSize.height),
                withAttributes: attributes
            )

            x += column.width
            if index < columns.count - 1 {
                MacAssistantUI.Color.hairline.withAlphaComponent(0.72).setStroke()
                let separator = NSBezierPath()
                separator.move(to: NSPoint(x: x, y: 8))
                separator.line(to: NSPoint(x: x, y: bounds.height - 8))
                separator.lineWidth = 1
                separator.stroke()
            }
        }
    }
}

private final class PortBadgeView: NSView {
    private let title: String
    private let tint: NSColor

    init(title: String, tint: NSColor) {
        self.title = title
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 48).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        tint.withAlphaComponent(0.12).setFill()
        path.fill()
        tint.withAlphaComponent(0.26).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: tint
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        title.draw(
            in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 0.5, width: size.width, height: size.height),
            withAttributes: attributes
        )
    }
}

private final class PortFavoriteButton: NSControl {
    let port: Int
    private var isFavorite: Bool
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    init(port: Int, isFavorite: Bool) {
        self.port = port
        self.isFavorite = isFavorite
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let shouldSendAction = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldSendAction {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tint = isFavorite ? NSColor.systemYellow : NSColor.secondaryLabelColor
        if isPressed || isFavorite {
            let chrome = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
            tint.withAlphaComponent(isPressed ? 0.18 : 0.10).setFill()
            chrome.fill()
        }

        let symbol = isFavorite ? "star.fill" : "star"
        guard let icon = MacAssistantUI.symbol(symbol, pointSize: 15, weight: .semibold) else { return }
        let rect = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        tint.setFill()
        rect.fill(using: .sourceAtop)
    }
}

private enum PortDetailResponse {
    case close
    case stop(PortStopMethod)
}

private final class PortDetailWindowController: NSWindowController, NSWindowDelegate {
    private let usage: PortUsage
    private let manager: PortManager
    private let resourceQueue = DispatchQueue(label: "com.fusheng.mac-tool.port-detail-resource", qos: .utility)
    private var response: PortDetailResponse = .close
    private var refreshTimer: Timer?
    private var resourceLabels: [ResourceField: NSTextField] = [:]
    private var stopButton: MacTextButton?
    private var stopMethodPopup: MacSelectControl?
    private var isProcessAlive = true
    private var isResourceSnapshotLoading = false

    init(usage: PortUsage, manager: PortManager) {
        self.usage = usage
        self.manager = manager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "端口详情"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func runModal(parentWindow: NSWindow?) -> PortDetailResponse {
        guard let window else { return .close }
        if let parentWindow {
            let parentFrame = parentWindow.frame
            let windowFrame = window.frame
            window.setFrameOrigin(NSPoint(
                x: parentFrame.midX - windowFrame.width / 2,
                y: parentFrame.midY - windowFrame.height / 2
            ))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        updateResourceSnapshot()
        startRefreshing()
        NSApp.runModal(for: window)
        return response
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = MacAssistantUI.Color.window.cgColor

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        root.addArrangedSubview(headerView())
        root.addArrangedSubview(detailCard())
        root.addArrangedSubview(buttonRow())
    }

    private func headerView() -> NSView {
        let title = MacAssistantUI.title("\(usage.displayName) 正在监听 \(usage.port)", size: 17, weight: .bold)
        title.maximumNumberOfLines = 2
        let subtitle = MacAssistantUI.caption("双击列表只查看详情；需要释放端口时，请先选择停止方式。", size: 12)
        subtitle.maximumNumberOfLines = 2

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 512).isActive = true
        return stack
    }

    private func detailCard() -> NSView {
        let card = LayerBackedView(
            backgroundColor: MacAssistantUI.Color.card,
            cornerRadius: 8,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        card.widthAnchor.constraint(equalToConstant: 512).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        stack.addArrangedSubview(detailRow(title: "端口", value: "\(usage.port)"))
        stack.addArrangedSubview(detailRow(title: "协议", value: usage.protocolName))
        stack.addArrangedSubview(detailRow(title: "监听地址", value: usage.endpoint))
        stack.addArrangedSubview(detailRow(title: "地址范围", value: usage.addressScope.displayName))
        stack.addArrangedSubview(detailRow(title: "应用", value: usage.displayName))
        stack.addArrangedSubview(detailRow(title: "命令", value: usage.command))
        stack.addArrangedSubview(detailRow(title: "PID", value: "\(usage.pid)"))
        stack.addArrangedSubview(detailRow(title: "用户", value: usage.user.isEmpty ? "未知" : usage.user))
        stack.addArrangedSubview(sectionSeparator())
        stack.addArrangedSubview(resourceRow(title: "CPU", field: .cpu))
        stack.addArrangedSubview(resourceRow(title: "内存", field: .memory))
        stack.addArrangedSubview(resourceRow(title: "虚拟内存", field: .virtualMemory))
        stack.addArrangedSubview(resourceRow(title: "线程数", field: .threads))
        stack.addArrangedSubview(resourceRow(title: "打开文件", field: .openFiles))
        stack.addArrangedSubview(resourceRow(title: "父进程", field: .parentPID))
        stack.addArrangedSubview(resourceRow(title: "状态", field: .state))
        stack.addArrangedSubview(resourceRow(title: "运行时长", field: .elapsed))
        stack.addArrangedSubview(resourceRow(title: "启动命令", field: .commandLine))
        stack.addArrangedSubview(sectionSeparator())
        stack.addArrangedSubview(detailRow(title: "路径", value: usage.displayPath))
        if !usage.executablePath.isEmpty, usage.executablePath != usage.displayPath {
            stack.addArrangedSubview(detailRow(title: "可执行文件", value: usage.executablePath))
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func resourceRow(title: String, field: ResourceField) -> NSView {
        let row = detailRow(title: title, value: "读取中...")
        if let valueLabel = row.subviews.compactMap({ $0 as? NSTextField }).last {
            resourceLabels[field] = valueLabel
        }
        return row
    }

    private func detailRow(title: String, value: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .systemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .labelColor
        valueLabel.isSelectable = true
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.maximumNumberOfLines = 2
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(titleLabel)
        row.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            titleLabel.widthAnchor.constraint(equalToConstant: 78),

            valueLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: row.topAnchor),
            valueLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor),

            row.widthAnchor.constraint(equalToConstant: 484)
        ])
        return row
    }

    private func sectionSeparator() -> NSView {
        let separator = MacAssistantUI.separator()
        separator.widthAnchor.constraint(equalToConstant: 484).isActive = true
        return separator
    }

    private func formattedCPU(_ value: Double?) -> String {
        guard let value else { return "未知" }
        return String(format: "%.1f%%", value)
    }

    private func formattedBytes(_ value: UInt64?) -> String {
        guard let value else { return "未知" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(value))
    }

    private func formattedCount(_ value: Int?) -> String {
        guard let value else { return "未知" }
        return "\(value)"
    }

    private func formattedPID(_ value: Int32?) -> String {
        guard let value else { return "未知" }
        return "\(value)"
    }

    private func buttonRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 512).isActive = true
        row.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let closeButton = MacTextButton(title: "关闭", role: .primary)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(closeButton)

        var constraints = [
            closeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 86)
        ]

        if usage.pid != getpid() {
            let revealButton = MacTextButton(title: "打开位置")
            revealButton.target = self
            revealButton.action = #selector(revealProcessLocation)
            revealButton.translatesAutoresizingMaskIntoConstraints = false
            revealButton.isEnabled = manager.locationURL(for: usage) != nil
            row.addSubview(revealButton)

            let copyKillButton = MacTextButton(title: "复制命令")
            copyKillButton.target = self
            copyKillButton.action = #selector(copyKillCommand)
            copyKillButton.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(copyKillButton)

            let stopMethodPopup = MacSelectControl()
            stopMethodPopup.items = PortStopMethod.allCases.map(\.displayName)
            stopMethodPopup.selectedIndex = PortStopMethod.allCases.firstIndex(of: .terminate) ?? 1
            stopMethodPopup.toolTip = "正常退出风险最低，TERM 可清理，KILL 立即强制结束。"
            stopMethodPopup.translatesAutoresizingMaskIntoConstraints = false
            self.stopMethodPopup = stopMethodPopup
            row.addSubview(stopMethodPopup)

            let stopButton = MacTextButton(title: "停止运行", role: .destructive)
            stopButton.target = self
            stopButton.action = #selector(stopPressed)
            stopButton.translatesAutoresizingMaskIntoConstraints = false
            self.stopButton = stopButton
            row.addSubview(stopButton)
            constraints.append(contentsOf: [
                stopButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
                stopButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                stopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),

                stopMethodPopup.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -8),
                stopMethodPopup.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                stopMethodPopup.widthAnchor.constraint(equalToConstant: 112),

                copyKillButton.trailingAnchor.constraint(equalTo: stopMethodPopup.leadingAnchor, constant: -8),
                copyKillButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                copyKillButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),

                revealButton.trailingAnchor.constraint(equalTo: copyKillButton.leadingAnchor, constant: -8),
                revealButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                revealButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 78)
            ])
        }

        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateResourceSnapshot()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateResourceSnapshot() {
        guard !isResourceSnapshotLoading else {
            return
        }
        isResourceSnapshotLoading = true
        let pid = usage.pid
        resourceQueue.async { [weak self] in
            let result = Result { try self?.manager.resourceSnapshot(pid: pid) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isResourceSnapshotLoading = false
                guard self.window?.isVisible == true else { return }
                switch result {
                case .success(let snapshot?):
                    self.isProcessAlive = true
                    self.stopButton?.isEnabled = self.usage.pid != getpid()
                    self.stopMethodPopup?.isEnabled = self.usage.pid != getpid()
                    self.apply(snapshot: snapshot)
                case .success(nil), .failure:
                    self.isProcessAlive = false
                    self.stopButton?.isEnabled = false
                    self.stopMethodPopup?.isEnabled = false
                    self.applyExitedState()
                }
            }
        }
    }

    private func apply(snapshot: ProcessResourceSnapshot) {
        resourceLabels[.cpu]?.stringValue = formattedCPU(snapshot.cpuPercent)
        resourceLabels[.memory]?.stringValue = formattedBytes(snapshot.residentMemoryBytes)
        resourceLabels[.virtualMemory]?.stringValue = formattedBytes(snapshot.virtualMemoryBytes)
        resourceLabels[.threads]?.stringValue = formattedCount(snapshot.threadCount)
        resourceLabels[.openFiles]?.stringValue = formattedCount(snapshot.openFileCount)
        resourceLabels[.parentPID]?.stringValue = formattedPID(snapshot.parentPID)
        resourceLabels[.state]?.stringValue = snapshot.state.isEmpty ? "未知" : snapshot.state
        resourceLabels[.elapsed]?.stringValue = snapshot.elapsedTime.isEmpty ? "未知" : snapshot.elapsedTime
        resourceLabels[.commandLine]?.stringValue = snapshot.commandLine.isEmpty ? "未知" : snapshot.commandLine
    }

    private func applyExitedState() {
        resourceLabels[.cpu]?.stringValue = "进程已退出"
        resourceLabels[.memory]?.stringValue = "进程已退出"
        resourceLabels[.virtualMemory]?.stringValue = "进程已退出"
        resourceLabels[.threads]?.stringValue = "进程已退出"
        resourceLabels[.openFiles]?.stringValue = "进程已退出"
        resourceLabels[.parentPID]?.stringValue = "进程已退出"
        resourceLabels[.state]?.stringValue = "进程已退出"
        resourceLabels[.elapsed]?.stringValue = "进程已退出"
        resourceLabels[.commandLine]?.stringValue = "进程已退出"
    }

    @objc private func closePressed() {
        response = .close
        closeModal()
    }

    @objc private func stopPressed() {
        guard isProcessAlive else { return }
        let index = stopMethodPopup?.selectedIndex ?? PortStopMethod.allCases.firstIndex(of: .terminate) ?? 1
        let method = PortStopMethod.allCases.indices.contains(index) ? PortStopMethod.allCases[index] : .terminate
        response = .stop(method)
        closeModal()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        isResourceSnapshotLoading = false
        NSApp.stopModal()
    }

    @objc private func copyKillCommand() {
        let index = stopMethodPopup?.selectedIndex ?? PortStopMethod.allCases.firstIndex(of: .terminate) ?? 1
        let method = PortStopMethod.allCases.indices.contains(index) ? PortStopMethod.allCases[index] : .terminate
        guard let command = manager.shellKillCommand(pid: usage.pid, method: method) else {
            showInlineAlert(title: "无法复制命令", message: "正常退出不是 shell kill 命令，请选择 TERM 或 KILL。")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        MacAssistantNotifier.notify(title: "已复制端口命令", message: command)
    }

    @objc private func revealProcessLocation() {
        guard let url = manager.locationURL(for: usage) else {
            showInlineAlert(title: "找不到进程位置", message: usage.displayPath)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func showInlineAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func closeModal() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        window?.close()
        NSApp.stopModal()
    }
}

private enum ResourceField: Hashable {
    case cpu
    case memory
    case virtualMemory
    case threads
    case openFiles
    case parentPID
    case state
    case elapsed
    case commandLine
}
