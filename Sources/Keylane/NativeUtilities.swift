import AppKit
import Combine
import Contacts
import CoreServices
import KeylaneCore

private enum UtilityVerification {
    static func record(_ module: String, count: Int) {
        guard ProcessInfo.processInfo.environment["KEYLANE_UTILITIES_ACCEPTANCE"] == "1" else { return }
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keylane/Diagnostics/utility-" + module + ".json")
        let report: [String: Any] = ["count": count, "timestamp": Date().timeIntervalSince1970]
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report) { try? data.write(to: path, options: .atomic) }
        }
    }
}

enum UtilityActions {
    @discardableResult
    static func copy(_ value: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }

    static func openApplication(_ identifier: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

final class SystemShortcutsController: ObservableObject {
    @Published private(set) var entries: [SystemShortcut] = []
    private(set) var duplicateTitles: Set<String> = []
    @Published private(set) var loading = false
    @Published private(set) var runningID: String?
    @Published private(set) var message = ""
    @Published private(set) var icons: [String: NSImage] = [:]
    private var iconAccess: IconAccess = .inactive
    private enum IconAccess { case inactive, loading, allowed, denied, unavailable }
    @Published var disabledIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledIDs), forKey: "systemShortcuts.disabled") }
    }
    private let catalogQueue = DispatchQueue(label: "org.keylane.shortcuts.catalog", qos: .utility)
    private let runQueue = DispatchQueue(label: "org.keylane.shortcuts.run", qos: .userInitiated)
    private let iconQueue = DispatchQueue(label: "org.keylane.shortcuts.icons", qos: .utility)
    private let loadsIcons: Bool
    private let executable: URL
    private var iconPermissionRequested = false
    private var iconGeneration = 0
    private var iconRequest: DispatchWorkItem?
    private var catalogRequest: ExtensionProcessRequest?
    private var runRequest: ExtensionProcessRequest?
    private var active: Bool
    private var lastRefresh = Date.distantPast
    private var refreshWhenIdle = false
    private var launcherRefresh: Timer?
    @Published private(set) var executionMessage = ""

    init(loadsIcons: Bool = true, active: Bool = true,
         executable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts")) {
        self.executable = executable
        self.active = active
        self.loadsIcons = loadsIcons
        disabledIDs = Set(UserDefaults.standard.stringArray(forKey: "systemShortcuts.disabled") ?? [])
    }

    func start() { active = true; refresh() }

    func launcherShown() {
        refresh(force: true, requestIconPermission: false)
        guard launcherRefresh == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        launcherRefresh = timer
    }

    func launcherHidden() {
        launcherRefresh?.invalidate()
        launcherRefresh = nil
    }

    deinit { launcherRefresh?.invalidate() }

    func stop() {
        active = false
        launcherHidden()
        refreshWhenIdle = false
        duplicateTitles = []
        iconPermissionRequested = false
        catalogRequest?.cancel()
        catalogRequest = nil
        runRequest?.cancel()
        runRequest = nil
        iconGeneration += 1
        iconRequest?.cancel()
        iconRequest = nil
        icons = [:]
        iconAccess = .inactive
        entries = []
        loading = false
        runningID = nil
        message = ""
        executionMessage = ""
        lastRefresh = .distantPast
    }

    func refresh(force: Bool = false, requestIconPermission: Bool = true) {
        guard active else { return }
        if force && loadsIcons && requestIconPermission { iconPermissionRequested = true }
        if loading {
            refreshWhenIdle = refreshWhenIdle || force
            return
        }
        guard force || Date().timeIntervalSince(lastRefresh) >= 15 else { return }
        lastRefresh = Date()
        loading = true
        let request = ExtensionProcessRequest()
        catalogRequest = request
        catalogQueue.async { [weak self, executable] in
            let result = Self.listShortcuts(executable: executable, request: request)
            let records = result.map(SystemShortcut.parse)
            DispatchQueue.main.async {
                guard let self, self.catalogRequest === request else { return }
                self.catalogRequest = nil
                self.loading = false
                if let records {
                    let changed = self.entries != records
                    if changed {
                        self.duplicateTitles = Set(Dictionary(grouping: records, by: \.name)
                            .filter { $0.value.count > 1 }.keys)
                        self.entries = records
                        let currentIDs = Set(records.map(\.id))
                        if !Set(self.icons.keys).isSubset(of: currentIDs) {
                            self.icons = self.icons.filter { currentIDs.contains($0.key) }
                        }
                    }
                    if !self.message.isEmpty { self.message = "" }
                    self.refreshIcons(force: changed || self.iconPermissionRequested)
                    UtilityVerification.record("shortcuts", count: records.count)
                } else {
                    self.message = "暂时无法读取快捷指令，将自动重试。"
                    self.refreshIcons(force: false)
                }
                if self.refreshWhenIdle {
                    self.refreshWhenIdle = false
                    self.refresh(force: true, requestIconPermission: false)
                }
            }
        }
    }

    func icon(forCommandID commandID: String) -> NSImage? {
        guard commandID.hasPrefix("shortcut:") else { return nil }
        return icons[String(commandID.dropFirst("shortcut:".count))]
    }

    private func refreshIcons(force: Bool) {
        guard active, loadsIcons, iconAccess != .loading, !entries.isEmpty else { return }
        let ids = entries.map(\.id)
        let prompt = iconPermissionRequested
        let previousAccess = iconAccess
        let needsImages = force || prompt || previousAccess != .allowed || Set(ids) != Set(icons.keys)
        iconPermissionRequested = false
        iconAccess = .loading
        let ticket = iconGeneration
        let request = DispatchWorkItem {}
        iconRequest = request

        let load: () -> Void = { [weak self] in
            guard let self, self.iconGeneration == ticket, self.active else { return }
            self.iconQueue.async { [weak self] in
                guard !request.isCancelled else { return }
                let permission = ShortcutIconReader.permissionStatus(prompt: prompt)
                guard permission == noErr else {
                    DispatchQueue.main.async {
                        guard let self, self.iconGeneration == ticket else { return }
                        if !self.icons.isEmpty { self.icons = [:] }
                        self.finishIconRefresh(permission == -1743 || permission == -1744 ? .denied : .unavailable,
                                               ids: ids)
                    }
                    return
                }
                if !needsImages {
                    DispatchQueue.main.async {
                        guard let self, self.iconGeneration == ticket else { return }
                        self.finishIconRefresh(.allowed, ids: ids)
                    }
                    return
                }
                var rendered: [String: CGImage] = [:]
                var denied = false
                for id in ids where !request.isCancelled {
                    do { rendered[id] = try ShortcutIconReader.image(id: id) }
                    catch let error as NSError {
                        if error.code == -1743 || error.code == -1744 { denied = true; break }
                        if error.code == -1712 || error.code == -600 { break }
                    }
                }
                let result = rendered
                let authorizationLost = denied
                DispatchQueue.main.async {
                    guard let self, self.iconGeneration == ticket, self.active else { return }
                    if authorizationLost {
                        self.icons = [:]
                        self.finishIconRefresh(.denied, ids: ids)
                        return
                    }
                    let currentIDs = Set(self.entries.map(\.id))
                    self.icons = result.filter { currentIDs.contains($0.key) }.mapValues {
                        NSImage(cgImage: $0, size: .zero)
                    }
                    self.finishIconRefresh(self.icons.isEmpty ? .unavailable : .allowed, ids: ids)
                    UtilityVerification.record("shortcut-icons", count: self.icons.count)
                }
            }
        }

        let identifier = ShortcutIconReader.bundleIdentifier
        if !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
            load()
        } else if !prompt && previousAccess != .inactive {
            // A passive refresh must not launch Shortcuts just to check artwork.
            iconAccess = previousAccess
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
                DispatchQueue.main.async {
                    guard let self, self.iconGeneration == ticket else { return }
                    if app == nil || error != nil { self.iconAccess = .unavailable }
                    else { load() }
                }
            }
        } else {
            iconAccess = .unavailable
        }
    }

    private func finishIconRefresh(_ access: IconAccess, ids: [String]) {
        iconAccess = access
        if iconPermissionRequested || ids != entries.map(\.id) { refreshIcons(force: true) }
    }

    enum RunStatus: Equatable {
        case started, busy, completed, interrupted, failed(Int32), unavailable

        var message: String {
            switch self {
            case .started: "正在运行…"
            case .busy: "已有快捷指令正在运行，请等待它完成。"
            case .completed: "快捷指令已完成。"
            case .interrupted: "快捷指令进程已中断，无法确认结果。"
            case .failed(let code): "系统快捷指令返回错误（退出码 \(code)）。"
            case .unavailable: "无法启动系统快捷指令。"
            }
        }
    }

    func run(_ id: String, feedback: @escaping (RunStatus) -> Void = { _ in }) {
        guard active, UUID(uuidString: id) != nil, !disabledIDs.contains(id) else { return }
        guard runningID == nil else { feedback(.busy); return }
        runningID = id
        executionMessage = RunStatus.started.message
        let request = ExtensionProcessRequest()
        runRequest = request
        feedback(.started)
        runQueue.async { [weak self, executable] in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["run", id]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let status: RunStatus
            do {
                try request.launch(process)
                defer { request.finished() }
                // Interactive shortcuts can wait for user input or a permission dialog.
                process.waitUntilExit()
                if process.terminationReason != .exit {
                    status = .interrupted
                } else if process.terminationStatus == 0 {
                    status = .completed
                } else {
                    status = .failed(process.terminationStatus)
                }
            } catch {
                status = .unavailable
            }
            DispatchQueue.main.async {
                guard let self, self.runRequest === request else { return }
                self.runRequest = nil
                self.executionMessage = status.message
                self.runningID = nil
                feedback(status)
            }
        }
    }

    private static func listShortcuts(executable: URL, request: ExtensionProcessRequest) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["list", "--show-identifiers"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try request.launch(process) } catch { return nil }
        defer { request.finished() }
        let stop = DispatchWorkItem { request.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: stop)
        defer { stop.cancel() }
        var bytes = Data()
        var overflow = false
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
            if bytes.count + chunk.count <= 2 * 1024 * 1024 { bytes.append(chunk) }
            else { overflow = true }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, !overflow else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

