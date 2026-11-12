import SwiftUI
import AppKit
import Combine
import KeylaneCore

struct ClipboardHistoryView: View {
    let controller: ClipboardController
    let query: String
    @StateObject private var observation: ViewObservation

    init(controller: ClipboardController, query: String) {
        self.controller = controller
        self.query = query
        _observation = StateObject(wrappedValue: ViewObservation([ViewObservation.changes(controller.$textDraft)]))
    }

    var body: some View {
        ResultDetailLayout {
            ClipboardHistoryList(controller: controller, query: query)
        } detail: {
            ClipboardHistoryDetail(controller: controller)
        }
        .onAppear { controller.reload() }
        .sheet(item: Binding(get: { controller.textDraft }, set: { controller.textDraft = $0 })) { draft in
            ClipboardTextEditor(draft: draft, controller: controller)
        }
    }
}

private struct ClipboardTextEditor: View {
    let draft: ClipboardTextDraft
    let controller: ClipboardController
    @State private var text: String
    @State private var error = ""
    @State private var saving = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(draft: ClipboardTextDraft, controller: ClipboardController) {
        self.draft = draft
        self.controller = controller
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑文本").font(.headline)
            LauncherCreationControl(focused: focused) {
                TextEditor(text: $text).scrollContentBackground(.hidden)
                    .frame(minHeight: 185).focused($focused).accessibilityLabel("剪贴板文本")
                    .disabled(saving)
            }
            if draft.hasOtherFormats {
                Text("保存后，这条记录将使用编辑后的纯文本。").font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("保存", action: save).keyboardShortcut(.return, modifiers: .command)
                    .disabled(saving || text.isEmpty)
            }
        }
        .padding(20).frame(width: 500)
        .task {
            await Task.yield()
            focused = true
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        saving = true
        error = ""
        controller.saveEditedText(id: draft.id, text: text) { result in
            saving = false
            switch result {
            case .success: dismiss()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

private struct ClipboardHistoryList: View {
    let controller: ClipboardController
    let query: String
    @StateObject private var observation: ViewObservation

    init(controller: ClipboardController, query: String) {
        self.controller = controller
        self.query = query
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(controller.$items),
            ViewObservation.changes(controller.$selectedID),
            ViewObservation.changes(controller.$indexingImageText)
        ]))
    }

    var body: some View {
        SelectableResultList(selection: controller.selectedID, query: query, firstResult: controller.items.first?.id) {
            if controller.items.isEmpty {
                Text(controller.indexingImageText ? "正在搜索图片文字…" : "没有匹配记录")
                    .font(VisualStyle.sectionText).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 80)
            }
            ForEach(controller.items) { item in
                ResultListButton(id: item.id, action: { controller.select(item.id) }) {
                    ResultListRow(selected: item.id == controller.selectedID) {
                        ClipboardListIcon(item: item, controller: controller)
                    } content: {
                        HighlightedResultText(text: item.preview.replacingOccurrences(of: "\n", with: " "), query: query)
                            .font(VisualStyle.rowText).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }
}

private struct ClipboardHistoryDetail: View {
    let controller: ClipboardController
    @StateObject private var observation: ViewObservation

    init(controller: ClipboardController) {
        self.controller = controller
        _observation = StateObject(wrappedValue: ViewObservation([
            controller.$detail.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ViewObservation.changes(controller.$thumbnail),
            ViewObservation.changes(controller.$items.map(\.isEmpty)),
            ViewObservation.changes(controller.$indexingImageText),
            ViewObservation.changes(controller.$captureEnabled),
            ViewObservation.changes(controller.$status),
            ViewObservation.changes(controller.$accessMessage)
        ]))
    }

    var body: some View {
        if let detail = controller.detail {
            ClipboardDetail(detail: detail, thumbnail: controller.thumbnail,
                            status: controller.status, accessMessage: controller.accessMessage)
                .id(detail.item.id)
        } else {
            VStack(spacing: 10) {
                Spacer()
                if controller.indexingImageText {
                    Text("正在识别历史图片中的文字…").font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView(controller.items.isEmpty ? "暂无匹配记录" : "正在加载", systemImage: "clipboard", description: Text(controller.captureEnabled ? "复制文字、图片或文件后，会自动保存到这台 Mac。" : "采集已关闭。可在剪贴板设置中开启本地历史。"))
                    Button("剪贴板设置…") { (NSApp.delegate as? Delegate)?.model.openSettings(page: "clipboard") }
                        .buttonStyle(ContentActionButtonStyle())
                }
                Spacer()
                if !controller.accessMessage.isEmpty {
                    Text(controller.accessMessage).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16)
                }
                if !controller.status.isEmpty {
                    Text(controller.status).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, VisualStyle.launcherTopInset).padding(.bottom, VisualStyle.launcherBottomInset)
        }
    }
}

struct ClipboardPreferences: View {
    let controller: ClipboardController
    let model: Model
    @StateObject private var observation: ViewObservation
    @State private var showsUniversalDetails = true
    @State private var excludedApplications: [String: URL] = [:]

    init(controller: ClipboardController, model: Model) {
        self.controller = controller
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(controller.$automaticOCR),
            ViewObservation.changes(controller.$accurateOCR),
            ViewObservation.changes(controller.$historyCommandEnabled),
            ViewObservation.changes(controller.$showsHistorySettings),
            ViewObservation.changes(controller.$retentionDays),
            ViewObservation.changes(controller.$excludedApps),
            ViewObservation.changes(model.$aliases.map { $0["clipboard"] }),
            ViewObservation.changes(model.$bindings.map { $0["clipboard"] })
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("保留历史记录", selection: binding(\.retentionDays)) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("3 个月").tag(90)
                    Text("1 年").tag(365)
                }
            }.settingsAnchor(.clipboardRetention)
            SettingsGroup {
                Toggle(isOn: binding(\.automaticOCR)) {
                    SettingsRowLabel(title: "文字识别", detail: "在后台识别图片文字。搜索时也会按需识别尚未处理的历史图片。")
                }
                Divider()
                SettingsPicker("识别模式", detail: "快速模式处理更快，准确模式会使用更多 CPU 资源。",
                               selection: binding(\.accurateOCR)) {
                    Text("快速").tag(false)
                    Text("准确").tag(true)
                }
            }.settingsAnchor(.clipboardRecognition)
            SettingsGroup {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingsTitle("立即保存通用剪贴板内容")
                        if showsUniversalDetails {
                            SettingsDescription("macOS 没有提供单独控制跨设备剪贴板保存时机的公开接口。")
                        }
                        Button(showsUniversalDetails ? "收起" : "了解更多") {
                            showsUniversalDetails.toggle()
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                } control: {
                    Toggle("立即保存通用剪贴板内容", isOn: .constant(false))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(true)
                }
            }
            SettingsListCard(title: "不记录这些应用", detail: "这些应用的剪贴板变化不会记录到历史。", anchor: .clipboardExclusions) {
                SettingsIconButton("添加应用", symbol: "plus") { controller.addExcludedApplication() }
            } content: {
                SettingsCompactList(items: controller.excludedApps.sorted(), id: \.self) { id in
                    SettingsRow {
                        Label {
                            Text(excludedApplications[id].map {
                                FileManager.default.displayName(atPath: $0.path)
                            } ?? id).font(.system(size: 12))
                        } icon: {
                            if let url = excludedApplications[id] {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().scaledToFit().frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "app").frame(width: 16, height: 16)
                            }
                        }
                    } control: {
                        if !ClipboardPolicy.defaultExcluded.contains(id) {
                            SettingsRemoveItemButton(label: "移除应用", help: "从排除列表移除") { controller.excludedApps.remove(id) }
                        }
                    }
                }
            }
            SettingsSectionTitle(title: "命令")
            CommandSettingsList(items: ["clipboard", "paste-sequentially", "reset-paste-sequence"], id: \.self) { id in
                switch id {
                case "clipboard":
                    historyCommandEntry { controller.showsHistorySettings = true }
                case "paste-sequentially":
                    unavailableCommand("顺序粘贴", symbol: "list.clipboard")
                default:
                    unavailableCommand("重置粘贴顺序", symbol: "arrow.counterclockwise")
                }
            }
            SettingsSectionTitle(title: "AI 扩展")
            CommandSettingsList(items: ["询问剪贴板"], id: \.self) { title in
                unavailableCommand(title, symbol: "sparkles")
            }
        }
        .onAppear { updateExcludedApplications() }
        .onChange(of: controller.excludedApps) { _, _ in updateExcludedApplications() }
        .sheet(isPresented: binding(\.showsHistorySettings)) { historySettings }
    }

