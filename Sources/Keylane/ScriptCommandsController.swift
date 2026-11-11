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
            }
        }
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
    @Published private(set) var running = false
    @Published private(set) var result: ScriptRunner.Result?
    @Published private(set) var error = ""
    @Published var arguments = ""
    @Published var directory = ""
    @Published var timeout = "30"
    @Published var draftName = ""
    @Published var draftExtension = "sh"

    var draftFilename: String? {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else { return nil }
        return "\(name).\(draftExtension)"
    }

    private let preferences: UserDefaults
    private let scanner = DispatchQueue(label: "org.keylane.scripts.scan", qos: .utility)
    private let worker = DispatchQueue(label: "org.keylane.scripts.run", qos: .userInitiated)
    private var scanRevision = 0
    private var lastScan = Date.distantPast
    private var cancellation: DispatchWorkItem?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
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
                self.entries = catalog.commands
                self.unavailable = catalog.unavailable
                self.scanning = false
                completion?(catalog.commands.count)
            }
        }
    }

    func createScript(in window: NSWindow) {
        guard enabled, let filename = draftFilename, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.title = "创建脚本命令"
        panel.nameFieldStringValue = filename
        panel.message = "保存位置会加入脚本搜索范围。"
        panel.directoryURL = folders.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writeScript(at: url)
        }
    }

    private func writeScript(at url: URL) {
        let toast = (NSApp.delegate as? Delegate)?.toast
        do {
            try ScriptCommand.createTemplate(at: url)
            let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            if folders.contains(where: { folder == $0 || folder.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
                refresh(force: true)
            } else {
                setFolders(folders + [folder])
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            toast?.show("无法创建脚本：\(error.localizedDescription)", style: .failure)
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

    func select(_ script: ScriptCommand) {
        guard !running else { return }
        selected = script
        arguments = ""
        directory = script.url.deletingLastPathComponent().path
        timeout = "30"
        result = nil
        error = ""
    }

    func run() {
        guard !running, let selected else { return }
        result = nil
        error = ""
        guard canRun(selected) else { error = "此脚本已停用，或所在文件夹已移除。"; return }
        let args: [String]
        do { args = try ArgumentParser.parse(arguments) }
        catch { self.error = "参数引号或转义未完成。"; return }
        guard let seconds = Int(timeout), (1...3600).contains(seconds) else {
            error = "超时须为 1 至 3600 秒。"
            return
        }
        let path = (directory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            error = "请选择有效的工作目录。"
            return
        }
        let workingDirectory = URL(fileURLWithPath: path, isDirectory: true)
        let token = DispatchWorkItem {}
        cancellation = token
        running = true
        worker.async { [weak self] in
            let outcome = Result { try ScriptRunner.run(selected, arguments: args, directory: workingDirectory,
                                                        timeout: TimeInterval(seconds), isCancelled: { token.isCancelled }) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.cancellation = nil
                switch outcome {
                case .success(let value): self.result = value
                case .failure(let error): self.error = "无法运行脚本：\(error.localizedDescription)"
                }
            }
        }
    }

    func cancel() { cancellation?.cancel() }
}
