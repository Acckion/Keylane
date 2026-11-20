import AppKit
import ApplicationServices
import Carbon
import KeylaneCore

struct DictationTarget {
    let application: NSRunningApplication
    let position: SnippetTextTarget.Position?
    let element: AXUIElement?
    let website: String?
    let nearbyText: String?

    init(application: NSRunningApplication, includeContext: Bool) {
        self.application = application
        position = SnippetTextTarget.position(in: application)
        element = position?.element ?? SnippetTextTarget.focused(in: application)
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.06)
        var host: String?
        if let window = SnippetTextTarget.attribute(kAXFocusedWindowAttribute, of: root), CFGetTypeID(window) == AXUIElementGetTypeID(),
           let document = SnippetTextTarget.attribute(kAXDocumentAttribute, of: window as! AXUIElement) {
            let value = (document as? URL)?.absoluteString ?? (document as? String)
            if let value, let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), let domain = url.host {
                host = "https://" + domain
            }
        }
        website = host
        if includeContext, let position {
            let text = position.text as NSString
            let start = max(0, position.range.location - 2000)
            nearbyText = text.substring(with: NSRange(location: start, length: min(4000, text.length - start)))
        } else { nearbyText = nil }
    }

    var isCurrent: Bool {
        guard !application.isTerminated, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return false }
        if let position {
            guard let current = SnippetTextTarget.position(in: application), CFEqual(position.element, current.element),
                  position.range.location == current.range.location, position.range.length == current.range.length,
                  position.text == current.text else { return false }
        } else if let element {
            guard let current = SnippetTextTarget.focused(in: application), CFEqual(element, current) else { return false }
        }
        return true
    }
}

enum DictationDelivery {
    static func copy(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }

    static func paste(_ text: String, target: DictationTarget, keepCopy: Bool, submit: Bool, shift: Bool,
                      isCurrent: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard isCurrent(), target.isCurrent, let element = target.element else { completion(false); return }
        let originalElement = element
        if SnippetTextTarget.canReplaceSelection(in: element), SnippetTextTarget.replaceSelection(with: text, in: element) {
            if keepCopy { _ = copy(text) }
            finish(target: target, element: originalElement, submit: submit, shift: shift, isCurrent: isCurrent, completion: completion)
            return
        }
        let board = NSPasteboard.general
        let old = keepCopy ? nil : snapshot(board)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if !keepCopy { item.setString("1", forType: .init("org.nspasteboard.TransientType")) }
        board.clearContents()
        guard board.writeObjects([item]) else { completion(false); return }
        let generation = board.changeCount
        guard target.isCurrent, isCurrent(), post(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else {
            restore(old, board: board, generation: generation); completion(false); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            restore(old, board: board, generation: generation)
            finish(target: target, element: originalElement, submit: submit, shift: shift, isCurrent: isCurrent, completion: completion)
        }
    }

    private static func finish(target: DictationTarget, element: AXUIElement, submit: Bool, shift: Bool,
                               isCurrent: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard isCurrent() else { completion(false); return }
        if submit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard isCurrent(), !IsSecureEventInputEnabled(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processIdentifier,
                      let current = SnippetTextTarget.focused(in: target.application), CFEqual(element, current) else {
                    completion(true); return
                }
                _ = post(key: CGKeyCode(kVK_Return), flags: shift ? .maskShift : [])
                completion(true)
            }
        } else { completion(true) }
    }
    private static func post(key: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = flags; up.flags = flags
        ModifierShortcuts.postWithoutHyperRemapping(down); ModifierShortcuts.postWithoutHyperRemapping(up)
        return true
    }
    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem]? {
        guard board.accessBehavior == .alwaysAllow else { return nil }
        var bytes = 0
        var saved: [NSPasteboardItem] = []
        for original in board.pasteboardItems ?? [] {
            guard !original.types.contains(.fileURL), !original.types.contains(.init("org.nspasteboard.ConcealedType")) else { return nil }
            let item = NSPasteboardItem()
            for type in original.types {
                guard !type.rawValue.localizedCaseInsensitiveContains("promise"), let data = original.data(forType: type),
                      data.count <= 8_388_608 - bytes else { return nil }
                bytes += data.count; item.setData(data, forType: type)
            }
            saved.append(item)
        }
        return saved
    }
    private static func restore(_ items: [NSPasteboardItem]?, board: NSPasteboard, generation: Int) {
        guard let items, board.changeCount == generation else { return }
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }
}