    private var historySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsTitle("剪贴板历史")
            CommandSettingsList(items: ["clipboard"], id: \.self) { _ in historyCommandEntry() }
            ClipboardHistoryStatistics(controller: controller)
            Button("完成") { controller.showsHistorySettings = false }
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20).frame(width: 480)
        .environment(\.isEnabled, true)
    }

    private func historyCommandEntry(perform: (() -> Void)? = nil) -> CommandSettingsEntry<SettingsIcon> {
        CommandSettingsEntry(title: "剪贴板历史", model: model, commandID: .init(rawValue: "clipboard"),
                             isEnabled: binding(\.historyCommandEnabled), perform: perform) {
            SettingsIcon(symbol: "clipboard", artwork: ModuleArtwork.settings("clipboard"))
        }
    }

    private func unavailableCommand(_ title: String, symbol: String) -> CommandSettingsEntry<SettingsIcon> {
        CommandSettingsEntry(title: title, alias: .constant(""), shortcut: nil, isEnabled: .constant(false),
                             setShortcut: { _ in }, icon: { SettingsIcon(symbol: symbol) }, available: false)
    }

    private func binding<Value>(_ key: ReferenceWritableKeyPath<ClipboardController, Value>) -> Binding<Value> {
        Binding(get: { controller[keyPath: key] }, set: { controller[keyPath: key] = $0 })
    }

    private func updateExcludedApplications() {
        excludedApplications = Dictionary(uniqueKeysWithValues: controller.excludedApps.compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { (id, $0) }
        })
    }
}

