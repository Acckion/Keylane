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
                SettingsSectionTitle(title: "命令")
                CommandSettingsList(items: QuicklinksModule.Command.allCases, id: \.rawValue) { command in
                    CommandSettingsEntry(title: command.title, model: model, commandID: command.id,
                                         isEnabled: Binding(get: { !model.disabledCommands.contains(command.rawValue) }, set: {
                        if $0 { model.disabledCommands.remove(command.rawValue) }
                        else { model.disabledCommands.insert(command.rawValue) }
                    })) {
                        SettingsIcon(symbol: command.symbol)
                    }
                }
                SettingsSectionTitle(title: "快捷链接")
                SettingsGroup {
                    HStack {
                        SettingsSearchField(text: $filter, placeholder: "查找快捷链接…")
                        if let legacy = controller.legacyTemplate,
                           !controller.links.contains(where: { $0.template == legacy }) {
                            Button("恢复旧链接…") {
                                controller.settingsDraft = Quicklink(title: "原快捷链接", template: legacy)
                            }.buttonStyle(.bordered)
                        }
                        SettingsIconButton("添加快捷链接", symbol: "plus") {
                            controller.settingsDraft = Quicklink(title: "", template: "")
                        }
                    }.padding(.vertical, 6)
                }
                CommandSettingsList(items: filtered, id: \.id, emptyMessage: "没有匹配的快捷链接") { link in
                    link.commandSettingsEntry(model: model, perform: { controller.settingsDraft = link }, menu: [
                        .init(title: "编辑快捷链接") { controller.settingsDraft = link },
                        .init(title: "复制为新链接") { controller.settingsDraft = link.duplicate() },
                        .init(title: link.pinned ? "取消置顶" : "置顶链接") {
                            controller.updateOrganization(id: link.id) { $0.pinned.toggle() }
                        },
                        .init(title: link.hiddenFromRoot ? "在主搜索显示" : "从主搜索隐藏") {
                            controller.updateOrganization(id: link.id) { $0.hiddenFromRoot.toggle() }
                        },
                        .init(title: "删除快捷链接…") { pendingRemoval = link }
                    ])
                }
            }
        }
        .settingsAnchor(.quicklink)
        .sheet(item: $controller.settingsDraft) { link in
            QuicklinkEditor(link: link.preparedForEditing(), save: controller.save)
        }
        .confirmationDialog("删除快捷链接？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { link in
            Button("删除", role: .destructive) {
                do {
                    try QuicklinksModule.remove(link, model: model)
                } catch { failure = error.localizedDescription }
            }
        } message: { link in Text(link.title) }
        .alert("无法删除快捷链接", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) { Button("关闭", role: .cancel) {} } message: { Text(failure ?? "") }
    }

    private var filtered: [Quicklink] {
        controller.library.search(filter, aliases: model.aliases)
    }
}

private struct QuicklinkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link: Quicklink
    @State private var tags: String
    let save: (Quicklink) throws -> Void
    @State private var error: String?

    init(link: Quicklink, save: @escaping (Quicklink) throws -> Void) {
        _link = State(initialValue: link)
        _tags = State(initialValue: link.tags.joined(separator: ", "))
        self.save = save
    }

    var body: some View {
        Form {
            TextField("名称", text: $link.title)
            TextField("链接", text: $link.template, prompt: Text("https://example.com/?q={关键词}"))
            Text("可输入网页、邮件、本地绝对路径或 file:// 链接。网页链接可使用 {名称} 或 {名称=默认值}。")
                .font(.caption).foregroundStyle(.secondary)
            if link.usesDynamicPlaceholders == true {
                Link("动态占位符指南", destination: URL(string: "https://manual.raycast.com/dynamic-placeholders")!)
                    .font(.caption)
            }
            TextField("标签（用逗号分隔）", text: $tags)
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
        guard !SearchField.isComposing else { return }
        link.applyTagField(tags)
        do { try save(link); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
