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
