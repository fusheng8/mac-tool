import AppKit
import CryptoKit
import Foundation
import GRDB
import ImageIO

struct ClipboardHistorySearchFilter {
    static let empty = ClipboardHistorySearchFilter()

    var applicationKey: String?
    var favoritesOnly: Bool

    init(applicationKey: String? = nil, favoritesOnly: Bool = false) {
        self.applicationKey = applicationKey
        self.favoritesOnly = favoritesOnly
    }
}

final class ClipboardHistoryStore {
    private enum Constants {
        static let inlineDataLimit = 32 * 1024
        static let thumbnailMaxPixelSize = 108
    }

    private let databaseQueue: DatabaseQueue
    private let rootDirectory: URL
    private let databaseURL: URL
    private let blobDirectory: URL
    private let thumbnailDirectory: URL
    private let legacyHistoryURL: URL?
    private let fileManager: FileManager
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    init(
        rootDirectory: URL = AppPaths.clipboardDirectory,
        databaseURL: URL = AppPaths.clipboardDatabaseURL,
        blobDirectory: URL = AppPaths.clipboardBlobDirectory,
        thumbnailDirectory: URL = AppPaths.clipboardThumbnailDirectory,
        legacyHistoryURL: URL? = AppPaths.clipboardHistoryURL,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.databaseURL = databaseURL
        self.blobDirectory = blobDirectory
        self.thumbnailDirectory = thumbnailDirectory
        self.legacyHistoryURL = legacyHistoryURL
        self.fileManager = fileManager
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonDecoder.dateDecodingStrategy = .iso8601

        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            databaseQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            try Self.migrator.migrate(databaseQueue)
        } catch {
            fatalError("剪切板数据库初始化失败：\(error.localizedDescription)")
        }
    }

    func loadHistory(maxHistoryCount: Int, retentionDays: Int) throws -> [ClipboardHistoryItem] {
        try migrateLegacyHistoryIfNeeded(maxHistoryCount: maxHistoryCount, retentionDays: retentionDays)
        try prune(retentionDays: retentionDays)
        try trim(maxHistoryCount: maxHistoryCount)
        return try fetchItems()
    }

    func insert(_ item: ClipboardHistoryItem, maxHistoryCount: Int, retentionDays: Int) throws -> [ClipboardHistoryItem] {
        try databaseQueue.write { db in
            let hash = Self.contentHash(for: item.storedTypes)
            let duplicatedFavorite = try Bool.fetchOne(
                db,
                sql: "SELECT MAX(isFavorite) FROM clipboard_items WHERE contentHash = ?",
                arguments: [hash]
            ) ?? false
            var storedItem = item
            if duplicatedFavorite {
                storedItem.isFavorite = true
            }
            let duplicateIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM clipboard_items WHERE contentHash = ?",
                arguments: [hash]
            )
            try deleteItems(db, ids: duplicateIDs)
            try insertItem(db, storedItem, contentHash: hash)
        }
        try prune(retentionDays: retentionDays)
        try trim(maxHistoryCount: maxHistoryCount)
        return try fetchItems()
    }

    func search(_ query: String, filter: ClipboardHistorySearchFilter = .empty, limit: Int) throws -> [ClipboardHistoryItem] {
        let ftsQuery = Self.ftsQuery(for: query)
        guard !ftsQuery.isEmpty else {
            return try fetchItems(limit: limit)
        }
        return try databaseQueue.read { db in
            var predicates = ["clipboard_items_fts MATCH ?"]
            var arguments: StatementArguments = [ftsQuery]
            if filter.favoritesOnly {
                predicates.append("i.isFavorite = 1")
            }
            if let applicationKey = filter.applicationKey {
                if applicationKey.hasPrefix("app:") {
                    predicates.append("i.sourceBundleIdentifier = ?")
                    arguments += [String(applicationKey.dropFirst(4))]
                } else if applicationKey.hasPrefix("app-name:") {
                    predicates.append("i.sourceApplicationName = ?")
                    arguments += [String(applicationKey.dropFirst(9))]
                }
            }
            arguments += [limit]

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT i.*
                    FROM clipboard_items_fts f
                    JOIN clipboard_items i ON i.id = f.itemId
                    WHERE \(predicates.joined(separator: " AND "))
                    ORDER BY rank, i.createdAt DESC
                    LIMIT ?
                    """,
                arguments: arguments
            )
            return rows.map(Self.item(from:))
        }
    }

    func loadStoredTypes(itemID: UUID) throws -> [ClipboardStoredType] {
        try databaseQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT pasteboardType, storageMode, inlineData, blobFileName
                    FROM clipboard_contents
                    WHERE itemId = ?
                    ORDER BY sortOrder
                    """,
                arguments: [itemID.uuidString]
            )
            return rows.compactMap { row in
                let type: String = row["pasteboardType"]
                let mode: String = row["storageMode"]
                if mode == "inline" {
                    let data: Data = row["inlineData"]
                    return ClipboardStoredType(type: type, data: data)
                }
                guard let blobFileName: String = row["blobFileName"] else {
                    return nil
                }
                let data = try? Data(contentsOf: blobDirectory.appendingPathComponent(blobFileName))
                return data.map { ClipboardStoredType(type: type, data: $0) }
            }
        }
    }

    func delete(_ itemID: UUID) throws -> [ClipboardHistoryItem] {
        try databaseQueue.write { db in
            try deleteItems(db, ids: [itemID.uuidString])
        }
        return try fetchItems()
    }

    func toggleFavorite(_ itemID: UUID) throws -> [ClipboardHistoryItem] {
        try databaseQueue.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET isFavorite = CASE isFavorite WHEN 1 THEN 0 ELSE 1 END WHERE id = ?",
                arguments: [itemID.uuidString]
            )
        }
        return try fetchItems()
    }

    func clearUnfavorited() throws -> [ClipboardHistoryItem] {
        try databaseQueue.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM clipboard_items WHERE isFavorite = 0")
            try deleteItems(db, ids: ids)
        }
        return try fetchItems()
    }

    func clearAll() throws -> [ClipboardHistoryItem] {
        try databaseQueue.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM clipboard_items")
            try deleteItems(db, ids: ids)
        }
        return try fetchItems()
    }

    func clearItems(kind: ClipboardContentKind) throws -> [ClipboardHistoryItem] {
        try databaseQueue.write { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM clipboard_items WHERE contentType = ? AND isFavorite = 0",
                arguments: [kind.title]
            )
            try deleteItems(db, ids: ids)
        }
        return try fetchItems()
    }

    func countItems(kind: ClipboardContentKind) throws -> Int {
        try databaseQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clipboard_items WHERE contentType = ? AND isFavorite = 0",
                arguments: [kind.title]
            ) ?? 0
        }
    }

    func thumbnailURL(for item: ClipboardHistoryItem) -> URL? {
        let fileName = item.metadata.thumbnailFileName ?? "\(item.id.uuidString).jpg"
        let url = thumbnailDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func ensureThumbnail(for itemID: UUID) throws -> URL? {
        let fileName = "\(itemID.uuidString).jpg"
        let targetURL = thumbnailDirectory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: targetURL.path) {
            return targetURL
        }

        guard let imageData = try imageData(for: itemID),
              let thumbnailData = Self.makeThumbnailData(from: imageData) else {
            return nil
        }
        try fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        try thumbnailData.write(to: targetURL, options: .atomic)
        try databaseQueue.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET thumbnailFileName = ? WHERE id = ?",
                arguments: [fileName, itemID.uuidString]
            )
        }
        return targetURL
    }

    private func fetchItems(limit: Int? = nil) throws -> [ClipboardHistoryItem] {
        try databaseQueue.read { db in
            let sql: String
            let arguments: StatementArguments
            if let limit {
                sql = "SELECT * FROM clipboard_items ORDER BY createdAt DESC LIMIT ?"
                arguments = [limit]
            } else {
                sql = "SELECT * FROM clipboard_items ORDER BY createdAt DESC"
                arguments = []
            }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.item(from:))
        }
    }

    private func prune(retentionDays: Int) throws {
        guard retentionDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else {
            return
        }
        try databaseQueue.write { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM clipboard_items WHERE isFavorite = 0 AND createdAt < ?",
                arguments: [Self.dateString(cutoff)]
            )
            try deleteItems(db, ids: ids)
        }
    }

    private func trim(maxHistoryCount: Int) throws {
        try databaseQueue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0
            guard count > maxHistoryCount else { return }
            let removable = count - maxHistoryCount
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM clipboard_items
                    WHERE isFavorite = 0
                    ORDER BY createdAt ASC
                    LIMIT ?
                    """,
                arguments: [removable]
            )
            try deleteItems(db, ids: ids)
        }
    }

    private func migrateLegacyHistoryIfNeeded(maxHistoryCount: Int, retentionDays: Int) throws {
        guard let legacyHistoryURL,
              fileManager.fileExists(atPath: legacyHistoryURL.path),
              !fileManager.fileExists(atPath: databaseURL.path + "-legacy-migrated") else {
            return
        }

        guard let data = try? Data(contentsOf: legacyHistoryURL) else {
            return
        }
        let decoded = (try? jsonDecoder.decode([ClipboardHistoryItem].self, from: data)) ?? []
        try databaseQueue.write { db in
            for item in decoded {
                try insertItem(db, item, contentHash: Self.contentHash(for: item.storedTypes))
            }
        }
        try prune(retentionDays: retentionDays)
        try trim(maxHistoryCount: maxHistoryCount)

        let migratedMarker = URL(fileURLWithPath: databaseURL.path + "-legacy-migrated")
        try Data().write(to: migratedMarker, options: .atomic)
        let migratedURL = legacyHistoryURL.deletingLastPathComponent()
            .appendingPathComponent("\(legacyHistoryURL.lastPathComponent).migrated")
        if fileManager.fileExists(atPath: migratedURL.path) {
            try fileManager.removeItem(at: migratedURL)
        }
        try fileManager.moveItem(at: legacyHistoryURL, to: migratedURL)
    }

    private func insertItem(_ db: Database, _ item: ClipboardHistoryItem, contentHash: String) throws {
        let totalBytes = item.storedTypes.reduce(0) { $0 + $1.data.count }
        var metadata = item.metadata
        metadata.contentByteCount = totalBytes
        let itemID = item.id.uuidString

        try db.execute(
            sql: """
                INSERT INTO clipboard_items (
                    id, createdAt, sourceApplicationName, sourceBundleIdentifier,
                    plainText, previewText, contentType, detailText, sourcePathsJson,
                    fileNamesJson, pasteboardTypesJson, imagePixelWidth, imagePixelHeight,
                    isFavorite, thumbnailFileName, contentHash, byteCount
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                itemID,
                Self.dateString(item.createdAt),
                item.sourceApplicationName,
                item.sourceBundleIdentifier,
                item.plainText,
                item.previewText,
                metadata.contentType,
                metadata.detailText,
                Self.jsonString(metadata.sourcePaths),
                Self.jsonString(metadata.fileNames),
                Self.jsonString(metadata.pasteboardTypes),
                metadata.imagePixelWidth,
                metadata.imagePixelHeight,
                item.isFavorite,
                metadata.thumbnailFileName,
                contentHash,
                totalBytes
            ]
        )

        for (index, storedType) in item.storedTypes.enumerated() {
            let useBlob = Self.shouldStoreAsBlob(storedType)
            let blobFileName: String?
            let inlineData: Data?
            if useBlob {
                blobFileName = try writeBlob(itemID: item.id, index: index, storedType: storedType)
                inlineData = nil
            } else {
                blobFileName = nil
                inlineData = storedType.data
            }
            try db.execute(
                sql: """
                    INSERT INTO clipboard_contents (
                        itemId, pasteboardType, sortOrder, storageMode, inlineData, blobFileName, byteCount
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    itemID,
                    storedType.type,
                    index,
                    useBlob ? "blob" : "inline",
                    inlineData,
                    blobFileName,
                    storedType.data.count
                ]
            )
        }

        try insertFTS(db, item: item, metadata: metadata)
    }

    private func insertFTS(_ db: Database, item: ClipboardHistoryItem, metadata: ClipboardContentMetadata) throws {
        try db.execute(
            sql: """
                INSERT INTO clipboard_items_fts (
                    itemId, previewText, plainText, detailText, sourceAppName, fileNames, sourcePaths
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                item.id.uuidString,
                item.previewText,
                item.plainText,
                metadata.detailText,
                item.sourceApplicationName,
                metadata.fileNames.joined(separator: "\n"),
                metadata.sourcePaths.joined(separator: "\n")
            ]
        )
    }

    private func deleteItems(_ db: Database, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            let blobFileNames = try String.fetchAll(
                db,
                sql: "SELECT blobFileName FROM clipboard_contents WHERE itemId = ? AND blobFileName IS NOT NULL",
                arguments: [id]
            )
            for fileName in blobFileNames {
                try? fileManager.removeItem(at: blobDirectory.appendingPathComponent(fileName))
            }
            try? fileManager.removeItem(at: blobDirectory.appendingPathComponent(id, isDirectory: true))
            let thumbnailFileName = try String.fetchOne(
                db,
                sql: "SELECT thumbnailFileName FROM clipboard_items WHERE id = ?",
                arguments: [id]
            ) ?? "\(id).jpg"
            try? fileManager.removeItem(at: thumbnailDirectory.appendingPathComponent(thumbnailFileName))
            try db.execute(sql: "DELETE FROM clipboard_items_fts WHERE itemId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM clipboard_contents WHERE itemId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [id])
        }
    }

    private func writeBlob(itemID: UUID, index: Int, storedType: ClipboardStoredType) throws -> String {
        let itemDirectoryName = itemID.uuidString
        let itemDirectory = blobDirectory.appendingPathComponent(itemDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        let fileName = "\(index)-\(Self.sha256(storedType.data)).bin"
        let relativePath = "\(itemDirectoryName)/\(fileName)"
        try storedType.data.write(to: itemDirectory.appendingPathComponent(fileName), options: .atomic)
        return relativePath
    }

    private func imageData(for itemID: UUID) throws -> Data? {
        let imageTypes = [
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
            "public.jpeg",
            "public.heic"
        ]
        let storedTypes = try loadStoredTypes(itemID: itemID)
        for type in imageTypes {
            if let stored = storedTypes.first(where: { $0.type == type }) {
                return stored.data
            }
        }
        return storedTypes.first { $0.type.lowercased().contains("image") }?.data
    }

    private static func item(from row: Row) -> ClipboardHistoryItem {
        let idString: String = row["id"]
        let createdAtString: String = row["createdAt"]
        let sourcePathsJson: String = row["sourcePathsJson"]
        let fileNamesJson: String = row["fileNamesJson"]
        let pasteboardTypesJson: String = row["pasteboardTypesJson"]
        let byteCount: Int? = row["byteCount"]
        let metadata = ClipboardContentMetadata(
            contentType: row["contentType"],
            detailText: row["detailText"],
            sourcePaths: jsonArray(sourcePathsJson),
            fileNames: jsonArray(fileNamesJson),
            pasteboardTypes: jsonArray(pasteboardTypesJson),
            imagePixelWidth: row["imagePixelWidth"],
            imagePixelHeight: row["imagePixelHeight"],
            thumbnailFileName: row["thumbnailFileName"],
            contentByteCount: byteCount
        )
        return ClipboardHistoryItem(
            id: UUID(uuidString: idString) ?? UUID(),
            createdAt: date(from: createdAtString),
            sourceApplicationName: row["sourceApplicationName"],
            sourceBundleIdentifier: row["sourceBundleIdentifier"],
            plainText: row["plainText"],
            previewText: row["previewText"],
            storedTypes: [],
            isFavorite: row["isFavorite"],
            metadata: metadata
        )
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createClipboardHistory") { db in
            try db.create(table: "clipboard_items", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("createdAt", .text).notNull().indexed()
                table.column("sourceApplicationName", .text).notNull()
                table.column("sourceBundleIdentifier", .text).notNull()
                table.column("plainText", .text).notNull()
                table.column("previewText", .text).notNull()
                table.column("contentType", .text).notNull().indexed()
                table.column("detailText", .text).notNull()
                table.column("sourcePathsJson", .text).notNull()
                table.column("fileNamesJson", .text).notNull()
                table.column("pasteboardTypesJson", .text).notNull()
                table.column("imagePixelWidth", .integer)
                table.column("imagePixelHeight", .integer)
                table.column("isFavorite", .boolean).notNull().defaults(to: false).indexed()
                table.column("thumbnailFileName", .text)
                table.column("contentHash", .text).notNull().indexed()
                table.column("byteCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "clipboard_contents", ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("itemId", .text).notNull().indexed()
                table.column("pasteboardType", .text).notNull()
                table.column("sortOrder", .integer).notNull()
                table.column("storageMode", .text).notNull()
                table.column("inlineData", .blob)
                table.column("blobFileName", .text)
                table.column("byteCount", .integer).notNull()
                table.foreignKey(["itemId"], references: "clipboard_items", columns: ["id"], onDelete: .cascade)
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_items_fts
                USING fts5(itemId UNINDEXED, previewText, plainText, detailText, sourceAppName, fileNames, sourcePaths)
                """)
        }
        return migrator
    }()

    private static func shouldStoreAsBlob(_ storedType: ClipboardStoredType) -> Bool {
        storedType.data.count > Constants.inlineDataLimit || isRichOrImageType(storedType.type)
    }

    private static func isRichOrImageType(_ type: String) -> Bool {
        let lower = type.lowercased()
        return lower.contains("image")
            || lower.contains("png")
            || lower.contains("tiff")
            || lower.contains("jpeg")
            || lower.contains("jpg")
            || lower.contains("heic")
            || lower.contains("rtf")
            || lower.contains("html")
            || lower.contains("webarchive")
    }

    private static func contentHash(for storedTypes: [ClipboardStoredType]) -> String {
        var data = Data()
        for storedType in storedTypes.sorted(by: { $0.type < $1.type }) {
            data.append(Data(storedType.type.utf8))
            data.append(0)
            data.append(storedType.data)
            data.append(0)
        }
        return sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonString(_ array: [String]) -> String {
        guard let data = try? JSONEncoder().encode(array),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func jsonArray(_ string: String) -> [String] {
        guard let data = string.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return array
    }

    private static func dateString(_ date: Date) -> String {
        ISO8601DateFormatter.clipboardStore.string(from: date)
    }

    private static func date(from string: String) -> Date {
        ISO8601DateFormatter.clipboardStore.date(from: string) ?? Date()
    }

    private static func ftsQuery(for query: String) -> String {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in
                "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            .joined(separator: " ")
    }

    private static func makeThumbnailData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: Constants.thumbnailMaxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

private extension ISO8601DateFormatter {
    static let clipboardStore: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
