import SwiftUI

/// One action strip for every chat response, including interrupted responses.
struct AIChatMessageActions: View {
    let turn: QuickAIController.Turn
    let enabled: Bool
    let edit: () -> Void
    let retry: () -> Void
    let branch: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            action("复制回复", symbol: "doc.on.doc", enabled: !turn.answer.isEmpty) {
                AIConversationTranscript.copy(turn.answer)
            }
            action("编辑问题并创建分支", symbol: "pencil", enabled: enabled, perform: edit)
            action("重新生成并创建分支", symbol: "arrow.clockwise", enabled: enabled, perform: retry)
            action("从这里创建分支", symbol: "arrow.triangle.branch", enabled: enabled && turn.complete, perform: branch)
            Spacer(minLength: 0)
        }
    }

    private func action(_ title: String, symbol: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 28, height: 26)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!enabled)
        .help(title).accessibilityLabel(title)
    }
}
