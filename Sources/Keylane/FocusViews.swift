import AppKit
import SwiftUI
import KeylaneCore

struct FocusCategoryForm: View {
    @ObservedObject var controller: FocusController
    @ObservedObject var catalog: ApplicationSettingsCatalog
    let back: () -> Void
    @State private var open: String?
    @FocusState private var primaryFocused: Bool
    var body: some View {
        LauncherCreationForm(back: back) { EmptyView() } fields: {
            LauncherCreationField("名称与图标") {
                LauncherCreationControl(focused: primaryFocused || open == "icon") {
                    HStack(spacing: 12) {
                        TextField("为专注分类命名", text: $controller.categoryDraft.name).textFieldStyle(.plain).focused($primaryFocused)
                        Divider().frame(height: 20)
                        FocusIconPicker(selection: $controller.categoryDraft.symbol, open: picker("icon"))
                            .frame(width: 40)
                    }
                }
            }
            LauncherCreationField("应用与网站") {
                FocusTargets(applications: $controller.categoryDraft.applications, websites: $controller.categoryDraft.websites,
                             catalog: catalog, categories: [], open: picker("targets"))
            }
            FocusMessage(text: controller.message)
        }
        .task { await Task.yield(); if !Task.isCancelled { primaryFocused = true } }
        .onChange(of: primaryFocused) { _, value in if value { open = nil } }
    }
    private func picker(_ id: String) -> Binding<Bool> { Binding(get: { open == id }, set: { open = $0 ? id : nil }) }
}
struct FocusSessionForm: View {
    @ObservedObject var controller: FocusController
    @ObservedObject var catalog: ApplicationSettingsCatalog
    let back: () -> Void
    @State private var open: String?
    @FocusState private var primaryFocused: Bool
    var body: some View {
        LauncherCreationForm(back: back) { EmptyView() } fields: {
            LauncherCreationField("目标") {
                LauncherCreationControl(focused: primaryFocused) { TextField("这次想专注做什么？", text: $controller.draft.goal).textFieldStyle(.plain).focused($primaryFocused) }
            }
            LauncherCreationField("时长") { FocusDurationPicker(text: $controller.durationText, open: picker("duration")) }
            LauncherCreationField("模式") {
                LauncherCreationPicker(label: "专注模式", selection: $controller.draft.mode,
                                       values: FocusConfiguration.Mode.allCases, open: picker("mode")) {
                    $0 == .block ? "屏蔽应用与网站" : "允许应用与网站"
                }
            }
            LauncherCreationField(controller.draft.mode == .block ? "屏蔽" : "允许", detail: "网站屏蔽支持 Safari 和 Chromium 系浏览器。访达与系统设置始终可用。") {
                FocusTargets(applications: $controller.draft.applications, websites: $controller.draft.websites,
                             catalog: catalog, categories: controller.categories, open: picker("targets"))
            }
            FocusMessage(text: controller.message)
        }
        .task { await Task.yield(); if !Task.isCancelled { primaryFocused = true } }
        .onChange(of: primaryFocused) { _, value in if value { open = nil } }
    }
    private func picker(_ id: String) -> Binding<Bool> { Binding(get: { open == id }, set: { open = $0 ? id : nil }) }
}
struct FocusCategoryList: View {
    @ObservedObject var controller: FocusController
    let edit: (FocusCategory) -> Void
    var body: some View {
        SelectableResultList(selection: controller.selectedCategory, query: controller.categoryQuery,
                             firstResult: controller.visibleCategories.first?.id) {
            ForEach([true, false], id: \.self) { custom in
                let items = controller.visibleCategories.filter { item in controller.archive.categories.contains { $0.id == item.id } == custom }
                if !items.isEmpty {
                    ResultListSection(title: custom ? "自定义" : "内置", isFirst: custom) {
                        ForEach(items) { item in
                            ResultListButton(id: item.id, action: { controller.selectedCategory = item.id; edit(item) }) {
                                ResultListRow(selected: controller.selectedCategory == item.id) {
                                    Image(systemName: item.symbol).font(.system(size: 19))
                                } content: {
                                    HStack {
                                        Text(item.name)
                                        Spacer()
                                        Text("\(item.websites.count) 个网站  \(item.applications.count) 个应用").foregroundStyle(.secondary)
                                    }
                                }
                            }.onHover { if $0 { controller.selectedCategory = item.id } }
                        }
                    }
                }
            }
            if controller.visibleCategories.isEmpty { Text("没有匹配的专注分类").foregroundStyle(.secondary).padding(24) }
            FocusMessage(text: controller.message)
        }
    }
}
struct FocusImportView: View {
    @ObservedObject var controller: FocusController
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "target").font(.system(size: 52)).foregroundStyle(.mint)
            Text("导入专注分类").font(.title.bold())
            Text("选择从 Keylane 导出的 JSON 文件以继续").foregroundStyle(.secondary)
            FocusMessage(text: controller.message)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}
