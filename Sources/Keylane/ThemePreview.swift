import Combine
import KeylaneCore
import SwiftUI

/// Isolated sample data and local interaction: no Model, services, pasteboard or app commands.
final class ThemePreviewState: ObservableObject {
    struct Row: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let role: ThemeColorRole
        let detail: String
        var subtitle = ""
        var alias = ""
        var enabled = true
    }
    enum Menu { case application, actions }
    static let rows: [Row] = [
        .init(id: "calendar", title: "日历", symbol: "calendar", role: .red, detail: "应用程序", subtitle: "正在运行"),
        .init(id: "clipboard", title: "剪贴板历史", symbol: "list.clipboard", role: .orange, detail: "命令"),
        .init(id: "link", title: "项目主页", symbol: "link", role: .blue, detail: "快捷链接", alias: "home"),
        .init(id: "document", title: "项目说明.md", symbol: "doc.text", role: .yellow, detail: "文件", subtitle: "文稿 / 项目"),
        .init(id: "ai", title: "改进写作", symbol: "sparkles", role: .purple, detail: "AI 命令"),
        .init(id: "snippet", title: "邮件签名", symbol: "text.alignleft", role: .green, detail: "文字片段", alias: "!sig"),
        .init(id: "timer", title: "开始专注", symbol: "timer", role: .magenta, detail: "命令"),
        .init(id: "unavailable", title: "暂不可用的命令", symbol: "exclamationmark.triangle", role: .red, detail: "不可用", enabled: false)
    ]
    @Published var query = ""
    @Published private(set) var selectedID = rows[0].id
    @Published private(set) var menu: Menu?
    @Published var menuQuery = ""
    @Published var menuSelection: String?
    @Published private(set) var focusToken = 0
    @Published private(set) var interacted = false
    @Published private(set) var favorites: Set<String> = ["clipboard"]
    @Published var feedback: LauncherFooterFeedback?
    @Published private(set) var submenu: [LauncherAction]?
    var selected: Row { Self.rows.first { $0.id == selectedID } ?? Self.rows[0] }
    var primaryTitle: String {
        switch selectedID {
        case "calendar": "打开应用"
        case "document": "打开文件"
        case "link": "打开链接"
        case "snippet": "粘贴文字片段"
        default: "执行命令"
        }
    }
    var menuTitle: String { menu == .application ? "Keylane" : selected.title }
    var items: [LauncherAction] {
        let values = submenu ?? (menu == .application ? applicationActions : resultActions)
        return values.filter { menuQuery.isEmpty || $0.title.localizedStandardContains(menuQuery) }
    }
    var selectedAction: LauncherAction? { items.first { $0.id == menuSelection && $0.enabled } ?? items.first(where: \.enabled) }
    func select(_ id: String) {
        guard Self.rows.contains(where: { $0.id == id && $0.enabled }) else { return }
        selectedID = id; closeMenu()
    }
    func toggle(_ target: Menu) {
        if menu == target { closeMenu(); return }
        feedback = nil; menu = target; submenu = nil; menuQuery = ""; menuSelection = nil
        interacted = true; focusToken += 1
    }
    func closeMenu() {
        menu = nil; submenu = nil; menuQuery = ""; menuSelection = nil
        interacted = true; focusToken += 1
    }
    func move(_ delta: Int) {
        if menu != nil {
            let enabled = items.filter(\.enabled)
            guard !enabled.isEmpty else { return }
            let index = enabled.firstIndex { $0.id == selectedAction?.id } ?? 0
            menuSelection = enabled[min(enabled.count - 1, max(0, index + delta))].id
        } else {
            let enabled = Self.rows.filter(\.enabled)
            let index = enabled.firstIndex { $0.id == selectedID } ?? 0
            select(enabled[min(enabled.count - 1, max(0, index + delta))].id)
        }
    }
    func submit() {
        if menu != nil { if let action = selectedAction { activate(action.id) } }
        else { notice("\(primaryTitle)：\(selected.title)") }
    }
    func activate(_ id: String) {
        guard let action = items.first(where: { $0.id == id }), action.enabled else { return }
        if let child = action.submenu {
            submenu = [.init(id: "back", title: "返回", icon: "chevron.left") { [weak self] in self?.back() }] + child.items
            menuQuery = ""; menuSelection = nil; focusToken += 1
        } else if id == "back" { back() }
        else { closeMenu(); action.perform() }
    }
    func back() {
        if submenu != nil { submenu = nil; menuQuery = ""; menuSelection = nil; focusToken += 1 }
        else { closeMenu() }
    }
    func notice(_ text: String) { closeMenu(); feedback = .init(message: text, style: .success) }
    private func action(_ id: String, _ title: String, _ icon: String, group: Int = 0, shortcut: KeyboardShortcut? = nil) -> LauncherAction {
        .init(id: id, title: title, icon: icon, shortcut: shortcut, group: group) { [weak self] in self?.notice(title) }
    }
    private var applicationActions: [LauncherAction] {
        [action("about", "关于 Keylane", "app.badge"),
         action("settings", "设置…", "gearshape", shortcut: .init(",", modifiers: .command)),
         action("clipboard", "剪贴板历史", "list.clipboard"),
         action("hide", "隐藏 Keylane", "rectangle.compress.vertical", shortcut: .init(.escape, modifiers: [])),
         action("quit", "退出 Keylane", "rectangle.portrait.and.arrow.right")]
    }
    private var resultActions: [LauncherAction] {
        var result = [action("open", primaryTitle, "return", shortcut: .init(.return, modifiers: []))]
        result.append(.init(id: "favorite", title: favorites.contains(selectedID) ? "从收藏移除" : "添加到收藏", icon: "star", group: 1) { [weak self] in
            guard let self else { return }
            if !favorites.insert(selectedID).inserted { favorites.remove(selectedID) }
            notice(favorites.contains(selectedID) ? "已添加到收藏" : "已从收藏移除")
        })
        result.append(.init(id: "open-with", title: "打开方式…", icon: "app",
                            submenu: .init(title: "打开方式", items: [action("default", "默认应用", "app"), action("preview", "预览", "eye")]), group: 1))
        result.append(action("copy", "复制名称", "doc.on.doc", group: 1, shortcut: .init("c", modifiers: .command)))
        result.append(.init(id: "disabled", title: "暂不可用的操作", icon: "lock", group: 2, enabled: false))
        result.append(.init(id: "remove", title: "移除记录", icon: "trash", group: 2, destructive: true) { [weak self] in self?.notice("移除记录") })
        return result
    }
}

