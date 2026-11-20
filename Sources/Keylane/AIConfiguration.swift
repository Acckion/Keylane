import Combine
import Foundation
import Security

enum AIRoute: String, Codable, CaseIterable, Identifiable {
    case quick, chat, commands, files
    var id: Self { self }
    var title: String {
        switch self {
        case .quick: "Quick AI"
        case .chat: "AI Chat"
        case .commands: "AI 命令"
        case .files: "询问文件"
        }
    }
}

final class AIConfiguration: ObservableObject {
    struct State: Codable, Equatable {
        var enabled = false
        var connections: [AIConnection] = []
        var selectedID: UUID?
        var defaults: [AIRoute: UUID]?
        var usesLastChatModel: Bool?
        var lastChatModelID: UUID?
        var providerCatalogs: [String: AIProviderCatalogCache]?
        var selected: AIConnection? { connections.first { $0.id == selectedID } }
        var isAvailable: Bool { connection(for: .files) != nil }

        func connection(for route: AIRoute) -> AIConnection? {
            guard enabled else { return nil }
            let fallback = defaults?[route] ?? selectedID
            let id = route == .chat && usesLastChatModel == true ? lastChatModelID ?? fallback : fallback
            return connections.first { $0.id == id && $0.isConfigured && $0.taskKind == .text }
        }

        var routeAvailability: [Bool] { AIRoute.allCases.map { connection(for: $0) != nil } }
        var availableConnectionIDs: Set<UUID> {
            guard enabled else { return [] }
            return Set(connections.filter { $0.isConfigured && $0.taskKind == .text }.map(\.id))
        }
    }

