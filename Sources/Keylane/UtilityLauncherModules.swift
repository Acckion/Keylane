import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum UtilityLauncherModules {
    static func make(model: Model) -> [LauncherModule] {
        [ContactsLauncherModule.make(model: model), DictionaryLauncherModule.make(model: model), emoji(model), shortcuts(model)]
    }

    private static func emoji(_ model: Model) -> LauncherModule {
        let controller = model.emoji
        let pageID = EmojiSearchController.pageID
        let settingsID = "keylane.emoji"
        let title = EmojiCatalog.label("Emoji 与符号", "Emoji & Symbols")
        let use: (EmojiItem, Bool) -> Void = { item, paste in
            let delegate = NSApp.delegate as? Delegate
            guard controller.selected?.id == item.id else { return }
            guard let generation = controller.copy(item) else {
                delegate?.showLauncherFeedback(EmojiCatalog.label("无法复制字符", "Could not copy character"), style: .failure)
                return
            }
            if paste, let delegate, delegate.pasteTargetName != nil {
                delegate.pasteIntoPreviousApplication(clipboardGeneration: generation)
            } else {
                delegate?.hideLauncher()
                delegate?.showLauncherFeedback(EmojiCatalog.label("已复制字符", "Character copied"), style: .success)
            }
        }
        let snapshot: () -> LauncherPage.ActionSnapshot = { [weak model] in
            let ai = model.map { [EmojiAIActions.action(model: $0)] } ?? []
            let pasteFirst = controller.primaryAction == .paste
            let paste = LauncherAction(id: "paste-emoji", title: emojiPasteTitle(), icon: "doc.on.clipboard",
                shortcut: pasteFirst ? .init(.return, modifiers: []) : .init(.return, modifiers: .command),
                enabled: controller.selected != nil, perform: {
                    if let item = controller.selected { use(item, true) }
                })
            let copy = LauncherAction(id: "copy-emoji", title: EmojiCatalog.label("复制字符", "Copy Character"), icon: "doc.on.doc",
                shortcut: pasteFirst ? .init(.return, modifiers: .command) : .init(.return, modifiers: []),
                enabled: controller.selected != nil, perform: {
                    if let item = controller.selected { use(item, false) }
                })
            return .init(primary: pasteFirst ? paste : copy,
                items: (controller.selected == nil ? [] : (pasteFirst ? [paste, copy] : [copy, paste])) + ai)
        }
        var page = LauncherPage(id: pageID,
            placeholder: EmojiCatalog.label("搜索 Emoji 与符号…", "Search Emoji & Symbols…"),
            badge: (title, "face.smiling"), contentPlacement: .underChrome,
            content: { AnyView(EmojiSearchPage(controller: controller) { item in
                guard controller.selected?.id == item.id else { return }
                snapshot().primary.invoke()
            }) },
            queryChanged: { controller.query = $0 }, move: { controller.move($0, vertical: true) },
            updates: Publishers.Merge3(ViewObservation.changes(controller.$selection),
                ViewObservation.changes(controller.$category), ViewObservation.changes(controller.$primaryAction)).eraseToAnyPublisher(),
            actionSnapshot: snapshot, startSession: { session in session.onEnd(controller.stop) })
        page.loading = controller.$isLoading.combineLatest(controller.$isSearching)
            .map { loading, searching in loading || searching }.removeDuplicates().eraseToAnyPublisher()
        page.enter = { query in
            controller.query = query
            controller.start()
            return nil
        }
        page.resume = controller.start
        page.actionSelectionID = { controller.selected?.id }
        page.returnBindings.alternates[.command] = .init(actionID: {
            controller.primaryAction == .copy ? "paste-emoji" : "copy-emoji"
        })
        page.moveHorizontal = { controller.move($0, vertical: false) }
        page.navigateWhileTyping = true
        page.badgeTitle = { controller.selected.map { "\(title) – \($0.title)" } ?? title }

        page.typeFilterWidth = 174
        page.typeFilter = { [weak model] open in
            AnyView(ResultTypeFilter(
                selection: Binding(get: { controller.category }, set: { controller.category = $0 }),
                options: EmojiCatalog.categories, open: open, navigation: model?.navigation ?? "arrows", width: 174,
                searchPlaceholder: EmojiCatalog.label("搜索分类…", "Search categories…")
            ))
        }
        var modelChanges: AnyCancellable?
        let settings = LauncherSettingsPage(id: settingsID, title: title, symbol: "face.smiling",
                                            subtitle: "搜索和插入表情与符号。", order: 65,
                                            items: SettingsItem.all.filter { $0.page == settingsID },
                                            centeredHeader: true, content: { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(EmojiPreferences(controller: controller, model: model))
        })
        return .init(id: .init(rawValue: settingsID), title: title, symbol: "face.smiling", commands: [
            command("emoji-symbols", EmojiCatalog.label("Emoji 与符号", "Search Emoji & Symbols"),
                    EmojiCatalog.label("搜索并插入表情与符号", "Search and insert emoji and symbols"),
                    "face.smiling", ["Emoji", "Symbols", "表情", "符号"], destination: .page(pageID), settings: settingsID,
                    acceptsFallbackQuery: true)
        ] + EmojiAIActions.commands(model: model), aiActions: [EmojiAIActions.definition], pages: [page], settings: [settings], services: [.init(start: { [weak model] in
            guard let model else { return }
            modelChanges = model.aiSettings.$state.map { EmojiAIActions.modelIdentity($0.connection(for: .commands)) }.removeDuplicates().sink { controller.setAIModelIdentity($0) }
        }, stop: { modelChanges?.cancel(); modelChanges = nil; controller.releaseCatalog() })])
    }

    private static func emojiPasteTitle() -> String {
        guard let app = (NSApp.delegate as? Delegate)?.pasteTargetName else {
            return EmojiCatalog.label("复制字符", "Copy Character")
        }
        return EmojiCatalog.label("粘贴到 \(app)", "Paste to \(app)")
    }

    private static func shortcuts(_ model: Model) -> LauncherModule {
        let controller = model.systemShortcuts
        let pageID = "shortcuts"
        let editPageID = PageID(rawValue: "ShortcutCommandEdit")
        let editor = ApplicationCommandEdit()
        let search = SettingsSearchControls()
        let provider = LauncherModule.Provider(namespace: .prefix("shortcut:"), entries: { _ in
            return controller.entries.compactMap { shortcut in
                guard !controller.disabledIDs.contains(shortcut.id) else { return nil }
                return Entry(id: shortcut.commandID, commandID: .init(rawValue: shortcut.commandID),
                             name: shortcut.name, detail: "Shortcut", symbol: "square.stack.3d.up",
                             subtitle: controller.duplicateTitles.contains(shortcut.name) ? shortcut.identifierSuffix : nil)
            }
        }, resolve: { command, _ in
            guard let shortcut = controller.entries.first(where: { $0.commandID == command.rawValue }),
                  !controller.disabledIDs.contains(shortcut.id) else { return nil }
            return {
                controller.run(shortcut.id) { status in
                    let message: String
                    let style: ToastStyle
                    switch status {
                    case .started:
                        message = "正在运行「\(shortcut.name)」…"
                        style = .neutral
                    case .completed:
                        message = "「\(shortcut.name)」已完成。"
                        style = .success
                    default:
                        message = status.message
                        style = .failure
                    }
                    (NSApp.delegate as? Delegate)?.showLauncherFeedback(message, style: style)
                }
            }
        }, primaryTitle: { _ in
            controller.runningID == nil ? "运行" : "运行中"
        }, actions: { [weak model] row in
            guard let model else { return nil }
            return shortcutActions(for: row, model: model) { [weak model] in
                guard let model else { return }
                editor.prepare(row, model: model, isAvailable: {
                    controller.entries.contains { shortcut in
                        shortcut.commandID == row.commandID.rawValue && !controller.disabledIDs.contains(shortcut.id)
                    }
                })
                model.openPage(editPageID, origin: .search)
            }
        }, displayDetail: { _ in "快捷指令" }, artwork: { row in
            AnyView(ShortcutArtwork(image: controller.icon(forCommandID: row.id)))
        })
        let settings = LauncherSettingsPage(id: pageID, title: "快捷指令", symbol: "square.stack.3d.up",
                                            subtitle: "为系统快捷指令设置搜索别名与热键。", order: 60,
                                            items: SettingsItem.all.filter { $0.page == pageID },
                                            trailingToolbar: {
                                                AnyView(SettingsToolbarSearch(title: "搜索快捷指令", selection: search))
                                            },
                                            loading: controller.$loading.combineLatest(controller.$entries)
                                                .map { $0 && $1.isEmpty }.removeDuplicates().eraseToAnyPublisher(),
                                            content: { [weak model] in
                                                guard let model else { return AnyView(EmptyView()) }
                                                return AnyView(SystemShortcutsPreferences(model: model, controller: controller, search: search))
                                            })
        let searchUpdates = Publishers.Merge(
            controller.$entries.removeDuplicates().dropFirst().map { _ in () },
            controller.$disabledIDs.removeDuplicates().dropFirst().map { _ in () }
        ).eraseToAnyPublisher()
        var module = LauncherModule(id: .init(rawValue: "keylane.shortcuts"), commands: [
            command("system-shortcuts", "管理快捷指令", "别名、热键与启用状态", "square.stack.3d.up",
                    ["Shortcuts", "Apple Shortcuts", "快捷指令"], destination: .settings(pageID), settings: pageID)
        ], providers: [provider], pages: [.init(
            id: editPageID, placeholder: "", badge: ("配置快捷指令", "keyboard"), contentPlacement: .form,
            content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(ApplicationCommandEditPage(editor: editor, model: model) { row in
                    AnyView(ShortcutArtwork(image: controller.icon(forCommandID: row.id)))
                })
            }, submit: { [weak model] in
                if let model { editor.save(model: model) }
            }, primaryTitle: { "保存别名" }
        )], settings: [settings], services: [
            .init(start: controller.start, stop: controller.stop)
        ], searchUpdates: [searchUpdates], dynamicCommandSettings: .init(
            model: model, items: { controller.entries }, title: \.name, commandID: \.commandID,
            updates: {
                [ViewObservation.changes(controller.$entries), ViewObservation.changes(controller.$disabledIDs),
                 controller.$icons.dropFirst().map { _ in () }.eraseToAnyPublisher()]
            },
            entry: { $0.commandSettingsEntry(model: $1, controller: controller) }
        ))
        module.launcherShown = controller.launcherShown
        module.launcherHidden = controller.launcherHidden
        module.presentationUpdates = [
            controller.$runningID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            controller.$icons.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        return module
    }

    private static func shortcutActions(for row: Entry, model: Model,
                                        configure: @escaping () -> Void) -> [LauncherAction] {
        return [
            LauncherAction(id: "shortcut-run", title: "运行快捷指令", icon: "play", perform: { [weak model] in
                model?.runCommand(row.commandID, origin: .menu, usageKey: row.id)
            }),
            LauncherAction(id: "shortcut-configure", title: "编辑别名与快捷键…", icon: "keyboard",
                           group: 1, perform: configure),
            LauncherAction(id: "shortcut-settings", title: "快捷指令设置…", icon: "gearshape", perform: { [weak model] in
                model?.runCommand(CommandID(rawValue: "system-shortcuts"), origin: .menu)
            })
        ]
    }

    private static func command(_ id: String, _ title: String, _ detail: String, _ symbol: String,
                                _ keywords: [String], destination: LauncherCommandDeclaration.Destination,
                                settings: String? = nil, permission: PermissionFeature? = nil,
                                acceptsFallbackQuery: Bool = false) -> LauncherModule.Command {
        .init(declaration: .init(id: .init(rawValue: id), title: title, detail: detail, symbol: symbol,
                                keywords: keywords, destination: destination, settingsPage: settings), permission: permission,
              acceptsFallbackQuery: acceptsFallbackQuery)
    }
}
