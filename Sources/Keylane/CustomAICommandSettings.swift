import AppKit
import KeylaneCore
import SwiftUI
import UniformTypeIdentifiers

struct CustomAICommandSettings: View {
    let model: Model
    @ObservedObject var library: CustomAICommandLibrary
    @ObservedObject var configuration: AIConfiguration
    @State private var editing: CustomAICommand?
    @State private var removing: CustomAICommand?
    @State private var status = ""
    @StateObject private var observation: ViewObservation

    init(model: Model, library: CustomAICommandLibrary, configuration: AIConfiguration) {
        self.model = model
        self.library = library
        self.configuration = configuration
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsRow("自定义 AI 命令", detail: "保存可从启动器和快捷键执行的提示词。") {
                    HStack {
                        Button("导入…", action: importCommands)
                        Button("导出…", action: exportCommands).disabled(library.commands.isEmpty)
                        SettingsIconButton("新建 AI 命令", symbol: "plus") { editing = CustomAICommand() }
                    }.disabled(library.loadError != nil)
                }
                if let message = library.loadError?.localizedDescription ?? (status.isEmpty ? nil : status) {
                    Divider()
                    SettingsRow("状态", detail: message) { EmptyView() }
                }
            }
            if !library.commands.isEmpty {
                CommandSettingsList(items: library.commands, id: \.id, showsColumns: true) { command in
                    command.settingsEntry(model: model, edit: { editing = command }, menu: [
                        .init(title: "复制为新命令…", perform: {
                            var copy = command
                            copy.id = UUID()
                            copy.title += " 副本"
                            editing = copy
                        }),
                        .init(title: "删除…", perform: { removing = command })
                    ])
                }
            }
        }
        .sheet(item: $editing) { draft in
            CustomAICommandEditor(draft: draft, configuration: configuration, save: library.save)
        }
        .confirmationDialog("删除此 AI 命令？", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { command in
            Button("删除", role: .destructive) {
                do {
                    try library.remove(command)
                    model.setShortcut(command.commandID, value: nil)
                    model.setAlias(command.commandID, value: "")
                } catch { status = error.localizedDescription }
            }
        } message: { command in
            Text(command.title)
        }
    }

    private func importCommands() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: CustomAICommandLibrary.maximumArchiveBytes + 1) ?? Data()
            let count = try library.importData(data)
            status = "已导入 \(count) 个 AI 命令。已有命令保留原配置。"
        } catch { status = error.localizedDescription }
    }

    private func exportCommands() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Keylane AI Commands.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.exportData().write(to: url, options: .atomic)
            status = "已导出 \(library.commands.count) 个 AI 命令。"
        } catch { status = error.localizedDescription }
    }
}

extension CustomAICommand {
    func settingsEntry(model: Model, edit: (() -> Void)? = nil,
                       menu: [CommandSettingsAction] = []) -> CommandSettingsEntry<SettingsIcon> {
        CommandSettingsEntry(title: title, model: model, commandID: .init(rawValue: commandID), isEnabled: Binding(
            get: { !model.disabledCommands.contains(commandID) },
            set: { enabled in
                if enabled { model.disabledCommands.remove(commandID) }
                else { model.disabledCommands.insert(commandID) }
            }
        ), perform: edit, menu: menu) { SettingsIcon(symbol: "sparkles") }
    }
}

private struct CustomAICommandEditor: View {
    @State var draft: CustomAICommand
    @ObservedObject var configuration: AIConfiguration
    let save: (CustomAICommand) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsRow("名称") {
                    TextField("命令名称", text: $draft.title).frame(width: 250)
                }
                Divider()
                SettingsPicker("模型连接", selection: $draft.connectionID) {
                    Text("跟随 AI 命令默认模型").tag(nil as UUID?)
                    if let id = draft.connectionID, !configuration.state.connections.contains(where: { $0.id == id && $0.isConfigured }) {
                        Text("连接不可用").tag(Optional(id))
                    }
                    ForEach(configuration.state.connections.filter {
                        $0.isConfigured && ($0.hiddenFromPicker != true || $0.id == draft.connectionID)
                    }) { connection in
                        Text("\(connection.displayName) · \(connection.providerLabel)").tag(Optional(connection.id))
                    }
                }
                Divider()
                SettingsRow("提示词", detail: "可使用 {selection}、{clipboard} 和 {argument name=\"参数名\"}。") {
                    EmptyView()
                }
                TextEditor(text: $draft.prompt)
                    .frame(height: 130)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                    .accessibilityLabel("提示词")
            }
            if !error.isEmpty { SettingsDescription(error) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try save(draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }.frame(width: 500)
    }
}
