import SwiftUI
import AppKit
import KeylaneCore

struct SettingsView: View {
    @ObservedObject var state: SettingsWindowState
    @State private var selected = "applications"
    @State private var headerScrolledAway = false
    @State private var query = ""
    @State private var target: String?
    @State private var searchSelection: String?
    @State private var history = ["applications"]
    @State private var historyIndex = 0
    private var page: LauncherSettingsPage? { state.catalog.page(selected) ?? state.catalog.pages.first }

    var body: some View {
        let matches = SettingsItem.search(query, in: state.catalog.items)
        return NavigationSplitView {
            sidebar(matches: matches)
        } detail: {
            SettingsPageContainer(pageID: selected, title: page?.title ?? "设置", symbol: page?.symbol ?? "gearshape", subtitle: page?.subtitle ?? "", target: target, headerScrolledAway: $headerScrolledAway) {
                if !state.error.isEmpty {
                    HStack {
                        Text(state.error).foregroundStyle(.red)
                        Spacer()
                        Button { state.clearError() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                    }.padding(12).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                page?.content()
            }
        }.toggleStyle(SettingsSwitchStyle())
        .navigationTitle(headerScrolledAway ? (page?.title ?? "设置") : "")
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .preferredColorScheme(state.colorScheme)
        .onAppear { selected = state.page; history = [selected]; historyIndex = 0 }
        .onChange(of: selected) { _, page in
            if history[historyIndex] != page { history = Array(history.prefix(historyIndex + 1)); history.append(page); historyIndex = history.count - 1 }
            if state.page != page { state.select(page) }
        }
        .onChange(of: state.page) { _, page in
            guard selected != page else { return }
            selected = page
            query = ""
            target = nil
        }
        .toolbar {

            ToolbarItemGroup(placement: .navigation) {
                ControlGroup {
                    Button { historyIndex -= 1; selected = history[historyIndex] } label: { Image(systemName: "chevron.backward") }.disabled(historyIndex == 0).help("后退")
                    Button { historyIndex += 1; selected = history[historyIndex] } label: { Image(systemName: "chevron.forward") }.disabled(historyIndex == history.count - 1).help("前进")
                }.controlGroupStyle(.navigation)
            }

        }
    }
    private func sidebar(matches: [SettingsItem]) -> some View {
        ZStack(alignment: .top) {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    settingsPages
                } else {
                    searchResults(matches)
                }
            }.scrollIndicators(.hidden)
            SettingsSearchField(text: $query, floating: true, submit: {
                if let item = matches.first { reveal(item) }
            })
            .padding(.horizontal, 8).frame(height: 36)
            .glassEffect(.regular, in: Capsule()).padding(.horizontal, 12).padding(.top, 12)
        }.navigationSplitViewColumnWidth(min: 230, ideal: 230, max: 230)
    }

    private var settingsPages: some View {
        List(selection: $selected) {
            searchClearance
            ForEach(state.catalog.pages) { item in
                Label { Text(item.title).font(VisualStyle.rowText) } icon: {
                    SettingsIcon(symbol: item.symbol)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .overlay { SettingsRowMouseDown { selected = item.id } }
                .tag(item.id)
            }
        }.listStyle(.sidebar)
    }

    private func searchResults(_ matches: [SettingsItem]) -> some View {
        List(selection: $searchSelection) {
            searchClearance
            ForEach(matches) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                    Text(state.catalog.page(item.page)?.title ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .overlay { SettingsRowMouseDown { reveal(item) } }
                .tag(item.id)
            }
        }
        .onChange(of: searchSelection) { _, id in
            if let id, let item = state.catalog.item(id) { reveal(item) }
        }
        .overlay { if matches.isEmpty { ContentUnavailableView.search(text: query) } }
    }

    private var searchClearance: some View {
        Color.clear.frame(height: 52).listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear).disabled(true).accessibilityHidden(true)
    }
    private func reveal(_ item: SettingsItem) {
        selected = item.page; target = nil; searchSelection = nil; query = ""
        DispatchQueue.main.async { target = item.id }
    }
}