struct FocusMessage: View {
    let text: String
    var body: some View {
        if !text.isEmpty { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 24) }
    }
}
private struct FocusIconPicker: View {
    @Binding var selection: String
    @Binding var open: Bool
    @State private var query = ""
    private let icons = [("target", "靶心 Target"), ("book", "学习 Study"), ("textformat.abc", "文字 Alphabet"),
                         ("hammer", "工作 Work"), ("pencil", "写作 Writing"), ("laptopcomputer", "电脑 Computer"),
                         ("gamecontroller", "游戏 Gaming"), ("person.2", "社交 Social"), ("airplane", "旅行 Travel"),
                         ("newspaper", "新闻 News"), ("play.circle", "影音 Streaming"), ("cart", "购物 Shopping"),
                         ("message", "通讯 Messaging"), ("cup.and.saucer", "休息 Break"), ("leaf", "自然 Nature"),
                         ("bug", "调试 Bug"), ("building.2", "建筑 Building"), ("list.bullet", "清单 List")]
    var body: some View {
        Button { open.toggle() } label: {
            HStack { Image(systemName: selection); Image(systemName: "chevron.down").font(.caption2) }
                .frame(height: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("分类图标")
            .anchorPreference(key: CreationPickerMenuPreference.self, value: .bounds) { anchor in
                guard open else { return nil }
                return CreationPickerMenu(id: "focus-icon", anchor: anchor) { _, rows in
                    AnyView(ResultFilterPanel(selection: selection,
                                              options: ResultFilterPanel.matches(icons.map { .init(id: $0.0, title: $0.1, symbol: $0.0) }, query: query),
                                              query: $query, searchPlaceholder: "搜索图标…", width: 230, maximumVisibleRows: rows,
                                              choose: { selection = $0.id; open = false }, dismiss: { open = false })
                        .modifier(LauncherMenuSurface(open: true)))
                }
            }
    }
}
private struct FocusDurationPicker: View {
    @Binding var text: String
    @Binding var open: Bool
    @State private var query = ""
    private var options: [ResultFilterOption] {
        var rows: [ResultFilterOption] = [ .init(id: "", title: "不限时长", symbol: "infinity") ]
        rows += [15, 30, 60, 90].map { .init(id: "\($0) min", title: "\($0) 分钟", symbol: "clock") }
        rows += [.init(id: "until 12pm", title: "直到中午", symbol: "sun.max")]
        if !query.isEmpty, let duration = try? FocusDuration.parse(query) {
            rows.insert(.init(id: query, title: "\(Int(duration / 60)) 分钟", symbol: "clock"), at: 0)
        }
        return rows
    }
    var body: some View {
        HStack(spacing: 4) {
            LauncherCreationControl(focused: open) {
                HStack {
                    TextField("不限时长，如 45 min、1:30", text: $text).textFieldStyle(.plain)
                    Button { query = ""; open.toggle() } label: { Image(systemName: "clock") }.buttonStyle(.plain).help("选择时长")
                }
            }
        }.anchorPreference(key: CreationPickerMenuPreference.self, value: .bounds) { anchor in
            guard open else { return nil }
            return CreationPickerMenu(id: "focus-duration", anchor: anchor) { width, rows in
                AnyView(ResultFilterPanel(selection: text, options: options, query: $query,
                                          searchPlaceholder: "输入时长：45 min、1:30、until 6pm", width: width, maximumVisibleRows: rows,
                                          choose: { text = $0.id; open = false }, dismiss: { open = false })
                    .modifier(LauncherMenuSurface(open: true)))
            }
        }
    }
}

/// Chips and an inline query share one keyboard responder, including IME composition.
private struct FocusTargets: View {
    @Binding var applications: [FocusApplication]
    @Binding var websites: [String]
    @ObservedObject var catalog: ApplicationSettingsCatalog
    let categories: [FocusCategory]
    @Binding var open: Bool
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var inputFocused: Bool
    private var options: [ResultFilterOption] {
        var result = categories.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.map {
            ResultFilterOption(id: "category:" + $0.id.uuidString, title: $0.name, symbol: $0.symbol, subtitle: "分类")
        }
        let selected = Set(applications.map(\.id))
        result += catalog.items.compactMap { item in
            guard let id = Bundle(url: item.url)?.bundleIdentifier, !selected.contains(id),
                  query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.filename.localizedCaseInsensitiveContains(query) || id.localizedCaseInsensitiveContains(query) else { return nil }
            return ResultFilterOption(id: "app:" + id, title: item.title, symbol: "app", iconPath: item.url.path)
        }
        if let host = FocusWebsite.host(query), !websites.contains(host) {
            result.append(.init(id: "website:" + host, title: "添加网站：" + host, symbol: "link"))
        }
        return result
    }
    var body: some View {
        LauncherCreationControl(focused: open) {
            HStack(alignment: .top, spacing: 4) {
                FocusFlowLayout {
                    ForEach(websites, id: \.self) { site in chip(site, symbol: "link") { websites.removeAll { $0 == site } } }
                    ForEach(applications) { app in
                        chip(app.name, symbol: "app", appID: app.id) { applications.removeAll { $0.id == app.id } }
                    }
                    TextField(applications.isEmpty && websites.isEmpty ? "搜索应用、网站或分类…" : "添加…", text: $query)
                        .textFieldStyle(.plain).focused($inputFocused).frame(width: applications.isEmpty && websites.isEmpty ? 290 : 100, height: 24)
                        .onTapGesture { open = true }
                        .onChange(of: inputFocused) { _, value in if value { open = true } }
                        .onChange(of: query) { _, _ in open = true; highlighted = 0 }
                        .onKeyPress(.downArrow) { move(1) }
                        .onKeyPress(.upArrow) { move(-1) }
                        .onKeyPress(.return) {
                            guard open, !SearchField.isComposing, options.indices.contains(highlighted) else { return .ignored }
                            choose(options[highlighted]); return .handled
                        }
                        .onKeyPress(.escape) {
                            guard open, !SearchField.isComposing else { return .ignored }; open = false; return .handled
                        }
                }
                Button { open.toggle() } label: { Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2) }
                    .buttonStyle(.plain).help("选择应用与网站")
            }
        }.anchorPreference(key: CreationPickerMenuPreference.self, value: .bounds) { anchor in
            guard open else { return nil }
            return CreationPickerMenu(id: "focus-targets", anchor: anchor) { width, rows in
                AnyView(ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                                LauncherMenuRow(title: option.title, symbol: option.symbol, selected: index == highlighted,
                                                style: .filter, iconPath: option.iconPath, activate: { choose(option) },
                                                highlight: { highlighted = index }) { EmptyView() }.id(index)
                            }
                            if options.isEmpty { Text("没有匹配项，输入完整域名以添加网站").foregroundStyle(.secondary).padding(12) }
                        }.padding(8)
                    }.onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
                }.frame(width: width, height: CGFloat(min(rows, max(1, options.count))) * 43 + 16)
                    .modifier(LauncherMenuSurface(open: true)))
            }
        }
    }
    private func chip(_ title: String, symbol: String, appID: String? = nil, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if let appID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 15, height: 15)
            } else { Image(systemName: symbol).font(.caption) }
            Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: 240)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("移除 " + title)
        }.padding(.horizontal, 7).padding(.vertical, 4).background(.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
    }
    private func move(_ delta: Int) -> KeyPress.Result {
        guard !SearchField.isComposing else { return .ignored }
        open = true; highlighted = NavigationBounds.move(highlighted, by: delta, count: options.count); return .handled
    }
    private func choose(_ option: ResultFilterOption) {
        if option.id.hasPrefix("website:") { websites.append(String(option.id.dropFirst(8))) }
        else if option.id.hasPrefix("app:") { applications.append(.init(id: String(option.id.dropFirst(4)), name: option.title)) }
        else if let category = categories.first(where: { "category:" + $0.id.uuidString == option.id }) {
            applications += category.applications.filter { app in !applications.contains { $0.id == app.id } }
            websites += category.websites.filter { !websites.contains($0) }
        }
        query = ""; highlighted = 0; inputFocused = true
    }
}

struct FocusFlowLayout: Layout {
    private func placements(_ views: Subviews, width: CGFloat) -> ([CGPoint], CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        var points: [CGPoint] = []
        for view in views {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += height + 4; height = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + 4; height = max(height, size.height)
        }
        return (points, y + height)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 340
        return CGSize(width: width, height: placements(subviews, width: width).1)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (points, _) = placements(subviews, width: bounds.width)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y), proposal: .unspecified)
        }
    }
}
