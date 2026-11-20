import AppKit
import SwiftUI

NSApplication.shared.setActivationPolicy(.prohibited)
func height<V: View>(_ view: V) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: 280, alignment: .leading))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}
for text in ["Ordinary answer text without a heading.", "- First list item\n- Second list item", "# Heading\nOrdinary paragraph\n- List item"] {
    let normal = height(AIConversationMarkdownBody(text: text))
    let enlarged = height(AIConversationMarkdownBody(text: text, scale: 1.6))
    let reduced = height(AIConversationMarkdownBody(text: text, scale: 0.8))
    precondition(normal.isFinite && reduced > 0 && enlarged > normal && normal > reduced,
                 "Paragraph/list/heading typography must follow the shared conversation scale")
}
let inheritedSmall = height(ReleaseNotesBody(notes: "Release notes paragraph").font(.system(size: 12)))
let inheritedLarge = height(ReleaseNotesBody(notes: "Release notes paragraph").font(.system(size: 24)))
precondition(inheritedLarge > inheritedSmall, "Release notes must still inherit the caller's unscaled font")
print("PASS shared conversation typography: rendered paragraphs, lists and headings zoom in/out; release notes retain inherited defaults")
