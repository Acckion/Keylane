import AppKit
import Combine
import KeylaneCore

/// Generic registration and lifetime wiring; each module owns its source, permission and policy.
enum ModuleAICommands {
    static func command(model: Model, moduleID: ModuleID, settings: String, definition: AIActionDefinition,
                        permission: PermissionFeature? = nil, available: @escaping () -> Bool = { true },
                        updates: [AnyPublisher<Bool, Never>] = [], source: @escaping () -> AIActionSource?,
                        initialQuestion: @escaping () -> String = { "" }, fallback: @escaping (LauncherCommandOrigin) -> Void,
                        transform: ((AIActionContext, String) throws -> String)? = nil) -> LauncherModule.Command {
        .init(declaration: .init(id: definition.commandID, title: definition.title, detail: "预览后明确发送给模型",
              symbol: "sparkles", keywords: ["AI", definition.title], destination: .action, settingsPage: settings),
              available: { [weak model] in available() && model?.aiSettings.state.connection(for: .commands) != nil }, permission: permission,
              aiExecute: { [weak model] origin, provided in
            guard let model, let registry = model.launcherModules else { return }
            let selected = definition.showsSourcePreview ? (provided ?? source()) : source()
            guard let selected, selected.moduleID == moduleID else { fallback(origin); return }
            let allowed = { [weak model, weak registry] in
                guard let model, let registry else { return false }
                return available() && registry.isCommandModuleEnabled(definition.commandID) && !model.disabledCommands.contains(definition.commandID.rawValue)
            }
            model.moduleAIAction.prepare(definition, source: registry.guardedAIContextSource(selected), initialQuestion: initialQuestion(), resultTransform: transform, allowed: allowed)
            model.moduleAIAction.observeAvailability(Publishers.MergeMany(updates + [
                registry.availabilityChanges.map { allowed() }.eraseToAnyPublisher(),
                model.$disabledCommands.map { !$0.contains(definition.commandID.rawValue) }.eraseToAnyPublisher()
            ]).eraseToAnyPublisher())
            model.openPage(AIActionLauncher.pageID, origin: origin)
        })
    }

    static func menu(title: String = "AI", definitions: [AIActionDefinition], source: AIActionSource, model: Model) -> LauncherAction {
        .init(id: source.moduleID.rawValue + ".ai", title: title, icon: "sparkles", submenu: .init(title: title, items: definitions.map { definition in
            .init(id: definition.commandID.rawValue, title: definition.title, icon: "sparkles",
                  enabled: model.aiSettings.state.connection(for: .commands) != nil && !model.disabledCommands.contains(definition.commandID.rawValue)) { [weak model] in
                _ = model?.runCommand(definition.commandID, origin: .menu, aiSource: source)
            }
        }))
    }
}

extension ModuleAICommands {
    static func attachment(model: Model, moduleID: ModuleID, id: CommandID, title: String, settings: String,
                           permission: PermissionFeature? = nil, available: @escaping () -> Bool = { true },
                           source: @escaping () -> AIActionSource?, fallback: @escaping (LauncherCommandOrigin) -> Void) -> LauncherModule.Command {
        .init(declaration: .init(id: id, title: title, detail: "仅加入草稿，不自动发送", symbol: "sparkles", keywords: ["AI", "聊天"], destination: .action, settingsPage: settings),
              available: { [weak model] in available() && model?.aiSettings.isAvailable == true }, permission: permission, isAICommand: true,
              aiExecute: { [weak model] origin, provided in
            guard let model else { return }
            guard let selected = provided ?? source(), selected.moduleID == moduleID else { fallback(origin); return }
            if model.attachModuleAIContext?(selected, id) != true {
                (NSApp.delegate as? Delegate)?.showLauncherFeedback("无法加入草稿，请确认模型可用并等待附件处理完成。", style: .failure)
            }
        })
    }
}
