import SwiftUI
import KeylaneCore

struct WindowActionEditor: View {
    @ObservedObject var controller: WindowManagementController
    let back: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        LauncherCreationForm(back: back) { EmptyView() } fields: {
            LauncherCreationField("名称") {
                LauncherCreationControl(focused: nameFocused) {
                    TextField("窗口命令名称", text: $controller.draft.name)
                        .textFieldStyle(.plain).focused($nameFocused)
                }
            }
            geometryFields(Binding(get: { controller.draft.geometry ?? .init() },
                                   set: { controller.draft.geometry = $0 }))
            if !controller.error.isEmpty {
                LauncherCreationField("") { Text(controller.error).foregroundStyle(.red) }
            }
        }
        .task {
            await Task.yield()
            if !Task.isCancelled { nameFocused = true }
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

extension WindowGeometry.Anchor {
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
