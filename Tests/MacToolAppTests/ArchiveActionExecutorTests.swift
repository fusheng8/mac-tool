import XCTest
@testable import MacToolApp
import MacToolCore

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

    func testSmartExtractRarUsesBundledEngineAndFlattensSingleFile() throws {
        let root = try makeTemporaryDirectory()
        let archiveURL = root.appendingPathComponent("fixture.rar")
        try FileManager.default.copyItem(at: fixtureURL("rar5-basic.rar"), to: archiveURL)

        try ArchiveActionExecutor().smartExtract(urls: [archiveURL])

        let extractedFile = root
            .appendingPathComponent("2026-06-02.jsonl")
        XCTAssertEqual(try String(contentsOf: extractedFile, encoding: .utf8), "{\"ok\":true}\n")
    }

    func testEncryptedRar5PasswordValidationUsesBundledEngine() throws {
        let service = try ArchiveBrowserService(archiveURL: fixtureURL("rar5-encrypted.rar"))
        XCTAssertTrue(try service.requiresPassword())
        XCTAssertThrowsError(try service.validatePassword("wrong"))
        XCTAssertNoThrow(try service.validatePassword("secret"))
        XCTAssertTrue(try service.listEntries(password: "secret").entries.contains { $0.path.hasSuffix("2026-06-02.jsonl") })
    }

    func testLegacyRarCanBeListedByBundledEngine() throws {
        let entries = try ArchiveBrowserService(archiveURL: fixtureURL("rar-legacy-v2.rar")).listEntries().entries
        XCTAssertTrue(entries.contains { $0.path == "test.txt" })
        XCTAssertTrue(entries.contains { $0.path == "testdir/test.txt" })
    }

    func testArchiveFormatDetectorUsesSignatureBeforeExtension() throws {
        let root = try makeTemporaryDirectory()
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try "content".write(to: sourceRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let archiveURL = root.appendingPathComponent("renamed.data")
        try runTool(name: "zip", arguments: ["-q", archiveURL.path, "file.txt"], currentDirectory: sourceRoot)

        XCTAssertEqual(ArchiveFormatDetector.detect(url: archiveURL), .zip)
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

    func testTarBrowserListsRealPathsAndPartiallyExtracts() throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("目录", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "tar-content".write(to: nested.appendingPathComponent("file name.txt"), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("fixture.tar")
        try runTool(name: "tar", arguments: ["-cf", archive.path, "-C", source.path, "目录"])

        let service = try ArchiveBrowserService(archiveURL: archive)
        let entries = try service.listEntries().entries
        let fileEntry = try XCTUnwrap(entries.first { $0.path == "目录/file name.txt" })
        XCTAssertEqual(fileEntry.size, 11)

        let destination = root.appendingPathComponent("partial", isDirectory: true)
        try service.extract(entries: [fileEntry], to: destination, password: nil)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("目录/file name.txt"), encoding: .utf8),
            "tar-content"
        )
    }

    func testAESZipPasswordValidationAndExtraction() throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "secret".write(to: source.appendingPathComponent("秘密.txt"), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("aes.zip")
        try runBundledSevenZip(
            arguments: ["a", "-tzip", "-mem=AES256", "-pcorrect-password", archive.path, "秘密.txt"],
            currentDirectory: source
        )

        let service = try ArchiveBrowserService(archiveURL: archive)
        XCTAssertTrue(try service.requiresPassword())
        XCTAssertThrowsError(try service.validatePassword("wrong-password"))
        XCTAssertNoThrow(try service.validatePassword("correct-password"))
        let entry = try XCTUnwrap(try service.listEntries(password: "correct-password").entries.first)
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try service.extract(entries: [entry], to: destination, password: "correct-password")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("秘密.txt"), encoding: .utf8), "secret")
    }

    func testEncryptedSevenZipPasswordValidationAndExtraction() throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "encrypted-7z".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("encrypted.7z")
        let engine = ArchiveEngine()
        try engine.create(ArchiveCreationRequest(
            sourceParent: source,
            sourceNames: ["file.txt"],
            destinationURL: archive,
            format: .sevenZip,
            compressionLevel: 6,
            password: "secret",
            stripMacMetadata: true
        ))
        let service = try ArchiveBrowserService(archiveURL: archive)
        XCTAssertTrue(try service.requiresPassword())
        XCTAssertThrowsError(try service.validatePassword("wrong"))
        XCTAssertNoThrow(try service.validatePassword("secret"))
        let destination = root.appendingPathComponent("output", isDirectory: true)
        let entry = try XCTUnwrap(try service.listEntries(password: "secret").entries.first)
        try service.extract(entries: [entry], to: destination, password: "secret")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("file.txt"), encoding: .utf8), "encrypted-7z")
    }

    func testExtractHereKeepsExistingFileAndRenamesExtractedConflict() throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "new".write(to: source.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("fixture.zip")
        try runTool(name: "zip", arguments: ["-q", archive.path, "same.txt"], currentDirectory: source)
        try "old".write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)

        try ArchiveActionExecutor().extractHere(urls: [archive])

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("same.txt"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("same 2.txt"), encoding: .utf8), "new")
    }

    func testCommandRunnerDrainsOutputLargerThanPipeBuffer() throws {
        let result = try ArchiveCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i = 0; i < 20000; i++) print \"archive-entry-\" i }"] ,
            timeout: 10,
            outputLimit: 1_024 * 1_024
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertGreaterThan(result.stdout.count, 64 * 1_024)
    }

    func testCommandRunnerCancellationTerminatesChild() {
        let token = ArchiveCancellationToken()
        token.cancel()
        let started = Date()
        XCTAssertThrowsError(try ArchiveCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeout: 10,
            cancellation: token
        )) { error in
            guard case ArchiveEngineError.cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testCommandRunnerReportsPercentProgress() throws {
        var values: [Double] = []
        let lock = NSLock()
        _ = try ArchiveCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["10%% 42%% 100%%"],
            progressHandler: { value in
                lock.lock()
                values.append(value)
                lock.unlock()
            }
        )
        lock.lock()
        let captured = values
        lock.unlock()
        XCTAssertEqual(captured.last, 1)
        XCTAssertTrue(captured.contains(0.42))
    }

    func testArchiveEngineRejectsTraversalAndEscapingSymlinks() {
        let traversal = ArchiveEntry(
            id: 0,
            path: "../outside.txt",
            rawPath: "../outside.txt",
            size: 1,
            packedSize: 1,
            isDirectory: false,
            isSymbolicLink: false,
            linkTarget: nil,
            modifiedAt: nil,
            isEncrypted: false
        )
        let escapingLink = ArchiveEntry(
            id: 1,
            path: "safe/link",
            rawPath: "safe/link",
            size: 0,
            packedSize: 0,
            isDirectory: false,
            isSymbolicLink: true,
            linkTarget: "../../outside",
            modifiedAt: nil,
            isEncrypted: false
        )

        XCTAssertThrowsError(try ArchiveEngine().validateEntryPaths([traversal]))
        XCTAssertThrowsError(try ArchiveEngine().validateEntryPaths([escapingLink]))
    }

    func testArchiveNameValidationRejectsPathTraversalAndControlCharacters() throws {
        let parent = try makeTemporaryDirectory()
        for name in ["", ".", "..", "../backup", "a/b", "a\\b", "bad\u{0000}name"] {
            XCTAssertThrowsError(try ArchiveActionExecutor.validatedArchiveFileName(name, format: .zip, parent: parent), name)
        }
    }

    func testArchiveNameValidationAcceptsLocalizedAndMultiDotNames() throws {
        let parent = try makeTemporaryDirectory()
        XCTAssertEqual(
            try ArchiveActionExecutor.validatedArchiveFileName("项目 备份.v2", format: .zip, parent: parent),
            "项目 备份.v2.zip"
        )
        XCTAssertEqual(
            try ArchiveActionExecutor.validatedArchiveFileName("项目 备份.ZIP", format: .zip, parent: parent),
            "项目 备份.ZIP"
        )
    }

    func testBundledEngineRoundTripsAllWritableFormats() throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "round-trip".write(to: source.appendingPathComponent("跨平台 file.txt"), atomically: true, encoding: .utf8)
        let engine = ArchiveEngine()
        let formats: [ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXz, .gzip, .bzip2, .xz, .sevenZip]

        for format in formats {
            let archive = root.appendingPathComponent("fixture-\(format.rawValue).\(format.archiveExtension)")
            try engine.create(ArchiveCreationRequest(
                sourceParent: source,
                sourceNames: ["跨平台 file.txt"],
                destinationURL: archive,
                format: format,
                compressionLevel: 6,
                password: nil,
                stripMacMetadata: true
            ))
            let listed = try engine.list(archive)
            let extractedName = (format == .bzip2 || format == .xz)
                ? archive.deletingPathExtension().lastPathComponent
                : "跨平台 file.txt"
            XCTAssertTrue(listed.contains { $0.path == extractedName }, "Failed to list \(format)")
            let output = root.appendingPathComponent("output-\(format.rawValue)", isDirectory: true)
            try engine.extract(ArchiveExtractionRequest(archiveURL: archive, destinationURL: output, paths: nil, password: nil))
            XCTAssertEqual(
                try String(contentsOf: output.appendingPathComponent(extractedName), encoding: .utf8),
                "round-trip",
                "Failed to extract \(format)"
            )
        }
    }

    func testLegacyCP437ZipFileName() throws {
        let root = try makeTemporaryDirectory()
        let archive = root.appendingPathComponent("cp437.zip")
        try createStoredZip(
            at: archive,
            rawName: Data([0x63, 0x61, 0x66, 0x82, 0x2E, 0x74, 0x78, 0x74]),
            contents: Data("cp437".utf8)
        )

        let entries = try ArchiveEngine().list(archive)
        XCTAssertEqual(entries.map(\.path), ["café.txt"])
    }

    func testLegacyGBKZipFileName() throws {
        let root = try makeTemporaryDirectory()
        let archive = root.appendingPathComponent("gbk.zip")
        try createStoredZip(
            at: archive,
            rawName: Data([0xD6, 0xD0, 0xCE, 0xC4, 0x2E, 0x74, 0x78, 0x74]),
            contents: Data("gbk".utf8)
        )

        let entries = try ArchiveEngine().list(archive)
        XCTAssertEqual(entries.map(\.path), ["中文.txt"])
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try ArchiveEngine().extract(ArchiveExtractionRequest(
            archiveURL: archive,
            destinationURL: destination,
            paths: [try XCTUnwrap(entries.first?.rawPath)],
            password: nil
        ))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("中文.txt"), encoding: .utf8), "gbk")
    }

    func testZip64CentralDirectoryIsListedAndExtracted() throws {
        let root = try makeTemporaryDirectory()
        let archive = root.appendingPathComponent("forced-zip64.zip")
        try createStoredZip64(at: archive, name: Data("large-compatible.txt".utf8), contents: Data("zip64".utf8))

        let engine = ArchiveEngine()
        XCTAssertEqual(try engine.list(archive).map(\.path), ["large-compatible.txt"])
        let output = root.appendingPathComponent("output", isDirectory: true)
        try engine.extract(ArchiveExtractionRequest(archiveURL: archive, destinationURL: output, paths: nil, password: nil))
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("large-compatible.txt"), encoding: .utf8), "zip64")
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

    private func runTool(name: String, arguments: [String], currentDirectory: URL? = nil) throws {
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

    private func runBundledSevenZip(arguments: [String], currentDirectory: URL? = nil) throws {
        let toolURL = try ArchiveToolLocator().sevenZipURL()
        let result = try ArchiveCommandRunner().run(
            executableURL: toolURL,
            arguments: arguments,
            currentDirectory: currentDirectory
        )
        if result.status != 0 {
            XCTFail(result.stderrString + result.stdoutString)
        }
    }

    private func createStoredZip(at url: URL, rawName: Data, contents: Data) throws {
        let crc = crc32(contents)
        var local = Data()
        local.appendUInt32LE(0x0403_4B50)
        local.appendUInt16LE(20)
        local.appendUInt16LE(0)
        local.appendUInt16LE(0)
        local.appendUInt16LE(0)
        local.appendUInt16LE(0)
        local.appendUInt32LE(crc)
        local.appendUInt32LE(UInt32(contents.count))
        local.appendUInt32LE(UInt32(contents.count))
        local.appendUInt16LE(UInt16(rawName.count))
        local.appendUInt16LE(0)
        local.append(rawName)
        local.append(contents)

        var central = Data()
        central.appendUInt32LE(0x0201_4B50)
        central.appendUInt16LE(20)
        central.appendUInt16LE(20)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt32LE(crc)
        central.appendUInt32LE(UInt32(contents.count))
        central.appendUInt32LE(UInt32(contents.count))
        central.appendUInt16LE(UInt16(rawName.count))
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt32LE(0)
        central.appendUInt32LE(0)
        central.append(rawName)

        var end = Data()
        end.appendUInt32LE(0x0605_4B50)
        end.appendUInt16LE(0)
        end.appendUInt16LE(0)
        end.appendUInt16LE(1)
        end.appendUInt16LE(1)
        end.appendUInt32LE(UInt32(central.count))
        end.appendUInt32LE(UInt32(local.count))
        end.appendUInt16LE(0)

        var archive = local
        archive.append(central)
        archive.append(end)
        try archive.write(to: url)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc ^ UInt32.max
    }

    private func createStoredZip64(at url: URL, name: Data, contents: Data) throws {
        let crc = crc32(contents)
        var local = Data()
        local.appendUInt32LE(0x0403_4B50)
        local.appendUInt16LE(45)
        local.appendUInt16LE(0x0800)
        local.appendUInt16LE(0)
        local.appendUInt16LE(0)
        local.appendUInt16LE(0)
        local.appendUInt32LE(crc)
        local.appendUInt32LE(UInt32(contents.count))
        local.appendUInt32LE(UInt32(contents.count))
        local.appendUInt16LE(UInt16(name.count))
        local.appendUInt16LE(0)
        local.append(name)
        local.append(contents)

        var zip64Extra = Data()
        zip64Extra.appendUInt16LE(0x0001)
        zip64Extra.appendUInt16LE(24)
        zip64Extra.appendUInt64LE(UInt64(contents.count))
        zip64Extra.appendUInt64LE(UInt64(contents.count))
        zip64Extra.appendUInt64LE(0)

        let centralOffset = UInt64(local.count)
        var central = Data()
        central.appendUInt32LE(0x0201_4B50)
        central.appendUInt16LE(45)
        central.appendUInt16LE(45)
        central.appendUInt16LE(0x0800)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt32LE(crc)
        central.appendUInt32LE(UInt32.max)
        central.appendUInt32LE(UInt32.max)
        central.appendUInt16LE(UInt16(name.count))
        central.appendUInt16LE(UInt16(zip64Extra.count))
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt32LE(0)
        central.appendUInt32LE(UInt32.max)
        central.append(name)
        central.append(zip64Extra)

        let zip64EndOffset = centralOffset + UInt64(central.count)
        var zip64End = Data()
        zip64End.appendUInt32LE(0x0606_4B50)
        zip64End.appendUInt64LE(44)
        zip64End.appendUInt16LE(45)
        zip64End.appendUInt16LE(45)
        zip64End.appendUInt32LE(0)
        zip64End.appendUInt32LE(0)
        zip64End.appendUInt64LE(1)
        zip64End.appendUInt64LE(1)
        zip64End.appendUInt64LE(UInt64(central.count))
        zip64End.appendUInt64LE(centralOffset)

        var locator = Data()
        locator.appendUInt32LE(0x0706_4B50)
        locator.appendUInt32LE(0)
        locator.appendUInt64LE(zip64EndOffset)
        locator.appendUInt32LE(1)

        var end = Data()
        end.appendUInt32LE(0x0605_4B50)
        end.appendUInt16LE(0)
        end.appendUInt16LE(0)
        end.appendUInt16LE(UInt16.max)
        end.appendUInt16LE(UInt16.max)
        end.appendUInt32LE(UInt32.max)
        end.appendUInt32LE(UInt32.max)
        end.appendUInt16LE(0)

        var archive = local
        archive.append(central)
        archive.append(zip64End)
        archive.append(locator)
        archive.append(end)
        try archive.write(to: url)
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

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
