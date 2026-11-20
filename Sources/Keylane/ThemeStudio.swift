import AppKit
import Combine
import KeylaneCore
import SwiftUI
import UniformTypeIdentifiers

/// Drafts belong to the editor, never to the active palette. Closing the window
/// keeps them in memory; only Save writes to the theme library.
final class ThemeStudio: NSObject, ObservableObject, NSWindowDelegate {
    let store: ThemeStore
    let undo = UndoManager()
    let preview = ThemePreviewState()
    @Published var selectedID = ThemeDefinition.darkID
    @Published private(set) var drafts: [UUID: ThemeDefinition] = [:]
    @Published private(set) var draftOrder: [UUID] = []
    @Published var error: String?
    var applyAppearance: (String) -> Void = { _ in }
    private var window: NSWindow?
    private var changes: AnyCancellable?

    init(store: ThemeStore = .shared) {
        self.store = store
        super.init()
        changes = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    var themes: [ThemeDefinition] {
        store.library.all.map { drafts[$0.id] ?? $0 } + draftOrder.compactMap { id in
            store.library.all.contains { $0.id == id } ? nil : drafts[id]
        }
    }
    var selected: ThemeDefinition { themes.first { $0.id == selectedID } ?? ThemeDefinition.builtins[0] }
    var dirty: Bool { drafts[selectedID] != nil }
    func select(_ id: UUID) { selectedID = id; error = nil }
    func edit(_ value: ThemeDefinition) {
        guard !value.isBuiltin else { return }
        let previous = selected
        guard previous != value else { return }
        undo.registerUndo(withTarget: self) { target in target.select(previous.id); target.edit(previous) }
        undo.setActionName("编辑主题")
        drafts[value.id] = value
    }
    func add(_ value: ThemeDefinition) {
        drafts[value.id] = value; draftOrder.append(value.id); select(value.id)
    }
    func create() { add(selected.duplicate(name: "新主题")) }
    func duplicate() { add(selected.duplicate()) }
    func save() {
        perform {
            try store.save(selected)
            drafts[selectedID] = nil; draftOrder.removeAll { $0 == selectedID }
            undo.removeAllActions()
        }
    }
    func reset() {
        let id = selectedID
        drafts[id] = nil; draftOrder.removeAll { $0 == id }
        if !store.library.all.contains(where: { $0.id == id }) { selectedID = ThemeDefinition.darkID }
        undo.removeAllActions(); error = nil
    }
    func assign() { assign(changeAppearance: false) }
    func apply() { assign(changeAppearance: true) }
    private func assign(changeAppearance: Bool) {
        perform {
            let value = selected
            if dirty { try store.save(value); drafts[value.id] = nil; draftOrder.removeAll { $0 == value.id } }
            try store.assign(value.id)
            if changeAppearance { applyAppearance(value.appearance.rawValue) }
        }
    }
    func remove() {
        guard !selected.isBuiltin else { return }
        let alert = NSAlert(); alert.messageText = "删除“\(selected.name)”？"
        alert.informativeText = "正在使用的主题会恢复为 Keylane 默认主题。"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            let id = selectedID
            if store.library.custom.contains(where: { $0.id == id }) { try store.remove(id) }
            reset()
        }
    }
    func copy(link: Bool) {
        perform {
            let text = try link ? ThemeArchive.url(selected).absoluteString : String(decoding: ThemeArchive.data(selected), as: UTF8.self)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "\(selected.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try ThemeArchive.data(selected).write(to: url, options: .atomic) }
    }
    func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let bytes = try handle.read(upToCount: ThemeArchive.maximumBytes + 1) ?? Data()
            add(try ThemeArchive.decode(bytes))
        }
    }
    func paste() {
        perform {
            guard let text = NSPasteboard.general.string(forType: .string) else { throw ThemeError.invalid("剪贴板中没有主题 JSON 或分享链接。") }
            add(try ThemeArchive.decode(text))
        }
    }
    func open(url: URL) { show(); perform { add(try ThemeArchive.decode(url.absoluteString)) } }
    func perform(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription } }
    func show(rememberFrame: Bool = true) {
        if window == nil {
            let window = ThemeStudioWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Theme Studio"; window.isReleasedWhenClosed = false; window.delegate = self
            window.minSize = NSSize(width: 1080, height: 620)
            window.studioUndo = undo
            let host = NSHostingController(rootView: ThemeStudioView(studio: self))
            host.sceneBridgingOptions = .all
            window.contentViewController = host
            window.toolbarStyle = .unified
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 1260, height: 780))
            if rememberFrame { window.setFrameAutosaveName("ThemeStudio") }
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        // Retain drafts, but release previews and their animations while the Studio is closed.
        DispatchQueue.main.async { [weak self, weak closed] in
            guard let self, let closed, closed === self.window, !closed.isVisible else { return }
            closed.contentViewController = nil; closed.contentView = nil; closed.toolbar = nil; self.window = nil
        }
    }
