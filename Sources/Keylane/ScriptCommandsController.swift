import AppKit
import Combine
import KeylaneCore
import SwiftUI

final class ScriptCommandsController: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            preferences.set(enabled, forKey: "scriptCommands.enabled")
            guard enabled != oldValue else { return }
            if enabled, serviceRunning { restartDiscovery() }
            else {
                stopDiscovery()
                inlineDue.removeAll()
                if !inlineOutput.isEmpty { inlineOutput.removeAll() }
                suspendInlineRefresh()
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
        didSet {
            preferences.set(Array(disabled), forKey: "scriptCommands.disabled")
            guard disabled != oldValue else { return }
            pruneInlineState()
            scheduleInlineRefresh()
        }
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
    private var inlineRun: (script: ScriptCommand, token: DispatchWorkItem)?
    private var launcherVisible = false
    private var serviceRunning = false
    @Published var directory = ""
    @Published var timeout = "30"

    private let preferences: UserDefaults
    private let scanner = DispatchQueue(label: "org.keylane.scripts.scan", qos: .utility)
    private let worker = DispatchQueue(label: "org.keylane.scripts.run", qos: .userInitiated)
    private var scanToken: DispatchWorkItem?
    private var lastScan: TimeInterval?
    private let folderWatcher: FolderChangeWatcher = {
        let watcher = FolderChangeWatcher()
        watcher.ignoresDirectory = ScriptCommand.ignoresDiscoveryDirectory(named:)
        return watcher
    }()
    private var pendingFolderRefresh: DispatchWorkItem?
    private var rebuildWatch = false
    private var rescanRequested = false
    private var entriesByID: [String: ScriptCommand] = [:]
    private var cancellation: DispatchWorkItem?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        fallbackID = preferences.string(forKey: "scriptCommands.fallback") ?? ""
        enabled = preferences.object(forKey: "scriptCommands.enabled") as? Bool ?? true
        folders = Self.canonicalFolders(preferences.stringArray(forKey: "scriptCommands.folders") ?? [])
        disabled = Set(preferences.stringArray(forKey: "scriptCommands.disabled") ?? [])
    }

    func start() {
        guard !serviceRunning else { return }
        serviceRunning = true
        if enabled { restartDiscovery() }
        scheduleInlineRefresh()
    }

    func setLauncherVisible(_ visible: Bool) {
        guard launcherVisible != visible else { return }
        launcherVisible = visible
        if visible {
            refresh()
            scheduleInlineRefresh()
        } else {
            suspendInlineRefresh()
        }
    }

    private func restartDiscovery() {
        stopDiscovery()
        folderWatcher.changed = { [weak self] rebuild in self?.folderChanged(rebuild: rebuild) }
        folderWatcher.start(roots: folders)
        refresh(force: true)
    }

    private func folderChanged(rebuild: Bool) {
        rebuildWatch = rebuildWatch || rebuild
        guard pendingFolderRefresh == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFolderRefresh = nil
            if self.rebuildWatch {
                self.rebuildWatch = false
                self.folderWatcher.start(roots: self.folders)
            }
            if self.scanToken != nil { self.rescanRequested = true }
            else { self.refresh(force: true) }
        }
        pendingFolderRefresh = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    func refresh(force: Bool = false, completion: ((Int) -> Void)? = nil) {
        guard serviceRunning, enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // The visibility and settings entry points only retry when a watch could not start.
        guard force || (!folders.isEmpty && scanToken == nil && !folderWatcher.isWatching && now - (lastScan ?? -.infinity) > 15) else { return }
        if !force { folderWatcher.start(roots: folders) }
        lastScan = now
        scanToken?.cancel()
        scanToken = nil
        rescanRequested = false
        let paths = folders
        guard !paths.isEmpty else {
            replaceEntries([])
            if !unavailable.isEmpty { unavailable = [] }
            if scanning { scanning = false }
            completion?(0)
            return
        }

        let token = DispatchWorkItem {}
        scanToken = token
        if !scanning { scanning = true }
        scanner.async { [weak self] in
            guard !token.isCancelled else { return }
            let catalog = ScriptCommand.discover(in: paths, isCancelled: { token.isCancelled })
            DispatchQueue.main.async {
                guard let self, self.scanToken === token, !token.isCancelled else { return }
                self.scanToken = nil
                self.replaceEntries(catalog.commands)
                if self.unavailable != catalog.unavailable { self.unavailable = catalog.unavailable }
                if self.rescanRequested { self.refresh(force: true) }
                else { self.scanning = false }
                completion?(catalog.commands.count)
            }
        }
    }

    private func replaceEntries(_ updated: [ScriptCommand]) {
        guard entries != updated else { return }
        let previous = entriesByID
        entriesByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        pruneInlineState { previous[$0] == entriesByID[$0] }
        entries = updated
        scheduleInlineRefresh()
    }

    private func stopDiscovery() {
        folderWatcher.stop()
        pendingFolderRefresh?.cancel()
        pendingFolderRefresh = nil
        rebuildWatch = false
        rescanRequested = false
        scanToken?.cancel()
        scanToken = nil
        if scanning { scanning = false }
        lastScan = nil
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

    var canSaveDraft: Bool {
        enabled && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveDraft() {
        guard enabled, let window = (NSApp.delegate as? Delegate)?.window, window.attachedSheet == nil else { return }
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
        panel.message = "如需搜索此脚本，请在设置中手动添加它所在的文件夹。"
        panel.directoryURL = folders.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        panel.canCreateDirectories = true
        let selectedTemplate = template
        let validatedMetadata = metadata
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writeDraft(at: url, template: selectedTemplate, metadata: validatedMetadata)
        }
    }

    private func writeDraft(at url: URL, template: ScriptTemplate, metadata: ScriptMetadata) {
        do {
            try template.create(at: url, metadata: metadata)
            let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            if folders.contains(where: { folder == $0 || folder.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
                refresh(force: true)
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
        let updated = Self.canonicalFolders(paths)
        guard folders != updated else { return }
        folders = updated
        replaceEntries(entries.filter { command in folders.contains { Self.contains(command, in: $0) } })
        preferences.set(folders, forKey: "scriptCommands.folders")
        if serviceRunning, enabled { restartDiscovery() }
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
        serviceRunning && enabled && !disabled.contains(script.id) && folders.contains { Self.contains(script, in: $0) }
    }

    func command(withID id: String) -> ScriptCommand? { entriesByID[id] }

    private func acceptsFallbackInput(_ script: ScriptCommand) -> Bool {
        guard let args = script.metadata?.arguments else { return false }
        return args.first?.kind == .text && args.dropFirst().allSatisfy { $0.optional == true }
    }

    var fallbackEntries: [ScriptCommand] { entries.filter(acceptsFallbackInput) }

    var fallback: ScriptCommand? {
        guard let script = command(withID: fallbackID), canRun(script), acceptsFallbackInput(script) else { return nil }
        return script
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

    func stop() {
        serviceRunning = false
        launcherVisible = false
        stopDiscovery()
        suspendInlineRefresh()
        inlineRun = nil
        cancel()
        cancellation = nil
        runningScript = nil
        replaceEntries([])
        inlineDue.removeAll()
        inlineOutput.removeAll()
        selected = nil
        unavailable = []
        result = nil
        liveOutput = ""
        arguments = ""
        argumentValues = []
        error = ""
        draft = ScriptMetadata()
        draftChoiceText = []
        creationError = ""
    }

    private func suspendInlineRefresh() {
        inlineTimer?.invalidate()
        inlineTimer = nil
        inlineRun?.token.cancel()
    }

    private func pruneInlineState(keep: (String) -> Bool = { _ in true }) {
        inlineDue = inlineDue.filter { entriesByID[$0.key] != nil && !disabled.contains($0.key) && keep($0.key) }
        let output = inlineOutput.filter { entriesByID[$0.key] != nil && !disabled.contains($0.key) && keep($0.key) }
        if inlineOutput != output { inlineOutput = output }
        if let run = inlineRun, entriesByID[run.script.id] != run.script || !canRun(run.script) {
            run.token.cancel()
        }
    }

    private func scheduleInlineRefresh() {
        inlineTimer?.invalidate()
        inlineTimer = nil
        guard serviceRunning, enabled, launcherVisible, !running, inlineRun == nil, !inlineDue.isEmpty else { return }
        let eligible: [ScriptCommand]
        if inlineDue.count <= 10 {
            eligible = inlineDue.keys.compactMap { entriesByID[$0] }.filter(canRun)
        } else {
            eligible = Array(entries.lazy.filter { self.inlineDue[$0.id] != nil && self.canRun($0) }.prefix(10))
        }
        guard let script = eligible.min(by: { inlineDue[$0.id, default: .infinity] < inlineDue[$1.id, default: .infinity] }),
              let due = inlineDue[script.id] else { return }
        let delay = max(0.01, due - ProcessInfo.processInfo.systemUptime)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.inlineTimer = nil
            self.execute(script, arguments: [], directory: script.workingDirectory, timeout: 30, background: true)
        }
        timer.tolerance = min(0.25, delay / 10)
        inlineTimer = timer
    }

    private func execute(_ script: ScriptCommand, arguments: [String], directory: URL,
                         timeout: TimeInterval, background: Bool) {
        let token = DispatchWorkItem {}
        if background {
            inlineRun = (script, token)
        } else {
            suspendInlineRefresh()
            cancellation = token
            runningScript = script
        }
        let mode = script.metadata?.effectiveMode ?? .fullOutput
        worker.async { [weak self] in
            let outcome = Result {
                // A changed header must go through routing and confirmation again.
                if !token.isCancelled, try ScriptCommand.read(script.url).metadata != script.metadata {
                    throw ScriptMetadata.ValidationError.invalidHeader
                }
                return try ScriptRunner.run(script, arguments: arguments, directory: directory,
                                            timeout: timeout, isCancelled: { token.isCancelled },
                                            onOutput: { [weak self] text in
                                                guard mode == .fullOutput else { return }
                                                DispatchQueue.main.async { [weak self] in
                                                    if self?.cancellation === token, !token.isCancelled { self?.liveOutput = text }
                                                }
                                            })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if background {
                    guard self.inlineRun?.token === token else { return }
                    self.inlineRun = nil
                    if !token.isCancelled { self.finish(script, mode: mode, outcome: outcome, background: true) }
                } else {
                    guard self.cancellation === token else { return }
                    self.runningScript = nil
                    self.cancellation = nil
                    self.finish(script, mode: mode, outcome: outcome, background: false)
                }
                self.scheduleInlineRefresh()
            }
        }
    }

    private func finish(_ script: ScriptCommand, mode: ScriptMetadata.Mode,
                        outcome: Result<ScriptRunner.Result, Error>, background: Bool) {
        let toast = (NSApp?.delegate as? Delegate)?.toast
        let acceptsInlineOutput = mode == .inline && serviceRunning && canRun(script) && entriesByID[script.id] == script
        switch outcome {
        case .success(let value):
            if acceptsInlineOutput {
                if value.status == .cancelled {
                    inlineDue.removeValue(forKey: script.id)
                } else if script.metadata?.needsConfirmation == false, let interval = script.metadata?.refreshInterval {
                    inlineDue[script.id] = ProcessInfo.processInfo.systemUptime + interval
                }
            }
            let succeeded = value.status == .exited(0)
            let lines = (succeeded ? value.standardOutput : value.output).split(whereSeparator: \.isNewline)
            if acceptsInlineOutput, value.status != .cancelled {
                let line = succeeded ? lines.first : lines.last
                let text = value.status == .timedOut ? "运行超时" : (line.map(String.init) ?? (succeeded ? "" : "运行失败"))
                if inlineOutput[script.id] != text { inlineOutput[script.id] = text }
            }
            guard !background else { return }
            result = value
            if mode == .compact || (mode == .silent && (!succeeded || !lines.isEmpty)) || (mode == .inline && !succeeded) {
                let text: String
                switch value.status {
                case .cancelled: text = "已取消脚本运行"
                case .timedOut: text = "脚本运行超时"
                default:
                    text = lines.last.map { ScriptOutputText.plain(String($0)) } ?? (succeeded ? "脚本运行完成" : "脚本未完成")
                }
                toast?.show(text, style: succeeded ? .success : .failure)
            }
        case .failure(let failure):
            if acceptsInlineOutput {
                inlineDue.removeValue(forKey: script.id)
                if background, inlineOutput[script.id] != "运行失败" { inlineOutput[script.id] = "运行失败" }
            }
            if background { return }
            error = "无法运行脚本：\(failure.localizedDescription)"
            if mode != .fullOutput { toast?.show(error, style: .failure) }
        }
    }

    func cancel() { cancellation?.cancel() }
}
