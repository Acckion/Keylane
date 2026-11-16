import AppKit
import Carbon
import KeylaneCore

enum SnippetPasteboard {
    static func attributedText(_ data: Data?) -> NSAttributedString? {
        guard let data else { return nil }
        return try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                       documentAttributes: nil)
    }

    private static func item(_ rendered: DynamicTemplate.Rendered, richText: Data?, suffix: String = "") -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(rendered.text + suffix, forType: .string)
        if let original = attributedText(richText) {
            let output = NSMutableAttributedString(attributedString: original)
            for replacement in rendered.replacements.reversed() where NSMaxRange(replacement.range) <= output.length {
                output.replaceCharacters(in: replacement.range, with: replacement.text)
            }
            if output.string == rendered.text {
                output.mutableString.append(suffix)
                if let data = try? output.data(from: NSRange(location: 0, length: output.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    item.setData(data, forType: .rtf)
                }
            }
        }
        return item
    }

    static func copy(_ rendered: DynamicTemplate.Rendered, richText: Data?) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.writeObjects([item(rendered, richText: richText)])
    }

    /// Keep the user's clipboard intact, including when another application copies during the paste.
    static func pasteTemporarily(_ rendered: DynamicTemplate.Rendered, richText: Data, suffix: String,
                                 response: TimeInterval, target: pid_t, canPaste: () -> Bool,
                                 completion: @escaping () -> Void) -> Bool {
        let board = NSPasteboard.general
        guard board.accessBehavior == .alwaysAllow else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        let initialGeneration = board.changeCount
        guard let originalItems = board.pasteboardItems else { return false }
        var saved: [NSPasteboardItem] = []
        var bytes = 0
        for original in originalItems {
            guard !original.types.contains(.fileURL),
                  !original.types.contains(.init("org.nspasteboard.ConcealedType")) else { return false }
            let snapshot = NSPasteboardItem()
            for type in original.types {
                guard !type.rawValue.localizedCaseInsensitiveContains("promise"),
                      let data = original.data(forType: type), data.count <= 8 * 1024 * 1024 - bytes else { return false }
                bytes += data.count
                snapshot.setData(data, forType: type)
            }
            saved.append(snapshot)
        }
        let temporary = item(rendered, richText: richText, suffix: suffix)
        guard temporary.types.contains(.rtf), canPaste(), board.changeCount == initialGeneration else { return false }
        temporary.setString("1", forType: .init("org.nspasteboard.TransientType"))
        board.clearContents()
        guard board.writeObjects([temporary]) else {
            board.clearContents()
            if !saved.isEmpty { _ = board.writeObjects(saved) }
            return false
        }
        let generation = board.changeCount
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(target)
        up.postToPid(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.12, response * 2)) {
            if board.changeCount == generation {
                board.clearContents()
                if !saved.isEmpty { _ = board.writeObjects(saved) }
            }
            completion()
        }
        return true
    }
}
