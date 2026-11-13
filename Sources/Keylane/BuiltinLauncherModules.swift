import AppKit
import Combine
import SwiftUI
import KeylaneCore

/// Composition point for the features present on dev. Construction stores
/// closures only; controllers are consulted when the host uses a contribution.
enum BuiltinLauncherModules {
    static func make(model: Model) -> [LauncherModule] {
        let modules = [applications(model), host(model), files(model), clipboard(model), AppleNotesModule.make(model: model),
                       QuicklinksModule.make(model: model), calculator(model), systemTools(model), CalendarLauncherModule.make(model: model),
                       ScriptCommandsModule.make(model: model), AppUtilitiesModule.make(model: model), SnippetsModule.make(model: model), WindowManagementModule.make(model: model)]
            + NavigationLauncherModules.make(model: model) + UtilityLauncherModules.make(model: model)
        return modules.enumerated().map { index, module in
            guard module.canDisable, module.settings.isEmpty else {
                return module
            }
            let id = module.id.rawValue
            let title = module.displayTitle
            let symbol = module.displaySymbol
            let commands = module.commands
            let dynamic = module.dynamicCommandSettings
            let searchItem = SettingsItem(id: id, page: id, title: title,
                                           keywords: commands.flatMap { $0.declaration.keywords }.joined(separator: " "))
            var extensionModule = module
            extensionModule.settings = [.init(id: id, title: title, symbol: symbol,
                                               subtitle: "管理此扩展的命令、别名与快捷键。", order: 120 + index,
                                               items: [searchItem], titlebar: module.permissionTitlebar, content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                if !commands.isEmpty {
                    return AnyView(ExtensionCommandPreferences(model: model, commands: commands).settingsAnchor(searchItem))
                }
                return AnyView(SettingsPageSections {
                    if let list = dynamic?.matchingList(nil) { list(false) }
                    else {
                        SettingsGroup {
                            SettingsRow("搜索结果", detail: "在启动器中输入关键词，查找此扩展提供的项目。") { EmptyView() }
                        }
                    }
                }.settingsAnchor(searchItem))
            })]
            return extensionModule
        }
    }

    private static func command(_ id: String, _ title: String, _ detail: String, _ symbol: String,
                                _ keywords: [String], destination: LauncherCommandDeclaration.Destination = .action,
                                settings: String? = nil,
                                available: @escaping () -> Bool = { true },
                                permission: PermissionFeature? = nil,
                                dynamicDetail: (() -> String)? = nil,
                                settingsEnabled: Binding<Bool>? = nil,
                                execute: @escaping (LauncherCommandOrigin) -> Void = { _ in }) -> LauncherModule.Command {
        LauncherModule.Command(
            declaration: .init(id: .init(rawValue: id), title: title, detail: detail, symbol: symbol,
                               keywords: keywords, destination: destination, settingsPage: settings),
            detail: dynamicDetail, settingsEnabled: settingsEnabled, available: available, permission: permission, execute: execute
        )
    }

    private static func host(_ model: Model) -> LauncherModule {
        let category = ShortcutSettingsControls()
        return .init(id: .init(rawValue: "keylane.host"), origin: .application, title: "Keylane", symbol: "command",
              commands: [command("settings", "Keylane 设置", "偏好设置与隐私", "gearshape",
                                 ["Settings", "Preferences", "设置", "偏好设置"], destination: .settings(nil), settings: "general"),
                         command("show-onboarding", "Show Onboarding", "重新打开 Keylane 的首次引导",
                                 "sparkles.rectangle.stack", ["onboarding", "welcome", "首次引导", "新手引导"]) { _ in
                             (NSApp.delegate as? Delegate)?.showOnboarding()
                         }],
              settings: [settingsPage(model, "general", "通用", "slider.horizontal.3", "管理外观、快捷键和启动方式。", 0, content: LauncherSettingsContent.general),
                         settingsPage(model, "launcher", "启动器", "magnifyingglass", "管理启动器的显示与搜索行为。", 5) {
                             LauncherBehaviorPreferences(model: $0)
                         },
                         settingsPage(model, "keyboard", "键盘", "keyboard", "管理按键行为、导航和 Hyper Key。", 6) {
                             KeyboardPreferences(model: $0)
                         },
                         settingsPage(model, "hotkeys", "快捷键", "command", "按扩展管理命令别名与快捷键。", 7, trailingToolbar: { [weak model] in
                             AnyView(ShortcutSettingsToolbar(groups: model?.launcherModules?.shortcutCommandGroups ?? [],
                                                                    navigation: model?.navigation ?? "arrows", selection: category))
                         }) {
                             ShortcutSettingsPreferences(model: $0, selection: category)
                         },
                         settingsPage(model, "menu-bar", "菜单栏", "menubar.rectangle", "选择各模块在菜单栏中显示的项目。", 70) {
                             MenuBarPreferences(registry: $0.menuBar)
                         },
                         settingsPage(model, "permissions", "权限", "lock.shield", "查看和管理 Keylane 使用的系统权限。", 95,
                                      loading: model.calendar.$requesting.combineLatest(model.contacts.$requesting)
                                          .map { $0 || $1 }.removeDuplicates().eraseToAnyPublisher()) {
                             PermissionsPreferences(model: $0)
                         },
                         settingsPage(model, "advanced", "高级", "wrench.and.screwdriver", "管理窗口、导出和连接设置。", 100, content: LauncherSettingsContent.advanced),
                         settingsPage(model, "about", "关于 Keylane", "info.circle", "独立、原生、以键盘为中心。", 110,
                                      loading: model.updates.$busy.eraseToAnyPublisher(), content: LauncherSettingsContent.about)],
              shortcutSettingsBinding: .init(id: "launcher", title: "Keylane 热键", symbol: "command"))
    }

    private static func applications(_ model: Model) -> LauncherModule {
        let provider = LauncherModule.Provider(namespace: .prefix("app:"), entries: { [weak model] _ in
            guard let model, model.applicationsEnabled else { return [] }
            return model.applicationSearchEntries()
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
        let uninstallPage = PageID(rawValue: "ApplicationUninstall")
        let applicationActions = model.applicationResultActions
        let uninstallSelection = applicationActions.uninstallSelection
        let startUninstall: (String) -> Void = { [weak model] query in
            guard let model else { return }
            applicationActions.startUninstallSelection(catalog: model.applicationSettingsCatalog, query: query)
        }
        let submitUninstall: () -> Void = { [weak model] in
            guard let model, let item = uninstallSelection.selected else { return }
            model.applicationResultActions.uninstall(item.url, model: model, keepLauncher: true)
        }
        return .init(id: .init(rawValue: "keylane.applications"), commands: [
                         command("manage-auto-quit", "管理自动退出", "为应用配置离开前台后的退出时间", "app.badge.clock",
                                 ["Manage Auto Quit", "闲置退出"], settings: "applications",
                                 available: { [weak model] in model?.applicationsEnabled ?? false },
                                 execute: { [weak model] _ in model?.openSettings(page: "applications") }),
                         command("uninstall-application", "卸载应用程序", "选择应用并移到废纸篓", "trash",
                                 ["Uninstall Application", "移除应用"], destination: .page(uninstallPage), settings: "applications",
                                 available: { [weak model] in model?.applicationsEnabled ?? false })
                     ], providers: [provider], pages: [.init(
                        id: uninstallPage, placeholder: "查找要卸载的应用…", badge: ("卸载应用程序", "trash"),
                        contentPlacement: .underChrome,
                        content: {
                            AnyView(ApplicationUninstallPage(selection: uninstallSelection, submit: submitUninstall))
                        },
                        queryChanged: uninstallSelection.filter, leave: applicationActions.stopUninstallSelection,
                        move: uninstallSelection.move, submit: submitUninstall,
                        actionContextTitle: { uninstallSelection.selected?.title }, primaryTitle: { "卸载应用…" },
                        primaryEnabled: { uninstallSelection.selected != nil },
                        updates: Publishers.Merge(ViewObservation.changes(uninstallSelection.$selectedID),
                                                    ViewObservation.changes(uninstallSelection.$items)).eraseToAnyPublisher(),
                        enter: { query in startUninstall(query); return nil },
                        resume: { [weak model] in
                            guard let model else { return }
                            startUninstall(model.query)
                        }
                     ), .init(
                        id: ApplicationCommandEdit.pageID, placeholder: "", badge: ("编辑应用命令", "keyboard"),
                        contentPlacement: .form,
                        content: { [weak model] in
                            guard let model else { return AnyView(EmptyView()) }
                            return AnyView(ApplicationCommandEditPage(editor: model.applicationResultActions.commandEditor, model: model))
                        },
                        submit: { [weak model] in
                            guard let model else { return }
                            model.applicationResultActions.commandEditor.save(model: model)
                        },
                        primaryTitle: { "保存别名" }
                     )],
                     settings: [settingsPage(model, "applications", "应用程序", "square.grid.2x2.fill", "快速查找并启动已安装的应用程序。", 10, titlebar: SettingsTitlebarContribution(
                         title: "启用应用程序", help: "启用应用搜索和应用快捷键",
                         enabled: Binding(get: { [weak model] in model?.applicationsEnabled ?? false },
                                          set: { [weak model] in model?.applicationsEnabled = $0 }),
                         updates: model.$applicationsEnabled.removeDuplicates().eraseToAnyPublisher()
                     ), content: LauncherSettingsContent.applications)],
                     services: [.init(start: { [weak model] in
                         model?.startApplicationDiscovery()
                         model?.applicationAutoQuit.start { [weak model] in model?.applicationsEnabled ?? false }
                     }, stop: { [weak model] in
                         model?.applicationResultActions.stopUninstallSelection()
                         model?.stopApplicationDiscovery()
                         model?.applicationAutoQuit.stop()
                         model?.releaseApplicationCatalog()
                     })],
                     searchUpdates: [updates(model.$apps), updates(model.$applicationsEnabled)],
                     dynamicCommandSettings: .init(
                         model: model, items: { [weak model] in model?.applicationSettingsCatalog.items ?? [] },
                         title: \.title, commandID: \.commandID, aliasKey: \.id,
                         updates: { [weak model] in
                             guard let model else { return [] }
                             return [ViewObservation.changes(model.applicationSettingsCatalog.$items),
                                     ViewObservation.changes(model.$excluded),
                                     ViewObservation.changes(model.$favorites)]
                         },
                         entry: { $0.commandSettingsEntry(model: $1) }
                     ))
    }

    static func fileEntry(_ file: SpotlightFile) -> Entry {
        Entry(id: file.id, commandID: .init(rawValue: "file:" + file.id),
              name: file.name, detail: "File", symbol: "doc", rankingKind: .file, isDirectory: file.isDirectory,
              subtitle: file.matchesContent ? "正文匹配" : nil)
    }

    static let fileSearchPage = PageID(rawValue: "Files")

    private static func files(_ model: Model) -> LauncherModule {
        let controller = model.fileSearch
        let permission = PermissionFeature("fileSearch.scopeOptIn", authorization: .init(
            check: { controller.hasAuthorizedScope },
            request: { complete in
                controller.addScope()
                complete(controller.hasAuthorizedScope)
            },
            guidance: "请通过启用开关选择可访问的文件夹。文件搜索只会扫描你授权的范围。"
        ), observeImmediately: false)
        var permissionChanges: AnyCancellable?
        func start(reconcile: Bool) {
            controller.startRuntime()
            permission.startObserving()
            controller.applyPermissionEnabled(permission.available)
            if reconcile && !controller.indexing { controller.startIndex() }
            let scopeChanges = controller.$options.map { [$0.enabled ? "enabled" : "disabled"] + $0.roots }
            permissionChanges = Publishers.Merge(permission.updates, ViewObservation.changes(scopeChanges))
                .receive(on: DispatchQueue.main).sink {
                    permission.recheck()
                    controller.applyPermissionEnabled(permission.available)
                }
        }
        let page = fileSearchPage
        let provider = LauncherModule.Provider(namespace: .prefix("file:"), entries: { [weak model] input in
            guard let model, input.page == .root, model.fileSearch.options.enabled,
                  model.fileSearch.lastPublishedQuery == input.query,
                  !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            if FileSearchLocation.typedURL(input.query) != nil, let file = model.fileResults.first {
                var entry = fileEntry(file)
                entry.matchScore = 1000
                entry.rankingKind = .command
                entry.subtitle = "在 Finder 中打开位置"
                return [entry]
            }
            guard model.fileSearch.options.searchFromLauncher else { return [] }
            let reserveScripts = model.launcherModules?.isModuleEnabled(.init(rawValue: "keylane.script-commands")) != false
            return model.fileResults.lazy.filter {
                $0.url.pathExtension.lowercased() != "app" &&
                    ($0.isDirectory || !reserveScripts || !ScriptCommand.reservesLauncherResult($0.url, in: model.scripts.folders))
            }.prefix(10).map(fileEntry)
        }, resolve: { [weak model] id, _ in
            guard id.rawValue.hasPrefix("file:"), let model, model.fileSearch.options.enabled,
                  model.fileSearch.lastPublishedQuery == model.query, !model.fileSearch.isSearching else { return nil }
            let path = String(id.rawValue.dropFirst("file:".count))
            guard let file = model.fileResults.first(where: { $0.id == path }) else { return nil }
            let directPath = model.pageID == .root && FileSearchLocation.typedURL(model.query) != nil
            return { [weak model] in
                guard let model else { return }
                if directPath {
                    model.withFileResult(file.url) { item in
                        if item.isDirectory { model.openFile(item.url) }
                        else {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            (NSApp.delegate as? Delegate)?.hideLauncher()
                        }
                    }
                } else { model.openFile(file.url) }
            }
        }, primaryTitle: { $0.rankingKind == .command ? "在 Finder 中打开位置" : nil },
        actions: { [weak model] entry in model.map { fileActions(entry, model: $0) } })
        return .init(id: .init(rawValue: "keylane.files"), commands: [
            command("file-search", "搜索文件", "Spotlight", "doc.text.magnifyingglass",
                    ["File Search", "Spotlight"], destination: .page(page), settings: "files",
                    permission: permission),
            command("rebuild-file-index", "重建文件索引", "重新检查已授权范围并更新索引", "arrow.clockwise",
                    ["Rebuild File Index", "Reindex Files"], settings: "files",
                    available: { controller.options.enabled && !controller.indexPaused }, execute: { [weak model] _ in
                        controller.startIndex(force: true)
                        model?.fileActionFeedback("正在重建文件索引", style: .neutral)
                    }),
            command("toggle-file-index", "暂停或恢复文件索引", "继续使用已建立的索引", "pause.circle",
                    ["Pause File Index", "Resume File Index"], settings: "files",
                    available: { controller.options.enabled },
                    dynamicDetail: { controller.indexPaused ? "当前已暂停" : "当前已启用" },
                    execute: { [weak model] _ in
                        controller.setIndexPaused(!controller.indexPaused)
                        model?.fileActionFeedback(controller.indexPaused ? "已暂停文件索引" : "已恢复文件索引", style: .neutral)
                    }),
            command("ask-files", "询问文件搜索", "AI", "sparkles", ["Ask File Search"], settings: "files",
                    available: { [weak model] in model.map { $0.fileSearch.options.enabled && $0.fileAI.commandsEnabled["ask-files"] != false } ?? false },
                    settingsEnabled: model.fileAI.commandEnabledBinding("ask-files"), execute: { [weak model] origin in
                guard let model else { return }
                if origin == .shortcut { (NSApp.delegate as? Delegate)?.hideLauncher() }
                model.fileAI.present(model.fileResults.map(\.url))
            }),
            command("ask-finder", "询问 Finder", "AI", "sparkles", ["Ask Finder"], settings: "files",
                    available: { [weak model] in model.map { $0.fileSearch.options.enabled && $0.finderAutomation.available && $0.fileAI.commandsEnabled["ask-finder"] != false } ?? false },
                    settingsEnabled: model.fileAI.commandEnabledBinding("ask-finder"), execute: { [weak model] origin in
                if origin == .shortcut { (NSApp.delegate as? Delegate)?.hideLauncher() }
                model?.fileAI.presentFinder()
            })
        ], providers: [provider], pages: [
            LauncherPage(id: page, placeholder: "搜索文件…", badge: ("文件搜索", "doc.text.magnifyingglass"),
                         contentPlacement: .fileResults, queryChanged: { [weak model] _ in model?.searchFiles() },
                         leave: { [weak model] in model?.fileSearch.cancel() },
                         updates: model.fileSearch.$isSearching.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
                         enter: { [weak model] _ in
                             let seed = model?.fileSearchSeed
                             model?.fileSearchSeed = nil
                             return seed
                         },
                         releasePreview: { FilePreview.shared.dismiss() },
                          loading: controller.$isSearching.eraseToAnyPublisher())
        ], settings: [settingsPage(model, "files", "文件搜索", "doc.text.magnifyingglass", "搜索电脑上的文件与文件夹。", 20, titlebar: permission.titlebar("启用文件搜索"),
                                   loading: controller.$indexing.eraseToAnyPublisher(), content: LauncherSettingsContent.files)],
           services: [.init(start: { start(reconcile: false) }, stop: { [weak model] in
               permissionChanges?.cancel()
               permissionChanges = nil
               permission.stopObserving()
               controller.stopRuntime()
               FilePreview.shared.dismiss(owner: .fileSearch)
               model?.fileAI.stopPresentation()
               FileActionsWindow.shared.dismiss(owner: .fileSearch)
           }, resume: { [weak model] in
               start(reconcile: true)
               if let model, model.searchesFilesHere, (NSApp.delegate as? Delegate)?.window?.isVisible == true {
                   model.searchFiles()
               }
           })],
           searchUpdates: [updates(model.$fileResults),
                           updates(model.fileSearch.$options.map { [$0.enabled, $0.searchFromLauncher] }),
                           updates(model.fileAI.$commandsEnabled), model.finderAutomation.updates,
                           updates(controller.$indexPaused)],
           shortcutSettingsUpdates: [ViewObservation.changes(model.fileAI.$commandsEnabled)])
    }

    private static func fileActions(_ entry: Entry, model: Model) -> [LauncherAction] {
        let url = URL(fileURLWithPath: entry.id)
        let title = entry.rankingKind == .command ? "在 Finder 中打开位置"
            : entry.isDirectory ? "在 Finder 中打开文件夹" : "打开文件"
        var actions = [
            openAction(title, entry: entry, model: model),
            .init(id: "preview", title: "快速查看", icon: "eye") { [weak model] in
                model?.withFileResult(url) { FilePreview.shared.show($0.url, owner: .fileSearch) }
            },
            .init(id: "open-with-file", title: "打开方式…", icon: "app") { [weak model] in
                model?.withFileResult(url) { FileActionsWindow.shared.show($0.url, page: "open", owner: .fileSearch) }
            },
            .init(id: "share-file", title: "分享…", icon: "square.and.arrow.up") { [weak model] in
                model?.withFileResult(url) { FileActionsWindow.shared.show($0.url, page: "share", owner: .fileSearch) }
            },
            .init(id: "ask-file", title: "询问此文件…", icon: "sparkles") { [weak model] in
                model?.withFileResult(url) { model?.fileAI.present([$0.url]) }
            },
            .init(id: "reveal-file", title: "在 Finder 中显示", icon: "folder") { [weak model] in
                model?.withFileResult(url) { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) }
            },
            copyPathAction(id: "copy-file-path", url: url),
            model.favoriteAction(for: entry)
        ]
        if model.launcherModules?.isModuleEnabled(.init(rawValue: "keylane.links")) == true {
            actions.append(.init(id: "save-file-quicklink", title: "存为快捷链接…", icon: "link.badge.plus") { [weak model] in
                guard let model, !model.fileSearch.isSearching,
                      model.fileSearch.lastPublishedQuery == model.query else { return }
                model.withFileResult(url) { file in
                    QuicklinksModule.create(from: file.url, title: file.name, model: model)
                }
            })
        }
        if model.pageID == .root {
            actions.insert(.init(id: "file-detail", title: "在文件搜索中查看详情", icon: "sidebar.right") { [weak model] in
                model?.showFileLocation(url, browse: false)
            }, at: 1)
        }
        if entry.isDirectory {
            actions.insert(.init(id: "browse-file-directory", title: "浏览文件夹", icon: "folder") { [weak model] in
                model?.showFileLocation(url, browse: true)
            }, at: 1)
        }
        actions.append(.init(id: "exclude-file-result", title: "从文件搜索中排除", icon: "eye.slash") { [weak model] in
            guard let model else { return }
            do {
                let path = try model.fileSearch.exclude(url)
                (NSApp.delegate as? Delegate)?.showLauncherFeedback("已排除所选路径", style: .success, actionTitle: "撤销") { [weak model] in
                    model?.fileSearch.undoExclusion(path)
                }
            } catch { model.fileActionFeedback(error.localizedDescription, style: .failure) }
        })
        if entry.isDirectory {
            actions.append(.init(id: "terminal-file-directory", title: "在终端中打开文件夹", icon: "terminal") { [weak model] in
                model?.withFileResult(url) { file in
                    guard file.isDirectory, let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                        model?.fileActionFeedback("无法在终端中打开此文件夹。", style: .failure)
                        return
                    }
                    NSWorkspace.shared.open([file.url], withApplicationAt: terminal, configuration: .init()) { _, error in
                        if let error {
                            DispatchQueue.main.async { model?.fileActionFeedback(error.localizedDescription, style: .failure) }
                        }
                    }
                }
            })
        }
        actions += [
            .init(id: "duplicate-file-result", title: "创建副本", icon: "plus.square.on.square") { [weak model] in
                model?.performFileMutation(url, trash: false)
            },
            .init(id: "trash-file-result", title: "移到废纸篓…", icon: "trash", destructive: true) { [weak model] in
                model?.performFileMutation(url, trash: true)
            }
        ]
        return actions
    }

    private static func openAction(_ title: String, entry: Entry, model: Model) -> LauncherAction {
        .init(id: "open", title: title, icon: "return", keys: ["↩"]) { [weak model] in
            model?.runCommand(entry.commandID, origin: .menu, usageKey: entry.id)
        }
    }

    private static func copyPathAction(id: String, url: URL) -> LauncherAction {
        .init(id: id, title: "复制路径", icon: "doc.on.doc") {
            UtilityActions.copy(url.path, feedback: "已复制路径")
        }
    }

    private static func clipboard(_ model: Model) -> LauncherModule {
        let id = PageID(rawValue: "Clipboard")
        let controller = model.clipboard
        let permission = PermissionFeature("clipboardPersistentCapture", authorization: .persistentClipboard, observeImmediately: false)
        var titlebar = permission.titlebar(SettingsItem.clipboardCapture.title)
        titlebar.searchItem = .clipboardCapture
        var permissionChanges: AnyCancellable?
        var linkVisualChanges: AnyCancellable?
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
                ClipboardActions.submit(controller)
            },
            shortcutSubmit: { [weak model] in
                if let controller = model?.clipboard { ClipboardActions.submit(controller, alternate: true) }
            },
            optionSubmit: {
                guard !SearchField.isComposing, let delegate = NSApp.delegate as? Delegate, delegate.pasteTargetName != nil else { return }
                delegate.pasteClipboard(keepOpen: true)
            },
            actionContextTitle: { [weak model] in
                guard let controller = model?.clipboard,
                      let item = controller.items.first(where: { $0.id == controller.selectedID }) else { return nil }
                return item.preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            },
            primaryTitle: {
                if controller.primaryAction == .paste, let target = (NSApp.delegate as? Delegate)?.pasteTargetName {
                    return "粘贴到 \(target)"
                }
                return "复制到剪贴板"
            },
            primaryEnabled: { [weak model] in model?.clipboard.selectedID != nil },
            actions: { [weak model] in
                guard let model else { return [] }
                return ClipboardActions.items(model)
            },
            updates: Publishers.MergeMany([
                ViewObservation.changes(model.clipboard.$selectedID),
                ViewObservation.changes(model.clipboard.$items),
                ViewObservation.changes(model.clipboard.$kind),
                ViewObservation.changes(model.clipboard.$primaryAction),
                model.clipboard.$detail.dropFirst().map { _ in () }.eraseToAnyPublisher()
            ]).eraseToAnyPublisher(),
            typeFilterWidth: 138,
            typeFilter: { [weak model] open in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(ResultTypeFilter(selection: Binding(get: { model.clipboard.kind }, set: { model.clipboard.kind = $0 }),
                                         options: ResultFilterOption.clipboard, open: open, navigation: model.navigation))
            },
            badgeActions: { [weak model] in
                guard let model else { return [] }
                return [
                    .init(id: "configure-clipboard-command", title: "配置命令…", icon: "gearshape",
                          keys: ["⇧", "⌘", ","]) { [weak model] in
                        model?.clipboard.showsHistorySettings = true
                        model?.openSettings(page: "clipboard")
                    },
                    .init(id: "configure-clipboard-extension", title: "配置扩展", icon: "gearshape",
                          keys: ["⌥", "⌘", ","]) { [weak model] in
                        model?.clipboard.showsHistorySettings = false
                        model?.openSettings(page: "clipboard")
                    }
                ]
            },
            maximumActionWidth: 280,
            releasePreview: { FilePreview.shared.dismiss() },
            actionShortcutsEnabled: true,
            loading: controller.$searching.combineLatest(controller.$loadingDetail, controller.$indexingImageText)
                .map { searching, detail, imageText in searching || detail || imageText }
                .removeDuplicates().eraseToAnyPublisher()
        )
        return .init(id: .init(rawValue: "keylane.clipboard"), commands: [
            command("clipboard", "剪贴板历史", "本地文字、图片和文件历史", "clipboard",
                    ["Clipboard History", "剪切板", "剪贴板", "复制历史"], destination: .page(id), settings: "clipboard",
                    available: { controller.historyCommandEnabled },
                    settingsEnabled: Binding(get: { controller.historyCommandEnabled }, set: { controller.historyCommandEnabled = $0 })),
            command(ClipboardSequenceCommand.paste.rawValue, ClipboardSequenceCommand.paste.title,
                    "粘贴下一条剪贴板记录", ClipboardSequenceCommand.paste.symbol,
                    ["Paste Sequentially", "顺序粘贴", "依次粘贴"], settings: "clipboard", execute: { _ in
                (NSApp.delegate as? Delegate)?.pasteClipboardSequentially()
            }),
            command(ClipboardSequenceCommand.reset.rawValue, ClipboardSequenceCommand.reset.title,
                    "从最新复制的记录重新开始", ClipboardSequenceCommand.reset.symbol,
                    ["Reset Paste Sequence", "重置粘贴顺序"], settings: "clipboard", execute: { _ in
                (NSApp.delegate as? Delegate)?.resetClipboardPasteSequence()
            })
        ], pages: [page], settings: [
            settingsPage(model, "clipboard", "剪贴板历史", "clipboard.fill", "查找本地保存的文字、图片和文件引用。", 40, titlebar: titlebar, content: LauncherSettingsContent.clipboard)
        ], services: [
            .init(start: {
                controller.startRuntime()
                linkVisualChanges = controller.$showsLinkVisuals.removeDuplicates().sink { enabled in
                    MainActor.assumeIsolated { ClipboardLinkPreviews.shared.setEnabled(enabled) }
                }
                permission.startObserving()
                controller.captureEnabled = permission.available
                controller.startMonitoring()
                permissionChanges = permission.updates.receive(on: DispatchQueue.main).sink {
                    controller.captureEnabled = permission.available
                }
            }, stop: {
                permissionChanges?.cancel()
                permissionChanges = nil
                permission.stopObserving()
                controller.stopRuntime()
                linkVisualChanges?.cancel()
                linkVisualChanges = nil
                MainActor.assumeIsolated { ClipboardLinkPreviews.shared.setEnabled(false) }
                FilePreview.shared.dismiss(owner: .clipboard)
                FileActionsWindow.shared.dismiss(owner: .clipboard)
            })
        ], searchUpdates: [updates(controller.$historyCommandEnabled)],
        shortcutSettingsUpdates: [ViewObservation.changes(controller.$historyCommandEnabled)])
    }

    private static func calculator(_ model: Model) -> LauncherModule {
        let exchange = CalculatorExchangeRates()
        func result(_ query: String) -> (value: String?, detail: String)? {
            if let conversion = CalculatorConversion(query) {
                if let value = conversion.unitResult { return (value, "单位换算") }
                if let value = exchange.result(conversion) { return value }
                return (nil, "单位不支持或无法互相换算")
            }
            return calculatorResult(query).map { ($0, "回车复制结果") }
        }
        let id = CommandID(rawValue: "calculator")
        let provider = LauncherModule.Provider(namespace: .exact(id), entries: { input in
            guard let result = result(input.query), let value = result.value else { return [] }
            return [Entry(id: id.rawValue, commandID: id, name: value, detail: result.detail,
                          symbol: "equal", rankingKind: .calculator)]
        }, resolve: { [weak model] command, origin in
            guard command == id, origin != .shortcut, let query = model?.query, let value = result(query)?.value else { return nil }
            return {
                UtilityActions.copy(value, feedback: "已复制计算结果")
            }
        }, actions: { [weak model] row in
            [LauncherAction(id: "calculator-copy", title: "复制结果", icon: "doc.on.doc", keys: ["↩"]) { [weak model] in
                model?.runCommand(row.commandID, origin: .menu, usageKey: row.id)
            }]
        })
        let hintID = CommandID(rawValue: "calculator-hint")
        let hint = LauncherModule.Provider(namespace: .exact(hintID), entries: { input in
            let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome = result(query)
            guard outcome?.value == nil,
                  outcome != nil || query.folding(options: .widthInsensitive, locale: .current).hasPrefix("=") else { return [] }
            let message = outcome?.detail ?? (query.count == 1 ? "例如 2 × (3 + 4)、5 km to mi、100 美元转人民币" : "表达式不完整或无法计算")
            return [Entry(id: hintID.rawValue, commandID: hintID, name: message,
                          detail: "计算器", symbol: "equal", rankingKind: .calculator)]
        }, resolve: { _, _ in nil })
        var module = LauncherModule(id: .init(rawValue: "keylane.calculator"), commands: [
            command("calculator-help", "计算器", "在搜索框输入表达式", "equal.circle", ["Calculator", "计算"], execute: { [weak model] _ in
                model?.query = "="
            })
        ], providers: [provider, hint], services: [.init(start: {}, stop: exchange.stop)], searchUpdates: [exchange.updates])
        module.launcherShown = exchange.startPresenting
        module.launcherHidden = exchange.endPresentation
        return module
    }

    private static func calculatorResult(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Calculator.isExpression(trimmed), let value = Calculator.evaluate(trimmed, locale: .current) else { return nil }
        return Calculator.format(value)
    }

    private static func systemTools(_ model: Model) -> LauncherModule {
        return .init(id: .init(rawValue: "keylane.system-tools"), title: "系统", symbol: "gearshape", commands: [
            command("color", "Pick Color / 取色", "Copy hex color", "eyedropper", [], execute: { _ in SystemTools.shared.colorPicker() }),
            command("speak", "Read Clipboard / 朗读", "System text to speech", "speaker.wave.2", [], settings: "permissions", permission: model.clipboardSpeech,
                    execute: { _ in SystemTools.shared.readClipboard() }),
            command("stop-speaking", "Stop Reading / 停止朗读", "Stop speech playback", "stop.circle", [], execute: { _ in SystemTools.shared.stopReading() }),
            command("finder", "Open Home / 个人文件夹", "Finder", "folder", [], execute: { _ in NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser) }),
            command("lock-screen", "锁定屏幕", "锁定当前 macOS 会话", "lock.fill",
                    ["Lock Screen", "锁屏"], settings: "permissions", permission: model.lockScreenPermission,
                    execute: { _ in SystemActions.lockScreen() }),
            command("sleep-mac", "让 Mac 睡眠", "让电脑进入睡眠", "moon.zzz",
                    ["Sleep Mac", "系统睡眠", "休眠"], execute: { _ in SystemActions.requestPowerAction(.sleep) }),
            command("sleep-displays", "让显示器睡眠", "关闭显示器画面", "display",
                    ["Sleep Displays", "显示器睡眠", "关闭屏幕"], execute: { _ in SystemActions.requestPowerAction(.sleepDisplays) }),
            command("toggle-output-mute", "切换静音", "切换默认音频输出设备的静音状态", "speaker.slash",
                    ["Toggle Mute", "Mute", "Unmute", "取消静音"], execute: { _ in SystemActions.toggleOutputMute() }),
            command("hide-other-applications", "隐藏其他应用", "保留前台应用", "eye.slash",
                    ["Hide Other Apps", "Hide All Apps Except Frontmost"], execute: { _ in SystemActions.hideOtherApplications() }),
            command("restart-frontmost-application", "重启前台应用", "正常退出并重新打开前台应用", "arrow.clockwise",
                    ["Restart Frontmost App"], execute: { [weak model] _ in
                        guard let model else { return }
                        model.applicationResultActions.restartFrontmost(model: model)
                    }),
            command("quit-all-applications", "退出所有应用", "向打开的应用发出正常退出请求", "rectangle.portrait.and.arrow.right",
                    ["Quit All Apps"], execute: { _ in SystemActions.quitApplications(keepingFrontmost: false) }),
            command("quit-other-applications", "退出其他应用", "保留前台应用并退出其余应用", "rectangle.portrait.and.arrow.right",
                    ["Quit All Apps Except Frontmost", "Quit Other Apps"], execute: { _ in SystemActions.quitApplications(keepingFrontmost: true) }),
            command("unhide-applications", "显示所有隐藏应用", "恢复已隐藏的应用窗口", "eye",
                    ["Unhide All Hidden Apps", "Show Hidden Apps"], execute: { _ in SystemActions.unhideApplications() })
        ], services: [.init(start: { [weak model] in
            model?.lockScreenPermission.startObserving()
            model?.clipboardSpeech.startObserving()
        }, stop: { [weak model] in
            model?.lockScreenPermission.stopObserving()
            model?.clipboardSpeech.stopObserving()
            SystemTools.shared.stopSystemTools()
        })], searchUpdates: [model.lockScreenPermission.updates, model.clipboardSpeech.updates])
    }

    private static func updates<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never>
        where P.Output: Equatable, P.Failure == Never {
        publisher.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
    }

    private static func settingsPage<Content: View>(_ model: Model, _ id: String, _ title: String, _ symbol: String,
                                     _ subtitle: String, _ order: Int, titlebar: SettingsTitlebarContribution? = nil,
                                     trailingToolbar: (() -> AnyView)? = nil, loading: AnyPublisher<Bool, Never>? = nil,
                                     content: @escaping (Model) -> Content) -> LauncherSettingsPage {
        .init(id: id, title: title, symbol: symbol, subtitle: subtitle, order: order, items: SettingsItem.all.filter { $0.page == id }, titlebar: titlebar, trailingToolbar: trailingToolbar, loading: loading) { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(content(model))
        }
    }
}
