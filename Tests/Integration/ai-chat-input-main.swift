import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let composer = AIConversationComposer()
var submitted = 0
var chosen = 0
var moved = 0
var dismissed = 0
let root = AIConversationTextInput(composer: composer, height: .constant(36), enabled: true,
    sendWithReturn: true, menuVisible: true, submit: { submitted += 1 },
    moveMenu: { moved += $0 }, chooseMenu: { chosen += 1 }, dismissMenu: { dismissed += 1 })
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView = NSHostingView(rootView: root)
window.contentView!.layoutSubtreeIfNeeded()
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
let input = descendants(window.contentView!).compactMap { $0 as? AIConversationTextInput.Input }.first!
func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    input.keyDown(with: event)
}
input.string = "hello 😀 @file suffix"
input.setSelectedRange(NSRange(location: ("hello 😀 @file" as NSString).length, length: 0))
input.owner!.textDidChange(Notification(name: NSText.didChangeNotification, object: input))
precondition(composer.completion?.query == "file")
key(125, "\u{F701}")
key(36, "\r")
key(53, "\u{1b}")
precondition(moved == 1 && chosen == 1 && dismissed == 1 && submitted == 0)
input.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: input.selectedRange())
input.owner!.textDidChange(Notification(name: NSText.didChangeNotification, object: input))
precondition(composer.completion == nil, "Marked text must not open a command menu")
precondition(!input.showsPlaceholder, "IME candidate text must not overlap a placeholder")
input.unmarkText()
input.owner!.parent = AIConversationTextInput(composer: composer, height: .constant(36), enabled: true,
    sendWithReturn: true, menuVisible: false, submit: { submitted += 1 }, moveMenu: { moved += $0 },
    chooseMenu: { chosen += 1 }, dismissMenu: { dismissed += 1 })
key(36, "\r")
precondition(submitted == 1)
key(36, "\r", modifiers: .shift)
precondition(submitted == 1, "Shift Return must insert a newline rather than send")
key(36, "\r", modifiers: .command)
precondition(submitted == 2)
input.owner!.parent = AIConversationTextInput(composer: composer, height: .constant(36), enabled: true,
    sendWithReturn: false, menuVisible: false, submit: { submitted += 1 }, moveMenu: { moved += $0 },
    chooseMenu: { chosen += 1 }, dismissMenu: { dismissed += 1 })
key(36, "\r")
precondition(submitted == 2)
composer.focusRequested.send()
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
precondition(window.firstResponder === input)
precondition(input.allowsUndo)
input.string = "Recoverable draft"
input.undoManager?.removeAllActions()
input.insertText("replacement", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
input.breakUndoCoalescing()
guard let undo = input.undoManager else { fatalError("Native composer requires an undo manager") }
precondition(undo.canUndo)
undo.undo()
precondition(input.string == "Recoverable draft" && composer.text == "Recoverable draft")
undo.redo()
precondition(input.string == "replacement" && composer.text == "replacement")
var escaped = false
input.owner!.parent = AIConversationTextInput(composer: composer, height: .constant(36), enabled: true,
    sendWithReturn: true, menuVisible: false, submit: {}, moveMenu: { _ in }, chooseMenu: {}, dismissMenu: {}, escape: { escaped = true })
key(53, "\u{1b}")
precondition(escaped, "Compact host receives Escape after the shared menu has dismissed")
var compactCopy = 0
var compactFormatted = 0
input.owner!.parent = AIConversationTextInput(composer: composer, height: .constant(36), enabled: true,
    sendWithReturn: true, menuVisible: false, submit: { submitted += 1 }, moveMenu: { _ in }, chooseMenu: {}, dismissMenu: {},
    commandReturn: { compactCopy += 1 }, optionReturn: { compactFormatted += 1 })
let submittedBeforeAlternates = submitted
key(36, "\r", modifiers: .command)
key(36, "\r", modifiers: .option)
precondition(compactCopy == 1 && compactFormatted == 1 && submitted == submittedBeforeAlternates,
             "Quick AI alternate Return actions must not send another request")
composer.clear()
RunLoop.current.run(until: Date().addingTimeInterval(0.15))
precondition(input.string.isEmpty && !undo.canUndo, "A new draft must not undo into a sent/deleted conversation")
precondition(input.showsPlaceholder, "Clearing the draft must restore the native placeholder")
window.close()
print("PASS native chat input: caret and IME composition, menu arrows/Return/Esc, send preference, Shift Return, Command Return and focus routing")
