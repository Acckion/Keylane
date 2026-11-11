import SwiftUI
import AppKit
import KeylaneCore

struct FileSearchPreferences: View {
    let controller: FileSearchController
    let model: Model
    @StateObject private var observation: ViewObservation

    init(controller: FileSearchController, model: Model) {
        self.controller = controller
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(controller.$options),
            ViewObservation.changes(controller.$automaticExclusions),
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.fileAI.$commandsEnabled)
        ]))
    }
    @State private var pattern = ""
    @State private var showsIgnoreInfo = false
    @State private var resets = false
    private func option(_ title: String, _ detail: String, _ path: WritableKeyPath<FileSearchOptions,Bool>) -> some View { Toggle(isOn: Binding(get: { controller.options[keyPath:path] }, set: { controller.options[keyPath:path] = $0 })) { SettingsRowLabel(title: title, detail: detail) }.toggleStyle(SettingsSwitchStyle()).controlSize(.small) }
    var body: some View {
        SettingsPageSections {
            SettingsSearchScopeCard(
                paths: controller.options.roots,
                detail: "选择要纳入索引的文件夹。",
                anchor: .fileSearchScope,
                add: { controller.addScope() },
                remove: controller.removeScope
            ) { EmptyView() }
            ignoreRules
            SettingsGroup {
                option("内容搜索","搜索文字和 PDF 的内容，不仅仅是文件名。仅在开启后读取正文并保存本地文本索引；不会下载 iCloud 占位文件。",\.contentSearch)
                Divider(); option("包含隐藏文件","搜索名称以句点开头的文件；忽略规则仍然生效。",\.includeHidden)
                Divider(); option("使用忽略文件","遵循 .gitignore、.ignore 和 .rayignore。",\.useIgnoreFiles)
                Divider(); option("索引网络与可移除磁盘","包含搜索范围内的网络共享、外接磁盘和虚拟卷。",\.externalVolumes)
                Divider(); option("保留已移除卷的文件","卷断开后保留已索引名称；打开前会提示文件不可用。",\.keepRemovedVolumes)
                Divider(); option("低储存空间时暂停索引","按下一批目录的预计索引大小检查可用空间，并保留128MB余量。",\.enforceDiskSpace)
                Divider()
                SettingsActionRow(title: "恢复默认设置", detail: "恢复搜索范围、忽略规则和各项开关；不会删除原文件。", actionTitle: "重置…") { resets = true }
            }
            SettingsSectionTitle(title: "命令")
            CommandSettingsList(items: ["file-search"], id: \.self) { id in
                CommandSettingsEntry(title: "搜索文件",
                    model: model, commandID: .init(rawValue: id),
                    icon: { Image(systemName: "doc.text.magnifyingglass").font(VisualStyle.actionSymbol) })
            }
            SettingsSectionTitle(title: "AI 扩展")
            CommandSettingsList(items: ["ask-files", "ask-finder"], id: \.self, entry: aiCommand)
            SettingsDescription("使用你配置的 OpenAI 兼容服务。先查看发送范围并主动发送；API密钥保存至钥匙串，未配置时先填写服务地址与模型。").padding(.horizontal, 14)
            FileIndexStatistics(controller: controller)
        }.confirmationDialog("恢复文件搜索默认设置？",isPresented:$resets,titleVisibility:.visible) { Button("恢复默认",role:.destructive) { controller.reset() }; Button("取消",role:.cancel) {} }.onAppear { if controller.stats.entries == 0 && !controller.indexing { controller.startIndex() } }
    }
    private var pendingRule: String { pattern.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAddRule: Bool {
        !pendingRule.isEmpty && pendingRule.utf8.count <= 1024
            && !controller.options.ignorePatterns.contains(pendingRule)
    }

    private var ignoreRules: some View {
        SettingsListCard(title: "忽略规则", detail: "默认跳过忽略文件指定的项目。") {
            HStack(spacing: 6) {
                SettingsIconButton("了解更多", symbol: "info.circle") { showsIgnoreInfo.toggle() }
                    .accessibilityValue(showsIgnoreInfo ? "已展开" : "已折叠")
                TextField("添加规则…", text: $pattern)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 150)
                    .onSubmit(addPattern)
                SettingsIconButton("添加忽略规则", symbol: "plus", action: addPattern)
                    .disabled(!canAddRule)
            }
        } content: {
            if showsIgnoreInfo {
                SettingsDescription("支持 *、?、** 和简单字符组。无斜线规则匹配任意层级的名称；带斜线规则匹配路径。启用忽略文件后读取目录中的 .gitignore、.ignore 和 .rayignore，按目录继承并支持 ! 取消忽略；已忽略的父目录不会继续遍历。不运行 Git 或 Shell 命令。")
                    .padding(.vertical, 8)
            }
            if controller.options.ignorePatterns.isEmpty {
                SettingsListEmptyState(title: "暂无忽略规则")
            } else {
                SettingsCompactList(items: controller.options.ignorePatterns, id: \.self) { rule in
                    SettingsCompactItemRow(title: rule, symbol: "line.3.horizontal.decrease",
                                           selectable: true, showsActionsOnHover: true) {
                        SettingsRemoveItemButton(label: "移除规则 \(rule)", help: "移除规则") {
                            controller.options.ignorePatterns.removeAll { $0 == rule }
                        }
                    }.help(rule)
                }.padding(.bottom, 5)
            }
            Divider()
            SettingsListHeader(title: "自动排除", detail: "跳过构建输出或依赖缓存。恢复后重新索引该目录。") {
                EmptyView()
            }
            if controller.automaticExclusions.isEmpty {
                SettingsListEmptyState(title: "暂无自动排除的目录")
            } else {
                SettingsCompactList(items: controller.automaticExclusions, id: \.id) { entry in
                    SettingsFolderRow(path: entry.path, detail: exclusionDetail(entry),
                                      selectable: true, showsActionsOnHover: true) {
                        Button("恢复") { controller.restore(entry.path) }
                            .buttonStyle(ContentActionButtonStyle()).controlSize(.small)
                    }
                }.padding(.bottom, 5)
            }
        }
    }

    private func exclusionDetail(_ entry: AutomaticFileExclusion) -> String {
        guard entry.events > 0 else { return entry.reason }
        return entry.reason + " · 已跳过\(entry.events)次文件事件"
    }

    private func aiCommand(_ id: String) -> CommandSettingsEntry<some View> {
        let commandID = CommandID(rawValue: id)
        let declaration = model.launcherModules?.declaration(commandID)
        return CommandSettingsEntry(title: declaration?.title ?? id,
            model: model, commandID: commandID,
            isEnabled: Binding(get: { model.fileAI.commandsEnabled[id] != false }, set: { model.fileAI.commandsEnabled[id] = $0 }),
            perform: { model.runCommand(commandID, origin: .menu) },
            icon: { Image(systemName: declaration?.symbol ?? "sparkles").font(VisualStyle.actionSymbol) })
    }

    private func addPattern() {
        guard canAddRule else { return }
        controller.options.ignorePatterns.append(pendingRule)
        pattern = ""
    }
}


