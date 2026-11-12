import AppKit
import Combine
import SwiftUI
import KeylaneCore

enum LauncherCommandOrigin { case search, shortcut, menu }

struct Entry: Identifiable {
    /// The existing result ID is also used by alias, favorite and usage preferences.
    let id: String
    let commandID: CommandID
    let name: String
    let detail: String
    let symbol: String
    var aliases: [String] = []
    var rankingKind: LauncherSearchRanking.Kind = .command
    var matchScore: Int?
    var isDirectory = false
    var isFallback = false
    var subtitle: String?
    var needsPermissionActivation = false
}

struct LauncherAction: Identifiable {
    struct Submenu {
        let title: String
        let items: [LauncherAction]
    }

    struct ArgumentForm {
        let title: String
        let submit: ([String]) -> Void
    }

    let id: String
    let title: String
    let icon: String
    var keys: [String] = []
    var artwork: NSImage? = nil
    var submenu: Submenu?
    var group = 0
    var enabled = true
    var destructive = false
    var perform: () -> Void = {}
}

struct LauncherPage {
    enum ContentPlacement {
        case inset
        case underChrome
        case fileResults
        case form
    }

    let id: PageID
    let placeholder: String
    var badge: (title: String, symbol: String)?
    var actionTitle: String?
    var contentPlacement: ContentPlacement = .inset
    var content: (() -> AnyView)?
    var queryChanged: (String) -> Void = { _ in }
    var leave: () -> Void = {}
    var move: ((Int) -> Void)?
    var submit: (() -> Void)?
    var shortcutSubmit: (() -> Void)?
    var optionSubmit: (() -> Void)?
    var actionContextTitle: (() -> String?)?
    var primaryTitle: (() -> String)?
    var primaryEnabled: (() -> Bool)?
    var actions: (() -> [LauncherAction])?
    var updates: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    var searchAccessory: (() -> AnyView)?
    var enter: ((String) -> String?)?
    var resume: (() -> Void)?
    var moveHorizontal: ((Int) -> Void)?
    var navigateWhileTyping = false
    var typeFilterWidth: CGFloat?
    var typeFilter: ((Binding<Bool>) -> AnyView)?
    var badgeTitle: (() -> String)?
    var actionWidth: CGFloat?
    var releasePreview: (() -> Void)?
}

struct SettingsTitlebarContribution {
    let title: String
    var help: String?
    let enabled: Binding<Bool>
    let updates: AnyPublisher<Bool, Never>
    var searchItem: SettingsItem?
    var permissionStatus: AnyPublisher<SettingsPermissionStatus, Never>?
    var openPrivacySettings: (() -> Void)?
}

struct LauncherSettingsPage: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let subtitle: String
    let order: Int
    let items: [SettingsItem]
    var titlebar: SettingsTitlebarContribution?
    var trailingToolbar: (() -> AnyView)?
    let content: () -> AnyView
}

enum LauncherModuleOrigin: CaseIterable {
    case application
    case builtInExtension
    case installedExtension

    var settingsSectionTitle: String? {
        switch self {
        case .application: nil
        case .builtInExtension: "内置扩展"
        case .installedExtension: "已安装扩展"
        }
    }
}

struct SettingsSidebarGroup: Identifiable {
    let id: LauncherModuleOrigin
    let pages: [LauncherSettingsPage]
}

struct SettingsWindowCatalog {
    let pages: [LauncherSettingsPage]
    let sidebarGroups: [SettingsSidebarGroup]
    let items: [SettingsItem]
    private let pagesByID: [String: LauncherSettingsPage]
    private let itemsByID: [String: SettingsItem]

    init(pages: [LauncherSettingsPage], origins: [String: LauncherModuleOrigin] = [:]) {
        self.pages = pages
        sidebarGroups = LauncherModuleOrigin.allCases.compactMap { origin in
            let matches = pages.filter { (origins[$0.id] ?? .builtInExtension) == origin }
            return matches.isEmpty ? nil : SettingsSidebarGroup(id: origin, pages: matches)
        }
        items = pages.flatMap(\.items)
        pagesByID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func page(_ id: String) -> LauncherSettingsPage? { pagesByID[id] }
    func item(_ id: String) -> SettingsItem? { itemsByID[id] }
}

struct LauncherModule {
    struct Command {
        let declaration: LauncherCommandDeclaration
        var detail: (() -> String)?
        var settingsEnabled: Binding<Bool>?
        var available: () -> Bool = { true }
        var permission: PermissionFeature?
        var execute: (LauncherCommandOrigin) -> Void = { _ in }
    }
    struct Provider {
        /// Each provider owns a disjoint ID namespace or a single exact ID.
        let namespace: LauncherCommandNamespace
        let entries: (LauncherCommandSearch.Input) -> [Entry]
        let resolve: (CommandID, LauncherCommandOrigin) -> (() -> Void)?
        var primaryTitle: ((Entry) -> String?)?
        var actions: ((Entry) -> [LauncherAction]?)?
        var displayDetail: ((Entry) -> String?)?
        var artwork: ((Entry) -> AnyView)?
        var detailView: ((Entry) -> AnyView?)?
    }

