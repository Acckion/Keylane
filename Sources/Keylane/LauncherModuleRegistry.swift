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
    var value: String? = nil
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
    var badgeActions: (() -> [LauncherAction])?
    var maximumActionWidth: CGFloat?
    var releasePreview: (() -> Void)?
    var actionShortcutsEnabled = false
    var loading: AnyPublisher<Bool, Never>?
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
    var loading: AnyPublisher<Bool, Never>?
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
        struct Arguments {
            let count: ClosedRange<Int>
            let execute: (LauncherCommandOrigin, [String]) -> Void
        }

        let declaration: LauncherCommandDeclaration
        var detail: (() -> String)?
        var settingsEnabled: Binding<Bool>?
        var available: () -> Bool = { true }
        var permission: PermissionFeature?
        var execute: (LauncherCommandOrigin) -> Void = { _ in }
        var arguments: Arguments?
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
        var available: (CommandID) -> Bool = { _ in true }
        var permission: (CommandID) -> PermissionFeature? = { _ in nil }
    }

    /// Runtime-discovered modules expose their current presence from validated in-memory metadata.
    /// Built-in modules are always present; command and permission state are evaluated separately.
    struct Registration {
        let isPresent: () -> Bool
        let updates: AnyPublisher<Void, Never>
        var isEnabled: () -> Bool = { true }
        var generation: () -> UInt64 = { 0 }
    }

    struct Service {
        let start: () -> Void
        let stop: () -> Void
        var resume: (() -> Void)?
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
    var registration: Registration?
    var canDisable: Bool { origin != .application }
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
    private struct Owned<Value> {
        let module: ModuleID
        let value: Value
    }

    private let registeredShortcutGroups: [ShortcutCommandGroup]
    var shortcutCommandGroups: [ShortcutCommandGroup] {
        registeredShortcutGroups.filter { isModulePresent($0.id) }
    }

    private let commandSettingsUpdates: [AnyPublisher<Void, Never>]
    private let commands: [Owned<LauncherModule.Command>]
    private let commandEnabled: (CommandID) -> Bool
    private let byID: [CommandID: Owned<LauncherModule.Command>]
    private let providers: [Owned<LauncherModule.Provider>]
    private let moduleRegistrations: [ModuleID: LauncherModule.Registration]
    private let pages: [PageID: Owned<LauncherPage>]
    private let registeredSettings: [Owned<LauncherSettingsPage>]
    private let settingsOrigins: [String: LauncherModuleOrigin]
    let registrationUpdates: AnyPublisher<Void, Never>
    var settingsCatalog: SettingsWindowCatalog {
        SettingsWindowCatalog(pages: registeredSettings.compactMap { isModulePresent($0.module) ? $0.value : nil },
                              origins: settingsOrigins)
    }
    var settings: [LauncherSettingsPage] { settingsCatalog.pages }
    private let modules: [LauncherModule]
    private let disableableModules: Set<ModuleID>
    private let preferences: UserDefaults
    private static let disabledKey = "disabledLauncherModules"
    private var disabledModules: Set<ModuleID>
    let availabilityChanges = PassthroughSubject<Void, Never>()
    private var launcherVisible = false
    private var servicesRunning = false
    private(set) lazy var searchUpdates: AnyPublisher<Void, Never> =
        Publishers.MergeMany([updates(\.searchUpdates), availabilityChanges.eraseToAnyPublisher(), registrationUpdates])
            .eraseToAnyPublisher()
    private(set) lazy var presentationUpdates: AnyPublisher<Void, Never> =
        updates(\.presentationUpdates).receive(on: DispatchQueue.main).eraseToAnyPublisher()

    init(modules: [LauncherModule], preferences: UserDefaults = .standard,
         commandEnabled: @escaping (CommandID) -> Bool = { _ in true }) throws {
        self.commandEnabled = commandEnabled
        self.modules = modules
        self.preferences = preferences
        disableableModules = Set(modules.filter(\.canDisable).map(\.id))
        disabledModules = Set((preferences.stringArray(forKey: Self.disabledKey) ?? []).map(ModuleID.init(rawValue:)))
        _ = try LauncherModuleCatalog(modules: modules.map {
            LauncherModuleDeclaration(id: $0.id, commands: $0.commands.map(\.declaration),
                                      pages: $0.pages.map(\.id), settingsPages: $0.settings.map(\.id),
                                      providers: $0.providers.map(\.namespace))
        })
        moduleRegistrations = Dictionary(uniqueKeysWithValues: modules.compactMap { module in
            module.registration.map { (module.id, $0) }
        })
        registrationUpdates = Publishers.MergeMany(modules.compactMap { $0.registration?.updates })
            .receive(on: DispatchQueue.main).eraseToAnyPublisher()
        registeredShortcutGroups = modules.compactMap { module in
            guard !module.commands.isEmpty || module.dynamicCommandSettings != nil || module.shortcutSettingsBinding != nil
            else { return nil }
            return ShortcutCommandGroup(id: module.id, title: module.displayTitle,
                                        symbol: module.displaySymbol, commands: module.commands,
                                        dynamicCommands: module.dynamicCommandSettings, binding: module.shortcutSettingsBinding)
        }
        commandSettingsUpdates = modules.flatMap(\.shortcutSettingsUpdates)
        commands = modules.flatMap { module in module.commands.map { Owned(module: module.id, value: $0) } }
        byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.value.declaration.id, $0) })
        providers = modules.flatMap { module in module.providers.map { Owned(module: module.id, value: $0) } }
        pages = Dictionary(uniqueKeysWithValues: modules.flatMap { module in
            module.pages.map { ($0.id, Owned(module: module.id, value: $0)) }
        })
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
        settingsOrigins = Dictionary(uniqueKeysWithValues: modules.flatMap { module in
            module.settings.map { ($0.id, module.origin) }
        })
        registeredSettings = modules.flatMap { module in module.settings.map { Owned(module: module.id, value: $0) } }
            .sorted { $0.value.order < $1.value.order }
    }

    private func updates(_ key: KeyPath<LauncherModule, [AnyPublisher<Void, Never>]>) -> AnyPublisher<Void, Never> {
        let streams = modules.flatMap { module in
            let id = module.id
            return module[keyPath: key].map { stream in
                stream.filter { [weak self] in self?.isModuleEnabled(id) == true }.eraseToAnyPublisher()
            }
        }
        return Publishers.MergeMany(streams).eraseToAnyPublisher()
    }

    func module(forSettingsPage id: String) -> ModuleID? {
        registeredSettings.first { $0.value.id == id && disableableModules.contains($0.module) }?.module
    }

    func module(forPage id: PageID) -> ModuleID? { pages[id]?.module }

    func isCommandModuleEnabled(_ id: CommandID) -> Bool {
        moduleOwningCommand(id).map { isModuleEnabled($0) } ?? true
    }

    @discardableResult
    func setModuleEnabled(_ id: ModuleID, _ enabled: Bool) -> Bool {
        guard let module = modules.first(where: { $0.id == id && $0.canDisable }),
              enabled == disabledModules.contains(id) else { return false }
        if enabled { disabledModules.remove(id) } else { disabledModules.insert(id) }
        preferences.set(disabledModules.map(\.rawValue).sorted(), forKey: Self.disabledKey)
        if servicesRunning {
            if enabled {
                module.services.forEach { ($0.resume ?? $0.start)() }
                if launcherVisible { module.launcherShown?() }
            } else {
                module.services.reversed().forEach { $0.stop() }
            }
        }
        availabilityChanges.send()
        return true
    }

    func shortcutSettingsUpdates() -> [AnyPublisher<Void, Never>] {
        commandSettingsUpdates + [registrationUpdates] +
            registeredShortcutGroups.flatMap { $0.dynamicCommands?.updates() ?? [] }
    }

    func launcherShown() {
        launcherVisible = true
        for module in modules where isModuleEnabled(module.id) { module.launcherShown?() }
    }
    func launcherHidden() {
        launcherVisible = false
        for module in modules where isModuleEnabled(module.id) { module.launcherHidden?() }
    }
    func applicationFocused(_ app: NSRunningApplication) {
        guard servicesRunning else { return }
        for module in modules where isModuleEnabled(module.id) { module.applicationFocused?(app) }
    }

    func startServices() {
        guard !servicesRunning else { return }
        servicesRunning = true
        for module in modules where isModuleEnabled(module.id) { module.services.forEach { $0.start() } }
    }
    func stopServices() {
        guard servicesRunning else { return }
        servicesRunning = false
        for module in modules.reversed() where isModuleEnabled(module.id) { module.services.reversed().forEach { $0.stop() } }
    }
    /// Preserve a prior disable from the host when a module supplies its own command preference.
    func migrateDisabledCommands(_ disabled: Set<String>) -> Set<String> {
        var remaining = disabled
        for id in disabled {
            guard let preference = byID[CommandID(rawValue: id)]?.value.settingsEnabled else { continue }
            if preference.wrappedValue { preference.wrappedValue = false }
            remaining.remove(id)
        }
        return remaining
    }

    func declaration(_ id: CommandID) -> LauncherCommandDeclaration? {
        guard let command = byID[id], isModulePresent(command.module) else { return nil }
        return command.value.declaration
    }

    func page(_ id: PageID, includingInactive: Bool = false) -> LauncherPage? {
        guard let page = pages[id], includingInactive || isModuleEnabled(page.module) else { return nil }
        return page.value
    }

    func moduleOwningCommand(_ id: CommandID) -> ModuleID? {
        byID[id]?.module ?? provider(owning: id)?.module
    }

    private func isModulePresent(_ id: ModuleID) -> Bool {
        moduleRegistrations[id]?.isPresent() ?? true
    }

    func isModuleEnabled(_ id: ModuleID) -> Bool {
        isModulePresent(id) && (moduleRegistrations[id]?.isEnabled() ?? true) &&
            (!disableableModules.contains(id) || !disabledModules.contains(id))
    }

    private func isCommandEnabled(_ id: CommandID, in module: ModuleID) -> Bool {
        isModuleEnabled(module) && commandEnabled(id)
    }

    func permissionNeeded(for id: CommandID) -> PermissionFeature? {
        let permission: PermissionFeature?
        if let owned = byID[id] {
            guard isCommandEnabled(owned) else { return nil }
            permission = owned.value.permission
        } else if let owned = provider(owning: id) {
            guard isCommandEnabled(id, in: owned.module), owned.value.available(id) else { return nil }
            permission = owned.value.permission(id)
        } else {
            return nil
        }
        return permissionAllowsExecution(permission) ? nil : permission
    }

    private func isCommandEnabled(_ command: Owned<LauncherModule.Command>) -> Bool {
        let value = command.value
        return isCommandEnabled(value.declaration.id, in: command.module) &&
            value.settingsEnabled?.wrappedValue != false && value.available()
    }

    private func provider(owning id: CommandID) -> Owned<LauncherModule.Provider>? {
        providers.first { $0.value.namespace.contains(id) }
    }

    private func provider(for entry: Entry) -> LauncherModule.Provider? {
        guard let provider = provider(owning: entry.commandID), isModuleEnabled(provider.module) else { return nil }
        return provider.value
    }

    private func permissionAllowsExecution(_ permission: PermissionFeature?) -> Bool {
        guard let permission else { return true }
        permission.recheck()
        return permission.available
    }

    func actions(for entry: Entry) -> [LauncherAction]? { provider(for: entry)?.actions?(entry) }
    func primaryTitle(for entry: Entry) -> String? { provider(for: entry)?.primaryTitle?(entry) }
    func displayDetail(for entry: Entry) -> String? { provider(for: entry)?.displayDetail?(entry) }

    func detailView(for entry: Entry) -> AnyView? { provider(for: entry)?.detailView?(entry) }

    func artwork(for entry: Entry) -> AnyView? {
        if let artwork = provider(for: entry)?.artwork?(entry) { return artwork }
        let item = declaration(entry.commandID)
        return ModuleArtwork.command(entry.commandID, settingsPage: item?.settingsPage,
                                     moduleID: byID[entry.commandID]?.module)
            .map { AnyView(ModuleArtworkImage(image: $0)) }
    }

    func candidates(for input: LauncherCommandSearch.Input) -> [Entry] {
        commands.compactMap { owned in
            let command = owned.value
            let item = command.declaration
            guard input.namespace?.contains(item.id) != false,
                  isCommandEnabled(owned),
                  command.permission?.available != false else { return nil }
            return Entry(id: item.id.rawValue, commandID: item.id, name: item.title,
                         detail: command.detail?() ?? item.detail, symbol: item.symbol, aliases: item.keywords)
        } + providers.flatMap { owned in
            let provider = owned.value
            guard isModuleEnabled(owned.module), input.namespace?.overlaps(provider.namespace) != false else { return [Entry]() }
            return provider.entries(input).filter { entry in
                let id = entry.commandID
                return provider.namespace.contains(id) && input.namespace?.contains(id) != false &&
                    isCommandEnabled(id, in: owned.module) && provider.available(id) && provider.permission(id)?.available != false
            }
        }
    }

    /// Resolve and run at the point of invocation. Providers consult their current records here,
    /// so a menu or queued callback cannot retain a handler for a removed command.
    @discardableResult
    func invoke(_ id: CommandID, origin: LauncherCommandOrigin, arguments: [String] = [],
                navigate: (LauncherCommandDeclaration.Destination) -> Void) -> Bool {
        guard let action = currentAction(for: id, origin: origin, arguments: arguments) else { return false }
        action.perform()
        if let destination = action.destination { navigate(destination) }
        return true
    }

    /// Legacy callback API. Production callers invoke directly to avoid a separate resolution pass.
    func resolve(_ id: CommandID, origin: LauncherCommandOrigin,
                 navigate: @escaping (LauncherCommandDeclaration.Destination) -> Void) -> (() -> Void)? {
        guard let module = moduleOwningCommand(id),
              currentAction(for: id, origin: origin, arguments: []) != nil else { return nil }
        let generation = moduleRegistrations[module]?.generation()
        return { [weak self] in
            guard let self, self.moduleRegistrations[module]?.generation() == generation else { return }
            self.invoke(id, origin: origin, navigate: navigate)
        }
    }

    private func currentAction(for id: CommandID, origin: LauncherCommandOrigin, arguments: [String])
        -> (perform: () -> Void, destination: LauncherCommandDeclaration.Destination?)? {
        if let owned = byID[id] {
            let command = owned.value
            guard isCommandEnabled(owned),
                  command.arguments?.count.contains(arguments.count) ?? arguments.isEmpty,
                  permissionAllowsExecution(command.permission) else { return nil }
            let perform = {
                if let handler = command.arguments { handler.execute(origin, arguments) }
                else { command.execute(origin) }
            }
            let destination = command.declaration.destination
            return (perform, destination == .action ? nil : destination)
        }
        guard arguments.isEmpty, let owned = provider(owning: id), isCommandEnabled(id, in: owned.module),
              owned.value.available(id), permissionAllowsExecution(owned.value.permission(id)),
              let action = owned.value.resolve(id, origin) else { return nil }
        return (action, nil)
    }
}
