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
let registry = try LauncherModuleRegistry(modules: [module])
precondition(starts == 0 && views == 0)
let input = LauncherCommandSearch.Input(query: "clipboard", page: PageID(rawValue: "Commands"),
                                       aliases: ["clipboard": "clipboard"], favorites: ["clipboard"], usage: ["clipboard": 3])
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


let applications = LauncherSettingsPage(id: "applications", title: "应用程序", symbol: "app", subtitle: "", order: 10,
                                        items: [.applicationScopes, .applicationFavorites], content: { AnyView(EmptyView()) })
let settingsModule = LauncherModule(id: .init(rawValue: "keylane.applications"), settings: [applications])
let settingsRegistry = try LauncherModuleRegistry(modules: [settingsModule, module])
precondition(settingsRegistry.settingsCatalog.pages.map(\.id) == ["clipboard", "applications"])
precondition(settingsRegistry.settingsCatalog.item("favorites") == .applicationFavorites)
precondition(settingsRegistry.settingsCatalog.page("applications")?.items.count == 2)
let invalidPage = LauncherSettingsPage(id: "unrelated", title: "", symbol: "", subtitle: "", order: 0,
                                       items: [.applicationScopes], content: { AnyView(EmptyView()) })
do {
    _ = try LauncherModuleRegistry(modules: [.init(id: .init(rawValue: "invalid"), settings: [invalidPage])])
    preconditionFailure("Settings items must belong to their registered page")
} catch let error as LauncherModuleRegistry.SettingsRegistrationError {
    precondition(error == .wrongPage(item: "scopes", expected: "unrelated"))
}
print("PASS settings catalog lookup, ordering and page ownership")


let windowPage = PageID(rawValue: "Windows")
let menuPage = PageID(rawValue: "MenuItems")
let windowCommand = CommandID(rawValue: "switch-windows")
let menuCommand = CommandID(rawValue: "search-menu-items")
let navigation = LauncherModule(
    id: .init(rawValue: "keylane.navigation"),
    commands: [
        .init(declaration: .init(id: windowCommand, title: "切换窗口", detail: "", symbol: "macwindow", keywords: [],
                                 destination: .page(windowPage), settingsPage: "navigation")),
        .init(declaration: .init(id: menuCommand, title: "搜索菜单项", detail: "", symbol: "menubar", keywords: [],
                                 destination: .page(menuPage), settingsPage: "navigation"))
    ],
    pages: [.init(id: windowPage, placeholder: "搜索窗口"), .init(id: menuPage, placeholder: "搜索菜单")],
    settings: [.init(id: "navigation", title: "导航", symbol: "macwindow", subtitle: "", order: 20, items: [],
                     content: { AnyView(EmptyView()) })]
)
let pageSettingsRegistry = try LauncherModuleRegistry(modules: [module, navigation])
precondition(pageSettingsRegistry.command(for: pageID)?.id == commandID)
precondition(pageSettingsRegistry.command(for: windowPage)?.id == windowCommand)
precondition(pageSettingsRegistry.command(for: menuPage)?.id == menuCommand)
precondition(pageSettingsRegistry.command(for: .root) == nil)
precondition(pageSettingsRegistry.commands(inSettingsPage: "navigation").map(\.id) == [windowCommand, menuCommand])
print("PASS page-specific command settings and shared extension settings")
