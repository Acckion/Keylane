import SwiftUI
import AppKit

/// Native macOS search field, with the system search and clear controls.
struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "搜索设置…"
    var floating = false
    var submit: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.controlSize = .large
        field.isBezeled = !floating
        field.drawsBackground = !floating
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.maximumRecents = 0
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search)
        field.setAccessibilityLabel(placeholder)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        // Never replace the field editor while an input method is composing.
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField
        init(_ parent: SettingsSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }
        @objc func search(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode == 36 { parent.submit() }
        }
    }
}
