import AppKit
import ApplicationServices
import Carbon
import KeylaneCore

final class SnippetExpansion {
    private var monitor: Any?
    private var pending: DispatchWorkItem?
    private var snippets: [String: Snippet] = [:]
    private var token = ""

    func configure(_ entries: [Snippet]) -> Bool {
        stop()
        for snippet in entries where !snippet.keyword.isEmpty {
            snippets[snippet.keyword] = snippet
        }
        guard !snippets.isEmpty, AXIsProcessTrusted() else { return false }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handle(event)
        }
        return monitor != nil
    }

    func stop() {
        resetInput()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        snippets = [:]
    }

    func resetInput() {
        pending?.cancel()
        pending = nil
        token = ""
    }

    deinit { stop() }

    private func handle(_ event: NSEvent) {
        pending?.cancel()
        guard event.type == .keyDown, !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !IsSecureEventInputEnabled() else { token = ""; return }
        let typed = token
        if event.keyCode != UInt16(kVK_Space) || event.characters != " " {
            if let character = event.characters, character.utf8.count == 1,
               Snippet.validKeyword(character) {
                token = String((token + character).suffix(40))
            } else { token = "" }
            return
        }
        token = ""
        guard let snippet = snippets[typed], !event.modifierFlags.contains(.shift), Self.asciiInput,
              let target = NSWorkspace.shared.frontmostApplication,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let field = Self.focused(pid: target.processIdentifier) else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.monitor != nil, AXIsProcessTrusted(), !IsSecureEventInputEnabled(), Self.asciiInput,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  let current = Self.focused(pid: target.processIdentifier), CFEqual(field, current) else { return }
            self.expand(snippet, in: current)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    private static var asciiInput: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }

    private static func attribute(_ key: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private static func focused(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.10)
        guard let value = attribute(kAXFocusedUIElementAttribute, of: app),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    private func expand(_ snippet: Snippet, in element: AXUIElement) {
        let role = Self.attribute(kAXRoleAttribute, of: element) as? String
        let subrole = Self.attribute(kAXSubroleAttribute, of: element) as? String
        guard role == kAXTextFieldRole || role == kAXTextAreaRole,
              subrole != kAXSecureTextFieldSubrole else { return }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue,
              let value = Self.attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return }
        var caret = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &caret), caret.length == 0, caret.location > 0,
              let text = Self.attribute(kAXValueAttribute, of: element) as? String else { return }

        guard let range = Snippet.expansionRange(in: text, caret: caret.location, keyword: snippet.keyword) else { return }
        let rendered = snippet.render()
        guard Self.setSelection(CFRange(location: range.location, length: range.length), on: element) else { return }
        guard Self.attribute(kAXSelectedTextAttribute, of: element) as? String == snippet.keyword + " ",
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, (rendered.text + " ") as CFString) == .success else {
            _ = Self.setSelection(caret, on: element)
            return
        }
        if let offset = rendered.cursorOffset {
            _ = Self.setSelection(CFRange(location: range.location + offset, length: 0), on: element)
        }
    }

    private static func setSelection(_ range: CFRange, on element: AXUIElement) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}
