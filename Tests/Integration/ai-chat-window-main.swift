import AppKit
import Combine
import Foundation

// Inert services keep the real window/toolbar test independent of models, credentials and history.
final class AIConfiguration: ObservableObject {}
final class QuickAIController: ObservableObject {
    struct Summary { let id: UUID; let title: String }
    struct Connection { let displayName: String }
    @Published var chats: [Summary] = []
    @Published var chatID: UUID?
    @Published var chatTitle = ""
    var currentProjectID: UUID?
    let currentConnection: Connection? = .init(displayName: "Fixture model")
    func beginChat(restoreLatest: Bool) {}
    func reset(projectID: UUID? = nil) {}
    func closeChat() {}
}
enum WindowActivationBehavior {
    case systemDefault
    func apply(to window: NSWindow) {}
}
final class AIChatSplitViewController: NSSplitViewController {
    init(controller: QuickAIController, configuration: AIConfiguration,
         interaction: AIInteractionPreferences, composer: AIChatComposer,
         presentation: AIChatPresentation) {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        for _ in 0..<3 { addSplitViewItem(NSSplitViewItem(viewController: NSViewController())) }
    }
    required init?(coder: NSCoder) { fatalError("Unavailable") }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let suite = "org.keylane.ai-chat-toolbar-test.\(UUID().uuidString)"
let preferences = UserDefaults(suiteName: suite)!
defer { preferences.removePersistentDomain(forName: suite) }
let controller = QuickAIController()
let owner = AIChatWindow(controller: controller, configuration: AIConfiguration(),
                         interaction: AIInteractionPreferences(preferences: preferences),
                         appearance: Just("dark").eraseToAnyPublisher())
func show() -> NSWindow {
    owner.show(draft: "", restoreLatest: false, activation: .systemDefault, leaveLauncher: {})
    let window = app.windows.first { $0.identifier?.rawValue == "org.keylane.ai-chat" }!
    window.orderOut(nil)
    return window
}
let presentation = Mirror(reflecting: owner).children.first { $0.label == "presentation" }!.value as! AIChatPresentation
let inspectorIDs = Set(["chat.inspector-separator", "chat.inspector-title", "chat.inspector-close"])
func check(_ window: NSWindow, visible: Bool) {
    let actual = Set(window.toolbar!.items.map { $0.itemIdentifier.rawValue }).intersection(inspectorIDs)
    guard actual == (visible ? inspectorIDs : []) else {
        print("FAIL inspector toolbar does not match newly published visibility \(visible): \(actual)")
        exit(1)
    }
}
let window = show()
check(window, visible: false)
let composer = Mirror(reflecting: owner).children.first { $0.label == "composer" }!.value as! AIChatComposer
var composerFocusRequests = 0
let focusObserver = composer.focusRequested.sink { composerFocusRequests += 1 }
composer.text = "An unsent draft"
let newItem = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "chat.new" }!
precondition(app.sendAction(newItem.action!, to: newItem.target, from: newItem))
precondition(composer.text.isEmpty && composerFocusRequests == 1,
             "The native New Chat action must clear the draft and focus the real composer column")
focusObserver.cancel()
let toolbarIDs = window.toolbar!.items.map(\.itemIdentifier)
let searchIndex = toolbarIDs.firstIndex(of: .init("chat.search"))!
precondition(toolbarIDs[searchIndex + 1] == .space, "Search must be separate from the action/settings capsule")
let projectButton = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "chat.project" }!
var projectRequests = 0
let projectObserver = presentation.createProjectRequested.sink { projectRequests += 1 }
precondition(app.sendAction(projectButton.action!, to: projectButton.target, from: projectButton))
precondition(projectRequests == 1)
projectObserver.cancel()
let searchItem = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "chat.search" }!
precondition(app.sendAction(searchItem.action!, to: searchItem.target, from: searchItem))
precondition(presentation.searchVisible)
precondition(app.sendAction(searchItem.action!, to: searchItem.target, from: searchItem))
precondition(!presentation.searchVisible)
controller.chatTitle = "Fixture renamed chat"
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
precondition(window.title == "Fixture renamed chat")
for _ in 0..<8 {
    presentation.settingsVisible = true
    check(window, visible: true)
    presentation.settingsVisible = false
    check(window, visible: false)
}
presentation.settingsVisible = true
check(window, visible: true)
window.performClose(nil)
let reopened = show()
check(reopened, visible: true)
presentation.settingsVisible = false
check(reopened, visible: false)
reopened.performClose(nil)
print("PASS native AI Chat toolbar: title changes, search action, initial state, immediate open/close, rapid toggles and reopen while visible")
