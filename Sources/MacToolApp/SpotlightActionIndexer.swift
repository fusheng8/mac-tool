import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum SpotlightActionIdentifier {
    static let domain = "com.fusheng.mac-tool.actions"
    static let portManagement = "settings.portManagement"
}

final class SpotlightActionIndexer {
    private let index = CSSearchableIndex(name: "MacAssistantActions")

    func indexActions() {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .item)
        attributeSet.title = "端口管理"
        attributeSet.displayName = "Mac助手 - 端口管理"
        attributeSet.contentDescription = "查看端口占用、进程、应用和路径，并管理本机端口使用情况。"
        attributeSet.keywords = [
            "Mac助手",
            "端口管理",
            "端口",
            "端口占用",
            "进程",
            "应用",
            "路径",
            "port",
            "pid",
            "process"
        ]

        let item = CSSearchableItem(
            uniqueIdentifier: SpotlightActionIdentifier.portManagement,
            domainIdentifier: SpotlightActionIdentifier.domain,
            attributeSet: attributeSet
        )
        item.expirationDate = .distantFuture

        index.indexSearchableItems([item]) { error in
            if let error {
                AppLogger.shared.error("Spotlight 端口管理索引失败：\(error.localizedDescription)")
            } else {
                AppLogger.shared.info("Spotlight 端口管理索引已更新")
            }
        }
    }
}