    @Published private(set) var catalogSyncStatus: [String: String] = [:]
    @Published private(set) var state: State
    private var modelCatalogSync: AIProviderCatalogSync?
    private let preferences: UserDefaults
    private static let storageKey = "aiConnections.v1"
    private static let service = "org.keylane.ai"
    private static let legacyService = "org.keylane.file-ai"

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            let endpoint = preferences.string(forKey: "fileAIEndpoint") ?? ""
            let model = preferences.string(forKey: "fileAIModel") ?? ""
            if endpoint.isEmpty && model.isEmpty {
                state = State()
            } else {
                let account = URL(string: endpoint)?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let connection = AIConnection(name: "文件问答", endpoint: endpoint, model: model,
                                              mode: .complete, legacyAccount: account)
                state = State(enabled: connection.isConfigured, connections: [connection], selectedID: connection.id)
                if let data = try? JSONEncoder().encode(state) { preferences.set(data, forKey: Self.storageKey) }
            }
        }
        // Expand the former shared selection into explicit per-surface defaults.
        if let selected = state.selectedID, state.selected?.taskKind == .text {
            var defaults = state.defaults ?? [:]
            for route in AIRoute.allCases where defaults[route] == nil { defaults[route] = selected }
            state.defaults = defaults
            if let data = try? JSONEncoder().encode(state) { preferences.set(data, forKey: Self.storageKey) }
        }
    }

    var selected: AIConnection? { state.selected }
    var isAvailable: Bool { state.isAvailable }

    /// Start once from the application composition root, never from a model menu.
    @MainActor func startModelCatalogSync(runtime: AIRuntime) {
        guard modelCatalogSync == nil else { return }
        modelCatalogSync = AIProviderCatalogSync(configuration: self, runtime: runtime)
        modelCatalogSync?.start()
    }

    @MainActor func refreshModelCatalogs(runtime: AIRuntime, connection: AIConnection? = nil) {
        startModelCatalogSync(runtime: runtime)
        modelCatalogSync?.refresh(force: true, connection: connection)
    }

    @MainActor func setCatalogSyncStatus(_ status: String, for identity: String) {
        catalogSyncStatus[identity] = status
    }

    /// Merge one provider atomically into the same persistent snapshot all pickers read.
    /// Existing IDs, defaults and visibility survive; failed/stale requests never replace it.
    @discardableResult
    func applyProviderCatalog(_ models: [AIProviderModel], snapshot: AIConnection, at date: Date) -> Bool {
        guard !models.isEmpty, state.enabled,
              let current = state.connections.first(where: { $0.id == snapshot.id }),
              current.catalogIdentity == snapshot.catalogIdentity, current.model == snapshot.model,
              current.additionalParametersJSON == snapshot.additionalParametersJSON,
              current.modelTask == snapshot.modelTask else { return false }
        let key = snapshot.catalogIdentity
        let previous = state.providerCatalogs?[key]
        let available = Set(models.map(\.id))
        var updated = state
        var members = [String: Int]()
        for index in updated.connections.indices where updated.connections[index].catalogIdentity == key {
            let member = updated.connections[index]
            if members[member.model] == nil { members[member.model] = index }
            if previous?.modelIDs.contains(member.id) == true {
                updated.connections[index].catalogUnavailable = available.contains(member.model) ? nil : true
            }
        }
        var catalogIDs = Set<UUID>()
        for model in models {
            let index: Int
            if let existing = members[model.id] { index = existing }
            else {
                var copy = snapshot
                copy.id = UUID()
                copy.model = model.id
                copy.name = model.name ?? model.id
                copy.credentialOwnerID = snapshot.credentialOwnerID ?? snapshot.id
                copy.contextTokens = nil
                copy.supportsImages = nil
                copy.supportsTools = nil
                copy.hiddenFromPicker = nil
                copy.modelTask = nil
                updated.connections.append(copy)
                index = updated.connections.count - 1
                members[model.id] = index
            }
            catalogIDs.insert(updated.connections[index].id)
            updated.connections[index].catalogUnavailable = nil
            let member = updated.connections[index]
            if let name = model.name, !name.isEmpty, name.utf8.count <= 512,
               name.rangeOfCharacter(from: .controlCharacters) == nil {
                if member.name.isEmpty || member.name == member.catalogName || member.name == member.model
                    || member.name == member.providerLabel || member.name == member.providerLabel + " · " + member.model {
                    updated.connections[index].name = name
                }
                updated.connections[index].catalogName = name
            }
            if let tokens = model.contextLength, tokens > 0 { updated.connections[index].contextTokens = tokens }
            if let modalities = model.architecture?.inputModalities {
                updated.connections[index].supportsImages = modalities.contains("image")
            }
            if let parameters = model.supportedParameters {
                updated.connections[index].supportsTools = parameters.contains("tools")
            }
        }
        updated.providerCatalogs = updated.providerCatalogs ?? [:]
        updated.providerCatalogs?[key] = .init(updatedAt: date, modelIDs: catalogIDs.union(previous?.modelIDs ?? []))
        persist(updated)
        return true
    }

    func setEnabled(_ enabled: Bool) {
        var updated = state
        updated.enabled = enabled
        persist(updated)
    }

    func select(_ id: UUID) {
        guard state.connections.contains(where: { $0.id == id }) else { return }
        var updated = state
        updated.selectedID = id
        persist(updated)
    }

    func setDefault(_ id: UUID?, for route: AIRoute, usesLastChatModel: Bool = false) {
        guard id == nil || state.connections.contains(where: { $0.id == id && $0.isConfigured && $0.taskKind == .text }) else { return }
        var updated = state
        var defaults = updated.defaults ?? [:]
        defaults[route] = id
        updated.defaults = defaults
        if route == .chat { updated.usesLastChatModel = usesLastChatModel }
        persist(updated)
    }

    func recordChatModel(_ id: UUID) {
        guard state.connections.contains(where: { $0.id == id }) else { return }
        var updated = state
        updated.lastChatModelID = id
        persist(updated)
    }

    func setModelVisible(_ id: UUID, visible: Bool) {
        var updated = state
        guard let index = updated.connections.firstIndex(where: { $0.id == id }) else { return }
        updated.connections[index].hiddenFromPicker = visible ? nil : true
        persist(updated)
    }

    func addProviderModels(_ models: [String], from connection: AIConnection, discoveredUsing target: AIConnection) -> Int {
        guard target == connection, state.connections.contains(connection) else { return 0 }
        var updated = state
        let existing = Set(state.connections.filter {
            ($0.credentialOwnerID ?? $0.id) == (connection.credentialOwnerID ?? connection.id)
                && $0.credentialURL == connection.credentialURL
        }.map(\.model))
        var added = 0
        for model in Set(models).sorted() where !existing.contains(model) {
            var copy = connection
            copy.id = UUID()
            copy.model = model
            copy.name = connection.providerLabel + " · " + model
            copy.contextTokens = nil
            copy.supportsImages = nil
            copy.supportsTools = nil
            copy.modelTask = nil
            if copy.taskKind != connection.taskKind, let base = connection.apiBaseURL {
                copy.endpoint = base.absoluteString
            }
            copy.credentialOwnerID = connection.credentialOwnerID ?? connection.id
            updated.connections.append(copy)
            added += 1
        }
        persist(updated)
        return added
    }

    /// Publish a whole subscription catalog together. IDs/defaults survive account changes,
    /// while requestIdentity changes so old conversations and in-flight work cannot follow.
    func reconnectSubscription(_ snapshot: AIConnection, accountID: String, models: [String]) -> (added: Int, unavailable: Int)? {
        let supported = Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard snapshot.protocolKind.isSubscription, !accountID.isEmpty, !supported.isEmpty,
              state.connections.contains(snapshot) else { return nil }
        let owner = snapshot.credentialOwnerID ?? snapshot.id
        var updated = state
        var retained = [String: UUID]()
        var aliases = [UUID: UUID]()
        var unavailable = 0
        for index in updated.connections.indices {
            var member = updated.connections[index]
            guard (member.credentialOwnerID ?? member.id) == owner,
                  member.protocolKind == snapshot.protocolKind else { continue }
            if member.model == "default", member.id == snapshot.id { member.model = supported.sorted()[0] }
            if let existing = retained[member.model] { aliases[member.id] = existing; continue }
            retained[member.model] = member.id
            member.subscriptionAccountID = accountID
            member.executablePath = snapshot.executablePath
            member.accountFolder = snapshot.accountFolder
            member.subscriptionEnabled = snapshot.subscriptionEnabled == true && supported.contains(member.model)
            if !supported.contains(member.model) { member.hiddenFromPicker = true; unavailable += 1 }
            updated.connections[index] = member
        }
        updated.connections.removeAll { aliases[$0.id] != nil }
        if updated.selectedID == nil { updated.selectedID = aliases[snapshot.id] ?? snapshot.id }
        var defaults = updated.defaults ?? [:]
        for route in AIRoute.allCases where defaults[route] == nil { defaults[route] = aliases[snapshot.id] ?? snapshot.id }
        updated.defaults = defaults
        if let selected = updated.selectedID { updated.selectedID = aliases[selected] ?? selected }
        updated.defaults = updated.defaults?.mapValues { aliases[$0] ?? $0 }
        if let last = updated.lastChatModelID { updated.lastChatModelID = aliases[last] ?? last }
        var added = 0
        for model in supported.sorted() where retained[model] == nil {
            var member = snapshot
            member.id = UUID()
            member.model = model
            member.name = snapshot.providerLabel + " · " + model
            member.credentialOwnerID = owner
            member.subscriptionAccountID = accountID
            member.contextTokens = nil
            member.supportsImages = nil
            member.supportsTools = nil
            updated.connections.append(member)
            added += 1
        }
        persist(updated)
        return (added, unavailable)
    }

    func setSubscriptionEnabled(_ connection: AIConnection, enabled: Bool) {
        var updated = state
        let owner = connection.credentialOwnerID ?? connection.id
        if !updated.connections.contains(where: { $0.id == connection.id }) { updated.connections.append(connection) }
        for index in updated.connections.indices where (updated.connections[index].credentialOwnerID ?? updated.connections[index].id) == owner {
            updated.connections[index].subscriptionEnabled = enabled
        }
        persist(updated)
    }

    func applyCustomProviders(_ models: [(AIConnection, String?)]) async throws {
        // Reject incoming collisions before touching credentials or publishing any state.
        let ids = models.map { $0.0.id }
        guard Set(ids).count == ids.count,
              Set(state.connections.filter { $0.customConfigID == nil }.map(\.id)).isDisjoint(with: ids) else {
            throw CredentialError.invalidCatalog
        }
        try await Task.detached(priority: .utility) {
            try Self.stageCustomProviderKeys(models)
        }.value
        var updated = state
        // Older imports may already contain duplicate IDs. Reload must not trap.
        var existing = [UUID: AIConnection]()
        for connection in state.connections where existing[connection.id] == nil { existing[connection.id] = connection }
        updated.connections.removeAll { $0.customConfigID != nil }
        updated.connections += models.map { connection, _ in
            var result = connection
            result.hiddenFromPicker = existing[connection.id]?.hiddenFromPicker
            return result
        }
        persist(updated)
    }

    private static func stageCustomProviderKeys(_ models: [(AIConnection, String?)]) throws {
        var previousKeys = [(AIConnection, String?)]()
        do {
            for (connection, key) in models {
                guard connection.isValidConfiguration else { throw CredentialError.unavailable }
                let previous = try Self.key(for: connection)
                previousKeys.append((connection, previous))
                if key == previous { continue }
                if let key, !key.isEmpty { try Self.saveKey(key, for: connection) }
                else { try Self.deleteKey(for: connection) }
            }
        } catch {
            for (connection, key) in previousKeys.reversed() {
                if let key { try? Self.saveKey(key, for: connection) }
                else { try? Self.deleteKey(for: connection) }
            }
            throw error
        }
    }

    @discardableResult
    func save(_ draft: AIConnection, selectAsDefault: Bool = true) -> Bool {
        var connection = draft
        connection.endpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connection.isValidConfiguration else { return false }
        var updated = state
        if let index = updated.connections.firstIndex(where: { $0.id == connection.id }) {
            let original = updated.connections[index]
            connection.legacyAccount = original.legacyAccount
            if original.credentialURL != connection.credentialURL {
                if let oldEndpoint = original.credentialURL?.absoluteString {
                    var previous = Set(original.previousEndpoints ?? [])
                    previous.insert(oldEndpoint)
                    if let current = connection.credentialURL?.absoluteString { previous.remove(current) }
                    connection.previousEndpoints = previous.sorted()
                }
            }
            updated.connections[index] = connection
        } else {
            updated.connections.append(connection)
        }
        if connection.taskKind == .text, selectAsDefault || updated.selectedID == nil { updated.selectedID = connection.id }
        var defaults = updated.defaults ?? [:]
        if connection.taskKind == .text {
            for route in AIRoute.allCases where defaults[route] == nil { defaults[route] = connection.id }
        }
        updated.defaults = defaults
        persist(updated)
        return true
    }

    func remove(_ connection: AIConnection) throws {
        guard let saved = state.connections.first(where: { $0.id == connection.id }) else { return }
        let credentialOwner = saved.credentialOwnerID ?? saved.id
        if !state.connections.contains(where: { $0.id != saved.id && ($0.credentialOwnerID ?? $0.id) == credentialOwner }) {
            try Self.deleteKey(for: saved, includingPreviousEndpoints: true)
        }
        var updated = state
        updated.connections.removeAll { $0.id == connection.id }
        if updated.selectedID == connection.id { updated.selectedID = nil }
        persist(updated)
    }

    private func persist(_ updated: State) {
        guard updated != state, let data = try? JSONEncoder().encode(updated) else { return }
        preferences.set(data, forKey: Self.storageKey)
        state = updated
    }

    enum CredentialError: Error, LocalizedError {
        case unavailable, invalidKey, invalidCatalog
        var errorDescription: String? {
            switch self {
            case .unavailable: "无法访问此连接的钥匙串密钥。"
            case .invalidKey: "请输入一行有效的 API 密钥。"
            case .invalidCatalog: "模型配置存在重复标识，之前的有效配置继续可用。"
            }
        }
    }

    static func credentialQueries(for connection: AIConnection, includingPreviousEndpoints: Bool = false) -> [[String: Any]] {
        guard !connection.protocolKind.isSubscription else { return [] }
        func query(service: String, account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
             kSecAttrAccount as String: account]
        }

        let currentURL = connection.credentialURL
        var endpoints = currentURL.map { [$0.absoluteString] } ?? []
        if includingPreviousEndpoints { endpoints.append(contentsOf: connection.previousEndpoints ?? []) }
        var result = endpoints.map { query(service: service, account: (connection.credentialOwnerID ?? connection.id).uuidString + "|" + $0) }
        if let account = connection.legacyAccount,
           includingPreviousEndpoints || (currentURL != nil && currentURL == AIConnection.completionURL(for: account)) {
            result.append(query(service: legacyService, account: account))
        }
        return result
    }

    static func hasKey(for connection: AIConnection) -> Bool {
        credentialQueries(for: connection).contains { query in
            SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        }
    }

    /// Draft credentials are request-local. Never reuse a saved key at another endpoint.
    static func discoveryKey(for target: AIConnection, original: AIConnection?, enteredKey: String,
                             readSaved: (AIConnection) throws -> String? = { try key(for: $0) }) throws -> String? {
        let entered = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        guard let original, let endpoint = target.credentialURL,
              endpoint == original.credentialURL else { return nil }
        return try readSaved(original)
    }

    static func key(for connection: AIConnection) throws -> String? {
        for var query in credentialQueries(for: connection) {
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let bytes = result as? Data,
                  let key = String(data: bytes, encoding: .utf8) else { throw CredentialError.unavailable }
            return key
        }
        return nil
    }

    static func saveKey(_ input: String, for connection: AIConnection) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 8192, key.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw CredentialError.invalidKey }
        guard var query = credentialQueries(for: connection).first else { throw CredentialError.unavailable }
        let values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = values[kSecValueData as String]
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.unavailable }
    }

    static func deleteKey(for connection: AIConnection, includingPreviousEndpoints: Bool = false) throws {
        for query in credentialQueries(for: connection, includingPreviousEndpoints: includingPreviousEndpoints).reversed() {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable }
        }
    }
}

