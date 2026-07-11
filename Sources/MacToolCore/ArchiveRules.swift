import Foundation

public enum ArchiveRules {
    public static let toolSearchDirectories = ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"]

    public static func missingToolMessage(_ name: String) -> String {
        let lowercased = name.lowercased()
        let requiredTools: String
        let installSuggestion: String
        if lowercased.contains("unrar") || lowercased.contains("rar") {
            requiredTools = "unrar 或 rar"
            installSuggestion = "brew install rar"
        } else if lowercased.contains("7z") || lowercased.contains("7zz") {
            requiredTools = "7zz 或 7z"
            installSuggestion = "brew install sevenzip"
        } else if lowercased.contains("xz") || lowercased.contains("unxz") {
            requiredTools = "xz 或 unxz"
            installSuggestion = "brew install xz"
        } else {
            requiredTools = name
            installSuggestion = "请通过 Homebrew 或系统工具安装 \(name)，并确认工具位于搜索路径中。"
        }

        return """
        当前系统缺少处理该格式所需的工具：\(requiredTools)
        安装建议：\(installSuggestion)
        当前搜索路径：\(toolSearchDirectories.joined(separator: ", "))
        """
    }
}
