import AppKit
import Carbon
import Combine
import Foundation
import SwiftUI
import KeylaneCore

let formReturn = LauncherPage.ReturnBindings(primary: .command)
precondition(formReturn.reserves(.init(.return, modifiers: .command)))
precondition(!formReturn.reserves(.init(.return, modifiers: [])))
precondition(!formReturn.reserves(.init("r", modifiers: .command)))
precondition(LauncherPage.ReturnKey.command.shortcut.launcherKeycaps == ["⌘", "↩"])

let clipboardReturns = LauncherPage.ReturnBindings(alternates: [
    .command: .init(dismissMenu: true) {},
    .option: .init(dismissMenu: true) {}
])
precondition(clipboardReturns.reserves(.init(.return, modifiers: .command)))
precondition(clipboardReturns.reserves(.init(.return, modifiers: .option)))
precondition(!clipboardReturns.reserves(.init(.return, modifiers: [.command, .option])))

let pageID = PageID(rawValue: "Clipboard")
let commandID = CommandID(rawValue: "clipboard")
let moduleID = ModuleID(rawValue: "keylane.clipboard")
let command = LauncherCommandDeclaration(id: commandID, title: "剪贴板历史", detail: "", symbol: "clipboard",
                                         keywords: ["clipboard"], destination: .page(pageID), settingsPage: "clipboard")
var enabled = true
let dynamicCommand = CommandID(rawValue: "fixture:dynamic")
var dynamicRuns = 0
var starts = 0
var stops = 0
var views = 0
var destinations: [LauncherCommandDeclaration.Destination] = []
let updates = PassthroughSubject<Void, Never>()
let module = LauncherModule(
    id: moduleID, commands: [.init(declaration: command, available: { enabled })],
    providers: [.init(namespace: .prefix("fixture:"), entries: { input in
        guard input.query == "dynamic" else { return [] }
        return [.init(id: dynamicCommand.rawValue, commandID: dynamicCommand, name: "Dynamic", detail: "", symbol: "gear")]
    }, resolve: { id, _ in
        guard id == dynamicCommand else { return nil }
        return { dynamicRuns += 1 }
    })],
    pages: [.init(id: pageID, placeholder: "搜索", content: { views += 1; return AnyView(EmptyView()) })],
    settings: [.init(id: "clipboard", title: "剪贴板", symbol: "clipboard", subtitle: "", order: 0, items: [],
                     content: { views += 1; return AnyView(EmptyView()) })],
    services: [.init(start: { starts += 1 }, stop: { stops += 1 })],
    searchUpdates: [updates.eraseToAnyPublisher()]
)
var shortcutEnabled = true
let extensionSuite = "org.keylane.extension.fixture.\(UUID())"
let extensionPreferences = UserDefaults(suiteName: extensionSuite)!
defer { extensionPreferences.removePersistentDomain(forName: extensionSuite) }
let registry = try LauncherModuleRegistry(modules: [module], preferences: extensionPreferences, commandEnabled: { _ in shortcutEnabled })
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
enabled = true
registry.startServices()
let previouslyResolved = registry.resolve(commandID, origin: .shortcut) { destinations.append($0) }!
let dynamicInput = LauncherCommandSearch.Input(query: "dynamic", page: .root, aliases: [:], favorites: [], usage: [:])
let dynamicAction = registry.resolve(dynamicCommand, origin: .shortcut) { _ in }!
precondition(registry.candidates(for: dynamicInput).contains { $0.commandID == dynamicCommand })
precondition(registry.setModuleEnabled(moduleID, false) && !registry.setModuleEnabled(moduleID, false))
precondition(stops == 2 && registry.page(pageID) == nil)
precondition(registry.candidates(for: input).isEmpty)
precondition(registry.module(forSettingsPage: "clipboard") == moduleID)
precondition(registry.shortcutCommandGroups.first?.commands.first?.declaration.id == commandID)
for origin in [LauncherCommandOrigin.search, .shortcut, .menu] {
    precondition(registry.resolve(commandID, origin: origin, navigate: { _ in }) == nil)
}
previouslyResolved()
dynamicAction()
precondition(destinations.count == 3 && dynamicRuns == 0)
precondition(registry.resolve(dynamicCommand, origin: .shortcut) { _ in } == nil)
precondition(!registry.candidates(for: dynamicInput).contains { $0.commandID == dynamicCommand })
let restored = try LauncherModuleRegistry(modules: [module], preferences: extensionPreferences)
restored.startServices()
precondition(!restored.isModuleEnabled(moduleID) && starts == 2)
restored.stopServices()
precondition(stops == 2)
precondition(registry.setModuleEnabled(moduleID, true) && registry.page(pageID) != nil)
precondition(starts == 3 && registry.candidates(for: input).map(\.commandID) == [commandID])
registry.stopServices()
precondition(stops == 3)
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
precondition(localRegistry.independentlyEnabledCommandIDs == [localID.rawValue])
precondition(registry.independentlyEnabledCommandIDs.isEmpty)
var configuration = ConfigurationArchive()
configuration.disabledCommands = [localID.rawValue, "host-only"]
let configurationPlan = try configuration.plan(current: [:], overwrite: true,
                                                excludingCommandStates: localRegistry.independentlyEnabledCommandIDs)
precondition(configurationPlan.changes["disabledLauncherCommands"] as? [String] == ["host-only"])
precondition(locallyEnabled && configurationPlan.omitted == 1)
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
        commandNames: { [.init(id: "app:/Fixture.app", title: "Fixture App", aliasKey: "/Fixture.app")] },
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
let keyboardCommand = dynamicGroup.dynamicCommands?.commandNames().first
precondition(keyboardCommand?.title == "Fixture App" && keyboardCommand?.aliasKey == "/Fixture.app")
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
], preferences: extensionPreferences)
precondition(groupedRegistry.settingsCatalog.sidebarGroups.map(\.id) == [.application, .builtInExtension, .installedExtension])
precondition(groupedRegistry.settingsCatalog.sidebarGroups.map { $0.pages.map(\.id) } ==
             [["general"], ["clipboard", "applications"], ["external"]])
