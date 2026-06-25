import XCTest
@testable import MacToolApp

final class ArchiveActionExecutorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testSmartExtractZipWithoutDirectoryEntries() throws {
        let root = try makeTemporaryDirectory()
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let nestedDirectory = sourceRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "console.log('ok')\n".write(
            to: nestedDirectory.appendingPathComponent("main.tsx"),
            atomically: true,
            encoding: .utf8
        )
        try "readme\n".write(
            to: sourceRoot.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let archiveURL = root.appendingPathComponent("fixture.zip")
        try runTool(
            name: "zip",
            arguments: ["-q", "-D", archiveURL.path, "src/main.tsx", "README.md"],
            currentDirectory: sourceRoot
        )

        try ArchiveActionExecutor().smartExtract(urls: [archiveURL])

        let extractedFile = root
            .appendingPathComponent("fixture", isDirectory: true)
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("main.tsx")
        XCTAssertEqual(try String(contentsOf: extractedFile, encoding: .utf8), "console.log('ok')\n")
    }

    func testSmartExtractRarPrefersUnrarCompatiblePath() throws {
        guard firstAvailableTool("rar") != nil else {
            throw XCTSkip("rar is not installed")
        }
        guard firstAvailableTool("unrar") != nil else {
            throw XCTSkip("unrar is not installed")
        }

        let root = try makeTemporaryDirectory()
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let nestedDirectory = sourceRoot.appendingPathComponent("log/checkins", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "{\"ok\":true}\n".write(
            to: nestedDirectory.appendingPathComponent("2026-06-02.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let archiveURL = root.appendingPathComponent("fixture.rar")
        try runTool(
            name: "rar",
            arguments: ["a", "-idq", "-m3", archiveURL.path, "log"],
            currentDirectory: sourceRoot
        )

        try ArchiveActionExecutor().smartExtract(urls: [archiveURL])

        let extractedFile = root
            .appendingPathComponent("fixture", isDirectory: true)
            .appendingPathComponent("log/checkins", isDirectory: true)
            .appendingPathComponent("2026-06-02.jsonl")
        XCTAssertEqual(try String(contentsOf: extractedFile, encoding: .utf8), "{\"ok\":true}\n")
    }

    func testZipExtractionFallbackDetectsUnzipWritePrompt() {
        let message = """
        User/User_76561198697327662/Player/RGD_Users - ����.rgd:  write error (disk full?).  Continue? (y/n/^C) fchmod (file attributes) error: Bad file descriptor
        warning:  cannot set modif./access times
        """

        XCTAssertTrue(zipExtractionShouldFallbackToSevenZip(message: message))
    }

    func testArchiveBrowserDeleteZipEntryDoesNotCrashAndUpdatesArchive() throws {
        let root = try makeTemporaryDirectory()
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try "delete me\n".write(to: sourceRoot.appendingPathComponent("remove.txt"), atomically: true, encoding: .utf8)
        try "keep me\n".write(to: sourceRoot.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        let archiveURL = root.appendingPathComponent("fixture.zip")
        try runTool(
            name: "zip",
            arguments: ["-q", archiveURL.path, "remove.txt", "keep.txt"],
            currentDirectory: sourceRoot
        )

        let service = try ArchiveBrowserService(archiveURL: archiveURL)
        let entries = try service.listEntries().entries
        let removedEntry = try XCTUnwrap(entries.first { $0.path == "remove.txt" })

        try service.delete(entries: [removedEntry], password: nil)

        let remainingPaths = try service.listEntries().entries.map(\.path)
        XCTAssertFalse(remainingPaths.contains("remove.txt"))
        XCTAssertTrue(remainingPaths.contains("keep.txt"))
    }

    func testLaunchProcessSafelyReportsUnsetExecutableWithoutCrashing() throws {
        let shellURL = URL(fileURLWithPath: "/bin/sh")
        let process = Process()

        XCTAssertThrowsError(try launchProcessSafely(process, executableURL: shellURL)) { error in
            guard let launchError = error as? ProcessLaunchError else {
                return XCTFail("Expected ProcessLaunchError, got \(error)")
            }
            XCTAssertTrue(launchError.localizedDescription.contains("未设置执行文件路径"))
        }
    }

    func testLaunchProcessSafelyReportsNonExecutableFileWithoutCrashing() throws {
        let root = try makeTemporaryDirectory()
        let executableURL = root.appendingPathComponent("tool")
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = executableURL

        XCTAssertThrowsError(try launchProcessSafely(process, executableURL: executableURL)) { error in
            guard let launchError = error as? ProcessLaunchError else {
                return XCTFail("Expected ProcessLaunchError, got \(error)")
            }
            XCTAssertTrue(launchError.localizedDescription.contains("执行文件不存在或不可执行"))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacToolAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func runTool(name: String, arguments: [String], currentDirectory: URL) throws {
        let toolURL = try XCTUnwrap(firstAvailableTool(name))
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "\(name) failed"
            XCTFail(message)
        }
    }

    private func firstAvailableTool(_ name: String) -> URL? {
        for directory in archiveToolSearchDirectories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
