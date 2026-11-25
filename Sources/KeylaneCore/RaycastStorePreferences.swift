import Foundation

public struct RaycastStorePreferenceKey: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case extensionWide
        case command(String)
    }

    public let scope: Scope
    public let name: String

    public init(scope: Scope, name: String) {
        self.scope = scope
        self.name = name
    }
}

public struct RaycastStorePreferenceSnapshot: Sendable {
    public let values: [RaycastStorePreferenceKey: RaycastExtensionManifest.PreferenceValue]
    var launchSecrets: [RaycastStorePreferenceKey: String] = [:]
    public let storedSecretKeys: Set<RaycastStorePreferenceKey>

    public init(values: [RaycastStorePreferenceKey: RaycastExtensionManifest.PreferenceValue] = [:],
                storedSecretKeys: Set<RaycastStorePreferenceKey> = []) {
        self.values = values
        self.storedSecretKeys = storedSecretKeys
    }
}

/// Passwords are write-only, separate from ordinary values, and never encoded.
public struct RaycastStorePreferenceChanges: Sendable {
    public enum ValueChange: Sendable {
        case set(RaycastExtensionManifest.PreferenceValue)
        case reset
    }
    public enum SecretChange: Sendable {
        case set(String)
        case remove
    }

    public var values: [RaycastStorePreferenceKey: ValueChange] = [:]
    public var secrets: [RaycastStorePreferenceKey: SecretChange] = [:]
    public init() {}
}

/// Implementers must verify installation identity and generation at load and commit.
/// Save is atomic from the caller's perspective; secure storage is not part of
/// the ordinary persistence payload, and load must never return secret contents.
public protocol RaycastStorePreferencePersistence: Sendable {
    func load(installationID: UUID, generation: UInt64) async throws -> RaycastStorePreferenceSnapshot
    func save(installationID: UUID, generation: UInt64, changes: RaycastStorePreferenceChanges) async throws
}

public struct RaycastStorePreferenceSchema: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: RaycastStorePreferenceKey
        public let field: RaycastExtensionManifest.Field
    }
    public enum Issue: Error, Equatable, Sendable {
        case unknownCommand(String)
        case invalidName(RaycastStorePreferenceKey)
        case duplicateField(RaycastStorePreferenceKey)
        case unsupportedField(RaycastStorePreferenceKey)
        case missingRequired(RaycastStorePreferenceKey)
        case invalidValue(RaycastStorePreferenceKey)
        case unexpectedChange(RaycastStorePreferenceKey)
    }

    public let entries: [Entry]

    public init(manifest: RaycastExtensionManifest, commandID: String? = nil) throws {
        let command: RaycastExtensionManifest.Command?
        if let commandID {
            guard let match = manifest.commands.first(where: { $0.id == commandID }) else {
                throw Issue.unknownCommand(commandID)
            }
            command = match
        } else {
            command = nil
        }
        try self.init(extensionFields: manifest.preferences, commandID: commandID,
                      commandFields: command?.preferences ?? [])
    }

    init(extensionFields: [RaycastExtensionManifest.Field], commandID: String?,
         commandFields: [RaycastExtensionManifest.Field]) throws {
        var inputs: [(RaycastStorePreferenceKey.Scope, [RaycastExtensionManifest.Field])] = [(.extensionWide, extensionFields)]
        if let commandID { inputs.append((.command(commandID), commandFields)) }
        var keys: Set<RaycastStorePreferenceKey> = []
        var entries: [Entry] = []
        for (scope, fields) in inputs {
            for field in fields {
                let key = RaycastStorePreferenceKey(scope: scope, name: field.name)
                guard !field.name.isEmpty, field.name.utf8.count <= 256,
                      !field.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else { throw Issue.invalidName(key) }
                guard keys.insert(key).inserted else { throw Issue.duplicateField(key) }
                entries.append(.init(id: key, field: field))
            }
        }
        self.entries = entries
    }

    /// Resolves only non-secret values. An explicit reset reapplies a valid schema default.
    public func value(for entry: Entry, snapshot: RaycastStorePreferenceSnapshot,
                      changes: RaycastStorePreferenceChanges = .init()) -> RaycastExtensionManifest.PreferenceValue? {
        guard entry.field.type != "password" else { return nil }
        switch changes.values[entry.id] {
        case .set(let value): return value
        case .reset: return Self.validDefault(entry.field)
        case nil: return snapshot.values[entry.id] ?? Self.validDefault(entry.field)
        }
    }

    public func validate(snapshot: RaycastStorePreferenceSnapshot,
                         changes: RaycastStorePreferenceChanges = .init()) -> [Issue] {
        let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.field) })
        var issues: [Issue] = []
        for key in changes.values.keys where byKey[key] == nil || byKey[key]?.type == "password" {
            issues.append(.unexpectedChange(key))
        }
        for key in changes.secrets.keys where byKey[key]?.type != "password" {
            issues.append(.unexpectedChange(key))
        }
        for entry in entries {
            let field = entry.field
            let key = entry.id
            if field.type == "password" {
                let present: Bool
                switch changes.secrets[key] {
                case .set(let secret):
                    guard !secret.isEmpty, secret.utf8.count <= 1_024 else {
                        issues.append(.invalidValue(key))
                        continue
                    }
                    present = true
                case .remove: present = false
                case nil: present = snapshot.storedSecretKeys.contains(key)
                }
                if field.required == true && !present { issues.append(.missingRequired(key)) }
                continue
            }
            guard ["checkbox", "dropdown", "textfield", "appPicker", "file", "directory"].contains(field.type) else {
                if field.required == true || changes.values[key] != nil { issues.append(.unsupportedField(key)) }
                continue
            }
            // A file/app string may represent a preference but must not confer host
            // access. The production bridge independently validates its grant.
            if let current = value(for: entry, snapshot: snapshot, changes: changes) {
                if !field.accepts(current) { issues.append(.invalidValue(key)) }
                else if case .string(let text) = current,
                        field.required == true && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.missingRequired(key))
                }
            } else if field.required == true {
                issues.append(.missingRequired(key))
            }
        }
        return issues
    }

    private static func validDefault(_ field: RaycastExtensionManifest.Field) -> RaycastExtensionManifest.PreferenceValue? {
        guard let value = field.defaultValue, field.accepts(value) else { return nil }
        return value
    }
}