struct ContactSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let organization: String
    let phones: [String]
    let emails: [String]
    let searchable: String

    init(contact: CNContact) {
        id = contact.identifier
        organization = contact.organizationName
        let formatted = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        name = formatted.isEmpty ? (organization.isEmpty ? "未命名联系人" : organization) : formatted
        phones = contact.phoneNumbers.map { $0.value.stringValue }
        emails = contact.emailAddresses.map { String($0.value) }
        searchable = ([name, contact.nickname, organization] + phones + emails + phones.map { $0.filter(\.isNumber) }).joined(separator: " ")
    }

    var firstValue: String? { phones.first ?? emails.first }
}

final class ContactsController: ObservableObject {
    @Published private(set) var access: CNAuthorizationStatus = .notDetermined
    @Published private(set) var visible: [ContactSummary] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var loading = false
    @Published private(set) var requesting = false
    @Published private(set) var error = ""
    @Published var query = "" { didSet { if oldValue != query { updateResults() } } }
    private var fetch: Task<Void, Never>?
    private var contacts: [ContactSummary] = []
    private var observation: NSObjectProtocol?
    private var generation = 0
    private var active = false

    var canRead: Bool { access == .authorized }
    var selected: ContactSummary? { visible.first { $0.id == selectedID } }
    func start() {
        active = true
        if observation == nil {
            observation = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        active = false
        generation += 1
        fetch?.cancel()
        fetch = nil
        if let observation { NotificationCenter.default.removeObserver(observation) }
        observation = nil
        contacts = []
        visible = []
        selectedID = nil
        loading = false
    }

    func requestAccess() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined, !requesting else { return }
        requesting = true
        CNContactStore().requestAccess(for: .contacts) { [weak self] _, failure in
            DispatchQueue.main.async {
                self?.access = CNContactStore.authorizationStatus(for: .contacts)
                self?.requesting = false
                self?.refresh()
                if failure != nil { self?.error = "无法完成联系人授权。" }
            }
        }
    }