    struct Service {
        let start: () -> Void
        let stop: () -> Void
    }

    let id: ModuleID
    var origin: LauncherModuleOrigin = .builtInExtension
    var title: String? = nil
    var symbol: String? = nil
    var commands: [Command] = []
    var providers: [Provider] = []
    var pages: [LauncherPage] = []
    var settings: [LauncherSettingsPage] = []
    var services: [Service] = []
    var searchUpdates: [AnyPublisher<Void, Never>] = []
    var launcherShown: (() -> Void)?
    var launcherHidden: (() -> Void)?
    var presentationUpdates: [AnyPublisher<Void, Never>] = []
    var applicationFocused: ((NSRunningApplication) -> Void)?
    var dynamicCommandSettings: DynamicCommandSettings?
    var shortcutSettingsBinding: ShortcutSettingsBinding?
    var shortcutSettingsUpdates: [AnyPublisher<Void, Never>] = []
    var permissionTitlebar: SettingsTitlebarContribution?
}

extension LauncherModule {
    var displayTitle: String { title ?? settings.first?.title ?? commands.first?.declaration.title ?? id.rawValue }
    var displaySymbol: String { symbol ?? settings.first?.symbol ?? commands.first?.declaration.symbol ?? "puzzlepiece.extension" }
}

/// Modules supply a lazy catalog and a list that uses the shared command settings rows.
struct DynamicCommandSettings {
    typealias Matches = (_ title: String, _ commandID: String, _ aliasKey: String?) -> Bool
    let updates: () -> [AnyPublisher<Void, Never>]
    let matchingList: (_ matches: Matches?) -> ((_ showsColumns: Bool) -> AnyView)?
}

struct ShortcutSettingsBinding {
    let id: String
    let title: String
    let symbol: String
}

struct ShortcutCommandGroup {
    let id: ModuleID
    let title: String
    let symbol: String
    let commands: [LauncherModule.Command]
    let dynamicCommands: DynamicCommandSettings?
    let binding: ShortcutSettingsBinding?
}

/// The registry stores native factories and handlers. Validation never runs a
/// handler, constructs a view, or touches a permission-protected service.
final class LauncherModuleRegistry {
    enum SettingsRegistrationError: Error, Equatable {
        case wrongPage(item: String, expected: String)
        case duplicateItem(String)
    }
    let shortcutCommandGroups: [ShortcutCommandGroup]
    private let commandSettingsUpdates: [AnyPublisher<Void, Never>]
    private let commands: [LauncherModule.Command]
    private let commandEnabled: (CommandID) -> Bool
    private let byID: [CommandID: LauncherModule.Command]
    private let providers: [LauncherModule.Provider]
    private let pages: [PageID: LauncherPage]
    let settingsCatalog: SettingsWindowCatalog
    var settings: [LauncherSettingsPage] { settingsCatalog.pages }
    private let services: [LauncherModule.Service]
    private let launcherShownHandlers: [() -> Void]
    private let launcherHiddenHandlers: [() -> Void]
    private let applicationFocusedHandlers: [(NSRunningApplication) -> Void]
    private var servicesRunning = false
    let searchUpdates: AnyPublisher<Void, Never>
    let presentationUpdates: AnyPublisher<Void, Never>

