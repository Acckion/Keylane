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
    var fallbackQuery: String?
    var isFallback: Bool { fallbackQuery != nil }
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
    var shortcut: KeyboardShortcut? = nil
    var displayedKeys: [String] { shortcut?.launcherKeycaps ?? [] }
    var artwork: NSImage? = nil
    var value: String? = nil
    var submenu: Submenu?
    var group = 0
    var enabled = true
    var destructive = false
    var perform: () -> Void = {}

    @discardableResult func invoke() -> Bool {
        guard enabled else { return false }
        perform()
        return true
    }
}

extension KeyboardShortcut {
    var launcherKeycaps: [String] {
        let modifierLabels: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let key: String
        switch self.key {
        case .return: key = "↩"
        case .escape: key = "esc"
        default: key = String(self.key.character).uppercased()
        }
        return modifierLabels.compactMap { modifiers.contains($0.0) ? $0.1 : nil } + [key]
    }
}

/// Owns work for one active page visit, independently of persistent module services.
final class LauncherPageSession {
    private(set) var ended = false
    private var cleanup: [() -> Void] = []
    func onEnd(_ action: @escaping () -> Void) {
        if ended { action() } else { cleanup.append(action) }
    }
    func own(_ task: Task<Void, Never>) { onEnd { task.cancel() } }
    @discardableResult func publish(_ action: () -> Void) -> Bool {
        guard !ended else { return false }
        action(); return true
    }
    func end() {
        guard !ended else { return }
        ended = true
        let actions = cleanup; cleanup.removeAll()
        actions.reversed().forEach { $0() }
    }
}

struct LauncherPage {
    /// Produced together from current selection/state, never retained across page visits.
    struct ActionSnapshot {
        let primary: LauncherAction
        var items: [LauncherAction] = []
        var footerTitle: String?
        var menuActions: [LauncherAction] {
            items.map { $0.id == primary.id ? primary : $0 }
        }
    }

    enum ContentPlacement {
        case inset
        case underChrome
        case readingDetail
        case fileResults
        case form
        case conversation
    }

    enum ReturnKey: CaseIterable {
        case plain, command, option

        var modifiers: EventModifiers {
            switch self {
            case .plain: []
            case .command: .command
            case .option: .option
            }
        }

        var shortcut: KeyboardShortcut { .init(.return, modifiers: modifiers) }
    }

    struct ReturnBindings {
        struct Alternate {
            var dismissMenu = false
            let actionID: () -> String
            init(dismissMenu: Bool = false, actionID: @escaping () -> String) {
                self.dismissMenu = dismissMenu; self.actionID = actionID
            }
        }

        var primary: ReturnKey?
        var alternates: [ReturnKey: Alternate] = [:]

        func contains(_ key: ReturnKey) -> Bool { key == primary || alternates[key] != nil }

        func reserves(_ shortcut: KeyboardShortcut) -> Bool {
            guard shortcut.key == .return else { return false }
            return ReturnKey.allCases.contains { $0.modifiers == shortcut.modifiers && contains($0) }
        }
    }

    let id: PageID
    let placeholder: String
    var badge: (title: String, symbol: String)?
    var actionTitle: String?
    var contentPlacement: ContentPlacement = .inset
    var content: (() -> AnyView)?
    var queryChanged: (String) -> Void = { _ in }
    var leave: () -> Void = {}
    var keepsStateWhenHidden = false
    var parent: PageID?
    // A custom return action for pages that can be entered from another window or multiple routes.
    var back: (() -> Void)?
    var move: ((Int) -> Void)?
    var submit: (() -> Void)?
    var returnBindings = ReturnBindings()
    var actionSelectionID: (() -> String?)?
    var actionContextTitle: (() -> String?)?
    var primaryTitle: (() -> String)?
    var primaryEnabled: (() -> Bool)?
    var actions: (() -> [LauncherAction])?
    var updates: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    enum HeaderInput {
        case searchField
        case custom(() -> AnyView)
        case none
    }
    var headerInput: HeaderInput = .searchField
    var enter: ((String) -> String?)?
    var entryDraft: (() -> String)?
    var consumesEntryQuery = false
    var resume: (() -> Void)?
    var moveHorizontal: ((Int) -> Void)?
    var navigateWhileTyping = false
    var typeFilterWidth: CGFloat?
    var typeFilter: ((Binding<Bool>) -> AnyView)?
    var badgeTitle: (() -> String)?
    var badgeActions: (() -> [LauncherAction])?
    var releasePreview: (() -> Void)?
    var actionShortcutsEnabled = false
    var loading: AnyPublisher<Bool, Never>?
    var fullBleed = false
    var actionSnapshot: (() -> ActionSnapshot)?
    var selectionActions: ((Entry?) -> ActionSnapshot)?
    var startSession: ((LauncherPageSession) -> Void)?
    var resolvedActions: [LauncherAction] { actionSnapshot?().menuActions ?? actions?() ?? [] }
    func action(for key: ReturnKey, selection: Entry? = nil) -> LauncherAction? {
        guard let binding = returnBindings.alternates[key] else { return nil }
        let id = binding.actionID()
        let items = selectionActions.map { $0(selection).menuActions } ?? resolvedActions
        return items.first { $0.id == id }
    }
}

