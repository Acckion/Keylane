import SwiftUI
import KeylaneCore

struct ScreenshotPreferences: View {
    let library: ScreenshotLibrary
    let model: Model
    @StateObject private var observation: SettingsPageObservation

    init(library: ScreenshotLibrary, model: Model) {
        self.library = library
        self.model = model
        _observation = StateObject(wrappedValue: SettingsPageObservation([
            SettingsPageObservation.changes(model.$aliases),
            SettingsPageObservation.changes(model.$bindings),
            SettingsPageObservation.changes(library.$enabled),
            SettingsPageObservation.changes(library.$columns),
            SettingsPageObservation.changes(library.$scopes),
            SettingsPageObservation.changes(library.$includeAll),
            SettingsPageObservation.changes(library.$recognizesText),
            SettingsPageObservation.changes(library.$accurate),
            SettingsPageObservation.changes(library.$allowCloudOCR),
            SettingsPageObservation.changes(library.$disabledCommands)
        ]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                Toggle("启用截图管理", isOn: binding(\.enabled))
            }
            SettingsCard(anchor: .screenshotColumns) {
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
            }
            SettingsCard(anchor: .screenshotScopes) {
                HStack {
                    SettingsCaption(title: "搜索范围", detail: "搜索这些文件夹及其子目录。", style: .compact)
                    Spacer()
                    SettingsAddFolderButton { library.chooseFolders() }
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
            }
            SettingsCard {
                Toggle(isOn: binding(\.includeAll)) {
                    SettingsCaption(title: "包含所有媒体", detail: "搜索指定文件夹中的全部图片和视频。", style: .compact)
                }
            }
            SettingsCard(anchor: .screenshotText) {
                Toggle(isOn: binding(\.recognizesText)) {
                    SettingsCaption(title: "文字识别", detail: "使用本机文字识别，在搜索框输入 text: 或「文字:」查找图片内容。", style: .compact)
                }
                Divider()
                SettingsPicker("识别模式", selection: binding(\.accurate)) {
                    Text("准确").tag(true)
                    Text("快速").tag(false)
                }.disabled(!library.recognizesText)
                Divider()
                Toggle(isOn: binding(\.allowCloudOCR)) {
                    SettingsCaption(title: "允许识别云端文件", detail: "识别尚未下载的图片时，云盘可能会下载原文件。", style: .compact)
                }.disabled(!library.recognizesText)
            }
            Text("命令").font(VisualStyle.rowText).padding(.leading, 12)
            CommandSettingsList(items: ScreenshotCommand.allCases, id: \.rawValue) { command in
                CommandSettingsRow(title: command.title,
                    model: model, commandID: CommandID(rawValue: command.rawValue),
                    isEnabled: Binding(get: { !library.disabledCommands.contains(command.rawValue) }, set: { enabled in
                        if enabled { library.disabledCommands.remove(command.rawValue) }
                        else { library.disabledCommands.insert(command.rawValue) }
                    })) {
                        SettingsIcon(symbol: command.symbol)
                    }
            }.disabled(!library.enabled)
        }
    }

    private func binding<Value>(_ key: ReferenceWritableKeyPath<ScreenshotLibrary, Value>) -> Binding<Value> {
        Binding(get: { library[keyPath: key] }, set: { library[keyPath: key] = $0 })
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
