import SwiftUI
import AppKit
import KeylaneCore

/// Search menus share the clipboard filter surface and stay in their owner window.
struct ApplicationAutoQuitAddButton: View {
    let model: Model
    var body: some View {
        SettingsSearchMenuButton(title: "", symbol: "plus", label: "添加自动退出应用", enabled: model.applicationsEnabled) { dismiss in
            AnyView(ApplicationAutoQuitPicker(model: model, dismiss: dismiss))
        }
    }
}

private struct ApplicationAutoQuitPicker: View {
    let model: Model
    let dismiss: () -> Void
    @ObservedObject private var catalog: ApplicationSettingsCatalog
    @ObservedObject private var autoQuit: ApplicationAutoQuit
    @State private var query = ""
    @State private var options: [ResultFilterOption] = []
    @State private var error: String?

    init(model: Model, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        catalog = model.applicationSettingsCatalog
        autoQuit = model.applicationAutoQuit
    }

    var body: some View {
        VStack(spacing: 0) {
            ResultFilterPanel(selection: "", options: ResultFilterPanel.matches(options, query: query.trimmingCharacters(in: .whitespacesAndNewlines)),
                              query: $query, searchPlaceholder: "搜索应用…",
                              emptyTitle: options.isEmpty ? "没有可添加的应用" : "没有匹配的应用",
                              navigation: model.navigation, width: 360, maximumVisibleRows: 6,
                              choose: add, dismiss: dismiss)
            if let error {
                Divider()
                Text(error).font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .onAppear(perform: refreshOptions)
        .onChange(of: catalog.items) { _, _ in refreshOptions() }
        .onChange(of: autoQuit.rules.keys.sorted()) { _, _ in refreshOptions() }
    }

    private func refreshOptions() {
        let available = catalog.items.filter { autoQuit.minutes(for: $0.url) == 0 && autoQuit.canConfigure($0.url) }
        let names = Dictionary(grouping: available, by: \.title)
        options = available.map { item in
            let path = (item.id as NSString).abbreviatingWithTildeInPath
            return ResultFilterOption(id: item.id, title: item.title, symbol: "app", iconPath: item.id,
                                      subtitle: names[item.title, default: []].count > 1 ? path : nil)
        }
    }

    private func add(_ option: ResultFilterOption) {
        let url = URL(fileURLWithPath: option.id)
        guard catalog.items.contains(where: { $0.id == option.id }), autoQuit.canConfigure(url) else {
            error = "应用已移动或不可用。"
            refreshOptions()
            return
        }
        if autoQuit.minutes(for: url) == 0 {
            autoQuit.setMinutes(ApplicationAutoQuit.useDefault, for: url)
        }
        dismiss()
    }
}

struct AutoQuitDurationPicker: View {
    let label: String
    let minutes: Int
    let defaultMinutes: Int?
    let navigation: String
    let select: (Int) -> Void

    var body: some View {
        SettingsSearchMenuButton(title: minutes == ApplicationAutoQuit.useDefault ? "" : title(for: minutes),
                              symbol: "clock", label: label, value: title(for: minutes)) { dismiss in
            AnyView(AutoQuitDurationOptions(minutes: minutes, defaultMinutes: defaultMinutes,
                                           navigation: navigation, title: title, select: { value in
                dismiss()
                select(value)
            }, dismiss: dismiss))
        }
    }

    private func title(for duration: Int) -> String {
        if duration == ApplicationAutoQuit.useDefault, let defaultMinutes {
            return "使用默认时长（\(defaultMinutes) 分钟）"
        }
        return "\(duration) 分钟"
    }
}

private struct AutoQuitDurationOptions: View {
    let minutes: Int
    let defaultMinutes: Int?
    let navigation: String
    let title: (Int) -> String
    let select: (Int) -> Void
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        let values = (defaultMinutes == nil ? [] : [ApplicationAutoQuit.useDefault]) + ApplicationAutoQuit.intervals
        let options = values.map { ResultFilterOption(id: String($0), title: title($0), symbol: "") }
        ResultFilterPanel(selection: String(minutes), options: ResultFilterPanel.matches(options, query: query),
                          query: $query, searchPlaceholder: "搜索时长…", emptyTitle: "没有匹配时长",
                          navigation: navigation, maximumVisibleRows: 5, choose: { option in
            if let value = Int(option.id) { select(value) }
        }, dismiss: dismiss)
    }
}

/// Host the same in-window search surface as the clipboard filter. Keeping the
/// editor in the owner window avoids transient-popover dismissal during keyboard
/// activation. Only pointer events outside the menu and window lifecycle close it.
private struct SettingsSearchMenuButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let label: String
    var value: String? = nil
    var enabled = true
    let content: (@escaping () -> Void) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.bezelStyle = .texturedRounded
        configure(button)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        configure(button)
        if !enabled { context.coordinator.close() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { nsView.fittingSize }
    private func configure(_ button: NSButton) {
        button.title = title.isEmpty ? label : title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.isEnabled = enabled
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(value)
    }
    static func dismantleNSView(_ view: NSButton, coordinator: Coordinator) { coordinator.close() }

    final class Coordinator: NSObject {
        var parent: SettingsSearchMenuButton
        private weak var button: NSButton?
        private weak var owner: NSWindow?
        private var menu: MenuView?
        private var pointerMonitor: Any?
        private var observations: [NSObjectProtocol] = []
        init(_ parent: SettingsSearchMenuButton) { self.parent = parent }

        @objc func toggle(_ sender: NSButton) {
            if menu != nil { close(); return }
            guard parent.enabled, let owner = sender.window, let container = owner.contentView else { return }
            self.button = sender
            self.owner = owner
            let surface = parent.content { [weak self] in self?.close() }
                .modifier(LauncherMenuSurface(open: true))
                .fixedSize()
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
                .accessibilityIdentifier("settings-search-menu")
            let menu = MenuView(rootView: AnyView(surface))
            menu.identifier = NSUserInterfaceItemIdentifier("KeylaneSettingsSearchMenu")
            menu.resized = { [weak self] in self?.positionMenu() }
            self.menu = menu
            container.addSubview(menu, positioned: .above, relativeTo: nil)
            positionMenu()
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                guard let self, let menu = self.menu, let container = menu.superview else { return event }
                guard event.window === self.owner else { self.close(); return event }
                let point = container.convert(event.locationInWindow, from: nil)
                let anchor = self.button.map { container.convert($0.bounds, from: $0) } ?? .zero
                if !menu.frame.contains(point) && !anchor.contains(point) { self.close() }
                return event
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in self?.close() })
            }
            observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: owner, queue: .main) { [weak self] _ in self?.positionMenu() })
        }

        private func positionMenu() {
            guard let menu, let container = menu.superview, let button, button.window === owner else { close(); return }
            let size = menu.fittingSize
            guard size.width > 0, size.height > 0 else { return }
            let bounds = container.bounds.insetBy(dx: 8, dy: 8)
            let anchor = container.convert(button.bounds, from: button)
            let x = min(max(bounds.minX, anchor.maxX - size.width), max(bounds.minX, bounds.maxX - size.width))
            let below = container.isFlipped ? anchor.maxY + 6 : anchor.minY - size.height - 6
            let above = container.isFlipped ? anchor.minY - size.height - 6 : anchor.maxY + 6
            let fitsBelow = below >= bounds.minY && below + size.height <= bounds.maxY
            let preferred = fitsBelow ? below : above
            let y = min(max(bounds.minY, preferred), max(bounds.minY, bounds.maxY - size.height))
            let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
            if menu.frame != frame { menu.frame = frame }
        }

        func close() {
            guard let menu else { return }
            self.menu = nil
            menu.resized = nil
            menu.removeFromSuperview()
            if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
            pointerMonitor = nil
            observations.forEach(NotificationCenter.default.removeObserver)
            observations = []
            if let owner, let button, button.window === owner { owner.makeFirstResponder(button) }
            button = nil
            owner = nil
        }
    }

    final class MenuView: NSHostingView<AnyView> {
        var resized: (() -> Void)?
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in self?.resized?() }
        }
    }
}