private struct FileIndexStatistics: View {
    let controller: FileSearchController
    @StateObject private var observation: ViewObservation

    init(controller: FileSearchController) {
        self.controller = controller
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(controller.$stats),
            ViewObservation.changes(controller.$indexStatus),
            ViewObservation.changes(controller.$indexing)
        ]))
    }

    var body: some View {
        let stats = controller.stats
        let duration = Duration.seconds(stats.seconds).formatted(.units(
            allowed: [.seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2
        ))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("索引统计").foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("重新索引") { controller.startIndex() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.indexing)
            }
            .padding(.horizontal, 9)
            DetailInformationRows(rows: [
                .init(title: "磁盘占用", value: ByteCountFormatter.string(fromByteCount: Int64(stats.bytes), countStyle: .file)),
                .init(title: "总条目", value: stats.entries.formatted()),
                .init(title: "文件", value: stats.files.formatted()),
                .init(title: "目录", value: stats.directories.formatted()),
                .init(title: "符号链接", value: stats.symlinks.formatted()),
                .init(title: "无法读取", value: stats.invalid.formatted()),
                .init(title: "上次耗时", value: duration)
            ], verticalPadding: 7)
            Text(controller.indexStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
        }
        .font(.system(size: 12))
        .padding(13)
        .modifier(SettingsSurface())
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}
