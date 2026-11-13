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
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(controller.$textDraft),
            ViewObservation.changes(controller.$items.map(\.isEmpty)),
            ViewObservation.changes(controller.$searching),
            ViewObservation.changes(controller.$indexingImageText),
            ViewObservation.changes(controller.$captureEnabled),
            ViewObservation.changes(controller.$accessMessage),
            ViewObservation.changes(controller.$status)
        ]))
    }

    private var clipboardEmptyMessage: String {
        controller.captureEnabled ? "复制文字、图片或文件后，会自动保存到这台 Mac。" : "采集已关闭。可在剪贴板设置中开启本地历史。"
    }

    var body: some View {
        ResultDetailLayout(hasResults: !controller.items.isEmpty) {
            ClipboardHistoryList(controller: controller, query: query)
        } detail: {
            ClipboardHistoryDetail(controller: controller)
        } emptyState: {
            VStack(spacing: 12) {
                if controller.searching || controller.indexingImageText {
                    Text(controller.indexingImageText ? "正在搜索图片文字…" : "正在搜索剪贴板…")
                        .font(VisualStyle.rowText).foregroundStyle(.secondary)
                } else {
                    ResultDetailEmptyState(title: query.isEmpty ? "没有剪贴板记录" : "没有匹配结果",
                                           message: query.isEmpty ? clipboardEmptyMessage : nil)
                    if query.isEmpty || !controller.captureEnabled {
                        Button("剪贴板设置…") { (NSApp.delegate as? Delegate)?.model.openSettings(page: "clipboard") }
                            .buttonStyle(ContentActionButtonStyle())
                    }
                }
            }
        }
        .onAppear { controller.reload() }
        .onReceive(controller.$status.combineLatest(controller.$accessMessage)
            .map { status, accessMessage in accessMessage.isEmpty ? status : accessMessage }
            .removeDuplicates()) { message in
                guard !message.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let delegate = NSApp.delegate as? Delegate,
                          delegate.model.footerFeedback.current?.message != message else { return }
                    delegate.showLauncherFeedback(message, style: .failure)
                }
            }
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
            ViewObservation.changes(controller.$indexingImageText),
            ViewObservation.changes(controller.$showsLinkVisuals)
        ]))
    }

    var body: some View {
        let calendar = Calendar.current
        let now = Date()
        let groups = Dictionary(grouping: controller.items) {
            ClipboardHistoryPeriod(item: $0, now: now, calendar: calendar)
        }
        let periods = ClipboardHistoryPeriod.allCases.filter { groups[$0] != nil }
        SelectableResultList(selection: controller.selectedID, query: query, firstResult: periods.first?.scrollID) {
            ForEach(periods, id: \.self) { period in
                ResultListSection(title: period.rawValue, isFirst: period == periods.first) {
                    ForEach(groups[period, default: []]) { item in
                        ResultListButton(id: item.id, action: { controller.select(item.id) }) {
                            ResultListRow(selected: item.id == controller.selectedID) {
                                ClipboardListIcon(item: item, controller: controller, showsLinkVisuals: controller.showsLinkVisuals)
                            } content: {
                                HighlightedResultText(text: item.preview.replacingOccurrences(of: "\n", with: " "), query: query)
                                    .font(VisualStyle.rowText).lineLimit(1).truncationMode(.middle)
                                    .accessibilityValue(item.fileCount > 1 ? "\(item.fileCount) 个文件" : "")
                            }
                        }
                    }
                }
                .id(period.scrollID)
            }
        }
    }
}

private enum ClipboardHistoryPeriod: String, CaseIterable {
    case pinned = "已置顶"
    case today = "今天"
    case yesterday = "昨天"
    case week = "这周"
    case month = "这个月"
    case year = "今年"
    case earlier = "更早"

    var scrollID: String { "clipboard-period-" + rawValue }

