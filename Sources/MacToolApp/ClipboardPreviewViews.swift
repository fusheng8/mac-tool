import AppKit
import Foundation

class ClipboardPreviewCard: NSView {
    let contentView = NSView()

    init(title: String? = nil, symbolName: String? = nil, content: NSView? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = MacAssistantUI.Color.card.cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderColor = MacAssistantUI.Color.hairline.cgColor
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        if let title {
            stack.addArrangedSubview(Self.makeHeader(title: title, symbolName: symbolName))
        }

        contentView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(contentView)

        if let content {
            setContent(content)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func setContent(_ view: NSView) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    static func emptyState(title: String, message: String, symbolName: String = "doc.text.magnifyingglass") -> NSView {
        let view = LayerBackedView(backgroundColor: NSColor.white.withAlphaComponent(0.52), cornerRadius: 10, borderColor: MacAssistantUI.Color.hairline, borderWidth: 1)
        let icon = NSImageView()
        icon.image = MacAssistantUI.symbol(symbolName, pointSize: 34, weight: .regular)
        icon.contentTintColor = MacAssistantUI.Color.mutedText
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = MacAssistantUI.title(title, size: 13, weight: .semibold)
        titleLabel.alignment = .center

        let messageLabel = MacAssistantUI.caption(message, size: 12)
        messageLabel.alignment = .center

        let stack = NSStackView(views: [icon, titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 38),
            icon.heightAnchor.constraint(equalToConstant: 38),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        return view
    }

    private static func makeHeader(title: String, symbolName: String?) -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 22).isActive = true

        var leadingAnchor = header.leadingAnchor
        if let symbolName {
            let icon = NSImageView()
            icon.image = MacAssistantUI.symbol(symbolName, pointSize: 14, weight: .medium)
            icon.contentTintColor = MacAssistantUI.Color.blue
            icon.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16)
            ])
            leadingAnchor = icon.trailingAnchor
        }

        let label = MacAssistantUI.title(title, size: 13, weight: .semibold)
        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: symbolName == nil ? 0 : 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return header
    }
}

final class ClipboardPreviewTextView: ClipboardPreviewCard {
    enum Mode {
        case plain
        case code
    }

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var currentText = ""
    private var mode: Mode = .plain
    private var showsLineNumbers = false

