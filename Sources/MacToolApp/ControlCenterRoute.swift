import Foundation

enum ControlCenterRoute: String, CaseIterable, Codable {
    case overview
    case clipboard
    case finder
    case archive
    case displays
    case ports
    case uninstall
    case preferences

    var title: String {
        switch self {
        case .overview: return "概览"
        case .clipboard: return "剪贴板"
        case .finder: return "Finder 增强"
        case .archive: return "压缩工具"
        case .displays: return "显示器"
        case .ports: return "端口"
        case .uninstall: return "应用卸载"
        case .preferences: return "偏好设置"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .clipboard: return "doc.on.clipboard"
        case .finder: return "folder"
        case .archive: return "archivebox"
        case .displays: return "display"
        case .ports: return "network"
        case .uninstall: return "trash"
        case .preferences: return "gearshape"
        }
    }

    var searchTerms: [String] {
        switch self {
        case .overview:
            return ["概览", "状态", "本机", "系统", "overview", "status"]
        case .clipboard:
            return ["剪贴板", "复制", "粘贴", "收藏", "历史", "clipboard"]
        case .finder:
            return ["finder", "右键", "菜单", "扩展", "打开方式"]
        case .archive:
            return ["压缩", "解压", "归档", "zip", "tar", "rar", "7z"]
        case .displays:
            return ["显示器", "屏幕", "亮度", "音量", "分辨率", "ddc"]
        case .ports:
            return ["端口", "进程", "监听", "网络", "pid", "port"]
        case .uninstall:
            return ["应用", "卸载", "残留", "废纸篓", "uninstall"]
        case .preferences:
            return ["偏好设置", "设置", "权限", "诊断", "备份", "更新", "icloud"]
        }
    }
}
