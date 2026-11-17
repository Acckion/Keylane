import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum WindowManagementModule {
    private static let id = "keylane.window-management"

    static func make(model: Model) -> LauncherModule {
        let permission = PermissionFeature("windowManagement.enabled", authorization: .accessibility, observeImmediately: false)
        let controller = WindowManagementController(model: model, permission: permission)
        let spaceShortcuts = WindowSpaceShortcuts()
        let customUpdates = ViewObservation.changes(controller.$actions)
        let draftUpdates = ViewObservation.changes(controller.$draft)
        let layoutUpdates = Publishers.Merge(
            ViewObservation.changes(controller.$layoutDraft),
            ViewObservation.changes(controller.$layoutHasInvalidMeasurements)
        ).eraseToAnyPublisher()
        let coordinateUpdates = ViewObservation.changes(controller.$coordinates)
        var permissionObservation: AnyCancellable?
        let back: () -> Void = { [weak model] in model?.pageID = .root }

        spaceShortcuts.available = { [weak model] in
            permission.available && model?.launcherModules?.isModuleEnabled(.init(rawValue: id)) == true
        }
        spaceShortcuts.canHandle = { [weak model] direction in
            let command = direction > 0 ? "window-switch-next-space" : "window-switch-previous-space"
            return model?.disabledCommands.contains(command) == false
        }
        spaceShortcuts.perform = { [weak model] direction in
            let id = direction > 0 ? "window-switch-next-space" : "window-switch-previous-space"
            model?.runCommand(.init(rawValue: id), origin: .shortcut)
        }

        let commands: [LauncherModule.Command] = WindowCommand.all.map { command in
            let destination: LauncherCommandDeclaration.Destination
            switch command.action {
            case .createCommand: destination = .page(WindowManagementController.editorPage)
            case .createLayout: destination = .page(WindowManagementController.layoutPage)
            case .coordinate: destination = .page(WindowManagementController.coordinatesPage)
            default: destination = .action
            }
            return .init(declaration: .init(id: .init(rawValue: command.id), title: command.title, detail: title,
                                            symbol: command.symbol, keywords: [command.chinese, command.english, "窗口管理", "Window Management"],
                                            destination: destination, settingsPage: id),
                         permission: permission, execute: { origin in controller.run(command, origin: origin) })
        }
        let editor = LauncherPage(
            id: WindowManagementController.editorPage, placeholder: "", badge: ("窗口管理", "macwindow"), contentPlacement: .form,
            content: { AnyView(WindowActionEditor(controller: controller, back: back)) },
            back: back, submit: controller.saveDraft, shortcutSubmit: controller.saveDraft,
            primaryTitle: { "保存命令" },
            primaryEnabled: { controller.draft.isValid }, updates: draftUpdates
        )
        let layout = LauncherPage(
            id: WindowManagementController.layoutPage, placeholder: "", badge: ("窗口布局", "macwindow"),
            contentPlacement: .form,
            content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(WindowLayoutEditor(
                    draft: Binding(get: { controller.layoutDraft }, set: { controller.layoutDraft = $0 }),
                    hasInvalidMeasurements: Binding(get: { controller.layoutHasInvalidMeasurements },
                                                    set: { controller.layoutHasInvalidMeasurements = $0 }),
                    applications: model.applicationSettingsCatalog,
                    quicklinks: model.quicklinks, preferences: controller.preferences,
                    navigation: model.navigation,
                    capture: controller.captureLayoutEditorWindows, choosePath: controller.chooseLayoutPath,
                    back: back
                ).id(controller.layoutEditorID))
            }, leave: { [weak model] in
                controller.leaveLayout()
                model?.releaseApplicationCatalog(for: .windowLayout)
            }, back: back, submit: controller.saveLayoutDraft,
            shortcutSubmit: controller.saveLayoutDraft, primaryTitle: { "保存布局" },
            primaryEnabled: { controller.layoutIsValid }, updates: layoutUpdates,
            enter: { [weak model] _ in
                model?.acquireApplicationCatalog(for: .windowLayout)
                return nil
            }
        )
        let coordinates = LauncherPage(
            id: WindowManagementController.coordinatesPage, placeholder: "", badge: ("窗口管理", "macwindow"), contentPlacement: .form,
            content: { AnyView(WindowCoordinatesForm(controller: controller, back: back)) },
            back: back, submit: controller.submitCoordinates, shortcutSubmit: controller.submitCoordinates,
            primaryTitle: { controller.coordinates.resize ? "调整大小" : "移动窗口" },
            primaryEnabled: { controller.coordinates.placement != nil }, updates: coordinateUpdates
        )
        let settingsAnchor = SettingsItem(id: id, page: id, title: title,
                                          keywords: WindowCommand.all.flatMap { [$0.chinese, $0.english] }.joined(separator: " ")
                                            + " 窗口间距 屏幕边距 循环 台前调度 预设 空间快捷键")
        let settings = LauncherSettingsPage(
            id: id, title: title, symbol: "macwindow", subtitle: "移动、调整和排列应用窗口。",
            order: 142, items: [settingsAnchor], titlebar: permission.titlebar("启用窗口管理"), centeredHeader: true,
            content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(WindowManagementSettings(model: model, controller: controller,
                                                        preferences: controller.preferences, anchor: settingsAnchor, shortcuts: spaceShortcuts))
            }
        )
        let provider = LauncherModule.Provider(
            namespace: .prefix(WindowManagementController.customPrefix),
            entries: { _ in
                guard permission.available else { return [] }
                return controller.actions.map { item in
                    let id = item.commandID
                    return Entry(id: id, commandID: .init(rawValue: id), name: item.name, detail: title,
                                 symbol: item.displaySymbol,
                                 aliases: ["窗口管理", "Window Management"])
                }
            }, resolve: { id, origin in
                guard permission.available, let item = controller.actions.first(where: { $0.commandID == id.rawValue }) else { return nil }
                return { controller.run(item, origin: origin) }
            }, actions: { entry in
                guard let item = controller.actions.first(where: { $0.commandID == entry.id }) else { return nil }
                return [
                    .init(id: "window-edit", title: "编辑", icon: "pencil") { controller.edit(item) },
                    .init(id: "window-duplicate", title: "复制", icon: "plus.square.on.square") { controller.duplicate(item) }
                ]
            }, available: { id in permission.available && controller.actions.contains { $0.commandID == id.rawValue } },
            permission: { _ in permission }
        )
        return .init(id: .init(rawValue: id), title: title, symbol: "macwindow", commands: commands,
                     providers: [provider], pages: [editor, layout, coordinates], settings: [settings],
                     services: [.init(start: {
                         permission.startObserving()
                         spaceShortcuts.refresh()
                         permissionObservation = permission.updates.receive(on: DispatchQueue.main).sink {
                             spaceShortcuts.refresh()
                             if !permission.available { controller.cancel() }
                         }
                     }, stop: {
                         permissionObservation?.cancel()
                         permissionObservation = nil
                         spaceShortcuts.stop()
                         permission.stopObserving()
                         controller.cancel()
                         SystemNavigation.shared.clearWindowPlacementHistory()
                     })], searchUpdates: [permission.updates, customUpdates],
                     dynamicCommandSettings: .init(
                        model: model, items: { controller.actions }, title: \.name,
                        commandID: \.commandID, updates: { [customUpdates] },
                        entry: { item, model in customEntry(item, model: model) }
                     ))
    }

    private static var title: String { NavigationText.label("窗口管理", "Window Management") }

    private static func customEntry(_ item: CustomWindowAction, model: Model) -> CommandSettingsEntry<SettingsIcon> {
        let id = item.commandID
        return .init(title: item.name, model: model, commandID: .init(rawValue: id),
                     isEnabled: Binding(get: { !model.disabledCommands.contains(id) }, set: { value in
            if value { model.disabledCommands.remove(id) }
            else { model.disabledCommands.insert(id) }
        })) {
            SettingsIcon(symbol: item.displaySymbol)
        }
    }
}
