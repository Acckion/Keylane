import AppKit
import ApplicationServices
import Carbon
import KeylaneCore

enum SnippetTextTarget {
    struct Position {
        let element: AXUIElement
        let range: CFRange
        let text: String
    }

    static func attribute(_ key: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    static func focused(in app: NSRunningApplication) -> AXUIElement? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), !app.isTerminated else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.06)
        guard let value = attribute(kAXFocusedUIElementAttribute, of: root),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        guard attribute(kAXSubroleAttribute, of: element) as? String != kAXSecureTextFieldSubrole else { return nil }
        return element
    }

    static func position(in app: NSRunningApplication) -> Position? {
        guard let element = focused(in: app),
              let text = attribute(kAXValueAttribute, of: element) as? String,
              let value = attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { return nil }
        return Position(element: element, range: range, text: text)
    }

    static func canReplaceSelection(in element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success &&
            settable.boolValue
    }

    static func replaceSelection(with text: String, in element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    static func select(_ range: CFRange, in element: AXUIElement) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}

final class SnippetExpansion {
    struct Trigger {
        let application: NSRunningApplication
        let position: SnippetTextTarget.Position
        let match: SnippetExpansionMode.Match
    }

    private var monitor: Any?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pending: DispatchWorkItem?
    private var keywordIndex = SnippetKeywordIndex([])
    private var systemKeywords: Set<String> = []
    private var options = SnippetExpansionOptions()
    private var typed = ""
    var plan: ((Snippet) throws -> DynamicTemplate.Plan)?
    var requestArguments: ((Snippet, DynamicTemplate.Plan, Trigger) -> Void)?
    var failure: ((String) -> Void)?

