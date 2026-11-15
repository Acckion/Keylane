import AppKit
import Combine
import SwiftUI
import KeylaneCore

/// Every child runs off the main thread, with a wall-clock deadline independent of devicectl.
enum IPhoneDeviceCommand {
    static func run(_ arguments: [String], timeout: TimeInterval, executable: URL = URL(fileURLWithPath: "/usr/bin/xcrun")) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keylane-device-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = directory.appendingPathComponent("result.json")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["devicectl"] + arguments + ["--timeout", String(Int(timeout)), "--json-output", json.path]
        // Do not inherit DEVICECTL_CHILD_* environment variables into phone apps.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DEVICECTL_CHILD_") }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { throw IPhoneLaunchError.failed }
        if done.wait(timeout: .now() + timeout + 2) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = done.wait(timeout: .now() + 1)
            }
            throw IPhoneLaunchError.timeout
        }
        let response = (try? Data(contentsOf: json)) ?? Data()
        guard process.terminationStatus == 0 else {
            if let root = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
               let info = root["info"] as? [String: Any], info["outcome"] as? String == "timeout" { throw IPhoneLaunchError.timeout }
            throw IPhoneLaunchError.failed
        }
        guard let root = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let info = root["info"] as? [String: Any], info["outcome"] as? String == "success" else { throw IPhoneLaunchError.invalidResponse }
        return response
    }
}

final class IPhoneApplications: ObservableObject {
    @Published private(set) var apps: [IPhoneApplication] = []
    @Published private(set) var devices: [IPhoneDevice] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "experimentalIPhoneApplications")
            if enabled { refresh() } else { generation += 1; apps = []; devices = []; status = ""; busy = false }
        }
    }
    @Published var selectedDevice: String {
        didSet {
            defaults.set(selectedDevice, forKey: "iPhoneApplicationDevice")
            generation += 1
            busy = false
        }
    }
    private let defaults: UserDefaults
    private let scan: () -> [IPhoneApplication]
    private let command: ([String], TimeInterval) throws -> Data
    init(defaults: UserDefaults = .standard,
         scan: @escaping () -> [IPhoneApplication] = { IPhoneApplicationCatalog.scan() },
         command: @escaping ([String], TimeInterval) throws -> Data = { try IPhoneDeviceCommand.run($0, timeout: $1) }) {
        self.defaults = defaults
        self.scan = scan
        self.command = command
        enabled = defaults.bool(forKey: "experimentalIPhoneApplications")
        selectedDevice = defaults.string(forKey: "iPhoneApplicationDevice") ?? ""
    }
    private var generation = 0
    private let queue = DispatchQueue(label: "org.keylane.iphone", qos: .userInitiated)
    var updates: AnyPublisher<Void, Never> {
        Publishers.MergeMany([$apps.map { _ in () }.eraseToAnyPublisher(), $enabled.map { _ in () }.eraseToAnyPublisher()]).eraseToAnyPublisher()
    }
    func stop() { generation += 1; apps = []; devices = []; busy = false }
    func refresh() {
        guard enabled, #available(macOS 26, *) else { return }
        generation += 1
        let version = generation
        busy = true
        status = "正在读取 iPhone 应用与设备…"
        let scan = self.scan, command = self.command
        queue.async { [weak self] in
            let apps = scan()
            let devices = Result { try IPhoneDevice.parse(command(["list", "devices"], 10)) }
            DispatchQueue.main.async {
                guard let self, self.enabled, self.generation == version else { return }
                self.apps = apps
                self.busy = false
                switch devices {
                case .success(let values):
                    self.devices = values
                    self.status = apps.isEmpty ? "未找到可读的 iPhone 应用缓存。请手动连接 iPhone 镜像后刷新。" : "发现 \(apps.count) 个缓存应用；缓存不保证所选手机已安装。"
                case .failure(let error): self.devices = []; self.status = error.localizedDescription
                }
            }
        }
    }
    func available(_ id: String, model: Model) -> Bool {
        enabled && model.applicationsEnabled && apps.contains { $0.id == id } && !model.disabledCommands.contains(id)
    }
    func launch(_ id: String, model: Model) {
        guard !busy else {
            (NSApp.delegate as? Delegate)?.showLauncherFeedback("已有 iPhone 请求正在执行，请稍候。", style: .failure)
            return
        }
        guard available(id, model: model), let app = apps.first(where: { $0.id == id }) else { return }
        let preferred = selectedDevice
        let version = generation
        busy = true
        status = "正在启动 \(app.name)…"
        let command = self.command
        queue.async { [weak self, weak model] in
            let outcome = Result {
                let devices = try IPhoneDevice.parse(command(["list", "devices"], 10))
                let device = try IPhoneDevice.select(devices, preferred: preferred)
                guard device.available else { throw IPhoneLaunchError.unavailable }
                // Recheck opt-out on main before admitting the launch after device discovery.
                var admitted = false
                DispatchQueue.main.sync { admitted = self?.generation == version && model.map { self?.available(id, model: $0) == true } == true }
                guard admitted else { throw CancellationError() }
                _ = try command(["device", "process", "launch", "--device", device.id, app.bundleID], 30)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == version else { return }
                self.busy = false
                switch outcome {
                case .success:
                    self.status = "已向 iPhone 发送启动请求；画面请查看手机或已连接的 iPhone 镜像。"
                    (NSApp.delegate as? Delegate)?.showLauncherFeedback(self.status, style: .success)
                case .failure(let error):
                    self.status = error.localizedDescription
                    (NSApp.delegate as? Delegate)?.showLauncherFeedback(self.status, style: .failure)
                }
            }
        }
    }
    func settingsEntry(_ app: IPhoneApplication, model: Model) -> CommandSettingsEntry<Image> {
        CommandSettingsEntry(title: app.name + " · iPhone", model: model, commandID: .init(rawValue: app.id),
                    isEnabled: Binding(get: { !model.disabledCommands.contains(app.id) }, set: { value in
                        if value { model.disabledCommands.remove(app.id) } else { model.disabledCommands.insert(app.id) }
                    }), help: app.bundleID,
                    menu: [.init(title: model.favorites.contains(app.id) ? "取消收藏" : "加入收藏") { model.toggleFavorite(app.id) }],
                    icon: { Image(systemName: "iphone") })
    }
    func includingSettings(_ mac: DynamicCommandSettings, model: Model) -> DynamicCommandSettings {
        let phone = DynamicCommandSettings(model: model, items: { [weak self] in self?.enabled == true ? self?.apps ?? [] : [] },
            title: \.name, commandID: \.id, updates: { [weak self] in self.map { [$0.updates] } ?? [] },
            entry: { app, model in model.iPhoneApplications.settingsEntry(app, model: model) })
        return DynamicCommandSettings(updates: { mac.updates() + phone.updates() }, matchingList: { matches in
            let local = mac.matchingList(matches)
            let remote = phone.matchingList(matches)
            guard local != nil || remote != nil else { return nil }
            return { columns in AnyView(VStack(spacing: 0) {
                if let local { local(columns) }
                if let remote { remote(columns && local == nil) }
            }) }
        })
    }

    func provider(model: Model) -> LauncherModule.Provider {
        .init(namespace: .prefix("iphone:"), entries: { [weak self, weak model] _ in
            guard let self, let model else { return [] }
            return self.apps.filter { self.available($0.id, model: model) }.map {
                Entry(id: $0.id, commandID: .init(rawValue: $0.id), name: $0.name, detail: "iPhone 应用", symbol: "iphone", aliases: [$0.bundleID], subtitle: "iPhone · " + $0.bundleID)
            }
        }, resolve: { [weak self, weak model] id, _ in
            guard let self, let model, self.available(id.rawValue, model: model) else { return nil }
            return { [weak self, weak model] in if let model { self?.launch(id.rawValue, model: model) } }
        }, actions: { [weak self, weak model] entry in
            guard let self, let model else { return [] }
            return [LauncherAction(id: "open", title: "在 iPhone 上打开", icon: "iphone", keys: ["↩"]) { [weak self, weak model] in
                if let model { self?.launch(entry.id, model: model) }
            }, model.favoriteAction(for: entry),
            LauncherAction(id: "settings", title: "iPhone 应用设置", icon: "gearshape") { [weak model] in model?.openSettings(page: "applications") }]
        })
    }
}

