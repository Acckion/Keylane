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
        let observeFocus: (NSRunningApplication) -> Void = { SystemNavigation.shared.observeFocus(of: $0) }
        var focusObserver: NSObjectProtocol?
        let focusService = LauncherModule.Service(start: {
            focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    observeFocus(app)
                }
            }
        }, stop: {
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
                destination: .page(windows)
            )),
            .init(declaration: .init(
                id: .init(rawValue: "search-menu-items"), title: NavigationMode.menus.title,
                detail: NavigationText.label("搜索并执行前一个应用的菜单命令", "Find and run a menu command in the previous app"),
                symbol: NavigationMode.menus.symbol, keywords: ["Search Menu Items", "菜单", "菜单栏", "Navigation"],
                destination: .page(menus)
            ))
        ], pages: [
            navigationPage(windows, mode: .windows, model: model),
            navigationPage(menus, mode: .menus, model: model)
        ], services: [focusService], applicationFocused: observeFocus)
    }

    private static func navigationPage(_ id: PageID, mode: NavigationMode, model: Model) -> LauncherPage {
        let controller = model.systemNavigation
        let reload: () -> Void = { [weak model] in
            guard let model else { return }
            controller.query = model.query
            controller.load(mode, target: (NSApp.delegate as? Delegate)?.previousApplication)
        }
        let activate: (NavigationItem) -> Void = { item in
            guard let delegate = NSApp.delegate as? Delegate else { return }
            controller.perform(item, mode: mode) { [weak delegate] message in
                if let message { delegate?.toast.show(message) }
                else if item.application.isActive { delegate?.hideLauncher() }
            }
        }
        let placeholder = mode == .windows ? NavigationText.label("搜索窗口…", "Search Windows…")
                                          : NavigationText.label("搜索菜单项…", "Search Menu Items…")
        var page = LauncherPage(id: id, placeholder: placeholder, badge: (mode.title, mode.symbol))
        page.contentPlacement = .underChrome
        page.actionWidth = 258
        page.content = { [weak model] in
            AnyView(NavigationPage(controller: controller, mode: mode, requestAccess: { [weak model] in
                model?.requestKeyboardAccess()
            }, reload: reload, activate: activate))
        }
        page.enter = { query in
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
        return LauncherModule(id: .init(rawValue: "keylane.system-settings"), providers: [provider])
    }

    private static func screenshots(_ model: Model) -> LauncherModule {
        let id = PageID(rawValue: "Screenshots")
        let library = model.screenshots
        let commands = ScreenshotCommand.allCases.map { command in
            LauncherModule.Command(
                declaration: .init(id: .init(rawValue: command.rawValue), title: command.title,
                                   detail: "截图管理", symbol: command.symbol, keywords: command.aliases,
                                   destination: command == .search ? .page(id) : .action, settingsPage: "screenshots"),
                settingsEnabled: library.commandEnabledBinding(command),
                available: { library.isEnabled(command) },
                execute: { [weak model] _ in
                    if command == .latest, let model { pasteLatestScreenshot(model) }
                }
            )
        }
        let settings = LauncherSettingsPage(
            id: "screenshots", title: "截图", symbol: "viewfinder", subtitle: "搜索和管理截图与录屏。",
            order: 30, items: SettingsItem.all.filter { $0.page == "screenshots" },
            titlebar: .init(
                title: "启用截图管理",
                enabled: Binding(get: { library.enabled }, set: { library.enabled = $0 }),
                updates: library.$enabled.removeDuplicates().eraseToAnyPublisher()
            )
        ) { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(ScreenshotPreferences(library: library, model: model))
        }
        return LauncherModule(id: .init(rawValue: "keylane.screenshots"), commands: commands,
                              pages: [screenshotsPage(id, model: model)], settings: [settings], searchUpdates: [
            library.$enabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            library.$disabledCommands.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ])
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
        page.actionWidth = 258
        page.releasePreview = { FilePreview.shared.dismiss() }
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
            copyScreenshot(item, model: model)
        }
        page.primaryTitle = { "复制到剪贴板" }
        page.actions = { [weak model] in
            guard let model else { return [] }
            return screenshotActions(model, chooseFolders: chooseFolders)
        }
        let selectedMedia = library.$results.combineLatest(library.$selection)
            .map { results, selection in results.first { $0.id == selection?.itemID } }
        page.updates = Publishers.Merge(
            ViewObservation.changes(library.$filter),
            ViewObservation.changes(selectedMedia)
        ).eraseToAnyPublisher()
        return page
    }

    private static func screenshotActions(_ model: Model, chooseFolders: @escaping () -> Void) -> [LauncherAction] {
        let controls = [
            LauncherAction(id: "screenshot-refresh", title: "刷新截图", icon: "arrow.clockwise", perform: model.screenshots.refresh),
            LauncherAction(id: "screenshot-folders", title: "添加搜索文件夹…", icon: "folder.badge.plus", perform: chooseFolders),
            LauncherAction(id: "screenshot-settings", title: "截图设置…", icon: "gearshape",
                           perform: { model.openSettings(page: "screenshots") })
        ]
        guard let item = model.screenshots.selected else { return controls }
        return [
            LauncherAction(id: "screenshot-copy", title: "复制到剪贴板", icon: "doc.on.doc", keys: ["↩"],
                           perform: { copyScreenshot(item, model: model) }),
            LauncherAction(id: "screenshot-preview", title: "快速查看", icon: "eye", perform: {
                withScreenshot(item, model: model) { FilePreview.shared.show(item.url) }
            }),
            LauncherAction(id: "screenshot-open", title: "打开原文件", icon: "arrow.up.forward.app", perform: {
                withScreenshot(item, model: model) {
                    guard NSWorkspace.shared.open(item.url) else { throw CocoaError(.fileReadUnknown) }
                    (NSApp.delegate as? Delegate)?.hideLauncher()
                }
            }),
            LauncherAction(id: "screenshot-share", title: "分享…", icon: "square.and.arrow.up", perform: {
                withScreenshot(item, model: model) { FileActionsWindow.shared.show(item.url, page: "share") }
            }),
            LauncherAction(id: "screenshot-reveal", title: "在 Finder 中显示", icon: "folder", perform: {
                withScreenshot(item, model: model) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }),
            LauncherAction(id: "screenshot-trash", title: "移到废纸篓…", icon: "trash", perform: {
                trashScreenshot(item, model: model)
            })
        ] + controls
    }

    private static func withScreenshot(_ item: ScreenshotMedia, model: Model, perform: () throws -> Void) {
        do {
            try model.screenshots.validate(item)
            try perform()
        } catch {
            model.error = "截图操作失败：" + error.localizedDescription
            model.screenshots.refresh()
        }
    }

    private static func copyScreenshot(_ item: ScreenshotMedia, model: Model) {
        withScreenshot(item, model: model) {
            try model.screenshots.copy(item)
            (NSApp.delegate as? Delegate)?.hideLauncher()
        }
    }

    private static func trashScreenshot(_ item: ScreenshotMedia, model: Model) {
        let alert = NSAlert()
        alert.messageText = "将这张截图移到废纸篓？"
        alert.informativeText = item.name
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移到废纸篓").hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn {
            withScreenshot(item, model: model) { try model.screenshots.moveToTrash(item) }
        }
        model.runCommand(.init(rawValue: ScreenshotCommand.search.rawValue), origin: .menu)
    }
}