/// Cache bookkeeping contains no credentials. Model data itself lives in State.connections,
/// so settings, Quick AI, chat and commands never need a network request to open a menu.
struct AIProviderCatalogCache: Codable, Equatable {
    let updatedAt: Date
    let modelIDs: Set<UUID>
}

extension AIConnection {
    var catalogIdentity: String {
        [(credentialOwnerID ?? id).uuidString, credentialURL?.absoluteString ?? "",
         protocolKind.rawValue, providerID ?? ""].joined(separator: "|")
    }
}

@MainActor
final class AIProviderCatalogSync {
    private weak var configuration: AIConfiguration?
    private let runtime: AIRuntime
    private let readKey: @Sendable (AIConnection) throws -> String?
    private let now: () -> Date
    private var observation: AnyCancellable?
    private var timer: Task<Void, Never>?
    private var requests = [String: Task<Void, Never>]()
    private var generations = [String: UUID]()
    private var attempts = [String: Date]()
    nonisolated static let cacheLifetime: TimeInterval = 6 * 60 * 60

    init(configuration: AIConfiguration, runtime: AIRuntime,
         now: @escaping () -> Date = Date.init,
         readKey: @escaping @Sendable (AIConnection) throws -> String? = { try AIConfiguration.key(for: $0) }) {
        self.configuration = configuration
        self.runtime = runtime
        self.readKey = readKey
        self.now = now
    }

