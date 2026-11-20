import AppKit
import ApplicationServices
import Combine
import KeylaneCore
import SwiftUI

enum AITextCommandLauncher {
    static let pageID = PageID(rawValue: "ai-text-command")

    static func commands(model: Model, session: AITextCommandSession) -> [LauncherModule.Command] {
        AITextCommand.allCases.map { command in
            let id = CommandID(rawValue: command.id)
            return LauncherModule.Command(declaration: .init(
                id: id, title: command.title, detail: "预览选中文本，确认后交给模型处理",
                symbol: command.icon, keywords: [command.rawValue, "AI", "选中文字"], destination: .action,
                settingsPage: AIModule.textCommandsItem.page
            ), available: { [weak model] in model?.aiSettings.state.connection(for: .commands) != nil }, execute: { [weak model] origin in
                guard let model else { return }
                session.prepare(command, selection: selectedText()) { [weak model] in
                    model?.launcherModules?.isCommandModuleEnabled(id) == true &&
                        model?.disabledCommands.contains(id.rawValue) == false
                }
                model.openPage(pageID, origin: origin)
            })
        }
    }

    static func customCommands(model: Model, session: AITextCommandSession,
                               library: CustomAICommandLibrary) -> LauncherModule.Provider {
        .init(namespace: .prefix("ai-command:"), entries: { _ in
            library.commands.map {
                Entry(id: $0.commandID, commandID: .init(rawValue: $0.commandID), name: $0.title,
                      detail: "AI 命令", symbol: "sparkles", aliases: ["AI Command", "AI 命令"])
            }
        }, resolve: { [weak model] id, origin in
            guard let model, let command = library.commandsByID[id.rawValue] else { return nil }
            return { [weak model] in
                guard let model else { return }
                let template = DynamicTemplate(command.prompt, usage: .aiCommand)
                var context = model.snippets.templateContext()
                let selection = template.placeholderKinds.contains(.selection) ? selectedText() : nil
                context.selection = { selection }
                session.prepare(command, template: template, context: context) { [weak model] in
                    model?.launcherModules?.isCommandModuleEnabled(id) == true &&
                        model?.disabledCommands.contains(id.rawValue) == false && library.commandsByID[id.rawValue] == command
                }
                model.openPage(pageID, origin: origin)
            }
        }, actions: { [weak model] entry in
            guard let model else { return nil }
            return [LauncherAction(id: "configure-ai-command", title: "打开 AI 命令设置", icon: "gearshape") {
                model.openSettings(page: AIModule.textCommandsItem.page)
            }, model.favoriteAction(for: entry)]
        }, available: { id in
            guard let command = library.commandsByID[id.rawValue] else { return false }
            return AITextCommandSession.connection(for: command, in: session.configuration.state) != nil
        })
    }

    static func selectedText() -> String? {
        let delegate = NSApp.delegate as? Delegate
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let target = frontmost?.processIdentifier == ownPID
            ? delegate?.previousApplication
            : frontmost
        guard let target, let element = SnippetTextTarget.focused(in: target) else { return nil }
        return SnippetTextTarget.attribute(kAXSelectedTextAttribute, of: element) as? String
    }

