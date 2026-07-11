import AppKit
import Foundation

enum ContextMenuActionError: LocalizedError {
    case unsupportedAction(ContextMenuItemID)
    case applicationNotFound(String)
    case missingTargetDirectory

    var errorDescription: String? {
        switch self {
        case .unsupportedAction(let itemID):
            return "不支持执行菜单项：\(itemID.title)"
        case .applicationNotFound(let appName):
            return "找不到应用：\(appName)"
        case .missingTargetDirectory:
            return "没有可用的目标目录"
        }
    }
}

final class ContextMenuActionExecutor {
    private let progressHandler: ((ArchiveActionExecutor.Progress) -> Void)?
    private let archivePasswords: [String: String]
    private let archiveCancellation: ArchiveCancellationToken?

    init(
        progressHandler: ((ArchiveActionExecutor.Progress) -> Void)? = nil,
        archivePasswords: [String: String] = [:],
        archiveCancellation: ArchiveCancellationToken? = nil
    ) {
        self.progressHandler = progressHandler
        self.archivePasswords = archivePasswords
        self.archiveCancellation = archiveCancellation
    }

    func perform(
        itemID: ContextMenuItemID,
        urls: [URL],
        targetApplication: FinderTargetApplication? = nil
    ) throws {
        if itemID.supportsCustomTargetApplication, let targetApplication {
            try openWithCustomTarget(
                urls: urls,
                target: targetApplication,
                opensDirectory: itemID == .openInTerminal || itemID == .openInWarp
            )
            return
        }
        switch itemID {
        case .createFolder:
            try createFolder(in: targetDirectory(from: urls))
        case .copyPath:
            copyPath(urls)
        case .openWithIDEA:
            try open(urls: urls, app: .idea)
        case .openWithTypora:
            try open(urls: urls, app: .typora)
        case .openWithVSCode:
            try open(urls: urls, app: .vscode)
        case .openInTerminal:
            try openTerminalWorkspace(urls: urls, app: .terminal)
        case .openInWarp:
            try openWarpWorkspace(urls: urls)
        case .newTextFile:
            try createTextFile(named: "新建文本文档", extension: "txt", contents: Data(), in: targetDirectory(from: urls))
        case .newMarkdownFile:
            try createTextFile(named: "新建 Markdown", extension: "md", contents: Data(), in: targetDirectory(from: urls))
        case .newJSONFile:
            try createTextFile(named: "新建 JSON", extension: "json", contents: Data("{\n  \n}\n".utf8), in: targetDirectory(from: urls))
        case .newHTMLFile:
            try createTextFile(named: "新建 HTML", extension: "html", contents: Data(Self.defaultHTML.utf8), in: targetDirectory(from: urls))
        case .newWordFile:
            try createOfficeFile(named: "新建 Word", extension: "docx", entries: OfficeTemplate.word, in: targetDirectory(from: urls))
        case .newExcelFile:
            try createOfficeFile(named: "新建 Excel", extension: "xlsx", entries: OfficeTemplate.excel, in: targetDirectory(from: urls))
        case .newPowerPointFile:
            try createPowerPointFile(in: targetDirectory(from: urls))
        case .smartExtract:
            try archiveExecutor().smartExtract(urls: urls)
        case .smartExtractAndDelete:
            try archiveExecutor().smartExtractAndDelete(urls: urls)
        case .extractHere:
            try archiveExecutor().extractHere(urls: urls)
        case .extractToArchiveName:
            try archiveExecutor().extractToArchiveName(urls: urls)
        case .extractToArchiveNameAndDelete:
            try archiveExecutor().extractToArchiveNameAndDelete(urls: urls)
        case .compressZip:
            try archiveExecutor().compressZip(urls: urls)
        case .compressTar:
            try archiveExecutor().compressTar(urls: urls)
        case .compressTarGzip:
            try archiveExecutor().compressTarGzip(urls: urls)
        case .compressTarBzip2:
            try archiveExecutor().compressTarBzip2(urls: urls)
        case .compressTarXz:
            try archiveExecutor().compressTarXz(urls: urls)
        case .compressGzip:
            try archiveExecutor().compressGzip(urls: urls)
        case .compressBzip2:
            try archiveExecutor().compressBzip2(urls: urls)
        case .compressXz:
            try archiveExecutor().compressXz(urls: urls)
        case .compressSevenZip:
            try archiveExecutor().compressSevenZip(urls: urls)
        case .compressRar:
            try archiveExecutor().compressRar(urls: urls)
        case .open, .newFile, .archive, .compressCustom:
            throw ContextMenuActionError.unsupportedAction(itemID)
        }
    }

    private func archiveExecutor() -> ArchiveActionExecutor {
        ArchiveActionExecutor(
            progressHandler: progressHandler,
            archivePasswords: archivePasswords,
            cancellation: archiveCancellation
        )
    }

