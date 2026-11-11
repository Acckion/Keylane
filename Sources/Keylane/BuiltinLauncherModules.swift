import AppKit
import Combine
import SwiftUI
import KeylaneCore

/// Composition point for the features present on dev. Construction stores
/// closures only; controllers are consulted when the host uses a contribution.
enum BuiltinLauncherModules {
    static func make(model: Model) -> [LauncherModule] {
        [host(model), applications(model), files(model), clipboard(model), notes(model),
         links(model), calculator(model), systemTools(), CalendarLauncherModule.make(model: model)]
        + NavigationLauncherModules.make(model: model) + UtilityLauncherModules.make(model: model)
    }

    private static func command(_ id: String, _ title: String, _ detail: String, _ symbol: String,
                                _ keywords: [String], destination: LauncherCommandDeclaration.Destination = .action,
                                settings: String? = nil,
                                available: @escaping () -> Bool = { true },
                                dynamicDetail: (() -> String)? = nil,
                                execute: @escaping (LauncherCommandOrigin) -> Void = { _ in }) -> LauncherModule.Command {
        LauncherModule.Command(
            declaration: .init(id: .init(rawValue: id), title: title, detail: detail, symbol: symbol,
                               keywords: keywords, destination: destination, settingsPage: settings),
            detail: dynamicDetail, available: available, execute: execute
        )
    }

    private static func host(_ model: Model) -> LauncherModule {
        .init(id: .init(rawValue: "keylane.host"),
              commands: [command("settings", "Keylane 设置", "偏好设置与隐私", "gearshape",
                                 ["Settings", "Preferences", "设置", "偏好设置"], destination: .settings(nil), settings: "general")],
              settings: [settingsPage(model, "general", "通用", "slider.horizontal.3", "管理外观、快捷键和启动方式。", 0, content: LauncherSettingsContent.general),
                         settingsPage(model, "launcher", "启动器", "magnifyingglass", "管理启动器的显示与搜索行为。", 5) {
                             LauncherBehaviorPreferences(model: $0)
                         },
                         settingsPage(model, "keyboard", "键盘", "keyboard", "管理按键行为、导航和 Hyper Key。", 6) {
                             KeyboardPreferences(model: $0)
                         },
                         settingsPage(model, "menu-bar", "菜单栏", "menubar.rectangle", "选择各模块在菜单栏中显示的项目。", 70) {
                             MenuBarPreferences(registry: $0.menuBar)
                         },
                         settingsPage(model, "permissions", "权限", "lock.shield", "查看和管理 Keylane 使用的系统权限。", 95) {
                             PermissionsPreferences(model: $0)
                         },
                         settingsPage(model, "advanced", "高级", "wrench.and.screwdriver", "管理窗口、导出和连接设置。", 100, content: LauncherSettingsContent.advanced),
                         settingsPage(model, "about", "关于 Keylane", "info.circle", "独立、原生、以键盘为中心。", 110, content: LauncherSettingsContent.about)])
    }