    init(text: String, mode: Mode = .plain, showsLineNumbers: Bool = false, title: String? = nil) {
        super.init(title: title, symbolName: mode == .code ? "chevron.left.forwardslash.chevron.right" : "doc.text")
        setup()
        configure(text: text, mode: mode, showsLineNumbers: showsLineNumbers)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func configure(text: String, mode: Mode = .plain, showsLineNumbers: Bool = false) {
        currentText = text
        self.mode = mode
        self.showsLineNumbers = showsLineNumbers
        textView.textStorage?.setAttributedString(makeAttributedText())
    }

    private func setup() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView

        let well = LayerBackedView(
            backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.92),
            cornerRadius: 8,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        well.layer?.masksToBounds = true
        well.addSubview(scrollView)
        setContent(well)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: well.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: well.bottomAnchor),
            well.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }

    private func makeAttributedText() -> NSAttributedString {
        let font = mode == .code
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 12.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping

        let displayText = showsLineNumbers ? numberedText(currentText) : currentText
        let attributed = NSMutableAttributedString(
            string: displayText,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )

        if showsLineNumbers {
            colorLineNumbers(in: attributed)
        }
        if mode == .code {
            applyBasicHighlighting(to: attributed)
        }
        return attributed
    }

    private func numberedText(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let width = max(2, String(lines.count).count)
        return lines.enumerated().map { index, line in
            "\(String(format: "%\(width)d", index + 1))  \(line)"
        }.joined(separator: "\n")
    }

    private func colorLineNumbers(in attributed: NSMutableAttributedString) {
        let nsString = attributed.string as NSString
        nsString.enumerateSubstrings(in: NSRange(location: 0, length: nsString.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = nsString.substring(with: range)
            guard let numberEnd = line.range(of: "  ") else { return }
            let length = line.distance(from: line.startIndex, to: numberEnd.upperBound)
            attributed.addAttributes([
                .foregroundColor: MacAssistantUI.Color.subtleText,
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.035)
            ], range: NSRange(location: range.location, length: length))
        }
    }

    private func applyBasicHighlighting(to attributed: NSMutableAttributedString) {
        let rules: [(String, NSColor)] = [
            (#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, MacAssistantUI.Color.green),
            (#"\b\d+(?:\.\d+)?\b"#, MacAssistantUI.Color.purple),
            (#"\b(class|struct|enum|func|let|var|if|else|for|while|return|import|try|catch|throw|guard|switch|case|default|public|private|final|static|async|await|true|false|null|nil)\b"#, MacAssistantUI.Color.blue)
        ]

        for (pattern, color) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let fullRange = NSRange(location: 0, length: (attributed.string as NSString).length)
            regex.enumerateMatches(in: attributed.string, options: [], range: fullRange) { match, _, _ in
                guard let range = match?.range else { return }
                attributed.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }
}

final class ClipboardPreviewTableView: ClipboardPreviewCard {
    private let headerStack = NSStackView()
    private let bodyStack = NSStackView()
    private let scrollView = NSScrollView()
    private var rows: [[String]] = []

    init(rows: [[String]], title: String? = nil) {
        super.init(title: title ?? "表格预览", symbolName: "tablecells")
        setup()
        configure(rows: rows)
    }

    convenience init(text: String, delimiter: Character? = nil, title: String? = nil) {
        let parsed = Self.parseDelimitedText(text, delimiter: delimiter)
        self.init(rows: parsed, title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func configure(rows: [[String]]) {
        self.rows = rows
        rebuild()
    }

    private func setup() {
        let container = LayerBackedView(
            backgroundColor: NSColor.white.withAlphaComponent(0.58),
            cornerRadius: 8,
            borderColor: MacAssistantUI.Color.hairline,
            borderWidth: 1
        )
        container.layer?.masksToBounds = true

        headerStack.orientation = .horizontal
        headerStack.spacing = 0
        headerStack.distribution = .fillEqually
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        bodyStack.orientation = .vertical
        bodyStack.spacing = 0
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = ClipboardPreviewFlippedView()
        documentView.addSubview(bodyStack)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerStack)
        container.addSubview(scrollView)
        setContent(container)

        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: container.topAnchor),
            headerStack.heightAnchor.constraint(equalToConstant: 32),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: bodyStack.heightAnchor),

            bodyStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            bodyStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }

    private func rebuild() {
        headerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let header = rows.first else {
            setContent(ClipboardPreviewCard.emptyState(title: "无表格数据", message: "未检测到可预览的 CSV/TSV 内容", symbolName: "tablecells.badge.ellipsis"))
            return
        }

        let maxColumns = max(1, min(12, rows.map(\.count).max() ?? header.count))
        for index in 0..<maxColumns {
            headerStack.addArrangedSubview(makeCell(header[safe: index] ?? "列 \(index + 1)", isHeader: true))
        }

        for row in rows.dropFirst().prefix(500) {
            let rowStack = NSStackView()
            rowStack.orientation = .horizontal
            rowStack.spacing = 0
            rowStack.distribution = .fillEqually
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.heightAnchor.constraint(equalToConstant: 30).isActive = true
            for index in 0..<maxColumns {
                rowStack.addArrangedSubview(makeCell(row[safe: index] ?? "", isHeader: false))
            }
            bodyStack.addArrangedSubview(rowStack)
        }
    }

    private func makeCell(_ text: String, isHeader: Bool) -> NSView {
        let cell = LayerBackedView(backgroundColor: isHeader ? MacAssistantUI.Color.cardHover : NSColor.clear, borderColor: MacAssistantUI.Color.hairline.withAlphaComponent(0.55), borderWidth: 0.5)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: isHeader ? .semibold : .regular)
        label.textColor = isHeader ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private static func parseDelimitedText(_ text: String, delimiter: Character?) -> [[String]] {
        let resolvedDelimiter = delimiter ?? (text.contains("\t") ? "\t" : ",")
        if resolvedDelimiter == "\t" {
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            }.filter { !$0.allSatisfy(\.isEmpty) }
        }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if isQuoted, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        isQuoted = false
                        if next == resolvedDelimiter {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else {
                            field.append(next)
                        }
                    }
                } else {
                    isQuoted.toggle()
                }
            } else if character == resolvedDelimiter, !isQuoted {
                row.append(field)
                field = ""
            } else if character == "\n", !isQuoted {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
        }
        row.append(field)
        rows.append(row)
        return rows.filter { !$0.allSatisfy(\.isEmpty) }
    }
}

