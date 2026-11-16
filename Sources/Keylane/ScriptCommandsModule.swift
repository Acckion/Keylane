import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum ScriptCommandsModule {
    private static let settingsID = "script-commands"
    private static let pageID = PageID(rawValue: "RunScript")
    private static let createPageID = PageID(rawValue: "CreateScript")
    private static let searchPageID = PageID(rawValue: "SearchScripts")
    private static let configurePageID = PageID(rawValue: "ConfigureScriptCommand")
    private static let symbol = "terminal"

    enum Action: String, CaseIterable {
        case create = "create-script-command"
        case reload = "reload-script-commands"
        case search = "search-script-commands"

        var id: CommandID { .init(rawValue: rawValue) }
        var title: String {
            switch self {
            case .create: "创建脚本命令"
            case .reload: "重新加载脚本命令"
            case .search: "搜索脚本命令"
            }
        }
        var english: String {
            switch self {
            case .create: "Create Script Command"
            case .reload: "Reload Script Commands"
            case .search: "Search Script Commands"
            }
        }
        var icon: String {
            switch self {
            case .create: "plus.square"
            case .reload: "arrow.clockwise"
            case .search: "magnifyingglass"
            }
        }
    }

    static func results(_ model: Model) -> [Entry] {
        model.commands(in: .prefix(ScriptCommand.namespace))
    }

    static func selectedIndex(_ model: Model, count: Int) -> Int {
        NavigationBounds.move(model.scripts.searchSelection, by: 0, count: count)
    }

    static func focusArguments(forAlias alias: String, model: Model) -> Bool {
        guard model.pageID == .root, !alias.isEmpty, let row = model.commands.first,
              let saved = model.aliases[row.id],
              alias.compare(saved, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame,
              let script = model.scripts.command(withID: row.id) else { return false }
        return model.scripts.beginRootArguments(script)
    }

    static func runRootArguments(_ model: Model, in window: NSWindow? = NSApp?.keyWindow) {
        let controller = model.scripts
        guard let script = controller.rootArgumentScript, let metadata = script.metadata,
              let session = controller.rootArgumentSession else { return }
        let submit: (Bool) -> Void = { [weak model] confirmed in
            guard let model, model.pageID == .root, controller.rootArgumentSession == session else { return }
            controller.submitRootArguments(confirmed: confirmed) { script in
                if script.metadata?.effectiveMode == .fullOutput { model.openPage(pageID, origin: .search) }
            }
        }
        guard metadata.needsConfirmation else { submit(false); return }
        guard let window, window.attachedSheet == nil, controller.validateRootArguments() else { return }
        let alert = NSAlert()
        alert.messageText = "运行「\(script.title)」？"
        alert.informativeText = metadata.description
        alert.addButton(withTitle: "运行")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            guard controller.rootArgumentSession == session else { return }
            if response == .alertFirstButtonReturn { submit(true) }
            else { controller.cancelRootArguments() }
        }
    }

    private static func searchPage(_ model: Model) -> LauncherPage {
        let controller = model.scripts
        return .init(id: searchPageID, placeholder: "搜索脚本命令…", badge: ("脚本命令", symbol),
                     contentPlacement: .underChrome,
                     content: { [weak model] in
                         guard let model else { return AnyView(EmptyView()) }
                         return AnyView(ScriptSearchView(model: model))
                     },
                     queryChanged: { _ in controller.searchSelection = 0 },
                     move: { [weak model] delta in
                         guard let model else { return }
                         let count = results(model).count
                         controller.searchSelection = NavigationBounds.move(selectedIndex(model, count: count), by: delta, count: count)
                     },
                     submit: { [weak model] in
                         guard let model else { return }
                         let entries = results(model)
                         if !entries.isEmpty { model.perform(entries[selectedIndex(model, count: entries.count)]) }
                     },
                     primaryTitle: { "打开脚本" },
                     enter: { _ in
                         controller.searchSelection = 0
                         controller.refresh()
                         return ""
                     })
    }

    private static func actionCommands(_ controller: ScriptCommandsController) -> [LauncherModule.Command] {
        Action.allCases.map { action in
            .init(declaration: .init(id: action.id, title: action.title, detail: "脚本命令", symbol: action.icon,
                                     keywords: [action.english],
                                     destination: action == .search ? .page(searchPageID) : action == .create ? .page(createPageID) : .action, settingsPage: settingsID),
                  settingsEnabled: controller.commandEnabledBinding(action.rawValue),
                  available: { controller.enabled && !controller.disabled.contains(action.rawValue) },
                  execute: { _ in
                      switch action {
                      case .create: controller.prepareCreation()
                      case .reload:
                          controller.refresh(force: true) { count in
                              let delegate = NSApp.delegate as? Delegate
                              if !controller.unavailable.isEmpty {
                                  delegate?.showLauncherFeedback("已加载 \(count) 个脚本，部分文件夹无法读取", style: .failure)
                              } else if count == 0 {
                                  delegate?.showLauncherFeedback("未找到脚本命令", style: .success)
                              } else {
                                  delegate?.showLauncherFeedback("已重新加载 \(count) 个脚本命令", style: .success)
                              }
                          }
                      case .search: break
                      }
                  })
        }
    }

    static func make(model: Model) -> LauncherModule {
        let controller = model.scripts
        let editor = ApplicationCommandEdit()
        let provider = LauncherModule.Provider(namespace: .prefix(ScriptCommand.namespace), entries: { _ in
            controller.entries.filter(controller.canRun).map { script in
                Entry(id: script.id, commandID: .init(rawValue: script.id), name: script.title,
                      detail: "脚本命令", symbol: symbol,
                      aliases: [script.url.lastPathComponent, script.metadata?.packageName ?? "", script.metadata?.description ?? ""],
                      subtitle: script.metadata.map {
                          $0.packageName.isEmpty ? script.url.deletingLastPathComponent().lastPathComponent : $0.packageName
                      })
            }
        }, resolve: { [weak model] id, origin in
            guard let model, let script = controller.command(withID: id.rawValue),
                  controller.canRun(script) else { return nil }
            return {
                if controller.running && controller.selected != script {
                    model.error = "已有脚本正在运行。"
                    return
                }
                if model.pageID == .root, origin == .search, !controller.running, script.metadata?.arguments.isEmpty == false {
                    if !controller.beginRootArguments(script) {
                        model.error = "此脚本已更改或不可用，请重新选择。"
                    } else if model.isCompact {
                        model.compactExpanded = true
                    }
                    return
                }
                if controller.selected != script || script.metadata != nil { controller.select(script) }
                if let metadata = script.metadata, metadata.arguments.isEmpty {
                    if metadata.effectiveMode == .fullOutput { model.openPage(pageID, origin: origin) }
                    controller.run()
                } else {
                    model.openPage(pageID, origin: origin)
                }
            }
        }, primaryTitle: { row in
            controller.command(withID: row.id)?.metadata?.arguments.isEmpty == false ? "填写参数" : "运行脚本"
        }, actions: { [weak model] row in
            guard let model, let script = controller.command(withID: row.id) else { return nil }
            if controller.runningScript?.id == script.id {
                return [.init(id: "cancel-script", title: "取消运行", icon: "stop.circle", perform: controller.cancel),
                        model.favoriteAction(for: row)]
            }
            return [
                .init(id: "script-run", title: script.metadata?.arguments.isEmpty == false ? "填写参数" : "运行脚本",
                      icon: "play", keys: ["↩"], perform: {
                    model.runCommand(row.commandID, origin: model.pageID == .root ? .search : .menu, usageKey: row.id)
                }),
                .init(id: "script-configure-run", title: "设置参数并运行", icon: "slider.horizontal.3", perform: {
                    guard !controller.running else { return }
                    controller.select(script)
                    model.openPage(pageID, origin: .menu)
                }),
                .init(id: "script-edit", title: "编辑脚本", icon: "pencil", group: 1, perform: {
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
                        NSWorkspace.shared.open([script.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                            guard let error else { return }
                            DispatchQueue.main.async {
                                (NSApp?.delegate as? Delegate)?.toast.show(error.localizedDescription, style: .failure)
                            }
                        }
                    }
                }),
                .init(id: "script-reveal", title: "在访达中显示", icon: "folder", group: 1, perform: {
                    NSWorkspace.shared.activateFileViewerSelecting([script.url])
                }),
                .init(id: "script-settings", title: "脚本命令设置…", icon: "gearshape", group: 2, perform: {
                    model.openSettings(page: settingsID)
                }),
                .init(id: "script-edit-command", title: "编辑别名与快捷键…", icon: "keyboard", group: 2, perform: {
                    guard controller.isAvailable(script), !model.disabledCommands.contains(row.commandID.rawValue),
                          model.launcherModules?.isCommandModuleEnabled(row.commandID) == true else { return }
                    editor.prepare(row, model: model, isAvailable: { [weak model = model] in
                        guard let model, !model.disabledCommands.contains(row.commandID.rawValue),
                              model.launcherModules?.isCommandModuleEnabled(row.commandID) == true,
                              let current = controller.command(withID: script.id) else { return false }
                        return controller.isAvailable(current)
                    })
                    model.openPage(configurePageID, origin: .search)
                }),
                model.favoriteAction(for: row)
            ]
        }, displayDetail: { _ in "脚本命令" }, artwork: { row in
            guard let script = controller.command(withID: row.id) else {
                return AnyView(Image(systemName: symbol))
            }
            return AnyView(ScriptArtwork(script: script))
        }, detailView: { row in
            guard let line = controller.inlineOutput[row.id], !line.isEmpty else { return nil }
            return AnyView(ScriptTerminalText(source: line))
        })
        let cancelID = CommandID(rawValue: "cancel-running-script")
        let cancellation = LauncherModule.Provider(namespace: .exact(cancelID), entries: { input in
            guard input.page == .root, let script = controller.runningScript else { return [] }
            return [Entry(id: cancelID.rawValue, commandID: cancelID,
                          name: "取消运行脚本", detail: "脚本命令", symbol: "stop.circle",
                          aliases: ["Cancel Running Script", script.title], subtitle: script.title)]
        }, resolve: { _, _ in
            controller.running ? controller.cancel : nil
        }, primaryTitle: { _ in "取消运行" })
        let fallbackID = CommandID(rawValue: "script-fallback")
        let fallback = LauncherModule.Provider(namespace: .exact(fallbackID), entries: { input in
            let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard input.page == .root, !query.isEmpty, let script = controller.fallback else { return [] }
            return [.init(id: fallbackID.rawValue, commandID: fallbackID,
                          name: "用「\(script.title)」处理输入", detail: "脚本命令", symbol: symbol, isFallback: true)]
        }, resolve: { [weak model] _, origin in
            guard let model, !controller.running, let script = controller.fallback else { return nil }
            let query = model.query
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return {
                controller.select(script)
                controller.argumentValues[0] = query
                if script.metadata?.effectiveMode == .fullOutput || script.metadata?.needsConfirmation == true {
                    model.openPage(pageID, origin: origin)
                }
                controller.run()
            }
        })
        let settings = LauncherSettingsPage(
            id: settingsID, title: "脚本命令", symbol: symbol, subtitle: "从指定文件夹发现并运行本机脚本。",
            order: 65, items: [.scriptFolders, .scriptCommands],
            titlebar: .init(title: "启用脚本命令", enabled: Binding(get: { controller.enabled }, set: { controller.enabled = $0 }),
                            updates: controller.$enabled.removeDuplicates().eraseToAnyPublisher()),
            loading: controller.$scanning.eraseToAnyPublisher(),
            content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(ScriptCommandsPreferences(model: model, controller: controller))
            })
        let page = LauncherPage(
            id: pageID, placeholder: "运行脚本", badge: ("脚本命令", symbol),
            contentPlacement: .underChrome,
            content: { AnyView(ScriptCommandRunView(controller: controller)) },
            submit: { if !controller.running { controller.run() } },
            primaryTitle: { controller.running ? "运行中" : "运行脚本" },
            actions: {
                if controller.running {
                    return [.init(id: "cancel-script", title: "取消运行", icon: "stop.circle", perform: controller.cancel)]
                }
                guard let result = controller.result, !result.output.isEmpty else { return [] }
                return [.init(id: "copy-script-output", title: "复制输出", icon: "doc.on.doc",
                              perform: { UtilityActions.copy(ScriptOutputText.plain(result.output)) })]
            },
            updates: Publishers.Merge(ViewObservation.changes(controller.$runningScript),
                                      ViewObservation.changes(controller.$result)).eraseToAnyPublisher(),
            enter: { _ in "" },
            loading: controller.$runningScript.map { $0 != nil }.removeDuplicates().eraseToAnyPublisher()
        )
        let create = LauncherPage(
            id: createPageID, placeholder: "", badge: ("创建脚本命令", "plus.square"),
            contentPlacement: .form,
            content: { [weak model] in
                AnyView(ScriptCreationPage(controller: controller) { model?.pageID = .root })
            },
            submit: controller.saveDraft, shortcutSubmit: controller.saveDraft,
            primaryTitle: { "创建脚本" },
            primaryEnabled: { controller.canSaveDraft },
            updates: Publishers.Merge(
                ViewObservation.changes(controller.$draft.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.removeDuplicates()),
                ViewObservation.changes(controller.$enabled)
            ).eraseToAnyPublisher()
        )
        let configure = LauncherPage(
            id: configurePageID, placeholder: "", badge: ("编辑脚本命令", "keyboard"),
            contentPlacement: .form,
            content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(ApplicationCommandEditPage(editor: editor, model: model, icon: { row in
                    if let script = controller.command(withID: row.id) { return AnyView(ScriptArtwork(script: script)) }
                    return AnyView(Image(systemName: symbol))
                }))
            },
            submit: { [weak model] in if let model { editor.save(model: model) } },
            primaryTitle: { "保存别名" }
        )
        return .init(id: .init(rawValue: "keylane.script-commands"), commands: [
            .init(declaration: .init(id: .init(rawValue: "manage-script-commands"), title: "管理脚本命令",
                                    detail: "添加脚本文件夹和热键", symbol: symbol,
                                    keywords: ["Script Commands", "脚本", "Shell", "Python", "Node"],
                                    destination: .settings(settingsID), settingsPage: settingsID))
        ] + actionCommands(controller), providers: [provider, cancellation, fallback], pages: [searchPage(model), page, create, configure], settings: [settings],
        services: [.init(start: controller.start, stop: controller.stop)],
        searchUpdates: [
            ViewObservation.changes(controller.$folders),
            ViewObservation.changes(controller.$entries),
            ViewObservation.changes(controller.$runningScript),
            ViewObservation.changes(controller.$enabled),
            ViewObservation.changes(controller.$fallbackID),
            ViewObservation.changes(controller.$disabled)
        ], launcherShown: { controller.setLauncherVisible(true) },
        launcherHidden: { controller.setLauncherVisible(false) },
        presentationUpdates: [ViewObservation.changes(controller.$inlineOutput)],
        dynamicCommandSettings: .init(
            model: model, items: { controller.entries }, title: \.title, commandID: \.id,
            updates: { [ViewObservation.changes(controller.$entries), ViewObservation.changes(controller.$disabled)] },
            entry: { $0.commandSettingsEntry(model: $1, controller: controller) }
        ))
    }
}

