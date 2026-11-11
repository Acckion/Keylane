import SwiftUI
import AppKit
import Combine
import KeylaneCore

struct ClipboardHistoryView: View {
    let controller: ClipboardController
    let query: String

    var body: some View {
        ResultDetailLayout {
            ClipboardHistoryList(controller: controller, query: query)
        } detail: {
            ClipboardHistoryDetail(controller: controller)
        }
        .onAppear { controller.reload() }
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
            ViewObservation.changes(controller.$selectedID)
        ]))
    }

    var body: some View {
        SelectableResultList(selection: controller.selectedID, query: query, firstResult: controller.items.first?.id) {
            if controller.items.isEmpty {
                Text("没有匹配记录").font(VisualStyle.sectionText).foregroundStyle(.secondary)
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
                ContentUnavailableView(controller.items.isEmpty ? "暂无匹配记录" : "正在加载", systemImage: "clipboard", description: Text(controller.captureEnabled ? "复制文字、图片或文件后，会自动保存到这台 Mac。" : "采集已关闭。可在剪贴板设置中开启本地历史。"))
                Button("剪贴板设置…") { (NSApp.delegate as? Delegate)?.model.openSettings(page: "clipboard") }
                    .buttonStyle(ContentActionButtonStyle())
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

    init(controller: ClipboardController, model: Model) {
        self.controller = controller
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(controller.$automaticOCR),
            ViewObservation.changes(controller.$primaryAction),
            ViewObservation.changes(controller.$retentionDays),
            ViewObservation.changes(controller.$maxItems),
            ViewObservation.changes(controller.$excludedApps),
            ViewObservation.changes(controller.$accessMessage),
            ViewObservation.changes(model.$bindings.map { $0["clipboard"] })
        ]))
    }

    private func binding<Value>(_ key: ReferenceWritableKeyPath<ClipboardController, Value>) -> Binding<Value> {
        Binding(get: { controller[keyPath: key] }, set: { controller[keyPath: key] = $0 })
    }
    @State private var excludedNames: [String: String] = [:]

    private func updateExcludedNames(_ ids: Set<String>) {
        excludedNames = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path) } ?? id)
        })
    }
    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                Toggle("自动识别新图片中的文字", isOn: binding(\.automaticOCR))
            }
            SettingsGroup {
                SettingsShortcutBindingRow(title: "剪贴板快捷键", shortcut: model.bindings["clipboard"], symbol: "clipboard") {
                    model.setShortcut("clipboard", value: $0)
                }
                Divider()
                SettingsPicker("回车动作", selection: binding(\.primaryAction)) {
                    Text("仅复制").tag("copy")
                    Text("粘贴到上个应用").tag("paste")
                }
                Divider()
                SettingsActionRow(title: "辅助功能", actionTitle: "允许…") { model.requestKeyboardAccess() }
                if !controller.accessMessage.isEmpty {
                    Divider()
                    SettingsActionRow(title: "权限状态", detail: controller.accessMessage, actionTitle: "打开系统设置") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                    }
                }
            }
            SettingsGroup {
                SettingsPicker("保留时间", selection: binding(\.retentionDays)) { Text("7天").tag(7); Text("30天").tag(30); Text("90天").tag(90); Text("1年").tag(365) }
                Divider()
                SettingsPicker("记录上限", selection: binding(\.maxItems)) { Text("100项").tag(100); Text("500项").tag(500); Text("1000项").tag(1000) }
            }
            SettingsCard {
                SettingsRow("不记录这些应用") {
                    Button("添加应用…", systemImage: "plus") { controller.addExcludedApplication() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                SettingsCompactList(items: controller.excludedApps.sorted(), id: \.self) { id in
                    SettingsRow(excludedNames[id] ?? id) {
                        if !ClipboardPolicy.defaultExcluded.contains(id) {
                            Button("移除") { controller.excludedApps.remove(id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
            ClipboardHistoryStatistics(controller: controller)
        }
        .onAppear { updateExcludedNames(controller.excludedApps) }
        .onChange(of: controller.excludedApps) { _, ids in updateExcludedNames(ids) }
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
