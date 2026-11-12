import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum SnippetsModule {
    private static let listID = PageID(rawValue: "Snippets")
    private static let editID = PageID(rawValue: "EditSnippet")
    private static let settingsID = "snippets"
    private static let symbol = "text.badge.plus"

    static func create(from text: String, model: Model) {
        guard model.launcherModules?.page(editID) != nil else { return }
        model.snippets.edit(Snippet(text: text))
        model.openPage(editID, origin: .menu)
    }

    static func make(model: Model) -> LauncherModule {
        let snippets = model.snippets
        let expansionPermission = PermissionFeature("snippets.expandsKeywords", authorization: .accessibility, observeImmediately: false)
        var expansionChanges: AnyCancellable?
        let create: (LauncherCommandOrigin) -> Void = { [weak model] origin in
            snippets.edit()
            model?.openPage(editID, origin: origin)
        }
        let save: () -> Void = { [weak model] in
            if snippets.save() { model?.pageID = listID }
        }
        let useSelected = {
            if let snippet = snippets.selected { snippets.use(snippet, paste: true) }
        }
        let list = LauncherPage(
            id: listID, placeholder: "搜索文字片段…", badge: ("文字片段", symbol),
            contentPlacement: .underChrome,
            content: { AnyView(SnippetsList(controller: snippets)) },
            queryChanged: { snippets.query = $0 },
            move: snippets.move, submit: useSelected,
            primaryTitle: {
                (NSApp?.delegate as? Delegate)?.pasteTargetName.map { "粘贴到 \($0)" } ?? "复制片段"
            },
            actions: { [weak model] in
                var actions = [LauncherAction(id: "snippet-create", title: "创建片段", icon: "plus",
                                              perform: { create(.menu) })]
                if let selected = snippets.selected {
                    actions += [
                        .init(id: "snippet-paste", title: "粘贴片段", icon: "clipboard", keys: ["↩"], perform: useSelected),
                        .init(id: "snippet-copy", title: "复制片段", icon: "doc.on.doc",
                              perform: { snippets.use(selected, paste: false) }),
                        .init(id: "snippet-edit", title: "编辑片段", icon: "pencil", perform: {
                            snippets.edit(selected)
                            model?.openPage(editID, origin: .menu)
                        }),
                        .init(id: "snippet-delete", title: "删除片段", icon: "trash", group: 1, destructive: true,
                              perform: { snippets.delete(selected) })
                    ]
                }
                return actions
            },
            updates: Publishers.Merge3(ViewObservation.changes(snippets.$selectedID),
                                       ViewObservation.changes(snippets.$entries),
                                       ViewObservation.changes(snippets.$query)).eraseToAnyPublisher(),
            enter: { _ in snippets.query = ""; return "" }
        )
        let editor = LauncherPage(
            id: editID, placeholder: "", badge: ("编辑文字片段", symbol),
            contentPlacement: .form,
            content: { [weak model] in
                AnyView(SnippetEditor(controller: snippets) { model?.pageID = listID })
            },
            submit: save, shortcutSubmit: save, primaryTitle: { "保存片段" }
        )
        return .init(
            id: .init(rawValue: "keylane.snippets"),
            commands: [
                .init(declaration: .init(id: .init(rawValue: "search-snippets"), title: "搜索文字片段",
                                         detail: "查找并粘贴常用文字", symbol: symbol,
                                         keywords: ["Search Snippets", "Snippet", "片段", "常用短语"],
                                         destination: .page(listID), settingsPage: settingsID)),
                .init(declaration: .init(id: .init(rawValue: "create-snippet"), title: "创建文字片段",
                                         detail: "保存可重复使用的文字", symbol: "plus.square",
                                         keywords: ["Create Snippet", "新建片段"], destination: .action, settingsPage: settingsID),
                      execute: create)
            ],
            pages: [list, editor],
            settings: [
                .init(id: settingsID, title: "文字片段", symbol: symbol, subtitle: "管理常用文字与缩写展开。",
                      order: 85, items: [.snippetExpansion], content: { [weak model] in
                          guard let model else { return AnyView(EmptyView()) }
                          return AnyView(SnippetPreferences(model: model, expansionPermission: expansionPermission))
                      })
            ],
            services: [.init(start: {
                expansionPermission.startObserving()
                snippets.expandsKeywords = expansionPermission.available
                snippets.start()
                expansionChanges = expansionPermission.updates.receive(on: DispatchQueue.main).sink {
                    snippets.expandsKeywords = expansionPermission.available
                }
            }, stop: {
                expansionChanges?.cancel()
                expansionChanges = nil
                expansionPermission.stopObserving()
                snippets.stop()
            })],
            applicationFocused: { _ in snippets.applicationFocused() }
        )
    }
}