    init(modules: [LauncherModule], commandEnabled: @escaping (CommandID) -> Bool = { _ in true }) throws {
        self.commandEnabled = commandEnabled
        _ = try LauncherModuleCatalog(modules: modules.map {
            LauncherModuleDeclaration(id: $0.id, commands: $0.commands.map(\.declaration),
                                      pages: $0.pages.map(\.id), settingsPages: $0.settings.map(\.id),
                                      providers: $0.providers.map(\.namespace))
        })
        shortcutCommandGroups = modules.compactMap { module in
            guard !module.commands.isEmpty || module.dynamicCommandSettings != nil || module.shortcutSettingsBinding != nil
            else { return nil }
            return ShortcutCommandGroup(id: module.id, title: module.displayTitle,
                                        symbol: module.displaySymbol, commands: module.commands,
                                        dynamicCommands: module.dynamicCommandSettings, binding: module.shortcutSettingsBinding)
        }
        commandSettingsUpdates = modules.flatMap(\.shortcutSettingsUpdates)
        commands = modules.flatMap(\.commands)
        byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.declaration.id, $0) })
        providers = modules.flatMap(\.providers)
        pages = Dictionary(uniqueKeysWithValues: modules.flatMap(\.pages).map { ($0.id, $0) })
        let settingsPages = modules.flatMap(\.settings).sorted { $0.order < $1.order }
        var itemIDs: Set<String> = []
        for page in settingsPages {
            for item in page.items {
                guard item.page == page.id else {
                    throw SettingsRegistrationError.wrongPage(item: item.id, expected: page.id)
                }
                guard itemIDs.insert(item.id).inserted else {
                    throw SettingsRegistrationError.duplicateItem(item.id)
                }
            }
        }
        let settingsOrigins = Dictionary(uniqueKeysWithValues: modules.flatMap { module in
            module.settings.map { ($0.id, module.origin) }
        })
        settingsCatalog = SettingsWindowCatalog(pages: settingsPages, origins: settingsOrigins)
        services = modules.flatMap(\.services)
        launcherShownHandlers = modules.compactMap(\.launcherShown)
        launcherHiddenHandlers = modules.compactMap(\.launcherHidden)
        applicationFocusedHandlers = modules.compactMap(\.applicationFocused)
        presentationUpdates = Publishers.MergeMany(modules.flatMap(\.presentationUpdates))
            .receive(on: DispatchQueue.main).eraseToAnyPublisher()
        searchUpdates = Publishers.MergeMany(modules.flatMap(\.searchUpdates)).eraseToAnyPublisher()
    }

    func shortcutSettingsUpdates() -> [AnyPublisher<Void, Never>] {
        commandSettingsUpdates + shortcutCommandGroups.flatMap { $0.dynamicCommands?.updates() ?? [] }
    }

    func launcherShown() { launcherShownHandlers.forEach { $0() } }
    func launcherHidden() { launcherHiddenHandlers.forEach { $0() } }
    func applicationFocused(_ app: NSRunningApplication) {
        guard servicesRunning else { return }
        applicationFocusedHandlers.forEach { $0(app) }
    }

    func startServices() {
        guard !servicesRunning else { return }
        servicesRunning = true
        for service in services { service.start() }
    }
    func stopServices() {
        guard servicesRunning else { return }
        servicesRunning = false
        for service in services.reversed() { service.stop() }
    }
    /// Preserve a prior disable from the host when a module supplies its own command preference.
    func migrateDisabledCommands(_ disabled: Set<String>) -> Set<String> {
        var remaining = disabled
        for id in disabled {
            guard let preference = byID[CommandID(rawValue: id)]?.settingsEnabled else { continue }
            if preference.wrappedValue { preference.wrappedValue = false }
            remaining.remove(id)
        }
        return remaining
    }

    func declaration(_ id: CommandID) -> LauncherCommandDeclaration? { byID[id]?.declaration }

    func page(_ id: PageID) -> LauncherPage? { pages[id] }

    func permissionNeeded(for id: CommandID) -> PermissionFeature? {
        guard let command = byID[id], commandEnabled(id), command.available(),
              let permission = command.permission else { return nil }
        permission.recheck()
        return permission.available ? nil : permission
    }

    private func provider(for entry: Entry) -> LauncherModule.Provider? {
        providers.first { $0.namespace.contains(entry.commandID) }
    }

    func actions(for entry: Entry) -> [LauncherAction]? { provider(for: entry)?.actions?(entry) }
    func primaryTitle(for entry: Entry) -> String? { provider(for: entry)?.primaryTitle?(entry) }
    func displayDetail(for entry: Entry) -> String? { provider(for: entry)?.displayDetail?(entry) }

    func detailView(for entry: Entry) -> AnyView? { provider(for: entry)?.detailView?(entry) }

    func artwork(for entry: Entry) -> AnyView? {
        if let artwork = provider(for: entry)?.artwork?(entry) { return artwork }
        let item = declaration(entry.commandID)
        return ModuleArtwork.command(entry.commandID, settingsPage: item?.settingsPage)
            .map { AnyView(ModuleArtworkImage(image: $0)) }
    }

    func candidates(for input: LauncherCommandSearch.Input) -> [Entry] {
        commands.compactMap { command in
            guard input.namespace?.contains(command.declaration.id) != false,
                  commandEnabled(command.declaration.id), command.available() else { return nil }
            let item = command.declaration
            let needsPermission = command.permission?.available == false
            if needsPermission && input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return Entry(id: item.id.rawValue, commandID: item.id, name: item.title,
                         detail: command.detail?() ?? item.detail, symbol: item.symbol, aliases: item.keywords,
                         subtitle: needsPermission ? "启用并继续" : nil, needsPermissionActivation: needsPermission)
        } + providers.flatMap { provider in
            guard input.namespace?.overlaps(provider.namespace) != false else { return [Entry]() }
            return provider.entries(input).filter {
                provider.namespace.contains($0.commandID) && input.namespace?.contains($0.commandID) != false
            }
        }
    }

    func resolve(_ id: CommandID, origin: LauncherCommandOrigin,
                 navigate: @escaping (LauncherCommandDeclaration.Destination) -> Void) -> (() -> Void)? {
        if let command = byID[id] {
            guard commandEnabled(command.declaration.id), command.available(),
                  command.permission?.available != false else { return nil }
            return {
                command.execute(origin)
                switch command.declaration.destination {
                case .action: break
                case .page, .settings: navigate(command.declaration.destination)
                }
            }
        }
        for provider in providers where provider.namespace.contains(id) {
            if let action = provider.resolve(id, origin) { return action }
        }
        return nil
    }
}
