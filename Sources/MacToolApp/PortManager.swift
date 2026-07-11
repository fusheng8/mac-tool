import AppKit
import Darwin
import Foundation
import MacToolCore

struct PortUsage: Hashable, Identifiable {
    var id: String {
        "\(pid)-\(protocolName)-\(endpoint)"
    }

    let port: Int
    let protocolName: String
    let endpoint: String
    let pid: Int32
    let command: String
    let user: String
    let executablePath: String
    let bundlePath: String?

    var listenAddress: String {
        Self.parseAddress(endpoint: endpoint)
    }

    var addressScope: PortAddressScope {
        PortAddressScope(address: listenAddress)
    }

    var displayName: String {
        if let runningAppName = NSRunningApplication(processIdentifier: pid)?.localizedName,
           !runningAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return runningAppName
        }
        return command
    }

    var displayPath: String {
        if let bundlePath, !bundlePath.isEmpty {
            return bundlePath
        }
        if !executablePath.isEmpty {
            return executablePath
        }
        return "未知路径"
    }

    private static func parseAddress(endpoint: String) -> String {
        if endpoint.hasPrefix("["),
           let closingBracket = endpoint.firstIndex(of: "]") {
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket])
        }

        guard let colonIndex = endpoint.lastIndex(of: ":") else {
            return endpoint
        }
        let address = endpoint[..<colonIndex]
        return address.isEmpty ? "*" : String(address)
    }
}

enum PortAddressScope: String, CaseIterable {
    case loopback
    case network

    init(address: String) {
        let normalized = address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "[::1]" {
            self = .loopback
        } else {
            self = .network
        }
    }

    var displayName: String {
        switch self {
        case .loopback:
            return "本机"
        case .network:
            return "局域网/对外"
        }
    }
}

enum PortStopMethod: String, CaseIterable {
    case graceful
    case terminate
    case kill

    var displayName: String {
        switch self {
        case .graceful:
            return "正常退出"
        case .terminate:
            return "TERM 终止"
        case .kill:
            return "KILL 强制"
        }
    }

    var riskDescription: String {
        switch self {
        case .graceful:
            return "最低风险：请求应用自行退出，可能被应用拒绝或延迟。"
        case .terminate:
            return "中等风险：发送 SIGTERM，请进程尽快结束，通常可做清理。"
        case .kill:
            return "高风险：发送 SIGKILL 立即结束，未保存数据可能丢失。"
        }
    }
}

struct ProcessResourceSnapshot: Hashable {
    let cpuPercent: Double?
    let residentMemoryBytes: UInt64?
    let virtualMemoryBytes: UInt64?
    let threadCount: Int?
    let openFileCount: Int?
    let parentPID: Int32?
    let state: String
    let elapsedTime: String
    let commandLine: String
}

enum PortManagerError: LocalizedError {
    case commandFailed(String)
    case killFailed(pid: Int32, reason: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        case .killFailed(let pid, let reason):
            return "无法停止进程 \(pid)：\(reason)"
        }
    }
}

struct PortCommandOutput {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

protocol PortCommandRunning {
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int) throws -> PortCommandOutput
}

final class PortCommandRunner: PortCommandRunning {
    private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var exceeded = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard data.count < limit else {
                exceeded = exceeded || !chunk.isEmpty
                return
            }
            let remaining = limit - data.count
            data.append(chunk.prefix(remaining))
            exceeded = exceeded || chunk.count > remaining
        }

        func snapshot() -> (data: Data, exceeded: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, exceeded)
        }
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 15,
        outputLimit: Int = 16 * 1_024 * 1_024
    ) throws -> PortCommandOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try launchProcessSafely(process, executableURL: executableURL)
        } catch {
            throw PortManagerError.commandFailed("无法运行 \(executableURL.lastPathComponent)：\(error.localizedDescription)")
        }

        let stdout = Accumulator(limit: outputLimit)
        let stderr = Accumulator(limit: outputLimit)
        let readers = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: stdout, group: readers)
        drain(stderrPipe.fileHandleForReading, into: stderr, group: readers)

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if process.isRunning {
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(0.3)
            while process.isRunning && Date() < terminateDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            guard waitForReaders(readers, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe) else {
                throw PortManagerError.commandFailed("外部命令已终止，但输出管道未关闭：\(executableURL.lastPathComponent)")
            }
            throw PortManagerError.commandFailed("外部命令超时，已终止：\(executableURL.lastPathComponent)")
        }

        guard waitForReaders(readers, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe) else {
            throw PortManagerError.commandFailed("外部命令输出管道超时未关闭：\(executableURL.lastPathComponent)")
        }
        let capturedStdout = stdout.snapshot()
        let capturedStderr = stderr.snapshot()
        if capturedStdout.exceeded || capturedStderr.exceeded {
            throw PortManagerError.commandFailed("外部命令输出超过安全限制：\(executableURL.lastPathComponent)")
        }
        return PortCommandOutput(
            exitCode: process.terminationStatus,
            stdout: capturedStdout.data,
            stderr: capturedStderr.data
        )
    }

    private func drain(_ handle: FileHandle, into accumulator: Accumulator, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                accumulator.append(chunk)
            }
        }
    }

    private func waitForReaders(_ readers: DispatchGroup, stdoutPipe: Pipe, stderrPipe: Pipe) -> Bool {
        guard readers.wait(timeout: .now() + 2) == .timedOut else { return true }
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()
        return false
    }
}

