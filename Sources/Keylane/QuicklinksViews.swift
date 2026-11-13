import KeylaneCore
import SwiftUI

struct QuicklinksList: View {
    let model: Model
    let create: () -> Void
    @ObservedObject private var controller: QuicklinksController
    @StateObject private var observation: ViewObservation

    init(model: Model, create: @escaping () -> Void) {
        self.model = model
        self.create = create
        _controller = ObservedObject(wrappedValue: model.quicklinks)
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$disabledCommands)
        ]))
    }

    var body: some View {
        let rows = controller.rows(aliases: model.aliases)
        let selected = controller.selected(in: rows)
        ResultDetailLayout(hasResults: !rows.isEmpty) {
            SelectableResultList(selection: selected?.id, query: controller.query, firstResult: rows.first?.id) {
                ForEach(rows) { link in
                    ResultListButton(id: link.id, action: { controller.selectedID = link.id }) {
                        ResultListRow(selected: selected?.id == link.id) {
                            SettingsIcon(symbol: "link", artwork: ModuleArtwork.settings("links"))
                        } content: {
                            HStack(spacing: 8) {
                                HighlightedResultText(text: link.title, query: controller.query)
                                    .font(VisualStyle.rowText).lineLimit(1)
                                Spacer()
                                if link.hiddenFromRoot {
                                    Image(systemName: "eye.slash").help("已从主搜索隐藏")
                                }
                                if link.pinned {
                                    Image(systemName: "pin").help("已置顶")
                                }
                                if model.disabledCommands.contains(link.id) {
                                    Text("已停用").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        } detail: {
            if let link = selected {
                ResultDetailPane { _ in
                    Text(link.template).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                } information: {
                    DetailInformationSection(rows: [
                        .init(title: "名称", value: link.title),
                        .init(title: "标签", value: link.tags.isEmpty ? "无" : link.tags.joined(separator: "、"))
                    ])
                }
                .id(link.id)
            }
        } emptyState: {
            let canCreate = controller.links.isEmpty && controller.storageError == nil
                && !model.disabledCommands.contains(QuicklinksModule.Command.create.rawValue)
            ResultDetailEmptyState(
                title: controller.links.isEmpty ? "暂无快捷链接" : "没有匹配的快捷链接",
                message: controller.storageError,
                action: canCreate ? .init(title: "创建快捷链接", perform: create) : nil
            )
        }
    }
}

struct QuicklinkTagFilter: View {
    @ObservedObject var controller: QuicklinksController
    @Binding var open: Bool
    let navigation: String

    var body: some View {
        ResultTypeFilter(selection: $controller.tag,
                         options: [.init(id: "", title: "全部标签", symbol: "tag")] + controller.library.tags.map {
                             .init(id: Quicklink.tagKey($0), title: $0, symbol: "tag")
                         }, open: $open, navigation: navigation, width: 124, searchPlaceholder: "搜索标签…",
                         emptyTitle: "没有匹配的标签", shortcut: "p")
    }
}

struct QuicklinkLauncherEditor: View {
    private enum Field: Hashable { case title, link, tags }
    @ObservedObject var controller: QuicklinksController
    let guideURL: URL
    let back: () -> Void
    @FocusState private var focused: Field?

    var body: some View {
        LauncherCreationForm(back: back) {
            if controller.draft?.usesDynamicPlaceholders == true {
                Link("动态占位符指南", destination: guideURL).font(.callout)
            }
        } fields: {
            LauncherCreationField("名称") {
                LauncherCreationControl(focused: focused == .title) {
                    TextField("快捷链接名称", text: field(\.title)).textFieldStyle(.plain)
                        .focused($focused, equals: .title).onSubmit { if !SearchField.isComposing { focused = .link } }
                }
            }
            LauncherCreationField("链接", detail: "支持 HTTP、HTTPS 和邮件地址。") {
                LauncherCreationControl(focused: focused == .link) {
                    TextField("https://example.com/?q={关键词}", text: field(\.template)).textFieldStyle(.plain)
                        .focused($focused, equals: .link).onSubmit { if !SearchField.isComposing { focused = .tags } }
                        .autocorrectionDisabled()
                }
            }
            LauncherCreationField("标签", detail: "用逗号分隔多个标签。") {
                LauncherCreationControl(focused: focused == .tags) {
                    TextField("例如 工作, 资料", text: $controller.draftTags).textFieldStyle(.plain)
                        .focused($focused, equals: .tags)
                }
            }
            if let error = controller.draftError { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .task(id: controller.draft?.id) {
            guard controller.draft != nil else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = .title
        }
        .onExitCommand { if !SearchField.isComposing { back() } }
    }

    private func field(_ key: WritableKeyPath<Quicklink, String>) -> Binding<String> {
        Binding(get: { controller.draft?[keyPath: key] ?? "" },
                set: { controller.draft?[keyPath: key] = $0 })
    }
}

struct QuicklinkParameterForm: View {
    @ObservedObject var controller: QuicklinksController
    let back: () -> Void
    let submit: () -> Void

    var body: some View {
        if let link = controller.argumentLink {
            DynamicArgumentsForm(title: link.title, arguments: controller.parameters,
                                 values: $controller.values, error: controller.inputError, back: back, submit: submit)
        }
    }
}
