import SwiftUI
import AppKit
import KeylaneCore
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var selected = "applications"
    @State private var headerScrolledAway = false
    @State private var query = ""
    @State private var target: String?
    @State private var searchSelection: String?
    @State private var history = ["applications"]
    @State private var historyIndex = 0
    @Environment(\.colorScheme) private var scheme
    private var pages: [LauncherSettingsPage] { model.launcherModules?.settings ?? [] }
    private var page: LauncherSettingsPage? { pages.first { $0.id == selected } ?? pages.first }
    private var settingsItems: [SettingsItem] {
        pages.flatMap(\.items)
    }
    private var matches: [SettingsItem] { SettingsItem.search(query, in: settingsItems) }
    var body: some View {
        NavigationSplitView {
            ZStack(alignment: .top) {
                Group {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    List(selection: $searchSelection) {
                        searchClearance
                        ForEach(matches) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                Text(pages.first { $0.id == item.page }?.title ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .overlay { SettingsRowMouseDown { reveal(item) } }
                            .tag(item.id)
                        }
                    }.onChange(of: searchSelection) { _, id in if let item = settingsItems.first(where: { $0.id == id }) { reveal(item) } }
                    .overlay { if matches.isEmpty { ContentUnavailableView.search(text: query) } }
                } else {
                    List(selection: $selected) {
                        searchClearance
                        ForEach(pages) { item in
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
                }.scrollIndicators(.hidden)
                SettingsSearchField(text: $query, floating: true, submit: { if let item = matches.first { reveal(item) } })
                    .padding(.horizontal, 8).frame(height: 36)
                    .glassEffect(.regular, in: Capsule()).padding(.horizontal, 12).padding(.top, 12)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 230, max: 230)
        } detail: {
            SettingsPageContainer(pageID: selected, title: page?.title ?? "设置", symbol: page?.symbol ?? "gearshape", subtitle: page?.subtitle ?? "", target: target, headerScrolledAway: $headerScrolledAway) {
                if !model.error.isEmpty {
                    HStack {
                        Text(model.error).foregroundStyle(.red)
                        Spacer()
                        Button { model.error = "" } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                    }.padding(12).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                page?.content()
            }
        }.toggleStyle(SettingsSwitchStyle())
        .navigationTitle(headerScrolledAway ? (page?.title ?? "设置") : "")
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .preferredColorScheme(model.colorScheme)
        .onAppear { selected = model.settingsPage; history = [selected]; historyIndex = 0 }
        .onChange(of: selected) { _, page in
            if history[historyIndex] != page { history = Array(history.prefix(historyIndex + 1)); history.append(page); historyIndex = history.count - 1 }
            if model.settingsPage != page { model.settingsPage = page }
        }
        .onChange(of: model.settingsPage) { _, page in
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
    private static func card<Content: View>(@ViewBuilder content: () -> Content) -> some View { SettingsGroup(content: content) }
    @ViewBuilder static func general(_ model: Model) -> some View {
        card {
            Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
            Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.glass)
        }.id("login")
        LauncherAppearancePreferences(model: model)
        card { SettingsPicker("窗口位置", selection: Binding(get: { model.placement }, set: { model.placement = $0 })) { Text("当前屏幕居中").tag("activeScreen"); Text("记住上次位置").tag("remember") } }.id("position")
        card { KeyboardPreferences(model: model) }.id("keyboard")
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
        card { LabeledContent("已保存便笺", value: String(model.savedNotes.count)); Text("使用本机 SQLite 自动保存。").foregroundStyle(.secondary); Button("导出便笺…") { model.exportData() }.buttonStyle(ContentActionButtonStyle()) }.id("export")
    }

    @ViewBuilder static func links(_ model: Model) -> some View {
        card { Text("默认快捷链接").font(.headline); TextField("https://example.com", text: Binding(get: { model.link }, set: { model.link = $0 })).textFieldStyle(.roundedBorder); Text("当前支持一个默认链接。链接集合与参数化功能尚未实现。").foregroundStyle(.secondary) }.id("quicklink")
    }

    @ViewBuilder static func advanced(_ model: Model) -> some View {
        card { Text("资料目录").font(.headline); Text("Application Support/Keylane").foregroundStyle(.secondary); Button("在 Finder 中显示") { let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane"); NSWorkspace.shared.open(url) }.buttonStyle(ContentActionButtonStyle()) }.id("directory")
        card { Text("无遥测").font(.headline); Text("默认无遥测。文件 AI 仅在你主动发送时连接所配置的服务；云同步与扩展模块尚未接入。").foregroundStyle(.secondary) }.id("privacy")
    }

    @ViewBuilder static func about(_ model: Model) -> some View {
        card { LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版")); LabeledContent("许可", value: "PolyForm Noncommercial 1.0.0"); Text("独立实现，非 SuperCmd 或 Raycast 官方产品。").foregroundStyle(.secondary) }.id("version")
        card { Text("开发状态").font(.headline); Text("当前支持应用搜索、计算器、多便笺、持久化剪贴板、快捷链接和部分系统工具。窗口管理、AI、扩展、同步等主要模块尚未完成。").foregroundStyle(.secondary) }.id("status")
    }
}