let installedID = ModuleID(rawValue: "external")
let hostID = ModuleID(rawValue: "host")
precondition(groupedRegistry.module(forSettingsPage: "external") == installedID)
precondition(groupedRegistry.module(forSettingsPage: "general") == nil)
precondition(!groupedRegistry.setModuleEnabled(hostID, false) && groupedRegistry.isModuleEnabled(hostID))
precondition(groupedRegistry.setModuleEnabled(installedID, false) && !groupedRegistry.isModuleEnabled(installedID))
precondition(groupedRegistry.setModuleEnabled(installedID, true))
let invalidPage = LauncherSettingsPage(id: "unrelated", title: "", symbol: "", subtitle: "", order: 0,
                                       items: [.applicationScopes], content: { AnyView(EmptyView()) })
do {
    _ = try LauncherModuleRegistry(modules: [.init(id: .init(rawValue: "invalid"), settings: [invalidPage])])
    preconditionFailure("Settings items must belong to their registered page")
} catch let error as LauncherModuleRegistry.SettingsRegistrationError {
    precondition(error == .wrongPage(item: "scopes", expected: "unrelated"))
}
let calendarParent = LauncherSettingsPage(id: "calendar", title: "日历", symbol: "calendar", subtitle: "", order: 0,
                                          items: [], content: { AnyView(EmptyView()) })
let calendarChild = LauncherSettingsPage(id: "calendar-enabled", title: "已启用的日历", symbol: "calendar", subtitle: "", order: 1,
                                         items: [.calendarSelection], parentID: "calendar", content: { AnyView(EmptyView()) })
let calendarSettingsCatalog = SettingsWindowCatalog(pages: [calendarParent, calendarChild])
precondition(calendarSettingsCatalog.sidebarGroups.flatMap(\.pages).map(\.id) == ["calendar"])
precondition(calendarSettingsCatalog.page("calendar-enabled")?.parentID == "calendar")
precondition(calendarSettingsCatalog.item(SettingsItem.calendarSelection.id)?.page == "calendar-enabled")
print("PASS settings catalog lookup, ordering and page ownership")


var unrelatedProviderCalls = 0
var receivedFallbackQuery: String?
var scriptEnabled = true
let fallbackScriptID = CommandID(rawValue: "script:demo")
let fallbackScript = Entry(id: fallbackScriptID.rawValue, commandID: fallbackScriptID, name: "Demo",
                           detail: "Script", symbol: "terminal")
let scopedSearch = LauncherCommandSearch()
let scopedRegistry = try LauncherModuleRegistry(modules: [
    module,
    .init(id: .init(rawValue: "fixture.providers"), providers: [
        .init(namespace: .prefix("script:"), entries: { _ in [fallbackScript] },
              resolve: { _, _ in nil }, available: { _ in scriptEnabled },
              fallback: .init(entries: { [fallbackScript] }, resolve: { id, query in
                  guard id == fallbackScriptID else { return nil }
                  return { receivedFallbackQuery = query }
              })),
        .init(namespace: .prefix("app:"), entries: { _ in unrelatedProviderCalls += 1; return [] }, resolve: { _, _ in nil })
    ]),
    .init(id: .init(rawValue: "fixture.fallback-page"), commands: [
        .init(declaration: .init(id: .init(rawValue: "fixture-lookup"), title: "Lookup",
                                 detail: "", symbol: "book", keywords: [], destination: .page(.init(rawValue: "Lookup"))),
              acceptsFallbackQuery: true)
    ], pages: [.init(id: .init(rawValue: "Lookup"), placeholder: "Search")])
], preferences: extensionPreferences, commandEnabled: { _ in true })
let scriptsInput = LauncherCommandSearch.Input(query: "", page: .root, aliases: [:], favorites: [], usage: [:],
                                              namespace: .prefix("script:"))
precondition(scopedSearch.results(for: scriptsInput, registry: scopedRegistry).map(\.id) == ["script:demo"])
precondition(unrelatedProviderCalls == 0)
print("PASS scoped ranking skips unrelated providers")

let noMatch = "  nothing-matches 测试 "
let fallbackIDs = ["fixture-lookup", "script:demo"]
let defaultFallback = LauncherCommandSearch.Input(query: noMatch, page: .root, aliases: [:], favorites: [], usage: [:])
precondition(scopedSearch.results(for: defaultFallback, registry: scopedRegistry).map(\.id) == fallbackIDs)
var preferenceFallback = defaultFallback
extensionPreferences.set("script:demo", forKey: "scriptCommands.fallback")
preferenceFallback.fallbackOrder = FallbackCommandOrder(preferences: extensionPreferences)
precondition(scopedSearch.results(for: preferenceFallback, registry: scopedRegistry).map(\.id) == Array(fallbackIDs.reversed()))
extensionPreferences.set([String](), forKey: FallbackCommandOrder.preferenceKey)
preferenceFallback.fallbackOrder = FallbackCommandOrder(preferences: extensionPreferences)
precondition(scopedSearch.results(for: preferenceFallback, registry: scopedRegistry).isEmpty)
let fallbackOrder = FallbackCommandOrder(custom: ["fixture-lookup", "script:missing", "script:demo"])
var rootFallback = LauncherCommandSearch.Input(query: noMatch, page: .root, aliases: [:], favorites: [], usage: [:],
                                              fallbackOrder: fallbackOrder)
let fallbackRows = scopedSearch.results(for: rootFallback, registry: scopedRegistry)
precondition(fallbackRows.map(\.id) == ["fixture-lookup", "script:demo"])
precondition(fallbackRows.allSatisfy { $0.fallbackQuery == noMatch })
precondition(receivedFallbackQuery == nil)
rootFallback.fallbackOrder.custom?.reverse()
precondition(scopedSearch.results(for: rootFallback, registry: scopedRegistry).map(\.id) == ["script:demo", "fixture-lookup"])
rootFallback.allowsFallback = false
precondition(scopedSearch.results(for: rootFallback, registry: scopedRegistry).isEmpty)
let rootMatch = LauncherCommandSearch.Input(query: "Demo", page: .root, aliases: [:], favorites: [], usage: [:],
                                            fallbackOrder: fallbackOrder)