private struct SnippetsList: View {
    @ObservedObject var controller: SnippetsController

    var body: some View {
        let snippets = controller.visible
        let selection = controller.selected?.id
        ResultDetailLayout {
            SelectableResultList(selection: selection, query: controller.query, firstResult: snippets.first?.id) {
                if snippets.isEmpty {
                    ContentUnavailableView("没有匹配的文字片段", systemImage: "text.badge.plus",
                                           description: Text("可在操作菜单中创建片段。"))
                        .frame(maxWidth: .infinity)
                }
                ForEach(snippets) { snippet in
                    ResultListButton(id: snippet.id, action: { controller.selectedID = snippet.id }) {
                        ResultListRow(selected: selection == snippet.id) {
                            Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                        } content: {
                            HStack {
                                HighlightedResultText(text: snippet.title, query: controller.query)
                                    .font(VisualStyle.rowText).lineLimit(1)
                                Spacer()
                                if !snippet.keyword.isEmpty { Text(snippet.keyword).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
        } detail: {
            if let snippet = controller.selected {
                ResultDetailPane { _ in
                    Text(snippet.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } information: {
                    DetailInformationSection(rows: [
                        .init(title: "标题", value: snippet.title),
                        .init(title: "缩写", value: snippet.keyword.isEmpty ? "未设置" : snippet.keyword)
                    ])
                    if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.red) }
                }
            } else if !controller.error.isEmpty {
                Text(controller.error).foregroundStyle(.red).padding()
            }
        }
    }
}

private struct SnippetEditor: View {
    @ObservedObject var controller: SnippetsController
    let back: () -> Void
    @FocusState private var focus: String?

    var body: some View {
        LauncherCreationForm(back: back) { EmptyView() } fields: {
            field("标题", "例如：常用回复", $controller.draft.title)
            field("缩写", "例如：;thanks", $controller.draft.keyword)
            LauncherCreationField("内容", detail: "可用 {date}、{time} 和 {cursor}。{cursor} 用于缩写展开时定位光标。") {
                LauncherCreationControl(focused: focus == "内容") {
                    TextEditor(text: $controller.draft.text)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 95)
                        .focused($focus, equals: "内容")
                }
            }
            if !controller.error.isEmpty {
                LauncherCreationField("") { Text(controller.error).foregroundStyle(.red) }
            }
        }
        .task { focus = "标题" }
        .onExitCommand(perform: back)
    }

    private func field(_ title: String, _ prompt: String, _ text: Binding<String>) -> some View {
        LauncherCreationField(title) {
            LauncherCreationControl(focused: focus == title) {
                TextField(prompt, text: text).textFieldStyle(.plain).focused($focus, equals: title)
            }
        }
    }
}

private struct SnippetPreferences: View {
    let model: Model
    @ObservedObject private var controller: SnippetsController
    let expansionPermission: PermissionFeature

    init(model: Model, expansionPermission: PermissionFeature) {
        self.model = model
        self.expansionPermission = expansionPermission
        controller = model.snippets
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPermissionToggle(contribution: expansionPermission.titlebar("展开缩写"),
                                         detail: "输入片段的缩写后按空格。安全输入和非 ASCII 输入源下暂停。")
                    .settingsAnchor(.snippetExpansion)
                if controller.expandsKeywords && !controller.expansionActive {
                    SettingsActionRow(title: "展开尚未启用", detail: "请确认至少有一个缩写，并检查辅助功能权限。",
                                      actionTitle: "权限设置…") { model.openSettings(page: "permissions") }
                }
            }
            SettingsGroup {
                SettingsActionRow(title: "文字片段", detail: "\(controller.entries.count) 条",
                                  actionTitle: "搜索片段…") { model.runCommand(.init(rawValue: "search-snippets"), origin: .menu) }
                SettingsActionRow(title: "创建片段", actionTitle: "创建…") { model.runCommand(.init(rawValue: "create-snippet"), origin: .menu) }
            }
        }
    }
}