    private static func applications(_ model: Model) -> LauncherModule {
        let provider = LauncherModule.Provider(namespace: .prefix("app:"), entries: { [weak model] _ in
            guard let model, model.applicationsEnabled else { return [] }
            return model.apps.filter { !model.excluded.contains($0.path) }.map { url in
                let identity = model.discoveredIdentity(for: url)
                let path = url.path
                return Entry(id: path, commandID: .init(rawValue: "app:" + path),
                             name: identity?.displayName ?? url.deletingPathExtension().lastPathComponent,
                             detail: "Application", symbol: "app", aliases: identity?.aliases ?? [])
            }
        }, resolve: { [weak model] id, origin in
            guard id.rawValue.hasPrefix("app:"), let model, model.applicationsEnabled else { return nil }
            let path = String(id.rawValue.dropFirst("app:".count))
            guard !model.excluded.contains(path), model.apps.contains(where: { $0.path == path }),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            return { [weak model] in
                if origin == .shortcut { model?.launchFromHotkey(url) }
                else { model?.launch(url) }
            }
        }, actions: { [weak model] entry in model.map { $0.applicationResultActions.actions(for: entry, model: $0) } })
        return .init(id: .init(rawValue: "keylane.applications"), providers: [provider],
                     settings: [settingsPage(model, "applications", "应用程序", "square.grid.2x2.fill", "快速查找并启动已安装的应用程序。", 10, titlebar: SettingsTitlebarContribution(
                         title: "启用应用程序", help: "启用应用搜索和应用快捷键",
                         enabled: Binding(get: { [weak model] in model?.applicationsEnabled ?? false },
                                          set: { [weak model] in model?.applicationsEnabled = $0 }),
                         updates: model.$applicationsEnabled.removeDuplicates().eraseToAnyPublisher(),
                         info: { [weak model] in
                             guard let model else { return AnyView(EmptyView()) }
                             return AnyView(ApplicationSettingsInfo(model: model))
                         }
                     ), content: LauncherSettingsContent.applications)],
                     services: [.init(start: { [weak model] in model?.startApplicationDiscovery() },
                                      stop: { [weak model] in model?.stopApplicationDiscovery() })],
                     searchUpdates: [updates(model.$apps), updates(model.$applicationsEnabled)])
    }

    static func fileEntry(_ file: SpotlightFile) -> Entry {
        Entry(id: file.id, commandID: .init(rawValue: "file:" + file.id),
              name: file.name, detail: "File", symbol: "doc", rankingKind: .file, isDirectory: file.isDirectory)
    }

    private static func files(_ model: Model) -> LauncherModule {
        let page = PageID(rawValue: "Files")
        let provider = LauncherModule.Provider(namespace: .prefix("file:"), entries: { [weak model] input in
            guard let model, input.page == .root, model.fileSearch.options.enabled,
                  model.fileSearch.options.searchFromLauncher,
                  !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return model.fileResults.lazy.filter { $0.url.pathExtension.lowercased() != "app" }.prefix(10).map(fileEntry)
        }, resolve: { [weak model] id, _ in
            guard id.rawValue.hasPrefix("file:"), let model, model.fileSearch.options.enabled,
                  !model.fileSearch.isSearching else { return nil }
            let path = String(id.rawValue.dropFirst("file:".count))
            guard let file = model.fileResults.first(where: { $0.id == path }) else { return nil }
            return { [weak model] in model?.openFile(file.url) }
        }, actions: { [weak model] entry in model.map { fileActions(entry, model: $0) } })
        return .init(id: .init(rawValue: "keylane.files"), commands: [
            command("file-search", "搜索文件", "Spotlight", "doc.text.magnifyingglass",
                    ["File Search", "Spotlight"], destination: .page(page), settings: "files",
                    available: { [weak model] in model?.fileSearch.options.enabled == true }),
            command("ask-files", "询问文件搜索", "AI", "sparkles", ["Ask File Search"], settings: "files",
                    available: { [weak model] in model.map { $0.fileAI.commandsEnabled["ask-files"] != false } ?? false }, execute: { [weak model] origin in
                guard let model else { return }
                if origin == .shortcut { (NSApp.delegate as? Delegate)?.hideLauncher() }
                model.fileAI.present(model.fileResults.map(\.url))
            }),
            command("ask-finder", "询问 Finder", "AI", "sparkles", ["Ask Finder"], settings: "files",
                    available: { [weak model] in model.map { $0.fileAI.commandsEnabled["ask-finder"] != false } ?? false }, execute: { [weak model] origin in
                if origin == .shortcut { (NSApp.delegate as? Delegate)?.hideLauncher() }
                model?.fileAI.presentFinder()
            })
        ], providers: [provider], pages: [
            LauncherPage(id: page, placeholder: "搜索文件…", badge: ("文件搜索", "doc.text.magnifyingglass"),
                         contentPlacement: .fileResults, queryChanged: { [weak model] in model?.fileSearch.search($0) },
                         leave: { [weak model] in model?.fileSearch.cancel() },
                         updates: model.fileSearch.$isSearching.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
                         releasePreview: { FilePreview.shared.dismiss() })
        ], settings: [settingsPage(model, "files", "文件搜索", "doc.text.magnifyingglass", "搜索电脑上的文件与文件夹。", 20, titlebar: SettingsTitlebarContribution(
                         title: "启用文件搜索",
                         enabled: Binding(get: { [weak model] in model?.fileSearch.options.enabled ?? false },
                                          set: { [weak model] in model?.fileSearch.options.enabled = $0 }),
                         updates: model.fileSearch.$options.map(\.enabled).removeDuplicates().eraseToAnyPublisher()
                     ), content: LauncherSettingsContent.files)],
           searchUpdates: [updates(model.$fileResults),
                           updates(model.fileSearch.$options.map { [$0.enabled, $0.searchFromLauncher] }),
                           updates(model.fileAI.$commandsEnabled)])
    }

