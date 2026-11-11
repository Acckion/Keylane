import SwiftUI
import AppKit
import KeylaneCore

struct FileSearchPreferences: View {
    let controller: FileSearchController
    let model: Model
    @StateObject private var observation: SettingsPageObservation

    init(controller: FileSearchController, model: Model) {
        self.controller = controller
        self.model = model
        _observation = StateObject(wrappedValue: SettingsPageObservation([
            SettingsPageObservation.changes(controller.$options),
            SettingsPageObservation.changes(controller.$automaticExclusions),
            SettingsPageObservation.changes(controller.$inaccessible),
            SettingsPageObservation.changes(model.$aliases),
            SettingsPageObservation.changes(model.$bindings),
            SettingsPageObservation.changes(model.fileAI.$commandsEnabled)
        ]))
    }
    @State private var pattern = ""
    @State private var showsIgnoreInfo = false
    @State private var resets = false
    private func option(_ title: String, _ detail: String, _ path: WritableKeyPath<FileSearchOptions,Bool>) -> some View { Toggle(isOn: Binding(get: { controller.options[keyPath:path] }, set: { controller.options[keyPath:path] = $0 })) { SettingsCaption(title: title, detail: detail, style: .inset) }.toggleStyle(SettingsSwitchStyle()).controlSize(.small) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(layout: .inset) {
                HStack(alignment:.top) { SettingsCaption(title: "搜索范围", detail: "添加要搜索的文件夹；通过选择面板授予访问权限。", style: .inset); Spacer(); SettingsAddFolderButton { controller.addScope() } }
                ForEach(controller.options.roots,id:\.self) { path in
                    HStack { Image(systemName:"folder"); Text(path).font(.system(size:12)).lineLimit(2).textSelection(.enabled); Spacer(); Button { controller.addScope(suggested:URL(fileURLWithPath:path)) } label: { Image(systemName:"key") }.buttonStyle(.plain).help("重新选择文件夹以授权"); Button { controller.removeScope(path) } label: { Image(systemName:"minus.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).help("移除搜索范围") }.padding(.vertical,5)
                    Divider().opacity(0.4)
                }
                if !controller.inaccessible.isEmpty {
                    Label("部分目录无法访问。若下载或文稿中的文件缺失，请选择并授权对应文件夹。",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    Button("授权下载文件夹…") { controller.addScope(suggested:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) }.buttonStyle(.glass)
                }
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:4) { Text("忽略规则").font(.system(size:14,weight:.medium)); Text("默认跳过忽略文件指定的项目。").font(.caption).foregroundStyle(.secondary); Button("了解更多…") { showsIgnoreInfo.toggle() }.buttonStyle(.plain).foregroundStyle(.blue) }
                    Spacer(); TextField("添加规则…",text:$pattern).textFieldStyle(.roundedBorder).frame(maxWidth:240).onSubmit { addPattern() }
                    Button { addPattern() } label: { Image(systemName:"plus") }.buttonStyle(.borderless).disabled(pattern.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.padding(.top,8)
                if showsIgnoreInfo { Text("支持 *、?、** 和简单字符组。无斜线规则匹配任意层级的名称；带斜线规则匹配路径。启用忽略文件后读取目录中的 .gitignore、.ignore 和 .rayignore，按目录继承并支持 ! 取消忽略；已忽略的父目录不会继续遍历。不运行 Git 或 Shell 命令。").font(.caption).foregroundStyle(.secondary) }
                ForEach(controller.options.ignorePatterns,id:\.self) { value in
                    HStack { Text(value).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled); Spacer(); Button { controller.options.ignorePatterns.removeAll { $0 == value } } label: { Image(systemName:"minus.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).help("移除规则") }.padding(.vertical,3)
                    Divider().opacity(0.3)
                }
                SettingsCaption(title: "自动排除", detail: "跳过构建输出或依赖缓存。恢复后重新索引该目录。", style: .inset)
                if controller.automaticExclusions.isEmpty { Text("暂无自动排除的目录").font(.caption).foregroundStyle(.tertiary) }
                ForEach(controller.automaticExclusions) { entry in
                    HStack { Image(systemName:"folder"); VStack(alignment:.leading,spacing:4) { Text(entry.path).font(.caption).lineLimit(2); Text(entry.reason + (entry.events > 0 ? " · 已跳过\(entry.events)次文件事件" : "")).font(.caption2).foregroundStyle(.secondary) }; Spacer(); Button("恢复") { controller.restore(entry.path) }.buttonStyle(.glass).controlSize(.small) }
                }
            }.settingsAnchor(.fileSearchScope)
            SettingsCard(layout: .inset) {
                option("在主界面搜索文件","在启动器中直接输入文件名，同时搜索应用、命令和文件；文件搜索页面仍然可用。",\.searchFromLauncher).settingsAnchor(.fileSearchInline)
                Divider()
                option("内容搜索","搜索文字和 PDF 的内容，不仅仅是文件名。仅在开启后读取正文并保存本地文本索引；不会下载 iCloud 占位文件。",\.contentSearch)
                Divider(); option("包含隐藏文件","搜索名称以句点开头的文件；忽略规则仍然生效。",\.includeHidden)
                Divider(); option("使用忽略文件","遵循 .gitignore、.ignore 和 .rayignore。",\.useIgnoreFiles)
                Divider(); option("索引网络与可移除磁盘","包含搜索范围内的网络共享、外接磁盘和虚拟卷。",\.externalVolumes)
                Divider(); option("保留已移除卷的文件","卷断开后保留已索引名称；打开前会提示文件不可用。",\.keepRemovedVolumes)
                Divider(); option("低储存空间时暂停索引","按下一批目录的预计索引大小检查可用空间，并保留128MB余量。",\.enforceDiskSpace)
                Divider(); HStack { SettingsCaption(title: "恢复默认设置", detail: "恢复搜索范围、忽略规则和各项开关；不会删除原文件。", style: .inset); Spacer(); Button("重置…") { resets = true }.buttonStyle(.glass).controlSize(.small) }
            }
            Text("命令").font(.headline).padding(.leading,14)
            SettingsCard(layout: .inset) {
                CommandSettingsRow(title: "搜索文件",
                    model: model, commandID: .init(rawValue: "file-search"),
                    isEnabled: Binding(get: { controller.options.enabled }, set: { controller.options.enabled = $0 }),
                    icon: { Image(systemName: "doc.text.magnifyingglass").font(VisualStyle.actionSymbol) })
            }
            Text("AI 扩展").font(.headline).padding(.leading,14)
            SettingsCard(layout: .inset) {
                aiRow("ask-files")
                Divider()
                aiRow("ask-finder")
                Text("使用你配置的 OpenAI 兼容服务。先查看发送范围并主动发送；API密钥保存至钥匙串，未配置时先填写服务地址与模型。").font(.caption).foregroundStyle(.secondary)
            }
            FileIndexStatistics(controller: controller)
        }.confirmationDialog("恢复文件搜索默认设置？",isPresented:$resets,titleVisibility:.visible) { Button("恢复默认",role:.destructive) { controller.reset() }; Button("取消",role:.cancel) {} }.onAppear { if controller.stats.entries == 0 && !controller.indexing { controller.startIndex() } }
    }
    private func aiRow(_ id: String) -> some View {
        let commandID = CommandID(rawValue: id)
        let declaration = model.launcherModules?.declaration(commandID)
        return CommandSettingsRow(title: declaration?.title ?? id,
            model: model, commandID: commandID,
            isEnabled: Binding(get: { model.fileAI.commandsEnabled[id] != false }, set: { model.fileAI.commandsEnabled[id] = $0 }),
            perform: { model.runCommand(commandID, origin: .menu) },
            icon: { Image(systemName: declaration?.symbol ?? "sparkles").font(VisualStyle.actionSymbol) })
    }

    private func addPattern() { let value = pattern.trimmingCharacters(in:.whitespacesAndNewlines); guard !value.isEmpty, value.utf8.count <= 1024, !controller.options.ignorePatterns.contains(value) else { return }; controller.options.ignorePatterns.append(value); pattern = "" }
}


private struct FileIndexStatistics: View {
    let controller: FileSearchController
    @StateObject private var observation: SettingsPageObservation

    init(controller: FileSearchController) {
        self.controller = controller
        _observation = StateObject(wrappedValue: SettingsPageObservation([
            SettingsPageObservation.changes(controller.$stats),
            SettingsPageObservation.changes(controller.$indexStatus),
            SettingsPageObservation.changes(controller.$indexing)
        ]))
    }

    var body: some View {
        SettingsCard(layout: .inset) {
            HStack { Text("索引统计").font(.headline); Spacer(); Button("重新索引") { controller.startIndex() }.buttonStyle(.glass).controlSize(.small).disabled(controller.indexing) }
            LabeledContent("磁盘占用",value:ByteCountFormatter.string(fromByteCount:Int64(controller.stats.bytes),countStyle:.file))
            LabeledContent("总条目",value:String(controller.stats.entries)); LabeledContent("文件",value:String(controller.stats.files)); LabeledContent("目录",value:String(controller.stats.directories)); LabeledContent("符号链接",value:String(controller.stats.symlinks)); LabeledContent("无法读取",value:String(controller.stats.invalid)); LabeledContent("上次耗时",value:String(format:"%.2f秒",controller.stats.seconds))
            Text(controller.indexStatus).font(.caption).foregroundStyle(.secondary)
        }
    }
}