struct SettingsTitlebarContribution {
    let title: String
    var help: String?
    let enabled: Binding<Bool>
    let updates: AnyPublisher<Bool, Never>
    var searchItem: SettingsItem?
    var permissionStatus: AnyPublisher<SettingsPermissionStatus, Never>?
    var openPrivacySettings: (() -> Void)?
    var requestEnable: ((@escaping (Bool) -> Void) -> Void)?
    var recheckPermission: (() -> Void)?
}

struct SettingsToolbarMenu {
    let title: String
    let symbol: String
    let content: (_ dismiss: @escaping () -> Void) -> AnyView
}

struct LauncherSettingsPage: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let subtitle: String
    let order: Int
    let items: [SettingsItem]
    var parentID: String? = nil
    var titlebar: SettingsTitlebarContribution?
    var trailingToolbar: (() -> AnyView)?
    var toolbarMenu: SettingsToolbarMenu?
    var centeredHeader = false
    var guideURL: URL? = nil
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
            let matches = pages.filter { $0.parentID == nil && (origins[$0.id] ?? .builtInExtension) == origin }
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
        var acceptsFallbackQuery = false
        var fallbackAvailable: () -> Bool = { true }
        var isAICommand = false
        var isInternal = false
        var aiExecute: ((LauncherCommandOrigin, AIActionSource?) -> Void)?
        var execute: (LauncherCommandOrigin) -> Void = { _ in }
        var arguments: Arguments?
    }
    struct Provider {
        struct Fallback {
            let entries: () -> [Entry]
            let resolve: (CommandID, String) -> (() -> Void)?
        }

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
        var fallback: Fallback?
        var isAICommand = false
    }

    /// Runtime-discovered modules expose their current presence from validated in-memory metadata.
    /// Built-in modules are always present; command and permission state are evaluated separately.
    struct Registration {
        // Publish on the main thread after updating all three snapshot fields.
        // Advance generation for each replacement, including replacement with the same IDs.
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
    var aiActions: [AIActionDefinition] = []
    var providers: [Provider] = []
    var pages: [LauncherPage] = []
    var settings: [LauncherSettingsPage] = []
    var services: [Service] = []
    var aiTools: [AIToolRegistration] = []
    var aiContexts: [AIContextRegistration] = []
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
    func withAIContexts(_ contexts: [AIContextRegistration]) -> Self {
        var copy = self; copy.aiContexts = contexts; return copy
    }
    func withAITools(_ tools: [AIToolRegistration]) -> Self {
        var copy = self; copy.aiTools = tools; return copy
    }
}

extension LauncherModule {
    var displayTitle: String { title ?? settings.first?.title ?? commands.first?.declaration.title ?? id.rawValue }
    var displaySymbol: String { symbol ?? settings.first?.symbol ?? commands.first?.declaration.symbol ?? "puzzlepiece.extension" }
}

/// Modules supply a lazy catalog and a list that uses the shared command settings rows.
struct DynamicCommandSettings {
    typealias Matches = (_ title: String, _ commandID: String, _ aliasKey: String?) -> Bool
    let updates: () -> [AnyPublisher<Void, Never>]
    let commandNames: () -> [ShortcutCommandName]
    let matchingList: (_ matches: Matches?) -> ((_ showsColumns: Bool) -> AnyView)?
}

struct ShortcutCommandName: Identifiable {
    let id: String
    let title: String
    var aliasKey: String? = nil
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
    struct Activation: Equatable {
        let id = UUID()
        let generation: UInt64
    }

    private struct Owned<Value> {
        let module: ModuleID
        let value: Value
    }

