import AppKit
import KeylaneCore
import UniformTypeIdentifiers

/// File operations never change live controllers: import is staged, then applied at next launch.
enum ConfigurationTransfer {
    static var root: URL { directory.deletingLastPathComponent() }
    /// Keep expensive decryption/snapshot construction off the UI thread while modal input is blocked.
    private final class Preparation<Value>: @unchecked Sendable { var result: Result<Value, Error>? }
    static func preparing<T>(_ title: String, _ operation: @escaping () throws -> T) throws -> T {
        let box = Preparation<T>()
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = "正在本机只读解析并准备预览，不改写现有资料。请稍候。"
        alert.addButton(withTitle: "正在处理…"); alert.buttons.first?.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try operation() }
            DispatchQueue.main.async { box.result = result; NSApp.abortModal() }
        }
        alert.runModal(); alert.window.orderOut(nil)
        guard let result = box.result else { throw ConfigurationError("准备预览被中断，未保存导入。") }
        return try result.get()
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keylane/ConfigurationRecovery", isDirectory: true)
    }
    static var domain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }
    static var current: [String: Any] { UserDefaults.standard.persistentDomain(forName: domain) ?? [:] }

    static func export() {
        (NSApp.delegate as? Delegate)?.hideLauncher()
        let alert = NSAlert()
        alert.messageText = "导出 Keylane 配置"
        alert.informativeText = "默认导出外观、启动器、键盘行为、命令热键及禁用状态。可另外包含别名和 Quicklinks（可能包含私人路径、URL 参数或自行填入的秘密）。热键命令标识也可能包含本地路径。文件不加密，请检查后再分享。\n\n不包含密码/API 密钥/令牌存储、权限、Hyper Key/双击修饰键、数据库、片段、历史、搜索目录及扩展设置。"
        alert.addButton(withTitle: "仅导出基本配置")
        alert.addButton(withTitle: "包含别名和 Quicklinks")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Keylane-configuration.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ConfigurationArchive.capture(.standard, includePersonalContent: response == .alertSecondButtonReturn).data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { show(error) }
    }

    static func restore(raycast: Bool = false) {
        (NSApp.delegate as? Delegate)?.hideLauncher()
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "rayconfig") ?? .data]
        panel.message = raycast
            ? "先在 Raycast Settings → Advanced → Export 导出 .rayconfig，或导出 Quicklinks JSON。选择文件后本地解析；不会读取 Raycast 私有数据库。"
            : "选择 Keylane configuration v2 或旧版基础设置 v1 JSON。先预览，再决定是否覆盖冲突。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ConfigurationTransaction.read(url)
            var archive: ConfigurationArchive, warnings: [String] = []
            var migration = RaycastMigrationData()
            if raycast {
                var password = ""
                if (try? JSONSerialization.jsonObject(with: data)) == nil {
                    let prompt = NSAlert(); prompt.messageText = "Raycast 备份密码"
                    prompt.informativeText = "输入导出备份时设置的密码。仅在本机内存解密，不保存密码，不把原始备份写入临时文件。"
                    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
                    prompt.accessoryView = field; prompt.addButton(withTitle: "解析"); prompt.addButton(withTitle: "取消")
                    guard prompt.runModal() == .alertFirstButtonReturn else { return }
                    password = field.stringValue; field.stringValue = ""
                }
                let paths = Set((NSApp.delegate as? Delegate)?.model.apps.map(\.path) ?? [])
                let localPassword = password; password = ""
                let preview = try preparing("解析 Raycast 备份") { try RaycastConfiguration.decode(data, password: localPassword, applicationPaths: paths) }
                archive = preview.archive; warnings = preview.warnings; migration = preview.data
                guard chooseCategories(archive: &archive, data: &migration) else { return }
            } else { archive = try ConfigurationArchive.decode(data) }
            guard let model = (NSApp.delegate as? Delegate)?.model, let registry = model.launcherModules else {
                throw ConfigurationError("命令目录不可用，无法安全预览配置。")
            }
            let snapshot = current
            let exclusions = registry.independentlyEnabledCommandIDs
            warnings.append("具有独立开关的命令（例如剪贴板、相机和 AI）的启用状态不迁移，避免间接改变权限或未备份的偏好。")
            let preserve = try archive.plan(current: snapshot, overwrite: false, excludingCommandStates: exclusions, templateContext: model.snippets.templateContext(interactive: false))
            let overwrite = try archive.plan(current: snapshot, overwrite: true, excludingCommandStates: exclusions, templateContext: model.snippets.templateContext(interactive: false))
            let selection = NSAlert(); selection.messageText = "导入预览"
            selection.informativeText = "先检查范围与限制，再选择冲突策略。此步骤不写入配置。"
            selection.accessoryView = previewText((preserve.messages + warnings + ["覆盖仅更新文件中提供的项目，不清空其他配置。热键冲突一律跳过；系统保留热键需重启后检查。选择后还会显示最终更改范围。"]).joined(separator: "\n\n"))
            selection.addButton(withTitle: "保留现有冲突项")
            selection.addButton(withTitle: "覆盖同名配置")
            selection.addButton(withTitle: "取消")
            let response = selection.runModal()
            guard response != .alertThirdButtonReturn else { return }
            let replacing = response == .alertSecondButtonReturn
            let plan = replacing ? overwrite : preserve
            let selectedData = migration
            let destination = root
            let prepared: RaycastDataMigration.Prepared
            if raycast && selectedData.hasData {
                prepared = try preparing("准备数据合并预览") { try RaycastDataMigration.prepare(selectedData, current: snapshot, root: destination, overwrite: replacing) }
            } else { prepared = .init() }
            var changes = plan.changes
            changes.merge(prepared.changes) { _, new in new }
            guard !changes.isEmpty || !prepared.resources.isEmpty else { throw ConfigurationError("没有需要导入的更改（可能为空、重复或全部跳过）。") }
            let confirm = NSAlert(); confirm.messageText = raycast ? "保存导入并退出 Keylane" : "保存导入，随后手动重启 Keylane"
            confirm.accessoryView = previewText((plan.messages + prepared.messages).joined(separator: "\n\n"))
            confirm.informativeText = "将先保存受影响配置与资料的本地恢复备份。" + (raycast ? "保存后立即退出，重新打开 Keylane 时应用导入。" : "当前会话继续使用原配置，请完全退出后重新打开。") + "可在生效后撤销上次导入。备份仅保留最近一次，包含受影响的私人内容，请妥善保管。"
            confirm.addButton(withTitle: raycast ? "保存并退出 Keylane" : "保存待处理导入"); confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            let now = current
            let affectedBefore = snapshot.filter { changes[$0.key] != nil }
            let affectedNow = now.filter { changes[$0.key] != nil }
            guard NSDictionary(dictionary: affectedNow).isEqual(to: affectedBefore) else { throw ConfigurationError("预览后相关配置已改变，请重新预览。") }
            if raycast {
                for resource in prepared.resources {
                    guard try RaycastMigrationTransaction.canApply(resource, current: RaycastMigrationTransaction.snapshot(resource.id, root: root)) else { throw ConfigurationError("预览后相关资料已改变，请重新预览。") }
                }
                try RaycastMigrationTransaction.stage(changes: changes, current: now, resources: prepared.resources, directory: directory)
            } else {
                guard !RaycastMigrationTransaction.hasPending(in: directory) else { throw ConfigurationError("已有待处理 Raycast 导入，请先完成或取消。") }
                try ConfigurationTransaction.stage(changes: changes, current: now, directory: directory)
            }
            if raycast { NSApp.terminate(nil); return }
            notice("已保存待处理导入", "请完全退出并重新打开 Keylane。重启前可取消；不会自动安装、更新应用或改变系统权限。")
        } catch { show(error) }
    }
    static func undo() {
        let alert = NSAlert(); alert.messageText = "撤销上次配置导入？"
        alert.informativeText = "仅在受影响配置仍与上次导入结果一致时恢复。保存撤销后，请完全退出并重新打开 Keylane。"
        alert.addButton(withTitle: "保存撤销"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if RaycastMigrationTransaction.canUndo(in: directory) { try RaycastMigrationTransaction.stageUndo(directory: directory, root: root, current: current) }
            else { try ConfigurationTransaction.stageUndo(current: current, directory: directory) }
            notice("已保存撤销", "完全退出并重新打开 Keylane 后恢复上次导入前配置。") }
        catch { show(error) }
    }
    static func cancel() {
        do {
            if RaycastMigrationTransaction.hasPending(in: directory) { try RaycastMigrationTransaction.cancel(directory: directory, root: root, current: current) }
            else { try ConfigurationTransaction.cancel(directory: directory, current: current) }
            notice("已处理待处理记录", "未改写当前配置。若导入此前已应用，取消不会撤销它；可使用“撤销上次导入”恢复。") }
        catch { show(error) }
    }
    static func finishPending(defaults: UserDefaults = .standard,
                              domain: String = ConfigurationTransfer.domain,
                              directory: URL = ConfigurationTransfer.directory) {
        do {
            if RaycastMigrationTransaction.hasPending(in: directory) {
                // Do not open controllers against partially migrated stores after a failed replay.
                do {
                    _ = try RaycastMigrationTransaction.finish(directory: directory, root: directory.deletingLastPathComponent(),
                        read: { defaults.persistentDomain(forName: domain) ?? [:] }, persist: { value in
                            defaults.setPersistentDomain(value, forName: domain); return defaults.synchronize()
                        })
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("last-import.plist"))
                    notice("已应用 Raycast 导入", "资料已在启动前合并。请检查导入结果；可在高级设置中撤销上次导入。")
                } catch {
                    let alert = NSAlert(); alert.messageText = "Raycast 导入尚未完成"
                    alert.informativeText = (error as? ConfigurationError)?.errorDescription ?? "迁移无法完成，恢复记录已保留。"
                    alert.addButton(withTitle: "退出，保留恢复记录")
                    let canCancel = !RaycastMigrationTransaction.hasStarted(in: directory)
                    if canCancel { alert.addButton(withTitle: "取消此次导入并继续启动") }
                    if alert.runModal() == .alertSecondButtonReturn, canCancel {
                        try RaycastMigrationTransaction.cancel(directory: directory, root: directory.deletingLastPathComponent(), current: defaults.persistentDomain(forName: domain) ?? [:])
                    } else { exit(EXIT_FAILURE) }
                }
            }
            if try ConfigurationTransaction.finish(defaults: defaults, domain: domain, directory: directory) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("raycast-last.plist"))
                notice("已应用待处理配置", "配置已在启动前恢复。可在高级设置中撤销上次导入；请检查热键与链接是否符合预期。")
            }
        } catch { show(error) }
    }
    private static func chooseCategories(archive: inout ConfigurationArchive, data: inout RaycastMigrationData) -> Bool {
        let counts = [archive.preferences.count + (archive.aliases?.count ?? 0) + (archive.shortcuts?.count ?? 0) + (archive.commandEnabled?.count ?? 0),
                      archive.quicklinks?.count ?? 0, data.snippets.count, data.clips.count, data.chats.count,
                      data.commands.count, data.emoji.count, data.focusCategories.count]
        let names = ["设置、命令别名与快捷键", "Quicklinks", "文本片段", "文本剪贴板历史", "AI 文本聊天（只读历史）", "AI 自定义命令", "Emoji 使用记录与关键词", "专注分类"]
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let buttons = zip(names, counts).map { name, count -> NSButton in
            let button = NSButton(checkboxWithTitle: "\(name)：\(count) 项可转换", target: nil, action: nil)
            button.state = count > 0 ? .on : .off; button.isEnabled = count > 0; stack.addArrangedSubview(button); return button
        }
        stack.frame = NSRect(x: 0, y: 0, width: 500, height: CGFloat(buttons.count * 28))
        let alert = NSAlert(); alert.messageText = "选择 Raycast 导入项目"
        alert.informativeText = "只列出当前可转换的内容。笔记暂不处理；其他不支持的数据只在预览和支持文档中说明，不保存其原始内容。"
        alert.accessoryView = stack; alert.addButton(withTitle: "继续预览"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if buttons[0].state != .on { archive.preferences = [:]; archive.aliases = nil; archive.shortcuts = nil; archive.commandEnabled = nil; archive.disabledCommands = nil }
        if buttons[1].state != .on { archive.quicklinks = nil }
        if buttons[2].state != .on { data.snippets = [] }
        if buttons[3].state != .on { data.clips = [] }
        if buttons[4].state != .on { data.chats = [] }
        if buttons[5].state != .on { data.commands = [] }
        if buttons[6].state != .on { data.emoji = [] }
        if buttons[7].state != .on { data.focusCategories = [] }
        return true
    }
    static func previewText(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.string = text; scroll.documentView = view
        return scroll
    }
    private static func notice(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.runModal()
    }
    private static func show(_ error: Error) {
        // Decoding errors may describe input values; never surface/log raw file contents.
        let text = (error as? ConfigurationError)?.errorDescription ?? "文件格式损坏、数据不受支持或无法访问文件。未完成导入；请检查文件和本地恢复目录。"
        notice("配置操作未完成", text)
    }
}
