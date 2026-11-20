#if DEBUG
import AppKit
import KeylaneCore
import SwiftUI

/// Isolated synthetic verification. Never constructs Model or touches the user's theme library.
enum ThemeUIFixture {
    static func run() throws {
        let domain = "org.keylane.theme-fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ThemeStore(defaults: defaults)
        let studio = ThemeStudio(store: store)
        let directory = URL(fileURLWithPath: "/private/tmp/keylane-theme-studio-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initial = store.library
        studio.select(ThemeDefinition.builtins[2].id); studio.duplicate()
        var theme = studio.selected
        theme.name = "我的雾港"
        theme.colors["text"] = "#E4F5FA"; theme.colors["selection"] = "#368B9E"
        studio.edit(theme)
        guard store.library == initial else { throw ThemeError.invalid("编辑草稿影响了活动主题。") }
        studio.select(ThemeDefinition.lightID); studio.select(theme.id)
        guard studio.selected == theme else { throw ThemeError.invalid("切换条目丢失了草稿。") }
        studio.undo.undo()
        guard studio.selected.colors["text"] != theme.colors["text"] else { throw ThemeError.invalid("主题编辑未能撤销。") }
        studio.edit(theme); studio.save()
        guard studio.error == nil, !studio.dirty, store.library.darkID == initial.darkID else { throw ThemeError.invalid("保存错误地应用了主题。") }
        studio.assign()
        guard store.library.darkID == theme.id, store.library.lightID == initial.lightID else { throw ThemeError.invalid("深浅色主题指定失败。") }
        let reloaded = ThemeStore(defaults: defaults)
        guard reloaded.library == store.library else { throw ThemeError.invalid("主题未能重新载入。") }
        studio.duplicate(); var invalid = studio.selected; invalid.colors["text"] = "#not-a-color"; studio.edit(invalid); studio.save()
        guard studio.error != nil, studio.dirty, store.library == reloaded.library else { throw ThemeError.invalid("无效颜色被保存。") }
        studio.reset(); studio.select(theme.id)
        try render(ThemeStudioView(studio: studio), name: "studio-dark", scheme: .dark, size: .init(width: 1260, height: 780), directory: directory)
        studio.select(ThemeDefinition.builtins[5].id); studio.duplicate()
        try render(ThemeStudioView(studio: studio), name: "studio-light", scheme: .light, size: .init(width: 1260, height: 780), directory: directory)
        try render(ThemeAppearancePreferences(store: store, openStudio: {}), name: "appearance", scheme: .dark, size: .init(width: 760, height: 330), directory: directory)
        try render(ThemePreview(theme: theme), name: "preview", scheme: .dark, size: .init(width: 700, height: 620), directory: directory)
        try render(VStack(spacing: 6) {
            Text("实际主题样式").font(.title2)
            ResultListRow(selected: true) { Image(systemName: "paintpalette").foregroundStyle(ThemeColorStyle(role: .purple)) } content: { Text("选中项与文字") }
            LauncherMenuRow(title: "菜单操作", symbol: "doc.on.doc", selected: true, activate: {}, highlight: {}) { EmptyView() }
            LauncherMenuRow(title: "删除", symbol: "trash", selected: false, destructive: true, activate: {}, highlight: {}) { EmptyView() }
        }.padding(22).keylaneTheme(store: store), name: "applied-components", scheme: .dark, size: .init(width: 650, height: 260), directory: directory)
        let switcher = ThemeSwitcher(store: store)
        switcher.query = "我的雾港"; switcher.reconcile()
        guard switcher.matches.count == 1, switcher.selected?.id == theme.id else { throw ThemeError.invalid("主题搜索失败。") }
        switcher.query = "no matching synthetic theme"; switcher.reconcile()
        guard switcher.selected == nil else { throw ThemeError.invalid("空结果仍可应用主题。") }
        switcher.query = ""; switcher.reconcile(); switcher.move(1)
        guard switcher.selectedID == switcher.matches[1].id else { throw ThemeError.invalid("主题键盘导航失败。") }
        if ProcessInfo.processInfo.environment["KEYLANE_THEME_CAPTURE_WINDOW"] == "1" {
            studio.select(theme.id)
            try studio.captureWindow(to: directory.appendingPathComponent("window-dark.png"), appearance: .darkAqua)
            studio.preview.toggle(.application)
            try studio.captureWindow(to: directory.appendingPathComponent("window-application-menu.png"), appearance: .darkAqua)
            studio.preview.toggle(.actions)
            try studio.captureWindow(to: directory.appendingPathComponent("window-actions-menu.png"), appearance: .darkAqua)
            studio.preview.closeMenu()
            studio.select(ThemeDefinition.builtins[5].id)
            try studio.captureWindow(to: directory.appendingPathComponent("window-light.png"), appearance: .aqua)
        }
        try verifyPreviewInteraction(theme: theme)
        let corruptDomain = domain + ".corrupt"
        let corrupt = UserDefaults(suiteName: corruptDomain)!
        defer { corrupt.removePersistentDomain(forName: corruptDomain) }
        let corruptData = Data("broken library".utf8)
        corrupt.set(corruptData, forKey: "themes.library.v1")
        let damagedStore = ThemeStore(defaults: corrupt)
        var refusedOverwrite = false
        do { try damagedStore.save(theme) } catch { refusedOverwrite = true }
        guard refusedOverwrite else { throw ThemeError.invalid("损坏主题库被静默覆盖。") }
        guard corrupt.data(forKey: "themes.library.v1") == corruptData else { throw ThemeError.invalid("损坏数据未保留。") }
        print("Theme Studio: draft isolation, undo, validation, persistence, appearance slots and five UI renders passed.")
    }
    private static func verifyPreviewInteraction(theme: ThemeDefinition) throws {
        let state = ThemePreviewState()
        let ids = ThemePreviewState.rows.map(\.id)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let hosting = NSHostingView(rootView: ThemePreview(theme: theme, state: state))
        hosting.sizingOptions = []; window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 470)
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.12)); hosting.layoutSubtreeIfNeeded() }
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
            }
            pump()
        }
        pump()
        click(NSPoint(x: 28, y: 28))
        guard state.menu == .application else { throw ThemeError.invalid("预览左下角按钮无法打开菜单。") }
        state.menuQuery = "退出"; state.submit(); pump()
        guard state.menu == nil, state.feedback != nil else { throw ThemeError.invalid("预览应用菜单未模拟操作。") }
        state.feedback = nil
        click(NSPoint(x: 700, y: 28))
        guard state.menu == .actions else { throw ThemeError.invalid("预览右下角操作按钮无法打开菜单。") }
        state.activate("disabled")
        guard state.menu == .actions else { throw ThemeError.invalid("禁用操作被执行。") }
        state.activate("open-with")
        guard state.submenu != nil else { throw ThemeError.invalid("预览子菜单未打开。") }
        state.back(); state.activate("favorite")
        guard state.favorites.contains("calendar") else { throw ThemeError.invalid("预览收藏未更新。") }
        state.feedback = nil
        click(NSPoint(x: 605, y: 28))
        guard state.feedback != nil else { throw ThemeError.invalid("预览主操作按钮无法点击。") }
        state.feedback = nil
        click(NSPoint(x: 160, y: 440))
        if let editor = window.firstResponder as? NSTextView { editor.insertText("fixed example", replacementRange: editor.selectedRange()) }
        else { throw ThemeError.invalid("预览搜索栏无法输入。") }
        pump()
        guard state.query == "fixed example", ThemePreviewState.rows.map(\.id) == ids else { throw ThemeError.invalid("预览搜索改变了固定示例结果。") }
        if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125) { window.sendEvent(down) }
        pump()
        guard state.selectedID == "clipboard" else { throw ThemeError.invalid("预览列表键盘导航失败。") }
        state.select("unavailable")
        guard state.selectedID == "clipboard" else { throw ThemeError.invalid("禁用示例可被选中。") }
        if let command = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40) { window.sendEvent(command) }
        pump()
        guard state.menu == .actions else { throw ThemeError.invalid("预览 ⌘K 未打开操作菜单。") }
        print("Theme preview: native footer clicks, search editing with fixed results, selection, disabled action, submenu and favorites passed.")
    }
    private static func render<V: View>(_ content: V, name: String, scheme: ColorScheme, size: NSSize, directory: URL) throws {
        let view = NSHostingView(rootView: content.environment(\.colorScheme, scheme).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .init(x: -20000, y: -20000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = view; view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15)); view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ThemeError.invalid("无法渲染主题界面。") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw ThemeError.invalid("无法保存预览。") }
        try bytes.write(to: directory.appendingPathComponent(name + ".png"))
        window.contentView = nil; window.close()
    }
}
#endif
