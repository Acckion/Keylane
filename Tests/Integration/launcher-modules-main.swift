import Combine
import Foundation
import SwiftUI
import KeylaneCore

let pageID = PageID(rawValue: "Clipboard")
let commandID = CommandID(rawValue: "clipboard")
let moduleID = ModuleID(rawValue: "keylane.clipboard")
let command = LauncherCommandDeclaration(id: commandID, title: "剪贴板历史", detail: "", symbol: "clipboard",
                                         keywords: ["clipboard"], destination: .page(pageID), settingsPage: "clipboard")
var enabled = true
var starts = 0
var stops = 0
var views = 0
var destinations: [LauncherCommandDeclaration.Destination] = []
let updates = PassthroughSubject<Void, Never>()
let module = LauncherModule(
    id: moduleID, commands: [.init(declaration: command, available: { enabled })],
    pages: [.init(id: pageID, placeholder: "搜索", content: { views += 1; return AnyView(EmptyView()) })],
    settings: [.init(id: "clipboard", title: "剪贴板", symbol: "clipboard", subtitle: "", order: 0, items: [],
                     content: { views += 1; return AnyView(EmptyView()) })],
    services: [.init(start: { starts += 1 }, stop: { stops += 1 })],
    searchUpdates: [updates.eraseToAnyPublisher()]
)
var shortcutEnabled = true
let registry = try LauncherModuleRegistry(modules: [module], commandEnabled: { _ in shortcutEnabled })
precondition(registry.shortcutCommandGroups.map(\.id) == [moduleID])
precondition(registry.shortcutCommandGroups.first?.commands.map(\.declaration.id) == [commandID])
precondition(starts == 0 && views == 0)
let input = LauncherCommandSearch.Input(query: "clipboard", page: PageID(rawValue: "Commands"),
                                       aliases: ["clipboard": "clipboard"], favorites: ["clipboard"], usage: ["clipboard": 3])
shortcutEnabled = false
precondition(registry.candidates(for: input).isEmpty)
precondition(registry.resolve(commandID, origin: .shortcut, navigate: { _ in }) == nil)
shortcutEnabled = true
let search = LauncherCommandSearch()
let change = registry.searchUpdates.sink { search.invalidate() }
precondition(search.results(for: input, registry: registry).map(\.id) == ["clipboard"])
for origin in [LauncherCommandOrigin.search, .shortcut, .menu] {
    let run = registry.resolve(commandID, origin: origin) { destinations.append($0) }
    precondition(run != nil)
    run?()
}
precondition(destinations == Array(repeating: .page(pageID), count: 3))
enabled = false
updates.send()
precondition(search.results(for: input, registry: registry).isEmpty)
precondition(registry.resolve(commandID, origin: .shortcut, navigate: { _ in }) == nil)
precondition(views == 0)
registry.startServices()
registry.startServices()
registry.stopServices()
registry.stopServices()
precondition(starts == 1 && stops == 1)
withExtendedLifetime(change) {}
print("PASS native module registry: lazy registration, unified dispatch, availability, cache invalidation and service lifecycle")

let localID = CommandID(rawValue: "module-preference")
var locallyEnabled = true
var globalDisabled: Set<String> = [localID.rawValue, "host-only"]
let localPreference = Binding(get: { locallyEnabled }, set: { locallyEnabled = $0 })
let localCommand = LauncherModule.Command(
    declaration: .init(id: localID, title: "Module Preference", detail: "", symbol: "gear", keywords: []),
    settingsEnabled: localPreference,
    available: { localPreference.wrappedValue }
)
let localRegistry = try LauncherModuleRegistry(
    modules: [.init(id: .init(rawValue: "test.preference"), commands: [localCommand])],
    commandEnabled: { !globalDisabled.contains($0.rawValue) }
)
globalDisabled = localRegistry.migrateDisabledCommands(globalDisabled)
precondition(globalDisabled == ["host-only"] && !locallyEnabled)
precondition(localRegistry.candidates(for: input).isEmpty)
let sharedPreference = localRegistry.shortcutCommandGroups[0].commands[0].settingsEnabled!
sharedPreference.wrappedValue = true
precondition(locallyEnabled)
precondition(localRegistry.candidates(for: input).map(\.commandID) == [localID])
precondition(localRegistry.resolve(localID, origin: .shortcut, navigate: { _ in }) != nil)
localPreference.wrappedValue = false
precondition(!sharedPreference.wrappedValue)
precondition(localRegistry.resolve(localID, origin: .menu, navigate: { _ in }) == nil)
precondition(localRegistry.migrateDisabledCommands(globalDisabled) == globalDisabled)
print("PASS shared command preference and legacy disabled-state migration")


