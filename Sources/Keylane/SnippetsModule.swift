import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum SnippetsModule {
    private static let listID = PageID(rawValue: "Snippets")
    private static let editID = PageID(rawValue: "EditSnippet")
    private static let settingsID = "snippets"
    static let searchSettingsID = SettingsItem.snippetSearchCommand.page
    static let guideURL = URL(string: "https://manual.raycast.com/snippets")!
    private static let symbol = "text.badge.plus"

    private static let argumentsID = PageID(rawValue: "SnippetArguments")

    enum Command: String, CaseIterable {
        case create = "create-snippet"
        case export = "export-snippets"
        case `import` = "import-snippets"
        case search = "search-snippets"

        var id: CommandID { .init(rawValue: rawValue) }
        var title: String {
            switch self {
            case .create: "创建文字片段"
            case .export: "导出文字片段"
            case .import: "导入文字片段"
            case .search: "搜索文字片段"
            }
        }
        var symbol: String {
            switch self {
            case .create: "plus.square"
            case .export: "square.and.arrow.up"
            case .import: "square.and.arrow.down"
            case .search: SnippetsModule.symbol
            }
        }
        var keywords: [String] {
            switch self {
            case .create: ["Create Snippet", "新建片段"]
            case .export: ["Export Snippets", "导出片段"]
            case .import: ["Import Snippets", "导入片段"]
            case .search: ["Search Snippets", "Snippet", "片段", "常用短语"]
            }
        }
    }

    static let createCommandID = Command.create.id

    static func make(model: Model) -> LauncherModule {
        let snippets = model.snippets
        snippets.clipboard = model.clipboard
        let expansionPermission = PermissionFeature("snippets.expandsKeywords", authorization: .accessibility, observeImmediately: false)
        var expansionChanges: AnyCancellable?
        let save: () -> Void = { [weak model] in
            if snippets.save() { model?.pageID = listID }
        }
        let create: () -> Void = { [weak model] in
            model?.runCommand(createCommandID, origin: .menu)
        }
        let useSelected = {
            if let snippet = snippets.selected { snippets.use(snippet, paste: snippets.options.primary == .paste) }
        }
        let list = LauncherPage(
            id: listID, placeholder: "搜索文字片段…", badge: ("文字片段", symbol),
            contentPlacement: .underChrome,
            content: { AnyView(SnippetsList(controller: snippets, create: create)) },
            queryChanged: { snippets.query = $0 },
            move: snippets.move,
            submit: { if snippets.entries.isEmpty { create() } else { useSelected() } },
            shortcutSubmit: {
                if let snippet = snippets.selected { snippets.use(snippet, paste: snippets.options.primary == .copy) }
            },
            primaryTitle: {
                if snippets.entries.isEmpty { return "创建文字片段" }
                if snippets.options.primary == .paste, let name = (NSApp.delegate as? Delegate)?.pasteTargetName {
                    return "粘贴到 \(name)"
                }
                return "复制片段"
            },
            primaryEnabled: { snippets.entries.isEmpty || snippets.selected != nil },
            actions: { [weak model] in
                var actions = [LauncherAction(id: "snippet-create", title: "创建片段", icon: "plus",
                                              perform: create)]
                if let selected = snippets.selected {
                    actions += [
                        .init(id: "snippet-paste", title: "粘贴片段", icon: "clipboard",
                              keys: snippets.options.primary == .paste ? ["↩"] : ["⌘", "↩"],
                              perform: { snippets.use(selected, paste: true) }),
                        .init(id: "snippet-copy", title: "复制片段", icon: "doc.on.doc",
                              keys: snippets.options.primary == .copy ? ["↩"] : ["⌘", "↩"],
                              perform: { snippets.use(selected, paste: false) }),
                        .init(id: "snippet-edit", title: "编辑片段", icon: "pencil", perform: {
                            snippets.edit(selected)
                            model?.openPage(editID, origin: .menu)
                        }),
                        .init(id: "snippet-duplicate", title: "复制为新片段", icon: "plus.square.on.square", perform: {
                            snippets.duplicate(selected)
                            model?.openPage(editID, origin: .menu)
                        }),
                        .init(id: "snippet-pin", title: selected.pinned ? "取消置顶" : "置顶片段",
                              icon: selected.pinned ? "pin.slash" : "pin", perform: { snippets.togglePin(selected) }),
                        .init(id: "snippet-delete", title: "删除片段", icon: "trash", group: 1, destructive: true,
                              perform: { snippets.delete(selected) })
                    ]
                }
                return actions
            },
            updates: Publishers.MergeMany(ViewObservation.changes(snippets.$selectedID),
                                          ViewObservation.changes(snippets.$entries),
                                          ViewObservation.changes(snippets.$query),
                                          ViewObservation.changes(snippets.$options)).eraseToAnyPublisher(),
            enter: { _ in snippets.tag = ""; snippets.query = ""; return "" },
            typeFilterWidth: 124,
            typeFilter: { open in
                AnyView(SnippetTagFilter(controller: snippets, open: open))
            }
        )
        let editor = LauncherPage(
            id: editID, placeholder: "", badge: ("创建文字片段", symbol),
            contentPlacement: .form,
            content: { [weak model] in
                AnyView(SnippetEditor(controller: snippets) { model?.pageID = listID })
            },
            submit: save, shortcutSubmit: save, primaryTitle: { "保存片段" },
            badgeTitle: { snippets.entries.contains { $0.id == snippets.draft.id } ? "编辑文字片段" : "创建文字片段" }
        )
        let submitArguments: () -> Void = { [weak model] in
            let isAutomatic = snippets.input?.trigger != nil
            if snippets.submitInput() { model?.pageID = isAutomatic ? .root : listID }
        }
        let argumentsPage = LauncherPage(
            id: argumentsID, placeholder: "", badge: ("文字片段", symbol), contentPlacement: .form,
            content: { [weak model] in
                AnyView(SnippetArgumentsPage(controller: snippets, back: {
                    if snippets.input?.trigger != nil {
                        model?.pageID = .root
                        (NSApp.delegate as? Delegate)?.hideLauncher()
                    } else { model?.pageID = listID }
                }, submit: submitArguments))
            },
            leave: snippets.clearInput,
            submit: submitArguments, shortcutSubmit: submitArguments,
            primaryTitle: { snippets.input?.paste == true ? "插入片段" : "复制片段" }
        )
        let commands: [LauncherModule.Command] = Command.allCases.map { command in
            let destination: LauncherCommandDeclaration.Destination
            switch command {
            case .create: destination = .page(editID)
            case .search: destination = .page(listID)
            case .export, .import: destination = .action
            }
            return .init(declaration: .init(id: command.id, title: command.title, detail: "文字片段",
                                            symbol: command.symbol, keywords: command.keywords,
                                            destination: destination, settingsPage: settingsID),
                         execute: { _ in
                switch command {
                case .export: snippets.exportSnippets()
                case .import: snippets.importSnippets()
                case .create, .search: break
                }
            }, arguments: command == .create ? .init(count: 0...1) { _, arguments in
                snippets.edit(arguments.first.map { Snippet(text: $0) })
            } : nil)
        }
        return .init(
            id: .init(rawValue: "keylane.snippets"),
            commands: commands,
            pages: [list, editor, argumentsPage],
            settings: [
                .init(id: settingsID, title: "文字片段", symbol: symbol, subtitle: "管理常用文字与缩写展开。",
                      order: 85, items: [.snippetExpansion], guideURL: guideURL, content: { [weak model] in
                          guard let model else { return AnyView(EmptyView()) }
                          return AnyView(SnippetPreferences(model: model, controller: snippets, expansionPermission: expansionPermission))
                      }),
                .init(id: searchSettingsID, title: Command.search.title, symbol: symbol, subtitle: "", order: 86,
                      items: [.snippetSearchCommand], parentID: settingsID,
                      content: { AnyView(SnippetSearchPreferences(controller: snippets)) })
            ],
            services: [.init(start: { [weak model] in
                expansionPermission.startObserving()
                snippets.expandsKeywords = expansionPermission.available
                snippets.start { [weak model] in model?.openPage(argumentsID, origin: .menu) }
                expansionChanges = expansionPermission.updates.receive(on: DispatchQueue.main).sink {
                    snippets.expandsKeywords = expansionPermission.available
                }
            }, stop: {
                expansionChanges?.cancel()
                expansionChanges = nil
                expansionPermission.stopObserving()
                snippets.stop()
            })],
            launcherHidden: { [weak model] in
                guard snippets.input?.trigger != nil else { return }
                snippets.clearInput()
                if model?.pageID == argumentsID { model?.pageID = .root }
            },
            applicationFocused: { _ in snippets.applicationFocused() }
        )
    }
}

