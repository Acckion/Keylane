import AppKit

/// The placeholder follows the editor's visible text, including uncommitted IME text.
final class TranslatorTextView: NSTextView {
    var onCommittedChange: ((String) -> Void)?
    var showsPlaceholder: Bool { string.isEmpty }

    override var string: String {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsPlaceholder else { return }
        let point = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                            y: textContainerOrigin.y)
        ("输入要翻译的文字…" as NSString).draw(at: point, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 23), .foregroundColor: NSColor.placeholderTextColor
        ])
    }

    override func didChangeText() {
        super.didChangeText()
        publishCommittedText()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        publishCommittedText()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        publishCommittedText()
    }

    private func publishCommittedText() {
        needsDisplay = true
        if !hasMarkedText() { onCommittedChange?(string) }
    }
}