let dynamicID = ModuleID(rawValue: "fixture.dynamic-commands")
let dynamicUpdates = PassthroughSubject<Void, Never>()
var catalogReads = 0
var rowBuilds = 0
let dynamicRegistry = try LauncherModuleRegistry(modules: [
    .init(id: dynamicID, title: "Dynamic Commands", dynamicCommandSettings: .init(
        updates: { [dynamicUpdates.eraseToAnyPublisher()] },
        matchingList: { matches in
            catalogReads += 1
            guard matches?("Fixture App", "app:/Fixture.app", "/Fixture.app") != false else { return nil }
            return { _ in rowBuilds += 1; return AnyView(EmptyView()) }
        }
    ))
])
let dynamicGroup = dynamicRegistry.shortcutCommandGroups[0]
precondition(dynamicGroup.id == dynamicID && dynamicGroup.commands.isEmpty)
precondition(catalogReads == 0 && rowBuilds == 0)
var updateCount = 0
let settingsSubscription = Publishers.MergeMany(dynamicRegistry.shortcutSettingsUpdates()).sink { updateCount += 1 }
dynamicUpdates.send()
precondition(updateCount == 1 && catalogReads == 0)
let matchedList = dynamicGroup.dynamicCommands?.matchingList { title, commandID, aliasKey in
    title == "Fixture App" && commandID == "app:/Fixture.app" && aliasKey == "/Fixture.app"
}
precondition(matchedList != nil && catalogReads == 1 && rowBuilds == 0)
_ = matchedList?(true)
precondition(rowBuilds == 1)
precondition(dynamicGroup.dynamicCommands?.matchingList { _, _, _ in false } == nil)
withExtendedLifetime(settingsSubscription) {}
print("PASS dynamic command settings group, settings updates and lazy list construction")


let applications = LauncherSettingsPage(id: "applications", title: "应用程序", symbol: "app", subtitle: "", order: 10,
                                        items: [.applicationScopes, .applicationFavorites], content: { AnyView(EmptyView()) })
let settingsModule = LauncherModule(id: .init(rawValue: "keylane.applications"), settings: [applications])
let settingsRegistry = try LauncherModuleRegistry(modules: [settingsModule, module])
precondition(settingsRegistry.settingsCatalog.pages.map(\.id) == ["clipboard", "applications"])
precondition(settingsRegistry.settingsCatalog.item("favorites") == .applicationFavorites)
precondition(settingsRegistry.settingsCatalog.page("applications")?.items.count == 2)
let hostPage = LauncherSettingsPage(id: "general", title: "通用", symbol: "gear", subtitle: "", order: 99,
                                    items: [], content: { AnyView(EmptyView()) })
let externalPage = LauncherSettingsPage(id: "external", title: "已安装扩展", symbol: "puzzlepiece", subtitle: "",
                                        order: -1, items: [], content: { AnyView(EmptyView()) })
let groupedRegistry = try LauncherModuleRegistry(modules: [
    settingsModule, module,
    .init(id: .init(rawValue: "host"), origin: .application, settings: [hostPage]),
    .init(id: .init(rawValue: "external"), origin: .installedExtension, settings: [externalPage])
])
precondition(groupedRegistry.settingsCatalog.sidebarGroups.map(\.id) == [.application, .builtInExtension, .installedExtension])
precondition(groupedRegistry.settingsCatalog.sidebarGroups.map { $0.pages.map(\.id) } ==
             [["general"], ["clipboard", "applications"], ["external"]])
