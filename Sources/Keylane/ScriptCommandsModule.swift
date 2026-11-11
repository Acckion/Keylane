import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum ScriptCommandsModule {
    private static let settingsID = "script-commands"
    private static let pageID = PageID(rawValue: "RunScript")
    private static let searchPageID = PageID(rawValue: "SearchScripts")
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
        model.commands.filter { $0.id.hasPrefix(ScriptCommand.namespace) }
    }

    static func selectedIndex(_ model: Model, count: Int) -> Int {
        NavigationBounds.move(model.scripts.searchSelection, by: 0, count: count)
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
                                     destination: action == .search ? .page(searchPageID) : .action, settingsPage: settingsID),
                  available: { controller.enabled && !controller.disabled.contains(action.rawValue) },
                  execute: { _ in
                      switch action {
                      case .create: controller.createScript()
                      case .reload:
                          controller.refresh(force: true) { count in
                              let toast = (NSApp.delegate as? Delegate)?.toast
                              if controller.unavailable.isEmpty {
                                  toast?.show("已重新加载 \(count) 个脚本", style: .success)
                              } else {
                                  toast?.show("已加载 \(count) 个脚本，部分文件夹无法读取。", style: .failure)
                              }
                          }
                      case .search: break
                      }
                  })
        }
    }

    static func make(model: Model) -> LauncherModule {
        let controller = model.scripts
        let provider = LauncherModule.Provider(namespace: .prefix(ScriptCommand.namespace), entries: { _ in
            controller.entries.filter(controller.canRun).map { script in
                Entry(id: script.id, commandID: .init(rawValue: script.id), name: script.title,
                      detail: "脚本命令", symbol: symbol, aliases: [script.url.lastPathComponent])
            }
        }, resolve: { [weak model] id, origin in
            guard let model, let script = controller.entries.first(where: { $0.id == id.rawValue }),
                  controller.canRun(script) else { return nil }
            return {
                if controller.running && controller.selected != script {
                    model.error = "已有脚本正在运行。"
                    return
                }
                if controller.selected != script { controller.select(script) }
                model.openPage(pageID, origin: origin)
            }
        }, primaryTitle: { _ in "打开脚本" })
        let settings = LauncherSettingsPage(
            id: settingsID, title: "脚本命令", symbol: symbol, subtitle: "从指定文件夹发现并运行本机脚本。",
            order: 65, items: [.scriptFolders, .scriptCommands],
            titlebar: .init(title: "启用脚本命令", enabled: Binding(get: { controller.enabled }, set: { controller.enabled = $0 }),
                            updates: controller.$enabled.removeDuplicates().eraseToAnyPublisher(),
                            info: { AnyView(Text("添加脚本文件夹后，可以搜索并显式运行其中的脚本。")) }),
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
                              perform: { UtilityActions.copy(result.output) })]
            },
            updates: Publishers.Merge(ViewObservation.changes(controller.$running),
                                      ViewObservation.changes(controller.$result)).eraseToAnyPublisher(),
            enter: { _ in "" }
        )
        return .init(id: .init(rawValue: "keylane.script-commands"), commands: [
            .init(declaration: .init(id: .init(rawValue: "manage-script-commands"), title: "管理脚本命令",
                                    detail: "添加脚本文件夹和热键", symbol: symbol,
                                    keywords: ["Script Commands", "脚本", "Shell", "Python", "Node"],
                                    destination: .settings(settingsID), settingsPage: settingsID))
        ] + actionCommands(controller), providers: [provider], pages: [searchPage(model), page], settings: [settings],
        services: [.init(start: { controller.refresh() }, stop: controller.cancel)],
        searchUpdates: [
            ViewObservation.changes(controller.$entries),
            ViewObservation.changes(controller.$enabled),
            ViewObservation.changes(controller.$disabled)
        ], launcherShown: { controller.refresh() })
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
            ViewObservation.changes(model.scripts.$searchSelection)
        ]))
    }

    var body: some View {
        let entries = ScriptCommandsModule.results(model)
        let index = ScriptCommandsModule.selectedIndex(model, count: entries.count)
        SelectableResultList(selection: entries.indices.contains(index) ? entries[index].id : nil,
                             query: model.query, firstResult: entries.first?.id) {
            if entries.isEmpty {
                ContentUnavailableView("没有匹配的脚本", systemImage: "terminal",
                                       description: Text("可以在脚本命令设置中添加文件夹。"))
                    .frame(maxWidth: .infinity)
            }
            ForEach(entries) { entry in
                ResultListButton(id: entry.id, action: { model.perform(entry) }) {
                    ResultListRow(selected: entries[index].id == entry.id) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                    } content: {
                        HighlightedResultText(text: entry.name, query: model.query).font(VisualStyle.rowText)
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
                detail: "扫描这些文件夹及子文件夹，支持 Shell、Python 和 JavaScript。",
                anchor: .scriptFolders, add: controller.addFolder, remove: controller.removeFolder
            ) {
                if !controller.unavailable.isEmpty {
                    Text("部分文件夹无法读取：\(controller.unavailable.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsSectionTitle(title: "命令").settingsAnchor(.scriptCommands)
            CommandSettingsList(items: ScriptCommandsModule.Action.allCases, id: \.rawValue) { action in
                CommandSettingsEntry(
                    title: action.title, model: model, commandID: action.id,
                    isEnabled: enabledBinding(action.rawValue),
                    perform: { model.runCommand(action.id, origin: .menu) },
                    icon: { Image(systemName: action.icon).foregroundStyle(.secondary) }
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
            if controller.scanning { ProgressView().controlSize(.small) }
            if !controller.entries.isEmpty {
                CommandSettingsList(items: controller.entries, id: \.id) { script in
                    let id = CommandID(rawValue: script.id)
                    return CommandSettingsEntry(
                        title: script.title, model: model, commandID: id,
                        isEnabled: enabledBinding(script.id),
                        perform: { model.runCommand(id, origin: .menu) },
                        icon: { Image(systemName: "terminal").foregroundStyle(.secondary) }
                    )
                }
                .disabled(!controller.enabled)
            }
        }
        .onAppear { controller.refresh(force: true) }
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !controller.disabled.contains(id) }, set: { enabled in
            if enabled { controller.disabled.remove(id) }
            else { controller.disabled.insert(id) }
        })
    }
}

private struct ScriptCommandRunView: View {
    @ObservedObject var controller: ScriptCommandsController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let script = controller.selected {
                    Label(script.title, systemImage: "terminal").font(.title3.weight(.semibold))
                    Text(script.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("参数")
                        TextField("例如：--name \"工作资料\"", text: $controller.arguments)
                            .accessibilityLabel("脚本参数")
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
                        ProgressView().controlSize(.small)
                        Text("正在运行")
                        Button("取消运行", action: controller.cancel)
                    }
                } else {
                    Button("运行脚本", systemImage: "play", action: controller.run)
                        .buttonStyle(ContentActionButtonStyle(prominent: true))
                }

                if !controller.error.isEmpty {
                    Label(controller.error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let result = controller.result {
                    Text(status(result.status)).font(.headline)
                    if !result.output.isEmpty {
                        Text(result.output).font(.system(.body, design: .monospaced))
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