    static func page(model: Model, session: AITextCommandSession, library: CustomAICommandLibrary) -> LauncherPage {
        let send: () -> Void = {
            guard !SearchField.isComposing else { return }
            session.send()
        }
        let invocationUpdates = Publishers.Merge(
            ViewObservation.changes(model.$disabledCommands),
            ViewObservation.changes(library.$commands)
        ).eraseToAnyPublisher()
        let updates = Publishers.MergeMany([
            invocationUpdates,
            ViewObservation.changes(session.configuration.$state),
            ViewObservation.changes(session.$invocationID),
            session.$input.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            session.$command.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            session.reply.$running.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            session.reply.$turns.map { $0.last?.answer.isEmpty == false }
                .removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ]).eraseToAnyPublisher()
        return LauncherPage(id: pageID, placeholder: "", badge: ("AI 命令", "sparkles"),
                            contentPlacement: .form, content: { [weak model] in
                                AnyView(AITextCommandForm(session: session, configuration: session.configuration,
                                                          invocationUpdates: invocationUpdates,
                                                          back: { model?.goBackInLauncher() }))
                            }, leave: session.clear, submit: send, returnBindings: .init(primary: .command),
                            actionSelectionID: { session.invocationID.uuidString },
                            primaryTitle: { "发送给模型" }, primaryEnabled: { session.canSend },
                            actions: {
                                var actions = [LauncherAction(id: "copy-ai-command-result", title: "复制结果",
                                                               icon: "doc.on.doc", enabled: session.reply.lastAnswer != nil) {
                                    AIConversationHostActions.copyText(session.reply.lastAnswer)
                                }]
                                if session.reply.running {
                                    actions.append(.init(id: "stop-ai-command", title: "停止生成", icon: "stop.fill",
                                                         perform: session.reply.stop))
                                }
                                return actions
                            }, updates: updates, badgeTitle: { session.title })
    }
}

private struct AITextCommandForm: View {
    @ObservedObject var session: AITextCommandSession
    @ObservedObject var configuration: AIConfiguration
    @StateObject private var invocationObservation: ViewObservation
    let back: () -> Void
    @State private var running = false
    @FocusState private var inputFocused: Bool

    init(session: AITextCommandSession, configuration: AIConfiguration,
         invocationUpdates: AnyPublisher<Void, Never>, back: @escaping () -> Void) {
        self.session = session
        self.configuration = configuration
        self.back = back
        _invocationObservation = StateObject(wrappedValue: ViewObservation([invocationUpdates]))
    }

    var body: some View {
        LauncherCreationForm(back: back, spacing: 16) {
            Text(session.title).font(.headline)
        } fields: {
            VStack(alignment: .leading, spacing: 12) {
                if session.customCommand != nil {
                    ForEach(session.arguments) { argument in
                        let value = Binding(get: { session.argumentValues[argument.id] ?? argument.defaultValue ?? "" },
                                            set: { session.setArgument(argument.id, value: $0) })
                        if argument.options.isEmpty {
                            TextField(argument.title, text: value).disabled(running)
                        } else {
                            Picker(argument.title, selection: value) {
                                if argument.defaultValue == nil { Text("请选择").tag("") }
                                ForEach(argument.options, id: \.self) { Text($0).tag($0) }
                            }.disabled(running)
                        }
                    }
                    Text("发送预览").font(.headline)
                    if !session.templateError.isEmpty {
                        Text(session.templateError).foregroundStyle(.secondary)
                    } else {
                        ScrollView { Text(session.input).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(height: 104)
                    }
                } else {
                    Text("待处理文本").font(.headline)
                    TextEditor(text: $session.input)
                        .font(VisualStyle.rowText)
                        .frame(height: 104)
                        .focused($inputFocused)
                        .accessibilityLabel("待处理文本")
                        .disabled(running)
                }
                Text(destinationStatus).font(.caption).foregroundStyle(.secondary)
                if session.customCommand == nil, session.input.isEmpty {
                    Text("无法读取选区时，可在此手动输入。").font(.caption).foregroundStyle(.secondary)
                }
                AITextCommandResult(reply: session.reply)
            }
            .padding(.horizontal, 26)
        }
        .task { inputFocused = session.input.isEmpty }
        .onReceive(session.reply.$running.removeDuplicates()) { running = $0 }
    }

    private var destinationStatus: String {
        if !session.isInvocationAvailable { return "命令已停用、编辑或移除，请返回后重新打开。" }
        if session.destinationChanged { return "模型连接已变化，请返回并重新打开命令。" }
        return "发送至 \(session.destination)。"
    }
}

private struct AITextCommandResult: View {
    @ObservedObject var reply: AIConversationSession

    var body: some View {
        if reply.running || !reply.status.isEmpty || reply.lastAnswer != nil {
            Divider()
            HStack {
                Text("结果").font(.headline)
                Spacer()
                if reply.running { Button("停止", action: reply.stop) }
                if let answer = reply.lastAnswer {
                    Button("复制") { AIConversationHostActions.copyText(answer) }
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