let invalidPage = LauncherSettingsPage(id: "unrelated", title: "", symbol: "", subtitle: "", order: 0,
                                       items: [.applicationScopes], content: { AnyView(EmptyView()) })
do {
    _ = try LauncherModuleRegistry(modules: [.init(id: .init(rawValue: "invalid"), settings: [invalidPage])])
    preconditionFailure("Settings items must belong to their registered page")
} catch let error as LauncherModuleRegistry.SettingsRegistrationError {
    precondition(error == .wrongPage(item: "scopes", expected: "unrelated"))
}
print("PASS settings catalog lookup, ordering and page ownership")


var unrelatedProviderCalls = 0
let scopedSearch = LauncherCommandSearch()
let scopedRegistry = try LauncherModuleRegistry(modules: [
    module,
    .init(id: .init(rawValue: "fixture.providers"), providers: [
        .init(namespace: .prefix("script:"), entries: { _ in
            [Entry(id: "script:demo", commandID: .init(rawValue: "script:demo"), name: "Demo",
                   detail: "Script", symbol: "terminal")]
        }, resolve: { _, _ in nil }),
        .init(namespace: .prefix("app:"), entries: { _ in unrelatedProviderCalls += 1; return [] }, resolve: { _, _ in nil }),
        .init(namespace: .exact(.init(rawValue: "script-fallback")), entries: { input in
            guard input.page == .root, !input.query.isEmpty else { return [] }
            return [Entry(id: "script-fallback", commandID: .init(rawValue: "script-fallback"),
                          name: "Script fallback", detail: "Script", symbol: "terminal", isFallback: true)]
        }, resolve: { _, _ in nil })
    ])
])
let scriptsInput = LauncherCommandSearch.Input(query: "", page: .root, aliases: [:], favorites: [], usage: [:],
                                              namespace: .prefix("script:"))
precondition(scopedSearch.results(for: scriptsInput, registry: scopedRegistry).map(\.id) == ["script:demo"])
precondition(unrelatedProviderCalls == 0)
print("PASS scoped ranking skips unrelated providers")

let noMatch = "nothing-matches"
let rootFallback = LauncherCommandSearch.Input(query: noMatch, page: .root, aliases: [:], favorites: [], usage: [:])
precondition(scopedSearch.results(for: rootFallback, registry: scopedRegistry).map(\.id) == ["script-fallback"])
let rootMatch = LauncherCommandSearch.Input(query: "Demo", page: .root, aliases: [:], favorites: [], usage: [:])
precondition(scopedSearch.results(for: rootMatch, registry: scopedRegistry).map(\.id) == ["script:demo"])
let scriptsNoMatch = LauncherCommandSearch.Input(query: noMatch, page: .init(rawValue: "SearchScripts"),
                                                aliases: [:], favorites: [], usage: [:], namespace: .prefix("script:"))
precondition(scopedSearch.results(for: scriptsNoMatch, registry: scopedRegistry).isEmpty)
print("PASS root fallback remains available only without matching commands")

let dictionaryID = CommandID(rawValue: "fixture-dictionary")
let scriptID = CommandID(rawValue: "fixture-define-task")
let explicitRankingRegistry = try LauncherModuleRegistry(modules: [
    .init(id: .init(rawValue: "fixture.explicit-ranking"), commands: [
        .init(declaration: .init(id: scriptID, title: "Define a task", detail: "Script",
                                 symbol: "terminal", keywords: []))
    ], providers: [
        .init(namespace: .exact(dictionaryID), entries: { _ in
            [Entry(id: dictionaryID.rawValue, commandID: dictionaryID, name: "a",
                   detail: "Dictionary", symbol: "book.closed", matchScore: 2000)]
        }, resolve: { _, _ in nil })
    ])
])
let dictionaryInput = LauncherCommandSearch.Input(query: "define a", page: .root,
                                                   aliases: [scriptID.rawValue: "define a"], favorites: [scriptID.rawValue],
                                                   usage: [scriptID.rawValue: 100])
precondition(LauncherCommandSearch().results(for: dictionaryInput, registry: explicitRankingRegistry)
    .map(\.commandID) == [dictionaryID, scriptID])
print("PASS explicit dictionary result outranks matching commands")
