import AppKit
import SwiftUI

final class AIChatWindow: NSObject, NSWindowDelegate {
    private let controller: QuickAIController
    private let configuration: AIConfiguration
    private var window: NSWindow?

    init(controller: QuickAIController, configuration: AIConfiguration) {
        self.controller = controller
        self.configuration = configuration
    }

    func show(draft: String, activation: WindowActivationBehavior, leaveLauncher: () -> Void) {
        controller.beginChat()
        leaveLauncher()
        if window == nil {
            let chat = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 570),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            chat.title = "AI Chat"
            chat.minSize = NSSize(width: 480, height: 350)
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

    var body: some View {
        VStack(spacing: 0) {
            AIConversationTranscript(controller: controller)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let connection = configuration.selected, configuration.isAvailable {
                    Text(connection.name.isEmpty ? connection.model : connection.name)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("请在「设置 → AI」中启用并配置模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextEditor(text: $draft)
                    .frame(height: 76)
                    .focused($editorFocused)
                    .accessibilityLabel("问题")
                HStack {
                    Button("新对话") { controller.reset(); draft = ""; editorFocused = true }
                    Button("复制回复") { AIConversationTranscript.copy(controller.lastAnswer) }
                        .disabled(controller.lastAnswer == nil)
                    Spacer()
                    Button("发送", action: submit)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(ContentActionButtonStyle())
                        .disabled(controller.running || !configuration.isAvailable
                                  || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(16)
        }
        .task { editorFocused = true }
        .onExitCommand { (NSApp.delegate as? Delegate)?.closeUtilityWindowOnEscape() }
    }

    private func submit() {
        guard !SearchField.isComposing else { return }
        if controller.submit(draft) { draft = "" }
    }
}
