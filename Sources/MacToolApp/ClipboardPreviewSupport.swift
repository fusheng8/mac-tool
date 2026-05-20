import AppKit
import Foundation

enum ClipboardPreviewKind: String, CaseIterable {
    case image
    case richText
    case json
    case markdown
    case url
    case code
    case table
    case file
    case text
}

struct ClipboardPreviewDescriptor: Hashable {
    var kind: ClipboardPreviewKind
    var title: String
    var symbolName: String
    var tintColor: NSColor
    var details: [String]
    var displayText: String?
    var url: URL?
    var formattedJSON: String?
    var tableRows: [[String]]
    var urlSummary: ClipboardPreviewURLSummary?
    var codeLanguage: String?

    init(
        kind: ClipboardPreviewKind,
        title: String,
        symbolName: String,
        tintColor: NSColor,
        details: [String],
        displayText: String? = nil,
        url: URL? = nil,
        formattedJSON: String? = nil,
        tableRows: [[String]] = [],
        urlSummary: ClipboardPreviewURLSummary? = nil,
        codeLanguage: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.symbolName = symbolName
        self.tintColor = tintColor
        self.details = details
        self.displayText = displayText
        self.url = url
        self.formattedJSON = formattedJSON
        self.tableRows = tableRows
        self.urlSummary = urlSummary
        self.codeLanguage = codeLanguage
    }
}

struct ClipboardPreviewURLSummary: Hashable {
    var scheme: String
    var host: String
    var path: String