    init(item: ClipItem, now: Date, calendar: Calendar) {
        if item.pinned { self = .pinned }
        else if calendar.isDate(item.lastUsedAt, inSameDayAs: now) { self = .today }
        else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                calendar.isDate(item.lastUsedAt, inSameDayAs: yesterday) { self = .yesterday }
        else if calendar.isDate(item.lastUsedAt, equalTo: now, toGranularity: .weekOfYear) { self = .week }
        else if calendar.isDate(item.lastUsedAt, equalTo: now, toGranularity: .month) { self = .month }
        else if calendar.isDate(item.lastUsedAt, equalTo: now, toGranularity: .year) { self = .year }
        else { self = .earlier }
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
            ViewObservation.changes(controller.$loadingDetail),
            ViewObservation.changes(controller.$showsLinkVisuals)
        ]))
    }

    var body: some View {
        if let detail = controller.detail {
            ClipboardDetail(detail: detail, thumbnail: controller.thumbnail,
                            showsLinkVisuals: controller.showsLinkVisuals)
                .id(detail.item.id)
        } else if controller.loadingDetail {
            Text("正在加载预览…").font(VisualStyle.rowText).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ClipboardPreferences: View {
    let controller: ClipboardController
    let model: Model
    @StateObject private var observation: ViewObservation
    @State private var excludedApplications: [String: URL] = [:]

    init(controller: ClipboardController, model: Model) {
        self.controller = controller
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(controller.$savesUniversalClipboardImmediately),
            ViewObservation.changes(controller.$automaticOCR),
            ViewObservation.changes(controller.$accurateOCR),
            ViewObservation.changes(controller.$historyCommandEnabled),
            ViewObservation.changes(controller.$showsHistorySettings),
            ViewObservation.changes(controller.$primaryAction),
            ViewObservation.changes(controller.$prefersPlainText),
            ViewObservation.changes(controller.$updatesHistoryAfterReplay),
            ViewObservation.changes(controller.$showsLinkVisuals),
            ViewObservation.changes(controller.$retentionDays),
            ViewObservation.changes(controller.$excludedApps),
            ViewObservation.changes(controller.$sequenceTimeout),
            ViewObservation.changes(controller.$sequenceAddsNewline),
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands)
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
                SettingsRow("立即保存通用剪贴板内容",
                            detail: "自动保存通过通用剪贴板传来的文字、链接和图片。可读取的文件会保存副本。受 macOS 保护的文件可使用当前通用剪贴板粘贴。") {
                    Toggle("立即保存通用剪贴板内容", isOn: binding(\.savesUniversalClipboardImmediately))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
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
            SettingsSectionTitle(title: "命令").settingsAnchor(.clipboardReplay)
            CommandSettingsList(items: ["clipboard", ClipboardSequenceCommand.paste.rawValue,
                                        ClipboardSequenceCommand.reset.rawValue], id: \.self) { id in
                if let command = ClipboardSequenceCommand(rawValue: id) {
                    sequenceCommandEntry(command)
                } else {
                    historyCommandEntry { controller.showsHistorySettings = true }
                }
            }
            SettingsGroup {
                SettingsPicker("顺序超时", detail: "超过所选间隔后，下次粘贴会从最新复制的记录开始。",
                               selection: binding(\.sequenceTimeout)) {
                    ForEach(ClipboardController.sequenceTimeouts, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分钟").tag(seconds)
                    }
                }
                Divider()
                Toggle(isOn: binding(\.sequenceAddsNewline)) {
                    SettingsRowLabel(title: "文字末尾追加换行", detail: "顺序粘贴单个文字项目时使用纯文本并追加一行。")
                }
            }
            .disabled(model.disabledCommands.contains(ClipboardSequenceCommand.paste.rawValue))
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
            SettingsGroup {
                SettingsPicker("回车动作", selection: binding(\.primaryAction)) {
                    Text("粘贴到当前应用").tag(ClipboardPrimaryAction.paste)
                    Text("复制到剪贴板").tag(ClipboardPrimaryAction.copy)
                }
                Divider()
                Toggle(isOn: binding(\.prefersPlainText)) {
                    SettingsRowLabel(title: "优先粘贴纯文本", detail: "默认粘贴时去除文字格式。图片、文件及多项目仍使用原始格式。")
                }
                Divider()
                Toggle(isOn: binding(\.showsLinkVisuals)) {
                    SettingsRowLabel(title: "显示链接预览和网站图标", detail: "开启后会向对应网站请求预览信息。")
                }
                Divider()
                Toggle(isOn: binding(\.updatesHistoryAfterReplay)) {
                    SettingsRowLabel(title: "复制或粘贴后移到顶部", detail: "更新列表顺序，保留原复制时间和置顶顺序。")
                }
            }
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

    private func sequenceCommandEntry(_ command: ClipboardSequenceCommand) -> CommandSettingsEntry<SettingsIcon> {
        let id = CommandID(rawValue: command.rawValue)
        return CommandSettingsEntry(title: command.title, model: model, commandID: id, isEnabled: Binding(
            get: { !model.disabledCommands.contains(command.rawValue) },
            set: { enabled in
                if enabled { model.disabledCommands.remove(command.rawValue) }
                else { model.disabledCommands.insert(command.rawValue) }
            }
        )) {
            SettingsIcon(symbol: command.symbol)
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
