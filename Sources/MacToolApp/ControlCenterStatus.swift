import Foundation

enum ControlCenterStatusLevel: Int, Codable, Comparable {
    case normal
    case attention
    case critical

    static func < (lhs: ControlCenterStatusLevel, rhs: ControlCenterStatusLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
struct ControlCenterServiceState: Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let level: ControlCenterStatusLevel
    let route: ControlCenterRoute
}

struct ControlCenterIssue: Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let level: ControlCenterStatusLevel
    let route: ControlCenterRoute
}

struct ControlCenterStatusInput: Equatable {
    var clipboardEnabled: Bool
    var clipboardPaused: Bool
    var clipboardPrivacyExclusionsActive: Bool
    var finderFeatureEnabled: Bool
    var finderExtensionEnabled: Bool?
    var connectedDisplayCount: Int
    var pendingDisplayRecoveryCount: Int
    var archiveFormatCount: Int
}

struct ControlCenterStatusSnapshot: Equatable {
    let level: ControlCenterStatusLevel
    let headline: String
    let services: [ControlCenterServiceState]
    let issues: [ControlCenterIssue]

    static func make(input: ControlCenterStatusInput) -> ControlCenterStatusSnapshot {
        let clipboardDetail: String
        let clipboardLevel: ControlCenterStatusLevel
        if !input.clipboardEnabled {
            clipboardDetail = "未启用"
            clipboardLevel = .attention
        } else if input.clipboardPaused {
            clipboardDetail = "已暂停"
            clipboardLevel = .attention
        } else if input.clipboardPrivacyExclusionsActive {
            clipboardDetail = "正在记录 · 隐私排除生效"
            clipboardLevel = .normal
        } else {
            clipboardDetail = "正在记录"
            clipboardLevel = .normal
        }

        let finderDetail: String
        let finderLevel: ControlCenterStatusLevel
        if !input.finderFeatureEnabled {
            finderDetail = "未启用"
            finderLevel = .normal
        } else {
            switch input.finderExtensionEnabled {
            case true:
                finderDetail = "扩展已启用"
                finderLevel = .normal
            case false:
                finderDetail = "扩展未授权"
                finderLevel = .attention
            case nil:
                finderDetail = "扩展状态待确认"
                finderLevel = .attention
            }
        }

        let displayDetail: String
        let displayLevel: ControlCenterStatusLevel
        if input.pendingDisplayRecoveryCount > 0 {
            displayDetail = "(input.pendingDisplayRecoveryCount) 台等待恢复"
            displayLevel = .critical
        } else if input.connectedDisplayCount > 0 {
            displayDetail = "(input.connectedDisplayCount) 台已连接"
            displayLevel = .normal
        } else {
            displayDetail = "未连接外部显示器"
            displayLevel = .normal
        }

        let services = [
            ControlCenterServiceState(
                id: "clipboard",
                title: "剪贴板",
                detail: clipboardDetail,
                level: clipboardLevel,
                route: .clipboard
            ),
            ControlCenterServiceState(
                id: "finder",
                title: "Finder 增强",
                detail: finderDetail,
                level: finderLevel,
                route: .finder
            ),
            ControlCenterServiceState(
                id: "display",
                title: "显示器",
                detail: displayDetail,
                level: displayLevel,
                route: .displays
            ),
            ControlCenterServiceState(
                id: "archive",
                title: "压缩工具",
                detail: input.archiveFormatCount > 0 ? "(input.archiveFormatCount) 种格式可用" : "没有启用格式",
                level: input.archiveFormatCount > 0 ? .normal : .attention,
                route: .archive
            )
        ]

        var issues: [ControlCenterIssue] = []
        if input.finderFeatureEnabled, input.finderExtensionEnabled != true {
            issues.append(ControlCenterIssue(
                id: "finder-extension",
                title: "Finder 扩展权限未完全授予",
                detail: "部分 Finder 增强功能受限，授权后即可启用完整体验。",
                level: .attention,
                route: .preferences
            ))
        }
        if input.pendingDisplayRecoveryCount > 0 {
            issues.append(ControlCenterIssue(
                id: "display-recovery",
                title: "显示器正在等待恢复",
                detail: "有 (input.pendingDisplayRecoveryCount) 台显示器处于恢复队列，请检查恢复状态。",
                level: .critical,
                route: .displays
            ))
        }
        if input.clipboardEnabled, input.clipboardPaused {
            issues.append(ControlCenterIssue(
                id: "clipboard-paused",
                title: "剪贴板记录已暂停",
                detail: "历史仍可查看，但新的复制内容不会被保存。",
                level: .attention,
                route: .clipboard
            ))
        }
        if input.archiveFormatCount == 0 {
            issues.append(ControlCenterIssue(
                id: "archive-formats",
                title: "压缩工具没有可用格式",
                detail: "至少启用一种归档格式后才能压缩或解压文件。",
                level: .attention,
                route: .archive
            ))
        }

        let level = issues.map(\.level).max() ?? .normal
        let headline = issues.isEmpty ? "所有核心服务均正常" : "有 (issues.count) 项需要处理"
        return ControlCenterStatusSnapshot(level: level, headline: headline, services: services, issues: issues)
    }
}
