import AppKit
import KeylaneCore
import UniformTypeIdentifiers

/// File operations never change live controllers: import is staged, then applied at next launch.
enum ConfigurationTransfer {
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
                let preview = try RaycastConfiguration.decode(data, password: password, applicationPaths: paths)
                password = ""; archive = preview.archive; warnings = preview.warnings
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
            let plan = response == .alertSecondButtonReturn ? overwrite : preserve
            guard !plan.changes.isEmpty else { throw ConfigurationError("没有需要导入的更改（可能为空、重复或全部跳过）。") }
            let confirm = NSAlert(); confirm.messageText = "保存导入，随后手动重启 Keylane"
            confirm.informativeText = (plan.messages + ["将先保存受影响配置的本地恢复备份。当前会话继续使用原配置；完全退出后重新打开 Keylane 才生效。可在重启前取消，或生效后撤销上次导入。备份仅保留最近一次，包含受影响的私人内容，请妥善保管。"] ).joined(separator: "\n\n")
            confirm.addButton(withTitle: "保存待处理导入"); confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            let now = current
            let affectedBefore = snapshot.filter { plan.changes[$0.key] != nil }
            let affectedNow = now.filter { plan.changes[$0.key] != nil }
            guard NSDictionary(dictionary: affectedNow).isEqual(to: affectedBefore) else { throw ConfigurationError("预览后相关配置已改变，请重新预览。") }
            try ConfigurationTransaction.stage(changes: plan.changes, current: now, directory: directory)
            notice("已保存待处理导入", "请完全退出并重新打开 Keylane。重启前可取消；不会自动安装、更新应用或改变系统权限。")
        } catch { show(error) }
    }
    static func undo() {
        let alert = NSAlert(); alert.messageText = "撤销上次配置导入？"
        alert.informativeText = "仅在受影响配置仍与上次导入结果一致时恢复。保存撤销后，请完全退出并重新打开 Keylane。"
        alert.addButton(withTitle: "保存撤销"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try ConfigurationTransaction.stageUndo(current: current, directory: directory); notice("已保存撤销", "完全退出并重新打开 Keylane 后恢复上次导入前配置。") }
        catch { show(error) }
    }
    static func cancel() {
        do { try ConfigurationTransaction.cancel(directory: directory, current: current); notice("已处理待处理记录", "未改写当前配置。若导入此前已应用，取消不会撤销它；可使用“撤销上次导入”恢复。") }
        catch { show(error) }
    }
    static func finishPending(defaults: UserDefaults = .standard,
                              domain: String = ConfigurationTransfer.domain,
                              directory: URL = ConfigurationTransfer.directory) {
        do {
            if try ConfigurationTransaction.finish(defaults: defaults, domain: domain, directory: directory) {
                notice("已应用待处理配置", "配置已在启动前恢复。可在高级设置中撤销上次导入；请检查热键与链接是否符合预期。")
            }
        } catch { show(error) }
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