    func refresh() {
        guard active else { return }
        access = CNContactStore.authorizationStatus(for: .contacts)
        generation += 1
        let ticket = generation
        fetch?.cancel()
        fetch = nil
        guard canRead else {
            contacts = []; updateResults(); loading = false
            return
        }
        loading = true
        error = ""
        fetch = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactNicknameKey as NSString, CNContactOrganizationNameKey as NSString,
                CNContactPhoneNumbersKey as NSString, CNContactEmailAddressesKey as NSString]
            let request = CNContactFetchRequest(keysToFetch: keys)
            let result = Result { () -> [ContactSummary] in
                var rows: [ContactSummary] = []
                try CNContactStore().enumerateContacts(with: request) { contact, stop in
                    if Task.isCancelled {
                        stop.pointee = true
                    } else {
                        rows.append(ContactSummary(contact: contact))
                    }
                }
                guard !Task.isCancelled else { return [] }
                return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == ticket else { return }
                self.fetch = nil
                self.loading = false
                switch result {
                case .success(let rows):
                    self.contacts = rows
                    self.updateResults()
                    UtilityVerification.record("contacts", count: rows.count)
                case .failure:
                    self.contacts = []
                    self.updateResults()
                    self.error = "无法读取联系人，请刷新或检查系统权限。"
                }
            }
        }
    }

    private func updateResults() {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = Array(contacts.lazy.filter { entry in terms.allSatisfy { entry.searchable.localizedCaseInsensitiveContains($0) } }.prefix(200))
        if visible != matches { visible = matches }
        if !matches.contains(where: { $0.id == selectedID }), selectedID != matches.first?.id { selectedID = matches.first?.id }
    }

    func select(_ id: String) { if selectedID != id { selectedID = id } }
    func move(_ delta: Int) {
        let index = visible.firstIndex { $0.id == selectedID } ?? 0
        let next = NavigationBounds.move(index, by: delta, count: visible.count)
        if visible.indices.contains(next) { select(visible[next].id) }
    }
}

