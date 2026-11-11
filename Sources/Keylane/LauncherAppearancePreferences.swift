import SwiftUI

struct LauncherAppearancePreferences: View {
    let model: Model
    @StateObject private var observation: SettingsPageObservation

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: SettingsPageObservation([
            SettingsPageObservation.changes(model.$appearance),
            SettingsPageObservation.changes(model.$interfaceSize),
            SettingsPageObservation.changes(model.$windowMode),
            SettingsPageObservation.changes(model.$compactFavorites)
        ]))
    }

    private func binding<Value>(_ key: ReferenceWritableKeyPath<Model, Value>) -> Binding<Value> {
        Binding(get: { model[keyPath: key] }, set: { model[keyPath: key] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("外观").font(.headline).padding(.leading, 14)
            SettingsCard(layout: .flush, anchor: .appearance) {
                VStack(spacing: 16) {
                    SettingsPicker("显示模式", selection: binding(\.appearance)) {
                        Text("跟随系统").tag("system")
                        Text("深色").tag("dark")
                        Text("浅色").tag("light")
                    }.settingsAnchor(.glass)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("界面大小")
                            Text("调整启动器的文字、图标和窗口大小。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ForEach(Array(["small", "medium", "large"].enumerated()), id: \.element) { index, value in
                            Button { model.interfaceSize = value } label: {
                                Text("Aa").font(.system(size: CGFloat(12 + index * 4), weight: .medium))
                                    .frame(width: 34, height: 34)
                                    .background(.primary.opacity(model.interfaceSize == value ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(["小", "中", "大"][index])
                                .accessibilityAddTraits(model.interfaceSize == value ? .isSelected : [])
                        }
                    }
                }.padding(18)
            }

            SettingsCard(layout: .flush, anchor: .windowMode) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("窗口模式").font(.headline)
                    Text("选择通过启动热键打开 Keylane 时的显示方式。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        mode("compact", title: "紧凑", expanded: false)
                        mode("expanded", title: "展开", expanded: true)
                    }
                    Divider()
                    Toggle(isOn: binding(\.compactFavorites)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("在紧凑模式显示收藏")
                            Text("在搜索框下方显示收藏图标。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(18)
            }
        }
    }
    private func mode(_ value: String, title: String, expanded: Bool) -> some View {
        Button { model.windowMode = value } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(model.windowMode == value ? Color.accentColor.gradient : Color.gray.gradient)
                    VStack(spacing: 5) {
                        HStack(spacing: 5) { Image(systemName: "magnifyingglass"); RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.3)).frame(height: 3) }
                            .font(.system(size: 8)).foregroundStyle(.white.opacity(0.6))
                        if expanded {
                            ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.12)).frame(height: 6) }
                        }
                    }.padding(9).frame(width: 100)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }.frame(height: 86)
                Text(title).font(.system(size: 12, weight: model.windowMode == value ? .semibold : .regular))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(model.windowMode == value ? .isSelected : [])
    }
}
