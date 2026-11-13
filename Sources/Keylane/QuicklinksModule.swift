import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum QuicklinksModule {
    static let listID = PageID(rawValue: "Quicklinks")
    static let editID = PageID(rawValue: "EditQuicklink")
    private static let argumentsID = PageID(rawValue: "QuicklinkParameters")
    private static let guideURL = URL(string: "https://manual.raycast.com/dynamic-placeholders")!

    enum Command: String, CaseIterable {
        case search = "search-quicklinks"
        case create = "create-quicklink"
        case importLinks = "import-quicklinks"
        case exportLinks = "export-quicklinks"

        var id: CommandID { .init(rawValue: rawValue) }
        var title: String {
            switch self {
            case .search: "搜索快捷链接"
            case .create: "创建快捷链接"
            case .importLinks: "导入快捷链接"
            case .exportLinks: "导出快捷链接"
            }
        }
        var symbol: String {
            switch self {
            case .search: "link"
            case .create: "plus.square"
            case .importLinks: "square.and.arrow.down"
            case .exportLinks: "square.and.arrow.up"
            }
        }
        var keywords: [String] {
            switch self {
            case .search: ["Search Quicklinks", "Quick Links", "网址"]
            case .create: ["Create Quicklink", "新建链接"]
            case .importLinks: ["Import Quicklinks"]
            case .exportLinks: ["Export Quicklinks"]
            }
        }
    }

    static func create(from url: URL, title: String, model: Model) {
        guard model.launcherModules?.isModuleEnabled(.init(rawValue: "keylane.links")) == true else { return }
        model.quicklinks.settingsDraft = Quicklink(title: title, template: url.absoluteString)
        model.openSettings(page: "links")
    }

    static func make(model: Model) -> LauncherModule {
        let controller = model.quicklinks
        controller.templateContext = { [weak model] in model?.snippets.templateContext() ?? .init() }
        controller.feedback = { (NSApp.delegate as? Delegate)?.showLauncherFeedback($0, style: $1) }

        var editReturn = PageID.root
        var argumentsReturn = PageID.root
        let startEdit: (Quicklink?) -> Void = { [weak model] link in
            guard let model else { return }
            editReturn = model.pageID == listID ? listID : .root
            controller.edit(link)
            model.openPage(editID, origin: .menu)
        }
        let create: () -> Void = { [weak model] in model?.runCommand(Command.create.id, origin: .menu) }

        func provider(_ namespace: LauncherCommandNamespace) -> LauncherModule.Provider {
            .init(namespace: namespace, entries: { input in
                controller.links.compactMap { link in
                    let id = CommandID(rawValue: link.id)
                    guard namespace.contains(id), input.page != .root || !link.hiddenFromRoot else { return nil }
                    return Entry(id: link.id, commandID: id, name: link.title, detail: "快捷链接", symbol: "link",
                                 aliases: ["Quicklink", "快捷链接", link.template] + link.tags)
                }
            }, resolve: { [weak model] id, origin in
                guard let link = controller.links.first(where: { $0.id == id.rawValue }) else { return nil }
                return { [weak model] in
                    guard let model else { return }
                    argumentsReturn = model.pageID == listID ? listID : .root
                    if controller.launch(link, presentParameters: { model.openPage(argumentsID, origin: origin) }) {
                        (NSApp.delegate as? Delegate)?.hideLauncher()
                    }
                }
            }, primaryTitle: { _ in "打开链接" }, actions: { [weak model] entry in
                guard let model, let link = controller.links.first(where: { $0.id == entry.commandID.rawValue }) else { return nil }
                return actions(for: link, model: model, edit: startEdit) + [model.favoriteAction(for: entry)]
            })
        }

        let list = LauncherPage(
            id: listID, placeholder: "搜索快捷链接…", badge: ("快捷链接", "link"),
            contentPlacement: .underChrome,
            content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(QuicklinksList(model: model, create: create))
            },
            queryChanged: { controller.query = $0 },
            move: { [weak model] delta in
                if let model { controller.move(delta, aliases: model.aliases) }
            },
            submit: { [weak model] in
                guard let model else { return }
                if controller.links.isEmpty, controller.storageError == nil { create(); return }
                if let link = controller.selected(in: controller.rows(aliases: model.aliases)) { open(link, model: model) }
            },
            actionContextTitle: { [weak model] in
                model.flatMap { controller.selected(in: controller.rows(aliases: $0.aliases))?.title }
            },
            primaryTitle: { controller.links.isEmpty ? "创建快捷链接" : "打开链接" },
            primaryEnabled: { [weak model] in
                guard let model, controller.storageError == nil else { return false }
                if controller.links.isEmpty { return !model.disabledCommands.contains(Command.create.rawValue) }
                guard let link = controller.selected(in: controller.rows(aliases: model.aliases)) else { return false }
                return !model.disabledCommands.contains(link.id)
            },
            actions: { [weak model] in
                guard let model else { return [] }
                let selection = controller.selected(in: controller.rows(aliases: model.aliases))
                return (selection.map { actions(for: $0, model: model, edit: startEdit) } ?? []) + [
                    .init(id: "quicklink-create", title: "创建快捷链接", icon: "plus", keys: ["⌘", "N"],
                          enabled: controller.storageError == nil && !model.disabledCommands.contains(Command.create.rawValue),
                          perform: create)
                ]
            },
            updates: Publishers.MergeMany([
                ViewObservation.changes(controller.$links), ViewObservation.changes(controller.$selectedID),
                ViewObservation.changes(controller.$query), ViewObservation.changes(controller.$tag),
                ViewObservation.changes(controller.$storageError),
                ViewObservation.changes(model.$aliases), ViewObservation.changes(model.$disabledCommands)
            ]).eraseToAnyPublisher(),
            enter: { _ in controller.query },
            typeFilterWidth: 124,
            typeFilter: { [weak model] open in
                AnyView(QuicklinkTagFilter(controller: controller, open: open, navigation: model?.navigation ?? "arrows"))
            },
            actionShortcutsEnabled: true
        )

        let save: () -> Void = { [weak model] in
            guard let model, model.pageID == editID, !SearchField.isComposing, let id = controller.saveDraft() else { return }
            if editReturn == listID {
                controller.query = ""
                controller.tag = ""
                controller.selectedID = id
            }
            model.pageID = editReturn
            controller.feedback("已保存快捷链接", .success)
        }
        let editPage = LauncherPage(
            id: editID, placeholder: "", badge: ("创建快捷链接", "link"), contentPlacement: .form,
            content: { [weak model] in
                AnyView(QuicklinkLauncherEditor(controller: controller, guideURL: guideURL, back: { model?.pageID = editReturn }))
            },
            leave: controller.clearDraft,
            submit: save, shortcutSubmit: save, primaryTitle: { "保存快捷链接" },
            badgeTitle: {
                controller.links.contains { $0.id == controller.draft?.id } ? "编辑快捷链接" : "创建快捷链接"
            }
        )

        let submit: () -> Void = { [weak model] in
            guard let model, model.pageID == argumentsID, !SearchField.isComposing else { return }
            if controller.submit() {
                model.pageID = argumentsReturn
                (NSApp.delegate as? Delegate)?.hideLauncher()
            }
        }
        let arguments = LauncherPage(
            id: argumentsID, placeholder: "", badge: ("快捷链接", "link"), contentPlacement: .form,
            content: { [weak model] in
                AnyView(QuicklinkParameterForm(controller: controller, back: { model?.pageID = argumentsReturn }, submit: submit))
            },
            leave: { [weak model] in
                controller.clearInput()
                if model?.pageID == argumentsID { model?.pageID = argumentsReturn }
            },
            submit: submit, shortcutSubmit: submit, primaryTitle: { "打开链接" }
        )

        let commands: [LauncherModule.Command] = Command.allCases.map { command in
            let destination: LauncherCommandDeclaration.Destination
            switch command {
            case .search: destination = .page(listID)
            case .create: destination = .page(editID)
            case .importLinks, .exportLinks: destination = .action
            }
            return .init(declaration: .init(id: command.id, title: command.title, detail: "快捷链接",
                                            symbol: command.symbol, keywords: command.keywords,
                                            destination: destination, settingsPage: "links"),
                         execute: { [weak model] _ in
                switch command {
                case .create:
                    editReturn = model?.pageID == listID ? listID : .root
                    controller.edit()
                case .importLinks: controller.importLinks()
                case .exportLinks: controller.exportLinks()
                case .search: break
                }
            })
        }
        let manage = LauncherModule.Command(declaration: .init(id: .init(rawValue: "manage-quicklinks"),
            title: "管理快捷链接", detail: "快捷链接设置", symbol: "link", keywords: ["Manage Quicklinks"],
            destination: .settings("links"), settingsPage: "links"))
        let settings = LauncherSettingsPage(id: "links", title: "快捷链接", symbol: "link",
                                            subtitle: "管理常用链接、标签、别名和快捷键。", order: 90,
                                            items: [.quicklink], content: { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(QuicklinkPreferences(model: model, controller: controller))
        })
        return .init(id: .init(rawValue: "keylane.links"), title: "快捷链接", symbol: "link", commands: commands + [manage],
           providers: [provider(.exact(.init(rawValue: QuicklinkLibrary.legacyID))), provider(.prefix("quicklink:"))],
           pages: [list, editPage, arguments], settings: [settings], services: [.init(start: controller.load, stop: controller.stop)],
           searchUpdates: [ViewObservation.changes(controller.$links)],
           dynamicCommandSettings: .init(
               model: model, items: { controller.links }, title: \.title, commandID: \.id,
               updates: { [ViewObservation.changes(controller.$links)] },
               entry: { $0.commandSettingsEntry(model: $1) }
           ))
    }

    private static func open(_ link: Quicklink, model: Model) {
        model.runCommand(.init(rawValue: link.id), origin: .search, usageKey: link.id)
    }

    private static func actions(for link: Quicklink, model: Model, edit: @escaping (Quicklink?) -> Void) -> [LauncherAction] {
        let controller = model.quicklinks
        return [
            .init(id: "quicklink-open", title: "打开链接", icon: "arrow.up.right", keys: ["↩"],
                  enabled: !model.disabledCommands.contains(link.id)) { [weak model] in
                if let model { open(link, model: model) }
            },
            .init(id: "quicklink-edit", title: "编辑快捷链接", icon: "pencil",
                  keys: model.pageID == listID ? ["⌘", "E"] : []) { edit(link) },
            .init(id: "quicklink-duplicate", title: "复制为新链接", icon: "plus.square.on.square") { edit(link.duplicate()) },
            .init(id: "quicklink-copy-name", title: "复制名称", icon: "doc.on.doc") {
                UtilityActions.copy(link.title, feedback: "已复制名称")
            },
            .init(id: "quicklink-copy-template", title: "复制链接", icon: "link") {
                UtilityActions.copy(link.template, feedback: "已复制链接")
            },
            .init(id: "quicklink-pin", title: link.pinned ? "取消置顶" : "置顶链接",
                  icon: link.pinned ? "pin.slash" : "pin") { controller.updateOrganization(id: link.id) { $0.pinned.toggle() } },
            .init(id: "quicklink-visibility", title: link.hiddenFromRoot ? "在主搜索显示" : "从主搜索隐藏",
                  icon: link.hiddenFromRoot ? "eye" : "eye.slash") {
                controller.updateOrganization(id: link.id) { $0.hiddenFromRoot.toggle() }
            },
            .init(id: "quicklink-delete", title: "删除快捷链接…", icon: "trash", group: 1, destructive: true) { [weak model] in
                guard let model, let window = NSApp.keyWindow, window.attachedSheet == nil else { return }
                let alert = NSAlert()
                alert.messageText = "删除快捷链接？"
                alert.informativeText = link.title
                alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
                alert.addButton(withTitle: "删除").hasDestructiveAction = true
                alert.beginSheetModal(for: window) { [weak model] result in
                    guard let model, result == .alertSecondButtonReturn,
                          model.launcherModules?.isModuleEnabled(.init(rawValue: "keylane.links")) == true else { return }
                    do { try remove(link, model: model) }
                    catch { controller.feedback(error.localizedDescription, .failure) }
                }
            }
        ]
    }

    static func remove(_ link: Quicklink, model: Model) throws {
        try model.quicklinks.remove(link)
        model.setShortcut(link.id, value: nil)
        if model.favorites.contains(link.id) { model.toggleFavorite(link.id) }
        model.disabledCommands.remove(link.id)
        model.setAlias(link.id, value: "")
        model.resetUsage(for: link.id)
    }
}

extension Quicklink {
    func commandSettingsEntry(model: Model, perform: (() -> Void)? = nil,
                              menu: [CommandSettingsAction] = []) -> CommandSettingsEntry<some View> {
        let commandID = CommandID(rawValue: id)
        return CommandSettingsEntry(title: title, model: model, commandID: commandID,
                                    isEnabled: Binding(get: { !model.disabledCommands.contains(id) }, set: {
            if $0 { model.disabledCommands.remove(id) }
            else { model.disabledCommands.insert(id) }
        }), perform: perform ?? { model.runCommand(commandID, origin: .menu) },
           help: template, menu: menu) { SettingsIcon(symbol: "link", artwork: ModuleArtwork.settings("links")) }
    }
}
