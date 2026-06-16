import AppKit
import Darwin
import Foundation

struct InstalledApplication: Identifiable, Hashable {
    enum Source: String {
        case applicationBundle = "App"
        case homebrewCask = "Homebrew"
    }

    let id: String
    let displayName: String
    let bundleID: String
    let version: String?
    let path: URL
    let source: Source
    let homebrewCask: String?
    let sizeBytes: Int64
    let lastUsedDate: Date?
    let requiresAdmin: Bool
    let protectedReason: String?
    let officialUninstallerVendor: String?
    let isRunning: Bool

    var canUninstall: Bool {
        protectedReason == nil && officialUninstallerVendor == nil
    }
}

struct ApplicationUninstallPlan {
    let id: UUID
    let application: InstalledApplication
    let items: [ApplicationUninstallItem]
    let warnings: [String]
    let blockedReason: String?
    let estimatedRecoverableBytes: Int64
    let estimatedReviewOnlyBytes: Int64

    var isBlocked: Bool { blockedReason != nil }

    var trashItems: [ApplicationUninstallItem] {
        items.filter { $0.action == .moveToTrash }
    }

    var reviewOnlyItems: [ApplicationUninstallItem] {
        items.filter { $0.action == .reviewOnly }
    }

    var commandItems: [ApplicationUninstallItem] {
        items.filter { $0.action == .command }
    }
}

struct ApplicationUninstallItem: Identifiable, Hashable {
    enum Category: String {
        case applicationBundle = "应用本体"
        case userSupport = "应用支持"
        case cache = "缓存"
        case logs = "日志"
        case preferences = "偏好设置"
        case container = "容器"
        case webData = "Web 数据"
        case launchAgent = "启动代理"
        case appExtension = "扩展数据"
        case diagnosticReport = "诊断报告"
        case systemReview = "系统级残留"
        case receipt = "安装收据"
        case sharedData = "共享数据"
        case homebrew = "Homebrew"
        case launchServices = "LaunchServices"
        case loginItem = "登录项"
        case runningProcess = "运行进程"
        case defaultsDomain = "Defaults"
        case dockEntry = "Dock"
        case warning = "提示"
    }

    enum Action: String {
        case moveToTrash = "移到废纸篓"
        case reviewOnly = "仅提示"
        case command = "执行命令"
        case skipped = "跳过"
    }

    let id: String
    let url: URL?
    let displayName: String
    let category: Category
    let action: Action
    let requiresAdmin: Bool
    let sizeBytes: Int64
    let detail: String?
}

struct ApplicationUninstallResult {
    struct ItemResult {
        let item: ApplicationUninstallItem
        let success: Bool
        let message: String
    }

    let plan: ApplicationUninstallPlan
    let itemResults: [ItemResult]
    let warnings: [String]
    let recoveredBytes: Int64

    var succeeded: Bool {
        itemResults.allSatisfy(\.success)
    }
}

struct ApplicationUninstallAuditEntry: Identifiable, Decodable {
    let id = UUID()
    let time: String?
    let runID: String?
    let batchID: String?
    let mode: String?
    let status: String?
    let app: String?
    let bundleID: String?
    let appPath: String?
    let path: String?
    let message: String?
    let itemCategory: String?
    let itemAction: String?
    let itemDisplayName: String?
    let itemSizeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case time
        case runID
        case batchID
        case mode
        case status
        case app
        case bundleID
        case appPath
        case path
        case message
        case itemCategory
        case itemAction
        case itemDisplayName
        case itemSizeBytes
    }
}

enum ApplicationUninstallerError: LocalizedError {
    case blocked(String)
    case invalidPath(String)
    case trashUnavailable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let reason):
            return reason
        case .invalidPath(let path):
            return "路径不安全，已拒绝处理：\(path)"
        case .trashUnavailable(let path):
            return "无法移到废纸篓，已拒绝永久删除：\(path)"
        case .commandFailed(let message):
            return message
        }
    }
}

final class ApplicationUninstaller {
    struct ExecutionOptions {
        enum Mode: String {
            case commit
            case dryRun = "dry-run"
        }

        let mode: Mode
        let batchID: UUID

        var isDryRun: Bool { mode == .dryRun }

        static func commit(batchID: UUID = UUID()) -> ExecutionOptions {
            ExecutionOptions(mode: .commit, batchID: batchID)
        }

        static func dryRun(batchID: UUID = UUID()) -> ExecutionOptions {
            ExecutionOptions(mode: .dryRun, batchID: batchID)
        }
    }

    struct Environment {
        var homeDirectory: URL
        var applicationDirectories: [URL]
        var volumesDirectory: URL
        var systemLibraryDirectory: URL
        var systemApplicationsDirectory: URL
        var trashDirectory: URL
        var receiptApplicationDirectories: [URL]
        var homebrewBinaryDirectories: [URL]
        var homebrewCaskroomDirectories: [URL]
        var uninstallAuditLogURL: URL
        var pkgReceiptCacheURL: URL
        var appMetadataCacheURL: URL
        var pkgReceiptCacheTTL: TimeInterval
        var appMetadataCacheTTL: TimeInterval
        var scanTimeout: TimeInterval
        var runExternalCommands: Bool
        var useSystemTrash: Bool

