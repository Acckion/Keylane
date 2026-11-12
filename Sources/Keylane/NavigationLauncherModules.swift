import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum NavigationLauncherModules {
    static func make(model: Model) -> [LauncherModule] {
        [navigation(model), systemSettings(model), screenshots(model)]
    }

    private static func navigation(_ model: Model) -> LauncherModule {
        let windows = PageID(rawValue: "Windows")
        let menus = PageID(rawValue: "MenuItems")
        let permission = PermissionFeature("windowNavigation.enabled", authorization: .accessibility, observeImmediately: false)
        let observeFocus: (NSRunningApplication) -> Void = {
            if permission.available { SystemNavigation.shared.observeFocus(of: $0) }
        }
        var focusObserver: NSObjectProtocol?
        var permissionChanges: AnyCancellable?
        let focusService = LauncherModule.Service(start: { [weak model] in
            permission.startObserving()
            if let app = NSWorkspace.shared.frontmostApplication { observeFocus(app) }
            permissionChanges = permission.updates.receive(on: DispatchQueue.main).sink { [weak model] in
                if !permission.available {
                    SystemNavigation.shared.stopObservingFocus()
                    model?.systemNavigation.permissionRequired()
                }
            }
            focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    observeFocus(app)
                }
            }
        }, stop: { [weak model] in
            permissionChanges?.cancel()
            permission.stopObserving()
            model?.systemNavigation.stopModule()
            permissionChanges = nil
            if let observer = focusObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                focusObserver = nil
            }
            SystemNavigation.shared.stopObservingFocus()
        })
        return LauncherModule(id: .init(rawValue: "keylane.navigation"), title: "窗口与菜单", symbol: "macwindow", commands: [
            .init(declaration: .init(
                id: .init(rawValue: "switch-windows"), title: NavigationMode.windows.title,
                detail: NavigationText.label("查找并切换已打开的窗口", "Find and switch open windows"),
                symbol: NavigationMode.windows.symbol, keywords: ["Switch Windows", "窗口切换", "窗口", "Navigation"],
                destination: .page(windows), settingsPage: "keylane.navigation"
            ), permission: permission),
            .init(declaration: .init(
                id: .init(rawValue: "search-menu-items"), title: NavigationMode.menus.title,
                detail: NavigationText.label("搜索并执行前一个应用的菜单命令", "Find and run a menu command in the previous app"),
                symbol: NavigationMode.menus.symbol, keywords: ["Search Menu Items", "菜单", "菜单栏", "Navigation"],
                destination: .page(menus), settingsPage: "keylane.navigation"
            ), permission: permission)
        ], pages: [
            navigationPage(windows, mode: .windows, model: model, permission: permission),
            navigationPage(menus, mode: .menus, model: model, permission: permission)
        ], services: [focusService], searchUpdates: [permission.updates], applicationFocused: observeFocus,
           permissionTitlebar: permission.titlebar("启用窗口与菜单"))
    }

    private static func navigationPage(_ id: PageID, mode: NavigationMode, model: Model, permission: PermissionFeature) -> LauncherPage {
        let controller = model.systemNavigation
        let reload: () -> Void = { [weak model] in
            guard permission.available, let model else { return }
            controller.query = model.query
            controller.load(mode, target: (NSApp.delegate as? Delegate)?.previousApplication)
        }
        let activate: (NavigationItem) -> Void = { item in
            guard permission.available, let delegate = NSApp.delegate as? Delegate else { return }
            controller.perform(item, mode: mode) { [weak delegate] message in
                if let message { delegate?.toast.show(message) }
                else if item.application.isActive { delegate?.hideLauncher() }
            }
        }
        let placeholder = mode == .windows ? NavigationText.label("搜索窗口…", "Search Windows…")
                                          : NavigationText.label("搜索菜单项…", "Search Menu Items…")
        var page = LauncherPage(id: id, placeholder: placeholder, badge: (mode.title, mode.symbol))
        page.contentPlacement = .underChrome
        page.loading = controller.$status.map { $0 == .loading }.removeDuplicates().eraseToAnyPublisher()
        page.maximumActionWidth = 258
        page.content = { [weak model] in
            AnyView(NavigationPage(controller: controller, mode: mode, requestAccess: { [weak model] in
                model?.openSettings(page: "keylane.navigation")
            }, reload: reload, activate: activate))
        }
        page.enter = { query in
            guard permission.available else { return nil }
            controller.query = query
            controller.load(mode, target: (NSApp.delegate as? Delegate)?.previousApplication)
            return nil
        }
        page.resume = reload
        page.queryChanged = { controller.query = $0 }
        page.leave = controller.stop
        page.move = controller.move
        page.submit = {
            if let item = controller.selected { activate(item) }
        }
        page.primaryTitle = { mode.action }
        page.actions = {
            let refresh = LauncherAction(id: "refresh-navigation", title: NavigationText.label("刷新结果", "Refresh Results"),
                                         icon: "arrow.clockwise", perform: reload)
            guard let item = controller.selected else { return [refresh] }
            return [LauncherAction(id: "run-navigation", title: mode.action, icon: mode.symbol, keys: ["↩"],
                                   perform: { activate(item) }), refresh]
        }
        page.updates = Publishers.Merge(
            ViewObservation.changes(controller.$selection),
            controller.$results.dropFirst().map { _ in () }
        ).eraseToAnyPublisher()
        return page
    }

    private static func systemSettings(_ model: Model) -> LauncherModule {
        let provider = LauncherModule.Provider(namespace: .prefix("system-setting:"), entries: { input in
            let hasQuery = !SystemSettingsCatalog.pageQuery(input.query).isEmpty
            return SystemSettingsCatalog.pages.compactMap { page in
                guard hasQuery || input.favorites.contains(page.id) else { return nil }
                return Entry(id: page.id, commandID: .init(rawValue: page.id), name: page.title(),
                             detail: SystemSettingsCatalog.resultKind, symbol: page.symbol, aliases: page.searchNames,
                             rankingKind: .systemSetting)
            }
        }, resolve: { [weak model] id, _ in
            guard let page = SystemSettingsCatalog.pages.first(where: { $0.id == id.rawValue }) else { return nil }
            return { [weak model] in
                if NSWorkspace.shared.open(page.url) {
                    (NSApp.delegate as? Delegate)?.hideLauncher()
                } else {
                    model?.error = SystemSettingsCatalog.prefersChinese()
                        ? "无法打开「\(page.title())」。请在系统设置中查找该页面。"
                        : "Could not open \(page.title()). Look for it in System Settings."
                }
            }
        })
        return LauncherModule(id: .init(rawValue: "keylane.system-settings"), title: "系统设置", symbol: "gear", providers: [provider])
    }

    private static func screenshots(_ model: Model) -> LauncherModule {
        let id = PageID(rawValue: "Screenshots")
        let library = model.screenshots
        let permission = PermissionFeature("screenshots.scopeOptIn", authorization: .init(
            check: { library.hasAuthorizedScope },
            request: { complete in
                library.chooseFolders()
                complete(library.hasAuthorizedScope)
            },
            guidance: "请通过启用开关选择可访问的截图文件夹。"
        ), observeImmediately: false)
        var permissionChanges: AnyCancellable?
        let commands = ScreenshotCommand.allCases.map { command in
            LauncherModule.Command(
                declaration: .init(id: .init(rawValue: command.rawValue), title: command.title,
                                   detail: "截图管理", symbol: command.symbol, keywords: command.aliases,
                                   destination: command == .search ? .page(id) : .action, settingsPage: "screenshots"),
                settingsEnabled: library.commandEnabledBinding(command),
                available: { !library.disabledCommands.contains(command.rawValue) }, permission: permission,
                execute: { [weak model] _ in
                    if command == .latest, let model { pasteLatestScreenshot(model) }
                }
            )
        }
        let settings = LauncherSettingsPage(
            id: "screenshots", title: "截图", symbol: "viewfinder", subtitle: "搜索和管理截图与录屏。",
            order: 30, items: SettingsItem.all.filter { $0.page == "screenshots" },
            titlebar: permission.titlebar("启用截图管理")
        ) { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(ScreenshotPreferences(library: library, model: model))
        }
        return LauncherModule(id: .init(rawValue: "keylane.screenshots"), commands: commands,
                              pages: [screenshotsPage(id, model: model)], settings: [settings], services: [.init(start: {
            permission.startObserving()
            library.enabled = permission.available
            permissionChanges = Publishers.Merge(permission.updates, ViewObservation.changes(library.$scopes))
                .receive(on: DispatchQueue.main).sink {
                    permission.recheck()
                    let enabled = permission.available
                    if library.enabled != enabled { library.enabled = enabled }
                }
        }, stop: {
            permissionChanges?.cancel()
            permissionChanges = nil
            permission.stopObserving()
            library.enabled = false
            ScreenshotThumbnail.releaseCache()
            FilePreview.shared.dismiss(owner: .screenshots)
            FileActionsWindow.shared.dismiss(owner: .screenshots)
        })], searchUpdates: [
            library.$enabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            library.$disabledCommands.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ], shortcutSettingsUpdates: [ViewObservation.changes(library.$disabledCommands)])
    }

    private static func pasteLatestScreenshot(_ model: Model) {
        guard let delegate = NSApp.delegate as? Delegate else { return }
        delegate.rememberPreviousApplication()
        let target = delegate.previousApplication?.processIdentifier
        model.screenshots.latest { [weak model, weak delegate] item in
            guard let model, let delegate else { return }
            guard let item else { model.error = "没有找到可粘贴的截图。"; return }
            do {
                try model.screenshots.copy(item)
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard delegate.previousApplication?.processIdentifier == target,
                      front == target || front == ProcessInfo.processInfo.processIdentifier else {
                    model.error = "已复制截图。目标应用已变化，已取消粘贴。"
                    return
                }
                delegate.pasteIntoPreviousApplication()
            } catch {
                model.error = "无法复制截图：" + error.localizedDescription
            }
        }
    }

    private static func screenshotsPage(_ id: PageID, model: Model) -> LauncherPage {
        let library = model.screenshots
        let chooseFolders: () -> Void = { [weak model] in
            library.chooseFolders()
            model?.runCommand(.init(rawValue: ScreenshotCommand.search.rawValue), origin: .menu)
        }
        var page = LauncherPage(id: id, placeholder: "按 name:、text: 或 date: 搜索截图…", badge: ("截图管理", "viewfinder"))
        page.contentPlacement = .underChrome
        page.maximumActionWidth = 258
        page.releasePreview = { FilePreview.shared.dismiss() }
        page.loading = library.$scanning.combineLatest(library.$searchingText)
            .map { scanning, searchingText in scanning || searchingText }.removeDuplicates().eraseToAnyPublisher()
        page.content = { [weak model] in
            AnyView(ScreenshotLibraryPage(library: library, query: model?.query ?? "", chooseFolders: chooseFolders))
        }
        page.typeFilterWidth = 138
        page.typeFilter = { [weak model] open in
            AnyView(ResultTypeFilter(
                selection: Binding(get: { library.filter.rawValue }, set: {
                    if let filter = ScreenshotFilter(rawValue: $0) { library.filter = filter }
                }),
                options: ScreenshotFilter.allCases.map { .init(id: $0.id, title: $0.title, symbol: $0.symbol) },
                open: open, navigation: model?.navigation ?? "arrows"
            ))
        }
        page.enter = { query in
            library.search(query)
            library.refresh()
            return nil
        }
        page.resume = library.refresh
        page.queryChanged = library.search
        page.leave = library.stop
        page.move = { library.move($0, vertical: true) }
        page.moveHorizontal = { library.move($0, vertical: false) }
        page.navigateWhileTyping = true
        page.submit = { [weak model] in
            guard let model, let item = library.selected else { return }
            ScreenshotActions.copy(item, model: model)
        }
        page.primaryTitle = { "复制到剪贴板" }
        page.primaryEnabled = { library.selected != nil }
        page.actionContextTitle = { library.selected?.name ?? "截图操作" }
        page.actionShortcutsEnabled = true
        page.actions = { [weak model] in
            guard let model else { return [] }
            return ScreenshotActions.items(model)
        }
        page.badgeActions = { [weak model] in
            guard let model else { return [] }
            return ScreenshotActions.controls(model, chooseFolders: chooseFolders)
        }
        let selectedMedia = library.$results.combineLatest(library.$selection)
            .map { results, selection in results.first { $0.id == selection?.itemID } }
        page.updates = Publishers.MergeMany([
            ViewObservation.changes(library.$filter),
            ViewObservation.changes(library.$columns),
            ViewObservation.changes(library.$pinnedIDs),
            ViewObservation.changes(selectedMedia)
        ]).eraseToAnyPublisher()
        return page
    }
}
