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

    @Published private(set) var state: State
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
