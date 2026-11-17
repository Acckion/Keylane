import SwiftUI
import KeylaneCore

struct WindowLayoutEditor: View {
    static let symbols = ["square.grid.2x2", "rectangle.split.2x1", "rectangle.split.1x2",
                          "rectangle.split.2x2", "rectangle.on.rectangle", "macwindow", "display"]

    @Binding var draft: CustomWindowAction
    @Binding var hasInvalidMeasurements: Bool
    @ObservedObject var applications: ApplicationSettingsCatalog
    @ObservedObject var quicklinks: QuicklinksController
    @ObservedObject var preferences: WindowManagementPreferences
    let capture: (@escaping ([WindowLayoutEntry]) -> Void) -> Void
    let choosePath: (Bool, @escaping (String) -> Void) -> Void
    let back: () -> Void

    @State private var selected: UUID?
    @State private var screenIndex = 0
    @State private var apps: [ApplicationChoice] = []
    @State private var displays = [Display]()
    @State private var adding = false
    @State private var choosingWindow = false
    @State private var dragStart: WindowLayoutEntry?
    @GestureState private var isDragging = false
    @State private var appQuery = ""
    @State private var measurementText: [Field: String] = [:]
    @State private var invalidMeasurements: Set<Field> = []
    @State private var message: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, applicationSearch, width, height, x, y }
    private enum PreviewSpace: Hashable { case display }
    private var windows: [WindowLayoutEntry] { draft.windows ?? [] }
    private var selectedEntry: WindowLayoutEntry? { windows.first { $0.id == selected } }
    private var canAddWindow: Bool {
        windows.count < 64 && windows.filter { $0.display == screenIndex }.count < 8
    }

    var body: some View {
        HStack(spacing: 0) {
            previewPane
                .padding(.bottom, VisualStyle.launcherBottomInset)
            Divider().padding(.vertical, 10)
                .padding(.bottom, VisualStyle.launcherBottomInset)
            inspectorPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: invalidMeasurements.isEmpty) { _, empty in hasInvalidMeasurements = !empty }
        .onChange(of: isDragging) { _, dragging in
            if !dragging { dragStart = nil }
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

    private var inspectorPane: some View {
        let topFade: CGFloat = 18
        return ScrollView {
            VStack(alignment: .leading, spacing: 13) { inspector }
                .padding(16)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .launcherScrollInsets(top: false)
        .launcherScrollEdgeFade(top: topFade)
        .overlay(alignment: .top) {
            ChromeBlur()
                .frame(height: topFade)
                .mask(LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: 300)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                LauncherBackButton(action: back)
                nameControl
                    .frame(maxWidth: 182)
                layoutPicker
            }
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
        .padding(.top, VisualStyle.launcherEdgeInset)
        .padding(.horizontal, VisualStyle.launcherEdgeInset)
        .padding(.bottom, 12)
        .frame(minWidth: 285)
        .overlayPreferenceValue(LayoutPickerAnchor.self) { anchor in
            if let anchor {
                GeometryReader { geometry in
                    let trigger = geometry[anchor]
                    let width = min(244, geometry.size.width)
                    Group {
                        if adding { applicationMenu }
                        else { windowMenu }
                    }
                    .frame(width: width)
                    .modifier(LauncherMenuSurface(open: true))
                    .offset(x: max(0, trigger.maxX - width), y: trigger.maxY + 6)
                }
            }
        }
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
                Text("点按上方加号添加应用程序").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(entries) { entry in
                if let proposed = draft.displayFrame(for: entry, in: frame, windowGap: CGFloat(preferences.windowGap),
                                                     screenGap: CGFloat(preferences.screenGap)) {
                    let visible = proposed.intersection(frame)
                    if !visible.isNull && !visible.isEmpty {
                        previewTile(entry, size: CGSize(width: visible.width * scale, height: visible.height * scale),
                                    in: frame, scale: scale)
                            .offset(x: (visible.minX - frame.minX) * scale, y: (visible.minY - frame.minY) * scale)
                            .zIndex(entry.id == selected ? 2 : entry.id == draft.frontWindowID ? 1 : 0)
                    }
                }
            }
        }
        .frame(width: frame.width * scale, height: frame.height * scale)
        .coordinateSpace(.named(PreviewSpace.display))
        .accessibilityLabel("\(display.name)上的窗口布局预览")
    }

    private func previewTile(_ entry: WindowLayoutEntry, size: CGSize, in screen: CGRect, scale: CGFloat) -> some View {
        let isSelected = entry.id == selected
        let shape = RoundedRectangle(cornerRadius: 6)
        return Button { choose(entry) } label: {
            ZStack {
                shape.fill(isSelected ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.15))
                shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.27), lineWidth: isSelected ? 2 : 1)
                if size.width >= 20, size.height >= 20 {
                    let side = min(24, size.width - 6, size.height - 6)
                    appIcon(entry.bundleID).frame(width: side, height: side)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .highPriorityGesture(previewDrag(for: entry, in: screen, scale: scale))
        .overlay {
            if isSelected {
                let handles = isDragging || (size.width >= 30 && size.height >= 30)
                    ? WindowGeometry.Anchor.allCases.filter { $0 != .center }
                    : [.bottomRight]
                ForEach(handles, id: \.self) { handle in
                    let position = handle.factors
                    let isCorner = position.x != 0.5 && position.y != 0.5
                    let inset = min(isCorner ? 2.5 : 1, size.width / 2, size.height / 2)
                    Circle()
                        .fill(.white)
                        .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 1) }
                        .frame(width: 7, height: 7)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                        .gesture(previewDrag(for: entry, in: screen, scale: scale, handle: handle))
                        .position(x: inset + (size.width - 2 * inset) * position.x,
                                  y: inset + (size.height - 2 * inset) * position.y)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel(appName(entry.bundleID))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func previewDrag(for entry: WindowLayoutEntry, in screen: CGRect, scale: CGFloat,
                             handle: WindowGeometry.Anchor? = nil) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(PreviewSpace.display))
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { value in
                guard scale > 0, let index = windows.firstIndex(where: { $0.id == entry.id }) else { return }
                if dragStart?.id != entry.id {
                    dragStart = windows[index]
                    choose(entry)
                    focus = nil
                }
                guard let start = dragStart else { return }
                let translation = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                guard let geometry = draft.draggedGeometry(for: start, in: screen,
                    windowGap: CGFloat(preferences.windowGap), screenGap: CGFloat(preferences.screenGap),
                    translation: translation, resizingFrom: handle, minimumSize: 28 / scale
                ) else { return }
                var updated = windows[index]
                updated.geometry = geometry
                updated.positionPreset = nil
                if updated != windows[index] { draft.windows?[index] = updated }
            }
    }

    private var nameControl: some View {
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

    @ViewBuilder private var inspector: some View {
        SettingsRow("使用偏好间距", detail: "按窗口管理设置为窗口之间和屏幕边缘留出间距。") {
            Toggle("使用偏好间距", isOn: Binding(get: { draft.usesPreferredGaps == true }, set: { draft.usesPreferredGaps = $0 }))
                .labelsHidden().toggleStyle(.switch)
        }
        Divider()
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
            SettingsRow("位置") {
                Picker("窗口位置", selection: binding.positionPreset) {
                    Text("自定义").tag(nil as WindowGeometry.Anchor?)
                    Divider()
                    Text("居中").tag(WindowGeometry.Anchor.center as WindowGeometry.Anchor?)
                    ForEach(WindowGeometry.Anchor.allCases.filter { $0 != .center }, id: \.self) { anchor in
                        Text(anchor.localizedTitle).tag(anchor as WindowGeometry.Anchor?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Divider()
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
        if let message { Text(message).foregroundStyle(.red).font(.callout) }
    }

    private var layoutPicker: some View {
        HStack(spacing: 8) {
            Button {
                adding = false
                choosingWindow.toggle()
            } label: {
                LauncherCreationControl(focused: choosingWindow) {
                    HStack(spacing: 8) {
                        if let entry = selectedEntry {
                            windowLabel(entry)
                        } else { Text("选择窗口") }
                        Spacer(minLength: 0)
                        Image(systemName: choosingWindow ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(windows.isEmpty)
            .accessibilityLabel("选择要编辑的窗口")
            .accessibilityValue(selectedEntry.map { appName($0.bundleID) } ?? "")
            .anchorPreference(key: LayoutPickerAnchor.self, value: .bounds) { choosingWindow ? $0 : nil }

            Button {
                appQuery = ""
                choosingWindow = false
                adding.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 26)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(!canAddWindow || displays.isEmpty)
            .help(canAddWindow ? "为当前显示器添加窗口" : "每台显示器最多八个窗口")
            .accessibilityLabel("添加应用程序")
            .anchorPreference(key: LayoutPickerAnchor.self, value: .bounds) { adding ? $0 : nil }
        }
    }

    private var windowMenu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Set(windows.map(\.display)).sorted(), id: \.self) { index in
                    Text(displays[safe: index]?.name ?? "显示器 \(index + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 8)
                    ForEach(windows.filter { $0.display == index }) { entry in
                        Button { choose(entry) } label: {
                            HStack {
                                windowLabel(entry)
                                Spacer()
                                if entry.id == selected { Image(systemName: "checkmark").font(.caption) }
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(entry.id == selected ? .isSelected : [])
                    }
                }
                if let selected {
                    Divider()
                    Button("移除此条目", role: .destructive) { remove(selected) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .padding(8)
                }
            }
            .padding(6)
        }
        .frame(height: min(184, 62 + CGFloat(windows.count) * 36))
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func windowLabel(_ entry: WindowLayoutEntry) -> some View {
        HStack(spacing: 8) {
            appIcon(entry.bundleID)
                .frame(width: 19, height: 19)
                .fixedSize()
                .accessibilityHidden(true)
            Text(appName(entry.bundleID))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var applicationMenu: some View {
        VStack(spacing: 0) {
            TextField("搜索应用程序…", text: $appQuery)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .applicationSearch)
                .padding(8)
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
            .frame(height: 164)
        }
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { focus = .applicationSearch }
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func choose(_ entry: WindowLayoutEntry?) {
        adding = false
        choosingWindow = false
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

private struct LayoutPickerAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let anchor = nextValue() { value = anchor }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