struct RootScriptArgumentBar: View {
    let script: ScriptCommand
    @ObservedObject var controller: ScriptCommandsController
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ScriptArtwork(script: script).frame(width: 20, height: 20).accessibilityHidden(true)
                Text(script.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                ForEach(Array((script.metadata?.arguments ?? []).enumerated()), id: \.offset) { index, argument in
                    ScriptArgumentInput(argument: argument, value: ScriptArgumentInput.value($controller.rootArgumentValues, at: index),
                                        inSearchBar: true, focusOnAppear: index == 0)
                }
            }
            if !controller.rootArgumentError.isEmpty {
                Text(controller.rootArgumentError)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onSubmit { if !SearchField.isComposing { submit() } }
    }
}

private struct ScriptArgumentInput: View {
    let argument: ScriptMetadata.Argument
    @Binding var value: String
    var inSearchBar = false
    var focusOnAppear = false
    @FocusState private var focused: Bool

    static func value(_ values: Binding<[String]>, at index: Int) -> Binding<String> {
        Binding(get: { values.wrappedValue.indices.contains(index) ? values.wrappedValue[index] : "" },
                set: { if values.wrappedValue.indices.contains(index) { values.wrappedValue[index] = $0 } })
    }

    var body: some View {
        Group {
            if inSearchBar {
                LauncherCreationControl(focused: focused) { field.textFieldStyle(.plain) }
                    .frame(maxWidth: .infinity)
            } else {
                field
            }
        }
        .accessibilityLabel(argument.placeholder)
        .task {
            guard focusOnAppear else { return }
            await Task.yield()
            if !Task.isCancelled { focused = true }
        }
    }

