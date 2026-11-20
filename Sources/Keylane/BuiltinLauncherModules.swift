import AppKit
import Combine
import SwiftUI
import KeylaneCore

/// Composition point for the features present on dev. Construction stores
/// closures only; controllers are consulted when the host uses a contribution.
enum BuiltinLauncherModules {
    static func make(model: Model) -> [LauncherModule] {
        let modules = [applications(model), host(model), AIModule.make(model: model), TranslatorModule.make(model: model), files(model), clipboard(model), AppleNotesModule.make(model: model),
                       QuicklinksModule.make(model: model), CalculatorLauncherModule.make(model: model), SystemActionsModule.make(model: model), CalendarLauncherModule.make(model: model),
                       ScriptCommandsModule.make(model: model), AppUtilitiesModule.make(model: model), SnippetsModule.make(model: model), WindowManagementModule.make(model: model), DropShelfModule.make(model: model)]
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
                                acceptsFallbackQuery: Bool = false,
                                execute: @escaping (LauncherCommandOrigin) -> Void = { _ in }) -> LauncherModule.Command {
        LauncherModule.Command(
            declaration: .init(id: .init(rawValue: id), title: title, detail: detail, symbol: symbol,
                               keywords: keywords, destination: destination, settingsPage: settings),
            detail: dynamicDetail, settingsEnabled: settingsEnabled, available: available, permission: permission,
            acceptsFallbackQuery: acceptsFallbackQuery, execute: execute
        )
    }

