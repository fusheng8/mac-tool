import DDCBackend
import Foundation

struct ProcessLaunchError: LocalizedError {
    let executableURL: URL
    let message: String

    var errorDescription: String? {
        "无法启动外部命令 \(executableURL.lastPathComponent)：\(message)"
    }
}

func launchProcessSafely(_ process: Process, executableURL: URL) throws {
    let fileManager = FileManager.default
    guard process.executableURL != nil else {
        throw ProcessLaunchError(executableURL: executableURL, message: "未设置执行文件路径")
    }
    guard fileManager.isExecutableFile(atPath: executableURL.path) else {
        throw ProcessLaunchError(executableURL: executableURL, message: "执行文件不存在或不可执行")
    }
    if let currentDirectoryURL = process.currentDirectoryURL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: currentDirectoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProcessLaunchError(executableURL: executableURL, message: "工作目录不存在")
        }
    }

    var launchError: NSError?
    var exceptionMessage: NSString?
    guard DCLLaunchTaskSafely(process, &launchError, &exceptionMessage) else {
        let message = (exceptionMessage as String?) ?? launchError?.localizedDescription ?? "未知启动错误"
        throw ProcessLaunchError(executableURL: executableURL, message: message)
    }
}
