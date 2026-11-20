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
            let window = ThemeStudioWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Theme Studio"; window.isReleasedWhenClosed = false; window.delegate = self
            window.minSize = NSSize(width: 1040, height: 440)
            window.studioUndo = undo
            let host = NSHostingController(rootView: ThemeStudioView(studio: self))
            host.sceneBridgingOptions = [.toolbars]
            window.contentViewController = host
            window.toolbarStyle = .unified
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 1280, height: 540))
            if rememberFrame { window.setFrameAutosaveName("ThemeStudio") }
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak window] in
            // The hosting bridge also supplies AppKit's standard sidebar item.
            if let toolbar = window?.toolbar, let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .toggleSidebar || $0.action == #selector(NSSplitViewController.toggleSidebar(_:)) }) {
                toolbar.removeItem(at: index)
            }
        }
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
    private var matches: [ThemeDefinition] {
        studio.themes.filter { filter == "all" || $0.appearance.rawValue == filter }
    }
    private var filterTitle: String { filter == "dark" ? "Dark" : filter == "light" ? "Light" : "All" }
    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 252)
                .navigationSplitViewColumnWidth(252)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            ForEach(["all", "dark", "light"], id: \.self) { value in
                                Button { filter = value } label: {
                                    let title = value == "all" ? "All" : value == "dark" ? "Dark" : "Light"
                                    if filter == value { Label(title, systemImage: "checkmark") } else { Text(title) }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) { Image(systemName: "list.bullet"); Text(filterTitle); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }
                        }.menuIndicator(.hidden).help("Filter Themes")
                    }
                    ToolbarSpacer(.fixed)
                    ToolbarItem {
                        Button("New Theme", systemImage: "doc.badge.plus", action: studio.create)
                    }
                }
        } detail: {
            GeometryReader { geometry in
                ThemePreview(theme: studio.selected, state: studio.preview)
                    .frame(width: max(1, min(geometry.size.width - 72, (geometry.size.height - 64) * VisualStyle.launcherWidth / ThemePreview.height)))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(minWidth: 520)
            .ignoresSafeArea(.container, edges: .top)
            .navigationTitle("")
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .inspector(isPresented: .constant(true)) {
            inspector
                .inspectorColumnWidth(min: 240, ideal: 252, max: 320)
                .toolbar {
                    ToolbarItemGroup {
                        Button("Paste Theme", systemImage: "clipboard", action: studio.paste)
                        Button("Revert Changes", systemImage: "arrow.uturn.backward", action: studio.reset).disabled(!studio.dirty)
                    }
                    ToolbarSpacer(.flexible)
                    ToolbarItem {
                        Button("Save", action: studio.save).keyboardShortcut("s").disabled(!studio.dirty)
                    }
                }
        }
        .onChange(of: studio.selectedID) { _, id in
            if let theme = studio.themes.first(where: { $0.id == id }), !matches.contains(where: { $0.id == id }) { filter = theme.appearance.rawValue }
        }
        .alert("Theme could not be updated", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
            Button("OK", role: .cancel) { studio.error = nil }
        } message: { Text(studio.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Installed Themes"); Text("\(studio.themes.count)").foregroundStyle(.tertiary)
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 3)
            List(selection: Binding(get: { studio.selectedID }, set: { studio.select($0) })) {
                ForEach(matches) { theme in
                    HStack(spacing: 9) {
                        Image(systemName: theme.appearance == .dark ? "moon" : "sun.max")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.color(.text).swiftUI)
                            .frame(width: 22, height: 22)
                            .background { ThemeBackgroundView(theme: theme).clipShape(Circle()) }
                            .overlay(Circle().stroke(.primary.opacity(0.3), lineWidth: 0.5))
                        Text(theme.name).font(.system(size: 13)).lineLimit(1)
                        if theme.isBuiltin { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.tertiary) }
                        if studio.drafts[theme.id] != nil { Circle().fill(.secondary).frame(width: 4, height: 4).accessibilityLabel("Unsaved") }
                        Spacer(minLength: 0)
                        if studio.store.library.darkID == theme.id { assignedIcon(dark: true) }
                        if studio.store.library.lightID == theme.id { assignedIcon(dark: false) }
                    }.frame(height: 28).tag(theme.id)
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .contextMenu {
                        Button("Apply Theme") { studio.select(theme.id); studio.apply() }
                        Button(theme.appearance == .dark ? "Use as Dark Theme" : "Use as Light Theme") { studio.select(theme.id); studio.assign() }
                        Button("Duplicate Theme") { studio.select(theme.id); studio.duplicate() }
                        Divider()
                        Button("Copy Theme URL") { studio.select(theme.id); studio.copy(link: true) }
                        Button("Copy JSON") { studio.select(theme.id); studio.copy(link: false) }
                        Button("Export Theme…") { studio.select(theme.id); studio.export() }
                        Button("Import Themes…", action: studio.importFile)
                        if !theme.isBuiltin { Divider(); Button("Delete Theme…", role: .destructive) { studio.select(theme.id); studio.remove() } }
                    }
                }
            }.listStyle(.sidebar)
        }
    }
    private func assignedIcon(dark: Bool) -> some View {
        Image(systemName: dark ? "moon" : "sun.max")
            .font(.system(size: 12, weight: .medium)).foregroundStyle(dark ? Color.cyan : .yellow)
            .frame(width: 22, height: 22).background((dark ? Color.cyan : .yellow).opacity(0.1), in: Circle())
            .accessibilityLabel(dark ? "Current Dark Theme" : "Current Light Theme")
    }
    private func binding<T>(_ key: WritableKeyPath<ThemeDefinition, T>) -> Binding<T> {
        Binding(get: { studio.selected[keyPath: key] }, set: { value in var copy = studio.selected; copy[keyPath: key] = value; studio.edit(copy) })
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Theme Name")
                    TextField("Theme Name", text: binding(\.name)).textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.18)))
                    HStack {
                        sectionTitle("Theme Appearance")
                        Spacer()
                        appearanceButton(.light, symbol: "sun.max")
                        appearanceButton(.dark, symbol: "moon")
                    }.padding(.top, 8).frame(height: 34)
                }.padding(.bottom, 16)
                Divider().padding(.horizontal, -18)
                VStack(spacing: 0) {
                    HStack {
                        sectionTitle("Background").fixedSize()
                        Spacer(minLength: 4)
                        ForEach([ThemeBackground.Kind.solid, .gradient], id: \.self) { kind in
                            Button { var theme = studio.selected; theme.background.kind = kind; studio.edit(theme) } label: {
                                Text(kind == .solid ? "Solid" : "Gradient").font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(.primary.opacity(studio.selected.background.kind == kind ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }.frame(height: 32)
                    ThemeColorField(title: "Background Color", hex: binding(\.background.color))
                    if studio.selected.background.kind == .gradient {
                        ThemeColorField(title: "End Color", hex: binding(\.background.endColor))
                        HStack { Text("Angle"); Slider(value: binding(\.background.angle), in: 0...360); Text("\(Int(studio.selected.background.angle.isFinite ? studio.selected.background.angle : 0))°").monospacedDigit() }.font(.system(size: 12)).frame(height: 30)
                    }
                }.padding(.top, 12).padding(.bottom, 12)
                sectionTitle("Primary Colors").padding(.top, 10).padding(.bottom, 10)
                ForEach(Array(ThemeColorRole.allCases.prefix(3)), id: \.self, content: colorField)
                Divider().padding(.horizontal, -18).padding(.top, 12)
                sectionTitle("Support Colors").padding(.top, 16).padding(.bottom, 10)
                ForEach(Array(ThemeColorRole.allCases.dropFirst(3)), id: \.self, content: colorField)
            }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 18).disabled(studio.selected.isBuiltin)
        }
    }
    private func appearanceButton(_ appearance: ThemeAppearance, symbol: String) -> some View {
        Button { var theme = studio.selected; theme.appearance = appearance; studio.edit(theme) } label: {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(studio.selected.appearance == appearance ? .primary : .secondary)
                .frame(width: 22, height: 22).background(.primary.opacity(studio.selected.appearance == appearance ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel(appearance == .dark ? "Dark" : "Light")
    }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
    private func colorField(_ role: ThemeColorRole) -> some View {
        let titles: [ThemeColorRole: String] = [.text: "Text", .selection: "Selection", .loader: "Loader", .red: "Red", .orange: "Orange", .yellow: "Yellow", .green: "Green", .blue: "Blue", .purple: "Purple", .magenta: "Magenta"]
        return ThemeColorField(title: titles[role] ?? role.rawValue, hex: Binding(get: { studio.selected.colors[role.rawValue] ?? "" }, set: { value in
            var theme = studio.selected; theme.colors[role.rawValue] = value; studio.edit(theme)
        }))
    }
}

/// A compact native color well. The system color panel provides exact numeric input.
struct ThemeColorField: View {
    let title: String
    @Binding var hex: String
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            ThemeColorWell(title: title, hex: $hex).frame(width: 22, height: 22)
        }.frame(height: 36)
    }
}

