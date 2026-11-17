import AppKit
import ApplicationServices
import Combine
import KeylaneCore
import SwiftUI

enum AITextCommandLauncher {
    static let pageID = PageID(rawValue: "ai-text-command")

    static func commands(model: Model, session: AITextCommandSession) -> [LauncherModule.Command] {
        AITextCommand.allCases.map { command in
            LauncherModule.Command(declaration: .init(
                id: .init(rawValue: command.id), title: command.title, detail: "预览选中文本，确认后交给模型处理",
                symbol: command.icon, keywords: [command.rawValue, "AI", "选中文字"], destination: .action, settingsPage: "ai"
            ), available: { [weak model] in model?.aiSettings.isAvailable == true }, execute: { [weak model] origin in
                guard let model else { return }
                session.prepare(command, selection: selectedText())
                model.openPage(pageID, origin: origin)
            })
        }
    }

    private static func selectedText() -> String? {
        let delegate = NSApp.delegate as? Delegate
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let target = frontmost?.processIdentifier == ownPID
            ? (delegate?.window?.isKeyWindow == true ? delegate?.previousApplication : nil)
            : frontmost
        guard let target, let element = SnippetTextTarget.focused(in: target) else { return nil }
        return SnippetTextTarget.attribute(kAXSelectedTextAttribute, of: element) as? String
    }

    static func page(model: Model, session: AITextCommandSession) -> LauncherPage {
        let send: () -> Void = {
            guard !SearchField.isComposing else { return }
            session.send()
        }
        let updates = Publishers.MergeMany([
            session.$input.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            session.$command.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            session.reply.$running.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            session.reply.$turns.map { $0.last?.answer.isEmpty == false }
                .removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ]).eraseToAnyPublisher()
        return LauncherPage(id: pageID, placeholder: "", badge: ("AI 命令", "sparkles"),
                            contentPlacement: .form, content: { [weak model] in
                                AnyView(AITextCommandForm(session: session, back: { model?.goBackInLauncher() }))
                            }, leave: session.clear, submit: send, returnBindings: .init(primary: .command),
                            primaryTitle: { "发送给模型" }, primaryEnabled: { session.canSend },
                            actions: {
                                var actions = [LauncherAction(id: "copy-ai-command-result", title: "复制结果",
                                                               icon: "doc.on.doc", enabled: session.reply.lastAnswer != nil) {
                                    AIConversationTranscript.copy(session.reply.lastAnswer)
                                }]
                                if session.reply.running {
                                    actions.append(.init(id: "stop-ai-command", title: "停止生成", icon: "stop.fill",
                                                         perform: session.reply.stop))
                                }
                                return actions
                            }, updates: updates, badgeTitle: { session.command.title })
    }
}

private struct AITextCommandForm: View {
    @ObservedObject var session: AITextCommandSession
    let back: () -> Void
    @State private var running = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        LauncherCreationForm(back: back, spacing: 16) {
            Text(session.command.title).font(.headline)
        } fields: {
            VStack(alignment: .leading, spacing: 12) {
                if session.command == .translate {
                    Picker("目标语言", selection: $session.language) {
                        ForEach(AITextCommand.Language.allCases) { language in
                            Text(language.rawValue).tag(language)
                        }
                    }
                    .fixedSize()
                    .disabled(running)
                }
                Text("待处理文本").font(.headline)
                TextEditor(text: $session.input)
                    .font(VisualStyle.rowText)
                    .frame(height: 104)
                    .focused($inputFocused)
                    .accessibilityLabel("待处理文本")
                    .disabled(running)
                Text("发送至 \(session.destination)。无法读取选区时，可在此手动输入。")
                    .font(.caption).foregroundStyle(.secondary)
                AITextCommandResult(reply: session.reply)
            }
            .padding(.horizontal, 26)
        }
        .task { inputFocused = session.input.isEmpty }
        .onReceive(session.reply.$running.removeDuplicates()) { running = $0 }
    }
}

private struct AITextCommandResult: View {
    @ObservedObject var reply: QuickAIController

    var body: some View {
        if reply.running || !reply.status.isEmpty || reply.lastAnswer != nil {
            Divider()
            HStack {
                Text("结果").font(.headline)
                Spacer()
                if reply.running { Button("停止", action: reply.stop) }
                if let answer = reply.lastAnswer {
                    Button("复制") { AIConversationTranscript.copy(answer) }
                }
            }
            if let answer = reply.lastAnswer { Text(answer).textSelection(.enabled) }
            if !reply.status.isEmpty {
                Text(reply.status).font(.caption).foregroundStyle(.secondary)
            } else if reply.running {
                ProgressView().controlSize(.small).accessibilityLabel("正在生成")
            }
        }
    }
}
