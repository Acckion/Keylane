import SwiftUI
import KeylaneCore

struct AIActionResultView: View {
    @ObservedObject var session: AIActionSession
    var statusOverride: String? = nil
    var continueAction: (() -> Void)? = nil
    var body: some View {
        AIResultContent(answer: session.answer, status: statusOverride ?? session.status,
                        running: session.running, progress: session.progress,
                        continueAction: session.canUseResult ? continueAction : nil)
    }
}

struct AIResultContent: View {
    let answer: String
    let status: String
    let running: Bool
    let progress: AIResponseProgress
    var continueAction: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if running { AIResponseProgressView(progress: progress) }
            if !answer.isEmpty { AIConversationMarkdownBody(text: answer).textSelection(.enabled) }
            if !running && !answer.isEmpty, let continueAction {
                Button("继续到 Quick AI", action: continueAction).buttonStyle(.glass)
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
