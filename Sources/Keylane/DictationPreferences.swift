import AppKit
import AVFoundation
import KeylaneCore
import SwiftUI
import UniformTypeIdentifiers

struct DictationPreferences: View {
    let model: Model
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: DictationSettings
    @ObservedObject var configuration: AIConfiguration
    let commands: [LauncherModule.Command]
    @State private var microphones: [AVCaptureDevice] = []

    var body: some View {
        SettingsPageSections {
            if !controller.message.isEmpty { SettingsDescription(controller.message).foregroundStyle(.orange) }
            DictationTranscriptionPreferences(settings: settings, configuration: configuration) {
                model.openSettings(page: "ai-models")
            }.settingsAnchor(DictationModule.connectionItem)

            SettingsGroup("麦克风") {
                SettingsDescription("未指定设备时跟随系统默认；可按优先级选择设备，不可用时自动尝试下一项。")
                    .padding(.vertical, 8)
                ForEach(Array(settings.options.microphoneIDs.enumerated()), id: \.element) { index, id in
                    Divider()
                    SettingsRow(microphones.first { $0.uniqueID == id }?.localizedName ?? "设备未连接") {
                        if index > 0 {
                            SettingsIconButton("提高优先级", symbol: "arrow.up") { settings.options.microphoneIDs.swapAt(index, index - 1) }
                        }
                        SettingsIconButton("移除设备", symbol: "minus") { settings.options.microphoneIDs.removeAll { $0 == id } }
                    }
                }
                Divider()
                SettingsRow("优先设备") {
                    Menu("添加麦克风") {
                        Button("跟随系统默认") { settings.options.microphoneIDs = [] }
                        ForEach(microphones, id: \.uniqueID) { device in
                            Button(device.localizedName) {
                                if !settings.options.microphoneIDs.contains(device.uniqueID) { settings.options.microphoneIDs.append(device.uniqueID) }
                            }.disabled(settings.options.microphoneIDs.contains(device.uniqueID))
                        }
                    }.onTapGesture { microphones = DictationCapture.microphones }
                }
            }

            SettingsGroup("录音与输出") {
                SettingsPicker("快捷键行为", selection: settings.binding(\.holdToTalk)) {
                    Text("按一下开始／结束").tag(false); Text("按住说话，松开结束").tag(true)
                }
                Divider()
                SettingsPicker("单独修饰键", detail: "也可以使用下方命令的组合快捷键。使用 fn 前，请将系统的 fn 行为设为「不执行任何操作」。", selection: settings.binding(\.modifierKey)) {
                    Text("不使用").tag(UInt16?.none)
                    Text("右 Option").tag(UInt16?(61)); Text("右 Command").tag(UInt16?(54))
                    Text("右 Control").tag(UInt16?(62)); Text("右 Shift").tag(UInt16?(60)); Text("fn／🌐").tag(UInt16?(63))
                }
                Divider()
                SettingsPicker("完成后", selection: settings.binding(\.output)) {
                    ForEach(DictationOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Divider()
                toggle("使用 ⌘ Return／⌘ Esc 完成和取消", detail: "关闭时使用 Return／Esc；全局按键需要辅助功能权限。", path: \.modifiedFinishKeys)
                Divider()
                toggle("播放开始和结束提示音", path: \.playSounds)
                Divider()
                toggle("录音时降低系统音量", detail: "结束或取消时恢复；你手动调整音量后不再覆盖。", path: \.lowerAudio)
                Divider()
                toggle("根据光标周围文字调整空格和大小写", path: \.contextAwarePaste)
                Divider()
                SettingsPicker("粘贴后自动提交", selection: settings.binding(\.submit)) {
                    ForEach(DictationSubmit.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.options.submit == .keyword {
                    SettingsRow("结尾提交词", detail: "词语会从结果中移除；仅在粘贴成功后提交。") {
                        TextField("发送", text: settings.binding(\.submitKeyword)).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    }
                }
                if settings.options.submit != .disabled {
                    SettingsPicker("提交按键", selection: settings.binding(\.submitWithShift)) {
                        Text("Return").tag(false); Text("Shift Return").tag(true)
                    }
                }
                Divider()
                SettingsPicker("口述提问的目标", selection: settings.binding(\.dictateToChat)) {
                    Text("Quick AI").tag(false); Text("AI Chat").tag(true)
                }
            }.settingsAnchor(DictationModule.behaviorItem)

            SettingsGroup("文字整理") {
                toggle("整理口头表达", detail: "去除填充词和重复，处理自我纠正、标点与格式；原始转写也会保留在历史中。", path: \.cleanup)
                Divider()
                SettingsRow("整理模型", detail: "可以沿用 AI 命令的默认云端模型。") {
                    AIModelPicker(configuration: configuration, selection: Binding(get: {
                        settings.options.cleanupModelID.map(AIModelChoice.model) ?? .inherit
                    }, set: { choice in
                        if case .model(let id) = choice { settings.options.cleanupModelID = id }
                        else { settings.options.cleanupModelID = nil }
                    }), inheritTitle: "沿用 AI 命令默认模型", purpose: .cloudText)
                }
                Divider()
                Button { model.openSettings(page: "ai-models") } label: {
                    SettingsRow("配置 AI 模型") { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
                Divider()
                link("个性化与词汇", page: DictationModule.personalizationItem.page)
                Divider()
                link("听写样式", page: DictationModule.stylesItem.page)
            }
            SettingsGroup("历史与隐私") {
                toggle("保留成功听写的录音", detail: "默认关闭。失败录音会保存在本机供重试；删除历史时一并删除对应录音。", path: \.keepRecordings)
                Divider()
                link("使用统计", page: DictationModule.statisticsItem.page)
                Divider()
                Button("打开听写历史") { model.runCommand(.init(rawValue: "dictation-history"), origin: .menu) }
            }
            ExtensionCommandPreferences(model: model, commands: commands)
        }
        .task { microphones = DictationCapture.microphones }
        .onChange(of: settings.options.modifierKey) { _, value in if value != nil { model.setShortcut("dictate", value: nil) } }
    }
    private func toggle(_ title: String, detail: String? = nil, path: WritableKeyPath<DictationOptions, Bool>) -> some View {
        SettingsRow(title, detail: detail) { SettingsInlineSwitch(title: title, isOn: settings.binding(path)) }
    }
    private func link(_ title: String, page: String) -> some View {
        Button { model.settingsPage = page } label: {
            SettingsRow(title) { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
        }.buttonStyle(.plain)
    }
}

struct DictationPersonalization: View {
    @ObservedObject var settings: DictationSettings
    @State private var term = ""
    @State private var error = ""
    var body: some View {
        SettingsPageSections {
            SettingsGroup("全局指令") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsDescription("例如：保留中英混排；产品名固定写为 Keylane。全局指令优先于单独样式。")
                    TextEditor(text: settings.binding(\.instructions)).font(.body).frame(minHeight: 110).padding(5)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }.padding(.vertical, 10)
                Divider()
                SettingsRow("使用应用上下文", detail: "将聚焦输入框附近的文字与应用名称发送给文字整理模型。本次请求后丢弃上下文，不写入历史；需要辅助功能权限。") {
                    SettingsInlineSwitch(title: "使用应用上下文", isOn: settings.binding(\.appContext))
                }
            }.settingsAnchor(DictationModule.personalizationItem)
            SettingsGroup("个人词汇（\(settings.options.validVocabulary.count)／50）") {
                HStack {
                    TextField("人名、产品名、术语，最多 20 个字符", text: $term).textFieldStyle(.roundedBorder).onSubmit(add)
                    Button("添加", action: add).disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("导入…", action: importVocabulary)
                    Button("导出…", action: exportVocabulary)
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                ForEach(settings.options.validVocabulary, id: \.self) { word in
                    Divider()
                    SettingsRow(word) {
                        SettingsIconButton("移除词汇", symbol: "minus") { settings.options.vocabulary.removeAll { $0 == word } }
                    }
                }
            }
        }
    }
    private func add() {
        let value = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 20, value.rangeOfCharacter(from: .controlCharacters) == nil else { error = "每项需为 1–20 个字符。"; return }
        guard settings.options.validVocabulary.count < 50 else { error = "词汇已达到 50 项上限。"; return }
        if !settings.options.vocabulary.contains(value) { settings.options.vocabulary.append(value) }
        term = ""; error = ""
    }
    private func importVocabulary() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 64_000 else { throw AITranscriptionError.responseTooLarge }
            let values = (try? JSONDecoder().decode([String].self, from: data)) ?? String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            var candidate = settings.options; candidate.vocabulary += values
            settings.options.vocabulary = candidate.validVocabulary
            error = "已导入；重复、空白、超长和超过 50 项的词汇已略过。"
        } catch { self.error = "无法导入词汇文件。" }
    }
    private func exportVocabulary() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "dictation-vocabulary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(settings.options.validVocabulary).write(to: url, options: .atomic) }
        catch { self.error = "无法导出词汇文件。" }
    }
}

final class DictationStyleDraft: ObservableObject {
    @Published var style = DictationStyle(name: "", prompt: "")
    @Published var applications = ""
    @Published var websites = ""
    func prepare(_ value: DictationStyle?) {
        style = value ?? .init(name: "", prompt: "")
        applications = style.applications.joined(separator: "\n"); websites = style.websites.joined(separator: "\n")
    }
    var canSave: Bool { !style.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !style.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func save(to settings: DictationSettings) {
        guard canSave else { return }
        style.name = String(style.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        style.applications = applications.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        style.websites = websites.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let index = settings.options.styles.firstIndex(where: { $0.id == style.id }) { settings.options.styles[index] = style }
        else { settings.options.styles.append(style) }
    }
}

struct DictationStylesPreferences: View {
    @ObservedObject var settings: DictationSettings
    let edit: (DictationStyle?) -> Void
    @State private var pendingRemoval: DictationStyle?
    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsRow("按应用与网站自动选择样式", detail: "邮件、消息和自定义规则在录音开始时匹配；全局指令始终优先。") {
                    SettingsInlineSwitch(title: "自动样式", isOn: settings.binding(\.autoStyling))
                }
            }.settingsAnchor(DictationModule.stylesItem)
            SettingsGroup("样式") {
                ForEach(settings.options.styles) { style in
                    SettingsRow(style.name, detail: (style.applications + style.websites).joined(separator: "、")) {
                        Button("编辑") { edit(style) }
                        SettingsIconButton("删除样式", symbol: "minus") { pendingRemoval = style }
                    }
                    Divider()
                }
                Button("创建样式…", systemImage: "plus") { edit(nil) }
            }
        }
        .confirmationDialog("删除这个听写样式？", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("删除", role: .destructive) {
                if let id = pendingRemoval?.id { settings.options.styles.removeAll { $0.id == id } }
                pendingRemoval = nil
            }
        }
    }
}

struct DictationStyleEditor: View {
    @ObservedObject var draft: DictationStyleDraft
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("样式提示词").font(.headline)
                TextEditor(text: $draft.style.prompt).font(.body).padding(10)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                Text("描述格式、语气、标点和分段方式；听写会保留原语言和原意。").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("名称与图标").font(.headline)
                TextField("样式名称", text: $draft.style.name).textFieldStyle(.roundedBorder)
                Picker("图标", selection: $draft.style.symbol) {
                    Label("文字", systemImage: "textformat").tag("textformat")
                    Label("邮件", systemImage: "envelope").tag("envelope")
                    Label("消息", systemImage: "bubble.left").tag("bubble.left")
                    Label("代码", systemImage: "chevron.left.forwardslash.chevron.right").tag("chevron.left.forwardslash.chevron.right")
                }
                Divider()
                Text("应用").font(.headline)
                ForEach(draft.style.applications, id: \.self) { id in
                    HStack {
                        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                        if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().frame(width: 20, height: 20) }
                        Text(url?.deletingPathExtension().lastPathComponent ?? "未安装的应用").lineLimit(1)
                        Spacer()
                        Button("移除应用", systemImage: "minus") {
                            draft.style.applications.removeAll { $0 == id }
                            draft.applications = draft.style.applications.joined(separator: "\n")
                        }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Button("添加应用…", systemImage: "plus") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = true
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK {
                        for url in panel.urls {
                            if let id = Bundle(url: url)?.bundleIdentifier, !draft.style.applications.contains(id) { draft.style.applications.append(id) }
                        }
                        draft.applications = draft.style.applications.joined(separator: "\n")
                    }
                }
                Text("网站域名").font(.headline)
                TextEditor(text: $draft.websites).font(.body).frame(minHeight: 55, maxHeight: 100)
                Text("每行一个，例如 mail.google.com；会匹配其子域名。网站自动识别取决于浏览器提供的辅助功能信息。").font(.caption).foregroundStyle(.secondary)
            }.frame(width: 280)
        }.padding(24)
    }
}

