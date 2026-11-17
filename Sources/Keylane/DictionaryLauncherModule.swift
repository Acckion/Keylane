import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum DictionaryLauncherModule {
    private static let settingsID = "keylane.dictionary"
    private static let commandID = CommandID(rawValue: "dictionary")
    private static let queryID = CommandID(rawValue: "dictionary-query")
    private static let listID = PageID(rawValue: "Dictionary")
    private static let detailID = PageID(rawValue: "DictionaryDetail")
    private static let title = "查询词典"
    private static let symbol = "book.closed"
    private static let argumentKey = "dictionary.acceptsArgument"
    private static let primaryKey = "dictionary.primaryAction"
    private static let item = SettingsItem(id: "dictionary-command", page: settingsID, title: title,
                                          keywords: "Dictionary Define Word 字典 查词 参数 主操作")

    private enum Action: String, CaseIterable {
        case details, open, paste, copy

        var title: String {
            switch self {
            case .details: "显示详情"
            case .open: "在系统词典中打开"
            case .paste: "粘贴词语"
            case .copy: "复制词语"
            }
        }

        var symbol: String {
            switch self {
            case .details: "sidebar.right"
            case .open: "book.closed"
            case .paste: "clipboard"
            case .copy: "doc.on.clipboard"
            }
        }
    }

    static func make(model: Model) -> LauncherModule {
        let controller = model.dictionary
        let defaults = UserDefaults.standard
        let command = LauncherModule.Command(declaration: .init(
            id: commandID, title: title, detail: "查找词语释义", symbol: symbol,
            keywords: ["Dictionary", "Define Word", "字典", "查词"], destination: .page(listID), settingsPage: settingsID))
        let provider = LauncherModule.Provider(namespace: .exact(queryID), entries: { [weak model] input in
            guard input.page == .root, let model,
                  let term = rootTerm(input.query, model: model, defaults: defaults) else { return [] }
            return [Entry(id: queryID.rawValue, commandID: queryID, name: "查询「" + term + "」",
                          detail: "系统词典", symbol: symbol, matchScore: 2000)]
        }, resolve: { [weak model] _, origin in
            guard origin != .shortcut, let model,
                  let term = rootTerm(model.query, model: model, defaults: defaults) else { return nil }
            return {
                controller.initialTerm = term
                model.openPage(listID, origin: origin)
            }
        })
        let options = DictionaryDetailOptions()
        let primary = { defaults.string(forKey: primaryKey).flatMap(Action.init(rawValue:)) ?? .details }
        let openDetails: () -> Void = { [weak model] in
            guard controller.selected != nil else { return }
            options.source = "all"
            model?.openPage(detailID, origin: .search)
        }
        let updates = Publishers.MergeMany([
            ViewObservation.changes(controller.$words), ViewObservation.changes(controller.$selectedID),
            ViewObservation.changes(controller.$term), ViewObservation.changes(controller.$loading)
        ]).eraseToAnyPublisher()
        let list = LauncherPage(
            id: listID, placeholder: "输入要查询的词语…", badge: (title, symbol), contentPlacement: .underChrome,
            content: { AnyView(DictionaryResultList(controller: controller)) }, queryChanged: controller.search,
            leave: { [weak model] in
                if model?.pageID != detailID { controller.search("") }
            },
            move: controller.move,
            submit: {
                guard let selected = controller.selected else {
                    if controller.canSubmit { open(controller) }
                    return
                }
                perform(primary(), word: selected, controller: controller, details: openDetails)
            },
            actionContextTitle: { controller.selected?.word },
            primaryTitle: { controller.selected == nil ? Action.open.title : actionTitle(primary()) },
            primaryEnabled: { controller.canSubmit },
            actions: {
                guard let selected = controller.selected else {
                    return controller.canSubmit ? [.init(id: "dictionary-open", title: Action.open.title,
                                                         icon: Action.open.symbol, keys: ["↩"], perform: { open(controller) })] : []
                }
                return actions(for: selected, controller: controller, primary: primary(), details: openDetails)
            }, updates: updates,
            enter: { _ in
                defer { controller.initialTerm = "" }
                return controller.initialTerm
            },
            actionShortcutsEnabled: true, loading: controller.$loading.eraseToAnyPublisher()
        )
        let openSelected = { if let selected = controller.selected { open(controller, word: selected.word) } }
        let detail = LauncherPage(
            id: detailID, placeholder: "", badge: (title, symbol), contentPlacement: .underChrome,
            content: {
                AnyView(DictionaryEntryDetail(word: controller.selected, options: options)
                    .id(controller.selectedID))
            },
            leave: { [weak model] in
                if model?.pageID != listID { controller.search("") }
            }, keepsStateWhenHidden: true, parent: listID,
            submit: openSelected, shortcutSubmit: openSelected,
            actionContextTitle: { controller.selected?.word },
            primaryTitle: { Action.open.title }, primaryEnabled: { controller.selected != nil },
            actions: {
                controller.selected.map { actions(for: $0, controller: controller, primary: .open) } ?? []
            }, updates: updates, headerInput: .none,
            typeFilterWidth: 174, typeFilter: { [weak model] isOpen in
                AnyView(DictionarySourceFilter(word: controller.selected, options: options,
                                               isOpen: isOpen, navigation: model?.navigation ?? "arrows"))
            }, badgeTitle: { controller.selected?.word ?? title },
            actionShortcutsEnabled: true, submitWithReturn: true
        )
        let settings = LauncherSettingsPage(
            id: settingsID, title: "词典", symbol: symbol, subtitle: "查询本机词库中的词语释义。",
            order: 130, items: [item], centeredHeader: true
        ) { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(Preferences(model: model, command: command))
        }
        let preferencesChanged = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in defaults.bool(forKey: argumentKey) }.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        return .init(id: .init(rawValue: settingsID), title: "词典", symbol: symbol, commands: [command],
                     providers: [provider], pages: [list, detail], settings: [settings],
                     services: [.init(start: {}, stop: {
            controller.initialTerm = ""
            controller.search("")
        })], searchUpdates: [preferencesChanged])
    }

    private static func rootTerm(_ query: String, model: Model, defaults: UserDefaults) -> String? {
        guard defaults.bool(forKey: argumentKey), !model.disabledCommands.contains(commandID.rawValue) else { return nil }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = ["define word", "define", "dictionary", title, "词典", "查词", model.aliases[commandID.rawValue] ?? ""]
        guard !names.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else { return nil }
        for name in names.sorted(by: { $0.count > $1.count }) where !name.isEmpty {
            guard let range = text.range(of: name, options: [.caseInsensitive, .anchored]),
                  range.upperBound < text.endIndex, text[range.upperBound].isWhitespace else { continue }
            let term = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return (1...DictionaryController.maximumTermLength).contains(term.utf16.count) ? term : nil
        }
        return nil
    }

    private static func actions(for word: DictionaryWord, controller: DictionaryController, primary: Action,
                                details: (() -> Void)? = nil) -> [LauncherAction] {
        let supported = Action.allCases.filter { $0 != .details || details != nil }
        return ([primary] + supported.filter { $0 != primary }).map { action in
            let keys: [String]
            let shortcut: KeyboardShortcut?
            if action == primary {
                keys = ["↩"]
                shortcut = nil
            }
            else {
                switch action {
                case .details:
                    keys = []
                    shortcut = nil
                case .open:
                    keys = []
                    shortcut = .init(.return, modifiers: .command)
                case .paste:
                    keys = []
                    shortcut = .init(.return, modifiers: details == nil ? .command : .option)
                case .copy:
                    keys = []
                    shortcut = details == nil ? .init(.return, modifiers: .option) : .init("c", modifiers: [.shift, .command])
                }
            }
            let targetIcon = action == .paste ? (NSApp.delegate as? Delegate)?.pasteTargetIcon : nil
            return LauncherAction(id: "dictionary-" + action.rawValue, title: actionTitle(action), icon: action.symbol,
                                  keys: keys, shortcut: shortcut, artwork: targetIcon) {
                perform(action, word: word, controller: controller, details: details)
            }
        } + [.init(id: "dictionary-copy-definition", title: "复制释义", icon: "doc.on.doc", group: 1) {
            guard controller.selected?.id == word.id else { return }
            let copied = controller.copyDefinition(for: controller.term)
            feedback(copied, subject: "释义")
        }]
    }

    private static func actionTitle(_ action: Action) -> String {
        if action == .paste, let destination = (NSApp.delegate as? Delegate)?.pasteTargetName {
            return "粘贴到 " + destination
        }
        return action.title
    }

    private static func perform(_ action: Action, word: DictionaryWord, controller: DictionaryController, details: (() -> Void)?) {
        guard !controller.loading, controller.selected?.id == word.id else { return }
        switch action {
        case .details: details?()
        case .open: open(controller, word: word.word)
        case .paste:
            guard let delegate = NSApp.delegate as? Delegate, UtilityActions.copy(word.word) else {
                feedback(false, subject: "词语")
                return
            }
            delegate.pasteIntoPreviousApplication(clipboardGeneration: NSPasteboard.general.changeCount)
        case .copy: feedback(UtilityActions.copy(word.word), subject: "词语")
        }
    }

    private static func open(_ controller: DictionaryController, word: String? = nil) {
        controller.openDictionary(word: word) {
            (NSApp.delegate as? Delegate)?.showLauncherFeedback("无法打开系统词典。", style: .failure)
        }
    }

    private static func feedback(_ copied: Bool, subject: String) {
        (NSApp.delegate as? Delegate)?.showLauncherFeedback((copied ? "已复制" : "无法复制") + subject,
                                                            style: copied ? .success : .failure)
    }

    private struct Preferences: View {
        let model: Model
        let command: LauncherModule.Command
        @State private var expanded = true
        @AppStorage(argumentKey) private var argument = false
        @AppStorage(primaryKey) private var primary = Action.details

        var body: some View {
            SettingsPageSections {
                SettingsSectionTitle(title: "词典命令")
                ExtensionCommandPreferences(model: model, commands: [command]) { _ in
                    CommandSettingsDisclosure(isExpanded: $expanded, revealItem: item) {
                        AnyView(SettingsRows {
                            Toggle(isOn: $argument) {
                                SettingsRowLabel(title: "启用参数", detail: "在主搜索中输入命令或别名，空一格后直接输入要查的词。")
                            }
                            Divider()
                            SettingsPicker("主操作", selection: $primary) {
                                ForEach(Action.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                        })
                    }
                }
            }
        }
    }
}