let matched = scopedSearch.results(for: rootMatch, registry: scopedRegistry)
precondition(matched.map(\.id) == ["script:demo"] && matched.allSatisfy { !$0.isFallback })
let scriptsNoMatch = LauncherCommandSearch.Input(query: noMatch, page: .root, aliases: [:], favorites: [], usage: [:],
                                                namespace: .prefix("script:"), fallbackOrder: fallbackOrder)
precondition(scopedSearch.results(for: scriptsNoMatch, registry: scopedRegistry).isEmpty)
let childNoMatch = LauncherCommandSearch.Input(query: noMatch, page: pageID, aliases: [:], favorites: [], usage: [:],
                                               fallbackOrder: fallbackOrder)
precondition(scopedSearch.results(for: childNoMatch, registry: scopedRegistry).isEmpty)
let blank = LauncherCommandSearch.Input(query: "  ", page: .root, aliases: [:], favorites: [], usage: [:],
                                        fallbackOrder: fallbackOrder)
precondition(scopedSearch.results(for: blank, registry: scopedRegistry).allSatisfy { !$0.isFallback })
precondition(!scopedRegistry.invokeFallback(fallbackScriptID, query: "  ") { _ in preconditionFailure() })
precondition(scopedRegistry.invokeFallback(fallbackScriptID, query: noMatch) { _ in preconditionFailure() })
precondition(receivedFallbackQuery == noMatch)
scriptEnabled = false
precondition(!scopedRegistry.invokeFallback(fallbackScriptID, query: "stale selection") { _ in preconditionFailure() })
precondition(receivedFallbackQuery == noMatch)
scopedSearch.invalidate()
rootFallback.allowsFallback = true
precondition(scopedSearch.results(for: defaultFallback, registry: scopedRegistry).map(\.id) == ["fixture-lookup"])
precondition(scopedSearch.results(for: rootFallback, registry: scopedRegistry).map(\.id) == ["fixture-lookup"])
var fallbackDestination: LauncherCommandDeclaration.Destination?
precondition(scopedRegistry.invokeFallback(.init(rawValue: "fixture-lookup"), query: noMatch) { fallbackDestination = $0 })
precondition(fallbackDestination == .page(.init(rawValue: "Lookup")))
print("PASS root fallback ordering, availability, query forwarding and search scope")

var quickFallbackEnabled = false
var quickCommandEnabled = true
var quickDraft: String?
let quickFixtureID = CommandID(rawValue: "fixture-quick-prompt")
let quickRegistry = try LauncherModuleRegistry(modules: [
    .init(id: .init(rawValue: "fixture.quick-prompt"), commands: [
        .init(declaration: .init(id: quickFixtureID, title: "Quick AI", detail: "", symbol: "sparkles",
                                 keywords: [], destination: .action),
              available: { quickCommandEnabled }, acceptsFallbackQuery: true, fallbackAvailable: { quickFallbackEnabled },
              arguments: .init(count: 0...1) { _, arguments in quickDraft = arguments.first })
    ])
], preferences: extensionPreferences, commandEnabled: { _ in true })
precondition(quickRegistry.fallbackCatalog().isEmpty)
precondition(!quickRegistry.invokeFallback(quickFixtureID, query: noMatch) { _ in preconditionFailure() })
precondition(quickRegistry.invoke(quickFixtureID, origin: .search, arguments: [noMatch]) { _ in preconditionFailure() })
precondition(quickDraft == noMatch, "Tab dispatch keeps the draft independent of fallback settings")
quickFallbackEnabled = true
precondition(quickRegistry.fallbackCatalog().map(\.commandID) == [quickFixtureID])
precondition(quickRegistry.invokeFallback(quickFixtureID, query: "新问题") { _ in preconditionFailure() })
precondition(quickDraft == "新问题")
quickCommandEnabled = false
precondition(!quickRegistry.invoke(quickFixtureID, origin: .search, arguments: [noMatch]) { _ in preconditionFailure() })
precondition(quickRegistry.fallbackCatalog().isEmpty && quickDraft == "新问题")
print("PASS opt-in Quick AI fallback and direct draft dispatch share command admission")

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

let permissionSuite = "org.keylane.permission-activation-test." + UUID().uuidString
let permissionDefaults = UserDefaults(suiteName: permissionSuite)!
defer { permissionDefaults.removePersistentDomain(forName: permissionSuite) }
var systemGrant = false
var requests = 0
var permissionResponse: ((Bool) -> Void)?
let permission = PermissionFeature("enabled", authorization: .init(check: { systemGrant }, request: {
    requests += 1
    permissionResponse = $0
}, guidance: "Fixture permission"), defaults: permissionDefaults)
let gatedID = CommandID(rawValue: "permission-test-calendar")
var opened = 0
let gated = try LauncherModuleRegistry(modules: [
    .init(id: .init(rawValue: "fixture.permission"), commands: [
        .init(declaration: .init(id: gatedID, title: "Calendar Fixture", detail: "Calendar",
                                 symbol: "calendar", keywords: []), permission: permission,
              execute: { _ in opened += 1 })
    ], shortcutSettingsUpdates: [permission.settingsUpdates])
])
var settingsRefreshes = 0
let permissionSettingsSubscription = gated.shortcutSettingsUpdates()[0].sink { settingsRefreshes += 1 }
let emptyPermissionInput = LauncherCommandSearch.Input(query: "", page: .root, aliases: [:], favorites: [], usage: [:])
let permissionInput = LauncherCommandSearch.Input(query: "Calendar Fixture", page: .root, aliases: [:], favorites: [], usage: [:])
precondition(gated.candidates(for: emptyPermissionInput).isEmpty)
precondition(gated.candidates(for: permissionInput).isEmpty)
precondition(gated.resolve(gatedID, origin: .search, navigate: { _ in }) == nil)
precondition(requests == 0 && opened == 0)
func activateFixtureCommand() {
    gated.permissionNeeded(for: gatedID)?.activate { allowed in
        if allowed { gated.resolve(gatedID, origin: .search, navigate: { _ in })?() }
    }
}
activateFixtureCommand()
precondition(settingsRefreshes == 1 && permission.requesting && !permission.enabled)
permissionResponse?(false)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(!permission.enabled && requests == 1 && opened == 0)
precondition(settingsRefreshes == 2 && permission.status.message == "Fixture permission")
withExtendedLifetime(permissionSettingsSubscription) {}
activateFixtureCommand()
systemGrant = true
permissionResponse?(true)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(permission.enabled && requests == 2 && opened == 1)
precondition(gated.candidates(for: permissionInput).map(\.commandID) == [gatedID])
systemGrant = false
permission.recheck()
precondition(gated.resolve(gatedID, origin: .shortcut, navigate: { _ in }) == nil && !permission.enabled)
print("PASS disabled permission commands hidden; authorization and revocation update availability")

