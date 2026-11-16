import AppKit
import SwiftUI

/// Standard SwiftUI text input owns the field editor and IME lifecycle.
/// Never copy model text into an active NSTextField or select its text on every render.
struct SearchField: View {
    @Binding var text: String
    let placeholder: String
    var focusToken: Int
    var wantsFocus: Bool = true
    var compact = false
    var navigation: String = "arrows"
    let submit: () -> Void
    let move: (Int) -> Void
    let escape: () -> Void
    var back: (() -> Void)? = nil
    var forward: (() -> Void)? = nil
    var navigateWhileTyping = false
    var spaceAtEnd: ((String) -> Bool)? = nil
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: compact ? 14 : 19))
            // The native editor draws the standard-size line one point higher while focused.
            .offset(y: focused && !compact ? 1 : 0)
            .animation(nil, value: focused)
            .focused($focused)
            .accessibilityLabel(placeholder)
            .onSubmit { if !Self.isComposing { submit() } }
            .onKeyPress(keys: [.space]) { press in
                guard let spaceAtEnd, press.modifiers.isEmpty, !Self.isComposing,
                      let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                      editor.string == text, editor.selectedRange() == NSRange(location: text.utf16.count, length: 0)
                else { return .ignored }
                return spaceAtEnd(text) ? .handled : .ignored
            }
            .onKeyPress(keys: [.leftArrow], phases: [.down, .repeat]) { guard (text.isEmpty || (navigateWhileTyping && $0.modifiers == .option)), !Self.isComposing, let back else { return .ignored }; back(); return .handled }
            .onKeyPress(keys: [.rightArrow], phases: [.down, .repeat]) { guard (text.isEmpty || (navigateWhileTyping && $0.modifiers == .option)), !Self.isComposing, let forward else { return .ignored }; forward(); return .handled }
            .onKeyPress(.downArrow) { guard !Self.isComposing else { return .ignored }; move(1); return .handled }
            .onKeyPress(.upArrow) { guard !Self.isComposing else { return .ignored }; move(-1); return .handled }
            .onKeyPress(phases: .down) { press in
                guard !Self.isComposing, press.modifiers == .control else { return .ignored }
                let down = navigation == "vim" ? "j" : navigation == "emacs" ? "n" : ""
                let up = navigation == "vim" ? "k" : navigation == "emacs" ? "p" : ""
                if !down.isEmpty && press.characters == down { move(1); return .handled }
                if !up.isEmpty && press.characters == up { move(-1); return .handled }
                if navigation == "vim" {
                    if press.characters == "h", let back { back(); return .handled }
                    if press.characters == "l", let forward { forward(); return .handled }
                }
                return .ignored
            }
            .onExitCommand { if !Self.isComposing { escape() } }
            .task(id: "\(focusToken):\(wantsFocus)") {
                await Task.yield()
                guard !Task.isCancelled else { return }
                focused = wantsFocus
            }
    }
    static var isComposing: Bool {
        // AppKit can report the owner as NSApp.keyWindow even when a popover
        // is key. The event's window owns the editor handling this keystroke.
        let window = NSApp.currentEvent?.window ?? NSApp.keyWindow
        return (window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }
}
extension Notification.Name {
    static let launcherShown = Notification.Name("Keylane.launcherShown")
    static let launcherHidden = Notification.Name("Keylane.launcherHidden")
    static let launcherResetSearch = Notification.Name("Keylane.launcherResetSearch")
}
