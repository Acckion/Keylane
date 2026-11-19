import AppKit
import SwiftUI

/// Uses the Launcher's action rows, groups, submenus and keyboard dispatch.
enum QuickAIActions {
    static func items(model: Model, controller: QuickAIController, openChat: @escaping () -> Void) -> [LauncherAction] {
        let hasAnswer = controller.lastAnswer != nil && !controller.running
        let ready = !controller.running && !controller.loadingChat
        let primaryCopies = model.aiInteraction.primaryAction == .copy
        let target = (NSApp.delegate as? Delegate)?.pasteTargetName
        var items: [LauncherAction] = [
            .init(id: "quick-ai-paste", title: primaryCopies ? "复制回复" : target.map { "粘贴回复到 \($0)" } ?? "复制回复", icon: "doc.on.clipboard",
                  shortcut: .init(.return, modifiers: []), enabled: hasAnswer) { QuickAILauncher.useResponse(controller, copyOnly: primaryCopies) },
            .init(id: "quick-ai-paste-formatted", title: "粘贴格式化回复", icon: "textformat", shortcut: .init(.return, modifiers: .option), enabled: hasAnswer) {
                QuickAILauncher.useResponse(controller, formatted: true)
            },
            .init(id: "quick-ai-copy", title: primaryCopies ? "粘贴回复" : "复制回复", icon: "doc.on.doc", shortcut: .init(.return, modifiers: .command), enabled: hasAnswer) {
                QuickAILauncher.useResponse(controller, copyOnly: !primaryCopies)
            },
            .init(id: "quick-ai-new", title: "新问题", icon: "sparkles", shortcut: .init("n", modifiers: .command), group: 1) {
                controller.reset(); model.query = ""
            },
            .init(id: "quick-ai-dictate", title: "开始听写", icon: "mic", shortcut: .init("m", modifiers: .control), group: 1, perform: dictate),
            .init(id: "quick-ai-continue", title: "在 AI Chat 中继续", icon: "arrow.up.forward.app", shortcut: .init("j", modifiers: .command), group: 1, perform: openChat),
            .init(id: "quick-ai-regenerate", title: "重新生成", icon: "arrow.clockwise", shortcut: .init("r", modifiers: .command), group: 2, enabled: controller.canRegenerate) {
                _ = controller.regenerate()
            },
            .init(id: "quick-ai-regenerate-model", title: "使用其他模型重新生成…", icon: "arrow.clockwise", shortcut: .init("r", modifiers: [.command, .shift]),
                  submenu: .init(title: "重新生成所用的模型", items: models(model, controller: controller, regenerate: true)), group: 2, enabled: controller.canRegenerate),
            .init(id: "quick-ai-model", title: "更换模型…", icon: "cube", shortcut: .init("m", modifiers: [.command, .shift]),
                  submenu: .init(title: "选择模型", items: models(model, controller: controller, regenerate: false)), group: 2, enabled: ready),
            .init(id: "quick-ai-preference", title: "更换模型偏好…", icon: "speedometer", submenu: .init(title: "自动模型偏好", items: preferences(model, controller)), group: 2, enabled: ready),
            .init(id: "quick-ai-link", title: "复制对话链接", icon: "link", group: 3, enabled: controller.chatID != nil, perform: controller.copyDeeplink),
            .init(id: "quick-ai-data", title: "复制聊天数据", icon: "doc.on.doc", group: 3, enabled: !controller.turns.isEmpty, perform: controller.copyChatData),
            .init(id: "quick-ai-previous-message", title: "上一条消息", icon: "arrow.up.circle", shortcut: .init(.upArrow, modifiers: .command), group: 4,
                  enabled: !controller.turns.isEmpty, perform: controller.previousMessage),
            .init(id: "quick-ai-previous-chat", title: "上一段对话", icon: "arrow.left.circle", shortcut: .init("[", modifiers: .command), group: 5,
                  enabled: ready && controller.neighboringChat(-1) != nil) { model.query = ""; controller.navigateChat(-1) },
            .init(id: "quick-ai-next-chat", title: "下一段对话", icon: "arrow.right.circle", shortcut: .init("]", modifiers: .command), group: 5,
                  enabled: ready && controller.neighboringChat(1) != nil) { model.query = ""; controller.navigateChat(1) },
            .init(id: "quick-ai-actual-size", title: "实际大小", icon: "1.magnifyingglass", shortcut: .init("0", modifiers: .command), group: 6) { controller.textScale = 1 },
            .init(id: "quick-ai-zoom-in", title: "放大", icon: "plus.magnifyingglass", shortcut: .init("+", modifiers: .command), group: 6,
                  enabled: controller.textScale < 1.6) { controller.textScale = min(1.6, controller.textScale + 0.1) },
            .init(id: "quick-ai-zoom-out", title: "缩小", icon: "minus.magnifyingglass", shortcut: .init("-", modifiers: .command), group: 6,
                  enabled: controller.textScale > 0.8) { controller.textScale = max(0.8, controller.textScale - 0.1) },
            .init(id: "quick-ai-delete", title: "删除对话", icon: "trash", shortcut: .init("x", modifiers: .control), group: 7,
                  enabled: ready && !controller.turns.isEmpty, destructive: true, perform: controller.confirmDelete)
        ]
        if controller.running {
            items.insert(.init(id: "quick-ai-stop", title: "停止生成", icon: "stop.fill", perform: controller.stop), at: 0)
        }
        return items
    }

    private static func models(_ model: Model, controller: QuickAIController, regenerate: Bool) -> [LauncherAction] {
        let catalog = AIModelMenuCatalog(connections: model.aiSettings.state.connections,
                                        selection: controller.currentConnection.map { .model($0.id) } ?? .inherit, query: "")
        let choices = catalog.groups.enumerated().flatMap { group, models in
            models.models.map { connection in
                LauncherAction(id: "quick-ai-model-" + connection.id.uuidString, title: connection.displayName,
                               icon: controller.currentConnection?.id == connection.id ? "checkmark" : "cube",
                               value: connection.providerLabel, group: group, enabled: connection.isConfigured) {
                    if regenerate { _ = controller.regenerate(modelID: connection.id) }
                    else { _ = controller.chooseQuickModel(connection.id) }
                }
            }
        }
        return choices.isEmpty ? [.init(id: "quick-ai-configure", title: "配置模型…", icon: "gearshape") { model.openSettings(page: AIModule.models.page) }] : choices
    }

    private static func preferences(_ model: Model, _ controller: QuickAIController) -> [LauncherAction] {
        QuickAIModelPreference.allCases.map { preference in
            .init(id: "quick-ai-preference-" + preference.rawValue, title: preference.title,
                  icon: model.aiInteraction.modelPreference == preference ? "checkmark" : "speedometer") {
                model.aiInteraction.modelPreference = preference
                if let id = model.aiInteraction.preferredModelID ?? model.aiSettings.state.connection(for: .quick)?.id { _ = controller.chooseQuickModel(id, automatic: true) }
            }
        }
    }

    private static func dictate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let selector = NSSelectorFromString("startDictation:")
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.responds(to: selector) else {
                (NSApp.delegate as? Delegate)?.showLauncherFeedback("请先启用 macOS 听写，并聚焦输入框。", style: .failure)
                return
            }
            editor.perform(selector, with: nil)
        }
    }
}