final class ClipboardPreviewURLCardView: ClipboardPreviewCard {
    private let hostLabel = MacAssistantUI.title("", size: 17, weight: .semibold)
    private let schemeLabel = ClipboardPreviewURLCardView.makeValueLabel()
    private let pathLabel = ClipboardPreviewURLCardView.makeValueLabel()
    private let urlLabel = ClipboardPreviewURLCardView.makeValueLabel()

    init(url: URL, title: String? = nil) {
        super.init(title: title, symbolName: "link")
        setup()
        configure(url: url)
    }

    convenience init(urlString: String, title: String? = nil) {
        self.init(url: URL(string: urlString) ?? URL(fileURLWithPath: urlString), title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func configure(url: URL) {
        hostLabel.stringValue = url.host(percentEncoded: false) ?? url.host ?? "本地路径"
        schemeLabel.stringValue = url.scheme?.uppercased() ?? "FILE"
        pathLabel.stringValue = url.path.isEmpty ? "/" : url.path
        urlLabel.stringValue = url.absoluteString
    }

    private func setup() {
        let iconWrap = LayerBackedView(backgroundColor: MacAssistantUI.Color.blue.withAlphaComponent(0.12), cornerRadius: 9)
        let icon = NSImageView()
        icon.image = MacAssistantUI.symbol("link.circle.fill", pointSize: 28, weight: .regular)
        icon.contentTintColor = MacAssistantUI.Color.blue
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.addSubview(icon)

        [hostLabel, schemeLabel, pathLabel, urlLabel].forEach {
            $0.lineBreakMode = .byTruncatingMiddle
            $0.maximumNumberOfLines = 1
        }

        let metaStack = NSStackView(views: [
            makeInfoRow(label: "Scheme", value: schemeLabel),
            makeInfoRow(label: "Path", value: pathLabel),
            makeInfoRow(label: "URL", value: urlLabel)
        ])
        metaStack.orientation = .vertical
        metaStack.spacing = 6

        let textStack = NSStackView(views: [hostLabel, metaStack])
        textStack.orientation = .vertical
        textStack.spacing = 10

        let row = NSStackView(views: [iconWrap, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        setContent(row)

        NSLayoutConstraint.activate([
            iconWrap.widthAnchor.constraint(equalToConstant: 44),
            iconWrap.heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: iconWrap.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func makeInfoRow(label: String, value: NSTextField) -> NSView {
        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = MacAssistantUI.Color.subtleText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let row = NSStackView(views: [titleLabel, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private static func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = MacAssistantUI.Color.mutedText
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

final class ClipboardPreviewFileListView: ClipboardPreviewCard {
    struct Item {
        let url: URL
        let exists: Bool
        let size: Int64?

        init(url: URL, exists: Bool? = nil, size: Int64? = nil) {
            self.url = url
            let fileExists = FileManager.default.fileExists(atPath: url.path)
            self.exists = exists ?? fileExists
            self.size = size ?? Self.fileSize(for: url, exists: exists ?? fileExists)
        }

        init(path: String, exists: Bool? = nil, size: Int64? = nil) {
            self.init(url: URL(fileURLWithPath: path), exists: exists, size: size)
        }

        private static func fileSize(for url: URL, exists: Bool) -> Int64? {
            guard exists,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]) else { return nil }
            if let fileSize = values.fileSize {
                return Int64(fileSize)
            }
            if let allocatedSize = values.totalFileAllocatedSize {
                return Int64(allocatedSize)
            }
            return nil
        }
    }

    private let stack = NSStackView()
    private let formatter = ByteCountFormatter()

    init(items: [Item], title: String? = nil) {
        super.init(title: title ?? "文件列表", symbolName: "folder")
        setup()
        configure(items: items)
    }

    convenience init(paths: [String], title: String? = nil) {
        self.init(items: paths.map { Item(path: $0) }, title: title)
    }

    convenience init(urls: [URL], title: String? = nil) {
        self.init(items: urls.map { Item(url: $0) }, title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func configure(items: [Item]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !items.isEmpty else {
            stack.addArrangedSubview(ClipboardPreviewCard.emptyState(title: "无文件路径", message: "没有可显示的文件或路径", symbolName: "folder.badge.questionmark"))
            return
        }

        for item in items.prefix(200) {
            stack.addArrangedSubview(makeRow(for: item))
        }
    }

    private func setup() {
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]

        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = ClipboardPreviewFlippedView()
        documentView.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        setContent(scrollView)

        NSLayoutConstraint.activate([
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }

    private func makeRow(for item: Item) -> NSView {
        let row = LayerBackedView(backgroundColor: NSColor.white.withAlphaComponent(0.56), cornerRadius: 8, borderColor: MacAssistantUI.Color.hairline.withAlphaComponent(0.72), borderWidth: 1)
        row.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let iconView = NSImageView()
        iconView.image = item.exists ? NSWorkspace.shared.icon(forFile: item.url.path) : MacAssistantUI.symbol("doc.badge.questionmark", pointSize: 24, weight: .regular)
        iconView.contentTintColor = item.exists ? nil : MacAssistantUI.Color.mutedText
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: item.url.lastPathComponent.isEmpty ? item.url.path : item.url.lastPathComponent)
        nameLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1

        let pathLabel = NSTextField(labelWithString: item.url.path)
        pathLabel.font = .systemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = MacAssistantUI.Color.mutedText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [nameLabel, pathLabel])
        textStack.orientation = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: statusText(for: item))
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = item.exists ? MacAssistantUI.Color.green : MacAssistantUI.Color.amber
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(iconView)
        row.addSubview(textStack)
        row.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 92)
        ])
        return row
    }

    private func statusText(for item: Item) -> String {
        guard item.exists else { return "不存在" }
        guard let size = item.size else { return "存在" }
        return formatter.string(fromByteCount: size)
    }
}

final class ClipboardPreviewImageView: ClipboardPreviewCard {
    private let checkerboardView = ClipboardPreviewCheckerboardView()
    private let imageCanvas = ClipboardPreviewAspectFitImageCanvas()

    init(image: NSImage?, title: String? = nil) {
        super.init(title: title ?? "图片预览", symbolName: "photo")
        setup()
        configure(image: image)
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    func configure(image: NSImage?) {
        imageCanvas.image = image
        imageCanvas.isHidden = image == nil
    }

    private func setup() {
        checkerboardView.translatesAutoresizingMaskIntoConstraints = false
        checkerboardView.addSubview(imageCanvas)
        setContent(checkerboardView)

        NSLayoutConstraint.activate([
            checkerboardView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            imageCanvas.leadingAnchor.constraint(equalTo: checkerboardView.leadingAnchor, constant: 14),
            imageCanvas.trailingAnchor.constraint(equalTo: checkerboardView.trailingAnchor, constant: -14),
            imageCanvas.topAnchor.constraint(equalTo: checkerboardView.topAnchor, constant: 14),
            imageCanvas.bottomAnchor.constraint(equalTo: checkerboardView.bottomAnchor, constant: -14)
        ])
    }
}

private final class ClipboardPreviewAspectFitImageCanvas: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image,
              image.isValid,
              image.size.width > 0,
              image.size.height > 0,
              bounds.width > 0,
              bounds.height > 0 else { return }

        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = NSRect(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

private final class ClipboardPreviewCheckerboardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderColor = MacAssistantUI.Color.hairline.cgColor
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        bounds.fill()

        let tileSize: CGFloat = 12
        let alternate = NSColor(calibratedWhite: 0.88, alpha: 1)
        var y: CGFloat = 0
        var row = 0
        while y < bounds.height {
            var x: CGFloat = row.isMultiple(of: 2) ? 0 : tileSize
            while x < bounds.width {
                alternate.setFill()
                NSRect(x: x, y: y, width: tileSize, height: tileSize).fill()
                x += tileSize * 2
            }
            row += 1
            y += tileSize
        }
    }
}

private final class ClipboardPreviewFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
