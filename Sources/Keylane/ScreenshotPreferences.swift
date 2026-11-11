import SwiftUI

struct ScreenshotPreferences: View {
    @ObservedObject var library: ScreenshotLibrary
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                Toggle("启用截图管理", isOn: $library.enabled)
            }
            card {
                Text("列数").font(VisualStyle.rowText)
                HStack {
                    ForEach(3...6, id: \.self) { count in
                        if count != 3 { Spacer(minLength: 8) }
                        Button { library.columns = count } label: {
                            VStack(spacing: 5) {
                                ColumnDiagram(count: count, selected: library.columns == count)
                                Text("\(count)").foregroundStyle(library.columns == count ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(count) 列")
                        .accessibilityAddTraits(library.columns == count ? .isSelected : [])
                    }
                }
            }.id("screenshot-columns")
            card {
                HStack {
                    caption("搜索范围", "搜索这些文件夹及其子目录。")
                    Spacer()
                    Button { library.chooseFolders() } label: { Image(systemName: "plus") }
                        .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
                        .help("添加搜索文件夹")
                }
                if library.scopes.isEmpty {
                    ForEach(library.folders, id: \.path) { url in folderRow(url.path) }
                    Text("正在使用 macOS 的截图保存位置。").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(library.scopes) { scope in
                        HStack {
                            folderRow(scope.url.path)
                            Spacer()
                            Button(role: .destructive) { library.removeFolder(scope) } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.plain).help("移除搜索范围")
                        }
                    }
                }
            }.id("screenshot-scopes")
            card {
                Toggle(isOn: $library.includeAll) {
                    caption("包含所有媒体", "搜索指定文件夹中的全部图片和视频。")
                }
            }
            card {
                Toggle(isOn: $library.recognizesText) {
                    caption("文字识别", "使用本机文字识别，在搜索框输入 text: 或「文字:」查找图片内容。")
                }
                Divider()
                SettingsPicker("识别模式", selection: $library.accurate) {
                    Text("准确").tag(true)
                    Text("快速").tag(false)
                }.disabled(!library.recognizesText)
                Divider()
                Toggle(isOn: $library.allowCloudOCR) {
                    caption("允许识别云端文件", "识别尚未下载的图片时，云盘可能会下载原文件。")
                }.disabled(!library.recognizesText)
            }.id("screenshot-text")
            Text("命令").font(VisualStyle.rowText).padding(.leading, 12)
            card {
                ForEach(ScreenshotCommand.allCases, id: \.rawValue) { command in
                    if command != .search { Divider() }
                    CommandSettingsRow(title: command.title,
                        alias: Binding(get: { model.aliases[command.rawValue] ?? "" },
                                       set: { model.setAlias(command.rawValue, value: $0) }),
                        shortcut: model.bindings[command.rawValue],
                        isEnabled: Binding(get: { !library.disabledCommands.contains(command.rawValue) }, set: { enabled in
                            if enabled { library.disabledCommands.remove(command.rawValue) }
                            else { library.disabledCommands.insert(command.rawValue) }
                        }),
                        setShortcut: { model.setShortcut(command.rawValue, value: $0) }) {
                            SettingsIcon(symbol: command.symbol)
                        }
                }
            }.disabled(!library.enabled)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11, content: content)
            .padding(14).modifier(SettingsSurface())
    }

    private func caption(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(VisualStyle.rowText)
            Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func folderRow(_ path: String) -> some View {
        Label((path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
            .font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(path)
    }
}

private struct ColumnDiagram: View {
    let count: Int
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        Canvas { context, size in
            var lines = Path()
            for step in 1..<count {
                let fraction = CGFloat(step) / CGFloat(count)
                lines.move(to: CGPoint(x: size.width * fraction, y: 0))
                lines.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                lines.move(to: CGPoint(x: 0, y: size.height * fraction))
                lines.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
            context.stroke(lines, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 0.6, dash: [1, 1]))
        }
        .frame(width: 66, height: 66)
        .background(.primary.opacity(selected ? 0.12 : 0.025))
        .clipShape(shape)
        .overlay { shape.strokeBorder(.primary.opacity(selected ? 0.32 : 0.14), lineWidth: 1) }
    }
}
