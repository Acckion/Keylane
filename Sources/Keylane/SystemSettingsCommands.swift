import AppKit
import KeylaneCore
import SwiftUI

enum SystemSettingsCommands {
    static func provider(model: Model) -> LauncherModule.Provider {
        LauncherModule.Provider(namespace: .prefix("system-setting:"), entries: { input in
            let hasQuery = !SystemSettingsCatalog.pageQuery(input.query).isEmpty
            return SystemSettingsCatalog.pages.compactMap { page in
                guard hasQuery || input.favorites.contains(page.id) else { return nil }
                return Entry(id: page.id, commandID: .init(rawValue: page.id), name: page.title(),
                             detail: SystemSettingsCatalog.resultKind, symbol: page.symbol, aliases: page.searchNames,
                             rankingKind: .systemSetting)
            }
        }, resolve: { [weak model] id, _ in
            guard let page = SystemSettingsCatalog.pages.first(where: { $0.id == id.rawValue }) else { return nil }
            return { [weak model] in
                if NSWorkspace.shared.open(page.url) {
                    (NSApp.delegate as? Delegate)?.hideLauncher()
                } else {
                    model?.error = SystemSettingsCatalog.prefersChinese()
                        ? "无法打开「\(page.title())」。请在系统设置中查找该页面。"
                        : "Could not open \(page.title()). Look for it in System Settings."
                }
            }
        })
    }

    static func shortcutSettings(model: Model) -> DynamicCommandSettings {
        .init(model: model, items: { SystemSettingsCatalog.pages }, title: \.commandTitle, commandID: \.id,
              updates: { [] }, entry: { $0.commandSettingsEntry(model: $1) })
    }
}

struct SystemCommandPreferences: View {
    let model: Model
    let commands: [LauncherModule.Command]
    let actionsItem: SettingsItem
    let settingsItem: SettingsItem
    @ObservedObject var search: SettingsSearchControls
    @StateObject private var observation: ViewObservation

    init(model: Model, commands: [LauncherModule.Command], actionsItem: SettingsItem,
         settingsItem: SettingsItem, search: SettingsSearchControls) {
        self.model = model
        self.commands = commands
        self.actionsItem = actionsItem
        self.settingsItem = settingsItem
        self.search = search
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands)
        ]))
    }

    var body: some View {
        let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ id: String, names: [String]) -> Bool {
            query.isEmpty || names.contains { $0.localizedCaseInsensitiveContains(query) }
                || model.aliases[id]?.localizedCaseInsensitiveContains(query) == true
        }
        let actions = commands.filter { command in
            let declaration = command.declaration
            return matches(declaration.id.rawValue, names: declaration.keywords)
        }
        let settings = SystemSettingsCatalog.pages.filter { matches($0.id, names: $0.searchNames) }
        return SettingsPageSections {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(title: actionsItem.title).settingsAnchor(actionsItem)
                ExtensionCommandPreferences(model: model, commands: actions, emptyMessage: "没有匹配的系统操作")
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(title: settingsItem.title).settingsAnchor(settingsItem)
                CommandSettingsList(items: settings, id: \.id, emptyMessage: "没有匹配的系统设置命令", showsColumns: true) {
                    $0.commandSettingsEntry(model: model)
                }
            }
        }
    }
}

private extension SystemSettingsPage {
    var commandTitle: String { title() }

    func commandSettingsEntry(model: Model) -> CommandSettingsEntry<SettingsIcon> {
        CommandSettingsEntry(title: commandTitle, model: model, commandID: .init(rawValue: id),
                             isEnabled: Binding(get: { !model.disabledCommands.contains(id) }, set: { enabled in
            if enabled { model.disabledCommands.remove(id) }
            else { model.disabledCommands.insert(id) }
        })) {
            SettingsIcon(symbol: symbol)
        }
    }
}