private struct ClipboardHistoryStatistics: View {
    let controller: ClipboardController
    @StateObject private var observation: ViewObservation
    @State private var confirmsClear = false
    @State private var clearAll = false

    init(controller: ClipboardController) {
        self.controller = controller
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(controller.$total),
            ViewObservation.changes(controller.$migrationBackupCount),
            ViewObservation.changes(controller.$status)
        ]))
    }

    var body: some View {
        SettingsGroup {
            LabeledContent("已保存", value: "\(controller.total)项")
            if controller.migrationBackupCount > 0 { SettingsDescription("保留了\(controller.migrationBackupCount)份升级前备份，包含旧历史与自有图片。清理全部历史时会一并删除；清理未置顶历史时保留备份。") }
            HStack { Button("清理未置顶历史…", role: .destructive) { clearAll = false; confirmsClear = true }; Button("清理全部历史…", role: .destructive) { clearAll = true; confirmsClear = true } }.buttonStyle(ContentActionButtonStyle())
            if !controller.status.isEmpty { Text(controller.status).font(.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog("清理剪贴板历史？", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button(clearAll ? "删除全部记录、历史图片及升级备份" : "删除未置顶记录及历史图片", role: .destructive) { controller.clear(includePinned: clearAll) }
            Button("取消", role: .cancel) {}
        } message: { Text("此操作无法撤销。原文件和当前剪贴板内容不会被删除。") }
    }
}