    func configure(_ entries: [Snippet], options: SnippetExpansionOptions) -> Bool {
        stop()
        self.options = options
        guard AXIsProcessTrusted() else { return false }
        keywordIndex = SnippetKeywordIndex(entries)
        guard !keywordIndex.isEmpty else { return false }
        systemKeywords = Set(NSSpellChecker.shared.userReplacementsDictionary.keys.map { $0.lowercased() })
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            if event.type == .keyDown {
                if self.tap == nil { _ = self.handle(event, beforeDelivery: false) }
            } else { self.resetInput() }
        }
        if options.overrideSystem, !systemKeywords.isEmpty {
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                    eventsOfInterest: 1 << CGEventType.keyDown.rawValue, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<SnippetExpansion>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.resetInput()
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if let key = NSEvent(cgEvent: event), owner.handle(key, beforeDelivery: true) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
                self.source = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            } else { tap = nil }
        }
        return monitor != nil
    }

    func stop() {
        resetInput()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        keywordIndex = SnippetKeywordIndex([])
        systemKeywords.removeAll()
    }

    func resetInput() {
        pending?.cancel()
        pending = nil
        typed = ""
    }

    deinit { stop() }

    private func handle(_ event: NSEvent, beforeDelivery: Bool) -> Bool {
        let waiting = pending != nil
        pending?.cancel()
        pending = nil
        guard !keywordIndex.isEmpty, !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty,
              !IsSecureEventInputEnabled(), Self.asciiInput,
              let characters = event.characters, characters.count == 1, let key = characters.first,
              let target = NSWorkspace.shared.frontmostApplication,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !options.excludes(target.bundleIdentifier) else { resetInput(); return false }
        let isDelimiter = SnippetExpansionMode.isDelimiter(key)
        let prior = typed
        typed = Snippet.validKeyword(characters) ? String((typed + characters).suffix(40)) : ""
        let mode = options.mode
        let onDelimiter = isDelimiter && (mode != .immediately || waiting ||
            (beforeDelivery && keywordIndex.matching(prior, where: isSystemKeyword) != nil))
        func matchingSnippet(in input: String) -> Snippet? {
            keywordIndex.matching(input) { options.overrideSystem || !isSystemKeyword($0) }
        }
        let delimited = onDelimiter ? matchingSnippet(in: prior) : nil
        guard let (snippet, usesDelimiter) = mode.keywordMatch(in: typed, delimited: delimited, matching: matchingSnippet) else {
            return false
        }

        let delimiter = usesDelimiter ? characters : ""
        let intercepted: Trigger?
        if beforeDelivery, let delimited, isSystemKeyword(delimited.keyword) {
            intercepted = intercept(characters, for: snippet, in: target, mode: mode, delimiter: delimiter)
            if intercepted != nil, usesDelimiter { typed = "" }
        } else {
            intercepted = nil
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            guard self.monitor != nil, Self.asciiInput,
                  let trigger = intercepted ?? self.match(snippet, target: target, delimiter: delimiter, mode: mode) else { return }
            do {
                guard let template = try self.plan?(snippet) else { return }
                if template.arguments.isEmpty {
                    _ = self.replace(try template.resolve(), trigger: trigger, richText: snippet.richText)
                } else if self.currentPosition(for: trigger) != nil {
                    self.requestArguments?(snippet, template, trigger)
                }
                self.typed = ""
            } catch { self.failure?(error.localizedDescription) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + options.delay.seconds + options.response.seconds, execute: work)
        return intercepted != nil
    }

    private func isSystemKeyword(_ keyword: String) -> Bool { systemKeywords.contains(keyword.lowercased()) }

    private func match(_ snippet: Snippet, target: NSRunningApplication, delimiter: String,
                       mode: SnippetExpansionMode) -> Trigger? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let position = SnippetTextTarget.position(in: target), position.range.length == 0,
              let match = mode.match(in: position.text, caret: position.range.location, keyword: snippet.keyword,
                                     delimiter: delimiter, withinWords: options.withinWords) else { return nil }
        return .init(application: target, position: position, match: match)
    }

    private func intercept(_ character: String, for snippet: Snippet, in target: NSRunningApplication,
                           mode: SnippetExpansionMode, delimiter: String) -> Trigger? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let original = SnippetTextTarget.position(in: target), original.range.length == 0,
              SnippetTextTarget.canReplaceSelection(in: original.element) else { return nil }
        let caret = NSRange(location: original.range.location, length: 0)
        let text = (original.text as NSString).replacingCharacters(in: caret, with: character)
        let location = caret.location + character.utf16.count
        guard let match = mode.match(in: text, caret: location, keyword: snippet.keyword,
                                     delimiter: delimiter, withinWords: options.withinWords),
              currentPosition(in: target, matching: original) != nil,
              SnippetTextTarget.replaceSelection(with: character, in: original.element) else { return nil }

        // Deliver the key literally so the system cannot replace the preceding keyword,
        // including when the key completes a longer keyword instead of delimiting it.
        let position = SnippetTextTarget.Position(element: original.element, range: CFRange(location: location, length: 0), text: text)
        return .init(application: target, position: position, match: match)
    }

    private func currentPosition(for trigger: Trigger, selection: CFRange? = nil) -> SnippetTextTarget.Position? {
        currentPosition(in: trigger.application, matching: trigger.position, selection: selection)
    }

    private func currentPosition(in app: NSRunningApplication, matching original: SnippetTextTarget.Position,
                                 selection: CFRange? = nil) -> SnippetTextTarget.Position? {
        let expected = selection ?? original.range
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              !options.excludes(app.bundleIdentifier), let current = SnippetTextTarget.position(in: app),
              CFEqual(original.element, current.element), original.text == current.text,
              current.range.location == expected.location, current.range.length == expected.length else { return nil }
        return current
    }

    @discardableResult
    func replace(_ rendered: DynamicTemplate.Rendered, trigger: Trigger, richText: Data?) -> Bool {
        guard let current = currentPosition(for: trigger) else { return false }
        let match = trigger.match
        let element = current.element
        let range = CFRange(location: match.range.location, length: match.range.length)
        guard SnippetTextTarget.canReplaceSelection(in: element),
              SnippetTextTarget.select(range, in: element) else { return false }

        guard SnippetTextTarget.attribute(kAXSelectedTextAttribute, of: element) as? String == match.expected else {
            if currentPosition(for: trigger, selection: range) != nil { _ = SnippetTextTarget.select(current.range, in: element) }
            return false
        }
        let value = rendered.text + match.suffix
        if let richText {
            let pasted = SnippetPasteboard.pasteTemporarily(
                rendered, richText: richText, suffix: match.suffix, response: options.response.seconds,
                target: trigger.application.processIdentifier,
                canPaste: { self.currentPosition(for: trigger, selection: range) != nil },
                completion: { [weak self] in self?.finish(rendered, value: value, trigger: trigger) }
            )
            if pasted { return true }
            guard currentPosition(for: trigger, selection: range) != nil else { return false }
        }
        guard SnippetTextTarget.replaceSelection(with: value, in: element) else {
            _ = SnippetTextTarget.select(current.range, in: element)
            return false
        }
        finish(rendered, value: value, trigger: trigger)
        return true
    }

    private func finish(_ rendered: DynamicTemplate.Rendered, value: String, trigger: Trigger) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == trigger.application.processIdentifier,
              let current = SnippetTextTarget.position(in: trigger.application),
              CFEqual(current.element, trigger.position.element),
              current.text == (trigger.position.text as NSString).replacingCharacters(in: trigger.match.range, with: value) else { return }
        if let offset = rendered.cursorOffset,
           current.range.length == 0, current.range.location == trigger.match.range.location + value.utf16.count {
            _ = SnippetTextTarget.select(CFRange(location: trigger.match.range.location + offset, length: 0), in: current.element)
        }
        if !options.sound.isEmpty { NSSound(named: options.sound)?.play() }
    }

    private static var asciiInput: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
}

/// Searches the bounded typed suffix from longest to shortest without scanning the snippet library.
struct SnippetKeywordIndex {
    private let snippets: [Substring: Snippet]

    init(_ entries: [Snippet]) {
        snippets = Dictionary(entries.lazy.filter { !$0.keyword.isEmpty }.map { ($0.keyword[...], $0) },
                              uniquingKeysWith: { first, _ in first })
    }

    var isEmpty: Bool { snippets.isEmpty }

    func matching(_ typed: String, where allowed: (String) -> Bool) -> Snippet? {
        var start = typed.startIndex
        while start < typed.endIndex {
            if let snippet = snippets[typed[start...]], allowed(snippet.keyword) { return snippet }
            typed.formIndex(after: &start)
        }
        return nil
    }
}