let registeredModuleID = ModuleID(rawValue: "fixture.registered")
let registeredCommandID = CommandID(rawValue: "fixture.registered.static")
let dynamicCommandID = CommandID(rawValue: "fixture.registered:dynamic")
let registeredLauncherPageID = PageID(rawValue: "fixture-installed-page")
var pageLeaves = 0
let registeredPage = LauncherSettingsPage(id: "fixture-registered", title: "Registered", symbol: "gear",
                                         subtitle: "", order: 0, items: [], content: { AnyView(EmptyView()) })
var isPresent = false
var moduleEnabled = true
var disabledIDs: Set<CommandID> = []
var providerReads = 0
var resolvedVersion = 0
var installationGeneration: UInt64 = 1
var dynamicPermission: PermissionFeature?
var executions: [String] = []
let registrationChanged = PassthroughSubject<Void, Never>()
let registered = try LauncherModuleRegistry(modules: [
    .init(id: registeredModuleID, origin: .installedExtension, commands: [
        .init(declaration: .init(id: registeredCommandID, title: "Static", detail: "", symbol: "gear", keywords: []),
              arguments: .init(count: 0...1) { _, arguments in executions += arguments.isEmpty ? ["static"] : arguments })
    ], providers: [
        .init(namespace: .prefix("fixture.registered:"), entries: { _ in
            providerReads += 1
            return [.init(id: dynamicCommandID.rawValue, commandID: dynamicCommandID, name: "Dynamic", detail: "", symbol: "gear")]
        }, resolve: { id, _ in
            guard id == dynamicCommandID else { return nil }
            let version = resolvedVersion
            return { executions.append("dynamic:\(version)") }
        }, permission: { _ in dynamicPermission })
    ], pages: [.init(id: registeredLauncherPageID, placeholder: "", leave: { pageLeaves += 1 })],
       settings: [registeredPage], registration: .init(isPresent: { isPresent },
                                                        updates: registrationChanged.eraseToAnyPublisher(),
                                                        isEnabled: { moduleEnabled }, generation: { installationGeneration }))
], commandEnabled: { !disabledIDs.contains($0) })
let registeredSearchInput = LauncherCommandSearch.Input(query: "", page: .root, aliases: [:], favorites: [], usage: [:])
let origins: [LauncherCommandOrigin] = [.search, .shortcut, .menu]
var registrationUpdates = 0
let registrationObservation = registered.searchUpdates.sink { registrationUpdates += 1 }

precondition(registered.moduleOwningCommand(registeredCommandID) == registeredModuleID)
precondition(registered.moduleOwningCommand(dynamicCommandID) == registeredModuleID)
precondition(registered.settingsCatalog.pages.isEmpty && registered.shortcutCommandGroups.isEmpty)
precondition(registered.candidates(for: registeredSearchInput).isEmpty && providerReads == 0)
precondition(registered.page(registeredLauncherPageID) == nil)
for origin in origins {
    precondition(!registered.invoke(dynamicCommandID, origin: origin, navigate: { _ in }))
}
isPresent = true
registrationChanged.send()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(registrationUpdates == 1)
precondition(registered.settingsCatalog.pages.map(\.id) == [registeredPage.id])
precondition(registered.shortcutCommandGroups.map(\.id) == [registeredModuleID] && providerReads == 0)
precondition(registered.candidates(for: registeredSearchInput).map(\.commandID) == [registeredCommandID, dynamicCommandID])
let favoriteSearch = LauncherCommandSearch()
let favoriteIDs = Set(registered.candidates(for: registeredSearchInput).map(\.id))
let requestedFavoriteOrder = registered.candidates(for: registeredSearchInput).map(\.id).reversed()
let orderedFavorites = favoriteSearch.results(for: .init(query: "", page: .root, aliases: [:], favorites: favoriteIDs,
                                                         usage: [:], favoriteOrder: Array(requestedFavoriteOrder)),
                                              registry: registered)
precondition(orderedFavorites.map(\.id) == Array(requestedFavoriteOrder))

let queuedStatic = registered.resolve(registeredCommandID, origin: .menu, navigate: { _ in })!
let queuedDynamic = registered.resolve(dynamicCommandID, origin: .shortcut, navigate: { _ in })!
precondition(registered.page(registeredLauncherPageID) != nil)
moduleEnabled = false
registrationChanged.send()
precondition(registered.page(registeredLauncherPageID) == nil)
registered.page(registeredLauncherPageID, includingInactive: true)?.leave()
precondition(pageLeaves == 1)
queuedStatic()
queuedDynamic()
precondition(executions.isEmpty && registered.candidates(for: registeredSearchInput).isEmpty)
precondition(registered.shortcutCommandGroups.map(\.id) == [registeredModuleID])
moduleEnabled = true
registrationChanged.send()
let currentDynamic = registered.resolve(dynamicCommandID, origin: .shortcut, navigate: { _ in })!
disabledIDs = [registeredCommandID, dynamicCommandID]
queuedStatic()
queuedDynamic()
for origin in origins {
    precondition(!registered.invoke(dynamicCommandID, origin: origin, navigate: { _ in }))
}
precondition(executions.isEmpty && registered.candidates(for: registeredSearchInput).isEmpty)
disabledIDs = []
resolvedVersion = 1
currentDynamic()
precondition(executions == ["dynamic:1"])
installationGeneration += 1
registrationChanged.send()
currentDynamic()
queuedDynamic()
queuedStatic()
precondition(executions == ["dynamic:1"])
dynamicPermission = permission
precondition(registered.permissionNeeded(for: dynamicCommandID) === permission)
for origin in origins {
    precondition(!registered.invoke(dynamicCommandID, origin: origin, navigate: { _ in }))
}
precondition(registered.candidates(for: registeredSearchInput).map(\.commandID) == [registeredCommandID])
precondition(requests == 2)
dynamicPermission = nil
precondition(registered.invoke(registeredCommandID, origin: .menu, arguments: ["preserve original text"], navigate: { _ in }))
precondition(!registered.invoke(registeredCommandID, origin: .menu, arguments: ["too", "many"], navigate: { _ in }))
isPresent = false
registrationChanged.send()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
queuedDynamic()
precondition(registrationUpdates == 5 && registered.settingsCatalog.pages.isEmpty)
precondition(registered.shortcutCommandGroups.isEmpty && executions == ["dynamic:1", "preserve original text"])
withExtendedLifetime(registrationObservation) {}
print("PASS shared command admission, installed catalog visibility, and stale dispatch")