    /// All declaration indexes are validated before becoming visible together.
    private struct CatalogSnapshot {
        let moduleIDs: Set<ModuleID>
        let registeredShortcutGroups: [ShortcutCommandGroup]
        let commandSettingsUpdates: [AnyPublisher<Void, Never>]
        let commands: [Owned<LauncherModule.Command>]
        let byID: [CommandID: Owned<LauncherModule.Command>]
        let providers: [Owned<LauncherModule.Provider>]
        let moduleRegistrations: [ModuleID: LauncherModule.Registration]
        let pages: [PageID: Owned<LauncherPage>]
        let registeredSettings: [Owned<LauncherSettingsPage>]
        let settingsOrigins: [String: LauncherModuleOrigin]
        let modules: [LauncherModule]
        let disableableModules: Set<ModuleID>
        init(modules: [LauncherModule]) throws {
            let contextIDs = modules.flatMap(\.aiContexts).map(\.id)
            guard contextIDs.allSatisfy({ !$0.isEmpty }), Set(contextIDs).count == contextIDs.count else { throw AIActionError.invalidDefinition }
            _ = try AIToolCatalog(modules.flatMap(\.aiTools).map(\.definition))
            self.modules = modules
            moduleIDs = Set(modules.map(\.id))
            disableableModules = Set(modules.filter(\.canDisable).map(\.id))
            _ = try LauncherModuleCatalog(modules: modules.map {
                LauncherModuleDeclaration(id: $0.id, commands: $0.commands.map(\.declaration),
                                          pages: $0.pages.map(\.id), settingsPages: $0.settings.map(\.id),
                                          providers: $0.providers.map(\.namespace))
            })
            for module in modules {
                guard Set(module.aiActions.map(\.commandID)).count == module.aiActions.count else { throw AIActionError.invalidDefinition }
                for definition in module.aiActions {
                    try definition.validate()
                    guard module.commands.contains(where: { $0.declaration.id == definition.commandID }) else { throw AIActionError.invalidDefinition }
                    if let destination = definition.resultDestination {
                        guard module.commands.contains(where: { $0.declaration.id == destination.commandID && $0.arguments?.count.contains(1) == true }) else { throw AIActionError.invalidDefinition }
                    }
                }
            }
            moduleRegistrations = Dictionary(uniqueKeysWithValues: modules.compactMap { module in
                module.registration.map { (module.id, $0) }
            })
            registeredShortcutGroups = modules.compactMap { module in
                guard module.commands.contains(where: { !$0.isInternal }) || module.dynamicCommandSettings != nil || module.shortcutSettingsBinding != nil
                else { return nil }
                return ShortcutCommandGroup(id: module.id, title: module.displayTitle,
                                            symbol: module.displaySymbol, commands: module.commands.filter { !$0.isInternal },
                                            dynamicCommands: module.dynamicCommandSettings, binding: module.shortcutSettingsBinding)
            }
            commandSettingsUpdates = modules.flatMap(\.shortcutSettingsUpdates)
            commands = modules.flatMap { module in module.commands.map { Owned(module: module.id, value: $0) } }
            byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.value.declaration.id, $0) })
            providers = modules.flatMap { module in module.providers.map { Owned(module: module.id, value: $0) } }
            pages = Dictionary(uniqueKeysWithValues: modules.flatMap { module in
                module.pages.map { ($0.id, Owned(module: module.id, value: $0)) }
            })
            let pageIDs = Set(pages.keys)
            for page in modules.flatMap(\.pages) {
                if let parent = page.parent, parent != .root, !pageIDs.contains(parent) {
                    throw CatalogUpdateError.missingParent(page.id.rawValue, parent.rawValue)
                }
            }
            let settingsPages = modules.flatMap(\.settings).sorted { $0.order < $1.order }
            let settingIDs = Set(settingsPages.map(\.id))
            for page in settingsPages {
                if let parent = page.parentID, !settingIDs.contains(parent) {
                    throw CatalogUpdateError.missingParent(page.id, parent)
                }
            }
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
    }
    private var catalog: CatalogSnapshot
    private let catalogChanges = CurrentValueSubject<UInt64, Never>(0)
    var catalogRevision: UInt64 { catalogChanges.value }
    private var updatingCatalog = false
    private var pendingRegistrationChanges: Set<ModuleID> = []
    private var pendingRegistrationRevocations: Set<ModuleID> = []
    private var drainingRegistrationChanges = false

    private var registeredShortcutGroups: [ShortcutCommandGroup] { catalog.registeredShortcutGroups }
    var shortcutCommandGroups: [ShortcutCommandGroup] {
        registeredShortcutGroups.filter { isModulePresent($0.id) }
    }

    private var commandSettingsUpdates: [AnyPublisher<Void, Never>] { catalog.commandSettingsUpdates }
    private var commands: [Owned<LauncherModule.Command>] { catalog.commands }
    private let commandEnabled: (CommandID) -> Bool
    private var byID: [CommandID: Owned<LauncherModule.Command>] { catalog.byID }
    private var providers: [Owned<LauncherModule.Provider>] { catalog.providers }
    private var moduleRegistrations: [ModuleID: LauncherModule.Registration] { catalog.moduleRegistrations }
    private var pages: [PageID: Owned<LauncherPage>] { catalog.pages }
    private var registeredSettings: [Owned<LauncherSettingsPage>] { catalog.registeredSettings }
    private var settingsOrigins: [String: LauncherModuleOrigin] { catalog.settingsOrigins }
    private let registrationChanges = PassthroughSubject<Void, Never>()
    private let revokedActivations = PassthroughSubject<(module: ModuleID, activation: Activation), Never>()
    var activationRevocations: AnyPublisher<(module: ModuleID, activation: Activation), Never> {
        revokedActivations.eraseToAnyPublisher()
    }
    var registrationUpdates: AnyPublisher<Void, Never> { registrationChanges.eraseToAnyPublisher() }
    private var registrationObservation: AnyCancellable?
    private var activations: [ModuleID: Activation] = [:]
    private var contextGenerations: [ModuleID: UUID] = [:]
    private var contextObservations: [AnyCancellable] = []
    private var toolGenerations: [ModuleID: UUID] = [:]
    private var runningModules: Set<ModuleID> = []
    private var reconcilingModules: Set<ModuleID> = []
    var settingsCatalog: SettingsWindowCatalog {
        SettingsWindowCatalog(pages: registeredSettings.compactMap { isModulePresent($0.module) ? $0.value : nil },
                              origins: settingsOrigins)
    }
    var settings: [LauncherSettingsPage] { settingsCatalog.pages }
    var aiActions: [AIActionDefinition] { modules.filter { isModuleEnabled($0.id) }.flatMap(\.aiActions) }
    private var modules: [LauncherModule] { catalog.modules }
    private var disableableModules: Set<ModuleID> { catalog.disableableModules }
    private let preferences: UserDefaults
    static let disabledModulesPreferenceKey = "disabledLauncherModules"
    private var disabledModules: Set<ModuleID>
    let availabilityChanges = PassthroughSubject<Void, Never>()
    private var launcherVisible = false
    private var servicesRunning = false
    /// nil means a host-wide change; module updates retain their owner identity.
    private(set) lazy var searchInvalidations: AnyPublisher<ModuleID?, Never> = {
        let moduleChanges = catalogChanges.map { [weak self] _ -> AnyPublisher<ModuleID?, Never> in
            guard let self else { return Empty().eraseToAnyPublisher() }
            return Publishers.MergeMany(self.modules.flatMap { module in
                module.searchUpdates.map { stream in
                    stream.filter { [weak self] in self?.updatingCatalog == false }
                        .map { Optional(module.id) }.eraseToAnyPublisher()
                }
            }).eraseToAnyPublisher()
        }.switchToLatest().eraseToAnyPublisher()
        return Publishers.MergeMany([moduleChanges,
            availabilityChanges.map { nil as ModuleID? }.eraseToAnyPublisher(),
            registrationUpdates.map { nil as ModuleID? }.eraseToAnyPublisher()]).eraseToAnyPublisher()
    }()
    private(set) lazy var searchUpdates: AnyPublisher<Void, Never> =
        searchInvalidations.map { _ in () }.eraseToAnyPublisher()
    private(set) lazy var presentationUpdates: AnyPublisher<Void, Never> =
        updates(\.presentationUpdates).receive(on: DispatchQueue.main).eraseToAnyPublisher()

    init(modules: [LauncherModule], preferences: UserDefaults = .standard,
         commandEnabled: @escaping (CommandID) -> Bool = { _ in true }) throws {
        self.catalog = try CatalogSnapshot(modules: modules)
        self.commandEnabled = commandEnabled
        self.preferences = preferences
        disabledModules = Set((preferences.stringArray(forKey: Self.disabledModulesPreferenceKey) ?? []).map(ModuleID.init(rawValue:)))
        let registeredModules = modules.filter { $0.registration != nil }
        for module in registeredModules {
            if let generation = enabledGeneration(for: module.id) {
                activations[module.id] = Activation(generation: generation)
            }
        }
        observeRegistrations()
    }

    private func observeRegistrations() {
        contextObservations.removeAll()
        for module in modules {
            for context in module.aiContexts {
                if let changes = context.availabilityUpdates {
                    contextObservations.append(changes.sink { [weak self] available in
                        precondition(Thread.isMainThread)
                        if !available { self?.contextGenerations[module.id] = UUID() }
                    })
                }
            }
        }
        registrationObservation?.cancel()
        registrationObservation = Publishers.MergeMany(modules.compactMap { module in
            module.registration?.updates.map { module }.eraseToAnyPublisher()
        }).sink { [weak self] module in
            precondition(Thread.isMainThread)
            guard let self else { return }
            if self.updatingCatalog {
                self.pendingRegistrationChanges.insert(module.id)
                if let active = self.activations[module.id], active.generation != self.enabledGeneration(for: module.id) {
                    // Preserve transient off/on changes even if final metadata
                    // returns to the same generation before callbacks finish.
                    self.pendingRegistrationRevocations.insert(module.id)
                }
            } else {
                self.registrationChanged(for: module)
            }
        }
    }

    private func updates(_ key: KeyPath<LauncherModule, [AnyPublisher<Void, Never>]>) -> AnyPublisher<Void, Never> {
        catalogChanges.map { [weak self] _ -> AnyPublisher<Void, Never> in
            guard let self else { return Empty().eraseToAnyPublisher() }
            return self.moduleUpdates(key)
        }.switchToLatest().eraseToAnyPublisher()
    }

    private func moduleUpdates(_ key: KeyPath<LauncherModule, [AnyPublisher<Void, Never>]>) -> AnyPublisher<Void, Never> {
        let streams = modules.flatMap { module in
            let id = module.id
            return module[keyPath: key].map { stream in
                stream.filter { [weak self] in self?.updatingCatalog == false && self?.isModuleEnabled(id) == true }.eraseToAnyPublisher()
            }
        }
        return Publishers.MergeMany(streams).eraseToAnyPublisher()
    }

    enum CatalogUpdateError: Error, Equatable {
        case busy
        case requiresRegistration(ModuleID)
        case immutableModule(ModuleID)
        case missingModule(ModuleID)
        case missingParent(String, String)
    }

    /// Native adapters and guest adapters both contribute the same declarations.
    /// Existing application/built-in modules without registration cannot be replaced.
    func install(_ module: LauncherModule) throws {
        precondition(Thread.isMainThread)
        guard !updatingCatalog, !drainingRegistrationChanges, reconcilingModules.isEmpty else { throw CatalogUpdateError.busy }
        guard module.registration != nil else { throw CatalogUpdateError.requiresRegistration(module.id) }
        if let old = modules.first(where: { $0.id == module.id }), old.registration == nil {
            throw CatalogUpdateError.immutableModule(module.id)
        }
        var proposed = modules
        if let index = proposed.firstIndex(where: { $0.id == module.id }) { proposed[index] = module }
        else { proposed.append(module) }
        try commit(proposed, changing: module.id)
    }

    func uninstall(_ id: ModuleID) throws {
        precondition(Thread.isMainThread)
        guard !updatingCatalog, !drainingRegistrationChanges, reconcilingModules.isEmpty else { throw CatalogUpdateError.busy }
        guard let old = modules.first(where: { $0.id == id }) else { throw CatalogUpdateError.missingModule(id) }
        guard old.registration != nil else { throw CatalogUpdateError.immutableModule(id) }
        try commit(modules.filter { $0.id != id }, changing: id)
    }

    private func commit(_ proposed: [LauncherModule], changing id: ModuleID) throws {
        // Preparation runs no service, permission request, page factory or handler.
        let next = try CatalogSnapshot(modules: proposed)
        updatingCatalog = true
        defer { updatingCatalog = false }
        let old = modules.first { $0.id == id }
        if let activation = activations.removeValue(forKey: id) {
            revokedActivations.send((module: id, activation: activation))
        }
        toolGenerations[id] = UUID()
        contextGenerations[id] = UUID()
        if let old { stop(old) }
        catalog = next
        if let generation = enabledGeneration(for: id) {
            activations[id] = Activation(generation: generation)
        }
        observeRegistrations()
        if let installed = modules.first(where: { $0.id == id }) {
            start(installed, notifyVisible: true)
        }
        // Recheck final registration metadata across the subscription handover,
        // as well as events queued by stop/start/show callbacks.
        pendingRegistrationChanges.formUnion(moduleRegistrations.keys)
        drainRegistrationChanges()
        catalogChanges.send(catalogRevision &+ 1)
        drainRegistrationChanges()
        // Publish only stable state, retaining the catalog mutation boundary.
        // Subscribers may update metadata themselves. Coalesce no-op events so
        // such a subscriber cannot turn publication into an endless echo loop.
        var published: [ModuleID: RegistrationState]
        repeat {
            published = registrationStates
            registrationChanges.send()
            drainRegistrationChanges()
        } while registrationStates != published
    }

    private struct RegistrationState: Equatable {
        let present: Bool
        let enabled: Bool
        let generation: UInt64
        let activation: UUID?
    }

    private var registrationStates: [ModuleID: RegistrationState] {
        Dictionary(uniqueKeysWithValues: moduleRegistrations.map { id, registration in
            (id, RegistrationState(present: registration.isPresent(), enabled: registration.isEnabled(),
                                   generation: registration.generation(), activation: activations[id]?.id))
        })
    }

    private func drainRegistrationChanges() {
        guard !drainingRegistrationChanges else { return }
        drainingRegistrationChanges = true
        defer { drainingRegistrationChanges = false }
        while !pendingRegistrationChanges.isEmpty {
            let pending = pendingRegistrationChanges
            pendingRegistrationChanges.removeAll()
            for id in pending.sorted(by: { $0.rawValue < $1.rawValue }) {
                // Resolve against the current snapshot, never a retired module.
                let revoke = pendingRegistrationRevocations.remove(id) != nil
                guard let module = modules.first(where: { $0.id == id && $0.registration != nil }) else { continue }
                if revoke, let activation = activations.removeValue(forKey: id) {
                    revokedActivations.send((module: id, activation: activation))
                    stop(module)
                }
                registrationChanged(for: module, notify: false)
            }
        }
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
        guard !updatingCatalog, let module = modules.first(where: { $0.id == id && $0.canDisable }),
              enabled == disabledModules.contains(id) else { return false }
        toolGenerations[id] = UUID()
        if enabled { disabledModules.remove(id) } else { disabledModules.insert(id) }
        preferences.set(disabledModules.map(\.rawValue).sorted(), forKey: Self.disabledModulesPreferenceKey)
        if module.registration != nil {
            registrationChanged(for: module, resuming: enabled)
        } else if enabled {
            start(module, resuming: true, notifyVisible: true)
        } else {
            stop(module)
        }
        availabilityChanges.send()
        return true
    }

    private func registrationChanged(for module: LauncherModule, resuming: Bool = false, notify: Bool = true) {
        let id = module.id
        guard reconcilingModules.insert(id).inserted else { return }
        while activations[id]?.generation != enabledGeneration(for: id) {
            // Revoke the old activation before any cancellation callbacks run.
            if let activation = activations.removeValue(forKey: id) {
                revokedActivations.send((module: id, activation: activation))
            }
            stop(module)
            if let generation = enabledGeneration(for: id) {
                activations[id] = Activation(generation: generation)
                start(module, resuming: resuming, notifyVisible: true)
            }
        }
        reconcilingModules.remove(id)
        if notify { registrationChanges.send() }
    }

    func canBindFromShortcutKeyboard(_ id: CommandID) -> Bool {
        if id.rawValue == "launcher" { return true }
        if let command = byID[id] {
            return isCommandEnabled(command) && command.value.arguments?.count.contains(0) != false
        }
        guard let provider = provider(owning: id) else { return false }
        return isCommandEnabled(id, in: provider.module) && provider.value.available(id)
    }

    func shortcutSettingsUpdates() -> [AnyPublisher<Void, Never>] {
        let current = catalogChanges.map { [weak self] _ -> AnyPublisher<Void, Never> in
            guard let self else { return Empty().eraseToAnyPublisher() }
            return Publishers.MergeMany(self.commandSettingsUpdates +
                self.registeredShortcutGroups.flatMap { $0.dynamicCommands?.updates() ?? [] })
                .filter { [weak self] in self?.updatingCatalog == false }.eraseToAnyPublisher()
        }.switchToLatest().eraseToAnyPublisher()
        return [current, registrationUpdates]
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
        for module in modules { start(module) }
    }
    func stopServices() {
        guard servicesRunning else { return }
        servicesRunning = false
        for module in modules.reversed() { stop(module) }
    }
    private func start(_ module: LauncherModule, resuming: Bool = false, notifyVisible: Bool = false) {
        guard servicesRunning, isModuleEnabled(module.id), runningModules.insert(module.id).inserted else { return }
        for service in module.services {
            (resuming ? service.resume ?? service.start : service.start)()
        }
        if notifyVisible && launcherVisible { module.launcherShown?() }
    }

    private func stop(_ module: LauncherModule) {
        guard runningModules.remove(module.id) != nil else { return }
        module.services.reversed().forEach { $0.stop() }
    }

    /// Importing a legacy host disable for these commands would mutate a separate preference.
    var independentlyEnabledCommandIDs: Set<String> {
        Set(byID.compactMap { $0.value.value.settingsEnabled == nil ? nil : $0.key.rawValue })
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

    func aiResultDestination(for id: CommandID) -> AIActionDefinition.ResultDestination? {
        guard currentAction(for: id, origin: .menu, arguments: []) != nil,
              let owner = byID[id]?.module else { return nil }
        guard let destination = modules.first(where: { $0.id == owner })?.aiActions.first(where: { $0.commandID == id })?.resultDestination,
              currentAction(for: destination.commandID, origin: .menu, arguments: [""]) != nil else { return nil }
        return destination
    }

    func aiCommands(in moduleID: ModuleID) -> [LauncherModule.Command] {
        guard let module = modules.first(where: { $0.id == moduleID }) else { return [] }
        let ids = Set(module.aiActions.map(\.commandID))
        return module.commands.filter { $0.isAICommand || ids.contains($0.declaration.id) }
    }

    /// Uses the ordinary command catalog and current admission; no second executor.
    func aiCommandEntries() -> [Entry] {
        let input = LauncherCommandSearch.Input(query: "", page: .root, aliases: [:], favorites: [], usage: [:])
        let fixed = commands.filter { owned in
            owned.value.isAICommand || modules.first(where: { $0.id == owned.module })?.aiActions.contains(where: { $0.commandID == owned.value.declaration.id }) == true
        }.compactMap { owned -> Entry? in
            let declaration = owned.value.declaration
            guard currentAction(for: declaration.id, origin: .menu, arguments: []) != nil else { return nil }
            return Entry(id: declaration.id.rawValue, commandID: declaration.id, name: declaration.title,
                         detail: "AI 命令", symbol: declaration.symbol)
        }
        let dynamic = providers.filter { $0.value.isAICommand && isModuleEnabled($0.module) }.flatMap { owned in
            owned.value.entries(input).filter { currentAction(for: $0.commandID, origin: .menu, arguments: []) != nil }
        }
        return fixed + dynamic
    }

    /// A captured source cannot survive disable/re-enable, replacement or uninstallation.
    func guardedAIContextSource(_ source: AIActionSource) -> AIActionSource {
        let module = source.moduleID
        let generation = toolGenerations[module]
        let contextGeneration = contextGenerations[module]
        let activation = activation(for: module)
        let current = { [weak self] in
            guard let self else { return false }
            return self.isModuleEnabled(module) && self.toolGenerations[module] == generation && self.contextGenerations[module] == contextGeneration && self.activation(for: module) == activation
        }
        return AIActionSource(moduleID: module, load: {
            guard current() else { throw AIActionError.unavailable }
            let value = try await source.load()
            try Task.checkCancellation()
            guard current(), try await source.isCurrent(value), current() else { throw AIActionError.staleSource }
            try Task.checkCancellation()
            try value.validate(maximumBytes: 32_000)
            return value
        }, isCurrent: { value in
            guard current(), try await source.isCurrent(value) else { return false }
            return current()
        })
    }

    var availableAIContexts: [AIContextRegistration] {
        modules.filter { isModuleEnabled($0.id) }.flatMap { module in
            module.aiContexts.filter { $0.available() }.map { contribution in
                let generation = toolGenerations[module.id]
                let contextGeneration = contextGenerations[module.id]
                let activation = activation(for: module.id)
                let current = { [weak self] in
                    guard let self else { return false }
                    return self.isModuleEnabled(module.id) && self.toolGenerations[module.id] == generation &&
                        self.contextGenerations[module.id] == contextGeneration && self.activation(for: module.id) == activation && contribution.available()
                }
                return AIContextRegistration(id: contribution.id, title: contribution.title, symbol: contribution.symbol,
                    available: current, search: { [weak self] query in
                        guard current(), let self else { throw AIActionError.unavailable }
                        let rows = try await contribution.search(query)
                        try Task.checkCancellation()
                        guard current() else { throw AIActionError.unavailable }
                        return rows.filter { $0.source.moduleID == module.id }.prefix(100).map { row in
                            let source = self.guardedAIContextSource(row.source)
                            return AIContextCandidate(id: row.id, title: row.title, detail: row.detail,
                                source: AIActionSource(moduleID: module.id, load: {
                                    guard current() else { throw AIActionError.unavailable }
                                    let value = try await source.load()
                                    guard current() else { throw AIActionError.unavailable }
                                    return value
                                }, isCurrent: { value in
                                    guard current(), try await source.isCurrent(value) else { return false }
                                    return current()
                                }))
                        }
                    })
            }
        }
    }

    @MainActor var availableAITools: [AIToolRegistration] {
        modules.flatMap { module in
            module.aiTools.map { contribution in
                var tool = contribution
                let generation = toolGenerations[module.id]
                let activation = activation(for: module.id)
                tool.available = { [weak self] in
                    guard let self, self.isModuleEnabled(module.id), self.toolGenerations[module.id] == generation,
                          self.activation(for: module.id) == activation else { return false }
                    return contribution.available()
                }
                return tool
            }
        }.filter { $0.available() }
    }

    func isModuleEnabled(_ id: ModuleID) -> Bool {
        guard catalog.moduleIDs.contains(id) else { return false }
        guard moduleRegistrations[id] != nil else { return !disabledModules.contains(id) || !disableableModules.contains(id) }
        return activation(for: id) != nil
    }

    private func enabledGeneration(for id: ModuleID) -> UInt64? {
        guard let registration = moduleRegistrations[id], registration.isPresent(), registration.isEnabled(),
              !disabledModules.contains(id) || !disableableModules.contains(id) else { return nil }
        return registration.generation()
    }

    func activation(for id: ModuleID) -> Activation? {
        guard !pendingRegistrationRevocations.contains(id),
              let activation = activations[id], activation.generation == enabledGeneration(for: id) else { return nil }
        return activation
    }

    func activation(forPage id: PageID) -> Activation? {
        module(forPage: id).flatMap { activation(for: $0) }
    }

    func shortcutScope(for id: CommandID) -> ShortcutRegistrationScope {
        if let owner = moduleOwningCommand(id), moduleRegistrations[owner] != nil {
            return activation(for: owner).map { .extensionActivation($0.id) } ?? .unavailable
        }
        // A saved binding can outlive the module that provided it.
        return id.rawValue.hasPrefix("extension:") ? .unavailable : .native
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

    func isRegisteredCommandEnabled(_ id: CommandID) -> Bool {
        byID[id].map { isCommandEnabled($0) } ?? false
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
            guard !command.isInternal, input.namespace?.contains(item.id) != false,
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

    private func fallbackCommandAvailable(_ command: Owned<LauncherModule.Command>) -> Bool {
        guard command.value.acceptsFallbackQuery, command.value.fallbackAvailable(), isCommandEnabled(command),
              command.value.permission?.available != false else { return false }
        if let arguments = command.value.arguments { return arguments.count.contains(1) }
        guard case .page(let page) = command.value.declaration.destination else { return false }
        return self.page(page) != nil
    }

    func fallbackCatalog() -> [Entry] {
        let declared = commands.compactMap { owned -> Entry? in
            guard fallbackCommandAvailable(owned) else { return nil }
            let item = owned.value.declaration
            return Entry(id: item.id.rawValue, commandID: item.id, name: item.title,
                         detail: item.detail, symbol: item.symbol, aliases: item.keywords)
        }
        return declared + providers.flatMap { owned -> [Entry] in
            guard isModuleEnabled(owned.module), let fallback = owned.value.fallback else { return [] }
            return fallback.entries().filter {
                let id = $0.commandID
                return owned.value.namespace.contains(id) && isCommandEnabled(id, in: owned.module)
                    && owned.value.available(id) && owned.value.permission(id)?.available != false
            }
        }
    }

    @discardableResult
    func invokeFallback(_ id: CommandID, query: String,
                        navigate: (LauncherCommandDeclaration.Destination) -> Void) -> Bool {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let command = byID[id] {
            guard fallbackCommandAvailable(command) else { return false }
            return invoke(id, origin: .search, arguments: command.value.arguments == nil ? [] : [query], navigate: navigate)
        }
        guard let owned = provider(owning: id), isCommandEnabled(id, in: owned.module),
              owned.value.available(id), permissionAllowsExecution(owned.value.permission(id)),
              let action = owned.value.fallback?.resolve(id, query) else { return false }
        action()
        return true
    }

    /// Resolve and run at the point of invocation. Providers consult their current records here,
    /// so a menu or queued callback cannot retain a handler for a removed command.
    @discardableResult
    func invoke(_ id: CommandID, origin: LauncherCommandOrigin, arguments: [String] = [], aiSource: AIActionSource? = nil,
                navigate: (LauncherCommandDeclaration.Destination) -> Void) -> Bool {
        guard let action = currentAction(for: id, origin: origin, arguments: arguments) else { return false }
        if let aiSource {
            guard let owned = byID[id], owned.module == aiSource.moduleID,
                  let execute = owned.value.aiExecute else { return false }
            execute(origin, aiSource)
        } else { action.perform() }
        if let destination = action.destination { navigate(destination) }
        return true
    }

    /// Legacy callback API. Production callers invoke directly to avoid a separate resolution pass.
    func resolve(_ id: CommandID, origin: LauncherCommandOrigin,
                 navigate: @escaping (LauncherCommandDeclaration.Destination) -> Void) -> (() -> Void)? {
        guard let module = moduleOwningCommand(id),
              currentAction(for: id, origin: origin, arguments: []) != nil else { return nil }
        let activation = activation(for: module)
        return { [weak self] in
            guard let self, self.activation(for: module) == activation else { return }
            self.invoke(id, origin: origin, navigate: navigate)
        }
    }

    private func currentAction(for id: CommandID, origin: LauncherCommandOrigin, arguments: [String])
        -> (perform: () -> Void, destination: LauncherCommandDeclaration.Destination?)? {
        if let owned = byID[id] {
            let command = owned.value
            guard !owned.value.isInternal || origin == .menu else { return nil }
            guard isCommandEnabled(owned),
                  command.arguments?.count.contains(arguments.count) ?? arguments.isEmpty,
                  permissionAllowsExecution(command.permission) else { return nil }
            let perform = {
                if let handler = command.arguments { handler.execute(origin, arguments) }
                else if let execute = command.aiExecute { execute(origin, nil) }
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
