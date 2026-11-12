import AppKit
import Combine
import KeylaneCore
import SwiftUI

final class QuicklinksController: ObservableObject {
    @Published private(set) var links: [Quicklink] = []
    @Published private(set) var storageError: String?
    @Published var selected: Quicklink?
    @Published var parameters: [QuicklinkTemplate.Parameter] = []
    @Published var values: [String: String] = [:]
    @Published var inputError: String?
    @Published var draft: Quicklink?
    var templateContext: () -> DynamicTemplate.Context = { .init() }
    private var pendingTemplate: QuicklinkTemplate?

    func load() {
        do { links = try QuicklinkLibrary.load(from: .standard).links; storageError = nil }
        catch { storageError = "无法读取快捷链接资料。" }
    }

    func save(_ link: Quicklink) throws {
        _ = try makeTemplate(link)
        var updated = links
        if let index = updated.firstIndex(where: { $0.id == link.id }) { updated[index] = link }
        else { updated.append(link) }
        try persist(updated)
    }

    func remove(_ link: Quicklink) throws {
        try persist(links.filter { $0.id != link.id })
    }

    private func persist(_ updated: [Quicklink]) throws {
        guard storageError == nil else { throw CocoaError(.fileWriteUnknown) }
        try QuicklinkLibrary(links: updated).save(to: .standard)
        links = updated
    }

    func launch(_ link: Quicklink, presentParameters: () -> Void) {
        do {
            let template = try makeTemplate(link)
            if template.parameters.isEmpty {
                try open(template.url())
            } else {
                pendingTemplate = template
                selected = link
                parameters = template.parameters
                values = [:]
                inputError = nil
                presentParameters()
            }
        } catch {
            (NSApp.delegate as? Delegate)?.showLauncherFeedback(error.localizedDescription, style: .failure)
        }
    }

    func submit() -> Bool {
        guard let pendingTemplate else { return false }
        do {
            try open(pendingTemplate.url(values: values))
            return true
        } catch {
            inputError = error.localizedDescription
            return false
        }
    }

    private func makeTemplate(_ link: Quicklink) throws -> QuicklinkTemplate {
        try QuicklinkTemplate(link.template, context: templateContext(), legacy: link.usesDynamicPlaceholders != true)
    }

    func clearInput() {
        pendingTemplate = nil
        selected = nil
        parameters = []
        values = [:]
        inputError = nil
    }

    func stop() { clearInput(); links = []; draft = nil; storageError = nil }

    private func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw NSError(domain: "Keylane.Quicklinks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法在默认浏览器中打开快捷链接。"])
        }
        (NSApp.delegate as? Delegate)?.hideLauncher()
    }
}

enum QuicklinksModule {
    static func create(from url: URL, title: String, model: Model) {
        guard model.launcherModules?.isModuleEnabled(.init(rawValue: "keylane.links")) == true else { return }
        model.quicklinks.draft = Quicklink(title: title, template: url.absoluteString)
        model.openSettings(page: "links")
    }

    static func make(model: Model) -> LauncherModule {
        let controller = model.quicklinks
        controller.templateContext = { [weak model] in model?.snippets.templateContext() ?? .init() }
        let pageID = PageID(rawValue: "QuicklinkParameters")
        let legacyID = CommandID(rawValue: QuicklinkLibrary.legacyID)
        func provider(_ namespace: LauncherCommandNamespace) -> LauncherModule.Provider {
            .init(namespace: namespace, entries: { _ in
                controller.links.compactMap { link in
                    let id = CommandID(rawValue: link.id)
                    guard namespace.contains(id) else { return nil }
                    return Entry(id: link.id, commandID: id, name: link.title, detail: "快捷链接", symbol: "link",
                                 aliases: ["Quicklink", "快捷链接", link.template])
                }
            }, resolve: { [weak model] id, origin in
                guard let model, let link = controller.links.first(where: { $0.id == id.rawValue }) else { return nil }
                return {
                    controller.launch(link) { model.openPage(pageID, origin: origin) }
                }
            }, primaryTitle: { _ in "打开链接" })
        }

        let submit: () -> Void = { [weak model] in
            if controller.submit() { model?.pageID = .root }
        }
        let page = LauncherPage(
            id: pageID, placeholder: "填写链接参数", badge: ("快捷链接", "link"), actionTitle: "打开链接",
            contentPlacement: .form,
            content: { [weak model] in
                AnyView(QuicklinkParameterForm(controller: controller, back: { model?.pageID = .root }, submit: submit))
            },
            leave: { [weak model] in
                controller.clearInput()
                if model?.pageID == pageID { model?.pageID = .root }
            }, submit: submit, enter: { _ in "" }
        )
        let settings = LauncherSettingsPage(id: "links", title: "快捷链接", symbol: "link",
                                            subtitle: "管理常用链接及其参数、别名和快捷键。", order: 90,
                                            items: [.quicklink], content: { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(QuicklinkPreferences(model: model, controller: controller))
        })
        return .init(id: .init(rawValue: "keylane.links"), title: "快捷链接", symbol: "link", commands: [
            .init(declaration: .init(id: .init(rawValue: "manage-quicklinks"), title: "管理快捷链接",
                                     detail: "新增、编辑或删除链接", symbol: "link",
                                     keywords: ["Manage Quicklinks", "Quick Links", "网址"],
                                     destination: .settings("links"), settingsPage: "links"))
        ], providers: [provider(.exact(legacyID)), provider(.prefix("quicklink:"))],
           pages: [page], settings: [settings], services: [.init(start: controller.load, stop: controller.stop)],
           searchUpdates: [ViewObservation.changes(controller.$links)],
           dynamicCommandSettings: .init(
               model: model, items: { controller.links }, title: \.title, commandID: \.id,
               updates: { [ViewObservation.changes(controller.$links)] },
               entry: { $0.commandSettingsEntry(model: $1) }
           ))
    }
}

private struct QuicklinkParameterForm: View {
    @ObservedObject var controller: QuicklinksController
    let back: () -> Void
    let submit: () -> Void
    var body: some View {
        DynamicArgumentsForm(title: controller.selected?.title ?? "快捷链接", arguments: controller.parameters,
                             values: $controller.values, error: controller.inputError, back: back, submit: submit)
    }

}

extension Quicklink {
    func commandSettingsEntry(model: Model, perform: (() -> Void)? = nil,
                              menu: [CommandSettingsAction] = []) -> CommandSettingsEntry<some View> {
        let commandID = CommandID(rawValue: id)
        return CommandSettingsEntry(title: title, model: model, commandID: commandID,
                                    isEnabled: Binding(get: { !model.disabledCommands.contains(id) }, set: {
            if $0 { model.disabledCommands.remove(id) }
            else { model.disabledCommands.insert(id) }
        }), perform: perform ?? { model.runCommand(commandID, origin: .menu) },
           help: template, menu: menu) { SettingsIcon(symbol: "link", artwork: ModuleArtwork.settings("links")) }
    }
}
