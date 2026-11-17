import SwiftUI
import KeylaneCore

struct WindowActionEditor: View {
    @ObservedObject var controller: WindowManagementController
    @ObservedObject var applications: ApplicationSettingsCatalog
    @ObservedObject var quicklinks: QuicklinksController
    let back: () -> Void
    @FocusState private var nameFocused: Bool
    @State private var selectedWindow: UUID?
    @State private var installedApps: [ApplicationChoice] = []

    var body: some View {
        LauncherCreationForm(back: back) {
            if controller.draft.windows != nil {
                Button("添加可见窗口") { controller.captureCurrentLayout(append: true) }
                    .buttonStyle(.glass)
            }
        } fields: {
            LauncherCreationField("名称") {
                LauncherCreationControl(focused: nameFocused) {
                    TextField("窗口命令或布局名称", text: $controller.draft.name)
                        .textFieldStyle(.plain).focused($nameFocused)
                }
            }
            if controller.draft.geometry != nil {
                geometryFields(Binding(get: { controller.draft.geometry ?? .init() },
                                       set: { controller.draft.geometry = $0 }))
            } else {
                layoutFields
            }
            if !controller.error.isEmpty {
                LauncherCreationField("") { Text(controller.error).foregroundStyle(.red) }
            }
        }
        .task {
            await Task.yield()
            if !Task.isCancelled { nameFocused = true }
        }
        .task(id: applications.items) {
            guard controller.draft.windows != nil else { return }
            let items = applications.items
            let choices = await Task.detached {
                var seen = Set<String>()
                return items.compactMap { item -> ApplicationChoice? in
                    guard let id = Bundle(url: item.url)?.bundleIdentifier, seen.insert(id).inserted else { return nil }
                    return ApplicationChoice(id: id, name: item.title)
                }
            }.value
            if !Task.isCancelled { installedApps = choices }
        }
    }

    @ViewBuilder private func geometryFields(_ geometry: Binding<WindowGeometry>) -> some View {
        LauncherCreationField("停靠位置") {
            Picker("停靠位置", selection: geometry.anchor) {
                ForEach(WindowGeometry.Anchor.allCases, id: \.self) { anchor in
                    Text(anchor.localizedTitle).tag(anchor)
                }
            }
            .labelsHidden()
        }
        measurement("宽度", value: geometry.width)
        measurement("高度", value: geometry.height)
        measurement("横向偏移", value: geometry.x)
        measurement("纵向偏移", value: geometry.y)
    }