struct IPhoneApplicationPreferences: View {
    let model: Model
    @ObservedObject var phone: IPhoneApplications
    var body: some View {
        SettingsGroup {
            SettingsRow("iPhone 应用（实验性）", detail: "备选机制验证草稿：显示系统镜像缓存中的应用，并通过 Xcode 启动；并非最终产品方案。默认关闭；需要现有 Xcode、设备配对及开发者模式。手机锁定时请先手动连接 iPhone 镜像。Keylane 不会更改这些设置。") {
                Toggle("iPhone 应用", isOn: $phone.enabled).labelsHidden()
            }
            if phone.enabled {
                SettingsPicker("启动设备", detail: "多台已配对 iPhone 时必须明确选择。缓存可能来自另一台手机。", selection: $phone.selectedDevice) {
                    Text("仅有一台已配对 iPhone 时自动选择").tag("")
                    if !phone.selectedDevice.isEmpty && !phone.devices.contains(where: { $0.id == phone.selectedDevice }) {
                        Text("所选设备不可用").tag(phone.selectedDevice)
                    }
                    ForEach(phone.devices) { Text($0.name + " · " + String($0.id.prefix(8)) + ($0.available ? "" : "（未连接）")).tag($0.id) }
                }
                SettingsRow("缓存与连接", detail: phone.status) {
                    Button("刷新") { phone.refresh() }.disabled(phone.busy)
                }
            }
        }.settingsAnchor(.iPhoneApplications)
        if phone.enabled {
            CommandSettingsList(items: phone.apps, id: \.id, emptyMessage: "暂无 iPhone 应用") { app in
                phone.settingsEntry(app, model: model)
            }
        }
    }
}
