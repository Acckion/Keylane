import Combine
import KeylaneCore
import SwiftUI

enum ScriptCommandsModule {
    private static let settingsID = "script-commands"
    private static let pageID = PageID(rawValue: "RunScript")
    private static let symbol = "terminal"

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
        ], providers: [provider], pages: [page], settings: [settings],
        services: [.init(start: { controller.refresh() }, stop: controller.cancel)],
        searchUpdates: [
            ViewObservation.changes(controller.$entries),
            ViewObservation.changes(controller.$disabled)
        ], launcherShown: { controller.refresh() })
    }
}

private struct ScriptCommandsPreferences: View {
    let model: Model
    let controller: ScriptCommandsController
    @StateObject private var observation: ViewObservation
    @State private var query = ""

    init(model: Model, controller: ScriptCommandsController) {
        self.model = model
        self.controller = controller
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(controller.$folders),
            ViewObservation.changes(controller.$entries),
            ViewObservation.changes(controller.$disabled),
            ViewObservation.changes(controller.$scanning),
            ViewObservation.changes(controller.$unavailable)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsSearchScopeCard(
                paths: controller.folders,
                detail: "扫描这些文件夹及子文件夹，支持 Shell、Python 和 JavaScript。",
                anchor: .scriptFolders, add: controller.addFolder, remove: controller.removeFolder
            ) {
                if !controller.unavailable.isEmpty {
                    Text("部分文件夹无法读取：\(controller.unavailable.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsGroup {
                HStack {
                    SettingsSearchField(text: $query, placeholder: "查找脚本…")
                    if controller.scanning { ProgressView().controlSize(.small) }
                    SettingsIconButton("刷新脚本", symbol: "arrow.clockwise") { controller.refresh(force: true) }
                        .disabled(controller.scanning)
                }
            }.settingsAnchor(.scriptCommands)
            CommandSettingsList(items: controller.entries.filter {
                query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            }, id: \.id, emptyMessage: "没有匹配的脚本") { script in
                let id = CommandID(rawValue: script.id)
                return CommandSettingsEntry(
                    title: script.title, model: model, commandID: id,
                    isEnabled: Binding(get: { !controller.disabled.contains(script.id) }, set: { enabled in
                        if enabled { controller.disabled.remove(script.id) }
                        else { controller.disabled.insert(script.id) }
                    }),
                    perform: { model.runCommand(id, origin: .menu) },
                    icon: { Image(systemName: "terminal").foregroundStyle(.secondary) }
                )
            }
        }
        .onAppear { controller.refresh(force: true) }
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
