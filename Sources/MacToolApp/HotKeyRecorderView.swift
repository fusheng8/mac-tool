import AppKit
import Foundation

final class HotKeyRecorderView: NSView {
    var onChange: ((HotKeyConfig) -> Void)?
    var allowsModifierless = false
    var isRecorderEnabled = true {
        didSet {
            if !isRecorderEnabled {
                isRecording = false
            }
            alphaValue = isRecorderEnabled ? 1.0 : 0.45
        }
    }
    var currentHotKey: HotKeyConfig { hotKey }
    private let label = NSTextField(labelWithString: "")
    private var hotKey: HotKeyConfig
    private var isRecording = false {
        didSet {
            label.stringValue = isRecording ? "输入快捷键..." : hotKey.displayText
            layer?.borderColor = (isRecording ? NSColor.systemBlue : NSColor.separatorColor).cgColor
        }
    }

    init(hotKey: HotKeyConfig) {
        self.hotKey = hotKey
        super.init(frame: .zero)
        buildUI()
        label.stringValue = hotKey.displayText
    }

    required init?(coder: NSCoder) {
        fatalError("未实现 init(coder:)")
    }

    override var acceptsFirstResponder: Bool { true }

    func setHotKey(_ hotKey: HotKeyConfig) {
        self.hotKey = hotKey
        if !isRecording {
            label.stringValue = hotKey.displayText
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isRecorderEnabled else { return }
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecorderEnabled else { return }
        if event.keyCode == 53 {
            isRecording = false
            return
        }
        let modifiers = HotKeyFormatter.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 || allowsModifierless else {
            NSSound.beep()
            return
        }
        let display = HotKeyFormatter.displayText(
            keyCode: event.keyCode,
            modifiers: modifiers,
            characters: event.charactersIgnoringModifiers
        )
        hotKey = HotKeyConfig(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: modifiers,
            displayText: display
        )
        isRecording = false
        onChange?(hotKey)
    }

    private func buildUI() {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 180).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}
