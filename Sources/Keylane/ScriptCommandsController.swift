import AppKit
import Combine
import KeylaneCore
import SwiftUI

final class ScriptCommandsController: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            preferences.set(enabled, forKey: "scriptCommands.enabled")
            if enabled { refresh(force: true) }
            else {
                scanRevision += 1
                scanning = false
                inlineDue.removeAll()
                inlineOutput.removeAll()
            }
        }
    }
    @Published var fallbackID: String {
        didSet { preferences.set(fallbackID, forKey: "scriptCommands.fallback") }
    }
    @Published var searchSelection = 0
    @Published private(set) var folders: [String]
    @Published private(set) var entries: [ScriptCommand] = []
    @Published private(set) var unavailable: [String] = []
    @Published private(set) var scanning = false
    @Published var disabled: Set<String> {
        didSet { preferences.set(Array(disabled), forKey: "scriptCommands.disabled") }
    }
    @Published private(set) var selected: ScriptCommand?
    @Published private(set) var runningScript: ScriptCommand?
    var running: Bool { runningScript != nil }
    @Published private(set) var result: ScriptRunner.Result?
    @Published private(set) var error = ""
    @Published var arguments = ""
    @Published var argumentValues: [String] = []
    @Published private(set) var liveOutput = ""
    @Published private(set) var inlineOutput: [String: String] = [:]
    @Published var draft = ScriptMetadata()
    @Published var template: ScriptTemplate = .bash
    @Published var includeArgument = false
    @Published var draftChoiceText: [String] = []
    @Published private(set) var creationError = ""
    private var inlineDue: [String: TimeInterval] = [:]
    private var inlineTimer: Timer?
    @Published var directory = ""
    @Published var timeout = "30"

    private let preferences: UserDefaults
    private let scanner = DispatchQueue(label: "org.keylane.scripts.scan", qos: .utility)
    private let worker = DispatchQueue(label: "org.keylane.scripts.run", qos: .userInitiated)
    private var scanRevision = 0
    private var lastScan = Date.distantPast
    private var cancellation: DispatchWorkItem?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        fallbackID = preferences.string(forKey: "scriptCommands.fallback") ?? ""
        enabled = preferences.object(forKey: "scriptCommands.enabled") as? Bool ?? true
        folders = Self.canonicalFolders(preferences.stringArray(forKey: "scriptCommands.folders") ?? [])
        disabled = Set(preferences.stringArray(forKey: "scriptCommands.disabled") ?? [])
    }

    func refresh(force: Bool = false, completion: ((Int) -> Void)? = nil) {
        guard enabled, force || (!scanning && Date().timeIntervalSince(lastScan) > 15) else { return }
        lastScan = Date()
        scanRevision += 1
        let revision = scanRevision
        let paths = folders
        scanning = !paths.isEmpty
        scanner.async { [weak self] in
            let catalog = ScriptCommand.discover(in: paths)
            DispatchQueue.main.async {
                guard let self, self.scanRevision == revision else { return }
                if self.entries != catalog.commands {
                    let incoming = Dictionary(uniqueKeysWithValues: catalog.commands.map { ($0.id, $0) })
                    let unchanged = Set(self.entries.filter { incoming[$0.id] == $0 }.map(\.id))
                    self.inlineDue = self.inlineDue.filter { unchanged.contains($0.key) }
                    self.inlineOutput = self.inlineOutput.filter { unchanged.contains($0.key) }
                    self.entries = catalog.commands
                }
                self.unavailable = catalog.unavailable
                self.scanning = false
                completion?(catalog.commands.count)
            }
        }
    }

    func prepareCreation() {
        draft = ScriptMetadata()
        draft.author = NSUserName()
        draft.refreshTime = "1m"
        template = .bash
        includeArgument = false
        draftChoiceText = []
        creationError = ""
    }

    func addDraftArgument() {
        guard draft.arguments.count < 3 else { return }
        draftChoiceText.append("")
        draft.arguments.append(.init(placeholder: "参数 \(draft.arguments.count + 1)"))
    }

    func removeDraftArgument(at index: Int) {
        draft.arguments.remove(at: index)
        draftChoiceText.remove(at: index)
    }

    func saveDraft() {
        guard enabled else { return }
        creationError = ""
        let name = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { creationError = "请填写命令标题。"; return }
        var metadata = draft
        if includeArgument && metadata.arguments.isEmpty {
            metadata.arguments = [.init(placeholder: "参数")]
        }
        if !includeArgument { metadata.arguments = [] }
        for index in metadata.arguments.indices where metadata.arguments[index].type == .dropdown {
            let choices = draftChoiceText[index].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            guard !choices.isEmpty, Set(choices).count == choices.count else {
                creationError = "下拉参数至少需要一个选项，且选项不能重复。"
                return
            }
            metadata.arguments[index].data = choices.map { .init(title: $0, value: $0) }
        }
        guard metadata.arguments.allSatisfy({ !$0.placeholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            creationError = "请填写每个参数的占位提示。"
            return
        }
        if metadata.mode == .inline {
            guard metadata.refreshInterval != nil, metadata.arguments.isEmpty else {
                creationError = "行内模式需要有效刷新间隔，且不接受参数。"
                return
            }
        }
        let panel = NSSavePanel()
        panel.title = "创建脚本命令"
        let filename = String(name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(80))
        panel.nameFieldStringValue = filename + "." + template.fileExtension
        panel.message = "保存位置会加入脚本搜索范围。"
        panel.directoryURL = folders.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try template.create(at: url, metadata: metadata)
            let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            if folders.contains(where: { folder == $0 || folder.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
                refresh(force: true)
            } else {
                setFolders(folders + [folder])
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            creationError = "无法创建脚本：\(error.localizedDescription)"
            (NSApp?.delegate as? Delegate)?.toast.show(creationError, style: .failure)
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        setFolders(folders + panel.urls.map(\.path))
    }

    func removeFolder(_ path: String) {
        setFolders(folders.filter { $0 != path })
    }

    private func setFolders(_ paths: [String]) {
        folders = Self.canonicalFolders(paths)
        entries = entries.filter { command in folders.contains { Self.contains(command, in: $0) } }
        preferences.set(folders, forKey: "scriptCommands.folders")
        refresh(force: true)
    }

    private static func canonicalFolders(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().path }
            .filter { seen.insert($0).inserted }
    }

    private static func contains(_ command: ScriptCommand, in folder: String) -> Bool {
        command.url.path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    func commandEnabledBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !self.disabled.contains(id) }, set: { enabled in
            if enabled { self.disabled.remove(id) }
            else { self.disabled.insert(id) }
        })
    }

    func canRun(_ script: ScriptCommand) -> Bool {
        enabled && !disabled.contains(script.id) && folders.contains { Self.contains(script, in: $0) }
    }

    var fallbackEntries: [ScriptCommand] {
        entries.filter { script in
            guard let args = script.metadata?.arguments else { return false }
            return args.first?.kind == .text && args.dropFirst().allSatisfy { $0.optional == true }
        }
    }

    var fallback: ScriptCommand? {
        fallbackEntries.first { $0.id == fallbackID && canRun($0) }
    }

    func select(_ script: ScriptCommand) {
        guard !running else { return }
        selected = script
        arguments = ""
        argumentValues = Array(repeating: "", count: script.metadata?.arguments.count ?? 0)
        liveOutput = ""
        directory = script.workingDirectory.path
        timeout = "30"
        result = nil
        error = ""
    }

    func run() {
        guard !running, let selected else { return }
        result = nil
        error = ""
        liveOutput = ""
        guard canRun(selected) else { error = "此脚本已停用，或所在文件夹已移除。"; return }
        let args: [String]
        do {
            if let metadata = selected.metadata {
                args = try metadata.arguments.enumerated().map { index, argument in
                    try argument.value(argumentValues.indices.contains(index) ? argumentValues[index] : "")
                }
            } else {
                args = try ArgumentParser.parse(arguments)
            }
        } catch let validation as ScriptMetadata.ValidationError {
            error = validation.localizedDescription
            return
        } catch {
            self.error = "参数引号或转义未完成。"
            return
        }
        guard let seconds = Int(timeout), (1...3600).contains(seconds) else {
            error = "超时须为 1 至 3600 秒。"
            return
        }
        let path = (directory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            error = "请选择有效的工作目录。"
            if let mode = selected.metadata?.effectiveMode, mode != .fullOutput {
                (NSApp?.delegate as? Delegate)?.toast.show(error, style: .failure)
            }
            return
        }
        if selected.metadata?.needsConfirmation == true {
            let alert = NSAlert()
            alert.messageText = "运行「\(selected.title)」？"
            alert.informativeText = selected.metadata?.description ?? ""
            alert.addButton(withTitle: "运行")
            alert.addButton(withTitle: "取消")
            NSApp?.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for index in argumentValues.indices where selected.metadata?.arguments[index].kind == .password {
            argumentValues[index] = ""
        }
        let mode = selected.metadata?.effectiveMode ?? .fullOutput
        if mode == .silent { (NSApp?.delegate as? Delegate)?.hideLauncher() }
        execute(selected, arguments: args, directory: URL(fileURLWithPath: path, isDirectory: true),
                timeout: TimeInterval(seconds), background: false)
    }

    func startInlineRefresh() {
        guard inlineTimer == nil else { return }
        inlineTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshInlineIfDue() }
    }

    func stop() {
        inlineTimer?.invalidate()
        inlineTimer = nil
        cancel()
    }

    private func refreshInlineIfDue() {
        guard enabled, !running, let window = (NSApp?.delegate as? Delegate)?.window, window.isVisible else { return }
        refresh()
        let now = ProcessInfo.processInfo.systemUptime
        let active = entries.filter { canRun($0) && $0.metadata?.effectiveMode == .inline && $0.metadata?.needsConfirmation == false }
            .filter { inlineDue[$0.id] != nil }.prefix(10)
        guard let script = active.first(where: { (inlineDue[$0.id] ?? .infinity) <= now }) else { return }
        execute(script, arguments: [], directory: script.workingDirectory, timeout: 30, background: true)
    }

    private func execute(_ script: ScriptCommand, arguments: [String], directory: URL,
                         timeout: TimeInterval, background: Bool) {
        let token = DispatchWorkItem {}
        cancellation = token
        runningScript = script
        let mode = script.metadata?.effectiveMode ?? .fullOutput
        worker.async { [weak self] in
            let outcome = Result {
                // A changed header must go through routing and confirmation again.
                guard try ScriptCommand.read(script.url).metadata == script.metadata else {
                    throw ScriptMetadata.ValidationError.invalidHeader
                }
                return try ScriptRunner.run(script, arguments: arguments, directory: directory,
                                            timeout: timeout, isCancelled: { token.isCancelled },
                                            onOutput: { [weak self] text in
                                                guard mode == .fullOutput else { return }
                                                DispatchQueue.main.async { [weak self] in self?.liveOutput = text }
                                            })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.runningScript = nil
                self.cancellation = nil
                self.finish(script, mode: mode, outcome: outcome, background: background)
            }
        }
    }

    private func finish(_ script: ScriptCommand, mode: ScriptMetadata.Mode,
                        outcome: Result<ScriptRunner.Result, Error>, background: Bool) {
        let toast = (NSApp?.delegate as? Delegate)?.toast
        switch outcome {
        case .success(let value):
            if mode == .inline {
                if value.status == .cancelled {
                    inlineDue.removeValue(forKey: script.id)
                } else if enabled, script.metadata?.needsConfirmation == false, let interval = script.metadata?.refreshInterval {
                    inlineDue[script.id] = ProcessInfo.processInfo.systemUptime + interval
                }
            }
            let succeeded = value.status == .exited(0)
            let lines = (succeeded ? value.standardOutput : value.output).split(whereSeparator: \.isNewline)
            if mode == .inline {
                let line = succeeded ? lines.first : lines.last
                inlineOutput[script.id] = line.map(String.init) ?? (succeeded ? "" : "运行失败")
            }
            guard !background else { return }
            result = value
            if mode == .compact || (mode == .silent && (!succeeded || !lines.isEmpty)) || (mode == .inline && !succeeded) {
                let text = lines.last.map { ScriptOutputText.plain(String($0)) } ?? (succeeded ? "脚本运行完成" : "脚本未完成")
                toast?.show(text, style: succeeded ? .success : .failure)
            }
        case .failure(let failure):
            if mode == .inline { inlineDue.removeValue(forKey: script.id) }
            if background { inlineOutput[script.id] = "运行失败"; return }
            error = "无法运行脚本：\(failure.localizedDescription)"
            if mode != .fullOutput { toast?.show(error, style: .failure) }
        }
    }

    func cancel() { cancellation?.cancel() }
}