private struct SnippetsList: View {
    @ObservedObject var controller: SnippetsController
    let create: () -> Void

    var body: some View {
        let snippets = controller.visible
        let selection = controller.selected?.id
        ResultDetailLayout(hasResults: !snippets.isEmpty) {
            SelectableResultList(selection: selection, query: controller.query, firstResult: snippets.first?.id) {
                ForEach(snippets) { snippet in
                    ResultListButton(id: snippet.id, action: { controller.selectedID = snippet.id }) {
                        ResultListRow(selected: selection == snippet.id) {
                            SettingsIcon(symbol: snippet.icon ?? "text.alignleft",
                                         artwork: snippet.icon == nil ? ModuleArtwork.settings("snippets") : nil)
                        } content: {
                            HStack {
                                HighlightedResultText(text: snippet.title, query: controller.query)
                                    .font(VisualStyle.rowText).lineLimit(1)
                                Spacer()
                                if snippet.pinned { Image(systemName: "pin").font(.caption).foregroundStyle(.secondary) }
                                if !snippet.keyword.isEmpty { Text(snippet.keyword).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
        } detail: {
            if let snippet = controller.selected {
                ResultDetailPane { _ in
                    Group {
                        if let richText = SnippetPasteboard.attributedText(snippet.richText),
                           let formatted = try? AttributedString(richText, including: \.appKit) {
                            Text(formatted)
                        } else { Text(snippet.text) }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                } information: {
                    DetailInformationSection(rows: [
                        .init(title: "标题", value: snippet.title),
                        .init(title: "关键词", value: snippet.keyword.isEmpty ? "未设置" : snippet.keyword),
                        .init(title: "标签", value: snippet.tags.isEmpty ? "无" : snippet.tags.joined(separator: "、"))
                    ])
                    if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.red) }
                }
            }
        } emptyState: {
            let isLibraryEmpty = controller.entries.isEmpty
            ResultDetailEmptyState(
                title: isLibraryEmpty ? "还没有文字片段" : "没有匹配的文字片段",
                message: controller.error.isEmpty
                    ? (isLibraryEmpty ? "保存常用文字，方便随时插入。" : nil)
                    : controller.error,
                action: isLibraryEmpty ? .init(title: "创建文字片段", perform: create) : nil
            )
        }
    }
}

private struct SnippetTagFilter: View {
    @ObservedObject var controller: SnippetsController
    @Binding var open: Bool

    var body: some View {
        ResultTypeFilter(selection: $controller.tag, options: [.init(id: "", title: "全部标签", symbol: "tag")] +
                         controller.tags.map { .init(id: $0, title: $0, symbol: "tag") },
                         open: $open, width: 124, searchPlaceholder: "搜索标签…")
    }
}

private struct SnippetArgumentsPage: View {
    @ObservedObject var controller: SnippetsController
    let back: () -> Void
    let submit: () -> Void

    var body: some View {
        if let input = controller.input {
            DynamicArgumentsForm(title: input.snippet.title, arguments: input.plan.arguments,
                                 values: $controller.values, error: controller.inputError, back: back, submit: submit)
        }
    }
}
