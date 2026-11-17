import SwiftUI
import KeylaneCore

struct WindowLayoutEditor: View {
    static let symbols = ["square.grid.2x2", "rectangle.split.2x1", "rectangle.split.1x2",
                          "rectangle.split.2x2", "rectangle.on.rectangle", "macwindow", "display"]

    @State var draft: CustomWindowAction
    let editing: Bool
    @ObservedObject var applications: ApplicationSettingsCatalog
    @ObservedObject var quicklinks: QuicklinksController
    @ObservedObject var preferences: WindowManagementPreferences
    let capture: (@escaping ([WindowLayoutEntry]) -> Void) -> Void
    let choosePath: (Bool, @escaping (String) -> Void) -> Void
    let save: (CustomWindowAction) -> Bool
    let cancel: () -> Void

    @State private var selected: UUID?
    @State private var screenIndex = 0
    @State private var apps: [ApplicationChoice] = []
    @State private var displays = [Display]()
    @State private var adding = false
    @State private var appQuery = ""
    @State private var measurementText: [Field: String] = [:]
    @State private var invalidMeasurements: Set<Field> = []
    @State private var message: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, width, height, x, y }
    private var windows: [WindowLayoutEntry] { draft.windows ?? [] }
    private var selectedEntry: WindowLayoutEntry? { windows.first { $0.id == selected } }
    private var canAddWindow: Bool {
        windows.count < 64 && windows.filter { $0.display == screenIndex }.count < 8
    }
    var windowTitle: String { editing ? "编辑窗口布局" : "新建窗口布局" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                previewPane
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) { inspector }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 300)
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
        .onAppear {
            refreshDisplays()
            choose(windows.first)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshDisplays()
        }
        .onChange(of: preferences.respectStageManager) { _, _ in refreshDisplays() }
        .onChange(of: focus) { old, _ in
            if let old { measurementText[old] = nil; invalidMeasurements.remove(old) }
        }
        .task(id: applications.items) {
            let items = applications.items
            apps = await Task.detached {
                var seen = Set<String>()
                return items.compactMap { item -> ApplicationChoice? in
                    guard let id = Bundle(url: item.url)?.bundleIdentifier, seen.insert(id).inserted else { return nil }
                    return ApplicationChoice(id: id, name: item.title, path: item.url.path)
                }
            }.value
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(windowTitle).font(.headline).accessibilityAddTraits(.isHeader)
            GeometryReader { proxy in
                if let display = displays[safe: screenIndex] {
                    displayPreview(display, available: proxy.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack(spacing: 6) {
                if let display = displays[safe: screenIndex] {
                    Text("\(display.name) · \(display.resolution)").font(.caption)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                ForEach(displays.indices, id: \.self) { index in
                    Button {
                        screenIndex = index
                        choose(windows.first { $0.display == index })
                    } label: {
                        Text("\(index + 1)").monospacedDigit()
                            .frame(width: 27, height: 27)
                            .background(.primary.opacity(index == screenIndex ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7).strokeBorder(
                                    index == screenIndex ? Color.accentColor : Color.primary.opacity(0.15))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(displays[index].name)
                    .accessibilityAddTraits(index == screenIndex ? .isSelected : [])
                }
            }
        }
        .padding(20)
        .frame(minWidth: 285)
    }

    private func displayPreview(_ display: Display, available: CGSize) -> some View {
        let frame = display.usableFrame
        let scale = max(0, min(available.width / max(1, frame.width), available.height / max(1, frame.height)))
        let shape = RoundedRectangle(cornerRadius: 7)
        let entries = windows.filter { $0.display == screenIndex }
        return ZStack(alignment: .topLeading) {
            shape.fill(.secondary.opacity(0.28))
            shape.strokeBorder(.primary.opacity(0.24))
            if entries.isEmpty {
                Text("从右侧添加应用程序").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(entries) { entry in
                if let proposed = draft.displayFrame(for: entry, in: frame, windowGap: CGFloat(preferences.windowGap),
                                                     screenGap: CGFloat(preferences.screenGap)) {
                    let visible = proposed.intersection(frame)
                    if !visible.isNull && !visible.isEmpty {
                        previewTile(entry, size: CGSize(width: visible.width * scale, height: visible.height * scale))
                            .offset(x: (visible.minX - frame.minX) * scale, y: (visible.minY - frame.minY) * scale)
                            .zIndex(entry.id == selected ? 2 : entry.id == draft.frontWindowID ? 1 : 0)
                    }
                }
            }
        }
        .frame(width: frame.width * scale, height: frame.height * scale)
        .clipShape(shape)
        .accessibilityLabel("\(display.name)上的窗口布局预览")
    }

    private func previewTile(_ entry: WindowLayoutEntry, size: CGSize) -> some View {
        let isSelected = entry.id == selected
        let shape = RoundedRectangle(cornerRadius: 6)
        return Button { choose(entry) } label: {
            ZStack {
                shape.fill(isSelected ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.15))
                shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.27), lineWidth: isSelected ? 2 : 1)
                if size.width >= 20, size.height >= 20 {
                    appIcon(entry.bundleID).frame(width: min(24, size.width - 6), height: min(24, size.height - 6))
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appName(entry.bundleID))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var inspector: some View {
        section("名称") {
            LauncherCreationControl(focused: focus == .name) {
                HStack(spacing: 8) {
                    TextField("布局名称", text: $draft.name).textFieldStyle(.plain).focused($focus, equals: .name)
                    Divider().frame(height: 14)
                    Menu {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button {
                                draft.icon = symbol
                            } label: { Label(Self.symbolTitle(symbol), systemImage: symbol) }
                        }
                    } label: { Image(systemName: draft.displaySymbol) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("布局图标")
                }
            }
        }

        SettingsRow("使用偏好间距", detail: "按窗口管理设置为窗口之间和屏幕边缘留出间距。") {
            Toggle("使用偏好间距", isOn: Binding(get: { draft.usesPreferredGaps == true }, set: { draft.usesPreferredGaps = $0 }))
                .labelsHidden().toggleStyle(.switch)
        }
        Divider()
        section("布局") { layoutSelector }
        if let entry = selectedEntry {
            let binding = entryBinding(entry)
            section("参数") { argumentEditor(binding) }
            SettingsRow("置于最前", detail: "布局完成后聚焦此窗口。") {
                Toggle("置于最前", isOn: Binding(get: { draft.frontWindowID == entry.id }, set: {
                    if $0 { draft.frontWindowID = entry.id }
                    else if draft.frontWindowID == entry.id { draft.frontWindowID = nil }
                }))
                .labelsHidden().toggleStyle(.switch)
            }
            Divider()
            section("大小") {
                HStack(spacing: 8) {
                    measurement("宽", value: binding.geometry.width, field: .width)
                    measurement("高", value: binding.geometry.height, field: .height)
                }
            }
            section("偏移") {
                HStack(spacing: 8) {
                    measurement("X", value: binding.geometry.x, field: .x)
                    measurement("Y", value: binding.geometry.y, field: .y)
                }
            }
            section("位置") { positionGrid(binding.geometry.anchor) }
        }
        Divider()
        DisclosureGroup("更多选项") {
            VStack(alignment: .leading, spacing: 12) {
                if let entry = selectedEntry {
                    let binding = entryBinding(entry)
                    Picker("显示器", selection: binding.display) {
                        ForEach(displays.indices, id: \.self) { index in
                            Text(displays[index].name).tag(index)
                                .disabled(index != entry.display && windows.filter { $0.display == index }.count >= 8)
                        }
                        if !displays.indices.contains(entry.display) {
                            Text("显示器 \(entry.display + 1)（未连接）").tag(entry.display)
                        }
                    }
                    TextField("匹配窗口标题", text: binding.windowTitle)
                        .help("留空时匹配该应用的可用窗口。")
                }
                Picker("其他窗口", selection: $draft.otherWindows) {
                    Text("保留").tag(CustomWindowAction.OtherWindows.keep)
                    Text("最小化").tag(CustomWindowAction.OtherWindows.minimize)
                    Text("关闭").tag(CustomWindowAction.OtherWindows.close)
                }
                Button("添加可见窗口") { capture(appendVisible) }
            }
            .padding(.top, 8)
        }
        if let message { Text(message).foregroundStyle(.red).font(.callout) }
    }

    private var layoutSelector: some View {
        HStack(spacing: 8) {
            Button("添加应用程序", systemImage: "plus") {
                appQuery = ""
                adding = true
            }
            .labelStyle(.iconOnly).buttonStyle(.bordered)
            .disabled(!canAddWindow || displays.isEmpty)
            .help(canAddWindow ? "为当前显示器添加窗口" : "每台显示器最多八个窗口")
            .popover(isPresented: $adding, arrowEdge: .bottom) { applicationMenu }
            Menu {
                let indices = Set(windows.map(\.display)).sorted()
                ForEach(indices, id: \.self) { index in
                    Section(displays[safe: index]?.name ?? "显示器 \(index + 1)") {
                        ForEach(windows.filter { $0.display == index }) { entry in
                            Button {
                                choose(entry)
                            } label: {
                                Label(appName(entry.bundleID), systemImage: entry.id == selected ? "checkmark" : "macwindow")
                            }
                        }
                    }
                }
                if let selected {
                    Divider()
                    Button("移除此条目", role: .destructive) { remove(selected) }
                }
            } label: {
                HStack(spacing: 7) {
                    if let entry = selectedEntry {
                        appIcon(entry.bundleID).frame(width: 19, height: 19)
                        Text(appName(entry.bundleID)).lineLimit(1)
                    } else { Text("选择窗口") }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(windows.isEmpty)
            .accessibilityLabel("选择要编辑的窗口")
        }
    }

    private var applicationMenu: some View {
        VStack(spacing: 0) {
            TextField("搜索应用程序…", text: $appQuery).textFieldStyle(.roundedBorder).padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let query = appQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    let matches = query.isEmpty ? apps : apps.filter { $0.name.localizedStandardContains(query) }
                    if matches.isEmpty { Text("没有匹配的应用程序").foregroundStyle(.secondary).padding(10) }
                    ForEach(matches) { app in
                        Button { add(app) } label: {
                            HStack(spacing: 8) {
                                WorkspaceItemIcon(path: app.path).frame(width: 20, height: 20)
                                Text(app.name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            .frame(height: 230)
        }
        .frame(width: 255)
    }

    @ViewBuilder private func argumentEditor(_ binding: Binding<WindowLayoutEntry>) -> some View {
        Menu {
            Button("无") { binding.wrappedValue.argument = .none }
            Button("选取文件…") { pickPath(for: binding.wrappedValue.id, folder: false) }
            Button("选取文件夹…") { pickPath(for: binding.wrappedValue.id, folder: true) }
            Button("输入 URL…") { binding.wrappedValue.argument = .url("") }
            Button("输入命令行参数…") { binding.wrappedValue.argument = .arguments("") }
            if !quicklinks.links.isEmpty {
                Section("快捷链接") {
                    ForEach(quicklinks.links) { link in
                        Button(link.title) { binding.wrappedValue.argument = .quicklink(link.id) }
                    }
                }
            }
        } label: {
            Text(argumentMenuTitle(binding.wrappedValue.argument)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("参数类型")
        switch binding.wrappedValue.argument {
        case .url:
            argumentField("URL", argument: binding.argument, wrap: { .url($0) })
        case .arguments:
            argumentField("命令行参数", argument: binding.argument, wrap: { .arguments($0) })
        default:
            EmptyView()
        }
    }

    private func argumentField(_ title: String, argument: Binding<WindowLayoutEntry.Argument>,
                               wrap: @escaping (String) -> WindowLayoutEntry.Argument) -> some View {
        LauncherCreationControl {
            TextField(title, text: Binding(get: { argumentLabel(argument.wrappedValue) }, set: { argument.wrappedValue = wrap($0) }))
                .textFieldStyle(.plain)
        }
    }

    private func measurement(_ title: String, value: Binding<WindowGeometry.Measurement>, field: Field) -> some View {
        LauncherCreationControl(focused: focus == field) {
            HStack(spacing: 5) {
                Text(title).foregroundStyle(.secondary)
                TextField(title, text: Binding(
                    get: { measurementText[field] ?? value.wrappedValue.value.formatted(.number.grouping(.never)) },
                    set: { text in
                        measurementText[field] = text
                        let normalized = text.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
                        if let number = Double(normalized), number.isFinite {
                            value.wrappedValue.value = number
                            invalidMeasurements.remove(field)
                        } else {
                            invalidMeasurements.insert(field)
                        }
                    }
                ))
                .textFieldStyle(.plain).focused($focus, equals: field)
                Divider().frame(height: 14)
                Menu {
                    Button("%") { value.wrappedValue.percentage = true }
                    Button("pt") { value.wrappedValue.percentage = false }
                } label: { Text(value.wrappedValue.percentage ? "%" : "pt").font(.caption).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("\(title)的单位")
            }
        }
    }

    private func positionGrid(_ selection: Binding<WindowGeometry.Anchor>) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 4) {
            ForEach(WindowGeometry.Anchor.allCases, id: \.self) { anchor in
                let isSelected = selection.wrappedValue == anchor
                Button { selection.wrappedValue = anchor } label: {
                    WindowAnchorImage(anchor: anchor)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(.primary.opacity(isSelected ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(anchor.localizedTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("取消", action: cancel).buttonStyle(.glass).keyboardShortcut(.cancelAction)
            Button {
                if !save(draft) { message = "无法保存布局。请检查名称和窗口设置。" }
            } label: {
                HStack(spacing: 6) {
                    Text("保存")
                    Keycaps(keys: ["⌘", "↩"])
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!draft.isValid || !invalidMeasurements.isEmpty)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func choose(_ entry: WindowLayoutEntry?) {
        if selected != entry?.id {
            measurementText = [:]
            invalidMeasurements.removeAll()
        }
        selected = entry?.id
        if let entry, displays.indices.contains(entry.display) { screenIndex = entry.display }
    }

    private func add(_ app: ApplicationChoice) {
        guard canAddWindow else { return }
        var entry = WindowLayoutEntry(bundleID: app.id)
        entry.display = screenIndex
        entry.geometry.x.percentage = false
        entry.geometry.y.percentage = false
        if windows.filter({ $0.display == screenIndex }).count == 1 {
            entry.geometry.anchor = .topRight
        }
        draft.windows?.append(entry)
        choose(entry)
        adding = false
    }

    private func remove(_ id: UUID) {
        draft.windows?.removeAll { $0.id == id }
        if draft.frontWindowID == id { draft.frontWindowID = nil }
        choose(windows.first { $0.display == screenIndex } ?? windows.first)
    }

    private func appendVisible(_ entries: [WindowLayoutEntry]) {
        var combined = windows
        for entry in entries where combined.count < 64 {
            guard combined.filter({ $0.display == entry.display }).count < 8,
                  !combined.contains(where: { $0.bundleID == entry.bundleID && $0.windowTitle == entry.windowTitle &&
                      $0.display == entry.display && $0.geometry == entry.geometry }) else { continue }
            combined.append(entry)
        }
        guard combined.count > windows.count else {
            message = "没有可添加的窗口。"
            return
        }
        message = nil
        draft.windows = combined
        if selected == nil { choose(combined.first) }
    }

    private func entryBinding(_ entry: WindowLayoutEntry) -> Binding<WindowLayoutEntry> {
        Binding(get: { windows.first { $0.id == entry.id } ?? entry }, set: { newValue in
            guard let index = windows.firstIndex(where: { $0.id == entry.id }) else { return }
            draft.windows?[index] = newValue
            if displays.indices.contains(newValue.display) { screenIndex = newValue.display }
        })
    }

    private func pickPath(for entryID: UUID, folder: Bool) {
        choosePath(folder) { path in
            guard let index = windows.firstIndex(where: { $0.id == entryID }) else { return }
            draft.windows?[index].argument = .file(path)
        }
    }

    private func refreshDisplays() {
        let usable = SystemNavigation.displayFrames(respectingStageManager: preferences.respectStageManager)
        displays = zip(NSScreen.screens, usable).map { screen, area in
            Display(name: screen.localizedName, resolution: "\(Int(screen.frame.width)) × \(Int(screen.frame.height))", usableFrame: area)
        }
        if !displays.indices.contains(screenIndex) { screenIndex = 0 }
    }

    private func argumentMenuTitle(_ argument: WindowLayoutEntry.Argument) -> String {
        switch argument {
        case .url(let url) where url.isEmpty: "URL"
        case .arguments(let text) where text.isEmpty: "命令行参数"
        default: argumentLabel(argument)
        }
    }

    private func argumentLabel(_ argument: WindowLayoutEntry.Argument) -> String {
        switch argument {
        case .none: "无"
        case .file(let path): URL(fileURLWithPath: path).lastPathComponent
        case .url(let raw): raw
        case .arguments(let raw): raw
        case .quicklink(let id): quicklinks.links.first { $0.id == id }?.title ?? "快捷链接已移除"
        }
    }

    private func appName(_ id: String) -> String {
        apps.first { $0.id == id }?.name ?? id
    }

    private func appIcon(_ id: String) -> some View {
        WorkspaceItemIcon(path: apps.first { $0.id == id }?.path ?? "", fallbackSymbol: "macwindow")
    }

    private static func symbolTitle(_ symbol: String) -> String {
        switch symbol {
        case "square.grid.2x2": "网格"
        case "rectangle.split.2x1": "左右分栏"
        case "rectangle.split.1x2": "上下分栏"
        case "rectangle.split.2x2": "四分屏"
        case "rectangle.on.rectangle": "重叠窗口"
        case "macwindow": "窗口"
        default: "显示器"
        }
    }

    private struct ApplicationChoice: Identifiable, Sendable {
        let id: String
        let name: String
        let path: String
    }

    private struct Display {
        let name: String
        let resolution: String
        let usableFrame: CGRect
    }
}

private struct WindowAnchorImage: View {
    let anchor: WindowGeometry.Anchor

    var body: some View {
        let factors = anchor.factors
        let width = factors.x == 0.5 && factors.y != 0.5 ? 20.0 : 10.0
        let height = factors.y == 0.5 && factors.x != 0.5 ? 12.0 : 6.0
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).strokeBorder(lineWidth: 1.5)
            RoundedRectangle(cornerRadius: 1).fill(.foreground.opacity(0.8))
                .frame(width: width, height: height)
                .offset(x: 2 + (22 - width) * factors.x, y: 2 + (14 - height) * factors.y)
        }
        .frame(width: 26, height: 18)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