struct DictationStatisticsView: View {
    @ObservedObject var controller: DictationController
    var body: some View {
        let stats = controller.statistics
        SettingsPageSections {
            SettingsGroup("本机听写统计") {
                SettingsRow("听写次数") { Text(stats.sessions.formatted()) }
                Divider()
                SettingsRow("总词数") { Text(stats.words.formatted()) }
                Divider()
                SettingsRow("平均速度") { Text("\(stats.wordsPerMinute) 词／分钟") }
                Divider()
                SettingsRow("估算节省时间", detail: "按每分钟输入 40 词估算，仅在本机计算，不发送使用遥测。") { Text("\(Int(stats.secondsSaved / 60)) 分钟") }
            }.settingsAnchor(DictationModule.statisticsItem)
            SettingsGroup("最近七天") {
                HStack(alignment: .bottom, spacing: 16) {
                    ForEach(Array(stats.activity.enumerated()), id: \.offset) { index, count in
                        VStack {
                            Text(count.formatted()).font(.caption).foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.7))
                                .frame(height: max(3, CGFloat(count) / CGFloat(max(1, stats.activity.max() ?? 1)) * 90))
                            Text(index == 6 ? "今天" : "\(6 - index) 天前").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(.vertical, 14)
            }
        }.task { controller.loadHistory() }
    }
}

/// Uses the same AIModelPicker and AIConfiguration as every other AI surface.
struct DictationTranscriptionPreferences: View {
    @ObservedObject var settings: DictationSettings
    @ObservedObject var configuration: AIConfiguration
    let manageModels: () -> Void
    var body: some View {
        SettingsGroup("云端转写") {
            SettingsDescription("转写与文字整理直接使用 AI 中的模型、接口和钥匙串凭据。录音会发送到所选语音模型，不在这里重复配置。")
                .padding(.vertical, 8)
            Divider()
            SettingsRow("语音转写模型", detail: configuration.state.connections.first { $0.id == settings.options.transcriptionModelID }?.destinationLabel ?? "从 AI 中选择支持语音转写的云端模型。") {
                AIModelPicker(configuration: configuration, selection: Binding(get: {
                    settings.options.transcriptionModelID.map(AIModelChoice.model) ?? .inherit
                }, set: { choice in
                    if case .model(let id) = choice { settings.options.transcriptionModelID = id }
                }), purpose: .transcription)
            }
            Divider()
            Button(action: manageModels) {
                SettingsRow("管理 AI 模型与提供方", detail: "语音模型可自动识别；自定义模型在 AI 编辑页指定「模型用途」。") {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
            Divider()
            SettingsPicker("语言", selection: settings.binding(\.language)) {
                Text("自动识别").tag("auto")
                Text("中文").tag("zh"); Text("English").tag("en"); Text("日本語").tag("ja")
                Text("한국어").tag("ko"); Text("Français").tag("fr"); Text("Deutsch").tag("de")
                Text("Español").tag("es")
            }
        }
    }
}