    @ViewBuilder private var field: some View {
        switch argument.kind {
        case .text:
            TextField(argument.placeholder, text: $value).focused($focused)
        case .password:
            SecureField(argument.placeholder, text: $value).focused($focused)
        case .dropdown:
            Picker(argument.placeholder, selection: $value) {
                Text(emptyChoice).tag("")
                ForEach(Array((argument.data ?? []).enumerated()), id: \.offset) { _, choice in
                    Text(choice.title).tag(choice.value)
                }
            }.labelsHidden().focused($focused)
        }
    }

    private var emptyChoice: String {
        if inSearchBar {
            return argument.optional == true ? "\(argument.placeholder)（可选）" : argument.placeholder
        }
        return argument.optional == true ? "无" : "请选择"
    }
}

private struct ScriptSearchView: View {
    let model: Model
    @StateObject private var observation: ViewObservation

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            model.rootSearchUpdates.eraseToAnyPublisher(),
            ViewObservation.changes(model.$query),
            ViewObservation.changes(model.scripts.$searchSelection),
            ViewObservation.changes(model.scripts.$inlineOutput)
        ]))
    }

    var body: some View {
        let entries = ScriptCommandsModule.results(model)
        let index = ScriptCommandsModule.selectedIndex(model, count: entries.count)
        SelectableResultList(selection: entries.indices.contains(index) ? entries[index].id : nil,
                             query: model.query, firstResult: entries.first?.id) {
            if entries.isEmpty {
                ContentUnavailableView("没有匹配的脚本", systemImage: "terminal",
                                       description: Text("请在脚本命令设置中添加文件夹，并在脚本中声明 @keylane.schemaVersion、@keylane.title 和 @keylane.mode。兼容 @raycast.*。"))
                    .frame(maxWidth: .infinity)
            }
            ForEach(entries) { entry in
                ResultListButton(id: entry.id, action: { model.perform(entry) }) {
                    ResultListRow(selected: entries[index].id == entry.id) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                    } content: {
                        HStack(spacing: 12) {
                            HighlightedResultText(text: entry.name, query: model.query).font(VisualStyle.rowText)
                            if let subtitle = entry.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer(minLength: 8)
                            if let line = model.scripts.inlineOutput[entry.id] {
                                ScriptTerminalText(source: line).lineLimit(1).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ScriptCommandsPreferences: View {
    let model: Model
    let controller: ScriptCommandsController
    @StateObject private var observation: ViewObservation

    init(model: Model, controller: ScriptCommandsController) {
        self.model = model
        self.controller = controller
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(controller.$folders),
            ViewObservation.changes(controller.$enabled),
            ViewObservation.changes(controller.$fallbackID),
            ViewObservation.changes(controller.$entries),
            ViewObservation.changes(controller.$disabled),
            ViewObservation.changes(controller.$scanning),
            ViewObservation.changes(controller.$unavailable)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsSearchScopeCard(
                title: "脚本文件夹", paths: controller.folders,
                detail: "扫描这些文件夹及子文件夹，只收录包含有效 @keylane.* 或 @raycast.* 命令元数据的脚本。",
                anchor: .scriptFolders, add: controller.addFolder, remove: controller.removeFolder
            ) {
                if !controller.unavailable.isEmpty {
                    Text("部分文件夹无法读取：\(controller.unavailable.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !controller.fallbackEntries.isEmpty {
                SettingsGroup {
                    SettingsRow("无匹配结果时使用脚本", detail: "将主搜索的输入作为脚本的第一个参数。") {
                        Picker("备用脚本", selection: Binding(get: { controller.fallbackID }, set: { controller.fallbackID = $0 })) {
                            Text("无").tag("")
                            ForEach(controller.fallbackEntries) { script in Text(script.title).tag(script.id) }
                        }
                        .labelsHidden()
                    }
                }
                .disabled(!controller.enabled)
            }
            SettingsSectionTitle(title: "命令").settingsAnchor(.scriptCommands)
            CommandSettingsList(items: ScriptCommandsModule.Action.allCases, id: \.rawValue) { action in
                CommandSettingsEntry(
                    title: action.title, model: model, commandID: action.id,
                    isEnabled: controller.commandEnabledBinding(action.rawValue),
                    perform: { model.runCommand(action.id, origin: .menu) },
                    icon: { SettingsIcon(symbol: action.icon, artwork: ModuleArtwork.settings("script-commands")) }
                )
            }
            .disabled(!controller.enabled)

            SettingsSectionTitle(title: "脚本命令")
            SettingsGroup {
                Button {
                    model.runCommand(ScriptCommandsModule.Action.create.id, origin: .menu)
                } label: {
                    SettingsRow {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.square").foregroundStyle(.secondary)
                            SettingsTitle("创建脚本命令")
                        }
                    } control: {
                        Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!controller.enabled || controller.disabled.contains(ScriptCommandsModule.Action.create.rawValue))
            }
            if !controller.entries.isEmpty {
                CommandSettingsList(items: controller.entries, id: \.id) { script in
                    script.commandSettingsEntry(model: model, controller: controller)
                }
                .disabled(!controller.enabled)
            }
        }
        .onAppear { controller.refresh() }
    }
}

private extension ScriptCommand {
    func commandSettingsEntry(model: Model, controller: ScriptCommandsController) -> CommandSettingsEntry<some View> {
        let commandID = CommandID(rawValue: id)
        return CommandSettingsEntry(
            title: title, model: model, commandID: commandID,
            isEnabled: controller.commandEnabledBinding(id),
            perform: { model.runCommand(commandID, origin: .menu) },
            icon: { ScriptArtwork(script: self).frame(width: 24, height: 24) }
        )
    }
}

private struct ScriptCommandRunView: View {
    @ObservedObject var controller: ScriptCommandsController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let script = controller.selected {
                    Label(script.title, systemImage: "terminal").font(.title3.weight(.semibold))
                    if let metadata = script.metadata {
                        if !metadata.description.isEmpty { Text(metadata.description).foregroundStyle(.secondary) }
                        if !metadata.author.isEmpty {
                            if let url = URL(string: metadata.authorURL),
                               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                                Link(metadata.author, destination: url)
                            } else {
                                Text(metadata.author).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(script.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    if let metadata = controller.selected?.metadata {
                        ForEach(Array(metadata.arguments.enumerated()), id: \.offset) { index, argument in
                            GridRow {
                                Text(argument.placeholder)
                                ScriptArgumentInput(argument: argument, value: ScriptArgumentInput.value($controller.argumentValues, at: index))
                            }
                        }
                    } else {
                        GridRow {
                            Text("参数")
                            TextField("例如：--name \"工作资料\"", text: $controller.arguments)
                                .accessibilityLabel("脚本参数")
                        }
                    }
                    GridRow {
                        Text("工作目录")
                        TextField("输入文件夹的绝对路径", text: $controller.directory)
                            .accessibilityLabel("工作目录")
                    }
                    GridRow {
                        Text("超时（秒）")
                        TextField("30", text: $controller.timeout).frame(width: 80)
                            .accessibilityLabel("超时秒数")
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(controller.running)
                .onSubmit { controller.run() }

                if controller.running {
                    HStack {
                        Text("正在运行")
                        Button("取消运行", action: controller.cancel)
                    }
                } else {
                    Button("运行脚本", systemImage: "play", action: controller.run)
                        .buttonStyle(ContentActionButtonStyle(prominent: true))
                }

                if controller.running, !controller.liveOutput.isEmpty {
                    ScriptTerminalText(source: controller.liveOutput).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !controller.error.isEmpty {
                    Label(controller.error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let result = controller.result {
                    Text(status(result.status)).font(.headline)
                    if !result.output.isEmpty, (controller.selected?.metadata?.effectiveMode ?? .fullOutput) == .fullOutput {
                        ScriptTerminalText(source: result.output).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if result.truncated { Text("输出超过 256 KB，已截断。").foregroundStyle(.secondary) }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .launcherScrollInsets()
    }

    private func status(_ status: ScriptRunner.Result.Status) -> String {
        switch status {
        case .exited(0): return "运行完成"
        case .exited(let code): return "运行失败，退出码 \(code)"
        case .signalled(let signal): return "进程已终止，信号 \(signal)"
        case .cancelled: return "已取消"
        case .timedOut: return "运行超时"
        }
    }
}
