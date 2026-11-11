import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum UtilityLauncherModules {
    static func make(model: Model) -> [LauncherModule] {
        [contacts(model.contacts), dictionary(model), emoji(model), shortcuts(model)]
    }

    private static func contacts(_ controller: ContactsController) -> LauncherModule {
        let pageID = PageID(rawValue: "Contacts")
        let selectedContact = controller.$visible.combineLatest(controller.$selectedID)
            .map { results, id in results.first { $0.id == id } }
        var page = LauncherPage(id: pageID, placeholder: "搜索联系人…",
                                badge: ("联系人", "person.crop.circle"),
                                contentPlacement: .underChrome,
                                content: { AnyView(ContactsPage(controller: controller)) },
                                queryChanged: { controller.query = $0 },
                                leave: controller.stop,
                                move: controller.move,
                                submit: {
                                    if let value = controller.selected?.firstValue { UtilityActions.copy(value) }
                                    else { UtilityActions.openApplication("com.apple.AddressBook") }
                                },
                                primaryTitle: { controller.selected?.firstValue == nil ? "打开联系人" : "复制" },
                                actions: { contactActions(controller) },
                                updates: ViewObservation.changes(selectedContact))
        page.enter = { query in
            controller.query = query
            controller.start()
            return nil
        }
        page.resume = controller.start
        return .init(id: .init(rawValue: "keylane.contacts"), commands: [
            command("contacts", "搜索联系人", "系统通讯录", "person.crop.circle",
                    ["Contacts", "Address Book", "联系人", "通讯录"], destination: .page(pageID))
        ], pages: [page])
    }

    private static func contactActions(_ controller: ContactsController) -> [LauncherAction] {
        var actions = [
            LauncherAction(id: "contacts-open", title: "打开系统联系人", icon: "person.crop.circle",
                           perform: { UtilityActions.openApplication("com.apple.AddressBook") }),
            LauncherAction(id: "contacts-refresh", title: "刷新联系人", icon: "arrow.clockwise",
                           perform: controller.refresh)
        ]
        if let contact = controller.selected {
            actions += contact.phones.enumerated().map { index, value in
                LauncherAction(id: "phone-\(index)", title: "复制电话 " + value, icon: "phone",
                               perform: { UtilityActions.copy(value) })
            }
            actions += contact.emails.enumerated().map { index, value in
                LauncherAction(id: "email-\(index)", title: "复制邮箱 " + value, icon: "envelope",
                               perform: { UtilityActions.copy(value) })
            }
        }
        return actions
    }

    private static func dictionary(_ model: Model) -> LauncherModule {
        let controller = model.dictionary
        let pageID = PageID(rawValue: "Dictionary")
        let suggestionID = CommandID(rawValue: "dictionary-query")
        let provider = LauncherModule.Provider(namespace: .exact(suggestionID), entries: { input in
            guard let term = dictionaryTerm(input.query) else { return [] }
            return [Entry(id: suggestionID.rawValue, commandID: suggestionID, name: "查询「" + term + "」",
                          detail: "系统词典", symbol: "book.closed", matchScore: 2000)]
        }, resolve: { [weak model] _, origin in
            guard origin != .shortcut, let model, let term = dictionaryTerm(model.query) else { return nil }
            return {
                controller.initialTerm = term
                model.openPage(pageID, origin: origin)
            }
        })
        var page = LauncherPage(id: pageID, placeholder: "输入要查询的词语…",
                                badge: ("词典", "book.closed"),
                                content: { AnyView(DictionaryPage(controller: controller)) },
                                queryChanged: controller.search,
                                leave: { controller.search("") },
                                submit: {
                                    if let definition = controller.definition { UtilityActions.copy(definition) }
                                    else { controller.openDictionary() }
                                },
                                primaryTitle: { controller.definition == nil ? "打开词典" : "复制释义" },
                                actions: { dictionaryActions(controller) },
                                updates: ViewObservation.changes(controller.$definition))
        page.enter = { _ in
            let term = controller.initialTerm
            controller.initialTerm = ""
            return term
        }
        page.resume = { [weak model] in
            if let query = model?.query { controller.search(query) }
        }
        return .init(id: .init(rawValue: "keylane.dictionary"), commands: [
            command("dictionary", "查询词典", "查找词语释义", "book.closed",
                    ["Dictionary", "Define Word", "字典", "查词"], destination: .page(pageID))
        ], providers: [provider], pages: [page])
    }

    private static func dictionaryTerm(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["define ", "词典 ", "查词 "]
        guard let prefix = prefixes.first(where: { trimmed.lowercased().hasPrefix($0) }) else { return nil }
        let term = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return term.isEmpty ? nil : term
    }

    private static func dictionaryActions(_ controller: DictionaryController) -> [LauncherAction] {
        let open = LauncherAction(id: "dictionary-open", title: "打开系统词典", icon: "book.closed",
                                  perform: controller.openDictionary)
        guard let definition = controller.definition else { return [open] }
        return [LauncherAction(id: "dictionary-copy", title: "复制释义", icon: "doc.on.doc",
                               perform: { UtilityActions.copy(definition) }), open]
    }

    private static func emoji(_ model: Model) -> LauncherModule {
        let controller = model.emoji
        let pageID = PageID(rawValue: "Emoji")
        let title = EmojiCatalog.label("Emoji 与符号", "Emoji & Symbols")
        let use: (EmojiItem, Bool) -> Void = { [weak model] item, paste in
            guard let model else { return }
            model.error = ""
            UtilityActions.copy(item.glyph)
            controller.recordUse(item)
            let delegate = NSApp.delegate as? Delegate
            if paste, let delegate, delegate.pasteTargetName != nil {
                delegate.pasteIntoPreviousApplication { [weak model] message in model?.error = message }
            } else {
                delegate?.hideLauncher()
            }
        }
        var page = LauncherPage(id: pageID,
                                placeholder: EmojiCatalog.label("搜索 Emoji 与符号…", "Search Emoji & Symbols…"),
                                badge: (title, "face.smiling"),
                                contentPlacement: .underChrome,
                                content: { AnyView(EmojiSearchPage(controller: controller) { use($0, true) }) },
                                queryChanged: { controller.query = $0 },
                                move: { controller.move($0, vertical: true) },
                                submit: { if let item = controller.selected { use(item, true) } },
                                primaryTitle: emojiPasteTitle,
                                actions: {
                                    guard let item = controller.selected else { return [] }
                                    return [
                                        LauncherAction(id: "paste-emoji", title: emojiPasteTitle(), icon: "doc.on.clipboard",
                                                       keys: ["↩"], perform: { use(item, true) }),
                                        LauncherAction(id: "copy-emoji", title: EmojiCatalog.label("复制字符", "Copy Character"),
                                                       icon: "doc.on.doc", perform: { use(item, false) })
                                    ]
                                },
                                updates: Publishers.Merge(ViewObservation.changes(controller.$selection),
                                                          ViewObservation.changes(controller.$category)).eraseToAnyPublisher())
        page.enter = { query in
            controller.query = query
            controller.start()
            return nil
        }
        page.leave = controller.stop
        page.resume = controller.start
        page.moveHorizontal = { controller.move($0, vertical: false) }
        page.navigateWhileTyping = true
        page.badgeTitle = { controller.selected.map { "\(title) – \($0.title)" } ?? title }
        page.actionWidth = 258
        page.typeFilterWidth = 174
        page.typeFilter = { [weak model] open in
            AnyView(ResultTypeFilter(
                selection: Binding(get: { controller.category }, set: { controller.category = $0 }),
                options: EmojiCatalog.categories, open: open, navigation: model?.navigation ?? "arrows", width: 174,
                searchPlaceholder: EmojiCatalog.label("搜索分类…", "Search categories…")
            ))
        }
        return .init(id: .init(rawValue: "keylane.emoji"), commands: [
            command("emoji-symbols", EmojiCatalog.label("Emoji 与符号", "Search Emoji & Symbols"),
                    EmojiCatalog.label("搜索并插入表情与符号", "Search and insert emoji and symbols"),
                    "face.smiling", ["Emoji", "Symbols", "表情", "符号"], destination: .page(pageID))
        ], pages: [page])
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
        let provider = LauncherModule.Provider(namespace: .prefix("shortcut:"), entries: { _ in
            controller.entries.compactMap { shortcut in
                guard !controller.disabledIDs.contains(shortcut.id) else { return nil }
                return Entry(id: shortcut.commandID, commandID: .init(rawValue: shortcut.commandID),
                             name: shortcut.name, detail: "Shortcut", symbol: "square.stack.3d.up")
            }
        }, resolve: { command, _ in
            guard controller.runningID == nil,
                  let shortcut = controller.entries.first(where: { $0.commandID == command.rawValue }),
                  !controller.disabledIDs.contains(shortcut.id) else { return nil }
            return { controller.run(shortcut.id) }
        }, primaryTitle: { _ in
            controller.runningID == nil ? "运行" : "运行中"
        }, actions: { [weak model] row in
            guard let model else { return nil }
            return shortcutActions(for: row, model: model)
        }, displayDetail: { _ in "快捷指令" }, artwork: { row in
            AnyView(ShortcutArtwork(image: controller.icon(forCommandID: row.id)))
        })
        let settings = LauncherSettingsPage(id: pageID, title: "快捷指令", symbol: "square.stack.3d.up",
                                            subtitle: "为系统快捷指令设置搜索别名与热键。", order: 60,
                                            items: SettingsItem.all.filter { $0.page == pageID },
                                            content: { [weak model] in
                                                guard let model else { return AnyView(EmptyView()) }
                                                return AnyView(SystemShortcutsPreferences(model: model, controller: controller))
                                            })
        let searchUpdates = Publishers.Merge(
            controller.$entries.removeDuplicates().dropFirst().map { _ in () },
            controller.$disabledIDs.removeDuplicates().dropFirst().map { _ in () }
        ).eraseToAnyPublisher()
        var module = LauncherModule(id: .init(rawValue: "keylane.shortcuts"), commands: [
            command("system-shortcuts", "管理快捷指令", "别名、热键与启用状态", "square.stack.3d.up",
                    ["Shortcuts", "Apple Shortcuts", "快捷指令"], destination: .settings(pageID), settings: pageID)
        ], providers: [provider], settings: [settings], services: [
            .init(start: { [weak model] in
                controller.onRunFailure = { [weak model] message in model?.error = message }
                controller.refresh()
            }, stop: { controller.onRunFailure = nil })
        ], searchUpdates: [searchUpdates])
        module.launcherShown = { controller.refresh() }
        module.presentationUpdates = [
            controller.$runningID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            controller.$icons.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        return module
    }

    private static func shortcutActions(for row: Entry, model: Model) -> [LauncherAction] {
        return [
            LauncherAction(id: "shortcut-run", title: "运行快捷指令", icon: "play", perform: { [weak model] in
                model?.runCommand(row.commandID, origin: .menu, usageKey: row.id)
            }),
            LauncherAction(id: "shortcut-settings", title: "快捷指令设置…", icon: "gearshape", perform: { [weak model] in
                model?.runCommand(CommandID(rawValue: "system-shortcuts"), origin: .menu)
            })
        ]
    }

    private static func command(_ id: String, _ title: String, _ detail: String, _ symbol: String,
                                _ keywords: [String], destination: LauncherCommandDeclaration.Destination,
                                settings: String? = nil) -> LauncherModule.Command {
        .init(declaration: .init(id: .init(rawValue: id), title: title, detail: detail, symbol: symbol,
                                keywords: keywords, destination: destination, settingsPage: settings))
    }
}
