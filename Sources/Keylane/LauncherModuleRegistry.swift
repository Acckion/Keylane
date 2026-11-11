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
}

struct LauncherAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    var keys: [String] = []
    let perform: () -> Void
}

struct LauncherPage {
    let id: PageID
    let placeholder: String
    var badge: (title: String, symbol: String)?
    var actionTitle: String?
    var usesSharedFileResults = false
    var extendsUnderChrome = false
    var content: (() -> AnyView)?
    var queryChanged: (String) -> Void = { _ in }
    var leave: () -> Void = {}
    var move: ((Int) -> Void)?
    var submit: (() -> Void)?
    var shortcutSubmit: (() -> Void)?
    var primaryTitle: (() -> String)?
    var actions: (() -> [LauncherAction])?
    var updates: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
}

struct LauncherSettingsPage: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let subtitle: String
    let order: Int
    let items: [SettingsItem]
    let content: () -> AnyView
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
}

/// The registry stores native factories and handlers. Validation never runs a
/// handler, constructs a view, or touches a permission-protected service.
final class LauncherModuleRegistry {
    private let commands: [LauncherModule.Command]
    private let byID: [CommandID: LauncherModule.Command]
    private let providers: [LauncherModule.Provider]
    private let pages: [PageID: LauncherPage]
    let settings: [LauncherSettingsPage]
    private let services: [LauncherModule.Service]
    private var servicesRunning = false
    let searchUpdates: AnyPublisher<Void, Never>

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
        settings = modules.flatMap(\.settings).sorted { $0.order < $1.order }
        services = modules.flatMap(\.services)
        searchUpdates = Publishers.MergeMany(modules.flatMap(\.searchUpdates)).eraseToAnyPublisher()
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
                switch command.declaration.destination {
                case .action: command.execute(origin)
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
