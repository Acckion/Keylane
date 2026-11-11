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
    var submenu: Submenu?
    var argumentForm: ArgumentForm?
    var perform: () -> Void = {}
}

struct LauncherPage {
    enum ContentPlacement {
        case inset
        case underChrome
        case fileResults
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
    var primaryTitle: (() -> String)?
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
    var info: (() -> AnyView)?
}

struct LauncherSettingsPage: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let subtitle: String
    let order: Int
    let items: [SettingsItem]
    var titlebar: SettingsTitlebarContribution?
    let content: () -> AnyView
}

struct SettingsWindowCatalog {
    let pages: [LauncherSettingsPage]
    let items: [SettingsItem]
    private let pagesByID: [String: LauncherSettingsPage]
    private let itemsByID: [String: SettingsItem]

    init(pages: [LauncherSettingsPage]) {
        self.pages = pages
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
        var available: () -> Bool = { true }
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
    }

    struct Service {
        let start: () -> Void
        let stop: () -> Void
    }

    let id: ModuleID
    var commands: [Command] = []
    var providers: [Provider] = []
    var pages: [LauncherPage] = []
    var settings: [LauncherSettingsPage] = []
    var services: [Service] = []
    var searchUpdates: [AnyPublisher<Void, Never>] = []
    var launcherShown: (() -> Void)?
    var presentationUpdates: [AnyPublisher<Void, Never>] = []
    var applicationFocused: ((NSRunningApplication) -> Void)?
}

/// The registry stores native factories and handlers. Validation never runs a
/// handler, constructs a view, or touches a permission-protected service.
final class LauncherModuleRegistry {
    enum SettingsRegistrationError: Error, Equatable {
        case wrongPage(item: String, expected: String)
        case duplicateItem(String)
    }
    private let commands: [LauncherModule.Command]
    private let byID: [CommandID: LauncherModule.Command]
    private let providers: [LauncherModule.Provider]
    private let pages: [PageID: LauncherPage]
    let settingsCatalog: SettingsWindowCatalog
    var settings: [LauncherSettingsPage] { settingsCatalog.pages }
    private let services: [LauncherModule.Service]
    private let launcherShownHandlers: [() -> Void]
    private let applicationFocusedHandlers: [(NSRunningApplication) -> Void]
    private var servicesRunning = false
    let searchUpdates: AnyPublisher<Void, Never>
    let presentationUpdates: AnyPublisher<Void, Never>

    init(modules: [LauncherModule]) throws {
        _ = try LauncherModuleCatalog(modules: modules.map {
            LauncherModuleDeclaration(id: $0.id, commands: $0.commands.map(\.declaration),
                                      pages: $0.pages.map(\.id), settingsPages: $0.settings.map(\.id),
                                      providers: $0.providers.map(\.namespace))
        })
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
        settingsCatalog = SettingsWindowCatalog(pages: settingsPages)
        services = modules.flatMap(\.services)
        launcherShownHandlers = modules.compactMap(\.launcherShown)
        applicationFocusedHandlers = modules.compactMap(\.applicationFocused)
        presentationUpdates = Publishers.MergeMany(modules.flatMap(\.presentationUpdates))
            .receive(on: DispatchQueue.main).eraseToAnyPublisher()
        searchUpdates = Publishers.MergeMany(modules.flatMap(\.searchUpdates)).eraseToAnyPublisher()
    }

    func launcherShown() { launcherShownHandlers.forEach { $0() } }
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
    func declaration(_ id: CommandID) -> LauncherCommandDeclaration? { byID[id]?.declaration }

    func page(_ id: PageID) -> LauncherPage? { pages[id] }

    private func provider(for entry: Entry) -> LauncherModule.Provider? {
        providers.first { $0.namespace.contains(entry.commandID) }
    }

    func actions(for entry: Entry) -> [LauncherAction]? { provider(for: entry)?.actions?(entry) }
    func primaryTitle(for entry: Entry) -> String? { provider(for: entry)?.primaryTitle?(entry) }
    func displayDetail(for entry: Entry) -> String? { provider(for: entry)?.displayDetail?(entry) }

    func artwork(for entry: Entry) -> AnyView? { provider(for: entry)?.artwork?(entry) }

    func candidates(for input: LauncherCommandSearch.Input) -> [Entry] {
        commands.compactMap { command in
            guard command.available() else { return nil }
            let item = command.declaration
            return Entry(id: item.id.rawValue, commandID: item.id, name: item.title,
                         detail: command.detail?() ?? item.detail, symbol: item.symbol, aliases: item.keywords)
        } + providers.flatMap { provider in
            provider.entries(input).filter { provider.namespace.contains($0.commandID) }
        }
    }

    func resolve(_ id: CommandID, origin: LauncherCommandOrigin,
                 navigate: @escaping (LauncherCommandDeclaration.Destination) -> Void) -> (() -> Void)? {
        if let command = byID[id] {
            guard command.available() else { return nil }
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