    private static func host(_ model: Model) -> LauncherModule {
        let category = ShortcutSettingsControls()
        let keyboard = ShortcutKeyboardSelection()
        let canBind = {
            guard let shortcut = keyboard.shortcut else { return false }
            return !keyboard.choosing && keyboard.previewModifiers == nil
                && ShortcutValidation.conflict(in: ["shortcut": shortcut]) == nil
        }
        let bindShortcut = {
            guard canBind() else { return }
            keyboard.feedback = nil
            keyboard.choosing = true
        }
        var openedFromHotkeys = false
        let leaveKeyboard: () -> Void = { [weak model] in
            model?.pageID = .root
            if openedFromHotkeys { model?.openSettings(page: "hotkeys") }
        }
        return .init(id: .init(rawValue: "keylane.host"), origin: .application, title: "Keylane", symbol: "command",
              commands: [command("settings", "Keylane 设置", "偏好设置与隐私", "gearshape",
                                 ["Settings", "Preferences", "设置", "偏好设置"], destination: .settings(nil), settings: "general"),
                         command("show-shortcut-keyboard", "显示键盘快捷键", "查看和编辑键盘上的快捷键", "keyboard",
                                 ["Show Keyboard Shortcuts", "快捷键键盘", "热键"],
                                 destination: .page(ShortcutKeyboardPage.pageID), settings: "hotkeys",
                                 execute: { _ in openedFromHotkeys = false }),
                         command("show-onboarding", "Show Onboarding", "重新打开 Keylane 的首次引导",
                                 "sparkles.rectangle.stack", ["onboarding", "welcome", "首次引导", "新手引导"]) { _ in
                             (NSApp.delegate as? Delegate)?.showOnboarding()
                         }],
              pages: [.init(id: ShortcutKeyboardPage.pageID, placeholder: "按下快捷键…", badge: ("快捷键键盘", "keyboard"),
                            contentPlacement: .underChrome, content: { [weak model] in
                                guard let model else { return AnyView(EmptyView()) }
                                return AnyView(ShortcutKeyboardPage(model: model, selection: keyboard))
                            }, back: leaveKeyboard, submit: bindShortcut,
                            primaryTitle: { "绑定命令" }, primaryEnabled: canBind,
                            actions: {
                                [.init(id: "bind-shortcut", title: "绑定命令", icon: "keyboard", shortcut: .init(.return, modifiers: []),
                                       enabled: canBind(), perform: bindShortcut)]
                            },
                            updates: keyboard.objectWillChange.eraseToAnyPublisher(),
                            headerInput: .custom({
                                let keys = keyboard.displayedKeys
                                return AnyView(Text(keys.isEmpty ? "按下快捷键…" : keys.joined(separator: " "))
                                    .font(.system(size: 19))
                                    .foregroundStyle(keys.isEmpty ? .secondary : .primary))
                            }),
                            typeFilterWidth: 220,
                            typeFilter: { [weak model] open in
                                guard let model else { return AnyView(EmptyView()) }
                                return AnyView(ShortcutKeyboardPage(model: model, selection: keyboard, menuOpen: open))
                            })],
              settings: [settingsPage(model, "general", "通用", "slider.horizontal.3", "管理外观、快捷键和启动方式。", 0, content: LauncherSettingsContent.general),
                         settingsPage(model, "launcher", "启动器", "magnifyingglass", "管理启动器的显示与搜索行为。", 5) {
                             LauncherBehaviorPreferences(model: $0)
                         },
                         settingsPage(model, "keyboard", "键盘", "keyboard", "管理按键行为、导航和 Hyper Key。", 6) {
                             KeyboardPreferences(model: $0)
                         },
                         settingsPage(model, "hotkeys", "快捷键", "command", "按扩展管理命令别名与快捷键。", 7, trailingToolbar: { [weak model] in
                             AnyView(ShortcutSettingsToolbar(groups: model?.launcherModules?.shortcutCommandGroups ?? [],
                                                                    navigation: model?.navigation ?? "arrows", selection: category) { [weak model] in
                                 openedFromHotkeys = true
                                 model?.openPage(ShortcutKeyboardPage.pageID, origin: .menu)
                             })
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
            guard id.rawValue.hasPrefix("app:"), let model else { return nil }
            let path = String(id.rawValue.dropFirst("app:".count))
            guard model.isApplicationCommandAvailable(at: path) else { return nil }
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
                                 ["Manage Auto Quit", "闲置退出"], destination: .settings(SettingsItem.applicationAutoQuit.page),
                                 settings: "applications", available: { [weak model] in model?.applicationsEnabled ?? false }),
                         command("uninstall-application", "卸载应用程序", "卸载应用并选择要清理的关联文件", "trash",
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
                        id: ApplicationUninstallReview.pageID, placeholder: "筛选文件和文件夹…", badge: ("卸载应用程序", "trash"),
                        contentPlacement: .underChrome,
                        content: { AnyView(ApplicationUninstallReviewPage(review: applicationActions.uninstallReview)) },
                        queryChanged: applicationActions.uninstallReview.filter,
                        leave: applicationActions.uninstallReview.clear,
                        keepsStateWhenHidden: true,
                        parent: uninstallPage,
                        move: applicationActions.uninstallReview.move,
                        submit: applicationActions.uninstallReview.submit,
                        actionSelectionID: { applicationActions.uninstallReview.highlighted },
                        actionContextTitle: { applicationActions.uninstallReview.name },
                        primaryTitle: { applicationActions.uninstallReview.isSubmitting ? "正在移到废纸篓…" : "移到废纸篓" },
                        primaryEnabled: { applicationActions.uninstallReview.canSubmit },
                        actions: {
                            [LauncherAction(id: "toggle-uninstall-file", title: "勾选或取消所选文件", icon: "checkmark.square",
                                            enabled: !applicationActions.uninstallReview.isSubmitting) {
                                applicationActions.uninstallReview.toggleHighlighted()
                            }]
                        },
                        updates: applicationActions.uninstallReview.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                        resume: { [weak model] in
                            applicationActions.uninstallReview.resume {
                                model?.pageID = uninstallPage
                            }
                        },
                        typeFilterWidth: 152,
                        typeFilter: { [weak model] open in
                            AnyView(ApplicationUninstallSortPicker(review: applicationActions.uninstallReview,
                                                                   open: open, navigation: model?.navigation ?? "arrows"))
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
                     ), content: LauncherSettingsContent.applications), .init(
                         id: SettingsItem.applicationAutoQuit.page, title: SettingsItem.applicationAutoQuit.title,
                         symbol: "app.badge.clock", subtitle: ApplicationAutoQuitPreferences.summary, order: 11,
                         items: [.applicationAutoQuit], parentID: "applications",
                         toolbarMenu: .init(title: "添加自动退出应用", symbol: "plus") { [weak model] dismiss in
                             guard let model else { return AnyView(EmptyView()) }
                             return AnyView(ApplicationAutoQuitAddMenu(model: model, dismiss: dismiss))
                         }, centeredHeader: true,
                         content: { [weak model] in
                             guard let model else { return AnyView(EmptyView()) }
                             return AnyView(ApplicationAutoQuitPreferences(model: model))
                         }
                     )],
                     services: [.init(start: { [weak model] in
                         model?.acquireApplicationCatalog(for: .applications)
                         model?.applicationAutoQuit.start { [weak model] in model?.applicationsEnabled ?? false }
                     }, stop: { [weak model] in
                         model?.applicationResultActions.stopUninstallSelection()
                         model?.applicationAutoQuit.stop()
                         model?.releaseApplicationCatalog(for: .applications)
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
                    permission: permission, acceptsFallbackQuery: true),
            command("ask-files", "询问文件搜索", "AI", "sparkles", ["Ask File Search"], settings: "files",
                    available: { [weak model] in model.map { $0.fileSearch.options.enabled && $0.aiSettings.isAvailable && $0.fileAI.commandsEnabled["ask-files"] != false } ?? false },
                    settingsEnabled: model.fileAI.commandEnabledBinding("ask-files"), execute: { [weak model] origin in
                guard let model else { return }
                if origin == .shortcut { (NSApp.delegate as? Delegate)?.hideLauncher() }
                model.fileAI.present(model.fileResults.map(\.url))
            }),
            command("ask-finder", "询问 Finder", "AI", "sparkles", ["Ask Finder"], settings: "files",
                    available: { [weak model] in model.map { $0.fileSearch.options.enabled && $0.aiSettings.isAvailable && $0.finderAutomation.available && $0.fileAI.commandsEnabled["ask-finder"] != false } ?? false },
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
                           updates(model.fileAI.$commandsEnabled),
                           model.finderAutomation.updates],
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
            .init(id: "ask-file", title: "询问此文件…", icon: "sparkles", enabled: model.aiSettings.isAvailable) { [weak model] in
                guard let model, model.aiSettings.isAvailable else { return }
                model.withFileResult(url) { model.fileAI.present([$0.url]) }
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
        .init(id: "open", title: title, icon: "return", shortcut: .init(.return, modifiers: [])) { [weak model] in
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
            returnBindings: .init(alternates: [
                .command: .init(dismissMenu: true) { [weak model] in
                    if let controller = model?.clipboard { ClipboardActions.submit(controller, alternate: true) }
                },
                .option: .init(dismissMenu: true) {
                    guard let delegate = NSApp.delegate as? Delegate, delegate.pasteTargetName != nil else { return }
                    delegate.pasteClipboard(keepOpen: true)
                }
            ]),
            actionSelectionID: { [weak model] in model?.clipboard.selectedID },
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
                ViewObservation.changes(model.clipboard.$total.map { $0 > 0 }),
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
                          shortcut: .init(",", modifiers: [.shift, .command])) { [weak model] in
                        model?.clipboard.showsHistorySettings = true
                        model?.openSettings(page: "clipboard")
                    },
                    .init(id: "configure-clipboard-extension", title: "配置扩展", icon: "gearshape",
                          shortcut: .init(",", modifiers: [.option, .command])) { [weak model] in
                        model?.clipboard.showsHistorySettings = false
                        model?.openSettings(page: "clipboard")
                    }
                ]
            },
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
                    settingsEnabled: Binding(get: { controller.historyCommandEnabled }, set: { controller.historyCommandEnabled = $0 }),
                    acceptsFallbackQuery: true),
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
