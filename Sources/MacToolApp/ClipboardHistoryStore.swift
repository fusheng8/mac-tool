import AppKit
import Foundation
import GRDB
import ImageIO
import MacToolCore

struct ClipboardHistorySearchFilter {
    static let empty = ClipboardHistorySearchFilter()
    var applicationKey: String?
    var favoritesOnly: Bool

    init(applicationKey: String? = nil, favoritesOnly: Bool = false) {
        self.applicationKey = applicationKey
        self.favoritesOnly = favoritesOnly
    }
}

final class ClipboardHistoryStore: @unchecked Sendable {
    private enum Constants {
        static let inlineDataLimit = 32 * 1024
        static let thumbnailMaxPixelSize = 108
    }

    private var databaseQueue: DatabaseQueue?
    private var crypto: (any ClipboardCryptoProviding)?
    private let rootDirectory: URL
    private let databaseURL: URL
    private let legacyDatabaseURL: URL?
    private let blobDirectory: URL
    private let thumbnailDirectory: URL
    private let thumbnailCacheDirectory: URL
    private let legacyHistoryURL: URL?
    private let fileManager: FileManager
    private let managesKeychain: Bool
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private(set) var initializationError: Error?

    var encryptionStatus: String {
        if let initializationError { return "已暂停 · \(initializationError.localizedDescription)" }
        return crypto?.statusDescription ?? "已暂停"
    }

    init(
        rootDirectory: URL = AppPaths.clipboardDirectory,
        databaseURL: URL = AppPaths.clipboardDatabaseURL,
        legacyDatabaseURL: URL? = nil,
        blobDirectory: URL = AppPaths.clipboardBlobDirectory,
        thumbnailDirectory: URL = AppPaths.clipboardThumbnailDirectory,
        thumbnailCacheDirectory: URL = AppPaths.clipboardThumbnailCacheDirectory,
        legacyHistoryURL: URL? = AppPaths.clipboardHistoryURL,
        fileManager: FileManager = .default,
        cryptoProvider: (any ClipboardCryptoProviding)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.databaseURL = databaseURL
        self.legacyDatabaseURL = legacyDatabaseURL ?? (
            databaseURL.standardizedFileURL == AppPaths.clipboardDatabaseURL.standardizedFileURL
                ? AppPaths.legacyClipboardDatabaseURL
                : nil
        )
        self.blobDirectory = blobDirectory
        self.thumbnailDirectory = thumbnailDirectory
        self.thumbnailCacheDirectory = thumbnailCacheDirectory
        self.legacyHistoryURL = legacyHistoryURL
        self.fileManager = fileManager
        managesKeychain = cryptoProvider == nil
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonDecoder.dateDecodingStrategy = .iso8601

        do {
            try createSecureDirectory(rootDirectory)
            try createSecureDirectory(blobDirectory)
            try createSecureDirectory(thumbnailDirectory)
            try createSecureDirectory(thumbnailCacheDirectory)
            let databaseExisted = fileManager.fileExists(atPath: databaseURL.path)
            crypto = try cryptoProvider ?? KeychainClipboardCryptoProvider(createIfMissing: !databaseExisted)

            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            try Self.migrator.migrate(queue)
            databaseQueue = queue
            try secureDatabaseFiles()
        } catch {
            initializationError = error
            AppLogger.shared.error("剪贴板加密存储初始化失败，已暂停记录：\(error.localizedDescription)")
        }
    }

    deinit {
        clearThumbnailCache()
    }

    func retryKeyAccess() throws {
        let provider = try KeychainClipboardCryptoProvider(createIfMissing: false)
        crypto = provider
        initializationError = nil
    }