    private static func fileActions(_ entry: Entry, model: Model) -> [LauncherAction] {
        let url = URL(fileURLWithPath: entry.id)
        return [
            openAction("打开文件", entry: entry, model: model),
            .init(id: "preview", title: "快速查看", icon: "eye") { [weak model] in
                if FileManager.default.fileExists(atPath: url.path) { FilePreview.shared.show(url) }
                else { model?.error = "文件已移走或删除。"; model?.searchFiles() }
            },
            .init(id: "open-with-file", title: "打开方式…", icon: "app") { FileActionsWindow.shared.show(url, page: "open") },
            .init(id: "share-file", title: "分享…", icon: "square.and.arrow.up") { FileActionsWindow.shared.show(url, page: "share") },
            .init(id: "ask-file", title: "询问此文件…", icon: "sparkles") { [weak model] in model?.fileAI.present([url]) },
            .init(id: "reveal-file", title: "在 Finder 中显示", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            copyPathAction(id: "copy-file-path", url: url),
            model.favoriteAction(for: entry)
        ]
    }

    private static func openAction(_ title: String, entry: Entry, model: Model) -> LauncherAction {
        .init(id: "open", title: title, icon: "return", keys: ["↩"]) { [weak model] in
            model?.runCommand(entry.commandID, origin: .menu, usageKey: entry.id)
        }
    }

    private static func copyPathAction(id: String, url: URL) -> LauncherAction {
        .init(id: id, title: "复制路径", icon: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }

    private static func clipboard(_ model: Model) -> LauncherModule {
        let id = PageID(rawValue: "Clipboard")
        let controller = model.clipboard
        let page = LauncherPage(
            id: id, placeholder: "搜索剪贴板历史…", badge: ("剪贴板历史", "list.clipboard"), actionTitle: "剪贴板操作",
            contentPlacement: .underChrome,
            content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(ClipboardHistoryView(controller: model.clipboard, query: model.query))
            },
            queryChanged: { [weak model] in model?.clipboard.search($0) },
            leave: { [weak model] in model?.clipboard.endPresentation() },
            move: { [weak model] in model?.clipboard.move($0) },
            submit: { [weak model] in
                guard let controller = model?.clipboard else { return }
                if controller.primaryAction == "paste" { (NSApp.delegate as? Delegate)?.pasteClipboard() }
                else { controller.copySelected() }
            },
            shortcutSubmit: { (NSApp.delegate as? Delegate)?.pasteClipboard() },
            primaryTitle: { [weak model] in model?.clipboard.primaryAction == "paste" ? "粘贴" : "复制" },
            actions: { [weak model] in
                guard let controller = model?.clipboard else { return [] }
                return clipboardActions(controller)
            },
            updates: Publishers.MergeMany([
                ViewObservation.changes(model.clipboard.$selectedID),
                ViewObservation.changes(model.clipboard.$items),
                ViewObservation.changes(model.clipboard.$primaryAction),
                ViewObservation.changes(model.clipboard.$kind)
            ]).eraseToAnyPublisher(),
            typeFilterWidth: 138,
            typeFilter: { [weak model] open in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(ResultTypeFilter(selection: Binding(get: { model.clipboard.kind }, set: { model.clipboard.kind = $0 }),
                                         options: ResultFilterOption.clipboard, open: open, navigation: model.navigation))
            }
        )
        return .init(id: .init(rawValue: "keylane.clipboard"), commands: [
            command("clipboard", "剪贴板历史", "本地文字、图片和文件历史", "clipboard",
                    ["Clipboard History", "剪切板", "剪贴板", "复制历史"], destination: .page(id), settings: "clipboard")
        ], pages: [page], settings: [
            settingsPage(model, "clipboard", "剪贴板历史", "clipboard.fill", "查找本地保存的文字、图片和文件引用。", 40, titlebar: .init(
                title: SettingsItem.clipboardCapture.title,
                help: "控制后台采集，已保存的记录仍可查看。",
                enabled: Binding(get: { controller.captureEnabled }, set: { controller.captureEnabled = $0 }),
                updates: controller.$captureEnabled.removeDuplicates().eraseToAnyPublisher(),
                searchItem: .clipboardCapture
            ), content: LauncherSettingsContent.clipboard)
        ], services: [
            .init(start: { [weak model] in model?.clipboard.startMonitoring() },
                  stop: { [weak model] in model?.clipboard.stopMonitoring() })
        ])
    }

    private static func clipboardActions(_ controller: ClipboardController) -> [LauncherAction] {
        guard let item = controller.items.first(where: { $0.id == controller.selectedID }) else { return [] }
        var actions = [
            LauncherAction(id: "copy-clip", title: "复制", icon: "doc.on.doc", keys: ["↩"], perform: { controller.copySelected() }),
            LauncherAction(id: "copy-plain-clip", title: "复制为纯文本", icon: "text.alignleft", perform: { controller.copySelected(plainText: true) }),
            LauncherAction(id: "paste-plain-clip", title: "粘贴为纯文本", icon: "text.insert", perform: { (NSApp.delegate as? Delegate)?.pasteClipboard(plainText: true) }),
            LauncherAction(id: "paste-clip", title: "粘贴到上个应用", icon: "doc.on.clipboard", keys: ["⌘", "↩"], perform: { (NSApp.delegate as? Delegate)?.pasteClipboard() }),
            LauncherAction(id: "pin-clip", title: item.pinned ? "取消置顶" : "置顶", icon: "pin", perform: { controller.pinSelected() })
        ]
        if item.kind == .image {
            actions.append(.init(id: "ocr-clip", title: "识别图片文字", icon: "text.viewfinder", perform: { controller.recognizeSelected() }))
        }
        actions.append(.init(id: "delete-clip", title: "删除记录", icon: "trash", perform: { controller.removeSelected() }))
        return actions
    }

    private static func notes(_ model: Model) -> LauncherModule {
        let id = PageID(rawValue: "Notes")
        return .init(id: .init(rawValue: "keylane.notes"), commands: [
            command("notes", "便笺", "本地便笺", "note.text", ["Notes", "便签", "笔记"],
                    destination: .page(id), settings: "notes")
        ], pages: [LauncherPage(id: id, placeholder: "便笺", content: { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(LauncherNotesPage(model: model))
        })], settings: [settingsPage(model, "notes", "便笺", "note.text", "保存你的想法，随时继续。", 80, content: LauncherSettingsContent.notes)])
    }

    private static func links(_ model: Model) -> LauncherModule {
        .init(id: .init(rawValue: "keylane.links"), commands: [
            command("quicklink", "快捷链接", "", "link", ["Quick Link", "快捷链接", "网址"], settings: "links",
                    dynamicDetail: { [weak model] in model?.link ?? "" }) { [weak model] _ in
                if let link = model?.link, let url = URL(string: link), ["https", "http"].contains(url.scheme ?? "") {
                    NSWorkspace.shared.open(url)
                }
            }
        ], settings: [settingsPage(model, "links", "快捷链接", "link", "设置常用链接，快速打开。", 90, content: LauncherSettingsContent.links)],
           searchUpdates: [updates(model.$link)])
    }

    private static func calculator(_ model: Model) -> LauncherModule {
        let id = CommandID(rawValue: "calculator")
        let provider = LauncherModule.Provider(namespace: .exact(id), entries: { input in
            guard let result = calculatorResult(input.query) else { return [] }
            return [Entry(id: id.rawValue, commandID: id, name: result, detail: "回车复制结果",
                          symbol: "equal", rankingKind: .calculator)]
        }, resolve: { [weak model] command, origin in
            guard command == id, origin != .shortcut, let query = model?.query, let result = calculatorResult(query) else { return nil }
            return {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
            }
        })
        let hintID = CommandID(rawValue: "calculator-hint")
        let hint = LauncherModule.Provider(namespace: .exact(hintID), entries: { input in
            let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.folding(options: .widthInsensitive, locale: .current).hasPrefix("="),
                  calculatorResult(query) == nil else { return [] }
            let message = query.count == 1 ? "输入计算表达式，如 2 × (3 + 4)" : "表达式不完整或无法计算"
            return [Entry(id: hintID.rawValue, commandID: hintID, name: message,
                          detail: "计算器", symbol: "equal", rankingKind: .calculator)]
        }, resolve: { _, _ in nil })
        return .init(id: .init(rawValue: "keylane.calculator"), commands: [
            command("calculator-help", "计算器", "在搜索框输入表达式", "equal.circle", ["Calculator", "计算"], execute: { [weak model] _ in
                model?.query = "="
            })
        ], providers: [provider, hint])
    }

    private static func calculatorResult(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Calculator.isExpression(trimmed), let value = Calculator.evaluate(trimmed) else { return nil }
        return String(format: "%.12g", value)
    }

    private static func systemTools() -> LauncherModule {
        .init(id: .init(rawValue: "keylane.system-tools"), commands: [
            command("screenshot", "Screenshot / 截图", "Select region · copy image", "camera.viewfinder", [], execute: { _ in
                (NSApp.delegate as? Delegate)?.hideLauncher()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { SystemTools.shared.screenshot() }
            }),
            command("color", "Pick Color / 取色", "Copy hex color", "eyedropper", [], execute: { _ in SystemTools.shared.colorPicker() }),
            command("speak", "Read Clipboard / 朗读", "System text to speech", "speaker.wave.2", [], execute: { _ in SystemTools.shared.readClipboard() }),
            command("stop-speaking", "Stop Reading / 停止朗读", "Stop speech playback", "stop.circle", [], execute: { _ in SystemTools.shared.stopReading() }),
            command("finder", "Open Home / 个人文件夹", "Finder", "folder", [], execute: { _ in NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser) })
        ])
    }

    private static func updates<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never>
        where P.Output: Equatable, P.Failure == Never {
        publisher.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
    }

    private static func settingsPage<Content: View>(_ model: Model, _ id: String, _ title: String, _ symbol: String,
                                     _ subtitle: String, _ order: Int, titlebar: SettingsTitlebarContribution? = nil, content: @escaping (Model) -> Content) -> LauncherSettingsPage {
        .init(id: id, title: title, symbol: symbol, subtitle: subtitle, order: order, items: SettingsItem.all.filter { $0.page == id }, titlebar: titlebar) { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(content(model))
        }
    }
}