var pastePermissionGranted = false
let pastePermission = PermissionFeature("crossAppPaste.enabled", authorization: .init(
    check: { pastePermissionGranted },
    request: { $0(false) },
    guidance: "Return after granting Accessibility access",
    enableOnReturn: true
), defaults: permissionDefaults)
var activationResults: [Bool] = []
pastePermission.activate { activationResults.append($0) }
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(activationResults == [false] && !pastePermission.available)

pastePermissionGranted = true
NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(pastePermission.available && permissionDefaults.bool(forKey: "crossAppPaste.enabled"))
precondition(pastePermission.status == .init() && activationResults == [false])
print("PASS cross-app paste activates on return after granting Accessibility access")


let lifecycleModuleID = ModuleID(rawValue: "fixture.lifecycle")
let lifecyclePageID = PageID(rawValue: "fixture.lifecycle.page")
let lifecycleCommandID = CommandID(rawValue: "extension:fixture:lifecycle")
let lifecycleEvents = PassthroughSubject<Void, Never>()
var lifecyclePresent = false
var lifecycleReady = false
var lifecycleGeneration: UInt64 = 1
var transitions: [String] = []
let lifecycle = try LauncherModuleRegistry(modules: [
    .init(id: lifecycleModuleID, origin: .installedExtension, commands: [
        .init(declaration: .init(id: lifecycleCommandID, title: "Fixture", detail: "", symbol: "gear",
                                 keywords: [], destination: .page(lifecyclePageID)))
    ], pages: [
        .init(id: lifecyclePageID, placeholder: "", leave: { transitions.append("leave") },
              releasePreview: { transitions.append("release") })
    ], services: [
        .init(start: { transitions.append("start") }, stop: { transitions.append("stop") },
              resume: { transitions.append("resume") })
    ], registration: .init(isPresent: { lifecyclePresent }, updates: lifecycleEvents.eraseToAnyPublisher(),
                           isEnabled: { lifecycleReady }, generation: { lifecycleGeneration }))
], preferences: extensionPreferences)
var revoked: [LauncherModuleRegistry.Activation] = []
let revocation = lifecycle.activationRevocations.sink { event in
    precondition(event.module == lifecycleModuleID && lifecycle.activation(forPage: lifecyclePageID) == nil)
    revoked.append(event.activation)
    precondition(lifecycle.shortcutScope(for: lifecycleCommandID) == .unavailable)
    let departing = lifecycle.page(lifecyclePageID, includingInactive: true)
    departing?.leave()
    departing?.releasePreview?()
}
lifecycle.startServices()
precondition(transitions.isEmpty)
precondition(lifecycle.shortcutScope(for: lifecycleCommandID) == .unavailable)
precondition(lifecycle.shortcutScope(for: .init(rawValue: "extension:fixture:removed")) == .unavailable)
precondition(lifecycle.shortcutScope(for: .init(rawValue: "launcher")) == .native)

lifecyclePresent = true
lifecycleReady = true
lifecycleEvents.send()
let firstActivation = lifecycle.activation(forPage: lifecyclePageID)!
let staleInvocation = lifecycle.resolve(lifecycleCommandID, origin: .shortcut, navigate: { _ in
    preconditionFailure("Revoked command reopened an extension")
})!
precondition(transitions == ["start"])
lifecycleEvents.send()
precondition(lifecycle.activation(forPage: lifecyclePageID) == firstActivation && transitions == ["start"])

// A replacement can publish a new generation with the same PageID and no intermediate snapshot.
lifecycleGeneration += 1
lifecycleEvents.send()
let replacement = lifecycle.activation(forPage: lifecyclePageID)!
precondition(replacement.generation == 2 && replacement.id != firstActivation.id)
precondition(revoked == [firstActivation])
precondition(transitions == ["start", "leave", "release", "stop", "start"])
staleInvocation()
let beforeDisable = lifecycle.resolve(lifecycleCommandID, origin: .menu, navigate: { _ in
    preconditionFailure("Disabling and resuming must revoke queued work for the same artifact")
})!

precondition(lifecycle.setModuleEnabled(lifecycleModuleID, false))
precondition(transitions.suffix(3) == ["leave", "release", "stop"])
precondition(lifecycle.setModuleEnabled(lifecycleModuleID, true))
let resumed = lifecycle.activation(forPage: lifecyclePageID)!
precondition(resumed.generation == replacement.generation && resumed.id != replacement.id)
precondition(transitions.last == "resume" && revoked == [firstActivation, replacement])
beforeDisable()
var reopened = false
precondition(lifecycle.invoke(lifecycleCommandID, origin: .shortcut, navigate: { destination in
    reopened = destination == .page(lifecyclePageID)
}) && reopened)
lifecyclePresent = false
lifecycleReady = false
lifecycleEvents.send()
precondition(transitions.suffix(3) == ["leave", "release", "stop"])
precondition(revoked == [firstActivation, replacement, resumed])
let transitionCount = transitions.count
lifecycle.stopServices()
precondition(transitions.count == transitionCount)