private final class ThemeNativeColorWell: NSColorWell {
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        color.setFill(); path.fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke(); path.lineWidth = 0.5; path.stroke()
    }
}

private struct ThemeColorWell: NSViewRepresentable {
    let title: String
    @Binding var hex: String
    @Environment(\.isEnabled) private var isEnabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSColorWell {
        let well = ThemeNativeColorWell()
        well.colorWellStyle = .minimal; well.supportsAlpha = true
        well.target = context.coordinator; well.action = #selector(Coordinator.changed(_:))
        well.setAccessibilityLabel(title)
        return well
    }
    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.parent = self
        well.isEnabled = isEnabled
        let color = (try? ThemeRGBA(hex))?.nsColor ?? .clear
        if !well.color.isEqual(color) { well.color = color }
    }
    final class Coordinator: NSObject {
        var parent: ThemeColorWell
        init(_ parent: ThemeColorWell) { self.parent = parent }
        @objc func changed(_ well: NSColorWell) {
            guard let rgb = well.color.usingColorSpace(.sRGB) else { return }
            parent.hex = "#" + [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
                .map { String(format: "%02X", min(255, max(0, Int(($0 * 255).rounded())))) }.joined()
        }
    }
}

private final class ThemeStudioWindow: NSWindow {
    var studioUndo = UndoManager()
    override var undoManager: UndoManager? { studioUndo }
}
