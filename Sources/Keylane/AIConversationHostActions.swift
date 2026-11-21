import AppKit
import Foundation
import UniformTypeIdentifiers

/// Window, pasteboard and dialogs belong to the presentation host.
enum AIConversationHostActions {
    enum ImageImportMode { case text, vision }
    static func chooseFiles(composer: AIConversationComposer, directory: URL? = nil, in window: NSWindow? = NSApp.keyWindow) {
        guard let window, window.attachedSheet == nil, !composer.loadingFiles else { return }
        let draft = composer.draftID
        let panel = NSOpenPanel()
        panel.title = "附加文件"
        panel.message = "支持 UTF-8 文本、代码和有文字的 PDF。文件仅在发送问题时交给所选模型。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = directory
        panel.beginSheetModal(for: window) { [weak composer] response in
            guard response == .OK, let composer, composer.draftID == draft else { return }
            composer.attachFiles(panel.urls)
        }
    }

    static func chooseImage(composer: AIConversationComposer, directory: URL? = nil, mode: ImageImportMode = .text,
                            read: @escaping @Sendable (URL) async throws -> AIConversationAttachment) {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil, !composer.loadingFiles else { return }
        let draft = composer.draftID
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.directoryURL = directory
        panel.allowedContentTypes = [.image]
        panel.prompt = mode == .vision ? "添加图像" : "提取文字并添加"
        panel.message = mode == .vision ? "图像以静态画面加入草稿后可预览，动图只取第一帧；仅在发送时交给支持视觉的模型。" : "在本机提取图片文字，加入草稿。"
        panel.beginSheetModal(for: window) { [weak composer] response in
            guard response == .OK, let url = panel.url, let composer, composer.draftID == draft else { return }
            composer.loadAttachments { [try await read(url)] }
        }
    }

    static func copyText(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copyChatData(_ controller: AIConversationSession) {
        struct Export: Encodable { let version = 1; let title: String; let turns: [AIConversationTurn] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Export(title: controller.conversationTitle, turns: controller.turns)),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copyDeeplink(_ controller: AIConversationSession) {
        guard let chatID = controller.chatID else { return }
        let text = AIChatLink.make(chatID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func confirmDelete(_ controller: AIConversationSession) {
        guard let chatID = controller.chatID else { controller.reset(); return }
        let alert = NSAlert()
        alert.messageText = "删除这段对话？"
        alert.informativeText = "这会移除本机保存的这段对话。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { controller.deleteChat(chatID) }
    }
}