    var displayText: String {
        [scheme.isEmpty ? nil : scheme, host.isEmpty ? nil : host, path.isEmpty ? nil : path]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

enum ClipboardPreviewSupport {
    static let maxTableRows = 50
    static let maxTableColumns = 12

    static func descriptor(
        for item: ClipboardHistoryItem,
        previewURL: URL? = nil,
        structuredTextLimitBytes: Int = ClipboardConfig.defaultValue.structuredPreviewLimitBytes
    ) -> ClipboardPreviewDescriptor {
        let text = bestText(for: item)
        let url = previewURL ?? firstFileURL(in: item)
        let skipsStructuredPreview = isStructuredTextTooLarge(text, limitBytes: structuredTextLimitBytes)
        let kind = previewKind(for: item, previewURL: url, structuredTextLimitBytes: structuredTextLimitBytes)
        let formattedJSON = kind == .json ? formatJSON(text) : nil
        let tableRows = kind == .table ? parseDelimitedTable(text) : []
        let urlSummary = kind == .url ? parseURLSummary(text) : nil
        let codeLanguage = kind == .code ? detectCodeLanguage(text, item: item) : nil
        let displayText = formattedJSON ?? normalizedPreviewText(text)
        var details = headerDetails(
            for: item,
            kind: kind,
            previewURL: url,
            text: text,
            tableRows: tableRows,
            urlSummary: urlSummary,
            codeLanguage: codeLanguage
        )
        if skipsStructuredPreview, kind == .text {
            details.insert("原文显示", at: min(1, details.count))
        }

        return ClipboardPreviewDescriptor(
            kind: kind,
            title: title(for: kind, codeLanguage: codeLanguage),
            symbolName: symbolName(for: kind),
            tintColor: tintColor(for: kind),
            details: details,
            displayText: displayText.isEmpty ? nil : displayText,
            url: urlSummary.flatMap { _ in URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? url,
            formattedJSON: formattedJSON,
            tableRows: tableRows,
            urlSummary: urlSummary,
            codeLanguage: codeLanguage
        )
    }

    static func previewKind(
        for item: ClipboardHistoryItem,
        previewURL: URL? = nil,
        structuredTextLimitBytes: Int = ClipboardConfig.defaultValue.structuredPreviewLimitBytes
    ) -> ClipboardPreviewKind {
        let contentType = item.metadata.contentType
        let lowerTypes = item.metadata.pasteboardTypes.map { $0.lowercased() }
        let text = normalizedPreviewText(bestText(for: item))

        if contentType == "文件" {
            return .file
        }
        if contentType == "图片" || isImageURL(previewURL) || lowerTypes.contains(where: isImagePasteboardType) {
            return .image
        }
        if isStructuredTextTooLarge(text, limitBytes: structuredTextLimitBytes) {
            return .text
        }
        if formatJSON(text) != nil {
            return .json
        }
        if parseURLSummary(text) != nil {
            return .url
        }
        if looksLikeLocalPathList(text) {
            return .file
        }
        if !parseDelimitedTable(text).isEmpty {
            return .table
        }
        if isMarkdown(text) {
            return .markdown
        }
        if detectCodeLanguage(text, item: item) != nil {
            return .code
        }
        if contentType == "富文本" || lowerTypes.contains(where: isRichTextPasteboardType) {
            return .richText
        }
        return .text
    }

    static func formatJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              JSONSerialization.isValidJSONObject((try? JSONSerialization.jsonObject(with: data)) as Any),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return pretty.replacingOccurrences(of: "\\/", with: "/")
    }

    static func isMarkdown(_ text: String) -> Bool {
        let normalized = normalizedPreviewText(text)
        guard normalized.count >= 8 else { return false }
        let lines = normalized.components(separatedBy: .newlines)
        var score = 0

        for line in lines.prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil { score += 3 }
            if trimmed.range(of: #"^[-*+]\s+\S"#, options: .regularExpression) != nil { score += 1 }
            if trimmed.range(of: #"^\d+\.\s+\S"#, options: .regularExpression) != nil { score += 1 }
            if trimmed.range(of: #"^>\s+\S"#, options: .regularExpression) != nil { score += 1 }
            if trimmed == "---" || trimmed == "***" { score += 1 }
            if trimmed.hasPrefix("```") { score += 3 }
        }

        let inlineSignals = [
            #"\[[^\]]+\]\([^)]+\)"#,
            #"`[^`]+`"#,
            #"\*\*[^*]+\*\*"#,
            #"__[^_]+__"#,
            #"!\[[^\]]*\]\([^)]+\)"#
        ]
        score += inlineSignals.reduce(0) { partial, pattern in
            partial + (normalized.range(of: pattern, options: .regularExpression) == nil ? 0 : 1)
        }
        return score >= 3
    }

    static func parseURLSummary(_ text: String) -> ClipboardPreviewURLSummary? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "file", "ftp"].contains(scheme) else {
            return nil
        }
        let host = components.host ?? ""
        guard scheme == "file" || !host.isEmpty else { return nil }
        let path = components.path.isEmpty ? "/" : components.path
        return ClipboardPreviewURLSummary(scheme: scheme, host: host, path: path)
    }

    static func detectCodeLanguage(_ text: String, item: ClipboardHistoryItem? = nil) -> String? {
        let normalized = normalizedPreviewText(text)
        guard normalized.count >= 8 else { return nil }

        if let typeLanguage = item.flatMap({ codeLanguageFromPasteboardTypes($0.metadata.pasteboardTypes) }) {
            return typeLanguage
        }
        if formatJSON(normalized) != nil {
            return "json"
        }

        let sample = String(normalized.prefix(4000))
        let lower = sample.lowercased()
        let checks: [(String, Int)] = [
            ("swift", score(sample, patterns: [#"^\s*import\s+\w+"#, #"\bfunc\s+\w+\s*\("#, #"\bstruct\s+\w+"#, #"\blet\s+\w+\s*[:=]"#])),
            ("javascript", score(sample, patterns: [#"\b(const|let|var)\s+\w+\s*="#, #"=>\s*[{\w]"#, #"\bfunction\s+\w*\s*\("#, #"\bconsole\.log\s*\("#])),
            ("html", score(sample, patterns: [#"<!doctype\s+html"#, #"<html[\s>]"#, #"</[a-z][^>]*>"#, #"<(div|span|body|head|script|style)[\s>]"#])),
            ("css", score(sample, patterns: [#"[.#]?[a-zA-Z][\w-]*\s*\{[^}]*:[^}]*\}"#, #"\b(color|display|position|margin|padding)\s*:"#, #"@media\s"#])),
            ("shell", score(sample, patterns: [#"^#!/bin/(ba)?sh"#, #"\b(echo|grep|curl|cd|export)\s+"#, #"\$\([^)]+\)"#])),
            ("python", score(sample, patterns: [#"^\s*def\s+\w+\s*\("#, #"^\s*class\s+\w+[:\(]"#, #"^\s*import\s+\w+"#, #"^\s*from\s+\w+\s+import\s+"#]))
        ]

        if let best = checks.max(by: { $0.1 < $1.1 }), best.1 >= 2 {
            return best.0
        }

        let genericSignals = ["{", "}", ";", "=>", "import ", "class ", "func ", "return ", "</"]
        return genericSignals.filter { lower.contains($0) }.count >= 3 ? "code" : nil
    }

    static func parseDelimitedTable(_ text: String) -> [[String]] {
        let normalized = normalizedPreviewText(text)
        guard !normalized.isEmpty else { return [] }
        let lines = Array(normalized.components(separatedBy: .newlines).prefix(maxTableRows))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard lines.count >= 2 else { return [] }

        let delimiter: Character
        if lines.filter({ $0.contains("\t") }).count >= max(2, lines.count / 2) {
            delimiter = "\t"
        } else if lines.filter({ $0.contains(",") }).count >= max(2, lines.count / 2) {
            delimiter = ","
        } else {
            return []
        }

        let rows = lines.map { parseDelimitedLine($0, delimiter: delimiter, maxColumns: maxTableColumns) }
        let usefulRows = rows.filter { $0.count > 1 }
        guard usefulRows.count >= 2 else { return [] }
        let commonWidth = usefulRows.map(\.count).reduce(into: [:]) { counts, width in counts[width, default: 0] += 1 }
            .max { $0.value < $1.value }?.key ?? 0
        guard commonWidth > 1 else { return [] }
        return rows.filter { $0.count > 1 }
    }

    static func headerDetails(
        for item: ClipboardHistoryItem,
        kind: ClipboardPreviewKind,
        previewURL: URL? = nil,
        text: String? = nil,
        tableRows: [[String]] = [],
        urlSummary: ClipboardPreviewURLSummary? = nil,
        codeLanguage: String? = nil
    ) -> [String] {
        var details: [String] = []
        let resolvedText = text ?? bestText(for: item)

        switch kind {
        case .image:
            if let imageSize = imagePixelSizeText(for: item, url: previewURL) {
                details.append(imageSize)
            }
            if let format = formatText(for: item, url: previewURL) {
                details.append(format)
            }
        case .file:
            let fileCount = max(max(item.metadata.fileNames.count, item.metadata.sourcePaths.count), localPaths(in: resolvedText).count)
            if fileCount > 0 {
                details.append(fileCount == 1 ? "1 个文件" : "\(fileCount) 个文件")
            }
            if let format = formatText(for: item, url: previewURL) {
                details.append(format)
            }
        case .richText:
            details.append(textFormat(for: item, richText: true))
            details.append("\(characterCount(for: item, fallbackText: resolvedText)) 个字符")
        case .json:
            details.append("JSON")
            details.append("\(characterCount(for: item, fallbackText: resolvedText)) 个字符")
        case .markdown:
            details.append("Markdown")
            details.append("\(characterCount(for: item, fallbackText: resolvedText)) 个字符")
        case .url:
            details.append(urlSummary?.scheme.uppercased() ?? "URL")
            if let host = urlSummary?.host, !host.isEmpty {
                details.append(host)
            }
        case .code:
            details.append((codeLanguage ?? detectCodeLanguage(resolvedText, item: item) ?? "code").uppercased())
            details.append("\(characterCount(for: item, fallbackText: resolvedText)) 个字符")
        case .table:
            if let first = tableRows.first {
                details.append("\(tableRows.count) 行")
                details.append("\(first.count) 列")
            } else {
                details.append("表格")
            }
        case .text:
            details.append(textFormat(for: item, richText: false))
            details.append("\(characterCount(for: item, fallbackText: resolvedText)) 个字符")
        }

        if let byteCount = byteCountText(item.metadata.contentByteCount) {
            details.append(byteCount)
        }
        let sourceApp = item.sourceApplicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourceApp.isEmpty, sourceApp != "未知应用" {
            details.append("来自 \(sourceApp)")
        }
        return details.isEmpty ? ["剪切板项目"] : details
    }

    static func normalizedPreviewText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func byteCountText(_ byteCount: Int?) -> String? {
        guard let byteCount, byteCount > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: Int64(byteCount))
    }

    static func isStructuredTextTooLarge(_ text: String, limitBytes: Int) -> Bool {
        limitBytes > 0 && text.utf8.count > limitBytes
    }
}

private extension ClipboardPreviewSupport {
    static func bestText(for item: ClipboardHistoryItem) -> String {
        let plainText = normalizedPreviewText(item.plainText)
        if !plainText.isEmpty {
            return plainText
        }
        return normalizedPreviewText(item.previewText)
    }

    static func title(for kind: ClipboardPreviewKind, codeLanguage: String?) -> String {
        switch kind {
        case .image: return "图片预览"
        case .richText: return "富文本预览"
        case .json: return "JSON 预览"
        case .markdown: return "Markdown 预览"
        case .url: return "链接预览"
        case .code: return "\(codeLanguage?.uppercased() ?? "代码") 预览"
        case .table: return "表格预览"
        case .file: return "文件预览"
        case .text: return "文本预览"
        }
    }

    static func symbolName(for kind: ClipboardPreviewKind) -> String {
        switch kind {
        case .image: return "photo"
        case .richText: return "doc.richtext"
        case .json: return "curlybraces"
        case .markdown: return "text.badge.checkmark"
        case .url: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .table: return "tablecells"
        case .file: return "doc"
        case .text: return "text.alignleft"
        }
    }

    static func tintColor(for kind: ClipboardPreviewKind) -> NSColor {
        switch kind {
        case .image, .url: return MacAssistantUI.Color.blue
        case .richText, .markdown: return MacAssistantUI.Color.green
        case .json, .code: return MacAssistantUI.Color.purple
        case .table: return NSColor.systemTeal
        case .file: return MacAssistantUI.Color.purple
        case .text: return MacAssistantUI.Color.amber
        }
    }

    static func textFormat(for item: ClipboardHistoryItem, richText: Bool) -> String {
        for type in item.metadata.pasteboardTypes.map({ $0.lowercased() }) {
            if type.contains("html") { return "HTML" }
            if type.contains("rtf") { return "RTF" }
        }
        return richText ? "富文本" : "纯文本"
    }

    static func characterCount(for item: ClipboardHistoryItem, fallbackText: String) -> Int {
        let plainText = normalizedPreviewText(item.plainText)
        if !plainText.isEmpty {
            return plainText.count
        }
        let previewText = normalizedPreviewText(item.previewText)
        if !previewText.isEmpty {
            return previewText.count
        }
        return normalizedPreviewText(fallbackText).count
    }

    static func imagePixelSizeText(for item: ClipboardHistoryItem, url: URL?) -> String? {
        if let width = item.metadata.imagePixelWidth,
           let height = item.metadata.imagePixelHeight {
            return "\(width)x\(height)"
        }
        guard let url,
              let image = NSImage(contentsOf: url),
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        return "\(Int(image.size.width))x\(Int(image.size.height))"
    }

    static func formatText(for item: ClipboardHistoryItem, url: URL?) -> String? {
        if let extensionText = url?.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines),
           !extensionText.isEmpty {
            return extensionText.uppercased()
        }

        for type in item.metadata.pasteboardTypes.map({ $0.lowercased() }) {
            if type.contains("png") { return "PNG" }
            if type.contains("tiff") { return "TIFF" }
            if type.contains("jpeg") || type.contains("jpg") { return "JPEG" }
            if type.contains("heic") { return "HEIC" }
            if type.contains("pdf") { return "PDF" }
            if type.contains("file-url") { return "文件 URL" }
        }
        return nil
    }

    static func firstFileURL(in item: ClipboardHistoryItem) -> URL? {
        if let path = item.metadata.sourcePaths.first, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let text = normalizedPreviewText(item.plainText)
        if let summary = parseURLSummary(text), summary.scheme == "file" {
            return URL(string: text)
        }
        if let path = localPaths(in: text).first {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func looksLikeLocalPathList(_ text: String) -> Bool {
        let paths = localPaths(in: text)
        guard !paths.isEmpty else { return false }
        let nonEmptyLines = normalizedPreviewText(text)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return paths.count == nonEmptyLines.count
    }

    static func localPaths(in text: String) -> [String] {
        normalizedPreviewText(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line in
                if line.hasPrefix("file://"), let url = URL(string: line) {
                    return url.path
                }
                if line.hasPrefix("/") {
                    return line
                }
                return nil
            }
    }

    static func isImageURL(_ url: URL?) -> Bool {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else { return false }
        return ["png", "jpg", "jpeg", "tif", "tiff", "gif", "heic", "webp", "bmp"].contains(ext)
    }

    static func isImagePasteboardType(_ type: String) -> Bool {
        type.contains("image") || type.contains("png") || type.contains("tiff") || type.contains("jpeg") || type.contains("jpg") || type.contains("heic")
    }

    static func isRichTextPasteboardType(_ type: String) -> Bool {
        type.contains("rtf") || type.contains("html") || type.contains("webarchive")
    }

    static func codeLanguageFromPasteboardTypes(_ types: [String]) -> String? {
        let joined = types.joined(separator: " ").lowercased()
        if joined.contains("json") { return "json" }
        if joined.contains("javascript") || joined.contains("ecmascript") { return "javascript" }
        if joined.contains("html") { return nil }
        if joined.contains("css") { return "css" }
        if joined.contains("python") { return "python" }
        if joined.contains("shell") || joined.contains("bash") { return "shell" }
        if joined.contains("swift") { return "swift" }
        return nil
    }

    static func score(_ text: String, patterns: [String]) -> Int {
        patterns.reduce(0) { partial, pattern in
            partial + (text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil ? 0 : 1)
        }
    }

    static func parseDelimitedLine(_ line: String, delimiter: Character, maxColumns: Int) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        inQuotes = false
                        if next == delimiter {
                            fields.append(cleanTableField(current))
                            current = ""
                            if fields.count == maxColumns { return fields }
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if character == delimiter, !inQuotes {
                fields.append(cleanTableField(current))
                current = ""
                if fields.count == maxColumns { return fields }
            } else {
                current.append(character)
            }
        }

        if fields.count < maxColumns {
            fields.append(cleanTableField(current))
        }
        return fields
    }

    static func cleanTableField(_ field: String) -> String {
        var trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
    }
}