    func clearUndecryptableHistory() throws {
        guard let databaseQueue else {
            for url in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")] {
                try? fileManager.removeItem(at: url)
            }
            try? fileManager.removeItem(at: blobDirectory)
            try? fileManager.removeItem(at: thumbnailDirectory)
            if managesKeychain {
                try KeychainClipboardCryptoProvider.resetKey()
                crypto = try KeychainClipboardCryptoProvider(createIfMissing: true)
            }
            try createSecureDirectory(rootDirectory)
            try createSecureDirectory(blobDirectory)
            try createSecureDirectory(thumbnailDirectory)
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let queue = try DatabaseQueue(path: self.databaseURL.path, configuration: configuration)
            try Self.migrator.migrate(queue)
            self.databaseQueue = queue
            initializationError = nil
            return
        }
        try databaseQueue.write { db in
            try db.execute(sql: "DELETE FROM clipboard_contents")
            try db.execute(sql: "DELETE FROM clipboard_items")
        }
        try? fileManager.removeItem(at: blobDirectory)
        try? fileManager.removeItem(at: thumbnailDirectory)
        try createSecureDirectory(blobDirectory)
        try createSecureDirectory(thumbnailDirectory)
        clearThumbnailCache()
    }

    func storageSize() -> Int64 {
        let urls = [databaseURL, blobDirectory, thumbnailDirectory]
        return urls.reduce(0) { total, url in
            total + (Self.allocatedSize(at: url, fileManager: fileManager) ?? 0)
        }
    }

    func loadHistory(maxHistoryCount: Int, retentionDays: Int) throws -> [ClipboardHistoryItem] {
        _ = try requireCrypto()
        try migrateLegacySQLiteIfNeeded()
        try migrateLegacyJSONIfNeeded()
        try prune(retentionDays: retentionDays)
        try trim(maxHistoryCount: maxHistoryCount)
        return try fetchItems()
    }

    func insert(_ item: ClipboardHistoryItem, maxHistoryCount: Int, retentionDays: Int) throws -> [ClipboardHistoryItem] {
        let crypto = try requireCrypto()
        let databaseQueue = try requireDatabase()
        try databaseQueue.write { db in
            let hash = contentHash(for: item.storedTypes, crypto: crypto)
            let duplicatedFavorite = try Bool.fetchOne(
                db,
                sql: "SELECT MAX(isFavorite) FROM clipboard_items WHERE contentHash = ?",
                arguments: [hash]
            ) ?? false
            var storedItem = item
            if duplicatedFavorite { storedItem.isFavorite = true }
            let duplicateIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM clipboard_items WHERE contentHash = ?",
                arguments: [hash]
            )
            try deleteItems(db, ids: duplicateIDs)
            try insertItem(db, storedItem, crypto: crypto, contentHash: hash)
        }
        try prune(retentionDays: retentionDays)
        try trim(maxHistoryCount: maxHistoryCount)
        try secureDatabaseFiles()
        return try fetchItems()
    }

    func search(_ query: String, filter: ClipboardHistorySearchFilter = .empty, limit: Int) throws -> [ClipboardHistoryItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return try fetchItems().filter { item in
            if filter.favoritesOnly && !item.isFavorite { return false }
            if let key = filter.applicationKey {
                if key.hasPrefix("app:"), item.sourceBundleIdentifier != String(key.dropFirst(4)) { return false }
                if key.hasPrefix("app-name:"), item.sourceApplicationName != String(key.dropFirst(9)) { return false }
            }
            guard !normalizedQuery.isEmpty else { return true }
            let searchable = ([
                item.previewText,
                item.plainText,
                item.metadata.detailText,
                item.sourceApplicationName
            ] + item.metadata.fileNames + item.metadata.sourcePaths)
                .joined(separator: "\n")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return searchable.contains(normalizedQuery)
        }.prefix(limit).map { $0 }
    }

    func loadStoredTypes(itemID: UUID) throws -> [ClipboardStoredType] {
        let crypto = try requireCrypto()
        return try requireDatabase().read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT storageMode, encryptedData, blobFileName FROM clipboard_contents WHERE itemId = ? ORDER BY sortOrder",
                arguments: [itemID.uuidString]
            )
            return try rows.map { row in
                let mode: String = row["storageMode"]
                let encrypted: Data
                if mode == "inline" {
                    guard let data: Data = row["encryptedData"] else { throw ClipboardCryptoError.invalidCiphertext }
                    encrypted = data
                } else {
                    guard let fileName: String = row["blobFileName"] else { throw ClipboardCryptoError.invalidCiphertext }
                    encrypted = try Data(contentsOf: blobDirectory.appendingPathComponent(fileName))
                }
                return try jsonDecoder.decode(ClipboardStoredType.self, from: crypto.open(encrypted))
            }
        }
    }

    func delete(_ itemID: UUID) throws -> [ClipboardHistoryItem] {
        try requireDatabase().write { db in try deleteItems(db, ids: [itemID.uuidString]) }
        return try fetchItems()
    }

    func toggleFavorite(_ itemID: UUID) throws -> [ClipboardHistoryItem] {
        try requireDatabase().write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET isFavorite = CASE isFavorite WHEN 1 THEN 0 ELSE 1 END WHERE id = ?",
                arguments: [itemID.uuidString]
            )
        }
        return try fetchItems()
    }

    func clearUnfavorited() throws -> [ClipboardHistoryItem] {
        try requireDatabase().write { db in
            try deleteItems(db, ids: String.fetchAll(db, sql: "SELECT id FROM clipboard_items WHERE isFavorite = 0"))
        }
        return try fetchItems()
    }

    func clearAll() throws -> [ClipboardHistoryItem] {
        try requireDatabase().write { db in
            try deleteItems(db, ids: String.fetchAll(db, sql: "SELECT id FROM clipboard_items"))
        }
        clearThumbnailCache()
        return []
    }

    func clearItems(kind: ClipboardContentKind) throws -> [ClipboardHistoryItem] {
        let ids = try fetchItems().filter { $0.metadata.contentType == kind.title && !$0.isFavorite }.map { $0.id.uuidString }
        try requireDatabase().write { db in try deleteItems(db, ids: ids) }
        return try fetchItems()
    }

    func countItems(kind: ClipboardContentKind) throws -> Int {
        try fetchItems().filter { $0.metadata.contentType == kind.title && !$0.isFavorite }.count
    }

    func thumbnailURL(for item: ClipboardHistoryItem) -> URL? {
        let url = thumbnailCacheDirectory.appendingPathComponent("\(item.id.uuidString).jpg")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func ensureThumbnail(for itemID: UUID) throws -> URL? {
        let crypto = try requireCrypto()
        let cacheURL = thumbnailCacheDirectory.appendingPathComponent("\(itemID.uuidString).jpg")
        if fileManager.fileExists(atPath: cacheURL.path) { return cacheURL }
        let encryptedURL = thumbnailDirectory.appendingPathComponent("\(itemID.uuidString).thumb")
        if fileManager.fileExists(atPath: encryptedURL.path) {
            let data = try crypto.open(Data(contentsOf: encryptedURL))
            try secureWrite(data, to: cacheURL)
            return cacheURL
        }
        guard let imageData = try imageData(for: itemID),
              let thumbnailData = Self.makeThumbnailData(from: imageData) else { return nil }
        try secureWrite(crypto.seal(thumbnailData), to: encryptedURL)
        try secureWrite(thumbnailData, to: cacheURL)
        return cacheURL
    }

    func clearThumbnailCache() {
        try? fileManager.removeItem(at: thumbnailCacheDirectory)
    }

    private func fetchItems(limit: Int? = nil) throws -> [ClipboardHistoryItem] {
        let crypto = try requireCrypto()
        let rows = try requireDatabase().read { db -> [Row] in
            if let limit {
                return try Row.fetchAll(db, sql: "SELECT * FROM clipboard_items ORDER BY sortKey DESC LIMIT ?", arguments: [limit])
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM clipboard_items ORDER BY sortKey DESC")
        }
        return try rows.map { row in
            let encrypted: Data = row["encryptedItem"]
            var item = try jsonDecoder.decode(ClipboardHistoryItem.self, from: crypto.open(encrypted))
            item.storedTypes = []
            item.isFavorite = row["isFavorite"]
            return item
        }
    }

    private func prune(retentionDays: Int) throws {
        guard retentionDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        try requireDatabase().write { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM clipboard_items WHERE isFavorite = 0 AND sortKey < ?",
                arguments: [cutoff.timeIntervalSince1970]
            )
            try deleteItems(db, ids: ids)
        }
    }

    private func trim(maxHistoryCount: Int) throws {
        try requireDatabase().write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0
            guard count > maxHistoryCount else { return }
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM clipboard_items WHERE isFavorite = 0 ORDER BY sortKey ASC LIMIT ?",
                arguments: [count - maxHistoryCount]
            )
            try deleteItems(db, ids: ids)
        }
    }

    private func insertItem(
        _ db: Database,
        _ item: ClipboardHistoryItem,
        crypto: any ClipboardCryptoProviding,
        contentHash: String
    ) throws {
        let totalBytes = item.storedTypes.reduce(0) { $0 + $1.data.count }
        var metadata = item.metadata
        metadata.contentByteCount = totalBytes
        var encryptedItem = item
        encryptedItem.metadata = metadata
        encryptedItem.storedTypes = []
        let payload = try crypto.seal(jsonEncoder.encode(encryptedItem))
        try db.execute(
            sql: "INSERT INTO clipboard_items (id, sortKey, isFavorite, contentHash, encryptedItem, byteCount) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [item.id.uuidString, item.createdAt.timeIntervalSince1970, item.isFavorite, contentHash, payload, totalBytes]
        )

        for (index, storedType) in item.storedTypes.enumerated() {
            let sealed = try crypto.seal(jsonEncoder.encode(storedType))
            let useBlob = storedType.data.count > Constants.inlineDataLimit || Self.isRichOrImageType(storedType.type)
            let fileName: String?
            let inlineData: Data?
            if useBlob {
                fileName = "\(item.id.uuidString)/\(index).blob"
                inlineData = nil
                try secureWrite(sealed, to: blobDirectory.appendingPathComponent(fileName!))
            } else {
                fileName = nil
                inlineData = sealed
            }
            try db.execute(
                sql: "INSERT INTO clipboard_contents (itemId, sortOrder, storageMode, encryptedData, blobFileName, byteCount) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [item.id.uuidString, index, useBlob ? "blob" : "inline", inlineData, fileName, storedType.data.count]
            )
        }
    }

    private func deleteItems(_ db: Database, ids: [String]) throws {
        for id in ids {
            try? fileManager.removeItem(at: blobDirectory.appendingPathComponent(id, isDirectory: true))
            try? fileManager.removeItem(at: thumbnailDirectory.appendingPathComponent("\(id).thumb"))
            try? fileManager.removeItem(at: thumbnailCacheDirectory.appendingPathComponent("\(id).jpg"))
            try db.execute(sql: "DELETE FROM clipboard_contents WHERE itemId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [id])
        }
    }

    private func imageData(for itemID: UUID) throws -> Data? {
        try loadStoredTypes(itemID: itemID).first { Self.isImageType($0.type) }?.data
    }

    private func migrateLegacyJSONIfNeeded() throws {
        guard let legacyHistoryURL, fileManager.fileExists(atPath: legacyHistoryURL.path) else { return }
        let items = try jsonDecoder.decode([ClipboardHistoryItem].self, from: Data(contentsOf: legacyHistoryURL))
        let crypto = try requireCrypto()
        try requireDatabase().write { db in
            for range in ClipboardPrivacyPolicy.batchRanges(itemCount: items.count) {
                for item in items[range] {
                    try insertItem(db, item, crypto: crypto, contentHash: contentHash(for: item.storedTypes, crypto: crypto))
                }
            }
        }
        let migratedIDs = Set(try fetchItems().map(\.id))
        guard items.allSatisfy({ migratedIDs.contains($0.id) }) else { throw ClipboardMigrationError.validationFailed }
        try fileManager.removeItem(at: legacyHistoryURL)
    }

    private func migrateLegacySQLiteIfNeeded() throws {
        guard let legacyDatabaseURL,
              legacyDatabaseURL.standardizedFileURL != databaseURL.standardizedFileURL,
              fileManager.fileExists(atPath: legacyDatabaseURL.path) else { return }
        let crypto = try requireCrypto()
        var configuration = Configuration()
        configuration.readonly = true
        let legacyQueue = try DatabaseQueue(path: legacyDatabaseURL.path, configuration: configuration)
        let legacyBlobDirectory = rootDirectory.appendingPathComponent("blobs", isDirectory: true)
        let items: [(ClipboardHistoryItem, [ClipboardStoredType])] = try legacyQueue.read { db in
            guard try db.tableExists("clipboard_items") else { return [] }
            return try Row.fetchAll(db, sql: "SELECT * FROM clipboard_items ORDER BY createdAt ASC").map { row in
                var item = Self.legacyItem(from: row)
                let contentRows = try Row.fetchAll(
                    db,
                    sql: "SELECT pasteboardType, storageMode, inlineData, blobFileName FROM clipboard_contents WHERE itemId = ? ORDER BY sortOrder",
                    arguments: [item.id.uuidString]
                )
                let types = try contentRows.map { contentRow -> ClipboardStoredType in
                    let type: String = contentRow["pasteboardType"]
                    let mode: String = contentRow["storageMode"]
                    if mode == "inline", let data: Data = contentRow["inlineData"] {
                        return ClipboardStoredType(type: type, data: data)
                    }
                    guard let name: String = contentRow["blobFileName"] else { throw ClipboardMigrationError.invalidLegacyContent }
                    return ClipboardStoredType(type: type, data: try Data(contentsOf: legacyBlobDirectory.appendingPathComponent(name)))
                }
                item.storedTypes = types
                return (item, types)
            }
        }
        guard !items.isEmpty else { return }

        do {
            try requireDatabase().write { db in
                try deleteItems(db, ids: String.fetchAll(db, sql: "SELECT id FROM clipboard_items"))
                for range in ClipboardPrivacyPolicy.batchRanges(itemCount: items.count) {
                    for (item, types) in items[range] {
                        try insertItem(db, item, crypto: crypto, contentHash: contentHash(for: types, crypto: crypto))
                    }
                }
            }
            let migrated = try fetchItems()
            guard migrated.count == items.count else { throw ClipboardMigrationError.validationFailed }
            let migratedByID = Dictionary(uniqueKeysWithValues: migrated.map { ($0.id, $0) })
            for (item, types) in items {
                guard migratedByID[item.id]?.isFavorite == item.isFavorite,
                      contentHash(for: try loadStoredTypes(itemID: item.id), crypto: crypto) == contentHash(for: types, crypto: crypto) else {
                    throw ClipboardMigrationError.validationFailed
                }
            }
        } catch {
            try? requireDatabase().write { db in
                try deleteItems(db, ids: String.fetchAll(db, sql: "SELECT id FROM clipboard_items"))
            }
            throw error
        }

        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: legacyDatabaseURL.path + suffix))
        }
        try? fileManager.removeItem(at: legacyBlobDirectory)
        try? fileManager.removeItem(at: rootDirectory.appendingPathComponent("thumbnails", isDirectory: true))
    }

    private func requireCrypto() throws -> any ClipboardCryptoProviding {
        guard let crypto else { throw initializationError ?? ClipboardCryptoError.keyMissing }
        return crypto
    }

    private func requireDatabase() throws -> DatabaseQueue {
        guard let databaseQueue else { throw initializationError ?? ClipboardMigrationError.databaseUnavailable }
        return databaseQueue
    }

    private func contentHash(for types: [ClipboardStoredType], crypto: any ClipboardCryptoProviding) -> String {
        var data = Data()
        for type in types.sorted(by: { $0.type < $1.type }) {
            data.append(Data(type.type.utf8)); data.append(0); data.append(type.data); data.append(0)
        }
        return crypto.authenticationHash(data)
    }

    private func createSecureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func secureWrite(_ data: Data, to url: URL) throws {
        try createSecureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func secureDatabaseFiles() throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createEncryptedClipboardHistoryV2") { db in
            try db.create(table: "clipboard_items", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("sortKey", .double).notNull().indexed()
                table.column("isFavorite", .boolean).notNull().defaults(to: false).indexed()
                table.column("contentHash", .text).notNull().indexed()
                table.column("encryptedItem", .blob).notNull()
                table.column("byteCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "clipboard_contents", ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("itemId", .text).notNull().indexed()
                table.column("sortOrder", .integer).notNull()
                table.column("storageMode", .text).notNull()
                table.column("encryptedData", .blob)
                table.column("blobFileName", .text)
                table.column("byteCount", .integer).notNull()
                table.foreignKey(["itemId"], references: "clipboard_items", columns: ["id"], onDelete: .cascade)
            }
        }
        return migrator
    }()

    private static func legacyItem(from row: Row) -> ClipboardHistoryItem {
        let id: String = row["id"]
        let created: String = row["createdAt"]
        let sourcePaths: String = row["sourcePathsJson"]
        let fileNames: String = row["fileNamesJson"]
        let pasteboardTypes: String = row["pasteboardTypesJson"]
        let metadata = ClipboardContentMetadata(
            contentType: row["contentType"],
            detailText: row["detailText"],
            sourcePaths: decodeLegacyArray(sourcePaths),
            fileNames: decodeLegacyArray(fileNames),
            pasteboardTypes: decodeLegacyArray(pasteboardTypes),
            imagePixelWidth: row["imagePixelWidth"],
            imagePixelHeight: row["imagePixelHeight"],
            thumbnailFileName: nil,
            contentByteCount: row["byteCount"]
        )
        return ClipboardHistoryItem(
            id: UUID(uuidString: id) ?? UUID(),
            createdAt: ISO8601DateFormatter.clipboardStore.date(from: created) ?? Date(),
            sourceApplicationName: row["sourceApplicationName"],
            sourceBundleIdentifier: row["sourceBundleIdentifier"],
            plainText: row["plainText"],
            previewText: row["previewText"],
            storedTypes: [],
            isFavorite: row["isFavorite"],
            metadata: metadata
        )
    }

    private static func decodeLegacyArray(_ string: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(string.utf8))) ?? []
    }

    private static func isRichOrImageType(_ type: String) -> Bool {
        let lower = type.lowercased()
        return ["image", "png", "tiff", "jpeg", "jpg", "heic", "rtf", "html", "webarchive"].contains { lower.contains($0) }
    }

    private static func isImageType(_ type: String) -> Bool {
        let lower = type.lowercased()
        return ["image", "png", "tiff", "jpeg", "jpg", "heic"].contains { lower.contains($0) }
    }

    private static func makeThumbnailData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: Constants.thumbnailMaxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private static func allocatedSize(at url: URL, fileManager: FileManager) -> Int64? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map(Int64.init)
        }
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

private enum ClipboardMigrationError: LocalizedError {
    case validationFailed
    case invalidLegacyContent
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .validationFailed: return "旧剪贴板历史迁移校验失败，未删除原数据库，可稍后重试。"
        case .invalidLegacyContent: return "旧剪贴板历史包含无法读取的内容，原数据库已保留。"
        case .databaseUnavailable: return "剪贴板数据库不可用。"
        }
    }
}

private extension ISO8601DateFormatter {
    static let clipboardStore: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