final class PortManager {
    private let commandRunner: any PortCommandRunning

    init(commandRunner: any PortCommandRunning = PortCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func shellKillCommand(pid: Int32, method: PortStopMethod) -> String? {
        switch method {
        case .graceful:
            return nil
        case .terminate:
            return "kill -TERM \(pid)"
        case .kill:
            return "kill -9 \(pid)"
        }
    }

    func locationURL(for usage: PortUsage) -> URL? {
        if let bundlePath = usage.bundlePath, FileManager.default.fileExists(atPath: bundlePath) {
            return URL(fileURLWithPath: bundlePath)
        }
        if !usage.executablePath.isEmpty, FileManager.default.fileExists(atPath: usage.executablePath) {
            return URL(fileURLWithPath: usage.executablePath)
        }
        return nil
    }

    func listListeningPorts() throws -> [PortUsage] {
        let tcpOutput = try runLsof(arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcLnP"])
        let udpOutput = (try? runLsof(arguments: ["-nP", "-iUDP", "-F", "pcLnP"])) ?? ""
        return parseLsofOutput(tcpOutput + "\n" + udpOutput)
            .sorted {
                if $0.port != $1.port {
                    return $0.port < $1.port
                }
                if $0.protocolName != $1.protocolName {
                    return $0.protocolName.localizedStandardCompare($1.protocolName) == .orderedAscending
                }
                if $0.displayName != $1.displayName {
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                return $0.pid < $1.pid
            }
    }

    func forceStop(pid: Int32) throws {
        try stop(pid: pid, method: .kill)
    }

    func stop(pid: Int32, method: PortStopMethod) throws {
        guard pid > 0 else {
            throw PortManagerError.killFailed(pid: pid, reason: "无效 PID")
        }
        guard pid != getpid() else {
            throw PortManagerError.killFailed(pid: pid, reason: "不能停止当前应用")
        }

        switch method {
        case .graceful:
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw PortManagerError.killFailed(pid: pid, reason: "找不到可正常退出的应用实例，请改用 TERM 终止")
            }
            guard app.terminate() else {
                throw PortManagerError.killFailed(pid: pid, reason: "应用拒绝正常退出，请改用 TERM 终止")
            }
        case .terminate:
            try sendSignal(SIGTERM, pid: pid)
        case .kill:
            try sendSignal(SIGKILL, pid: pid)
        }
    }

    func resourceSnapshot(pid: Int32) throws -> ProcessResourceSnapshot {
        let psInfo = try runPS(pid: pid)
        let taskInfo = Self.taskInfo(pid: pid)
        let openFileCount = try? openFileCount(pid: pid)

        return ProcessResourceSnapshot(
            cpuPercent: psInfo.cpuPercent,
            residentMemoryBytes: taskInfo?.residentMemoryBytes,
            virtualMemoryBytes: taskInfo?.virtualMemoryBytes,
            threadCount: taskInfo?.threadCount,
            openFileCount: openFileCount,
            parentPID: psInfo.parentPID,
            state: psInfo.state,
            elapsedTime: psInfo.elapsedTime,
            commandLine: psInfo.commandLine
        )
    }

    private func runLsof(arguments: [String]) throws -> String {
        let result = try commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: arguments,
            timeout: 20,
            outputLimit: 16 * 1_024 * 1_024
        )
        let output = String(decoding: result.stdout, as: UTF8.self)
        let errorOutput = String(decoding: result.stderr, as: UTF8.self)

        if result.exitCode != 0 && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PortManagerError.commandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "lsof 查询失败" : errorOutput)
        }
        return output
    }

    private func sendSignal(_ signal: Int32, pid: Int32) throws {
        if Darwin.kill(pid, signal) != 0 {
            throw PortManagerError.killFailed(pid: pid, reason: String(cString: strerror(errno)))
        }
    }

    private func runPS(pid: Int32) throws -> PSProcessInfo {
        let result = try commandRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "ppid=", "-o", "pcpu=", "-o", "stat=", "-o", "etime=", "-o", "command="],
            timeout: 10,
            outputLimit: 1 * 1_024 * 1_024
        )
        let output = String(decoding: result.stdout, as: UTF8.self)
        let errorOutput = String(decoding: result.stderr, as: UTF8.self)

        guard result.exitCode == 0 else {
            throw PortManagerError.commandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ps 查询失败" : errorOutput)
        }

        guard let line = output.split(separator: "\n", omittingEmptySubsequences: true).first else {
            throw PortManagerError.commandFailed("进程 \(pid) 不存在或已退出")
        }

        let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard fields.count >= 4 else {
            throw PortManagerError.commandFailed("ps 输出格式无法解析")
        }

        return PSProcessInfo(
            parentPID: Int32(String(fields[0])),
            cpuPercent: Double(String(fields[1])),
            state: String(fields[2]),
            elapsedTime: String(fields[3]),
            commandLine: fields.count >= 5 ? String(fields[4]) : ""
        )
    }

    private func openFileCount(pid: Int32) throws -> Int {
        let result = try commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-p", "\(pid)", "-F", "f"],
            timeout: 20,
            outputLimit: 16 * 1_024 * 1_024
        )
        let output = String(decoding: result.stdout, as: UTF8.self)
        if result.exitCode != 0 && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PortManagerError.commandFailed("lsof 查询进程打开文件失败")
        }
        return output.split(separator: "\n").filter { $0.first == "f" }.count
    }

    private func parseLsofOutput(_ output: String) -> [PortUsage] {
        var currentPID: Int32?
        var currentCommand = ""
        var currentUser = ""
        var currentProtocol = ""
        var results: [PortUsage] = []
        var seenIDs = Set<String>()

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let field = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch field {
            case "p":
                currentPID = Int32(value)
                currentCommand = ""
                currentUser = ""
                currentProtocol = ""
            case "c":
                currentCommand = value
            case "L":
                currentUser = value
            case "P":
                currentProtocol = value.uppercased()
            case "n":
                guard let pid = currentPID, let port = PortEndpointParser.port(from: value) else {
                    continue
                }
                let endpoint = value
                let protocolName = currentProtocol.isEmpty ? PortEndpointParser.inferredProtocol(from: endpoint) : currentProtocol
                let id = "\(pid)-\(protocolName)-\(endpoint)"
                guard !seenIDs.contains(id) else {
                    continue
                }
                seenIDs.insert(id)

                let bundlePath = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path
                results.append(PortUsage(
                    port: port,
                    protocolName: protocolName,
                    endpoint: endpoint,
                    pid: pid,
                    command: currentCommand,
                    user: currentUser,
                    executablePath: Self.executablePath(pid: pid),
                    bundlePath: bundlePath
                ))
            default:
                continue
            }
        }

        return results
    }

    private static func executablePath(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    private static func taskInfo(pid: Int32) -> TaskProcessInfo? {
        var info = proc_taskinfo()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<proc_taskinfo>.size) { rebound in
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, rebound, Int32(MemoryLayout<proc_taskinfo>.size))
            }
        }
        guard result == MemoryLayout<proc_taskinfo>.size else {
            return nil
        }
        return TaskProcessInfo(
            residentMemoryBytes: info.pti_resident_size,
            virtualMemoryBytes: info.pti_virtual_size,
            threadCount: Int(info.pti_threadnum)
        )
    }
}

private struct PSProcessInfo {
    let parentPID: Int32?
    let cpuPercent: Double?
    let state: String
    let elapsedTime: String
    let commandLine: String
}

private struct TaskProcessInfo {
    let residentMemoryBytes: UInt64
    let virtualMemoryBytes: UInt64
    let threadCount: Int
}
