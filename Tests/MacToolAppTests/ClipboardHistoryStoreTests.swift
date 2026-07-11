import AppKit
import XCTest
@testable import MacToolApp

final class ClipboardHistoryStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testInsertReadsStoredTypesAndSplitsInlineAndBlobStorage() throws {
        let fixture = try makeStoreFixture()
        let smallText = ClipboardStoredType(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("hello".utf8))
        let largeHTML = ClipboardStoredType(type: NSPasteboard.PasteboardType.html.rawValue, data: Data(repeating: 65, count: 40_000))
        let item = makeItem(
            preview: "hello",
            plainText: "hello",
            storedTypes: [smallText, largeHTML],
            metadata: makeMetadata(contentType: "富文本", pasteboardTypes: [smallText.type, largeHTML.type])
        )

        let loaded = try fixture.store.insert(item, maxHistoryCount: 20, retentionDays: 30)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].storedTypes.count, 0)
        XCTAssertEqual(try fixture.store.loadStoredTypes(itemID: item.id), [smallText, largeHTML])
        XCTAssertTrue(try containsFile(in: fixture.blobDirectory))
    }

    func testDuplicateInsertKeepsFavoriteState() throws {
        let fixture = try makeStoreFixture()
        let storedType = ClipboardStoredType(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("same".utf8))
        let first = makeItem(preview: "same", plainText: "same", storedTypes: [storedType], isFavorite: true)
        let second = makeItem(preview: "same", plainText: "same", storedTypes: [storedType], isFavorite: false)

        _ = try fixture.store.insert(first, maxHistoryCount: 20, retentionDays: 30)
        let loaded = try fixture.store.insert(second, maxHistoryCount: 20, retentionDays: 30)

        XCTAssertEqual(loaded.map(\.id), [second.id])
        XCTAssertTrue(loaded[0].isFavorite)
    }

    func testFTSSearchFindsPreviewPlainTextFilePathAndSourceApp() throws {
        let fixture = try makeStoreFixture()
        let storedType = ClipboardStoredType(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("Quarterly budget notes".utf8))
        let item = makeItem(
            sourceApplicationName: "Google Chrome",
            preview: "Quarterly budget",
            plainText: "Quarterly budget notes",
            storedTypes: [storedType],
            metadata: makeMetadata(
                contentType: "文件",
                detailText: "文件 · budget.txt",
                sourcePaths: ["/Users/example/Documents/budget.txt"],
                fileNames: ["budget.txt"],
                pasteboardTypes: [storedType.type]
            )
        )
        _ = try fixture.store.insert(item, maxHistoryCount: 20, retentionDays: 30)

        XCTAssertEqual(try fixture.store.search("Quarterly", limit: 10).map(\.id), [item.id])
        XCTAssertEqual(try fixture.store.search("budget", limit: 10).map(\.id), [item.id])
        XCTAssertEqual(try fixture.store.search("Chrome", limit: 10).map(\.id), [item.id])
        XCTAssertEqual(
            try fixture.store.search(
                "budget",
                filter: ClipboardHistorySearchFilter(applicationKey: "app:com.example.test"),
                limit: 10
            ).map(\.id),
            [item.id]
        )
        XCTAssertTrue(
            try fixture.store.search(
                "budget",
                filter: ClipboardHistorySearchFilter(favoritesOnly: true),
                limit: 10
            ).isEmpty
        )
    }

    func testDeleteAndClearRemoveBlobAndThumbnailFiles() throws {
        let fixture = try makeStoreFixture()
        let imageType = ClipboardStoredType(type: NSPasteboard.PasteboardType.png.rawValue, data: try makePNGData())
        let largeType = ClipboardStoredType(type: "public.html", data: Data(repeating: 66, count: 40_000))
        let item = makeItem(
            preview: "图片",
            plainText: "",
            storedTypes: [imageType, largeType],
            metadata: makeMetadata(contentType: "图片", pasteboardTypes: [imageType.type, largeType.type], imagePixelWidth: 2, imagePixelHeight: 2)
        )

        _ = try fixture.store.insert(item, maxHistoryCount: 20, retentionDays: 30)
        XCTAssertNotNil(try fixture.store.ensureThumbnail(for: item.id))
        XCTAssertTrue(try containsFile(in: fixture.blobDirectory))
        XCTAssertTrue(try containsFile(in: fixture.thumbnailDirectory))

        _ = try fixture.store.delete(item.id)
        XCTAssertFalse(try containsFile(in: fixture.blobDirectory))
        XCTAssertFalse(try containsFile(in: fixture.thumbnailDirectory))
    }

    func testLegacyJSONMigrationPreservesMetadataAndStoredTypes() throws {
        let root = try makeTemporaryDirectory()
        let legacyURL = root.appendingPathComponent("clipboard-history.json")
        let storedType = ClipboardStoredType(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("legacy".utf8))
        let item = makeItem(
            preview: "legacy",
            plainText: "legacy",
            storedTypes: [storedType],
            isFavorite: true,
            metadata: makeMetadata(contentType: "文本", detailText: "文本 · 纯文本", pasteboardTypes: [storedType.type])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([item]).write(to: legacyURL, options: .atomic)

        let fixture = try makeStoreFixture(rootDirectory: root, legacyHistoryURL: legacyURL)
        let loaded = try fixture.store.loadHistory(maxHistoryCount: 20, retentionDays: 30)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, item.id)
        XCTAssertTrue(loaded[0].isFavorite)
        XCTAssertEqual(loaded[0].metadata.detailText, "文本 · 纯文本")
        XCTAssertEqual(try fixture.store.loadStoredTypes(itemID: item.id), [storedType])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("clipboard-history.json.migrated").path))
    }

    func testDatabaseAndBlobDoNotContainPlaintext() throws {
        let fixture = try makeStoreFixture()
        let secret = "TOP-SECRET-CLIPBOARD-VALUE"
        let storedType = ClipboardStoredType(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(secret.utf8))
        _ = try fixture.store.insert(
            makeItem(preview: secret, plainText: secret, storedTypes: [storedType]),
            maxHistoryCount: 20,
            retentionDays: 30
        )

        let allFiles = try FileManager.default.subpathsOfDirectory(atPath: fixture.rootDirectory.path)
        for relativePath in allFiles {
            let url = fixture.rootDirectory.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let data = try Data(contentsOf: url)
            XCTAssertNil(data.range(of: Data(secret.utf8)), "明文出现在 \(relativePath)")
        }
    }

    func testWrongEncryptionKeyCannotReadHistory() throws {
        let root = try makeTemporaryDirectory()
        let fixture = try makeStoreFixture(rootDirectory: root)
        let storedType = ClipboardStoredType(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("encrypted".utf8))
        _ = try fixture.store.insert(
            makeItem(preview: "encrypted", plainText: "encrypted", storedTypes: [storedType]),
            maxHistoryCount: 20,
            retentionDays: 30
        )
        let clipboardDirectory = root.appendingPathComponent("Clipboard", isDirectory: true)
        let reopened = ClipboardHistoryStore(
            rootDirectory: clipboardDirectory,
            databaseURL: clipboardDirectory.appendingPathComponent("clipboard-v2.sqlite"),
            blobDirectory: fixture.blobDirectory,
            thumbnailDirectory: fixture.thumbnailDirectory,
            thumbnailCacheDirectory: clipboardDirectory.appendingPathComponent("cache-2"),
            legacyHistoryURL: nil,
            cryptoProvider: EphemeralClipboardCryptoProvider(keyData: Data(repeating: 0x3C, count: 32))
        )
        XCTAssertThrowsError(try reopened.loadHistory(maxHistoryCount: 20, retentionDays: 30))
    }

    func testFailedDuplicateInsertKeepsOriginalBlobReadable() throws {
        let crypto = ControllableClipboardCryptoProvider()
        let fixture = try makeStoreFixture(cryptoProvider: crypto)
        let storedType = ClipboardStoredType(type: "public.html", data: Data(repeating: 65, count: 40_000))
        let original = makeItem(preview: "same", plainText: "same", storedTypes: [storedType], isFavorite: true)
        _ = try fixture.store.insert(original, maxHistoryCount: 20, retentionDays: 30)

        crypto.failAfterSuccessfulSeals(1)
        let replacement = makeItem(preview: "same", plainText: "same", storedTypes: [storedType])
        XCTAssertThrowsError(try fixture.store.insert(replacement, maxHistoryCount: 20, retentionDays: 30))

        crypto.disableFailure()
        let loaded = try fixture.store.loadHistory(maxHistoryCount: 20, retentionDays: 30)
        XCTAssertEqual(loaded.map(\.id), [original.id])
        XCTAssertEqual(try fixture.store.loadStoredTypes(itemID: original.id), [storedType])
        XCTAssertTrue(try containsFile(in: fixture.blobDirectory))
    }

    func testFailedInsertRemovesNewBlobDirectory() throws {
        let crypto = ControllableClipboardCryptoProvider()
        let fixture = try makeStoreFixture(cryptoProvider: crypto)
        let firstBlob = ClipboardStoredType(type: "public.html", data: Data(repeating: 65, count: 40_000))
        let secondBlob = ClipboardStoredType(type: "public.rtf", data: Data(repeating: 66, count: 40_000))
        crypto.failAfterSuccessfulSeals(2)

        XCTAssertThrowsError(try fixture.store.insert(
            makeItem(preview: "failure", plainText: "", storedTypes: [firstBlob, secondBlob]),
            maxHistoryCount: 20,
            retentionDays: 30
        ))
        XCTAssertFalse(try containsFile(in: fixture.blobDirectory))
    }

    func testLoadHistoryRemovesOrphanedBlobDirectory() throws {
        let fixture = try makeStoreFixture()
        let orphan = fixture.blobDirectory.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan.appendingPathComponent("0.blob"))

        _ = try fixture.store.loadHistory(maxHistoryCount: 20, retentionDays: 30)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    private func makeStoreFixture(
        rootDirectory: URL? = nil,
        legacyHistoryURL: URL? = nil,
        cryptoProvider: any ClipboardCryptoProviding = EphemeralClipboardCryptoProvider()
    ) throws -> (store: ClipboardHistoryStore, rootDirectory: URL, blobDirectory: URL, thumbnailDirectory: URL) {
        let root = try rootDirectory ?? makeTemporaryDirectory()
        let clipboardDirectory = root.appendingPathComponent("Clipboard", isDirectory: true)
        let blobDirectory = clipboardDirectory.appendingPathComponent("encrypted-blobs", isDirectory: true)
        let thumbnailDirectory = clipboardDirectory.appendingPathComponent("encrypted-thumbnails", isDirectory: true)
        let store = ClipboardHistoryStore(
            rootDirectory: clipboardDirectory,
            databaseURL: clipboardDirectory.appendingPathComponent("clipboard-v2.sqlite"),
            blobDirectory: blobDirectory,
            thumbnailDirectory: thumbnailDirectory,
            thumbnailCacheDirectory: clipboardDirectory.appendingPathComponent("thumbnail-cache", isDirectory: true),
            legacyHistoryURL: legacyHistoryURL,
            cryptoProvider: cryptoProvider
        )
        return (store, root, blobDirectory, thumbnailDirectory)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeItem(
        sourceApplicationName: String = "Unit Test",
        preview: String,
        plainText: String,
        storedTypes: [ClipboardStoredType],
        isFavorite: Bool = false,
        metadata: ClipboardContentMetadata? = nil
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            sourceApplicationName: sourceApplicationName,
            sourceBundleIdentifier: "com.example.test",
            plainText: plainText,
            previewText: preview,
            storedTypes: storedTypes,
            isFavorite: isFavorite,
            metadata: metadata ?? makeMetadata(pasteboardTypes: storedTypes.map(\.type))
        )
    }

    private func makeMetadata(
        contentType: String = "文本",
        detailText: String = "文本 · 纯文本",
        sourcePaths: [String] = [],
        fileNames: [String] = [],
        pasteboardTypes: [String] = [],
        imagePixelWidth: Int? = nil,
        imagePixelHeight: Int? = nil
    ) -> ClipboardContentMetadata {
        ClipboardContentMetadata(
            contentType: contentType,
            detailText: detailText,
            sourcePaths: sourcePaths,
            fileNames: fileNames,
            pasteboardTypes: pasteboardTypes,
            imagePixelWidth: imagePixelWidth,
            imagePixelHeight: imagePixelHeight,
            thumbnailFileName: nil,
            contentByteCount: nil
        )
    }

    private func containsFile(in directory: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        let contents = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        return contents.contains { !$0.hasSuffix("/") }
    }

    private func makePNGData() throws -> Data {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let representation,
              let data = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ClipboardHistoryStoreTests", code: 1)
        }
        return data
    }
}

private enum TestClipboardCryptoError: Error {
    case forcedFailure
}

private final class ControllableClipboardCryptoProvider: ClipboardCryptoProviding, @unchecked Sendable {
    private let provider = EphemeralClipboardCryptoProvider()
    private let lock = NSLock()
    private var remainingSuccessfulSeals: Int?

    var statusDescription: String { provider.statusDescription }

    func failAfterSuccessfulSeals(_ count: Int) {
        lock.lock()
        remainingSuccessfulSeals = count
        lock.unlock()
    }

    func disableFailure() {
        lock.lock()
        remainingSuccessfulSeals = nil
        lock.unlock()
    }

    func seal(_ data: Data) throws -> Data {
        lock.lock()
        if let remaining = remainingSuccessfulSeals {
            if remaining == 0 {
                lock.unlock()
                throw TestClipboardCryptoError.forcedFailure
            }
            remainingSuccessfulSeals = remaining - 1
        }
        lock.unlock()
        return try provider.seal(data)
    }

    func open(_ data: Data) throws -> Data { try provider.open(data) }
    func authenticationHash(_ data: Data) -> String { provider.authenticationHash(data) }
}