    private func measurement(_ title: String, value: Binding<WindowGeometry.Measurement>) -> some View {
        LauncherCreationField(title) {
            HStack {
                TextField(title, value: value.value, format: .number)
                    .textFieldStyle(.roundedBorder)
                Picker("单位", selection: value.percentage) {
                    Text("%").tag(true)
                    Text("点").tag(false)
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    @ViewBuilder private var layoutFields: some View {
        let windows = controller.draft.windows ?? []
        LauncherCreationField("其他窗口") {
            Picker("其他窗口", selection: $controller.draft.otherWindows) {
                Text("保留").tag(CustomWindowAction.OtherWindows.keep)
                Text("最小化").tag(CustomWindowAction.OtherWindows.minimize)
                Text("关闭").tag(CustomWindowAction.OtherWindows.close)
            }
            .labelsHidden()
        }
        LauncherCreationField("窗口") {
            HStack {
                Picker("要编辑的窗口", selection: $selectedWindow) {
                    Text("选择窗口").tag(UUID?.none)
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        Text("\(index + 1). \(applicationName(window.bundleID))").tag(Optional(window.id))
                    }
                }
                .labelsHidden()
                Button("添加", systemImage: "plus") {
                    let window = WindowLayoutEntry(bundleID: "")
                    controller.draft.windows?.append(window)
                    selectedWindow = window.id
                }.labelStyle(.iconOnly)
                Button("移除", systemImage: "minus") {
                    controller.draft.windows?.removeAll { $0.id == selectedWindow }
                    selectedWindow = controller.draft.windows?.first?.id
                }.labelStyle(.iconOnly).disabled(selectedWindow == nil)
            }
        }
        if let id = selectedWindow, let initial = windows.first(where: { $0.id == id }) {
            let entry = Binding<WindowLayoutEntry>(
                get: { controller.draft.windows?.first(where: { $0.id == id }) ?? initial },
                set: { value in
                    guard let index = controller.draft.windows?.firstIndex(where: { $0.id == id }) else { return }
                    controller.draft.windows?[index] = value
                }
            )
            windowFields(entry)
        }
    }

    @ViewBuilder private func windowFields(_ entry: Binding<WindowLayoutEntry>) -> some View {
        LauncherCreationField("应用程序") {
            Picker("应用程序", selection: entry.bundleID) {
                Text("选择应用程序").tag("")
                if !entry.wrappedValue.bundleID.isEmpty, !installedApps.contains(where: { $0.id == entry.wrappedValue.bundleID }) {
                    Text(entry.wrappedValue.bundleID).tag(entry.wrappedValue.bundleID)
                }
                ForEach(installedApps) { app in Text(app.name).tag(app.id) }
            }
            .labelsHidden()
        }
        LauncherCreationField("窗口标题", detail: "留空时选择该应用的可用窗口。") {
            TextField("窗口标题", text: entry.windowTitle).textFieldStyle(.roundedBorder)
        }
        LauncherCreationField("显示器") {
            Picker("显示器", selection: entry.display) {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                    Text(screen.localizedName).tag(index)
                }
                if entry.wrappedValue.display >= NSScreen.screens.count {
                    Text("显示器 \(entry.wrappedValue.display + 1)（未连接）").tag(entry.wrappedValue.display)
                }
            }
            .labelsHidden()
        }
        geometryFields(entry.geometry)
        argumentFields(entry.argument)
    }

    @ViewBuilder private func argumentFields(_ argument: Binding<WindowLayoutEntry.Argument>) -> some View {
        LauncherCreationField("打开内容") {
            Picker("打开内容", selection: Binding(get: { argument.wrappedValue.kind }, set: { argument.wrappedValue = $0.empty })) {
                ForEach(WindowArgumentKind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
            }
            .labelsHidden()
        }
        switch argument.wrappedValue {
        case .none:
            EmptyView()
        case .quicklink:
            LauncherCreationField("快捷链接") {
                Picker("快捷链接", selection: Binding(get: { argument.wrappedValue.text }, set: { argument.wrappedValue = .quicklink($0) })) {
                    Text("选择快捷链接").tag("")
                    ForEach(quicklinks.links) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
            }
        default:
            let kind = argument.wrappedValue.kind
            LauncherCreationField(kind.label) {
                TextField(kind.label, text: Binding(get: { argument.wrappedValue.text }, set: { argument.wrappedValue = kind.value($0) }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private struct ApplicationChoice: Identifiable, Sendable {
        let id: String
        let name: String
    }

    private func applicationName(_ bundleID: String) -> String {
        if bundleID.isEmpty { return "新窗口" }
        return installedApps.first { $0.id == bundleID }?.name ?? bundleID
    }
}

struct WindowCoordinatesForm: View {
    @ObservedObject var controller: WindowManagementController
    let back: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        LauncherCreationForm(back: back) { EmptyView() } fields: {
            let resize = controller.coordinates.resize
            LauncherCreationField(resize ? "宽度（点）" : "横坐标（点）") {
                LauncherCreationControl(focused: focused) {
                    TextField(resize ? "宽度" : "X", text: $controller.coordinates.first)
                        .textFieldStyle(.plain).focused($focused)
                }
            }
            LauncherCreationField(resize ? "高度（点）" : "纵坐标（点）", detail: resize ? nil : "坐标以当前显示器可用区域的左上角为原点。") {
                LauncherCreationControl {
                    TextField(resize ? "高度" : "Y", text: $controller.coordinates.second).textFieldStyle(.plain)
                }
            }
            if !controller.error.isEmpty {
                LauncherCreationField("") { Text(controller.error).foregroundStyle(.red) }
            }
        }
        .task {
            await Task.yield()
            if !Task.isCancelled { focused = true }
        }
    }
}

private enum WindowArgumentKind: CaseIterable {
    case none, file, url, quicklink, arguments

    var label: String {
        switch self {
        case .none: "无"
        case .file: "文件或文件夹"
        case .url: "URL"
        case .quicklink: "快捷链接"
        case .arguments: "命令行参数"
        }
    }

    var empty: WindowLayoutEntry.Argument { value("") }

    func value(_ text: String) -> WindowLayoutEntry.Argument {
        switch self {
        case .none: .none
        case .file: .file(text)
        case .url: .url(text)
        case .quicklink: .quicklink(text)
        case .arguments: .arguments(text)
        }
    }
}

private extension WindowLayoutEntry.Argument {
    var kind: WindowArgumentKind {
        switch self {
        case .none: .none
        case .file: .file
        case .url: .url
        case .quicklink: .quicklink
        case .arguments: .arguments
        }
    }

    var text: String {
        switch self {
        case .none: ""
        case .file(let value), .url(let value), .quicklink(let value), .arguments(let value): value
        }
    }
}

private extension WindowGeometry.Anchor {
    var localizedTitle: String {
        switch self {
        case .topLeft: "左上"
        case .topCenter: "上方居中"
        case .topRight: "右上"
        case .left: "左侧居中"
        case .center: "正中"
        case .right: "右侧居中"
        case .bottomLeft: "左下"
        case .bottomCenter: "下方居中"
        case .bottomRight: "右下"
        }
    }
}
