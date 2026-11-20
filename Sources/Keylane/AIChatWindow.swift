import AppKit
import Combine
import SwiftUI

final class AIChatPresentation: ObservableObject {
    @Published var sidebarVisible = true
    @Published var settingsVisible = false
    @Published var actionsVisible = false
    @Published var fullWidth = false
    @Published var searchVisible = false
    let createProjectRequested = PassthroughSubject<Void, Never>()
}

final class AIChatWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let controller: QuickAIController
    private let configuration: AIConfiguration
    private let interaction: AIInteractionPreferences
    private let composer = AIChatComposer()
    private let presentation = AIChatPresentation()
    private var window: NSWindow?
    private var splitController: AIChatSplitViewController?
    private var inspectorChanges: AnyCancellable?
    private var titleChanges: AnyCancellable?
    private var appearance: NSAppearance?
    private var appearanceChanges: AnyCancellable?
    private var floatingChanges: AnyCancellable?

    init(controller: QuickAIController, configuration: AIConfiguration, interaction: AIInteractionPreferences,
         appearance: AnyPublisher<String, Never>) {
        self.controller = controller
        self.configuration = configuration
        self.interaction = interaction
        super.init()
        appearanceChanges = appearance.removeDuplicates().sink { [weak self] value in
            let resolved = value == "dark" ? NSAppearance(named: .darkAqua)
                : value == "light" ? NSAppearance(named: .aqua) : nil
            self?.appearance = resolved
            self?.window?.appearance = resolved
        }
        titleChanges = Publishers.Merge(controller.objectWillChange, configuration.objectWillChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateWindowTitle() }
        floatingChanges = interaction.$chatFloating.removeDuplicates().sink { [weak self] floating in
            self?.window?.level = floating ? .floating : .normal
        }
    }

    func show(draft: String, restoreLatest: Bool, activation: WindowActivationBehavior, leaveLauncher: () -> Void) {
        controller.beginChat(restoreLatest: restoreLatest)
        composer.offer(draft)
        leaveLauncher()
        if window == nil {
            let chat = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
            chat.title = "新对话"
            chat.identifier = .init("org.keylane.ai-chat")
            chat.titlebarAppearsTransparent = true
            chat.titleVisibility = .visible
            chat.titlebarSeparatorStyle = .none
            let split = AIChatSplitViewController(controller: controller, configuration: configuration,
                interaction: interaction, composer: composer, presentation: presentation)
            splitController = split
            chat.contentViewController = split
            chat.setContentSize(NSSize(width: 1120, height: 760))
            chat.toolbarStyle = .unified
            let toolbar = NSToolbar(identifier: "org.keylane.ai-chat.toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            chat.toolbar = toolbar
            chat.setFrameAutosaveName("KeylaneAIChat")
            chat.appearance = appearance
            chat.level = interaction.chatFloating ? .floating : .normal
            chat.minSize = NSSize(width: 720, height: 480)
            chat.isReleasedWhenClosed = false
            chat.delegate = self
            chat.center()
            window = chat
            updateWindowTitle()
            inspectorChanges = presentation.$settingsVisible.removeDuplicates().dropFirst().sink { [weak self] visible in
                self?.updateToolbarSections(settingsVisible: visible)
            }
        }
        guard let window else { return }
        activation.apply(to: window)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItemIdentifiers(settingsVisible: presentation.settingsVisible)
    }

    private func toolbarItemIdentifiers(settingsVisible: Bool) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [.init("chat.sidebar"), .flexibleSpace, .init("chat.project"), .init("chat.new"),
            .init("chat.history-separator"), .flexibleSpace,
            .init("chat.search"), .space, .init("chat.actions"), .init("chat.settings")]
        if settingsVisible {
            items += [.init("chat.inspector-separator"), .init("chat.inspector-title"), .flexibleSpace, .init("chat.inspector-close")]
        }
        return items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.init("chat.inspector-separator"), .init("chat.inspector-title"), .init("chat.inspector-close")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let splitController, identifier.rawValue == "chat.history-separator" || identifier.rawValue == "chat.inspector-separator" {
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitController.splitView,
                dividerIndex: identifier.rawValue == "chat.history-separator" ? 0 : 1)
        }
        if identifier.rawValue == "chat.inspector-title" {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = NSTextField(labelWithString: "聊天设置")
            item.label = "聊天设置"
            return item
        }
        let title: String
        let symbol: String
        let action: Selector
        switch identifier.rawValue {
        case "chat.sidebar": title = "切换侧栏"; symbol = "sidebar.left"; action = #selector(toggleSidebar)
        case "chat.project": title = "创建项目"; symbol = "folder.badge.plus"; action = #selector(createProject)
        case "chat.new": title = "新对话"; symbol = "square.and.pencil"; action = #selector(newChat)
        case "chat.search": title = "搜索当前对话"; symbol = "magnifyingglass"; action = #selector(toggleSearch)
        case "chat.actions": title = "操作"; symbol = "command"; action = #selector(toggleActions)
        case "chat.settings": title = "聊天设置"; symbol = "slider.horizontal.3"; action = #selector(toggleSettings)
        case "chat.inspector-close": title = "关闭聊天设置"; symbol = "xmark"; action = #selector(toggleSettings)
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self
        item.action = action
        return item
    }

    private func updateWindowTitle() {
        let title = controller.chatTitle.isEmpty ? (controller.chats.first(where: { $0.id == controller.chatID })?.title ?? "新对话") : controller.chatTitle
        let subtitle = controller.currentConnection?.displayName ?? "选择模型"
        if window?.title != title { window?.title = title }
        if window?.subtitle != subtitle { window?.subtitle = subtitle }
    }

    private func updateToolbarSections(settingsVisible: Bool) {
        guard let toolbar = window?.toolbar else { return }
        let desired = toolbarItemIdentifiers(settingsVisible: settingsVisible)
        guard toolbar.items.map(\.itemIdentifier) != desired else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, identifier) in desired.enumerated() { toolbar.insertItem(withItemIdentifier: identifier, at: index) }
    }

    @objc private func toggleSearch() { presentation.searchVisible.toggle() }
    @objc private func toggleSidebar() { presentation.sidebarVisible.toggle() }
    @objc private func toggleSettings() { presentation.settingsVisible.toggle(); presentation.actionsVisible = false }
    @objc private func toggleActions() { presentation.actionsVisible.toggle() }
    @objc private func createProject() { presentation.createProjectRequested.send() }
    @objc private func newChat() {
        controller.reset(projectID: controller.currentProjectID)
        composer.clear()
        presentation.actionsVisible = false
        composer.focusRequested.send()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        window = nil
        splitController = nil
        inspectorChanges = nil
        composer.clear()
        controller.closeChat()
    }
}
