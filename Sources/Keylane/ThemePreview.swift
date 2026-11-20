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
        .init(id: "primary", title: "Primary Text", symbol: "checkmark.circle", role: .text, detail: "", subtitle: "Secondary Text"),
        .init(id: "secondary", title: "Primary Text", symbol: "checkmark.circle", role: .text, detail: "", subtitle: "Secondary Text")
    ]
    static let gridNames = ["Paper Slice", "Gelato", "Corals", "Summer Dress", "Flower"]
    @Published var selectedGrid = 0
    @Published var formText = ""
    @Published var formTextArea = ""
    @Published var formChoice = "Apple"
    @Published var query = ""
    @Published private(set) var selectedID = rows[0].id
    @Published private(set) var menu: Menu?
    @Published var menuQuery = ""
    @Published var menuSelection: String?
    @Published private(set) var focusToken = 0
    @Published private(set) var interacted = false
    @Published private(set) var favorites: Set<String> = []
    @Published var feedback: LauncherFooterFeedback?
    @Published private(set) var submenu: [LauncherAction]?
    var selected: Row { Self.rows.first { $0.id == selectedID } ?? Self.rows[0] }
    var primaryTitle: String { "Open Command" }
    var menuTitle: String { menu == .application ? "Theme Studio Preview" : selected.title }
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
            submenu = [.init(id: "back", title: "Back", icon: "chevron.left") { [weak self] in self?.back() }] + child.items
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
        [action("configure-command", "Configure Command…", "gearshape", shortcut: .init(",", modifiers: [.shift, .command])),
         action("configure-extension", "Configure Extension", "gearshape", shortcut: .init(",", modifiers: [.option, .command]))]
    }
    private var resultActions: [LauncherAction] {
        var result = [action("open", primaryTitle, "return", shortcut: .init(.return, modifiers: []))]
        result.append(.init(id: "favorite", title: favorites.contains(selectedID) ? "Remove from Favorites" : "Add to Favorites", icon: "star", group: 1) { [weak self] in
            guard let self else { return }
            if !favorites.insert(selectedID).inserted { favorites.remove(selectedID) }
            notice(favorites.contains(selectedID) ? "已添加到收藏" : "已从收藏移除")
        })
        result.append(.init(id: "open-with", title: "Open With…", icon: "app",
                            submenu: .init(title: "Open With", items: [action("default", "Default Application", "app"), action("preview", "Preview", "eye")]), group: 1))
        result.append(action("copy", "Copy Name", "doc.on.doc", group: 1, shortcut: .init("c", modifiers: .command)))
        result.append(.init(id: "disabled", title: "Unavailable Action", icon: "lock", group: 2, enabled: false))
        result.append(.init(id: "remove", title: "Remove Item", icon: "trash", group: 2, destructive: true) { [weak self] in self?.notice("Remove Item") })
        return result
    }
}