lifecyclePresent = true
lifecycleReady = false
lifecycleGeneration += 1
lifecycleEvents.send()
precondition(lifecycle.activation(forPage: lifecyclePageID) == nil)
lifecycleReady = true
lifecycleEvents.send()
precondition(transitions.count == transitionCount)
lifecycle.startServices()
precondition(transitions.count == transitionCount + 1 && transitions.last == "start")
lifecycle.stopServices()
precondition(transitions.last == "stop")
withExtendedLifetime(revocation) {}
print("PASS installation, same-ID replacement, disable, uninstall and reinstall reconcile services and revoke old callbacks")


if CommandLine.arguments.contains("--verify-system-shortcuts") {
    _ = NSApplication.shared
    let manager = ShortcutManager()
    let nativeAction = "launcher"
    let extensionAction = "extension:fixture:hotkey"
    let nativeShortcut = Shortcut(key: UInt32(kVK_F17), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
    let extensionShortcut = Shortcut(key: UInt32(kVK_F18), modifiers: nativeShortcut.modifiers)
    let saved = [nativeAction: nativeShortcut, extensionAction: extensionShortcut]
    var scope = ShortcutRegistrationScope.extensionActivation(UUID())
    manager.scopeForAction = { $0 == extensionAction ? scope : .native }
    var fired: [String] = []
    manager.fired = { fired.append($0) }

    func sendHotkey(_ id: UInt32) -> OSStatus {
        var event: EventRef?
        precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                 GetCurrentEventTime(), 0, &event) == noErr)
        guard let event else { preconditionFailure("Unable to construct Carbon test event") }
        defer { ReleaseEvent(event) }
        var hotkey = EventHotKeyID(signature: 0x4B4C414E, id: id)
        precondition(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       MemoryLayout<EventHotKeyID>.size, &hotkey) == noErr)
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    try manager.restore(saved)
    // The manager registers the launcher first, then the extension.
    precondition(sendHotkey(1) == noErr && sendHotkey(2) == noErr)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(fired == [nativeAction, extensionAction])
    fired.removeAll()

    precondition(sendHotkey(2) == noErr)
    scope = .unavailable
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(fired.isEmpty, "Queued event must be rejected before registration refresh")

    precondition(sendHotkey(2) == noErr)
    manager.removeStaleRegistrations()
    precondition(sendHotkey(2) != noErr)
    var competing: EventHotKeyRef?
    let claim = RegisterEventHotKey(extensionShortcut.key, extensionShortcut.modifiers,
                                    EventHotKeyID(signature: 0x4B4C5453, id: 1),
                                    GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &competing)
    precondition(claim == noErr, "Revoked extension must release the system hotkey")
    scope = .extensionActivation(UUID())
    do {
        try manager.refreshExtensions()
        preconditionFailure("An exclusive hotkey should prevent restoration")
    } catch is ShortcutManager.Failure {}
    precondition(sendHotkey(1) == noErr)
    if let competing { UnregisterEventHotKey(competing) }
    try manager.refreshExtensions()
    precondition(sendHotkey(2) != noErr)
    precondition(sendHotkey(4) == noErr, "A saved extension shortcut must use a new registration ID")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(fired == [nativeAction, extensionAction])

    manager.suspend()
    scope = .unavailable
    try manager.refreshExtensions()
    try manager.resume()
    precondition(sendHotkey(4) != noErr && sendHotkey(5) == noErr)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    fired.removeAll()

    let replacement = "fixture:replacement"
    let blocked = Shortcut(key: UInt32(kVK_F19), modifiers: nativeShortcut.modifiers)
    var blocker: EventHotKeyRef?
    precondition(RegisterEventHotKey(blocked.key, blocked.modifiers, EventHotKeyID(signature: 0x4B4C5453, id: 2),
                                    GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &blocker) == noErr)
    do {
        try manager.apply([replacement: nativeShortcut, "zz:blocked": blocked])
        preconditionFailure("The overlapping transaction should fail as a whole")
    } catch is ShortcutManager.Failure {}
    if let blocker { UnregisterEventHotKey(blocker) }
    precondition(sendHotkey(5) == noErr)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(fired == [nativeAction], "Failed transfer retains the original destination")
    fired.removeAll()

    precondition(sendHotkey(5) == noErr)
    try manager.apply([replacement: nativeShortcut])
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(fired.isEmpty, "A queued callback must not follow a reassigned shortcut")
    precondition(sendHotkey(5) == noErr)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(fired == [replacement], "Reassigned shortcut should invoke its new destination")
    manager.stop()
    print("PASS Carbon registration, queued event revocation, slot release, conflict retry and recorder resume")
}

