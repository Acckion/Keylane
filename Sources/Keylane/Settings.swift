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
    private let pages: [(String,String,String)] = [("general","通用","slider.horizontal.3"),("applications","应用程序","square.grid.2x2.fill"),("files","文件搜索","doc.text.magnifyingglass"),("clipboard","剪贴板历史","clipboard.fill"),("notes","便笺","note.text"),("links","快捷链接","link"),("advanced","高级","wrench.and.screwdriver"),("about","关于 Keylane","info.circle")]
    private var page: (String,String,String) { pages.first { $0.0 == selected } ?? pages[0] }
    var body: some View {
        NavigationSplitView {
            ZStack(alignment: .top) {
                Group {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    List(selection: $searchSelection) {
                        searchClearance
                        ForEach(SettingsItem.search(query)) { item in
                            VStack(alignment: .leading, spacing: 3) { Text(item.title); Text(pages.first { $0.0 == item.page }?.1 ?? "").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).tag(item.id)
                        }
                    }.onChange(of: searchSelection) { _, id in if let item = SettingsItem.all.first(where: { $0.id == id }) { reveal(item) } }
                    .overlay { if SettingsItem.search(query).isEmpty { ContentUnavailableView.search(text: query) } }
                } else {
                List(selection: $selected) { searchClearance; ForEach(pages, id: \.0) { item in
                    Label { Text(item.1).font(VisualStyle.rowText) } icon: { SettingsIcon(symbol: item.2) }.padding(.vertical, 5).tag(item.0)
                } }.listStyle(.sidebar)
                }
                }.scrollIndicators(.hidden)
                SettingsSearchField(text: $query, floating: true, submit: { if let item = SettingsItem.search(query).first { reveal(item) } })
                    .padding(.horizontal, 8).frame(height: 36)
                    .glassEffect(.regular, in: Capsule()).padding(.horizontal, 12).padding(.top, 12)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 230, max: 230)
        } detail: {
            SettingsPageContainer(title: page.1, symbol: page.2, subtitle: subtitle, target: target, headerScrolledAway: $headerScrolledAway) {
                if !model.error.isEmpty {
                    HStack {
                        Text(model.error).foregroundStyle(.red)
                        Spacer()
                        Button { model.error = "" } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                    }.padding(12).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                settingsContent
            }
            .id(selected)
        }.toggleStyle(SettingsSwitchStyle())
        .navigationTitle(headerScrolledAway ? page.1 : "")
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .preferredColorScheme(model.colorScheme)
        .onAppear { selected = model.settingsPage; history = [selected]; historyIndex = 0 }
        .onChange(of: selected) { _, page in
            if history[historyIndex] != page { history = Array(history.prefix(historyIndex + 1)); history.append(page); historyIndex = history.count - 1 }
            if model.settingsPage != page { model.settingsPage = page }
        }
        .onChange(of: model.settingsPage) { _, page in selected = page; query = ""; target = nil }
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
    private var subtitle: String { switch selected { case "applications": return "快速查找并启动已安装的应用程序。"; case "files": return "搜索电脑上的文件与文件夹。"; case "general": return "管理外观、快捷键和启动方式。"; case "links": return "设置常用链接，快速打开。"; case "advanced": return "管理本地资料与隐私设置。"; case "clipboard": return "查找本地保存的文字、图片和文件引用。"; case "notes": return "保存你的想法，随时继续。"; case "about": return "独立、原生、以键盘为中心。"; default: return "按照你的习惯使用 Keylane。" } }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 14, content: content).padding(18).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsSurface()) }
    @ViewBuilder private var settingsContent: some View {
        switch selected {
        case "general":
            card {
                Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
                Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.glass)
            }.id("login")
            LauncherAppearancePreferences(model: model)
            card { SettingsPicker("窗口位置", selection: $model.placement) { Text("当前屏幕居中").tag("activeScreen"); Text("记住上次位置").tag("remember") } }.id("position")
            card { KeyboardPreferences(model: model) }.id("keyboard")
        case "applications":
            ApplicationPreferences(model: model)
        case "files":
            FileSearchPreferences(controller: model.fileSearch, model: model)
        case "clipboard":
            ClipboardPreferences(controller: model.clipboard, model: model)
        case "notes":
            card { LabeledContent("已保存便笺", value: String(model.savedNotes.count)); Text("使用本机 SQLite 自动保存。").foregroundStyle(.secondary); Button("导出便笺…") { model.exportData() }.buttonStyle(.glass) }.id("export")
        case "links":
            card { Text("默认快捷链接").font(.headline); TextField("https://example.com", text: $model.link).textFieldStyle(.roundedBorder); Text("当前支持一个默认链接。链接集合与参数化功能尚未实现。").foregroundStyle(.secondary) }.id("quicklink")
        case "advanced":
            card { Text("资料目录").font(.headline); Text("Application Support/Keylane").foregroundStyle(.secondary); Button("在 Finder 中显示") { let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane"); NSWorkspace.shared.open(url) }.buttonStyle(.glass) }.id("directory")
            card { Text("无遥测").font(.headline); Text("默认无遥测。文件 AI 仅在你主动发送时连接所配置的服务；云同步与扩展模块尚未接入。").foregroundStyle(.secondary) }.id("privacy")
        default:
            card { LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版")); LabeledContent("许可", value: "PolyForm Noncommercial 1.0.0"); Text("独立实现，非 SuperCmd 或 Raycast 官方产品。").foregroundStyle(.secondary) }.id("version")
            card { Text("开发状态").font(.headline); Text("当前支持应用搜索、计算器、多便笺、持久化剪贴板、快捷链接和部分系统工具。窗口管理、AI、扩展、同步等主要模块尚未完成。").foregroundStyle(.secondary) }.id("status")
        }
    }
}