/// Handles the physical press while List still owns selection for keyboard and VoiceOver.
private struct SettingsRowMouseDown: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> PressView { PressView() }

    func updateNSView(_ view: PressView, context: Context) {
        view.action = action
    }

    final class PressView: NSView {
        var action: (() -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // AppKit normally focuses the table as part of handling its own click.
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    window?.makeFirstResponder(table)
                    break
                }
                ancestor = view.superview
            }
            action?()
        }
    }
}

enum LauncherSettingsContent {
    @ViewBuilder static func general(_ model: Model) -> some View {
        LoginPreferences(model: model)
        LauncherAppearancePreferences(model: model)
        WindowPositionPreferences(model: model)
        KeyboardPreferences(model: model).settingsAnchor(.keyboard)
    }

    @ViewBuilder static func applications(_ model: Model) -> some View {
        ApplicationPreferences(model: model)
    }

    @ViewBuilder static func files(_ model: Model) -> some View {
        FileSearchPreferences(controller: model.fileSearch, model: model)
    }

    @ViewBuilder static func clipboard(_ model: Model) -> some View {
        ClipboardPreferences(controller: model.clipboard, model: model)
    }

    @ViewBuilder static func notes(_ model: Model) -> some View {
        NotesSettings(model: model)
    }

    @ViewBuilder static func links(_ model: Model) -> some View {
        QuicklinkSettings(model: model)
    }

    @ViewBuilder static func advanced(_ model: Model) -> some View {
        SettingsGroup { Text("资料目录").font(.headline); Text("Application Support/Keylane").foregroundStyle(.secondary); Button("在 Finder 中显示") { let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane"); NSWorkspace.shared.open(url) }.buttonStyle(ContentActionButtonStyle()) }.settingsAnchor(.dataDirectory)
        SettingsGroup { Text("无遥测").font(.headline); Text("默认无遥测。文件 AI 仅在你主动发送时连接所配置的服务；云同步与扩展模块尚未接入。").foregroundStyle(.secondary) }.settingsAnchor(.privacy)
    }

    @ViewBuilder static func about(_ model: Model) -> some View {
        SettingsGroup { LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版")); LabeledContent("许可", value: "PolyForm Noncommercial 1.0.0"); Text("独立实现，非 SuperCmd 或 Raycast 官方产品。").foregroundStyle(.secondary) }.settingsAnchor(.version)
        SettingsGroup { Text("开发状态").font(.headline); Text("当前支持应用搜索、计算器、多便笺、持久化剪贴板、快捷链接和部分系统工具。窗口管理、AI、扩展、同步等主要模块尚未完成。").foregroundStyle(.secondary) }.settingsAnchor(.developmentStatus)
    }
}


private struct LoginPreferences: View {
    let model: Model
    @StateObject private var observation: SettingsPageObservation

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: SettingsPageObservation([
            SettingsPageObservation.changes(model.$loginEnabled)
        ]))
    }

    var body: some View {
        SettingsGroup("启动") {
            Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
        }.settingsAnchor(.login)
    }
}

private struct WindowPositionPreferences: View {
    let model: Model
    @State private var placement = "activeScreen"

    var body: some View {
        SettingsGroup("位置") {
            SettingsPicker("窗口位置", selection: Binding(get: { placement }, set: { model.placement = $0 })) {
                Text("当前屏幕居中").tag("activeScreen")
                Text("记住上次位置").tag("remember")
            }
        }
        .settingsAnchor(.windowPosition)
        .onReceive(model.$placement.removeDuplicates()) { placement = $0 }
    }
}

private struct NotesSettings: View {
    let model: Model
    @State private var count = 0

    var body: some View {
        SettingsGroup("便笺") {
            SettingsRow("已保存便笺") { Text(count.formatted()).foregroundStyle(.secondary) }
            Divider()
            SettingsActionRow(title: "便笺数据", actionTitle: "导出…") { model.exportData() }
        }
        .settingsAnchor(.noteExport)
        .onReceive(model.$savedNotes.map(\.count).removeDuplicates()) { count = $0 }
    }
}

private struct QuicklinkSettings: View {
    let model: Model
    @State private var link = ""

    var body: some View {
        SettingsGroup("链接") {
            SettingsRow("默认快捷链接") {
                TextField("默认快捷链接", text: Binding(get: { link }, set: { model.link = $0 }),
                          prompt: Text("https://example.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
        .settingsAnchor(.quicklink)
        .onReceive(model.$link.removeDuplicates()) { link = $0 }
    }
}