// AI descriptors are a projection of the ordinary catalog, never another dispatch authority.
do {
    let definition = AIActionDefinition(commandID: .init(rawValue: "owned-ai"), title: "Owned AI", instructions: "Summarize")
    let missing = LauncherModule(id: .init(rawValue: "bad-ai"), aiActions: [definition])
    do { _ = try LauncherModuleRegistry(modules: [missing], preferences: UserDefaults(suiteName: "keylane-ai-missing-" + UUID().uuidString)!); preconditionFailure("Missing command accepted") }
    catch { }
    var invoked = 0
    let owner = ModuleID(rawValue: "owned-ai-module")
    let command = LauncherModule.Command(declaration: .init(id: definition.commandID, title: "AI", detail: "", symbol: "sparkles", keywords: []),
        aiExecute: { _, _ in invoked += 1 })
    let module = LauncherModule(id: owner, commands: [command], aiActions: [definition])
    let registry = try LauncherModuleRegistry(modules: [module], preferences: UserDefaults(suiteName: "keylane-ai-registry-" + UUID().uuidString)!)
    precondition(registry.aiActions == [definition] && invoked == 0)
    let wrong = AIActionSource(moduleID: .init(rawValue: "other-module"), load: { preconditionFailure("Catalog must not read a source") }, isCurrent: { _ in true })
    precondition(!registry.invoke(definition.commandID, origin: .menu, aiSource: wrong) { _ in })
    precondition(invoked == 0)
    precondition(registry.invoke(definition.commandID, origin: .shortcut) { _ in })
    precondition(invoked == 1)
    _ = registry.setModuleEnabled(owner, false)
    precondition(!registry.invoke(definition.commandID, origin: .menu) { _ in })
    precondition(registry.aiActions.isEmpty && invoked == 1)
}
print("PASS module AI metadata, exact source ownership and all command origins share admission")
// Tool catalog construction must be inert; captured entries must recheck module enablement.
var toolRegistryFinished = false
Task { @MainActor in
    let definition = try! AIToolDefinition(name: "module_fixture", title: "Fixture", description: "Synthetic tool")
    var probes = 0
    let contribution = AIToolRegistration(definition: definition, available: { probes += 1; return true }) { _ in try .init(text: "fixture") }
    let toolModule = LauncherModule(id: ModuleID(rawValue: "fixture.tools"), aiTools: [contribution])
    let tools = try! LauncherModuleRegistry(modules: [toolModule], preferences: extensionPreferences)
    precondition(probes == 0, "Registration cannot query services or permissions")
    let frozen = tools.availableAITools
    precondition(frozen.count == 1)
    precondition(tools.setModuleEnabled(toolModule.id, false))
    precondition(!frozen[0].available() && tools.availableAITools.isEmpty)
    precondition(tools.setModuleEnabled(toolModule.id, true))
    precondition(!frozen[0].available() && tools.availableAITools.count == 1, "Reenabling cannot revive a pending old action")
    do {
        _ = try LauncherModuleRegistry(modules: [toolModule, LauncherModule(id: ModuleID(rawValue: "fixture.other"), aiTools: [contribution])], preferences: extensionPreferences)
        preconditionFailure("Duplicate tool name accepted")
    } catch AIToolContractError.duplicateTool { } catch { preconditionFailure("Unexpected duplicate error") }
    toolRegistryFinished = true
}
let toolRegistryDeadline = Date().addingTimeInterval(3)
while !toolRegistryFinished, Date() < toolRegistryDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
precondition(toolRegistryFinished)
print("PASS module tools: inert catalog construction, duplicate rejection and live module enablement for captured declarations")

// Context discovery is metadata-only; captured sources cannot outlive their module activation.
var contextRegistryFinished = false
Task { @MainActor in
    let suite = "keylane.context-registry." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let owner = ModuleID(rawValue: "fixture.contexts")
    let commandID = CommandID(rawValue: "fixture-ai-command")
    var reads = 0
    let contextAvailability = PassthroughSubject<Bool, Never>()
    let registration = AIContextRegistration(id: "fixture.context", title: "Fixture", symbol: "doc", availabilityUpdates: contextAvailability.eraseToAnyPublisher()) { query in
        [AIContextCandidate(id: "item", title: query, detail: "metadata", source: .init(moduleID: owner, load: {
            reads += 1
            return AIActionContext(sourceID: "item", title: "Fixture", text: "synthetic context")
        }, isCurrent: { _ in true }))]
    }
    var commandEnabled = true
    let command = LauncherModule.Command(declaration: .init(id: commandID, title: "AI fixture", detail: "", symbol: "sparkles", keywords: []), isAICommand: true)
    let registry = try! LauncherModuleRegistry(modules: [LauncherModule(id: owner, commands: [command], aiContexts: [registration])], preferences: defaults, commandEnabled: { _ in commandEnabled })
    precondition(registry.aiCommandEntries().map(\.commandID) == [commandID])
    commandEnabled = false
    precondition(registry.aiCommandEntries().isEmpty)
    let context = registry.availableAIContexts[0]
    precondition(reads == 0)
    do {
        let rows = try await context.search("fixture")
        precondition(rows.count == 1 && reads == 0)
        let loaded = try await rows[0].source.load()
        precondition(loaded.text == "synthetic context" && reads == 1)
        _ = registry.setModuleEnabled(owner, false)
        _ = registry.setModuleEnabled(owner, true)
        do { _ = try await rows[0].source.load(); preconditionFailure("Old context revived") } catch { }
        do { _ = try await context.search(""); preconditionFailure("Old context directory revived") } catch { }
        precondition(reads == 1 && registry.availableAIContexts.count == 1)
        let freshRows = try await registry.availableAIContexts[0].search("fresh")
        contextAvailability.send(false); contextAvailability.send(true)
        do { _ = try await freshRows[0].source.load(); preconditionFailure("Feature off/on revived an old candidate") } catch { }
        precondition(reads == 1)
        // Suspend precisely inside the source version check, after the first generation check.
        for revocation in ["feature-off", "feature-off-on", "module-off-on"] {
            var validation: CheckedContinuation<Bool, Never>?
            let slow = AIActionSource(moduleID: owner, load: {
                .init(sourceID: "deferred", title: "Fixture", text: "Must not enter a draft")
            }, isCurrent: { _ in await withCheckedContinuation { validation = $0 } })
            let guarded = registry.guardedAIContextSource(slow)
            let pending = Task { @MainActor in try await guarded.load() }
            let deadline = ContinuousClock.now + .seconds(2)
            while validation == nil && ContinuousClock.now < deadline { await Task.yield() }
            precondition(validation != nil, "Fixture did not suspend inside asynchronous validation")
            if revocation == "module-off-on" {
                _ = registry.setModuleEnabled(owner, false)
                _ = registry.setModuleEnabled(owner, true)
            } else {
                contextAvailability.send(false)
                if revocation == "feature-off-on" { contextAvailability.send(true) }
            }
            validation?.resume(returning: true)
            do { _ = try await pending.value; preconditionFailure("Late validated context survived \(revocation)") }
            catch AIActionError.staleSource { }
            contextAvailability.send(true)
        }
        print("PASS PR212 context validation race: feature off, off/on and module off/on reject a read suspended inside isCurrent")
    } catch { preconditionFailure("Context fixture failed: \(error)") }
    do {
        _ = try LauncherModuleRegistry(modules: [LauncherModule(id: owner, aiContexts: [registration, registration])], preferences: defaults)
        preconditionFailure("Duplicate contexts accepted")
    } catch { }
    contextRegistryFinished = true
}
let contextDeadline = Date().addingTimeInterval(5)
while !contextRegistryFinished, Date() < contextDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
precondition(contextRegistryFinished)
print("PASS module context directory: no eager body reads, command admission, duplicate rejection and irreversible activation revocation")

