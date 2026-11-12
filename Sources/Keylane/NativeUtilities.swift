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
    var iconReadingAllowed: () -> Bool = { false }
    private var iconGeneration = 0
    private var lastRefresh = Date.distantPast
    var onRunFailure: ((String) -> Void)?

    init(loadsIcons: Bool = true) {
        self.loadsIcons = loadsIcons
        disabledIDs = Set(UserDefaults.standard.stringArray(forKey: "systemShortcuts.disabled") ?? [])
    }

    func refresh(force: Bool = false) {
        guard !loading, force || Date().timeIntervalSince(lastRefresh) > 15 else { return }
        lastRefresh = Date()
        loading = true
        message = ""
        catalogQueue.async { [weak self] in
            let result = Self.invoke(["list", "--show-identifiers"], timeout: 12, capture: true)
            let records = result.map(SystemShortcut.parse)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                if let records {
                    self.entries = records
                    self.refreshIcons(force: force)
                    UtilityVerification.record("shortcuts", count: records.count)
                } else {
                    self.message = "无法读取快捷指令。打开系统快捷指令后再刷新。"
                }
            }
        }
    }

    func icon(forCommandID commandID: String) -> NSImage? {
        guard commandID.hasPrefix("shortcut:") else { return nil }
        return icons[String(commandID.dropFirst("shortcut:".count))]
    }

    func updateIconPermission() {
        iconGeneration += 1
        icons = [:]
        iconAccess = .inactive
        if iconReadingAllowed() { refreshIcons(force: true) }
    }

    private func refreshIcons(force: Bool) {
        guard loadsIcons, iconReadingAllowed(), iconAccess != .loading, !entries.isEmpty else { return }
        let ids = entries.map(\.id)
        guard force || iconAccess == .inactive || (iconAccess == .allowed && Set(ids) != Set(icons.keys)) else { return }
        iconAccess = .loading
        let ticket = iconGeneration

        let load: () -> Void = { [weak self] in
            guard let self, self.iconGeneration == ticket, self.iconReadingAllowed() else { return }
            self.iconQueue.async { [weak self] in
                let permission = ShortcutIconReader.permissionStatus()
                guard permission == noErr else {
                    DispatchQueue.main.async {
                        guard let self, self.iconGeneration == ticket else { return }
                        self.icons = [:]
                        self.iconAccess = permission == -1743 || permission == -1744 ? .denied : .unavailable
                    }
                    return
                }
                var rendered: [String: CGImage] = [:]
                var denied = false
                for id in ids {
                    do { rendered[id] = try ShortcutIconReader.image(id: id) }
                    catch let error as NSError {
                        if error.code == -1743 || error.code == -1744 { denied = true; break }
                        if error.code == -1712 || error.code == -600 { break }
                    }
                }
                let result = rendered
                let authorizationLost = denied
                DispatchQueue.main.async {
                    guard let self, self.iconGeneration == ticket, self.iconReadingAllowed() else { return }
                    if authorizationLost {
                        self.icons = [:]
                        self.iconAccess = .denied
                        return
                    }
                    let currentIDs = Set(self.entries.map(\.id))
                    self.icons = result.filter { currentIDs.contains($0.key) }.mapValues {
                        NSImage(cgImage: $0, size: .zero)
                    }
                    self.iconAccess = self.icons.isEmpty ? .unavailable : .allowed
                    UtilityVerification.record("shortcut-icons", count: self.icons.count)
                }
            }
        }

        let identifier = ShortcutIconReader.bundleIdentifier
        if !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
            load()
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

    func run(_ id: String) {
        guard UUID(uuidString: id) != nil, !disabledIDs.contains(id), runningID == nil else { return }
        runningID = id
        message = "正在运行…"
        runQueue.async { [weak self] in
            let result = Self.invoke(["run", id], timeout: 180, capture: false)
            DispatchQueue.main.async {
                self?.runningID = nil
                if result == nil {
                    let message = "快捷指令未完成。请检查指令是否仍存在、所需权限和输入。"
                    self?.message = message
                    self?.onRunFailure?(message)
                } else {
                    self?.message = "快捷指令已完成。"
                }
            }
        }
    }

    private static func invoke(_ arguments: [String], timeout: TimeInterval, capture: Bool) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = capture ? pipe : FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
        defer { stop.cancel() }
        var bytes = Data()
        var overflow = false
        if capture {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
                if bytes.count + chunk.count <= 2 * 1024 * 1024 { bytes.append(chunk) }
                else { overflow = true }
            }
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
        term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        definition = nil
        loading = !term.isEmpty && term.utf16.count <= 256
        guard loading else { return }
        let text = term
        let job = DispatchWorkItem { [weak self] in
            let result = Self.definition(for: text)
            DispatchQueue.main.async {
                guard let self, self.generation == ticket else { return }
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
