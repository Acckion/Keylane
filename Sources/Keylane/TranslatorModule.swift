import AppKit
import ApplicationServices
import Combine
import KeylaneCore
import SwiftUI

enum TranslatorModule {
    static let pageID = PageID(rawValue: "Translator")
    static let commandID = CommandID(rawValue: "translate")
    static let settingsID = "translator"
    static let optionsItem = SettingsItem(id: "translator-options", page: settingsID, title: "翻译设置",
                                          keywords: "Translate Translator Google Microsoft 有道 百度 翻译 语言 提供商 API")
    static let commandsItem = SettingsItem(id: "translator-commands", page: settingsID, title: "翻译命令", keywords: "翻译 自定义命令 热键")

    static func make(model: Model) -> LauncherModule {
        let controller = TranslatorController(ai: model.aiSettings, runtime: model.aiRuntime)
        let begin: (String?, TranslateCommand?, LauncherCommandOrigin) -> Void = { [weak model] text, command, origin in
            guard let model else { return }
            let target = selectedTarget()
            let selected = target.flatMap { selection(in: $0) }
            let needsSelection = text == nil && (controller.preferences.useSelection || command?.replaceSelection == true)
            if needsSelection, !AXIsProcessTrusted() {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            let input = text ?? ((controller.preferences.useSelection || command?.replaceSelection == true) ? selected : nil) ?? ""
            var verify: (() -> Bool)?
            if text == nil, command?.replaceSelection == true, let target, let selected, !selected.isEmpty {
                verify = { [weak model] in
                    guard let model, model.pageID == pageID,
                          let command, model.disabledCommands.contains(command.commandID) == false,
                          controller.preferences.commands.contains(command),
                          model.launcherModules?.isModuleEnabled(.init(rawValue: "keylane.translator")) == true,
                          let delegate = NSApp.delegate as? Delegate, delegate.window?.isKeyWindow == true,
                          delegate.previousApplication?.processIdentifier == target.processIdentifier,
                          selection(in: target) == selected else { return false }
                    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    return front == ProcessInfo.processInfo.processIdentifier || front == target.processIdentifier
                }
            }
            controller.begin(text: input, command: command, replacement: verify)
            model.openPage(pageID, origin: origin)
        }
        controller.replaceWithResult = { [weak controller] in if let controller { use(controller, paste: true) } }
        let command = LauncherModule.Command(declaration: .init(
            id: commandID, title: "翻译", detail: "翻译文本并切换语言", symbol: "translate",
            keywords: ["Translate", "Translator", "翻译", "语言"], destination: .action, settingsPage: settingsID
        ), acceptsFallbackQuery: true, arguments: .init(count: 0...1) { origin, arguments in
            begin(arguments.first, nil, origin)
        })
        let custom = LauncherModule.Provider(namespace: .prefix("translate:"), entries: { _ in
            controller.preferences.commands.map { item in
                Entry(id: item.commandID, commandID: .init(rawValue: item.commandID), name: item.name,
                      detail: "翻译", symbol: "translate", aliases: ["Translate", "翻译"])
            }
        }, resolve: { id, origin in
            guard let item = controller.preferences.commands.first(where: { $0.commandID == id.rawValue }) else { return nil }
            return { begin(nil, item, origin) }
        }, fallback: .init(entries: {
            controller.preferences.commands.map { item in
                Entry(id: item.commandID, commandID: .init(rawValue: item.commandID), name: item.name,
                      detail: "翻译", symbol: "translate")
            }
        }, resolve: { id, query in
            guard let item = controller.preferences.commands.first(where: { $0.commandID == id.rawValue }) else { return nil }
            return { begin(query, item, .search) }
        }))
        let copy = { use(controller, paste: controller.preferences.pastePrimary) }
        var page = LauncherPage(id: pageID, placeholder: "", badge: ("翻译", "translate"),
                                contentPlacement: .conversation, content: { [weak model] in
            AnyView(TranslatorView(controller: controller, back: { model?.goBackInLauncher() }, navigation: model?.navigation ?? "arrows"))
        }, leave: controller.stop, submit: copy, returnBindings: .init(primary: .command),
                                primaryTitle: { controller.preferences.pastePrimary ? "粘贴译文" : "复制译文" },
                                primaryEnabled: { controller.canUseOutput }, actions: { [weak model] in
            var actions: [LauncherAction] = [
                .init(id: "translate-copy", title: "复制译文", icon: "doc.on.doc", shortcut: .init(.return, modifiers: .command),
                      enabled: controller.canUseOutput) { use(controller, paste: false) },
                .init(id: "translate-paste", title: "粘贴到前一个应用", icon: "doc.on.clipboard", shortcut: .init(.return, modifiers: [.option, .command]),
                      enabled: controller.canUseOutput) { use(controller, paste: true) },
                .init(id: "translate-copy-source", title: "复制原文", icon: "doc.on.doc", shortcut: .init(.return, modifiers: .option),
                      enabled: !controller.input.isEmpty) { UtilityActions.copy(controller.input, feedback: "已复制原文") },
                .init(id: "translate-swap", title: "交换语言", icon: "arrow.left.arrow.right", shortcut: .init("s", modifiers: .command),
                      group: 1, enabled: controller.canUseOutput) { controller.swap() },
                .init(id: "translate-source", title: "更改源语言", icon: "flag", shortcut: .init("p", modifiers: [.shift, .command]), group: 1) {
                    controller.languageMenu = "source"
                },
                .init(id: "translate-target", title: "更改目标语言", icon: "flag", shortcut: .init("p", modifiers: .command), group: 1) {
                    controller.languageMenu = "target"
                },
                .init(id: "translate-retry", title: "重新翻译", icon: "arrow.clockwise", group: 2,
                      enabled: !controller.input.isEmpty) { controller.retry() }
            ]
            if model?.aiSettings.state.connection(for: .chat) != nil {
                actions.append(.init(id: "translate-chat", title: "在 AI Chat 中继续", icon: "sparkles", shortcut: .init("j", modifiers: .command),
                                     group: 2, enabled: controller.canUseOutput) {
                    let context = "原文（\(controller.sourceTitle)）\n\(controller.input)\n\n译文（\(TranslationLanguage.language(controller.target)?.title ?? controller.target)）\n\(controller.output)"
                    model?.runCommand(.init(rawValue: "ai-chat"), origin: .menu, arguments: [context])
                })
            }
            actions.append(.init(id: "translate-settings", title: "翻译设置…", icon: "gearshape", group: 3) { model?.openSettings(page: settingsID) })
            return actions
        }, updates: controller.objectWillChange.receive(on: DispatchQueue.main).eraseToAnyPublisher(), headerInput: .none,
                                actionShortcutsEnabled: true)
        page.fullBleed = true
        page.resume = controller.resume
        let settings = LauncherSettingsPage(id: settingsID, title: "翻译", symbol: "translate", subtitle: "在语言之间快速翻译文本。",
                                            order: 129, items: [optionsItem, commandsItem], centeredHeader: true,
                                            content: { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(TranslatorSettings(model: model, controller: controller))
        })
        return .init(id: .init(rawValue: "keylane.translator"), title: "翻译", symbol: "translate", commands: [command], providers: [custom],
                     pages: [page], settings: [settings], services: [.init(start: {}, stop: controller.stop)],
                     searchUpdates: [controller.$preferences.removeDuplicates().map { _ in () }.eraseToAnyPublisher()],
                     dynamicCommandSettings: .init(model: model, items: { controller.preferences.commands }, title: \.name, commandID: \.commandID,
                                                  updates: { [controller.$preferences.map { $0.commands }.removeDuplicates().map { _ in () }.eraseToAnyPublisher()] },
                                                  entry: { item, model in
            CommandSettingsEntry(title: item.name, model: model, commandID: .init(rawValue: item.commandID), icon: { SettingsIcon(symbol: "translate") })
        }))
    }

    static func use(_ controller: TranslatorController, paste: Bool) {
        guard controller.canUseOutput else { return }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(controller.output, forType: .string) else { return }
        if paste, let delegate = NSApp.delegate as? Delegate, delegate.pasteTargetName != nil {
            delegate.pasteIntoPreviousApplication(clipboardGeneration: board.changeCount)
        } else {
            (NSApp.delegate as? Delegate)?.showLauncherFeedback("已复制译文", style: .success)
        }
    }
    private static func selectedTarget() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        return front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? (NSApp.delegate as? Delegate)?.previousApplication : front
    }
    private static func selection(in app: NSRunningApplication) -> String? {
        guard let element = SnippetTextTarget.focused(in: app) else { return nil }
        return SnippetTextTarget.attribute(kAXSelectedTextAttribute, of: element) as? String
    }
}