// Result destinations use the same command executor, including internal-only grid presentation.
do {
    let suite = "keylane.ai-result-routing." + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    let sourceID = CommandID(rawValue: "fixture-result-source")
    let destinationID = CommandID(rawValue: "fixture-result-target")
    let definition = AIActionDefinition(commandID: sourceID, title: "AI result", instructions: "Transform", resultDestination: .init(commandID: destinationID, title: "Preview result"))
    let source = LauncherModule.Command(declaration: .init(id: sourceID, title: "Source", detail: "", symbol: "sparkles", keywords: []))
    var delivered: [String] = []
    let destination = LauncherModule.Command(declaration: .init(id: destinationID, title: "Internal", detail: "", symbol: "doc", keywords: []), isInternal: true, arguments: .init(count: 1...1) { _, args in delivered = args })
    let module = LauncherModule(id: .init(rawValue: "fixture-result"), commands: [source, destination], aiActions: [definition])
    let registry = try LauncherModuleRegistry(modules: [module], preferences: prefs)
    precondition(registry.aiResultDestination(for: sourceID) == definition.resultDestination)
    let input = LauncherCommandSearch.Input(query: "", page: .root, aliases: [:], favorites: [], usage: [:])
    precondition(!registry.candidates(for: input).contains { $0.commandID == destinationID })
    precondition(!registry.shortcutCommandGroups.flatMap(\.commands).contains { $0.declaration.id == destinationID })
    precondition(!registry.invoke(destinationID, origin: .shortcut, arguments: ["result"]) { _ in })
    precondition(registry.invoke(destinationID, origin: .menu, arguments: ["result"]) { _ in })
    precondition(delivered == ["result"])
    _ = registry.setModuleEnabled(module.id, false)
    precondition(registry.aiResultDestination(for: sourceID) == nil)
    precondition(!registry.invoke(destinationID, origin: .menu, arguments: ["stale"]) { _ in })
    do {
        _ = try LauncherModuleRegistry(modules: [.init(id: module.id, commands: [source], aiActions: [definition])], preferences: prefs)
        preconditionFailure("Missing result destination accepted")
    } catch { }
}
print("PASS AI result routing: validated target, normal command admission, hidden internal action, shortcut denial and module revocation")

// A module refresh must update its own rows without re-scoring an unchanged catalog.
let appOwner = ModuleID(rawValue: "fixture.apps")
let fileOwner = ModuleID(rawValue: "fixture.files")
let appRefresh = PassthroughSubject<Void, Never>()
let fileRefresh = PassthroughSubject<Void, Never>()
var fileTitle = "Demo file"
var includeFile = true
var appAvailable = true
let performanceRegistry = try LauncherModuleRegistry(modules: [
    .init(id: appOwner, providers: [.init(namespace: .prefix("sample-app:"), entries: { _ in
        (0..<2000).map { Entry(id: "sample-app:\($0)", commandID: .init(rawValue: "sample-app:\($0)"),
                              name: "Demo app \($0)", detail: "", symbol: "app") }
    }, resolve: { _, _ in nil }, available: { _ in appAvailable })], searchUpdates: [appRefresh.eraseToAnyPublisher()]),
    .init(id: fileOwner, providers: [.init(namespace: .prefix("sample-file:"), entries: { _ in
        includeFile ? [Entry(id: "sample-file:1", commandID: .init(rawValue: "sample-file:1"),
                             name: fileTitle, detail: "", symbol: "doc")] : []
    }, resolve: { _, _ in nil })], searchUpdates: [fileRefresh.eraseToAnyPublisher()])
], preferences: extensionPreferences)
let performanceSearch = LauncherCommandSearch()
let performanceChanges = performanceRegistry.searchInvalidations.sink { performanceSearch.invalidate(module: $0) }
let performanceInput = LauncherCommandSearch.Input(query: "Demo", page: .root, aliases: [:], favorites: [], usage: [:])
let baselineRows = performanceSearch.results(for: performanceInput, registry: performanceRegistry)
let coldDiagnostics = performanceSearch.diagnostics
precondition(coldDiagnostics.scored == 2001)
precondition(performanceSearch.results(for: performanceInput, registry: performanceRegistry).map(\.id) == baselineRows.map(\.id))
precondition(performanceSearch.diagnostics.cacheHit)
fileTitle = "Demo changed file"
fileRefresh.send()
let refreshedRows = performanceSearch.results(for: performanceInput, registry: performanceRegistry)
let refreshedDiagnostics = performanceSearch.diagnostics
precondition(refreshedDiagnostics.scored == 1 && refreshedDiagnostics.reused == 2000)
precondition(refreshedRows.contains { $0.name == fileTitle })
let oracle = LauncherCommandSearch().results(for: performanceInput, registry: performanceRegistry)
precondition(refreshedRows.map(\.id) == oracle.map(\.id))
// Availability is checked on every enumerated candidate, including cached scores.
appAvailable = false
includeFile = false
fileRefresh.send()
precondition(performanceSearch.results(for: performanceInput, registry: performanceRegistry).isEmpty)
appAvailable = true
appRefresh.send()
precondition(performanceSearch.results(for: performanceInput, registry: performanceRegistry).count == 2000)
precondition(performanceSearch.diagnostics.scored == 2000)
print("Scoped search: cold scored=\(coldDiagnostics.scored), refresh scored=\(refreshedDiagnostics.scored), reused=\(refreshedDiagnostics.reused), cold_ms=\(coldDiagnostics.duration * 1000), refresh_ms=\(refreshedDiagnostics.duration * 1000)")

performanceRegistry.availabilityChanges.send()
_ = performanceSearch.results(for: performanceInput, registry: performanceRegistry)
precondition(performanceSearch.diagnostics.scored == 2000 && performanceSearch.diagnostics.reused == 0)
var newRankingInput = performanceInput
// Input is immutable for query/usage; use a different query to exercise full cache invalidation.
newRankingInput = .init(query: "Other", page: .root, aliases: [:], favorites: [], usage: [:])
precondition(performanceSearch.results(for: newRankingInput, registry: performanceRegistry).isEmpty)
precondition(performanceSearch.diagnostics.scored == 2000)
print("PASS global invalidation and query changes discard scoped scores")