/// One real-size Launcher screen, scaled as a whole. Only its sample data is fixed.
struct ThemePreview: View {
    let theme: ThemeDefinition
    var observeScroll: ((CGFloat) -> Void)?
    @StateObject private var state: ThemePreviewState
    @State private var formDropdownOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let height: CGFloat = 480
    init(theme: ThemeDefinition, state: ThemePreviewState = ThemePreviewState(), observeScroll: ((CGFloat) -> Void)? = nil) {
        self.theme = theme; self.observeScroll = observeScroll; _state = StateObject(wrappedValue: state)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("List", count: 2).padding(.top, 12).padding(.bottom, 8)
                    ForEach(Array(ThemePreviewState.rows.enumerated()), id: \.element.id) { index, row in sampleRow(row, index: index) }
                    section("Grid", count: 5).padding(.top, 22).padding(.bottom, 8)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(0..<5) { index in
                            Button { state.selectedGrid = index } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Image(nsImage: ThemePreviewArtwork.image(index)).resizable().aspectRatio(1, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(state.selectedGrid == index ? theme.color(.selection).swiftUI : .clear, lineWidth: 1.5))
                                    Text(ThemePreviewState.gridNames[index]).font(VisualStyle.rowText).lineLimit(1).padding(.top, 8)
                                    Text("512 × 512").font(VisualStyle.rowText).foregroundStyle(.secondary).padding(.top, 2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 8)
                    section("Form", count: 4).padding(.top, 30).padding(.bottom, 24)
                    form
                    Divider().padding(.vertical, 28)
                    ThemePreviewMarkdown()
                        .padding(.horizontal, 8).padding(.bottom, 28)
                }.padding(.horizontal, 8)
            }.launcherScrollInsets().launcherScrollEdgeFade()
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in observeScroll?(offset) }
            HStack(spacing: 10) {
                Button { state.query = ""; state.closeMenu() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 19, weight: .medium)).foregroundStyle(.secondary).frame(width: 26, height: 36)
                }.buttonStyle(.plain).accessibilityLabel("Back")
                SearchField(text: $state.query, placeholder: "Search bar placeholder…", focusToken: state.focusToken,
                            wantsFocus: state.interacted && state.menu == nil, submit: state.submit, move: state.move, escape: state.back).frame(height: 30)
            }.padding(.horizontal, 14).frame(height: VisualStyle.launcherTopInset)
                .background {
                    ThemeBackgroundView(theme: theme).mask {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    }
                }
            if state.menu != nil { Color.clear.contentShape(Rectangle()).onTapGesture(perform: state.closeMenu) }
            HStack(alignment: .bottom) {
                corner(application: true)
                Spacer(minLength: 24)
                corner(application: false)
            }.padding(VisualStyle.launcherEdgeInset).frame(maxHeight: .infinity, alignment: .bottom)
        }
        .background { ThemeBackgroundView(theme: theme) }
        .overlay(alignment: .top) { WindowLoadingIndicator(loading: state.$feedback.map { $0 != nil }.eraseToAnyPublisher()) }
        .clipShape(RoundedRectangle(cornerRadius: VisualStyle.launcherCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: VisualStyle.launcherCornerRadius).stroke(.primary.opacity(0.15)))
        .onKeyPress(phases: .down) { key in
            guard !SearchField.isComposing, key.modifiers == .command, key.characters.lowercased() == "k" else { return .ignored }
            state.toggle(.actions); return .handled
        }
    }
    private func section(_ title: String, count: Int) -> some View {
        HStack(spacing: 12) { Text(title); Text("\(count) items").foregroundStyle(.tertiary) }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 8)
    }
    private func sampleRow(_ row: ThemePreviewState.Row, index: Int) -> some View {
        Button { state.select(row.id) } label: {
            ResultListRow(selected: state.selectedID == row.id, height: 36) {
                Image(systemName: "checkmark.circle").font(.system(size: 20, weight: .medium))
            } content: {
                HStack(spacing: 12) {
                    Text(row.title).font(VisualStyle.rowText).fixedSize()
                    Text(row.subtitle).font(VisualStyle.rowText).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 4)
                    if index == 0 {
                        supportIcon("tag", .red); supportIcon("airplane", .orange); supportIcon("calendar", .blue)
                        tag("Red", .red); tag("Orange", .orange); tag("Blue", .blue)
                    } else {
                        supportIcon("checkmark.circle", .green); supportIcon("crown", .yellow); supportIcon("clock", .purple); supportIcon("touchid", .magenta)
                        tag("Green", .green); tag("Yellow", .yellow); tag("Purple", .purple); tag("Magenta", .magenta)
                    }
                }
            }
        }.buttonStyle(.plain).id(row.id)
    }
    private func supportIcon(_ symbol: String, _ role: ThemeColorRole) -> some View {
        Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(ThemeColorStyle(role: role)).frame(width: 17)
    }
    private func tag(_ title: String, _ role: ThemeColorRole) -> some View {
        Text(title).font(VisualStyle.rowText).foregroundStyle(ThemeColorStyle(role: role))
            .padding(.horizontal, 10).frame(height: 25).background(theme.color(role).swiftUI.opacity(0.18), in: RoundedRectangle(cornerRadius: 8)).fixedSize()
    }
    private var form: some View {
        VStack(spacing: 24) {
            formRow("Dropdown") {
                Button { formDropdownOpen.toggle() } label: {
                    HStack { Text(state.formChoice); Spacer(); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                        .padding(.horizontal, 12).frame(height: 34).contentShape(Rectangle())
                        .modifier(ThemePreviewFieldSurface())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Dropdown: " + state.formChoice)
                    .popover(isPresented: $formDropdownOpen, arrowEdge: .bottom) {
                        VStack(spacing: 4) {
                            ForEach(["Apple", "Orange", "Banana"], id: \.self) { option in
                                Button { state.formChoice = option; formDropdownOpen = false } label: {
                                    HStack { Text(option); Spacer(); Image(systemName: "checkmark").opacity(state.formChoice == option ? 1 : 0) }
                                        .padding(8).frame(width: 180).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(8).foregroundStyle(ThemeColorStyle.text)
                            .environment(\.keylaneTheme, theme)
                    }
            }
            Divider().padding(.vertical, 0)
            formRow("Text Field") {
                TextField("Placeholder", text: $state.formText, prompt: Text("Placeholder").foregroundStyle(.tertiary)).textFieldStyle(.plain)
                    .padding(.horizontal, 12).frame(height: 34).modifier(ThemePreviewFieldSurface())
            }
            formRow("Text Area") {
                ZStack(alignment: .topLeading) {
                    if state.formTextArea.isEmpty { Text("Write something…").foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 10).allowsHitTesting(false) }
                    TextEditor(text: $state.formTextArea).font(VisualStyle.rowText).scrollContentBackground(.hidden)
                        .padding(.horizontal, 8).padding(.vertical, 6).accessibilityLabel("Text Area")
                }.frame(height: 82).modifier(ThemePreviewFieldSurface())
            }
            formRow("") {
                Button { state.notice("Button") } label: {
                    Text("Button").frame(maxWidth: .infinity).frame(height: 34)
                        .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }.font(VisualStyle.rowText).padding(.horizontal, 8)
    }
    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 160, height: 34, alignment: .trailing)
            content().frame(width: 365, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
    private func corner(application: Bool) -> some View {
        let open = state.menu == (application ? .application : .actions)
        let bar = LauncherFooterActionBar(title: state.primaryTitle, keys: ["↩"], enabled: true, showsActions: true, actionsTitle: "Actions",
                                         perform: state.submit, showActions: { state.toggle(.actions) })
        let width = open ? LauncherActionListPanel.width : application
            ? state.feedback.map { LauncherFooterFeedbackLabel.width(for: $0.label) } ?? SecondaryPageBadge.width(for: "Theme Studio Preview") : bar.width
        return ZStack(alignment: application ? .bottomLeading : .bottomTrailing) {
            if open {
                LauncherActionListPanel(title: state.menuTitle, items: state.items, selectedID: state.selectedAction?.id,
                    query: Binding(get: { state.menuQuery }, set: { state.menuQuery = $0; state.menuSelection = nil }),
                    focusToken: state.focusToken, wantsFocus: true, navigation: "arrows", activate: state.activate,
                    highlight: { state.menuSelection = $0 }, submit: state.submit, move: state.move, escape: state.back,
                    forward: { if state.selectedAction?.submenu != nil, let id = state.selectedAction?.id { state.activate(id) } },
                    reconcile: { state.menuSelection = LauncherActionSelection.reconcile(state.menuSelection, enabledIDs: $0) })
            } else if application {
                NativeHoverButton(title: "Theme Studio Preview", action: { state.toggle(.application) }) {
                    if let feedback = state.feedback { LauncherFooterFeedbackLabel(feedback: feedback) }
                    else { SecondaryPageBadge(title: "Theme Studio Preview", symbol: "paintpalette", artwork: ThemePreviewArtwork.badge) }
                }
            } else { bar }
        }
        .frame(width: width, height: open ? LauncherActionListPanel.rowsHeight(state.items) + 87 : VisualStyle.launcherControlDiameter,
               alignment: application ? .bottomLeading : .bottomTrailing)
        .modifier(LauncherMenuSurface(open: open))
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: open)
    }
}
