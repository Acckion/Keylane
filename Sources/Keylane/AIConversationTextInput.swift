import AppKit
import Combine
import SwiftUI

/// One native input owns caret-aware completion, IME and send/newline behavior.
struct AIConversationTextInput: NSViewRepresentable {
    @ObservedObject var composer: AIConversationComposer
    @Binding var height: CGFloat
    let enabled: Bool
    let sendWithReturn: Bool
    let menuVisible: Bool
    let submit: () -> Void
    let moveMenu: (Int) -> Void
    let chooseMenu: () -> Void
    let dismissMenu: () -> Void
    var escape: (() -> Void)? = nil
    var commandReturn: (() -> Void)? = nil
    var optionReturn: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let input = Input(frame: NSRect(x: 0, y: 0, width: 400, height: 36))
        input.isRichText = false
        input.allowsUndo = true
        input.drawsBackground = false
        input.font = .systemFont(ofSize: 14)
        input.textColor = .labelColor
        input.insertionPointColor = .labelColor
        input.textContainerInset = NSSize(width: 0, height: 7)
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.widthTracksTextView = true
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.minSize = NSSize(width: 0, height: 36)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.setAccessibilityLabel("聊天输入框")
        input.delegate = context.coordinator
        input.owner = context.coordinator
        scroll.documentView = input
        context.coordinator.input = input
        context.coordinator.focus = composer.focusRequested.sink { [weak input] in
            DispatchQueue.main.async {
                guard let input, input.isEditable else { return }
                input.window?.makeFirstResponder(input)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = scroll.documentView as? Input else { return }
        input.isEditable = enabled
        if context.coordinator.draftID != composer.draftID {
            context.coordinator.draftID = composer.draftID
            input.undoManager?.removeAllActions()
        }
        let textChanged = input.string != composer.text && !input.hasMarkedText()
        if textChanged {
            input.string = composer.text
            let range = composer.selection
            input.setSelectedRange(NSRange(location: min(range.location, input.string.utf16.count),
                                           length: min(range.length, max(0, input.string.utf16.count - range.location))))
        }
        if textChanged { context.coordinator.resize() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIConversationTextInput
        weak var input: Input?
        var focus: AnyCancellable?
        var draftID: UUID
        init(_ parent: AIConversationTextInput) { self.parent = parent; draftID = parent.composer.draftID }

        func textDidChange(_ notification: Notification) {
            guard let input else { return }
            parent.composer.text = input.string
            updateSelection()
            resize()
        }

        func textViewDidChangeSelection(_ notification: Notification) { updateSelection() }

        private func updateSelection() {
            guard let input else { return }
            let range = input.selectedRange()
            if parent.composer.selection != range { parent.composer.selection = range }
            let token = AIChatCompletionToken.at(input.string, selection: range, composing: input.hasMarkedText())
            if parent.composer.completion != token { parent.composer.completion = token }
        }

        func resize() {
            guard let input, let manager = input.layoutManager, let container = input.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = min(150, max(36, ceil(manager.usedRect(for: container).height) + 14))
            guard abs(parent.height - height) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.height = height }
        }
    }

    final class Input: NSTextView {
        weak var owner: Coordinator?
        override func setFrameSize(_ newSize: NSSize) {
            let widthChanged = abs(frame.width - newSize.width) > 0.5
            super.setFrameSize(newSize)
            if widthChanged { owner?.resize() }
        }
        override func keyDown(with event: NSEvent) {
            guard let owner, !hasMarkedText() else { super.keyDown(with: event); return }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            if owner.parent.menuVisible, modifiers.isEmpty {
                switch event.keyCode {
                case 125: owner.parent.moveMenu(1); return
                case 126: owner.parent.moveMenu(-1); return
                case 36, 76: owner.parent.chooseMenu(); return
                case 53: owner.parent.dismissMenu(); return
                default: break
                }
            }
            if event.keyCode == 53, modifiers.isEmpty, let escape = owner.parent.escape { escape(); return }
            if event.keyCode == 36 || event.keyCode == 76 {
                if modifiers == .command, let action = owner.parent.commandReturn { action(); return }
                if modifiers == .option, let action = owner.parent.optionReturn { action(); return }
                if modifiers == .command || (owner.parent.sendWithReturn && modifiers.isEmpty) {
                    owner.parent.submit(); return
                }
            }
            super.keyDown(with: event)
        }
    }
}
