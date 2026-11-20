import KeylaneCore
import SwiftUI

/// Uses the production rows and menu surface, with synthetic content only.
struct ThemePreview: View {
    let theme: ThemeDefinition
    @State private var query = ""
    @State private var selected = 0
    @State private var actions = false
    @State private var checked = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                SearchField(text: $query, placeholder: "搜索预览…", focusToken: 0, wantsFocus: false,
                            submit: { actions.toggle() }, move: { selected = (selected + $0 + 2) % 2 }, escape: { actions = false })
                ProgressView().controlSize(.small).tint(theme.color(.loader).swiftUI)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("列表").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                ForEach(0..<2) { row in
                    Button { selected = row } label: {
                        ResultListRow(selected: selected == row) {
                            Image(systemName: row == 0 ? "paintpalette.fill" : "sparkles").foregroundStyle(ThemeColorStyle(role: row == 0 ? .purple : .yellow))
                        } content: {
                            HStack { Text(row == 0 ? "Theme Studio" : "你的灵感，从这里开始"); Spacer(); Text(row == 0 ? "命令" : "预览").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    ForEach(Array(ThemeColorRole.allCases.dropFirst(3)), id: \.self) { role in
                        Image(systemName: "circle.fill").foregroundStyle(ThemeColorStyle(role: role)).frame(maxWidth: .infinity)
                    }
                }.padding(.vertical, 14)
                Text("网格").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                HStack(spacing: 8) {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: [theme.color([.blue, .green, .orange, .magenta][index]).swiftUI.opacity(0.6), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay { Image(systemName: ["mountain.2", "leaf", "sun.horizon", "moon.stars"][index]).font(.title).foregroundStyle(theme.color(.text).swiftUI) }
                            .frame(height: 75)
                    }
                }
                Divider().padding(.vertical, 12)
                Text("表单").font(.caption).foregroundStyle(.secondary)
                TextField("名称", text: $query).textFieldStyle(.roundedBorder)
                Toggle("启用此选项", isOn: $checked).toggleStyle(.switch)
                HStack { Text("辅助文字与说明").foregroundStyle(.secondary); Spacer(); Button("主要按钮") {}.buttonStyle(.borderedProminent) }.padding(.vertical, 8)
            }.padding(12)
            Divider()
            HStack {
                Label("Theme Studio", systemImage: "paintpalette")
                Spacer()
                Button("操作", systemImage: "list.bullet") { actions.toggle() }.buttonStyle(.bordered)
            }.font(.callout).padding(14)
        }
        .overlay(alignment: .bottomTrailing) {
            if actions {
                VStack(spacing: 4) {
                    LauncherMenuRow(title: "应用主题", symbol: "checkmark", selected: true, activate: { actions = false }, highlight: {}) { Text("↩").foregroundStyle(.secondary) }
                    LauncherMenuRow(title: "复制主题", symbol: "doc.on.doc", selected: false, activate: {}, highlight: {}) { EmptyView() }
                    Divider()
                    LauncherMenuRow(title: "删除主题", symbol: "trash", selected: false, destructive: true, activate: {}, highlight: {}) { EmptyView() }
                }.padding(8).frame(width: 245).background { ThemeBackgroundView(theme: theme) }
                    .modifier(LauncherMenuSurface(open: true)).padding(12).padding(.bottom, 42)
            }
        }
        .background { ThemeBackgroundView(theme: theme) }
        .environment(\.keylaneTheme, theme)
        .foregroundStyle(theme.color(.text).swiftUI)
        .tint(theme.color(.selection).swiftUI)
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}