        static let live = Environment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            applicationDirectories: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
                URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Input Methods", isDirectory: true)
            ],
            volumesDirectory: URL(fileURLWithPath: "/Volumes", isDirectory: true),
            systemLibraryDirectory: URL(fileURLWithPath: "/Library", isDirectory: true),
            systemApplicationsDirectory: URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            trashDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true),
            receiptApplicationDirectories: [
                URL(fileURLWithPath: "/usr/local", isDirectory: true),
                URL(fileURLWithPath: "/opt", isDirectory: true)
            ],
            homebrewBinaryDirectories: [
                URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
            ],
            homebrewCaskroomDirectories: [
                URL(fileURLWithPath: "/opt/homebrew/Caskroom", isDirectory: true),
                URL(fileURLWithPath: "/usr/local/Caskroom", isDirectory: true)
            ],
            uninstallAuditLogURL: AppPaths.uninstallAuditLogURL,
            pkgReceiptCacheURL: AppPaths.applicationSupportDirectory.appendingPathComponent("pkg-receipt-apps.json"),
            appMetadataCacheURL: AppPaths.applicationSupportDirectory.appendingPathComponent("application-metadata-cache.json"),
            pkgReceiptCacheTTL: 86_400,
            appMetadataCacheTTL: 3_600,
            scanTimeout: 8,
            runExternalCommands: true,
            useSystemTrash: true
        )
    }

    struct Progress {
        let title: String
        let detail: String
    }

    private struct NameVariants {
        let appName: String
        let nospace: String
        let underscore: String
        let hyphen: String
        let lowercase: String
        let lowercaseNospace: String
        let lowercaseHyphen: String
        let lowercaseUnderscore: String
        let baseName: String
        let baseLowercase: String
    }

    private struct PackageReceiptAppCache: Codable {
        let createdAt: Date
        let paths: [String]
    }

    private struct ApplicationMetadataCache: Codable {
        let createdAt: Date
        var entries: [String: ApplicationMetadataCacheEntry]
    }

    private struct ApplicationMetadataCacheEntry: Codable {
        let path: String
        let identity: String
        let contentModificationDate: Date?
        let displayName: String
        let bundleID: String
        let version: String?
        let source: String
        let homebrewCask: String?
        let sizeBytes: Int64
        let lastUsedDate: Date?
        let requiresAdmin: Bool
        let protectedReason: String?
        let officialUninstallerVendor: String?
    }

    private enum HomebrewCaskState: Equatable {
        case installed
        case notInstalled
        case unknown(String)
    }

    private struct HomebrewUninstallOutcome {
        let success: Bool
        let message: String
        let state: HomebrewCaskState
    }

    private enum CommandPhase {
        case beforeTrash
        case afterApplicationBundle
    }

    private let fileManager: FileManager
    private let environment: Environment
    private let runner: CommandRunning

    init(
        fileManager: FileManager = .default,
        environment: Environment = .live,
        runner: CommandRunning = ProcessCommandRunner()
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.runner = runner
    }

    func scanApplications() -> [InstalledApplication] {
        var candidates: [URL] = []
        let deadline = Date().addingTimeInterval(environment.scanTimeout)
        for directory in applicationSearchDirectories() {
            guard Date() < deadline else { break }
            candidates.append(contentsOf: appBundles(in: directory, maxDepth: 3, deadline: deadline))
        }
        if Date() < deadline {
            candidates.append(contentsOf: packageReceiptAppPaths(deadline: deadline))
        }

        var byIdentity: [String: URL] = [:]
        for candidate in candidates {
            let normalized = candidate.standardizedFileURL
            guard fileManager.fileExists(atPath: normalized.path) else { continue }
            guard !shouldSkipAppPath(normalized) else { continue }
            byIdentity[pathIdentity(normalized)] = normalized
        }

        let candidatePaths = Set(byIdentity.values.map { $0.standardizedFileURL.path })
        var metadataCache = readApplicationMetadataCache()
        var metadataCacheChanged = false
        let apps = byIdentity.values.compactMap {
            resolveApplication($0, cache: &metadataCache, cacheChanged: &metadataCacheChanged)
        }
        if metadataCacheChanged {
            writeApplicationMetadataCache(metadataCache, validPaths: candidatePaths)
        }
        return dedupeApplications(apps)
            .sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    func makePlan(for application: InstalledApplication) -> ApplicationUninstallPlan {
        var items: [ApplicationUninstallItem] = []
        var warnings: [String] = []

        if let reason = application.protectedReason {
            return ApplicationUninstallPlan(
                id: UUID(),
                application: application,
                items: [
                    ApplicationUninstallItem(
                        id: "protected-\(application.id)",
                        url: application.path,
                        displayName: application.path.path,
                        category: .warning,
                        action: .skipped,
                        requiresAdmin: false,
                        sizeBytes: 0,
                        detail: reason
                    )
                ],
                warnings: [reason],
                blockedReason: reason,
                estimatedRecoverableBytes: 0,
                estimatedReviewOnlyBytes: 0
            )
        }

        if let vendor = application.officialUninstallerVendor {
            let reason = "\(application.displayName) 需要使用 \(vendor) 官方卸载器。"
            return ApplicationUninstallPlan(
                id: UUID(),
                application: application,
                items: [
                    ApplicationUninstallItem(
                        id: "official-\(application.id)",
                        url: application.path,
                        displayName: application.path.path,
                        category: .warning,
                        action: .skipped,
                        requiresAdmin: false,
                        sizeBytes: 0,
                        detail: reason
                    )
                ],
                warnings: [reason],
                blockedReason: reason,
                estimatedRecoverableBytes: 0,
                estimatedReviewOnlyBytes: 0
            )
        }

        if application.isRunning {
            warnings.append("应用正在运行，会请求正常退出；如果拒绝退出，不会强制结束进程。")
        }

        guard validateDeletionPath(application.path, allowApplicationBundle: true) else {
            let reason = "应用路径不在允许的卸载范围内，已拒绝只清理残留：\(application.path.path)"
            return ApplicationUninstallPlan(
                id: UUID(),
                application: application,
                items: [
                    ApplicationUninstallItem(
                        id: "unsafe-path-\(application.id)",
                        url: application.path,
                        displayName: application.path.path,
                        category: .warning,
                        action: .skipped,
                        requiresAdmin: false,
                        sizeBytes: 0,
                        detail: reason
                    )
                ],
                warnings: [reason],
                blockedReason: reason,
                estimatedRecoverableBytes: 0,
                estimatedReviewOnlyBytes: 0
            )
        }

        if isSensitiveApplication(bundleID: application.bundleID, appName: application.displayName) {
            warnings.append("检测到该应用可能包含账号、开发、代理或数据库等敏感数据；卸载前请确认已经备份。")
        }

        if application.source == .homebrewCask, let cask = application.homebrewCask {
            items.append(ApplicationUninstallItem(
                id: "homebrew-\(cask)",
                url: nil,
                displayName: "brew uninstall --cask --zap \(cask)",
                category: .homebrew,
                action: .command,
                requiresAdmin: false,
                sizeBytes: 0,
                detail: "Homebrew 管理的 App 会执行 brew --zap；该命令会清理配置和数据，不经过废纸篓。"
            ))
        }

        if application.isRunning {
            items.append(ApplicationUninstallItem(
                id: "quit-\(application.id)",
                url: nil,
                displayName: "请求正常退出 \(application.displayName)",
                category: .runningProcess,
                action: .command,
                requiresAdmin: false,
                sizeBytes: 0,
                detail: "只发送正常退出请求；不会执行 kill 或强制结束。"
            ))
        }

        if appDeclaresLocalNetworkUsage(application.path) {
            warnings.append("该应用声明过 Local Network/Bonjour 权限；macOS 15+ 可能在应用移除后仍保留网络权限记录，需要在系统设置中手动清理。")
        }

        let helperBundleIDs = loginItemHelperBundleIDs(in: application.path)
        if !helperBundleIDs.isEmpty {
            warnings.append("检测到登录项 helper：\(helperBundleIDs.joined(separator: "、"))；卸载成功后只按 helper Bundle ID 尝试 bootout，不按名称删除同名登录项。")
        }

        items.append(ApplicationUninstallItem(
            id: "app-\(application.path.path)",
            url: application.path,
            displayName: application.path.path,
            category: .applicationBundle,
            action: .moveToTrash,
            requiresAdmin: application.requiresAdmin,
            sizeBytes: application.sizeBytes,
            detail: application.requiresAdmin ? "需要管理员授权移动到当前用户废纸篓。" : nil
        ))

        let userItems = findUserRemnants(bundleID: application.bundleID, appName: application.displayName)
            .map { url -> ApplicationUninstallItem in
                if shouldProtectUserPath(url, bundleID: application.bundleID, appName: application.displayName) {
                    return makeItem(
                        url: url,
                        category: category(for: url, userLevel: true),
                        action: .reviewOnly,
                        reviewDetail: "高价值用户数据默认仅提示，不自动移到废纸篓。"
                    )
                }
                return makeItem(url: url, category: category(for: url, userLevel: true), action: .moveToTrash)
            }
        items.append(contentsOf: userItems)

        let userDiagnostics = diagnosticReportPaths(for: application, under: userLibrary().appendingPathComponent("Logs/DiagnosticReports", isDirectory: true))
            .map { makeItem(url: $0, category: .diagnosticReport, action: .moveToTrash) }
        items.append(contentsOf: userDiagnostics)

        let systemItems = findSystemRemnants(bundleID: application.bundleID, appName: application.displayName)
            .map { makeItem(url: $0, category: category(for: $0, userLevel: false), action: .reviewOnly, reviewDetail: "系统级残留默认只提示，不自动删除。") }
        items.append(contentsOf: systemItems)

        let systemDiagnostics = diagnosticReportPaths(for: application, under: URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true))
            .map { makeItem(url: $0, category: .diagnosticReport, action: .reviewOnly, reviewDetail: "系统级诊断报告默认只提示，不自动删除。") }
        items.append(contentsOf: systemDiagnostics)

        if isReverseDNSBundleID(application.bundleID) {
            items.append(contentsOf: [
                ApplicationUninstallItem(
                    id: "launchservices-\(application.id)",
                    url: nil,
                    displayName: "刷新 LaunchServices 和目标用户 LaunchAgent 状态",
                    category: .launchServices,
                    action: .command,
                    requiresAdmin: false,
                    sizeBytes: 0,
                    detail: "仅在应用本体移到废纸篓成功后执行。"
                ),
                ApplicationUninstallItem(
                    id: "dock-\(application.bundleID)",
                    url: nil,
                    displayName: "从 Dock 移除目标应用条目",
                    category: .dockEntry,
                    action: .command,
                    requiresAdmin: false,
                    sizeBytes: 0,
                    detail: "会改写 Dock 配置并重启 Dock。"
                )
            ])
        }
        if !helperBundleIDs.isEmpty {
            items.append(ApplicationUninstallItem(
                id: "helpers-\(helperBundleIDs.joined(separator: ","))",
                url: nil,
                displayName: "bootout 登录项 helper：\(helperBundleIDs.joined(separator: "、"))",
                category: .loginItem,
                action: .command,
                requiresAdmin: false,
                sizeBytes: 0,
                detail: "仅在应用本体移到废纸篓成功后执行。"
            ))
        }

        let uniqueItems = dedupeItems(items).filter { item in
            guard item.action == .moveToTrash, let url = item.url else { return true }
            let isPlannedAppBundle = url.standardizedFileURL.path == application.path.standardizedFileURL.path
            return validateDeletionPath(url, allowApplicationBundle: isPlannedAppBundle)
        }

        let recoverable = uniqueItems
            .filter { $0.action == .moveToTrash }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        let reviewOnly = uniqueItems
            .filter { $0.action == .reviewOnly }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }

        return ApplicationUninstallPlan(
            id: UUID(),
            application: application,
            items: uniqueItems,
            warnings: warnings,
            blockedReason: nil,
            estimatedRecoverableBytes: recoverable,
            estimatedReviewOnlyBytes: reviewOnly
        )
    }

    @discardableResult
    func execute(
        plan: ApplicationUninstallPlan,
        options: ExecutionOptions = .commit(),
        progress: ((Progress) -> Void)? = nil
    ) throws -> ApplicationUninstallResult {
        if let blockedReason = plan.blockedReason {
            throw ApplicationUninstallerError.blocked(blockedReason)
        }

        let runID = UUID()
        try appendAuditEvent(
            runID: runID,
            batchID: options.batchID,
            mode: options.mode,
            plan: plan,
            item: nil,
            status: "started",
            message: "开始\(options.mode == .dryRun ? " dry-run" : "卸载")",
            path: plan.application.path
        )
        for item in plan.items {
            try appendAuditEvent(
                runID: runID,
                batchID: options.batchID,
                mode: options.mode,
                plan: plan,
                item: item,
                status: "planned",
                message: item.action.rawValue,
                path: item.url
            )
        }

        if options.isDryRun {
            return dryRunResult(plan: plan, runID: runID, options: options)
        }

        let invalidTrashItems = invalidTrashItems(for: plan)
        if !invalidTrashItems.isEmpty {
            var failedResults: [ApplicationUninstallResult.ItemResult] = []
            for (failedItem, error) in invalidTrashItems {
                try? appendAuditEvent(
                    runID: runID,
                    batchID: options.batchID,
                    mode: options.mode,
                    plan: plan,
                    item: failedItem,
                    status: "failed",
                    message: error.localizedDescription,
                    path: failedItem.url
                )
                failedResults.append(ApplicationUninstallResult.ItemResult(
                    item: failedItem,
                    success: false,
                    message: error.localizedDescription
                ))
            }
            return ApplicationUninstallResult(
                plan: plan,
                itemResults: failedResults,
                warnings: plan.warnings + ["预检失败，未执行外部命令或移动文件：发现 \(failedResults.count) 个不安全路径。"],
                recoveredBytes: 0
            )
        }

        do {
            try prepareTrashDirectoryIfNeeded(for: plan)
        } catch {
            let failedItem = plan.trashItems.first ?? ApplicationUninstallItem(
                id: "preflight-\(plan.application.id)",
                url: plan.application.path,
                displayName: plan.application.path.path,
                category: .applicationBundle,
                action: .moveToTrash,
                requiresAdmin: plan.application.requiresAdmin,
                sizeBytes: plan.application.sizeBytes,
                detail: nil
            )
            try? appendAuditEvent(
                runID: runID,
                batchID: options.batchID,
                mode: options.mode,
                plan: plan,
                item: failedItem,
                status: "failed",
                message: error.localizedDescription,
                path: failedItem.url
            )
            return ApplicationUninstallResult(
                plan: plan,
                itemResults: [
                    ApplicationUninstallResult.ItemResult(item: failedItem, success: false, message: error.localizedDescription)
                ],
                warnings: plan.warnings + ["预检失败，未执行外部命令或移动文件：\(error.localizedDescription)"],
                recoveredBytes: 0
            )
        }

        progress?(Progress(title: "准备卸载", detail: plan.application.displayName))
        var results: [ApplicationUninstallResult.ItemResult] = []
        var recoveredBytes: Int64 = 0
        var warnings = plan.warnings

        var appBundleRemovedByHomebrew = false
        for commandItem in plan.commandItems where commandPhase(for: commandItem) == .beforeTrash {
            if commandItem.category == .homebrew, let cask = plan.application.homebrewCask {
                progress?(Progress(title: "Homebrew 卸载", detail: cask))
                let brewResult: HomebrewUninstallOutcome
                do {
                    try appendAuditEvent(
                        runID: runID,
                        batchID: options.batchID,
                        mode: options.mode,
                        plan: plan,
                        item: commandItem,
                        status: "command-started",
                        message: "brew uninstall --cask --zap \(cask)",
                        path: nil
                    )
                    brewResult = uninstallHomebrewCask(cask, appPath: plan.application.path)
                } catch {
                    brewResult = HomebrewUninstallOutcome(
                        success: false,
                        message: "审计日志写入失败，已拒绝执行 Homebrew 命令：\(error.localizedDescription)",
                        state: .unknown(error.localizedDescription)
                    )
                }
                if brewResult.success {
                    appBundleRemovedByHomebrew = !fileManager.fileExists(atPath: plan.application.path.path)
                } else {
                    warnings.append(brewResult.message)
                }
                try? appendAuditEvent(
                    runID: runID,
                    batchID: options.batchID,
                    mode: options.mode,
                    plan: plan,
                    item: commandItem,
                    status: brewResult.success ? "command-ok" : "command-failed",
                    message: brewResult.message,
                    path: nil
                )
                results.append(ApplicationUninstallResult.ItemResult(
                    item: commandItem,
                    success: brewResult.success,
                    message: brewResult.message
                ))
                if !brewResult.success {
                    switch brewResult.state {
                    case .installed:
                        return ApplicationUninstallResult(
                            plan: plan,
                            itemResults: results,
                            warnings: warnings + ["Homebrew 仍记录该 cask，已拒绝手动删除 App，避免包管理状态损坏。"],
                            recoveredBytes: recoveredBytes
                        )
                    case .unknown(let message):
                        return ApplicationUninstallResult(
                            plan: plan,
                            itemResults: results,
                            warnings: warnings + ["无法确认 Homebrew cask 状态（\(message)），已拒绝手动删除 App。"],
                            recoveredBytes: recoveredBytes
                        )
                    case .notInstalled:
                        break
                    }
                }
                continue
            }

            do {
                try appendAuditEvent(
                    runID: runID,
                    batchID: options.batchID,
                    mode: options.mode,
                    plan: plan,
                    item: commandItem,
                    status: "command-started",
                    message: commandItem.displayName,
                    path: nil
                )
                let commandResult = executePlannedCommand(commandItem, plan: plan)
                try? appendAuditEvent(
                    runID: runID,
                    batchID: options.batchID,
                    mode: options.mode,
                    plan: plan,
                    item: commandItem,
                    status: commandResult.success ? "command-ok" : "command-failed",
                    message: commandResult.message,
                    path: nil
                )
                results.append(commandResult)
                if !commandResult.success {
                    warnings.append(commandResult.message)
                    if commandItem.id.hasPrefix("quit-") {
                        return ApplicationUninstallResult(
                            plan: plan,
                            itemResults: results,
                            warnings: warnings + ["运行中的应用未正常退出，已停止卸载；未移动任何文件。"],
                            recoveredBytes: recoveredBytes
                        )
                    }
                }
            } catch {
                let message = "审计日志写入失败，已拒绝执行命令：\(error.localizedDescription)"
                results.append(ApplicationUninstallResult.ItemResult(item: commandItem, success: false, message: message))
                warnings.append(message)
                if commandItem.id.hasPrefix("quit-") {
                    return ApplicationUninstallResult(
                        plan: plan,
                        itemResults: results,
                        warnings: warnings + ["运行中应用退出前置命令未执行，已停止卸载；未移动任何文件。"],
                        recoveredBytes: recoveredBytes
                    )
                }
            }
        }

        for item in plan.items {
            guard item.action == .moveToTrash else {
                if item.action == .reviewOnly {
                    results.append(ApplicationUninstallResult.ItemResult(item: item, success: true, message: "仅提示，未删除"))
                    try? appendAuditEvent(
                        runID: runID,
                        batchID: options.batchID,
                        mode: options.mode,
                        plan: plan,
                        item: item,
                        status: "review-only",
                        message: "仅提示，未删除",
                        path: item.url
                    )
                }
                continue
            }
            if appBundleRemovedByHomebrew && item.category == .applicationBundle {
                results.append(ApplicationUninstallResult.ItemResult(item: item, success: true, message: "已由 Homebrew 移除"))
                recoveredBytes += item.sizeBytes
                try? appendAuditEvent(
                    runID: runID,
                    batchID: options.batchID,
                    mode: options.mode,
                    plan: plan,
                    item: item,
                    status: "removed-by-homebrew",
                    message: "已由 Homebrew 移除",
                    path: item.url
                )
                continue
            }
            guard let url = item.url else { continue }
            progress?(Progress(title: "移到废纸篓", detail: url.lastPathComponent))
            do {
                try appendAuditEvent(
                    runID: runID,
                    batchID: options.batchID,
                    mode: options.mode,
                    plan: plan,
                    item: item,
                    status: "trash-started",
                    message: "准备移到废纸篓",
                    path: url
                )
                try moveToTrash(item, plan: plan)
                results.append(ApplicationUninstallResult.ItemResult(item: item, success: true, message: "已移到废纸篓"))
                recoveredBytes += item.sizeBytes
                try? appendAuditEvent(
                    runID: runID,
                    batchID: options.batchID,
                    mode: options.mode,
                    plan: plan,
                    item: item,
                    status: "trashed",
                    message: "已移到废纸篓",
                    path: url
                )
                AppLogger.shared.info("应用卸载：已移到废纸篓 \(url.path)")
            } catch {
                results.append(ApplicationUninstallResult.ItemResult(item: item, success: false, message: error.localizedDescription))
                try? appendAuditEvent(
                    runID: runID,
                    batchID: options.batchID,
                    mode: options.mode,
                    plan: plan,
                    item: item,
                    status: "failed",
                    message: error.localizedDescription,
                    path: url
                )
                AppLogger.shared.error("应用卸载失败：\(url.path) \(error.localizedDescription)")
            }
        }

        let appBundleSucceeded = results.contains { $0.item.category == .applicationBundle && $0.success }
            || appBundleRemovedByHomebrew
        if appBundleSucceeded {
            for commandItem in plan.commandItems where commandPhase(for: commandItem) == .afterApplicationBundle {
                try? appendAuditEvent(
                    runID: runID,
                    batchID: options.batchID,
                    mode: options.mode,
                    plan: plan,
                    item: commandItem,
                    status: "command-started",
                    message: commandItem.displayName,
                    path: nil
                )
                let commandResult = executePlannedCommand(commandItem, plan: plan)
                results.append(commandResult)
                try? appendAuditEvent(
                    runID: runID,
                    batchID: options.batchID,
                    mode: options.mode,
                    plan: plan,
                    item: commandItem,
                    status: commandResult.success ? "command-ok" : "command-failed",
                    message: commandResult.message,
                    path: nil
                )
                if !commandResult.success {
                    warnings.append(commandResult.message)
                }
            }

            if backgroundItemsMayRemain(bundleID: plan.application.bundleID) {
                warnings.append("系统后台项目数据库仍包含 \(plan.application.bundleID)，请到“系统设置 > 通用 > 登录项与扩展”中确认残留项。")
            }
            let systemExtensions = systemExtensionsForBundle(plan.application.bundleID)
            if !systemExtensions.isEmpty {
                warnings.append("检测到系统扩展残留：\(systemExtensions.map(\.lastPathComponent).joined(separator: "、"))，需要在系统设置中手动移除。")
            }
        }

        return ApplicationUninstallResult(
            plan: plan,
            itemResults: results,
            warnings: warnings,
            recoveredBytes: recoveredBytes
        )
    }

    func uninstallHistory(limit: Int = 200) -> [ApplicationUninstallAuditEntry] {
        guard limit > 0,
              let data = try? Data(contentsOf: environment.uninstallAuditLogURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit * 3)
        let entries = lines.compactMap { line -> ApplicationUninstallAuditEntry? in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(ApplicationUninstallAuditEntry.self, from: lineData)
        }
        return Array(entries.suffix(limit).reversed())
    }

    func prepareAdministratorAuthorizationIfNeeded(for plans: [ApplicationUninstallPlan]) {
        let needsAdmin = plans.contains { plan in
            plan.trashItems.contains { $0.requiresAdmin }
        }
        guard needsAdmin,
              environment.runExternalCommands,
              let osascript = firstExecutable(named: "osascript", in: ["/usr/bin"]) else {
            return
        }
        let script = "do shell script \"/usr/bin/true\" with administrator privileges"
        _ = try? runner.run(executable: osascript, arguments: ["-e", script], timeout: 60)
    }

    func recordBatchAudit(batchID: UUID, mode: ExecutionOptions.Mode, status: String, message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record: [String: Any] = [
            "time": formatter.string(from: Date()),
            "batchID": batchID.uuidString,
            "mode": mode.rawValue,
            "status": status,
            "message": message
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            do {
                let logURL = environment.uninstallAuditLogURL
                try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                var line = data
                line.append(Data("\n".utf8))
                if fileManager.fileExists(atPath: logURL.path) {
                    let handle = try FileHandle(forWritingTo: logURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: logURL, options: .atomic)
                }
            } catch {
                AppLogger.shared.error("应用卸载审计写入失败：\(error.localizedDescription)")
            }
        }
    }

    private func dryRunResult(
        plan: ApplicationUninstallPlan,
        runID: UUID,
        options: ExecutionOptions
    ) -> ApplicationUninstallResult {
        var results: [ApplicationUninstallResult.ItemResult] = []
        for item in plan.items {
            let message: String
            let success: Bool
            switch item.action {
            case .command:
                message = "dry-run：将执行 \(item.displayName)"
                success = true
            case .moveToTrash:
                if let url = item.url {
                    let safe = validateDeletionPath(url, allowApplicationBundle: isApplicationBundleItem(item, in: plan))
                    success = safe
                    message = safe ? "dry-run：将移到废纸篓" : "dry-run：路径被保护，commit 时会拒绝"
                } else {
                    success = false
                    message = "dry-run：缺少路径，commit 时会拒绝"
                }
            case .reviewOnly:
                message = "dry-run：仅提示，不删除"
                success = true
            case .skipped:
                message = "dry-run：跳过"
                success = true
            }
            results.append(ApplicationUninstallResult.ItemResult(item: item, success: success, message: message))
            try? appendAuditEvent(
                runID: runID,
                batchID: options.batchID,
                mode: options.mode,
                plan: plan,
                item: item,
                status: "dry-run",
                message: message,
                path: item.url
            )
        }
        return ApplicationUninstallResult(
            plan: plan,
            itemResults: results,
            warnings: plan.warnings + ["dry-run 未执行任何外部命令，也未移动文件。"],
            recoveredBytes: 0
        )
    }

    private func appendAuditEvent(
        runID: UUID,
        batchID: UUID,
        mode: ExecutionOptions.Mode,
        plan: ApplicationUninstallPlan,
        item: ApplicationUninstallItem?,
        status: String,
        message: String,
        path: URL?
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var record: [String: Any] = [
            "time": formatter.string(from: Date()),
            "runID": runID.uuidString,
            "batchID": batchID.uuidString,
            "mode": mode.rawValue,
            "status": status,
            "app": plan.application.displayName,
            "bundleID": plan.application.bundleID,
            "appPath": plan.application.path.path,
            "message": message
        ]
        if let item {
            record["itemID"] = item.id
            record["itemCategory"] = item.category.rawValue
            record["itemAction"] = item.action.rawValue
            record["itemDisplayName"] = item.displayName
            record["itemSizeBytes"] = item.sizeBytes
        }
        if let path {
            record["path"] = path.standardizedFileURL.path
        }

        let logURL = environment.uninstallAuditLogURL
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(Data("\n".utf8))
        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: logURL, options: .atomic)
        }
    }

    private func invalidTrashItems(for plan: ApplicationUninstallPlan) -> [(ApplicationUninstallItem, ApplicationUninstallerError)] {
        plan.trashItems.compactMap { item in
            guard let url = item.url else {
                return (item, ApplicationUninstallerError.invalidPath(item.displayName))
            }
            guard validateDeletionPath(url, allowApplicationBundle: isApplicationBundleItem(item, in: plan)) else {
                return (item, ApplicationUninstallerError.invalidPath(url.path))
            }
            return nil
        }
    }

    private func prepareTrashDirectoryIfNeeded(for plan: ApplicationUninstallPlan) throws {
        let needsConfiguredTrash = !environment.useSystemTrash || plan.trashItems.contains(where: { item in
            item.requiresAdmin && (item.url.map(pathExists) ?? false)
        })
        if needsConfiguredTrash, plan.trashItems.contains(where: { item in
            item.url.map(pathExists) ?? false
        }) {
            try prepareConfiguredTrashDirectory()
        }
    }

    private func isApplicationBundleItem(_ item: ApplicationUninstallItem, in plan: ApplicationUninstallPlan) -> Bool {
        guard item.category == .applicationBundle, let url = item.url else { return false }
        return url.standardizedFileURL.path == plan.application.path.standardizedFileURL.path
    }

    private func commandPhase(for item: ApplicationUninstallItem) -> CommandPhase {
        if item.id.hasPrefix("homebrew-") || item.id.hasPrefix("quit-") {
            return .beforeTrash
        }
        return .afterApplicationBundle
    }

    private func executePlannedCommand(
        _ item: ApplicationUninstallItem,
        plan: ApplicationUninstallPlan
    ) -> ApplicationUninstallResult.ItemResult {
        let message: String
        let success: Bool
        switch item.id {
        case _ where item.id.hasPrefix("quit-"):
            success = terminateApplication(plan.application)
            message = success ? "已请求应用正常退出" : "应用未响应正常退出；未执行强制结束"
        case _ where item.id.hasPrefix("launchservices-"):
            stopLaunchServices(bundleID: plan.application.bundleID, appPath: plan.application.path)
            unregisterAppBundle(plan.application.path)
            refreshLaunchServices()
            success = true
            message = "已处理 LaunchServices 记录"
        case _ where item.id.hasPrefix("helpers-"):
            let rawIDs = String(item.id.dropFirst("helpers-".count))
            let helperIDs = rawIDs.split(separator: ",").map(String.init).filter(isReverseDNSBundleID)
            bootoutLoginItemHelpers(helperIDs)
            success = true
            message = helperIDs.isEmpty ? "没有可处理的 helper Bundle ID" : "已 bootout 登录项 helper"
        case _ where item.id.hasPrefix("dock-"):
            removeAppsFromDock(appPath: plan.application.path, bundleID: plan.application.bundleID)
            success = true
            message = "已处理 Dock 条目"
        default:
            success = false
            message = "未知命令项，已拒绝执行：\(item.displayName)"
        }
        return ApplicationUninstallResult.ItemResult(item: item, success: success, message: message)
    }

    private func applicationSearchDirectories() -> [URL] {
        var directories = environment.applicationDirectories
        if let volumeNames = try? fileManager.contentsOfDirectory(atPath: environment.volumesDirectory.path) {
            for volumeName in volumeNames {
                let volumeApplications = environment.volumesDirectory
                    .appendingPathComponent(volumeName, isDirectory: true)
                    .appendingPathComponent("Applications", isDirectory: true)
                if isReadableDirectory(volumeApplications),
                   !directories.contains(where: { sameFile($0, volumeApplications) }) {
                    directories.append(volumeApplications)
                }
            }
        }
        return directories.filter(isReadableDirectory)
    }

    private func appBundles(in directory: URL, maxDepth: Int, deadline: Date) -> [URL] {
        guard isReadableDirectory(directory),
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
              ) else {
            return []
        }

        var urls: [URL] = []
        let rootDepth = directory.pathComponents.count
        for case let url as URL in enumerator {
            if Date() >= deadline {
                AppLogger.shared.info("应用卸载：应用扫描超时，停止继续枚举 \(directory.path)")
                break
            }
            let depth = url.pathComponents.count - rootDepth
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "app" {
                urls.append(url)
                enumerator.skipDescendants()
            }
        }
        return urls
    }

    private func packageReceiptAppPaths(deadline: Date) -> [URL] {
        guard environment.runExternalCommands,
              let pkgutil = firstExecutable(named: "pkgutil", in: ["/usr/sbin", "/usr/bin"]) else {
            return []
        }
        if let cached = readPackageReceiptAppPathCache() {
            return cached
        }
        let packages = (try? runner.run(executable: pkgutil, arguments: ["--pkgs"], timeout: 12))?.stdout
            .split(separator: "\n")
            .map(String.init) ?? []
        guard !packages.isEmpty else { return [] }

        var paths: Set<String> = []
        for package in packages.prefix(400) {
            guard Date() < deadline else {
                AppLogger.shared.info("应用卸载：pkg receipt 扫描超时，停止继续解析")
                break
            }
            guard let info = try? runner.run(executable: pkgutil, arguments: ["--pkg-info-plist", package], timeout: 2),
                  let data = info.stdout.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                continue
            }
            let location = (plist["install-location"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
            guard let files = try? runner.run(executable: pkgutil, arguments: ["--files", package], timeout: 2) else { continue }
            for line in files.stdout.split(separator: "\n").map(String.init) where line.hasSuffix(".app") || line.contains(".app/Contents/Info.plist") {
                let appPathPart = line.components(separatedBy: ".app").first.map { "\($0).app" } ?? line
                let appPath: String
                if appPathPart.hasPrefix("/") {
                    appPath = appPathPart
                } else {
                    appPath = URL(fileURLWithPath: location, isDirectory: true).appendingPathComponent(appPathPart).path
                }
                let appURL = URL(fileURLWithPath: appPath, isDirectory: true).standardizedFileURL
                if fileManager.fileExists(atPath: appURL.path),
                   appURL.pathExtension == "app",
                   receiptApplicationPathIsAllowlisted(appURL),
                   !shouldSkipAppPath(appURL) {
                    paths.insert(appURL.path)
                }
            }
        }
        let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        writePackageReceiptAppPathCache(urls)
        return urls
    }

    private func readPackageReceiptAppPathCache() -> [URL]? {
        guard environment.pkgReceiptCacheTTL > 0,
              let data = try? Data(contentsOf: environment.pkgReceiptCacheURL),
              let cache = try? JSONDecoder().decode(PackageReceiptAppCache.self, from: data),
              Date().timeIntervalSince(cache.createdAt) <= environment.pkgReceiptCacheTTL else {
            return nil
        }
        let urls = cache.paths
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter {
                fileManager.fileExists(atPath: $0.path)
                    && $0.pathExtension == "app"
                    && receiptApplicationPathIsAllowlisted($0)
                    && !shouldSkipAppPath($0)
            }
        return urls
    }

    private func writePackageReceiptAppPathCache(_ urls: [URL]) {
        guard environment.pkgReceiptCacheTTL > 0 else { return }
        let cache = PackageReceiptAppCache(createdAt: Date(), paths: urls.map { $0.standardizedFileURL.path }.sorted())
        guard let data = try? JSONEncoder().encode(cache) else { return }
        do {
            try fileManager.createDirectory(at: environment.pkgReceiptCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: environment.pkgReceiptCacheURL, options: .atomic)
        } catch {
            AppLogger.shared.info("应用卸载：pkg receipt 缓存写入失败 \(error.localizedDescription)")
        }
    }

    private func readApplicationMetadataCache() -> ApplicationMetadataCache {
        guard environment.appMetadataCacheTTL > 0,
              let data = try? Data(contentsOf: environment.appMetadataCacheURL),
              let cache = try? JSONDecoder().decode(ApplicationMetadataCache.self, from: data),
              Date().timeIntervalSince(cache.createdAt) <= environment.appMetadataCacheTTL else {
            return ApplicationMetadataCache(createdAt: Date(), entries: [:])
        }
        return cache
    }

    private func writeApplicationMetadataCache(_ cache: ApplicationMetadataCache, validPaths: Set<String>) {
        guard environment.appMetadataCacheTTL > 0 else { return }
        let pruned = cache.entries.filter { path, _ in
            validPaths.contains(path)
        }
        let updated = ApplicationMetadataCache(createdAt: Date(), entries: pruned)
        guard let data = try? JSONEncoder().encode(updated) else { return }
        do {
            try fileManager.createDirectory(at: environment.appMetadataCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: environment.appMetadataCacheURL, options: .atomic)
        } catch {
            AppLogger.shared.info("应用卸载：应用元数据缓存写入失败 \(error.localizedDescription)")
        }
    }

    private func resolveApplication(
        _ url: URL,
        cache: inout ApplicationMetadataCache,
        cacheChanged: inout Bool
    ) -> InstalledApplication? {
        let normalized = url.standardizedFileURL
        let identity = pathIdentity(normalized)
        let modificationDate = resourceDate(normalized, key: .contentModificationDateKey)
        if let cached = cache.entries[normalized.path],
           cached.identity == identity,
           cached.contentModificationDate == modificationDate {
            let appName = url.deletingPathExtension().lastPathComponent
            let plist = infoPlist(at: url)
            let liveBundleID = sanitizeMetadata(plist?["CFBundleIdentifier"] as? String) ?? "unknown"
            let liveDisplayName = resolveDisplayName(appURL: url, appName: appName, plist: plist)
            let liveVersion = sanitizeMetadata(plist?["CFBundleShortVersionString"] as? String)
            let isBackgroundOnly = boolValue(plist?["LSBackgroundOnly"])
            let isOneDrive = liveBundleID.hasPrefix("com.microsoft.OneDrive")
                && (url.path == "/Applications/OneDrive.app" || url.path == environment.homeDirectory.appendingPathComponent("Applications/OneDrive.app").path)
            let protectedReason = protectionReason(bundleID: liveBundleID, appPath: url, backgroundOnly: isBackgroundOnly && !isOneDrive)
            let officialVendor = officialUninstallerVendor(bundleID: liveBundleID, appName: liveDisplayName, appPath: url)
            let cask = detectHomebrewCask(for: url)
            let source: InstalledApplication.Source = cask == nil ? .applicationBundle : .homebrewCask
            let requiresAdmin = needsAdminToRemove(url)
            return InstalledApplication(
                id: identity,
                displayName: liveDisplayName,
                bundleID: liveBundleID,
                version: liveVersion ?? cached.version,
                path: normalized,
                source: source,
                homebrewCask: cask,
                sizeBytes: cached.sizeBytes,
                lastUsedDate: cached.lastUsedDate,
                requiresAdmin: requiresAdmin,
                protectedReason: protectedReason,
                officialUninstallerVendor: officialVendor,
                isRunning: isApplicationRunning(bundleID: liveBundleID, appName: liveDisplayName, appPath: normalized)
            )
        }

        let appName = url.deletingPathExtension().lastPathComponent
        let plist = infoPlist(at: url)
        let bundleID = sanitizeMetadata(plist?["CFBundleIdentifier"] as? String) ?? "unknown"
        let displayName = resolveDisplayName(appURL: url, appName: appName, plist: plist)
        let version = sanitizeMetadata(plist?["CFBundleShortVersionString"] as? String)
        let isBackgroundOnly = boolValue(plist?["LSBackgroundOnly"])
        let isOneDrive = bundleID.hasPrefix("com.microsoft.OneDrive")
            && (url.path == "/Applications/OneDrive.app" || url.path == environment.homeDirectory.appendingPathComponent("Applications/OneDrive.app").path)
        let protectedReason = protectionReason(bundleID: bundleID, appPath: url, backgroundOnly: isBackgroundOnly && !isOneDrive)
        let officialVendor = officialUninstallerVendor(bundleID: bundleID, appName: displayName, appPath: url)
        let cask = detectHomebrewCask(for: url)
        let source: InstalledApplication.Source = cask == nil ? .applicationBundle : .homebrewCask
        let size = pathSizeBytes(url)
        let lastUsed = resourceDate(url, key: .contentAccessDateKey)
        let requiresAdmin = needsAdminToRemove(url)
        let running = isApplicationRunning(bundleID: bundleID, appName: displayName, appPath: url)
        cache.entries[normalized.path] = ApplicationMetadataCacheEntry(
            path: normalized.path,
            identity: identity,
            contentModificationDate: modificationDate,
            displayName: displayName,
            bundleID: bundleID,
            version: version,
            source: source.rawValue,
            homebrewCask: cask,
            sizeBytes: size,
            lastUsedDate: lastUsed,
            requiresAdmin: requiresAdmin,
            protectedReason: protectedReason,
            officialUninstallerVendor: officialVendor
        )
        cacheChanged = true
        return InstalledApplication(
            id: identity,
            displayName: displayName,
            bundleID: bundleID,
            version: version,
            path: url,
            source: source,
            homebrewCask: cask,
            sizeBytes: size,
            lastUsedDate: lastUsed,
            requiresAdmin: requiresAdmin,
            protectedReason: protectedReason,
            officialUninstallerVendor: officialVendor,
            isRunning: running
        )
    }

    private func dedupeApplications(_ apps: [InstalledApplication]) -> [InstalledApplication] {
        var keptByBundle: [String: InstalledApplication] = [:]
        var unknown: [InstalledApplication] = []
        for app in apps {
            guard app.bundleID != "unknown", isReverseDNSBundleID(app.bundleID) else {
                unknown.append(app)
                continue
            }
            if let existing = keptByBundle[app.bundleID] {
                if appRank(app) < appRank(existing) {
                    keptByBundle[app.bundleID] = app
                }
            } else {
                keptByBundle[app.bundleID] = app
            }
        }
        return Array(keptByBundle.values) + unknown
    }

    private func appRank(_ app: InstalledApplication) -> Int {
        let path = app.path.standardizedFileURL.path
        if path.hasPrefix("/Applications/") && path.pathDepth == 2 { return 0 }
        let homeApps = environment.homeDirectory.appendingPathComponent("Applications", isDirectory: true).path + "/"
        if path.hasPrefix(homeApps) && path.pathDepth == homeApps.pathDepth { return 1 }
        if path.hasPrefix("/Applications/") { return 2 }
        if path.hasPrefix(homeApps) { return 3 }
        return 4
    }

    private func shouldSkipAppPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let parent = url.deletingLastPathComponent().path
        if parent.contains(".app/") || parent.hasSuffix(".app") {
            return true
        }
        if isSymbolicLink(url),
           let target = resolvedSymlinkTarget(url),
           isCriticalSystemPath(target.standardizedFileURL.path) {
            return true
        }
        return path.isEmpty
    }

    private func resolveDisplayName(appURL: URL, appName: String, plist: [String: Any]?) -> String {
        let fileDisplayName = fileManager.displayName(atPath: appURL.path)
        let metadataName = [fileDisplayName, plist?["CFBundleDisplayName"] as? String, plist?["CFBundleName"] as? String]
            .compactMap(sanitizePathComponentName)
            .first { !$0.hasPrefix("/") && $0 != appName && $0 != "\(appName).app" }
        var displayName = metadataName ?? sanitizePathComponentName(appName) ?? appName
        if displayName.hasSuffix(".app") {
            displayName.removeLast(4)
        }
        if appName.hasPrefix(displayName), appName != displayName, appName.contains(where: \.isNumber) {
            displayName = appName
        }
        return displayName.replacingOccurrences(of: "|", with: "-")
    }

    private func infoPlist(at appURL: URL) -> [String: Any]? {
        let url = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    private func findUserRemnants(bundleID: String, appName: String) -> [URL] {
        guard let safeAppName = sanitizePathComponentName(appName),
              bundleID != "unknown" || safeAppName.count >= 2 else { return [] }
        let home = environment.homeDirectory
        let library = userLibrary()
        let variants = nameVariants(safeAppName)
        let bundleIDValid = isReverseDNSBundleID(bundleID)
        var candidates: [URL] = []

        if safeAppName.count >= 2 {
            candidates += [
                library.appendingPathComponent("Application Support/\(safeAppName)"),
                library.appendingPathComponent("Caches/\(safeAppName)"),
                library.appendingPathComponent("Logs/\(safeAppName)"),
                library.appendingPathComponent("Preferences/\(safeAppName)"),
                library.appendingPathComponent("Preferences/\(safeAppName).plist"),
                library.appendingPathComponent("Saved Application State/\(safeAppName).savedState"),
                library.appendingPathComponent("Services/\(safeAppName).workflow"),
                library.appendingPathComponent("QuickLook/\(safeAppName).qlgenerator"),
                library.appendingPathComponent("Internet Plug-Ins/\(safeAppName).plugin"),
                library.appendingPathComponent("Audio/Plug-Ins/Components/\(safeAppName).component"),
                library.appendingPathComponent("Audio/Plug-Ins/VST/\(safeAppName).vst"),
                library.appendingPathComponent("Audio/Plug-Ins/VST3/\(safeAppName).vst3"),
                library.appendingPathComponent("Audio/Plug-Ins/Digidesign/\(safeAppName).dpm"),
                library.appendingPathComponent("PreferencePanes/\(safeAppName).prefPane"),
                library.appendingPathComponent("Input Methods/\(safeAppName).app"),
                library.appendingPathComponent("Screen Savers/\(safeAppName).saver"),
                library.appendingPathComponent("Frameworks/\(safeAppName).framework"),
                library.appendingPathComponent("Contextual Menu Items/\(safeAppName).plugin"),
                library.appendingPathComponent("Spotlight/\(safeAppName).mdimporter"),
                library.appendingPathComponent("ColorPickers/\(safeAppName).colorPicker"),
                library.appendingPathComponent("Workflows/\(safeAppName).workflow"),
                home.appendingPathComponent(".config/\(safeAppName)"),
                home.appendingPathComponent(".cache/\(safeAppName)"),
                home.appendingPathComponent(".cache/\(variants.lowercase)"),
                home.appendingPathComponent(".local/share/\(safeAppName)"),
                home.appendingPathComponent(".\(safeAppName)"),
                home.appendingPathComponent(".\(safeAppName)rc"),
                library.appendingPathComponent("Address Book Plug-Ins/\(safeAppName).bundle"),
                library.appendingPathComponent("Accessibility/\(safeAppName).bundle"),
                library.appendingPathComponent("Mail/Bundles/\(safeAppName).mailbundle")
            ]
        }

        if bundleIDValid {
            candidates += [
                library.appendingPathComponent("Application Support/\(bundleID)"),
                library.appendingPathComponent("Caches/\(bundleID)"),
                library.appendingPathComponent("Logs/\(bundleID)"),
                library.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
                library.appendingPathComponent("Containers/\(bundleID)"),
                library.appendingPathComponent("WebKit/\(bundleID)"),
                library.appendingPathComponent("WebKit/com.apple.WebKit.WebContent/\(bundleID)"),
                library.appendingPathComponent("HTTPStorages/\(bundleID)"),
                library.appendingPathComponent("HTTPStorages/\(bundleID).binarycookies"),
                library.appendingPathComponent("Cookies/\(bundleID).binarycookies"),
                library.appendingPathComponent("Application Scripts/\(bundleID)"),
                library.appendingPathComponent("Input Methods/\(bundleID).app"),
                library.appendingPathComponent("Autosave Information/\(bundleID)"),
                library.appendingPathComponent("SyncedPreferences/\(bundleID).plist"),
                library.appendingPathComponent("Preferences/\(bundleID).plist"),
                library.appendingPathComponent("Preferences/\(bundleID)")
            ]
        }

        if safeAppName.count > 3, safeAppName.contains(" ") {
            candidates += [
                library.appendingPathComponent("Application Support/\(variants.nospace)"),
                library.appendingPathComponent("Caches/\(variants.nospace)"),
                library.appendingPathComponent("Logs/\(variants.nospace)"),
                library.appendingPathComponent("Preferences/\(variants.nospace)"),
                library.appendingPathComponent("Preferences/\(variants.nospace).plist"),
                library.appendingPathComponent("Saved Application State/\(variants.nospace).savedState"),
                library.appendingPathComponent("Application Support/\(variants.underscore)"),
                library.appendingPathComponent("Application Support/\(variants.hyphen)"),
                library.appendingPathComponent("Preferences/\(variants.underscore)"),
                library.appendingPathComponent("Preferences/\(variants.underscore).plist"),
                library.appendingPathComponent("Preferences/\(variants.hyphen)"),
                library.appendingPathComponent("Preferences/\(variants.hyphen).plist"),
                home.appendingPathComponent(".config/\(variants.lowercaseNospace)"),
                home.appendingPathComponent(".config/\(variants.lowercaseHyphen)"),
                home.appendingPathComponent(".config/\(variants.lowercaseUnderscore)"),
                home.appendingPathComponent(".cache/\(variants.lowercaseNospace)"),
                home.appendingPathComponent(".cache/\(variants.lowercaseHyphen)"),
                home.appendingPathComponent(".cache/\(variants.lowercaseUnderscore)"),
                home.appendingPathComponent(".local/share/\(variants.lowercaseNospace)"),
                home.appendingPathComponent(".local/share/\(variants.lowercaseHyphen)"),
                home.appendingPathComponent(".local/share/\(variants.lowercaseUnderscore)")
            ]
        }

        if variants.baseName != safeAppName, variants.baseName.count > 2 {
            candidates += [
                library.appendingPathComponent("Application Support/\(variants.baseName)"),
                library.appendingPathComponent("Caches/\(variants.baseName)"),
                library.appendingPathComponent("Logs/\(variants.baseName)"),
                library.appendingPathComponent("Preferences/\(variants.baseName)"),
                library.appendingPathComponent("Preferences/\(variants.baseName).plist"),
                library.appendingPathComponent("Saved Application State/\(variants.baseName).savedState"),
                home.appendingPathComponent(".config/\(variants.baseLowercase)"),
                home.appendingPathComponent(".cache/\(variants.baseLowercase)"),
                home.appendingPathComponent(".local/share/\(variants.baseLowercase)"),
                home.appendingPathComponent(".\(variants.baseLowercase)")
            ]
        }

        if bundleIDValid, bundleID.hasPrefix("dev.zed.Zed-") {
            candidates += contents(of: library.appendingPathComponent("HTTPStorages"), matching: { $0.lastPathComponent.hasPrefix("dev.zed.Zed-") })
        }

        candidates = candidates.filter { pathExists($0) && !isCollapsedRoot($0) && !pathBelongsToIndependentCLI($0) }

        if bundleIDValid {
            candidates += contents(of: library.appendingPathComponent("Preferences/ByHost"), matching: {
                $0.pathExtension == "plist" && nameStartsWithBundleBoundary($0.lastPathComponent, bundleID)
            })
            candidates += contents(of: library.appendingPathComponent("LaunchAgents"), matching: {
                $0.lastPathComponent == "\(bundleID).plist" || $0.lastPathComponent.hasPrefix("\(bundleID).")
            })
            let nsURLSession = library.appendingPathComponent("Caches/com.apple.nsurlsessiond/Downloads/\(bundleID)")
            if pathExists(nsURLSession) { candidates.append(nsURLSession) }
            candidates += contents(of: library.appendingPathComponent("Group Containers"), matching: {
                nameHasBundleBoundary($0.lastPathComponent, bundleID)
            })
            for root in [
                library.appendingPathComponent("Application Scripts"),
                library.appendingPathComponent("Containers"),
                library.appendingPathComponent("Application Support/FileProvider")
            ] {
                candidates += contents(of: root, matching: { nameHasBundleBoundary($0.lastPathComponent, bundleID) })
            }
            candidates += recursiveContents(
                of: library.appendingPathComponent("Application Support/com.apple.sharedfilelist"),
                maxDepth: 4,
                matching: { $0.lastPathComponent == "\(bundleID).sfl4" }
            )
            candidates += vendorNestedPaths(bundleID: bundleID, appName: appName, roots: [
                library.appendingPathComponent("Application Support"),
                library.appendingPathComponent("Caches"),
                library.appendingPathComponent("Logs")
            ])
        }

        if appName.count >= 5, !isCommonLaunchAgentName(appName) {
            candidates += contents(of: library.appendingPathComponent("LaunchAgents"), matching: {
                $0.lastPathComponent.contains(appName) && $0.pathExtension == "plist"
            })
        }

        candidates += specialUserRemnants(bundleID: bundleID, appName: appName)

        return dedupeURLs(candidates)
    }

    private func findSystemRemnants(bundleID: String, appName: String) -> [URL] {
        let library = environment.systemLibraryDirectory
        let variants = nameVariants(appName)
        let bundleIDValid = isReverseDNSBundleID(bundleID)
        var candidates: [URL] = [
            library.appendingPathComponent("Application Support/\(appName)"),
            library.appendingPathComponent("Application Support/\(bundleID)"),
            library.appendingPathComponent("LaunchAgents/\(bundleID).plist"),
            library.appendingPathComponent("LaunchDaemons/\(bundleID).plist"),
            library.appendingPathComponent("Preferences/\(bundleID).plist"),
            library.appendingPathComponent("Preferences/\(appName)"),
            library.appendingPathComponent("Preferences/\(appName).plist"),
            library.appendingPathComponent("Receipts/\(bundleID).bom"),
            library.appendingPathComponent("Receipts/\(bundleID).plist"),
            library.appendingPathComponent("Frameworks/\(appName).framework"),
            library.appendingPathComponent("Internet Plug-Ins/\(appName).plugin"),
            library.appendingPathComponent("Input Methods/\(appName).app"),
            library.appendingPathComponent("Input Methods/\(bundleID).app"),
            library.appendingPathComponent("Audio/Plug-Ins/Components/\(appName).component"),
            library.appendingPathComponent("Audio/Plug-Ins/VST/\(appName).vst"),
            library.appendingPathComponent("Audio/Plug-Ins/VST3/\(appName).vst3"),
            library.appendingPathComponent("Audio/Plug-Ins/Digidesign/\(appName).dpm"),
            library.appendingPathComponent("QuickLook/\(appName).qlgenerator"),
            library.appendingPathComponent("PreferencePanes/\(appName).prefPane"),
            library.appendingPathComponent("Screen Savers/\(appName).saver"),
            library.appendingPathComponent("Caches/\(bundleID)"),
            library.appendingPathComponent("Caches/\(appName)"),
            library.appendingPathComponent("Extensions/\(appName).kext"),
            library.appendingPathComponent("StartupItems/\(appName)"),
            library.appendingPathComponent("Logs/\(appName)"),
            library.appendingPathComponent("Logs/\(bundleID)")
        ]

        if appName.count > 3, appName.contains(" ") {
            candidates += [
                library.appendingPathComponent("Application Support/\(variants.nospace)"),
                library.appendingPathComponent("Caches/\(variants.nospace)"),
                library.appendingPathComponent("Logs/\(variants.nospace)"),
                library.appendingPathComponent("Application Support/\(variants.underscore)"),
                library.appendingPathComponent("Application Support/\(variants.hyphen)"),
                library.appendingPathComponent("Preferences/\(variants.nospace)"),
                library.appendingPathComponent("Preferences/\(variants.nospace).plist"),
                library.appendingPathComponent("Preferences/\(variants.underscore)"),
                library.appendingPathComponent("Preferences/\(variants.underscore).plist"),
                library.appendingPathComponent("Preferences/\(variants.hyphen)"),
                library.appendingPathComponent("Preferences/\(variants.hyphen).plist"),
                library.appendingPathComponent("Caches/\(variants.hyphen)"),
                library.appendingPathComponent("Caches/\(variants.lowercaseHyphen)")
            ]
        }

        candidates = candidates.filter { pathExists($0) && !isCollapsedSystemRoot($0) }

        if bundleIDValid {
            for base in [
                library.appendingPathComponent("LaunchAgents"),
                library.appendingPathComponent("LaunchDaemons")
            ] {
                candidates += contents(of: base, matching: {
                    $0.lastPathComponent == "\(bundleID).plist" || $0.lastPathComponent.hasPrefix("\(bundleID).")
                })
            }
            candidates += contents(of: library.appendingPathComponent("PrivilegedHelperTools"), matching: {
                nameStartsWithBundleBoundary($0.lastPathComponent, bundleID)
            })
            candidates += contents(of: URL(fileURLWithPath: "/private/var/db/receipts", isDirectory: true), matching: {
                nameStartsWithBundleBoundary($0.lastPathComponent, bundleID)
            })
            candidates += receiptPayloadPaths(bundleID: bundleID)
            candidates += vendorNestedPaths(bundleID: bundleID, appName: appName, roots: [
                library.appendingPathComponent("Application Support"),
                library.appendingPathComponent("Caches"),
                library.appendingPathComponent("Logs")
            ])
        }

        if appName.count >= 5, !isCommonLaunchAgentName(appName) {
            for base in [
                library.appendingPathComponent("LaunchAgents"),
                library.appendingPathComponent("LaunchDaemons")
            ] {
                candidates += contents(of: base, matching: {
                    !$0.lastPathComponent.hasPrefix("com.apple.")
                        && $0.lastPathComponent.contains(appName)
                        && $0.pathExtension == "plist"
                })
            }
        }

        if !isCommonAppName(appName) {
            let helperVariants = [variants.lowercase, variants.lowercaseNospace, variants.lowercaseHyphen, variants.lowercaseUnderscore]
                .filter { $0.count >= 5 }
            candidates += contents(of: library.appendingPathComponent("PrivilegedHelperTools"), matching: {
                let lower = $0.lastPathComponent.lowercased()
                return !$0.lastPathComponent.hasPrefix("com.apple.")
                    && helperVariants.contains(where: { lower.contains($0) })
            })
        }

        candidates += sharedAppPaths(bundleID: bundleID, appName: appName, root: URL(fileURLWithPath: "/Users/Shared", isDirectory: true))
        if bundleID == "com.raycast.macos" {
            candidates += contents(of: library.appendingPathComponent("Application Support"), matching: {
                $0.lastPathComponent.localizedCaseInsensitiveContains("raycast")
            })
        }

        return dedupeURLs(candidates)
    }

    private func specialUserRemnants(bundleID: String, appName: String) -> [URL] {
        let library = userLibrary()
        var candidates: [URL] = []
        let lower = appName.lowercased()
        if lower.contains("android studio") || bundleID.lowercased().contains("android") {
            candidates += [
                environment.homeDirectory.appendingPathComponent(".android/cache", isDirectory: true),
                environment.homeDirectory.appendingPathComponent(".android/build-cache", isDirectory: true),
                environment.homeDirectory.appendingPathComponent(".android/breakpad", isDirectory: true)
            ].filter(pathExists)
            candidates += contents(of: library.appendingPathComponent("Caches/Google"), matching: {
                $0.lastPathComponent.hasPrefix("AndroidStudio")
            })
            candidates += contents(of: library.appendingPathComponent("Logs/Google"), matching: {
                $0.lastPathComponent.hasPrefix("AndroidStudio")
            })
        }
        if lower.contains("xcode") || bundleID.lowercased().contains("xcode") {
            candidates += [
                library.appendingPathComponent("Developer/Xcode/DerivedData"),
                library.appendingPathComponent("Developer/CoreSimulator/Caches")
            ].filter(pathExists)
            for platform in ["iOS", "macOS", "watchOS", "tvOS", "xrOS"] {
                let deviceSupport = library.appendingPathComponent("Developer/Xcode/\(platform) DeviceSupport", isDirectory: true)
                if pathExists(deviceSupport) {
                    candidates.append(deviceSupport)
                }
            }
        }
        if bundleID.lowercased().contains("jetbrains")
            || ["IntelliJ", "PyCharm", "WebStorm", "GoLand", "RubyMine", "PhpStorm", "CLion", "DataGrip", "Rider"].contains(where: appName.contains) {
            let prefixes = jetBrainsProductPrefixes(appName: appName, bundleID: bundleID)
            candidates += contents(of: library.appendingPathComponent("Caches/JetBrains"), matching: { url in
                prefixes.contains { url.lastPathComponent.hasPrefix($0) }
            })
            candidates += contents(of: library.appendingPathComponent("Logs/JetBrains"), matching: { url in
                prefixes.contains { url.lastPathComponent.hasPrefix($0) }
            })
        }
        if bundleID == "com.raycast.macos" {
            candidates += contents(of: library.appendingPathComponent("Application Support"), matching: {
                $0.lastPathComponent.localizedCaseInsensitiveContains("raycast")
            })
        }
        return candidates
    }

    private func makeItem(
        url: URL,
        category: ApplicationUninstallItem.Category,
        action: ApplicationUninstallItem.Action,
        reviewDetail: String? = nil
    ) -> ApplicationUninstallItem {
        ApplicationUninstallItem(
            id: "\(action.rawValue)-\(url.standardizedFileURL.path)",
            url: url.standardizedFileURL,
            displayName: url.standardizedFileURL.path.replacingOccurrences(of: environment.homeDirectory.path, with: "~"),
            category: category,
            action: action,
            requiresAdmin: needsAdminToRemove(url),
            sizeBytes: pathSizeBytes(url),
            detail: reviewDetail
        )
    }

    private func category(for url: URL, userLevel: Bool) -> ApplicationUninstallItem.Category {
        let path = url.path
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") { return .launchAgent }
        if path.contains("/Caches/") || path.contains("/.cache/") { return .cache }
        if path.contains("/Logs/") { return .logs }
        if path.contains("/Preferences/") || path.hasSuffix(".plist") { return .preferences }
        if path.contains("/Containers/") || path.contains("/Group Containers/") { return .container }
        if path.contains("/WebKit/") || path.contains("/HTTPStorages/") || path.contains("/Cookies/") { return .webData }
        if path.contains("/DiagnosticReports/") { return .diagnosticReport }
        if path.contains("/Receipts/") || path.contains("/private/var/db/receipts/") { return .receipt }
        if path.contains("/Users/Shared/") { return .sharedData }
        if !userLevel { return .systemReview }
        if path.contains("/Application Scripts/") || path.contains("/Plug-Ins/") || path.contains("/QuickLook/") { return .appExtension }
        return .userSupport
    }

    private func moveToTrash(_ item: ApplicationUninstallItem, plan: ApplicationUninstallPlan) throws {
        guard let url = item.url else {
            throw ApplicationUninstallerError.invalidPath(item.displayName)
        }
        try moveToTrashURL(
            url,
            requiresAdmin: item.requiresAdmin,
            allowApplicationBundle: isApplicationBundleItem(item, in: plan)
        )
    }

    private func moveToTrashURL(_ url: URL, requiresAdmin: Bool, allowApplicationBundle: Bool) throws {
        guard validateDeletionPath(url, allowApplicationBundle: allowApplicationBundle) else {
            throw ApplicationUninstallerError.invalidPath(url.path)
        }
        guard pathExists(url) else { return }

        if !requiresAdmin {
            if environment.useSystemTrash {
                do {
                    _ = try fileManager.trashItem(at: url, resultingItemURL: nil)
                    return
                } catch {
                    throw ApplicationUninstallerError.trashUnavailable("\(url.path): \(error.localizedDescription)")
                }
            } else {
                try moveToConfiguredTrash(url, useAdmin: false)
                return
            }
        }

        try moveToConfiguredTrash(url, useAdmin: true)
    }

    private func moveToConfiguredTrash(_ url: URL, useAdmin: Bool) throws {
        try prepareConfiguredTrashDirectory()
        let destination = uniqueTrashDestination(for: url)
        if !useAdmin {
            try fileManager.moveItem(at: url, to: destination)
            return
        }

        guard environment.runExternalCommands else {
            throw ApplicationUninstallerError.trashUnavailable("测试环境未启用管理员移动：\(url.path)")
        }
        let uid = getuid()
        let gid = getgid()
        let script = """
        set sourcePath to "\(escapeAppleScript(url.path))"
        set destPath to "\(escapeAppleScript(destination.path))"
        set trashPath to "\(escapeAppleScript(environment.trashDirectory.path))"
        do shell script "/usr/bin/test -d " & quoted form of trashPath & " && /usr/bin/test ! -L " & quoted form of trashPath & " && /bin/mv " & quoted form of sourcePath & " " & quoted form of destPath & " && /usr/sbin/chown -R \(uid):\(gid) " & quoted form of destPath & " && /bin/chmod 700 " & quoted form of trashPath with administrator privileges
        """
        guard let osascript = firstExecutable(named: "osascript", in: ["/usr/bin"]) else {
            throw ApplicationUninstallerError.trashUnavailable("找不到 osascript")
        }
        let output = try runner.run(executable: osascript, arguments: ["-e", script], timeout: 120)
        guard output.exitCode == 0 else {
            throw ApplicationUninstallerError.trashUnavailable(output.stderr.isEmpty ? url.path : output.stderr)
        }
    }

    private func prepareConfiguredTrashDirectory() throws {
        let trash = environment.trashDirectory.standardizedFileURL
        let expectedTrash = environment.homeDirectory
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL
        guard trash.path == expectedTrash.path else {
            throw ApplicationUninstallerError.trashUnavailable("废纸篓路径不安全：\(trash.path)")
        }

        if pathExists(trash) {
            guard isDirectory(trash), !isSymbolicLink(trash) else {
                throw ApplicationUninstallerError.trashUnavailable("废纸篓不是普通目录：\(trash.path)")
            }
        } else {
            try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        }

        guard isDirectory(trash), !isSymbolicLink(trash) else {
            throw ApplicationUninstallerError.trashUnavailable("废纸篓不是普通目录：\(trash.path)")
        }
    }

    private func uniqueTrashDestination(for url: URL) -> URL {
        let base = url.lastPathComponent.isEmpty ? "mac-tool-trash-item" : url.lastPathComponent
        var destination = environment.trashDirectory.appendingPathComponent(base)
        if !pathExists(destination) {
            return destination
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        for index in 1...10_000 {
            destination = environment.trashDirectory.appendingPathComponent("\(base).\(timestamp).\(index)")
            if !pathExists(destination) {
                return destination
            }
        }
        return environment.trashDirectory.appendingPathComponent("\(base).\(UUID().uuidString)")
    }

    private func stopLaunchServices(bundleID: String, appPath: URL) {
        guard environment.runExternalCommands, isReverseDNSBundleID(bundleID) else { return }
        let uid = getuid()
        if let launchctl = firstExecutable(named: "launchctl", in: ["/bin", "/usr/bin"]) {
            _ = try? runner.run(executable: launchctl, arguments: ["bootout", "gui/\(uid)/\(bundleID)"], timeout: 3)
        }
        let userLaunchAgents = contents(of: userLibrary().appendingPathComponent("LaunchAgents"), matching: {
            $0.lastPathComponent == "\(bundleID).plist" || $0.lastPathComponent.hasPrefix("\(bundleID).")
        })
        for plist in userLaunchAgents {
            unloadLaunchPlist(plist, admin: false)
        }
        for plist in launchPlistsReferencing(appPath: appPath, under: userLibrary().appendingPathComponent("LaunchAgents", isDirectory: true)) {
            unloadLaunchPlist(plist, admin: false)
        }
    }

    private func unloadLaunchPlist(_ plist: URL, admin: Bool) {
        guard environment.runExternalCommands, let launchctl = firstExecutable(named: "launchctl", in: ["/bin", "/usr/bin"]) else { return }
        if admin {
            runAdminShellCommand("/bin/launchctl unload \(shellQuoted(plist.path))")
        } else {
            _ = try? runner.run(executable: launchctl, arguments: ["unload", plist.path], timeout: 4)
        }
    }

    private func unregisterAppBundle(_ appPath: URL) {
        guard environment.runExternalCommands else { return }
        let lsregister = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        guard fileManager.isExecutableFile(atPath: lsregister.path) else { return }
        _ = try? runner.run(executable: lsregister, arguments: ["-u", appPath.path], timeout: 5)
    }

    private func refreshLaunchServices() {
        guard environment.runExternalCommands else { return }
        let lsregister = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        guard fileManager.isExecutableFile(atPath: lsregister.path) else { return }
        _ = try? runner.run(executable: lsregister, arguments: ["-gc"], timeout: 8)
        _ = try? runner.run(executable: lsregister, arguments: ["-r", "-f", "-domain", "local", "-domain", "user", "-domain", "system"], timeout: 15)
    }

    private func loginItemHelperBundleIDs(in appPath: URL) -> [String] {
        let loginItems = appPath.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        return contents(of: loginItems, matching: { $0.pathExtension == "app" }).compactMap { helper in
            let bundleID = sanitizeMetadata(infoPlist(at: helper)?["CFBundleIdentifier"] as? String) ?? ""
            return isReverseDNSBundleID(bundleID) ? bundleID : nil
        }
    }

    private func bootoutLoginItemHelpers(_ helperBundleIDs: [String]) {
        guard environment.runExternalCommands,
              let launchctl = firstExecutable(named: "launchctl", in: ["/bin", "/usr/bin"]) else { return }
        let uid = getuid()
        for helperID in helperBundleIDs where isReverseDNSBundleID(helperID) {
            _ = try? runner.run(executable: launchctl, arguments: ["bootout", "gui/\(uid)/\(helperID)"], timeout: 4)
        }
    }

    private func terminateApplication(_ application: InstalledApplication) -> Bool {
        let executableName = sanitizeMetadata(infoPlist(at: application.path)?["CFBundleExecutable"] as? String) ?? application.displayName
        guard !isProtectedProcessName(application.displayName), !isProtectedProcessName(executableName) else {
            return false
        }
        let targets = runningApplications(at: application.path).filter { running in
            running.processIdentifier != getpid()
                && !isProtectedProcessName(running.localizedName ?? "")
        }
        guard !targets.isEmpty else { return true }

        for app in targets {
            app.terminate()
        }
        return waitForTermination(of: targets, timeout: 3)
    }

    private func waitForTermination(of applications: [NSRunningApplication], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if applications.allSatisfy({ $0.isTerminated }) { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return applications.allSatisfy { $0.isTerminated }
    }

    private func isProtectedProcessName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let protected = [
            "finder", "dock", "loginwindow", "windowserver", "systemuiserver", "controlcenter",
            "cfprefsd", "launchservicesd", "distnoted", "runningboardd", "kernel_task"
        ]
        return protected.contains(normalized)
    }

    private func uninstallHomebrewCask(_ cask: String, appPath: URL) -> HomebrewUninstallOutcome {
        guard environment.runExternalCommands else {
            return HomebrewUninstallOutcome(success: false, message: "测试环境未启用 Homebrew 命令", state: .unknown("未启用外部命令"))
        }
        guard let brew = brewExecutable() else {
            return HomebrewUninstallOutcome(success: false, message: "未找到 Homebrew，无法执行 brew uninstall --cask --zap \(cask)", state: .unknown("未找到 Homebrew"))
        }
        do {
            let output = try runner.run(
                executable: brew,
                arguments: ["uninstall", "--cask", "--zap", cask],
                timeout: homebrewUninstallTimeout(for: appPath),
                environment: homebrewWriteEnvironment()
            )
            let appGone = !fileManager.fileExists(atPath: appPath.path)
            let state = homebrewCaskState(cask)
            if output.exitCode == 0 && appGone && state == .notInstalled {
                return HomebrewUninstallOutcome(success: true, message: "Homebrew 已卸载 \(cask)", state: state)
            }
            let text = [output.stdout, output.stderr].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = text.isEmpty ? "Homebrew 卸载未完成：\(cask)" : text
            return HomebrewUninstallOutcome(success: false, message: fallback, state: state)
        } catch {
            return HomebrewUninstallOutcome(success: false, message: error.localizedDescription, state: .unknown(error.localizedDescription))
        }
    }

    private func homebrewCaskState(_ cask: String) -> HomebrewCaskState {
        guard environment.runExternalCommands, let brew = brewExecutable() else {
            return .unknown("未找到 Homebrew 或外部命令未启用")
        }
        do {
            let output = try runner.run(executable: brew, arguments: ["list", "--cask"], timeout: 8, environment: homebrewReadEnvironment())
            guard output.exitCode == 0 else {
                let text = [output.stdout, output.stderr].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return .unknown(text.isEmpty ? "brew list --cask 失败" : text)
            }
            return output.stdout.split(separator: "\n").contains { $0 == cask } ? .installed : .notInstalled
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    private func isHomebrewCaskInstalled(_ cask: String) -> Bool {
        homebrewCaskState(cask) == .installed
    }

    private func homebrewReadEnvironment() -> [String: String] {
        ["HOMEBREW_NO_ENV_HINTS": "1"]
    }

    private func homebrewWriteEnvironment() -> [String: String] {
        [
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "NONINTERACTIVE": "1"
        ]
    }

    private func homebrewUninstallTimeout(for appPath: URL) -> TimeInterval {
        let sizeInGiB = Double(pathSizeBytes(appPath)) / 1_073_741_824
        if sizeInGiB >= 8 { return 900 }
        if sizeInGiB >= 2 { return 600 }
        return 300
    }

    private func backgroundItemsMayRemain(bundleID: String) -> Bool {
        guard environment.runExternalCommands, isReverseDNSBundleID(bundleID),
              let sfltool = firstExecutable(named: "sfltool", in: ["/usr/bin"]) else {
            return false
        }
        guard let output = try? runner.run(executable: sfltool, arguments: ["dumpbtm"], timeout: 8) else {
            return false
        }
        return output.stdout.contains(bundleID) || output.stderr.contains(bundleID)
    }

    private func systemExtensionsForBundle(_ bundleID: String) -> [URL] {
        guard isReverseDNSBundleID(bundleID) else { return [] }
        let root = environment.systemLibraryDirectory.appendingPathComponent("SystemExtensions", isDirectory: true)
        return recursiveContents(of: root, maxDepth: 3, matching: { url in
            nameStartsWithBundleBoundary(url.lastPathComponent, bundleID)
                || url.lastPathComponent.hasPrefix(bundleID)
        })
    }

    private func removeAppsFromDock(appPath: URL, bundleID: String) {
        guard isReverseDNSBundleID(bundleID) else { return }
        let dockPlist = userLibrary().appendingPathComponent("Preferences/com.apple.dock.plist")
        guard let data = try? Data(contentsOf: dockPlist),
              var plist = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: nil) as? [String: Any],
              var persistentApps = plist["persistent-apps"] as? [[String: Any]] else {
            return
        }
        let originalCount = persistentApps.count
        persistentApps.removeAll { entry in
            guard let tileData = entry["tile-data"] as? [String: Any] else { return false }
            if let fileData = tileData["file-data"] as? [String: Any],
               let cfURL = fileData["_CFURLString"] as? String {
                return dockFileURL(cfURL, matches: appPath)
            }
            return false
        }
        guard persistentApps.count != originalCount else { return }
        plist["persistent-apps"] = persistentApps
        guard let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { return }
        try? updated.write(to: dockPlist, options: .atomic)
        if environment.runExternalCommands, let killall = firstExecutable(named: "killall", in: ["/usr/bin"]) {
            _ = try? runner.run(executable: killall, arguments: ["Dock"], timeout: 3)
        }
    }

    private func dockFileURL(_ value: String, matches appPath: URL) -> Bool {
        let targetPath = appPath.standardizedFileURL.path
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL.path == targetPath
        }
        let decoded = value.removingPercentEncoding ?? value
        if decoded == targetPath {
            return true
        }
        if decoded.hasPrefix("file://"),
           let url = URL(string: decoded),
           url.isFileURL {
            return url.standardizedFileURL.path == targetPath
        }
        return false
    }

    private func detectHomebrewCask(for appPath: URL) -> String? {
        guard environment.runExternalCommands, brewExecutable() != nil else { return nil }
        if let resolved = resolvedSymlinkTarget(appPath),
           let cask = extractCaskToken(from: resolved.path),
           isHomebrewCaskInstalled(cask) {
            return cask
        }
        if let cask = extractCaskToken(from: appPath.standardizedFileURL.path),
           isHomebrewCaskInstalled(cask) {
            return cask
        }
        return nil
    }

    private func appDeclaresLocalNetworkUsage(_ appPath: URL) -> Bool {
        guard let plist = infoPlist(at: appPath) else { return false }
        if let description = plist["NSLocalNetworkUsageDescription"] as? String,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let bonjour = plist["NSBonjourServices"] as? [Any], !bonjour.isEmpty {
            return true
        }
        return false
    }

    private func extractCaskToken(from path: String) -> String? {
        for root in environment.homebrewCaskroomDirectories {
            var prefix = root.standardizedFileURL.path
            if !prefix.hasSuffix("/") {
                prefix += "/"
            }
            guard path.hasPrefix(prefix) else { continue }
            let rest = String(path.dropFirst(prefix.count))
            guard let token = rest.split(separator: "/").first.map(String.init),
                  token.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil else {
                return nil
            }
            return token
        }
        return nil
    }

    private func brewExecutable() -> URL? {
        firstExecutable(named: "brew", in: environment.homebrewBinaryDirectories.map(\.path))
    }

    private func firstExecutable(named name: String, in directories: [String]) -> URL? {
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func protectionReason(bundleID: String, appPath: URL, backgroundOnly: Bool) -> String? {
        if backgroundOnly {
            return "后台辅助 App 不作为独立卸载目标，避免误删 Login Item 或嵌套 helper。"
        }
        let path = appPath.standardizedFileURL.path
        if path.hasPrefix(environment.systemApplicationsDirectory.path + "/") {
            return "系统应用目录内的 App 被保护。"
        }
        guard bundleID != "unknown" else { return nil }
        if matchesAny(ApplicationUninstallerRuleData.systemCriticalBundlePatterns, value: bundleID),
           !matchesAny(ApplicationUninstallerRuleData.appleUninstallableBundlePatterns, value: bundleID) {
            return "系统关键组件被保护：\(bundleID)"
        }
        return nil
    }

    private func officialUninstallerVendor(bundleID: String, appName: String, appPath: URL) -> String? {
        let normalizedBundle = bundleID.lowercased()
        let normalizedName = appName.lowercased()
        let normalizedPath = appPath.path.lowercased()
        for rule in ApplicationUninstallerRuleData.officialUninstallerRules {
            if rule.bundlePrefixes.contains(where: { normalizedBundle.hasPrefix($0) }) {
                return rule.vendor
            }
            if rule.nameFragments.contains(where: { normalizedName.contains($0) || normalizedPath.contains($0) }) {
                return rule.vendor
            }
        }
        return nil
    }

    private func isSensitiveApplication(bundleID: String, appName: String) -> Bool {
        let values = [bundleID, appName, appName.lowercased()]
        return values.contains { value in
            matchesAny(ApplicationUninstallerRuleData.dataProtectedPatterns, value: value)
        }
    }

    private func validateDeletionPath(_ url: URL, allowApplicationBundle: Bool) -> Bool {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard path.hasPrefix("/"), !path.isEmpty else { return false }
        guard !standardized.pathComponents.contains("..") else { return false }
        guard path.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        guard !isCriticalSystemPath(path) else { return false }

        if isSymbolicLink(standardized),
           let target = resolvedSymlinkTarget(standardized),
           isCriticalSystemPath(target.standardizedFileURL.path) {
            return false
        }

        if allowApplicationBundle, standardized.pathExtension == "app" {
            let allowedRoots = (environment.applicationDirectories + environment.receiptApplicationDirectories)
                .map { $0.standardizedFileURL.path + "/" }
            if allowedRoots.contains(where: path.hasPrefix) {
                return true
            }
            var volumePrefix = environment.volumesDirectory.standardizedFileURL.path
            if !volumePrefix.hasSuffix("/") {
                volumePrefix += "/"
            }
            guard path.hasPrefix(volumePrefix) else { return false }
            let relativeComponents = String(path.dropFirst(volumePrefix.count)).split(separator: "/")
            return relativeComponents.count >= 3 && relativeComponents[1] == "Applications"
        }

        let userRoots = [
            userLibrary().path + "/",
            environment.homeDirectory.appendingPathComponent(".config", isDirectory: true).path + "/",
            environment.homeDirectory.appendingPathComponent(".cache", isDirectory: true).path + "/",
            environment.homeDirectory.appendingPathComponent(".local/share", isDirectory: true).path + "/"
        ]
        if userRoots.contains(where: path.hasPrefix) {
            return !isCollapsedRoot(standardized) && !shouldProtectUserPath(standardized, bundleID: nil, appName: nil)
        }
        if isRegenerableDeveloperCachePath(standardized) {
            return true
        }
        return false
    }

    private func shouldProtectUserPath(_ url: URL, bundleID: String?, appName: String?) -> Bool {
        let standardized = url.standardizedFileURL
        if pathBelongsToIndependentCLI(standardized) { return true }
        if isProtectedDeveloperDataPath(standardized) { return true }

        let protectedRoots = [
            userLibrary().appendingPathComponent("Keychains", isDirectory: true),
            userLibrary().appendingPathComponent("Accounts", isDirectory: true),
            userLibrary().appendingPathComponent("Mobile Documents", isDirectory: true),
            userLibrary().appendingPathComponent("IdentityServices", isDirectory: true),
            userLibrary().appendingPathComponent("Messages", isDirectory: true),
            userLibrary().appendingPathComponent("Mail", isDirectory: true),
            userLibrary().appendingPathComponent("Calendars", isDirectory: true),
            userLibrary().appendingPathComponent("Safari", isDirectory: true),
            userLibrary().appendingPathComponent("Application Support/com.apple.TCC", isDirectory: true),
            userLibrary().appendingPathComponent("Application Support/CloudDocs", isDirectory: true),
            environment.homeDirectory.appendingPathComponent(".ssh", isDirectory: true),
            environment.homeDirectory.appendingPathComponent(".gnupg", isDirectory: true),
            environment.homeDirectory.appendingPathComponent(".aws", isDirectory: true),
            environment.homeDirectory.appendingPathComponent(".kube", isDirectory: true)
        ]
        if protectedRoots.contains(where: { isSameOrDescendant(standardized, of: $0) }) {
            return true
        }
        if isProtectedSystemUIStatePath(standardized) {
            return true
        }

        let lowerComponents = standardized.pathComponents.map { $0.lowercased() }
        let protectedFragments = [
            "keychain", "credential", "credentials", "secret", "secrets", "token", "tokens",
            "auth", "session", "sessions", "history", "keystore", "adbkey", "provisioning profiles"
        ]
        return lowerComponents.contains { component in
            protectedFragments.contains { fragment in
                component == fragment || component.contains(fragment)
            }
        }
    }

    private func isProtectedSystemUIStatePath(_ url: URL) -> Bool {
        let library = userLibrary()
        let protectedRoots = [
            library.appendingPathComponent("Application Support/com.apple.sharedfilelist", isDirectory: true),
            library.appendingPathComponent("Application Support/Dock", isDirectory: true),
            library.appendingPathComponent("Saved Application State/com.apple.finder.savedState", isDirectory: true),
            library.appendingPathComponent("Saved Application State/com.apple.systemuiserver.savedState", isDirectory: true)
        ]
        if protectedRoots.contains(where: { isSameOrDescendant(url, of: $0) }) {
            return true
        }
        let protectedPreferenceNames = [
            ".GlobalPreferences.plist",
            "com.apple.dock.plist",
            "com.apple.finder.plist",
            "com.apple.systemuiserver.plist",
            "com.apple.controlcenter.plist",
            "com.apple.sidebarlists.plist"
        ]
        return isSameOrDescendant(url, of: library.appendingPathComponent("Preferences", isDirectory: true))
            && protectedPreferenceNames.contains(url.lastPathComponent)
    }

    private func isProtectedDeveloperDataPath(_ url: URL) -> Bool {
        let home = environment.homeDirectory
        let library = userLibrary()
        let roots = [
            home.appendingPathComponent(".android", isDirectory: true),
            library.appendingPathComponent("Android", isDirectory: true),
            library.appendingPathComponent("Developer/Xcode/Archives", isDirectory: true),
            library.appendingPathComponent("Developer/Xcode/UserData", isDirectory: true),
            library.appendingPathComponent("Developer/Xcode/Toolchains", isDirectory: true),
            library.appendingPathComponent("Developer/CoreSimulator/Devices", isDirectory: true),
            library.appendingPathComponent("MobileDevice/Provisioning Profiles", isDirectory: true),
            library.appendingPathComponent("Application Support/JetBrains", isDirectory: true)
        ]
        let allowedAndroidCache = [
            home.appendingPathComponent(".android/cache", isDirectory: true),
            home.appendingPathComponent(".android/build-cache", isDirectory: true),
            home.appendingPathComponent(".android/breakpad", isDirectory: true)
        ]
        if allowedAndroidCache.contains(where: { isSameOrDescendant(url, of: $0) }) {
            return false
        }
        if roots.contains(where: { isSameOrDescendant(url, of: $0) }) {
            return true
        }
        if isSameOrDescendant(url, of: library.appendingPathComponent("Preferences", isDirectory: true)),
           url.lastPathComponent.hasPrefix("com.jetbrains.") {
            return true
        }
        return false
    }

    private func isRegenerableDeveloperCachePath(_ url: URL) -> Bool {
        let roots = [
            environment.homeDirectory.appendingPathComponent(".android/cache", isDirectory: true),
            environment.homeDirectory.appendingPathComponent(".android/build-cache", isDirectory: true),
            environment.homeDirectory.appendingPathComponent(".android/breakpad", isDirectory: true)
        ]
        return roots.contains { isSameOrDescendant(url, of: $0) }
    }

    private func receiptApplicationPathIsAllowlisted(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = environment.receiptApplicationDirectories.map { $0.standardizedFileURL.path + "/" }
        return roots.contains(where: path.hasPrefix)
    }

    private func isCriticalSystemPath(_ path: String) -> Bool {
        let protected = [
            "/", "/Applications", "/System", "/System/Applications", "/Library", "/Users",
            environment.homeDirectory.path,
            userLibrary().path,
            "/bin", "/sbin", "/usr", "/usr/bin", "/usr/lib", "/private/etc"
        ]
        if protected.contains(path) { return true }
        return path.hasPrefix("/System/")
            || path.hasPrefix("/usr/bin/")
            || path.hasPrefix("/usr/lib/")
            || path.hasPrefix("/bin/")
            || path.hasPrefix("/sbin/")
            || path.hasPrefix("/private/etc/")
    }

    private func isCollapsedRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = [
            userLibrary().appendingPathComponent("Application Support").path,
            userLibrary().appendingPathComponent("Caches").path,
            userLibrary().appendingPathComponent("Logs").path,
            userLibrary().appendingPathComponent("Preferences").path,
            userLibrary().appendingPathComponent("Preferences/ByHost").path,
            userLibrary().appendingPathComponent("Containers").path,
            userLibrary().appendingPathComponent("WebKit").path,
            userLibrary().appendingPathComponent("HTTPStorages").path,
            userLibrary().appendingPathComponent("Application Scripts").path,
            userLibrary().appendingPathComponent("Autosave Information").path,
            userLibrary().appendingPathComponent("Group Containers").path,
            environment.homeDirectory.appendingPathComponent(".config").path,
            environment.homeDirectory.appendingPathComponent(".cache").path,
            environment.homeDirectory.appendingPathComponent(".local/share").path,
            environment.homeDirectory.path
        ]
        return roots.contains(path)
    }

    private func isCollapsedSystemRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return [
            environment.systemLibraryDirectory.appendingPathComponent("Application Support").path,
            environment.systemLibraryDirectory.appendingPathComponent("Caches").path,
            environment.systemLibraryDirectory.appendingPathComponent("Logs").path,
            environment.systemLibraryDirectory.appendingPathComponent("Preferences").path
        ].contains(path)
    }

    private func diagnosticReportPaths(for application: InstalledApplication, under root: URL) -> [URL] {
        guard isReadableDirectory(root) else { return [] }
        let names = Set([
            application.displayName,
            application.path.deletingPathExtension().lastPathComponent,
            (infoPlist(at: application.path)?["CFBundleExecutable"] as? String) ?? ""
        ].filter { !$0.isEmpty })
        return contents(of: root, matching: { url in
            let name = url.lastPathComponent
            return names.contains { name.hasPrefix("\($0)_") || name.hasPrefix("\($0)-") }
        })
    }

    private func receiptPayloadPaths(bundleID: String) -> [URL] {
        guard environment.runExternalCommands, isReverseDNSBundleID(bundleID),
              let lsbom = firstExecutable(named: "lsbom", in: ["/usr/bin"]) else { return [] }
        let receipts = contents(of: URL(fileURLWithPath: "/private/var/db/receipts", isDirectory: true), matching: {
            nameStartsWithBundleBoundary($0.lastPathComponent, bundleID) && $0.pathExtension == "bom"
        })
        var paths: [URL] = []
        for receipt in receipts {
            guard let output = try? runner.run(executable: lsbom, arguments: ["-s", receipt.path], timeout: 4) else { continue }
            for raw in output.stdout.split(separator: "\n").map(String.init) {
                guard let url = sanitizeReceiptPayloadPath(raw) else {
                    AppLogger.shared.info("应用卸载：忽略不安全 BOM 路径 \(raw)")
                    continue
                }
                if receiptPayloadPathIsAllowlisted(url, bundleID: bundleID), pathExists(url) {
                    paths.append(url)
                }
            }
        }
        return paths
    }

    func sanitizeReceiptPayloadPath(_ raw: String) -> URL? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !rawComponents.contains("..") else {
            return nil
        }
        if !path.hasPrefix("/") {
            path = "/\(path)"
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
            return nil
        }
        guard ![
            "/", "/Applications", "/Library", "/System", "/Users",
            "/private", "/private/var", "/private/var/db", "/private/var/db/receipts",
            "/var", "/var/db", "/var/db/receipts"
        ].contains(url.path) else {
            return nil
        }
        return url
    }

    private func receiptPayloadPathIsAllowlisted(_ url: URL, bundleID: String) -> Bool {
        let path = url.path
        let base = url.lastPathComponent
        if path.hasPrefix("/Library/LaunchAgents/") || path.hasPrefix("/Library/LaunchDaemons/") {
            return base == "\(bundleID).plist" || base.hasPrefix("\(bundleID).")
        }
        if path.hasPrefix("/Library/PrivilegedHelperTools/") {
            return nameStartsWithBundleBoundary(base, bundleID)
        }
        if path.hasPrefix("/Library/Receipts/") || path.hasPrefix("/private/var/db/receipts/") {
            return base == "\(bundleID).bom" || base == "\(bundleID).plist" || base.hasPrefix("\(bundleID).")
        }
        return false
    }

    private func launchPlistsReferencing(appPath: URL, under directory: URL) -> [URL] {
        contents(of: directory, matching: { plist in
            guard plist.pathExtension == "plist",
                  let data = try? Data(contentsOf: plist),
                  let text = String(data: data, encoding: .utf8) else {
                return false
            }
            return text.contains(appPath.path) || text.contains(appPath.lastPathComponent)
        })
    }

    private func vendorNestedPaths(bundleID: String, appName: String, roots: [URL]) -> [URL] {
        guard let (vendor, product) = vendorProductTokens(bundleID: bundleID) else { return [] }
        let productNeedles = Set([
            product.lowercased(),
            appName.lowercased(),
            appName.replacingOccurrences(of: " ", with: "").lowercased(),
            appName.replacingOccurrences(of: " ", with: "-").lowercased()
        ].filter { $0.count >= 3 })
        var paths: [URL] = []
        for root in roots where isReadableDirectory(root) {
            for vendorDir in contents(of: root, matching: { url in
                url.lastPathComponent.lowercased().contains(vendor.lowercased())
            }) {
                paths += contents(of: vendorDir, matching: { child in
                    let lower = child.lastPathComponent.lowercased()
                    return productNeedles.contains(where: lower.contains)
                })
            }
        }
        return paths
    }

    private func sharedAppPaths(bundleID: String, appName: String, root: URL) -> [URL] {
        guard isReadableDirectory(root) else { return [] }
        let variants = nameVariants(appName)
        let needles = [variants.lowercase, variants.lowercaseNospace, variants.lowercaseHyphen]
            .filter { $0.count >= 4 }
        return contents(of: root, matching: { url in
            let lower = url.lastPathComponent.lowercased()
            return needles.contains(where: lower.contains) || lower.contains(bundleID.lowercased())
        })
    }

    private func vendorProductTokens(bundleID: String) -> (String, String)? {
        guard isReverseDNSBundleID(bundleID) else { return nil }
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 3, let product = parts.last, let vendor = parts.dropLast().last else { return nil }
        return (vendor, product)
    }

    private func pathBelongsToIndependentCLI(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let independent = [
            "git", "ssh", "gnupg", "npm", "pnpm", "yarn", "cargo", "gem", "pip", "gradle", "maven", "docker",
            "claude", "opencode", "codex", "gemini"
        ]
        for name in independent {
            let roots = [
                environment.homeDirectory.appendingPathComponent(".\(name)", isDirectory: true),
                environment.homeDirectory.appendingPathComponent(".config/\(name)", isDirectory: true),
                environment.homeDirectory.appendingPathComponent(".cache/\(name)", isDirectory: true),
                environment.homeDirectory.appendingPathComponent(".local/share/\(name)", isDirectory: true),
                userLibrary().appendingPathComponent("Application Support/\(name)", isDirectory: true)
            ]
            if roots.contains(where: { isSameOrDescendant(standardized, of: $0) }) {
                return true
            }
        }
        return false
    }

    private func jetBrainsProductPrefixes(appName: String, bundleID: String) -> [String] {
        let lowerValues = "\(appName) \(bundleID)".lowercased()
        let mapping: [(String, String)] = [
            ("intellij", "IntelliJIdea"),
            ("pycharm", "PyCharm"),
            ("webstorm", "WebStorm"),
            ("goland", "GoLand"),
            ("rubymine", "RubyMine"),
            ("phpstorm", "PhpStorm"),
            ("clion", "CLion"),
            ("datagrip", "DataGrip"),
            ("rider", "Rider"),
            ("appcode", "AppCode"),
            ("dataspell", "DataSpell"),
            ("rustrover", "RustRover"),
            ("aqua", "Aqua"),
            ("fleet", "Fleet"),
            ("mps", "MPS"),
            ("writerside", "Writerside")
        ]
        let prefixes = mapping.compactMap { lowerValues.contains($0.0) ? $0.1 : nil }
        if !prefixes.isEmpty {
            return prefixes
        }
        let fallback = appName.replacingOccurrences(of: " ", with: "")
        return fallback.count >= 4 ? [fallback] : []
    }

    private func isSameOrDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        var rootPath = root.standardizedFileURL.path
        if path == rootPath {
            return true
        }
        if !rootPath.hasSuffix("/") {
            rootPath += "/"
        }
        return path.hasPrefix(rootPath)
    }

    private func nameVariants(_ appName: String) -> NameVariants {
        let nospace = appName.replacingOccurrences(of: " ", with: "")
        let underscore = appName.replacingOccurrences(of: " ", with: "_")
        let hyphen = appName.replacingOccurrences(of: " ", with: "-")
        let base = baseName(appName)
        return NameVariants(
            appName: appName,
            nospace: nospace,
            underscore: underscore,
            hyphen: hyphen,
            lowercase: appName.lowercased(),
            lowercaseNospace: nospace.lowercased(),
            lowercaseHyphen: hyphen.lowercased(),
            lowercaseUnderscore: underscore.lowercased(),
            baseName: base,
            baseLowercase: base.lowercased()
        )
    }

    private func baseName(_ appName: String) -> String {
        let suffixes = [
            "Nightly", "Beta", "Alpha", "Dev", "Canary", "Preview", "Insider", "Edge",
            "Stable", "Release", "RC", "LTS", "Developer Edition", "Technology Preview"
        ]
        for suffix in suffixes {
            let marker = " \(suffix)"
            if appName.hasSuffix(marker), appName.count > marker.count + 2 {
                return String(appName.dropLast(marker.count))
            }
        }
        return appName
    }

    private func isReverseDNSBundleID(_ value: String) -> Bool {
        guard value != "unknown" else { return false }
        return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#, options: .regularExpression) != nil
            && !value.contains("/")
            && !value.contains("*")
            && !value.contains("?")
            && !value.contains("[")
    }

    private func nameStartsWithBundleBoundary(_ name: String, _ bundleID: String) -> Bool {
        name == bundleID
            || name == "\(bundleID).plist"
            || name == "\(bundleID).bom"
            || name.hasPrefix("\(bundleID).")
    }

    private func nameHasBundleBoundary(_ name: String, _ bundleID: String) -> Bool {
        name == bundleID
            || name.hasPrefix("\(bundleID).")
            || name.contains(".\(bundleID).")
            || name.contains("-\(bundleID).")
    }

    private func matchesAny(_ patterns: [String], value: String) -> Bool {
        patterns.contains { pattern in
            fnmatch(pattern, value, 0) == 0
        }
    }

    private func isCommonLaunchAgentName(_ appName: String) -> Bool {
        ApplicationUninstallerRuleData.commonLaunchAgentNames.contains(appName)
    }

    private func isCommonAppName(_ appName: String) -> Bool {
        isCommonLaunchAgentName(appName) || appName.count < 5
    }

    private func isApplicationRunning(bundleID _: String, appName _: String, appPath: URL) -> Bool {
        !runningApplications(at: appPath).isEmpty
    }

    private func runningApplications(at appPath: URL) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            app.bundleURL?.standardizedFileURL == appPath.standardizedFileURL
        }
    }

    private func needsAdminToRemove(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        if !fileManager.isWritableFile(atPath: parent.path) {
            return true
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        if let ownerID = attributes?[.ownerAccountID] as? NSNumber {
            return ownerID.uint32Value != getuid()
        }
        if let owner = attributes?[.ownerAccountName] as? String, owner != NSUserName() {
            return true
        }
        return false
    }

    private func pathSizeBytes(_ url: URL) -> Int64 {
        guard pathExists(url) else { return 0 }
        if isDirectory(url), !isSymbolicLink(url) {
            var total: Int64 = 0
            if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: [], errorHandler: nil) {
                for case let child as URL in enumerator {
                    total += fileSize(child)
                }
            }
            return max(total, fileSize(url))
        }
        return fileSize(url)
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        if let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize {
            return Int64(size)
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func resourceDate(_ url: URL, key: URLResourceKey) -> Date? {
        try? url.resourceValues(forKeys: [key]).allValues[key] as? Date
    }

    private func userLibrary() -> URL {
        environment.homeDirectory.appendingPathComponent("Library", isDirectory: true)
    }

    private func pathExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isReadableFile(atPath: url.path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            return true
        }
        return (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func resolvedSymlinkTarget(_ url: URL) -> URL? {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        if target.hasPrefix("/") {
            return URL(fileURLWithPath: target)
        }
        return url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if pathExists(lhs), pathExists(rhs) {
            return (try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject)
                == (try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject)
        }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private func pathIdentity(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        if let identity = values?.fileResourceIdentifier {
            return "inode:\(identity)"
        }
        return "path:\(url.standardizedFileURL.path)"
    }

    private func contents(of directory: URL, matching predicate: (URL) -> Bool) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter(predicate)
    }

    private func recursiveContents(of directory: URL, maxDepth: Int, matching predicate: (URL) -> Bool) -> [URL] {
        guard isReadableDirectory(directory),
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
              ) else {
            return []
        }
        let rootDepth = directory.pathComponents.count
        var matches: [URL] = []
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - rootDepth
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if predicate(url) {
                matches.append(url)
            }
        }
        return matches
    }

    private func dedupeURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            result.append(url.standardizedFileURL)
        }
        return result
    }

    private func dedupeItems(_ items: [ApplicationUninstallItem]) -> [ApplicationUninstallItem] {
        var seen: Set<String> = []
        var result: [ApplicationUninstallItem] = []
        for item in items {
            let key = item.url?.standardizedFileURL.path ?? item.id
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private func sanitizeMetadata(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value != "(null)" else {
            return nil
        }
        value = value.replacingOccurrences(of: "|", with: "-")
        value.removeAll { $0.isNewline || $0.isASCII && $0.asciiValue.map { $0 < 32 } == true }
        return value
    }

    private func sanitizePathComponentName(_ value: String?) -> String? {
        guard let value = sanitizeMetadata(value), value != ".", value != ".." else {
            return nil
        }
        let forbidden = CharacterSet(charactersIn: "/\\:")
        guard value.rangeOfCharacter(from: forbidden) == nil else { return nil }
        return value
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "yes", "true"].contains(string.lowercased())
        }
        return false
    }

    private func escapeAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func runAdminShellCommand(_ command: String) {
        guard environment.runExternalCommands,
              let osascript = firstExecutable(named: "osascript", in: ["/usr/bin"]) else { return }
        let script = "do shell script \"\(escapeAppleScript(command))\" with administrator privileges"
        _ = try? runner.run(executable: osascript, arguments: ["-e", script], timeout: 30)
    }
}

protocol CommandRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, environment: [String: String]) throws -> CommandOutput
}

extension CommandRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        try run(executable: executable, arguments: arguments, timeout: timeout, environment: [:])
    }
}

struct CommandOutput {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct ProcessCommandRunner: CommandRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, environment: [String: String] = [:]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var didTimeout = false
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            didTimeout = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning {
                process.interrupt()
            }
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        let exitGroup = DispatchGroup()
        exitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exitGroup.leave()
        }
        if exitGroup.wait(timeout: .now() + 2) == .timedOut {
            throw ApplicationUninstallerError.commandFailed("外部命令超时且无法结束：\(executable.path)")
        }
        if group.wait(timeout: .now() + 2) == .timedOut {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            throw ApplicationUninstallerError.commandFailed("外部命令输出管道超时未关闭：\(executable.path)")
        }
        if didTimeout {
            throw ApplicationUninstallerError.commandFailed("外部命令超时，已终止：\(executable.path)")
        }
        return CommandOutput(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

private extension String {
    var pathDepth: Int {
        split(separator: "/").count
    }
}
