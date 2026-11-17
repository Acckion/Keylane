import AppKit
import Combine
import SwiftUI

final class AIChatWindow: NSObject, NSWindowDelegate {
    private let controller: QuickAIController
    private let configuration: AIConfiguration
    private var window: NSWindow?
    private var appearance: NSAppearance?
    private var appearanceChanges: AnyCancellable?

    init(controller: QuickAIController, configuration: AIConfiguration, appearance: AnyPublisher<String, Never>) {
        self.controller = controller
        self.configuration = configuration
        super.init()
        appearanceChanges = appearance.removeDuplicates().sink { [weak self] value in
            let resolved = value == "dark" ? NSAppearance(named: .darkAqua)
                : value == "light" ? NSAppearance(named: .aqua) : nil
            self?.appearance = resolved
            self?.window?.appearance = resolved
        }
    }

    func show(draft: String, restoreLatest: Bool, activation: WindowActivationBehavior, leaveLauncher: () -> Void) {
        controller.beginChat(restoreLatest: restoreLatest)
        leaveLauncher()
        if window == nil {
            let chat = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 570),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            chat.title = "AI Chat"
            chat.appearance = appearance
            chat.minSize = NSSize(width: 620, height: 350)
            chat.isReleasedWhenClosed = false
            chat.delegate = self
            chat.contentView = NSHostingView(rootView: AIChatView(controller: controller, configuration: configuration, draft: draft))
            chat.center()
            window = chat
        }
        guard let window else { return }
        activation.apply(to: window)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        window = nil
        controller.closeChat()
    }
}

private struct AIChatView: View {
    @ObservedObject var controller: QuickAIController
    @ObservedObject var configuration: AIConfiguration
    @State var draft: String
    @FocusState private var editorFocused: Bool
    @State private var pendingDeletion: AIChatSummary?

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 160, idealWidth: 196, maxWidth: 290)
            chat.frame(minWidth: 400)
        }
        .task { editorFocused = true }
        .onChange(of: controller.chatID) { _, _ in draft = "" }
        .onExitCommand { (NSApp.delegate as? Delegate)?.closeUtilityWindowOnEscape() }
        .confirmationDialog("删除这段对话？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { item in
            Button("删除对话", role: .destructive) { controller.deleteChat(item.id); pendingDeletion = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("对话历史").font(.headline)
                Spacer()
                Button("新对话", systemImage: "plus", action: newChat)
                    .labelStyle(.iconOnly).help("新对话")
            }.padding(12)
            List(controller.chats, selection: Binding<UUID?>(
                get: { controller.chatID },
                set: { if let id = $0 { controller.openChat(id) } }
            )) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).lineLimit(1)
                    Text(item.updated, style: .date).font(.caption).foregroundStyle(.secondary)
                }
                .tag(item.id)
                .contextMenu { Button("删除…", role: .destructive) { pendingDeletion = item } }
            }
            .listStyle(.sidebar)
            if !controller.historyError.isEmpty {
                Text(controller.historyError).font(.caption).padding(10)
            }
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            AIConversationTranscript(controller: controller).id(controller.chatID)
                .overlay { if controller.loadingChat { ProgressView("正在读取对话…") } }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !controller.matchesCurrentModel {
                    Text("这段对话使用了另一模型或接口。切回原配置，或新建对话。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let connection = configuration.selected, configuration.isAvailable {
                    Text(connection.name.isEmpty ? connection.model : connection.name)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("请在「设置 → AI」中启用并配置模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextEditor(text: $draft)
                    .frame(height: 76)
                    .focused($editorFocused)
                    .disabled(controller.loadingChat || !controller.matchesCurrentModel)
                    .accessibilityLabel("问题")
                HStack {
                    Button("新对话", action: newChat)
                    Button("复制回复") { AIConversationTranscript.copy(controller.lastAnswer) }
                        .disabled(controller.lastAnswer == nil)
                    Spacer()
                    Button("发送", action: submit)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(ContentActionButtonStyle())
                        .disabled(controller.running || controller.loadingChat || !controller.matchesCurrentModel || !configuration.isAvailable
                                  || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(16)
        }
    }

    private func newChat() {
        controller.reset()
        draft = ""
        editorFocused = true
    }

    private func submit() {
        guard !SearchField.isComposing else { return }
        if controller.submit(draft) { draft = "" }
    }
}
