import SwiftUI
import AppKit
import KeylaneCore

/// The AppKit popover owns its lifetime independently of toolbar SwiftUI updates.
struct ApplicationAutoQuitAddButton: View {
    let model: Model
    var body: some View {
        SettingsPopoverButton(title: "", symbol: "plus", label: "添加自动退出应用", enabled: model.applicationsEnabled) { dismiss in
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
        SettingsPopoverButton(title: minutes == ApplicationAutoQuit.useDefault ? "" : title(for: minutes),
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

/// Native presentation gives the search editor a real key window. A SwiftUI
/// toolbar popover can focus an editor while leaving its owner as the key window.
private struct SettingsPopoverButton: NSViewRepresentable {
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
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.fittingSize
    }
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

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: SettingsPopoverButton
        private var popover: NSPopover?
        init(_ parent: SettingsPopoverButton) { self.parent = parent }
        @objc func toggle(_ sender: NSButton) {
            if popover?.isShown == true { close(); return }
            guard parent.enabled, sender.window != nil else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: parent.content { [weak self] in self?.close() })
            self.popover = popover
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
        func popoverDidShow(_ notification: Notification) {
            popover?.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
        func close() { popover?.performClose(nil) }
        func popoverDidClose(_ notification: Notification) {
            popover?.contentViewController = nil
            popover = nil
        }
    }
}