    func start() {
        observation = configuration?.$state.sink { [weak self] _ in
            // @Published sends before the stored state changes.
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000) }
                catch { return }
                self?.refresh()
            }
        }
    }

    deinit {
        timer?.cancel()
        for request in requests.values { request.cancel() }
    }

    func refresh(force: Bool = false, connection: AIConnection? = nil) {
        guard let configuration else { return }
        let state = configuration.state
        var sources = [String: AIConnection]()
        // YAML declares its own explicit catalog, subscriptions have their own account lifecycle.
        for source in state.connections where state.enabled && !source.protocolKind.isSubscription
            && source.customConfigID == nil && source.isValidConfiguration {
            let key = source.catalogIdentity
            if sources[key] == nil || source.credentialOwnerID == nil { sources[key] = source }
        }
        for key in Array(requests.keys) where sources[key] == nil {
            requests.removeValue(forKey: key)?.cancel()
            generations[key] = nil
            configuration.setCatalogSyncStatus("同步已停止，保留已有目录。", for: key)
        }
        for (key, source) in sources {
            if let connection, connection.catalogIdentity != key { continue }
            if force { requests.removeValue(forKey: key)?.cancel() }
            guard requests[key] == nil else { continue }
            let date = now()
            if !force {
                if let cached = state.providerCatalogs?[key], date.timeIntervalSince(cached.updatedAt) < Self.cacheLifetime { continue }
                // Failed/empty endpoints do not cause a retry loop on unrelated settings changes.
                if let attempted = attempts[key], date.timeIntervalSince(attempted) < 5 * 60 { continue }
            }
            attempts[key] = date
            let generation = UUID()
            generations[key] = generation
            let runtime = runtime
            let readKey = readKey
            configuration.setCatalogSyncStatus("正在同步模型…", for: key)
            requests[key] = Task { [weak self] in
                do {
                    let models = try await runtime.listModelCatalog(connection: source, readKey: readKey)
                    guard !Task.isCancelled, let self, self.generations[key] == generation else { return }
                    if self.configuration?.applyProviderCatalog(models, snapshot: source, at: self.now()) == true {
                        self.configuration?.setCatalogSyncStatus("已同步 \(models.count) 个模型。", for: key)
                    } else {
                        self.configuration?.setCatalogSyncStatus("目录未返回模型或连接已变更，保留已有目录。", for: key)
                    }
                } catch {
                    // Offline, unsupported and denied catalogs keep the last working snapshot.
                    // No provider error bodies or credentials are persisted.
                    if !Task.isCancelled, let self, self.generations[key] == generation {
                        self.configuration?.setCatalogSyncStatus("同步失败，保留已有目录；请检查网络、Key 和目录访问权限后重试。", for: key)
                    }
                }
                guard let self, self.generations[key] == generation else { return }
                self.requests[key] = nil
            }
        }
    }
}
