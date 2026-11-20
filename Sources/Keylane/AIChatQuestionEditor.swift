import SwiftUI

struct AIChatQuestionEditor: View {
    @ObservedObject var controller: AIConversationSession
    let turn: AIConversationSession.Turn
    let send: (String) -> Bool
    @State private var text: String
    @State private var error = ""
    @Environment(\.dismiss) private var dismiss

    init(controller: AIConversationSession, turn: AIConversationSession.Turn, send: @escaping (String) -> Bool) {
        self.controller = controller
        self.turn = turn
        self.send = send
        _text = State(initialValue: turn.question)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑问题").font(.headline)
            Text("发送后创建新分支，原对话、上下文与后续消息会保留。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).frame(minHeight: 140)
                .padding(8).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("编辑问题")
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建分支并发送") {
                    if send(text) { dismiss() }
                    else { error = "无法发送，请检查模型可用性与内容长度。" }
                }.keyboardShortcut(.defaultAction)
                    .disabled(!controller.canRevise || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              AIConversationAttachment.requestText(question: text, attachments: turn.attachments ?? []).utf8.count > 32_000)
            }
        }.padding(24).frame(width: 520)
    }
}