    private func targetDirectory(from urls: [URL]) throws -> URL {
        if let first = urls.first {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return first
            }
            return first.deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func createFolder(in directory: URL) throws {
        let url = uniqueURL(in: directory, baseName: "新建文件夹", extension: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    private func copyPath(_ urls: [URL]) {
        let paths = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    private func createTextFile(named baseName: String, extension fileExtension: String, contents: Data, in directory: URL) throws {
        let url = uniqueURL(in: directory, baseName: baseName, extension: fileExtension)
        try contents.write(to: url, options: .withoutOverwriting)
    }

    private func createOfficeFile(named baseName: String, extension fileExtension: String, entries: [ZipEntry], in directory: URL) throws {
        let url = uniqueURL(in: directory, baseName: baseName, extension: fileExtension)
        let data = ZipWriter.archive(entries: entries)
        try data.write(to: url, options: .withoutOverwriting)
    }

    private func createPowerPointFile(in directory: URL) throws {
        let url = uniqueURL(in: directory, baseName: "新建 PPT", extension: "pptx")
        let data = ZipWriter.archive(entries: OfficeTemplate.powerPoint)
        try data.write(to: url, options: .withoutOverwriting)
    }

    private func open(urls: [URL], app: ExternalApp) throws {
        guard let appURL = app.url else {
            throw ContextMenuActionError.applicationNotFound(app.displayName)
        }
        let targets = urls.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : urls
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(targets, withApplicationAt: appURL, configuration: configuration)
    }

    private func openTerminalWorkspace(urls: [URL], app: ExternalApp) throws {
        guard let appURL = app.url else {
            throw ContextMenuActionError.applicationNotFound(app.displayName)
        }
        let directory = try targetDirectory(from: urls)
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: configuration)
    }

    private func openWarpWorkspace(urls: [URL]) throws {
        guard ExternalApp.warp.url != nil else {
            throw ContextMenuActionError.applicationNotFound(ExternalApp.warp.displayName)
        }
        var components = URLComponents()
        components.scheme = "warp"
        components.host = "action"
        components.path = "/new_window"
        components.queryItems = [URLQueryItem(name: "path", value: try targetDirectory(from: urls).path)]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            throw ContextMenuActionError.applicationNotFound(ExternalApp.warp.displayName)
        }
    }

    private func openWithCustomTarget(
        urls: [URL],
        target: FinderTargetApplication,
        opensDirectory: Bool
    ) throws {
        let appURL: URL?
        if !target.bundleIdentifier.isEmpty,
           let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) {
            appURL = resolved
        } else if !target.lastKnownPath.isEmpty,
                  FileManager.default.fileExists(atPath: target.lastKnownPath) {
            appURL = URL(fileURLWithPath: target.lastKnownPath)
        } else {
            appURL = nil
        }
        guard let appURL else {
            throw ContextMenuActionError.applicationNotFound(
                target.displayName.isEmpty ? target.bundleIdentifier : target.displayName
            )
        }
        let targets: [URL]
        if opensDirectory {
            targets = [try targetDirectory(from: urls)]
        } else {
            targets = urls.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : urls
        }
        NSWorkspace.shared.open(targets, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private func uniqueURL(in directory: URL, baseName: String, extension fileExtension: String?) -> URL {
        func candidate(_ index: Int) -> URL {
            let name = index == 0 ? baseName : "\(baseName) \(index + 1)"
            if let fileExtension {
                return directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
            }
            return directory.appendingPathComponent(name, isDirectory: true)
        }

        var index = 0
        var url = candidate(index)
        while FileManager.default.fileExists(atPath: url.path) {
            index += 1
            url = candidate(index)
        }
        return url
    }

    private static let defaultHTML = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <title>新建 HTML</title>
    </head>
    <body>
    </body>
    </html>
    """

}

private struct ExternalApp {
    let displayName: String
    let bundleIdentifiers: [String]
    let fallbackPaths: [String]

    var url: URL? {
        for bundleIdentifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url
            }
        }
        for path in fallbackPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static let idea = ExternalApp(
        displayName: "IntelliJ IDEA",
        bundleIdentifiers: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"],
        fallbackPaths: ["/Applications/IntelliJ IDEA.app", "/Applications/IntelliJ IDEA CE.app"]
    )

    static let typora = ExternalApp(
        displayName: "Typora",
        bundleIdentifiers: ["abnerworks.Typora", "io.typora"],
        fallbackPaths: ["/Applications/Typora.app"]
    )

    static let vscode = ExternalApp(
        displayName: "Visual Studio Code",
        bundleIdentifiers: ["com.microsoft.VSCode"],
        fallbackPaths: ["/Applications/Visual Studio Code.app"]
    )

    static let terminal = ExternalApp(
        displayName: "Terminal",
        bundleIdentifiers: ["com.apple.Terminal"],
        fallbackPaths: ["/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app"]
    )

    static let warp = ExternalApp(
        displayName: "Warp",
        bundleIdentifiers: ["dev.warp.Warp-Stable", "dev.warp.Warp"],
        fallbackPaths: ["/Applications/Warp.app"]
    )
}

struct ZipEntry {
    let path: String
    let data: Data
}

private enum ZipWriter {
    static func archive(entries: [ZipEntry]) -> Data {
        var data = Data()
        var centralDirectory = Data()

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let localHeaderOffset = UInt32(data.count)

            data.appendUInt32LE(0x04034b50)
            data.appendUInt16LE(20)
            data.appendUInt16LE(0)
            data.appendUInt16LE(0)
            data.appendUInt16LE(0)
            data.appendUInt16LE(0)
            data.appendUInt32LE(crc)
            data.appendUInt32LE(UInt32(entry.data.count))
            data.appendUInt32LE(UInt32(entry.data.count))
            data.appendUInt16LE(UInt16(pathData.count))
            data.appendUInt16LE(0)
            data.append(pathData)
            data.append(entry.data)

            centralDirectory.appendUInt32LE(0x02014b50)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(crc)
            centralDirectory.appendUInt32LE(UInt32(entry.data.count))
            centralDirectory.appendUInt32LE(UInt32(entry.data.count))
            centralDirectory.appendUInt16LE(UInt16(pathData.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(pathData)
        }

        let centralDirectoryOffset = UInt32(data.count)
        data.append(centralDirectory)
        data.appendUInt32LE(0x06054b50)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(UInt16(entries.count))
        data.appendUInt16LE(UInt16(entries.count))
        data.appendUInt32LE(UInt32(centralDirectory.count))
        data.appendUInt32LE(centralDirectoryOffset)
        data.appendUInt16LE(0)

        return data
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            var current = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                current = (current & 1) == 1 ? (0xedb88320 ^ (current >> 1)) : (current >> 1)
            }
            crc = (crc >> 8) ^ current
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}

private enum OfficeTemplate {
    static let word = [
        ZipEntry(path: "[Content_Types].xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """.utf8)),
        ZipEntry(path: "_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """.utf8)),
        ZipEntry(path: "word/document.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p/><w:sectPr/></w:body></w:document>
        """.utf8))
    ]

    static let excel = [
        ZipEntry(path: "[Content_Types].xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """.utf8)),
        ZipEntry(path: "_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8)),
        ZipEntry(path: "xl/workbook.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """.utf8)),
        ZipEntry(path: "xl/_rels/workbook.xml.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """.utf8)),
        ZipEntry(path: "xl/worksheets/sheet1.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>
        """.utf8))
    ]

    static let powerPoint = [
        ZipEntry(path: "[Content_Types].xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/presProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"/><Override PartName="/ppt/viewProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"/><Override PartName="/ppt/tableStyles.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/></Types>
        """.utf8)),
        ZipEntry(path: "_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """.utf8)),
        ZipEntry(path: "docProps/app.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Mac助手</Application><PresentationFormat>宽屏</PresentationFormat><Slides>1</Slides><Notes>0</Notes><HiddenSlides>0</HiddenSlides><MMClips>0</MMClips><ScaleCrop>false</ScaleCrop><Company></Company><LinksUpToDate>false</LinksUpToDate><SharedDoc>false</SharedDoc><HyperlinksChanged>false</HyperlinksChanged><AppVersion>16.0000</AppVersion></Properties>
        """.utf8)),
        ZipEntry(path: "docProps/core.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title></dc:title><dc:creator>Mac助手</dc:creator><cp:lastModifiedBy>Mac助手</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">2026-01-01T00:00:00Z</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">2026-01-01T00:00:00Z</dcterms:modified></cp:coreProperties>
        """.utf8)),
        ZipEntry(path: "ppt/presentation.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """.utf8)),
        ZipEntry(path: "ppt/_rels/presentation.xml.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps" Target="presProps.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps" Target="viewProps.xml"/><Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/><Relationship Id="rId6" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles" Target="tableStyles.xml"/></Relationships>
        """.utf8)),
        ZipEntry(path: "ppt/slides/slide1.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """.utf8)),
        ZipEntry(path: "ppt/slides/_rels/slide1.xml.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>
        """.utf8)),
        ZipEntry(path: "ppt/slideLayouts/slideLayout1.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """.utf8)),
        ZipEntry(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """.utf8)),
        ZipEntry(path: "ppt/slideMasters/slideMaster1.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
        """.utf8)),
        ZipEntry(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
        """.utf8)),
        ZipEntry(path: "ppt/theme/theme1.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F3763"/></a:dk2><a:lt2><a:srgbClr val="F7F7F7"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln><a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln><a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
        """.utf8)),
        ZipEntry(path: "ppt/presProps.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentationPr xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>
        """.utf8)),
        ZipEntry(path: "ppt/viewProps.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:viewPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/></p:normalViewPr><p:slideViewPr><p:cSldViewPr><p:cViewPr varScale="1"><p:scale><a:sx n="100" d="100"/><a:sy n="100" d="100"/></p:scale><p:origin x="0" y="0"/></p:cViewPr><p:guideLst/></p:cSldViewPr></p:slideViewPr></p:viewPr>
        """.utf8)),
        ZipEntry(path: "ppt/tableStyles.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>
        """.utf8))
    ]
}