/// One real-size Launcher screen, scaled as a whole. Only its sample data is fixed.
struct ThemePreview: View {
    let theme: ThemeDefinition
    @StateObject private var state: ThemePreviewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let height: CGFloat = 470
    init(theme: ThemeDefinition, state: ThemePreviewState = ThemePreviewState()) {
        self.theme = theme; _state = StateObject(wrappedValue: state)
    }
    var body: some View {
        GeometryReader { geometry in
            screen.frame(width: VisualStyle.launcherWidth, height: Self.height)
                .scaleEffect(geometry.size.width / VisualStyle.launcherWidth, anchor: .topLeading)
        }
        .aspectRatio(VisualStyle.launcherWidth / Self.height, contentMode: .fit)
        .environment(\.keylaneTheme, theme)
        .foregroundStyle(theme.color(.text).swiftUI)
        .tint(theme.color(.selection).swiftUI)
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
        .task(id: state.feedback) {
            guard state.feedback != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            state.feedback = nil
        }
    }
    private var screen: some View {
        ZStack(alignment: .top) {
            SelectableResultList(selection: state.selectedID, firstResult: ThemePreviewState.rows.first?.id) {
                ResultListSection(title: "常用", isFirst: true) {
                    ForEach(Array(ThemePreviewState.rows.prefix(3))) { row in result(row) }
                }
                ResultListSection(title: "结果") {
                    ForEach(Array(ThemePreviewState.rows.dropFirst(3))) { row in result(row) }
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 19)).foregroundStyle(.secondary)
                SearchField(text: $state.query, placeholder: "搜索应用、文件和命令…", focusToken: state.focusToken,
                            wantsFocus: state.interacted && state.menu == nil, submit: state.submit, move: state.move, escape: state.back)
                    .frame(height: 30)
                Button { state.notice("询问 Quick AI") } label: {
                    HStack(spacing: 6) { Text("Quick AI"); Keycap(text: "⇥") }.font(.system(size: 13)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).fixedSize()
            }.padding(.horizontal, 19).frame(height: VisualStyle.launcherTopInset)
            if state.menu != nil { Color.clear.contentShape(Rectangle()).onTapGesture(perform: state.closeMenu) }
            HStack(alignment: .bottom) {
                corner(application: true)
                Spacer(minLength: 24)
                corner(application: false)
            }.padding(VisualStyle.launcherEdgeInset).frame(maxHeight: .infinity, alignment: .bottom)
        }
        .background { ThemeBackgroundView(theme: theme) }
        .overlay(alignment: .top) {
            WindowLoadingIndicator(loading: state.$feedback.map { $0 != nil }.eraseToAnyPublisher())
        }
        .clipShape(RoundedRectangle(cornerRadius: VisualStyle.launcherCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: VisualStyle.launcherCornerRadius).stroke(.primary.opacity(0.15)))
        .onKeyPress(phases: .down) { key in
            guard !SearchField.isComposing, key.modifiers == .command, key.characters.lowercased() == "k" else { return .ignored }
            state.toggle(.actions); return .handled
        }
    }
    private func result(_ row: ThemePreviewState.Row) -> some View {
        ResultListButton(id: row.id, disabled: !row.enabled, action: { state.select(row.id) }) {
            ResultListRow(selected: state.selectedID == row.id, layout: .root) {
                Group {
                    if row.id == "calendar" {
                        WorkspaceItemIcon(path: "/System/Applications/Calendar.app", fallbackSymbol: "calendar").scaleEffect(1.2)
                    } else {
                        Image(systemName: row.symbol).font(.system(size: 21)).foregroundStyle(ThemeColorStyle(role: row.role))
                    }
                }
                    .overlay(alignment: .bottom) {
                        if row.id == "calendar" { Circle().fill(.primary.opacity(0.78)).frame(width: 4, height: 4).offset(y: 6) }
                    }
            } content: {
                HStack(spacing: ResultListRowLayout.root.horizontalInset) {
                    Text(row.title).font(VisualStyle.rowText).lineLimit(1)
                    if !row.subtitle.isEmpty { Text(row.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    if !row.alias.isEmpty { Text(row.alias).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: RoundedRectangle(cornerRadius: 4)) }
                    Spacer(minLength: 8)
                    if state.favorites.contains(row.id) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary) }
                    Text(row.detail).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.opacity(row.enabled ? 1 : 0.45)
        }
    }
    private func corner(application: Bool) -> some View {
        let open = state.menu == (application ? .application : .actions)
        let bar = LauncherFooterActionBar(title: state.primaryTitle, keys: ["↩"], enabled: true, showsActions: true,
                                         perform: state.submit, showActions: { state.toggle(.actions) })
        let width = open ? LauncherActionMenuPanel.width : application
            ? state.feedback.map { LauncherFooterFeedbackLabel.width(for: $0.label) } ?? VisualStyle.launcherControlDiameter : bar.width
        return ZStack(alignment: application ? .bottomLeading : .bottomTrailing) {
            if open {
                LauncherActionMenuPanel(title: state.menuTitle, items: state.items, selectedID: state.selectedAction?.id,
                    query: Binding(get: { state.menuQuery }, set: { state.menuQuery = $0; state.menuSelection = nil }),
                    focusToken: state.focusToken, wantsFocus: true, navigation: "arrows", activate: state.activate,
                    highlight: { state.menuSelection = $0 }, submit: state.submit, move: state.move, escape: state.back,
                    forward: { if state.selectedAction?.submenu != nil, let id = state.selectedAction?.id { state.activate(id) } },
                    reconcile: { state.menuSelection = LauncherActionSelection.reconcile(state.menuSelection, enabledIDs: $0) })
            } else if application {
                NativeHoverButton(title: "Keylane 菜单", action: { state.toggle(.application) }) {
                    if let feedback = state.feedback { LauncherFooterFeedbackLabel(feedback: feedback) }
                    else { Image(systemName: "text.menu").font(.system(size: 16)).frame(width: 36, height: 36) }
                }
            } else { bar }
        }
        .frame(width: width, height: open ? LauncherActionMenuPanel.rowsHeight(state.items) + 87 : VisualStyle.launcherControlDiameter,
               alignment: application ? .bottomLeading : .bottomTrailing)
        .modifier(LauncherMenuSurface(open: open))
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: open)
    }
}
