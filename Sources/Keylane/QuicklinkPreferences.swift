import KeylaneCore
import SwiftUI

struct QuicklinkPreferences: View {
    let model: Model
    @ObservedObject var controller: QuicklinksController
    @StateObject private var observation: ViewObservation
    @State private var pendingRemoval: Quicklink?
    @State private var failure: String?
    @State private var filter = ""

    init(model: Model, controller: QuicklinksController) {
        self.model = model
        self.controller = controller
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases), ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            if let error = controller.storageError {
                Text(error).foregroundStyle(.secondary)
            } else {
                SettingsGroup {
                    HStack {
                        SettingsSearchField(text: $filter, placeholder: "查找快捷链接…")
                        if let legacy = QuicklinkLibrary.legacyTemplate(from: .standard),
                           !controller.links.contains(where: { $0.template == legacy }) {
                            Button("恢复旧链接…") {
                                controller.draft = Quicklink(title: "原快捷链接", template: legacy)
                            }.buttonStyle(.bordered)
                        }
                        SettingsIconButton("添加快捷链接", symbol: "plus") {
                            controller.draft = Quicklink(title: "", template: "")
                        }
                    }.padding(.vertical, 6)
                }
                CommandSettingsList(items: filtered, id: \.id, emptyMessage: "没有匹配的快捷链接") { link in
                    link.commandSettingsEntry(model: model, perform: { controller.draft = link }, menu: [
                        .init(title: "编辑快捷链接") { controller.draft = link },
                        .init(title: "删除快捷链接…") { pendingRemoval = link }
                    ])
                }
            }
        }
        .settingsAnchor(.quicklink)
        .sheet(item: $controller.draft) { link in
            QuicklinkEditor(link: link.preparedForEditing(), save: controller.save)
        }
        .confirmationDialog("删除快捷链接？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { link in
            Button("删除", role: .destructive) {
                do {
                    try controller.remove(link)
                    model.setShortcut(link.id, value: nil)
                    if model.favorites.contains(link.id) { model.toggleFavorite(link.id) }
                    model.disabledCommands.remove(link.id)
                    model.setAlias(link.id, value: "")
                    model.resetUsage(for: link.id)
                } catch { failure = error.localizedDescription }
            }
        } message: { link in Text(link.title) }
        .alert("无法删除快捷链接", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) { Button("关闭", role: .cancel) {} } message: { Text(failure ?? "") }
    }

    private var filtered: [Quicklink] {
        guard !filter.isEmpty else { return controller.links }
        return controller.links.filter {
            $0.title.localizedCaseInsensitiveContains(filter) ||
                $0.template.localizedCaseInsensitiveContains(filter) ||
                model.aliases[$0.id]?.localizedCaseInsensitiveContains(filter) == true
        }
    }
}

private struct QuicklinkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var link: Quicklink
    let save: (Quicklink) throws -> Void
    @State private var error: String?

    var body: some View {
        Form {
            TextField("名称", text: $link.title)
            TextField("链接", text: $link.template, prompt: Text("https://example.com/?q={关键词}"))
            Text("使用 {名称} 添加参数，或使用 {名称=默认值} 提供默认值。")
                .font(.caption).foregroundStyle(.secondary)
            if link.usesDynamicPlaceholders == true {
                Link("动态占位符指南", destination: URL(string: "https://manual.raycast.com/dynamic-placeholders")!)
                    .font(.caption)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 490)
    }

    private func submit() {
        link.title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
        link.template = link.template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.title.isEmpty else { error = "请输入名称。"; return }
        do { try save(link); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
