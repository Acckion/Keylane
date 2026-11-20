import SwiftUI

/// Conversation typography is shared by both presentations; release notes keep their own defaults.
struct AIConversationMarkdownBody: View {
    let text: String
    var scale: Double = 1

    var body: some View {
        ReleaseNotesBody(notes: text, textScale: scale)
            .font(.system(size: 14 * scale))
    }
}
