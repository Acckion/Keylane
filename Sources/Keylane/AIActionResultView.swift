import SwiftUI

struct AIActionResultView: View {
    @ObservedObject var session: AIActionSession
    var statusOverride: String? = nil
    var continueAction: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.running { AIResponseProgressView(progress: session.progress) }
            if !session.answer.isEmpty { AIConversationMarkdownBody(text: session.answer).textSelection(.enabled) }
            if !session.running && !session.preparing && !session.answer.isEmpty, let continueAction {
                Button("继续到 Quick AI", action: continueAction).buttonStyle(.glass)
            }
            if !(statusOverride ?? session.status).isEmpty { Text(statusOverride ?? session.status).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