#if DEBUG
    func captureWindow(to url: URL, appearance: NSAppearance.Name) throws {
        NSApp.setActivationPolicy(.regular)
        show(rememberFrame: false)
        guard let window else { throw ThemeError.invalid("主题窗口缺失。") }
        window.appearance = NSAppearance(named: appearance)
        window.display(); window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let toolbar = window.toolbar, !toolbar.items.isEmpty else { throw ThemeError.invalid("主题工具栏缺失。") }
        let separators = toolbar.items.filter { $0 is NSTrackingSeparatorToolbarItem }.count
        guard separators == 2 else { throw ThemeError.invalid("原生分栏工具栏分隔线缺失。") }
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try capture.run(); capture.waitUntilExit()
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard capture.terminationStatus == 0 else { throw ThemeError.invalid("无法截取主题窗口。") }
    }
#endif

}

struct ThemeStudioView: View {
    @ObservedObject var studio: ThemeStudio
    @State private var filter = "all"
    @State private var query = ""
    @State private var inspectorVisible = true
    private var matches: [ThemeDefinition] {
        studio.themes.filter { (filter == "all" || $0.appearance.rawValue == filter) && (query.isEmpty || $0.name.localizedStandardContains(query)) }
    }
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 226, max: 300)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button("新建主题", systemImage: "plus", action: studio.create)
                    }
                }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("实时预览").font(.title3.bold())
                    ThemePreview(theme: studio.selected, state: studio.preview)
                    Text("输入搜索文字不会改变示例结果；菜单操作只在预览内生效。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(studio.selected.isBuiltin ? "内置主题只读，复制后即可编辑。" : "编辑只影响此预览。保存后，点击“应用主题”更新 Keylane。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if studio.selected.isBuiltin { Button("复制并编辑", systemImage: "plus.square.on.square", action: studio.duplicate) }
                        Spacer()
                        Button("应用主题", action: studio.apply).buttonStyle(.borderedProminent)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 460, maxWidth: .infinity)
                .navigationTitle("Theme Studio")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("显示检查器", systemImage: "sidebar.trailing") { inspectorVisible.toggle() }
                            .help(inspectorVisible ? "隐藏检查器" : "显示检查器")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $inspectorVisible) {
            inspector
                .inspectorColumnWidth(min: 250, ideal: 278, max: 380)
                .toolbar {
                    ToolbarItem {
                        Button("还原更改", systemImage: "arrow.uturn.backward", action: studio.reset).disabled(!studio.dirty)
                    }
                    ToolbarItem {
                        Button("保存", systemImage: "checkmark", action: studio.save).disabled(!studio.dirty)
                    }
                }
        }
        .onChange(of: studio.selectedID) { _, id in
            if let theme = studio.themes.first(where: { $0.id == id }), !matches.contains(where: { $0.id == id }) {
                filter = theme.appearance.rawValue; query = ""
            }
        }
        .background {
            Button("保存主题", action: studio.save).keyboardShortcut("s").disabled(!studio.dirty).hidden().accessibilityHidden(true)
        }
        .alert("主题操作失败", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
            Button("好", role: .cancel) { studio.error = nil }
        } message: { Text(studio.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("主题外观", selection: $filter) {
                Text("全部").tag("all"); Text("深色").tag("dark"); Text("浅色").tag("light")
            }.labelsHidden().padding(.horizontal, 12).padding(.top, 12)
            SettingsSearchField(text: $query, placeholder: "搜索主题…").frame(height: 30).padding(.horizontal, 12).padding(.top, 12)
            Text("已安装主题  \(studio.themes.count)").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            List(selection: Binding(get: { studio.selectedID }, set: { studio.select($0) })) {
                ForEach(matches) { theme in
                    HStack(spacing: 10) {
                        Image(systemName: theme.appearance == .dark ? "moon.fill" : "sun.max.fill")
                            .font(.caption).foregroundStyle(theme.color(.text).swiftUI)
                            .frame(width: 26, height: 26).background { ThemeBackgroundView(theme: theme).clipShape(Circle()) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(theme.name).lineLimit(1)
                            if studio.drafts[theme.id] != nil { Text("未保存").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        if theme.isBuiltin { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary) }
                        if studio.store.library.darkID == theme.id || studio.store.library.lightID == theme.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).font(.caption)
                        }
                    }.tag(theme.id)
                    .contextMenu {
                        Button("应用主题") { studio.select(theme.id); studio.apply() }
                        Button(theme.appearance == .dark ? "设为深色主题" : "设为浅色主题") { studio.select(theme.id); studio.assign() }
                        Button("复制主题") { studio.select(theme.id); studio.duplicate() }
                        Divider()
                        Button("复制分享链接") { studio.select(theme.id); studio.copy(link: true) }
                        Button("复制 JSON") { studio.select(theme.id); studio.copy(link: false) }
                        Button("导出 JSON…") { studio.select(theme.id); studio.export() }
                        if !theme.isBuiltin { Divider(); Button("删除主题…", role: .destructive) { studio.select(theme.id); studio.remove() } }
                    }
                }
            }.listStyle(.sidebar)
            Menu("导入与分享", systemImage: "square.and.arrow.up") {
                Button("粘贴主题或链接", action: studio.paste)
                Button("从文件导入…", action: studio.importFile)
                Divider()
                Button("复制分享链接") { studio.copy(link: true) }
                Button("复制 JSON") { studio.copy(link: false) }
                Button("导出 JSON…", action: studio.export)
            }.padding(.horizontal, 12)
            Text("✓ 当前深色／浅色主题").font(.caption2).foregroundStyle(.secondary).padding(12)
        }
    }
    private func binding<T>(_ key: WritableKeyPath<ThemeDefinition, T>) -> Binding<T> {
        Binding(get: { studio.selected[keyPath: key] }, set: { value in var copy = studio.selected; copy[keyPath: key] = value; studio.edit(copy) })
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("名称").font(.headline)
                TextField("主题名称", text: binding(\.name)).textFieldStyle(.roundedBorder)
                Picker("外观", selection: binding(\.appearance)) {
                    Label("浅色", systemImage: "sun.max").tag(ThemeAppearance.light)
                    Label("深色", systemImage: "moon").tag(ThemeAppearance.dark)
                }.pickerStyle(.segmented)
                Divider()
                Text("背景").font(.headline)
                Picker("背景类型", selection: binding(\.background.kind)) {
                    Text("纯色").tag(ThemeBackground.Kind.solid); Text("渐变").tag(ThemeBackground.Kind.gradient)
                }.pickerStyle(.segmented)
                ThemeColorField(title: studio.selected.background.kind == .solid ? "背景" : "起始颜色", hex: binding(\.background.color))
                if studio.selected.background.kind == .gradient {
                    ThemeColorField(title: "结束颜色", hex: binding(\.background.endColor))
                    HStack { Text("角度"); TextField("角度", value: binding(\.background.angle), format: .number).textFieldStyle(.roundedBorder); Text("°") }
                    Slider(value: binding(\.background.angle), in: 0...360).accessibilityLabel("渐变角度")
                }
                Divider(); Text("主要颜色").font(.headline)
                ForEach(Array(ThemeColorRole.allCases.prefix(3)), id: \.self, content: colorField)
                Divider(); Text("辅助颜色").font(.headline)
                ForEach(Array(ThemeColorRole.allCases.dropFirst(3)), id: \.self, content: colorField)
            }.padding(18).disabled(studio.selected.isBuiltin)
        }
    }
    private func colorField(_ role: ThemeColorRole) -> some View {
        ThemeColorField(title: role.title, hex: Binding(get: { studio.selected.colors[role.rawValue] ?? "" }, set: { value in
            var theme = studio.selected; theme.colors[role.rawValue] = value; studio.edit(theme)
        }))
    }
}

struct ThemeColorField: View {
    let title: String
    @Binding var hex: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            TextField("#RRGGBB", text: $hex).font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 94)
                .accessibilityLabel("\(title)十六进制颜色")
                .overlay(alignment: .bottom) { if (try? ThemeRGBA(hex)) == nil { Rectangle().fill(.red).frame(height: 1) } }
            ColorPicker(title, selection: Binding(get: { (try? ThemeRGBA(hex))?.swiftUI ?? .clear }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
                hex = "#" + channels.map { String(format: "%02X", min(255, max(0, Int(($0 * 255).rounded())))) }.joined()
            })).labelsHidden()
        }
    }
}

private final class ThemeStudioWindow: NSWindow {
    var studioUndo = UndoManager()
    override var undoManager: UndoManager? { studioUndo }
}