final class DictionaryController: ObservableObject {
    @Published private(set) var term = ""
    @Published private(set) var definition: String?
    @Published private(set) var loading = false
    var initialTerm = ""
    private let worker = DispatchQueue(label: "org.keylane.dictionary", qos: .userInitiated)
    private var pending: DispatchWorkItem?
    private var generation = 0

    static func definition(for term: String) -> String? {
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = text.utf16.count
        guard (1...256).contains(length) else { return nil }
        return DCSCopyTextDefinition(nil, text as CFString, CFRange(location: 0, length: length))?.takeRetainedValue() as String?
    }

    func search(_ query: String) {
        generation += 1
        let ticket = generation
        pending?.cancel()
        pending = nil
        term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        definition = nil
        loading = !term.isEmpty && term.utf16.count <= 256
        guard loading else { return }
        let text = term
        let job = DispatchWorkItem { [weak self] in
            let result = Self.definition(for: text)
            DispatchQueue.main.async {
                guard let self, self.generation == ticket else { return }
                self.pending = nil
                self.definition = result
                self.loading = false
            }
        }
        pending = job
        worker.asyncAfter(deadline: .now() + 0.12, execute: job)
    }

    func openDictionary() {
        guard !term.isEmpty else { UtilityActions.openApplication("com.apple.Dictionary"); return }
        var components = URLComponents()
        components.scheme = "dict"
        components.path = term
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
