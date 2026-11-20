import AppKit
import SwiftUI
import KeylaneCore

struct ScreenshotPreferences: View {
    let library: ScreenshotLibrary
    let model: Model
    @StateObject private var observation: ViewObservation
    @State private var pendingRetention: ScreenshotRetention?

    init(library: ScreenshotLibrary, model: Model) {
        self.library = library
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(library.$enabled),
            ViewObservation.changes(library.$columns),
            ViewObservation.changes(library.$scopes),
            ViewObservation.changes(library.$unavailableScopePaths),
            ViewObservation.changes(library.$includeAll),
            ViewObservation.changes(library.$recognizesText),
            ViewObservation.changes(library.$accurate),
            ViewObservation.changes(library.$allowCloudOCR),
            ViewObservation.changes(library.$retention),
            ViewObservation.changes(library.$retentionFailures),
            ViewObservation.changes(library.$disabledCommands)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsCard(anchor: .screenshotColumns) {
                Text("列数").font(VisualStyle.rowText)
                GridColumnChoices(counts: ScreenshotLibrary.columnCounts, selection: binding(\.columns))
            }
            SettingsSearchScopeCard(paths: library.scopes.map(\.path), detail: "搜索已授权的文件夹及其子目录。",
                                    anchor: .screenshotScopes, add: library.chooseFolders, remove: library.removeFolder(at:)) {
                if library.scopes.isEmpty, let suggestedFolder = library.suggestedFolder {
                    SettingsDescription("建议从 macOS 截图保存位置开始：\((suggestedFolder.path as NSString).abbreviatingWithTildeInPath)")
                }
                ForEach(library.unavailableScopePaths, id: \.self) { path in
                    SettingsDescription("无法访问 \((path as NSString).abbreviatingWithTildeInPath)。如果文件夹已移动，请添加新位置并移除此范围。")
                }
            }
            SettingsCard {
                Toggle(isOn: binding(\.includeAll)) {
                    SettingsCaption(title: "包含所有媒体", detail: "搜索指定文件夹中的全部图片和视频。")
                }
            }
            SettingsCard(anchor: .screenshotText) {
                Toggle(isOn: binding(\.recognizesText)) {
                    SettingsCaption(title: "文字识别", detail: "使用本机文字识别，在搜索框输入 text: 或「文字:」查找图片内容。")
                }
                Divider()
                SettingsPicker("识别模式", selection: binding(\.accurate)) {
                    Text("准确").tag(true)
                    Text("快速").tag(false)
                }.disabled(!library.recognizesText)
                Divider()
                Toggle(isOn: binding(\.allowCloudOCR)) {
                    SettingsCaption(title: "允许识别云端文件", detail: "识别尚未下载的图片时，云盘可能会下载原文件。")
                }.disabled(!library.recognizesText)
            }
            SettingsCard(anchor: .screenshotRetention) {
                SettingsPicker("保留期限", detail: "按创建时间将搜索范围内过期的截图和录屏移到废纸篓。已置顶的项目会保留。",
                               selection: Binding(get: { library.retention }, set: { choice in
                    guard choice != library.retention else { return }
                    if choice == .unlimited { library.retention = choice }
                    else { pendingRetention = choice }
                })) {
                    ForEach(ScreenshotRetention.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if library.retentionFailures > 0 {
                    SettingsDescription("有 \(library.retentionFailures) 项无法移到废纸篓，将在下次检查时重试。")
                }
            }.disabled(!library.enabled)
            SettingsSectionTitle(title: "命令")
            CommandSettingsList(items: ScreenshotCommand.allCases, id: \.rawValue) { command in
                CommandSettingsEntry(title: command.title,
                    model: model, commandID: CommandID(rawValue: command.rawValue),
                    isEnabled: library.commandEnabledBinding(command)) {
                        SettingsIcon(symbol: command.symbol, artwork: ModuleArtwork.command(.init(rawValue: command.rawValue), settingsPage: "screenshots"))
                    }
            }.disabled(!library.enabled)
            SettingsSectionTitle(title: "AI 扩展")
            ExtensionCommandPreferences(model: model, commands: model.launcherModules?.aiCommands(in: ScreenshotAIActions.moduleID) ?? [])
                .disabled(!library.enabled)
        }
        .confirmationDialog("启用截图自动清理？", isPresented: Binding(
            get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }
        ), presenting: pendingRetention) { choice in
            Button("设为保留 " + choice.title, role: .destructive) {
                guard library.enabled else { return }
                library.retention = choice
            }
            Button("取消", role: .cancel) {}
        } message: { choice in
            Text("现有超过 \(choice.title) 的未置顶截图和录屏也会移到废纸篓。")
        }
        .onAppear(perform: library.checkFolders)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.checkFolders()
        }
    }

    private func binding<Value>(_ key: ReferenceWritableKeyPath<ScreenshotLibrary, Value>) -> Binding<Value> {
        Binding(get: { library[keyPath: key] }, set: { library[keyPath: key] = $0 })
    }


}

struct GridColumnChoices: View {
    let counts: ClosedRange<Int>
    @Binding var selection: Int

    var body: some View {
        HStack {
            ForEach(counts, id: \.self) { count in
                if count != counts.lowerBound { Spacer(minLength: 8) }
                Button { selection = count } label: {
                    VStack(spacing: 5) {
                        ColumnDiagram(count: count, selected: selection == count)
                        Text("\(count)").foregroundStyle(selection == count ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(count) 列")
                .accessibilityAddTraits(selection == count ? .isSelected : [])
            }
        }
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
