import Foundation
import XCTest
@testable import KeylaneCore

final class RaycastStorePreferencesTests: XCTestCase {
    private typealias Field = RaycastExtensionManifest.Field

    private func fields(_ json: String) throws -> [Field] {
        try JSONDecoder().decode([Field].self, from: Data(json.utf8))
    }

    func testScopePreventsCollisionsAndRequiredPasswordIsPresenceOnly() throws {
        let shared = try fields(#"[{"name":"token","type":"password","required":true,"default":"ignored"}]"#)
        let schema = try RaycastStorePreferenceSchema(extensionFields: shared, commandID: "x:y", commandFields: shared)
        let global = RaycastStorePreferenceKey(scope: .extensionWide, name: "token")
        let command = RaycastStorePreferenceKey(scope: .command("x:y"), name: "token")
        let snapshot = RaycastStorePreferenceSnapshot(values: [global: .string("not trusted")], storedSecretKeys: [command])
        XCTAssertEqual(schema.validate(snapshot: snapshot), [.missingRequired(global)])
        XCTAssertNil(schema.value(for: schema.entries[0], snapshot: snapshot))
        var changes = RaycastStorePreferenceChanges()
        changes.secrets[global] = .set("new-secret")
        XCTAssertEqual(schema.validate(snapshot: snapshot, changes: changes), [])
        changes.secrets[command] = .remove
        XCTAssertEqual(schema.validate(snapshot: snapshot, changes: changes), [.missingRequired(command)])
    }

    func testRequiredControlsValidateTypeOptionAndWhitespace() throws {
        let inputs = try fields(#"[{"name":"toggle","type":"checkbox","required":true,"default":false},{"name":"choice","type":"dropdown","required":true,"data":[{"title":"First","value":"x"}]},{"name":"label","type":"textfield","required":true}]"#)
        let schema = try RaycastStorePreferenceSchema(extensionFields: inputs, commandID: nil, commandFields: [])
        let toggle = schema.entries[0].id, choice = schema.entries[1].id, label = schema.entries[2].id
        XCTAssertEqual(schema.validate(snapshot: .init(values: [choice: .string("unknown"), label: .string("  ")])),
                       [.invalidValue(choice), .missingRequired(label)])
        XCTAssertEqual(schema.validate(snapshot: .init(values: [toggle: .string("false"), choice: .string("x"), label: .string("ok")])),
                       [.invalidValue(toggle)])
        XCTAssertEqual(schema.validate(snapshot: .init(values: [choice: .string("x"), label: .string("ok")])), [])
    }

    func testRequiredUnknownTypesFailClosedAndChangesCannotCrossSecretBoundary() throws {
        let inputs = try fields(#"[{"name":"unknown","type":"other","required":true},{"name":"optional","type":"other"},{"name":"secret","type":"password"}]"#)
        let schema = try RaycastStorePreferenceSchema(extensionFields: inputs, commandID: nil, commandFields: [])
        let unknown = schema.entries[0].id, optional = schema.entries[1].id, secret = schema.entries[2].id
        XCTAssertEqual(schema.validate(snapshot: .init(values: [unknown: .string("ignored")])), [.unsupportedField(unknown)])
        var changes = RaycastStorePreferenceChanges()
        changes.secrets[optional] = .set("no")
        changes.values[secret] = .set(.string("no"))
        XCTAssertEqual(schema.validate(snapshot: .init(), changes: changes),
                       [.unexpectedChange(secret), .unexpectedChange(optional), .unsupportedField(unknown)])
    }

    func testDuplicateNamesWithinScopeAndInvalidNamesAreRejected() throws {
        let input = try fields(#"[{"name":"x","type":"textfield"}]"#)
        XCTAssertThrowsError(try RaycastStorePreferenceSchema(extensionFields: input + input, commandID: nil, commandFields: []))
        let invalid = try fields(#"[{"name":"","type":"textfield"}]"#)
        XCTAssertThrowsError(try RaycastStorePreferenceSchema(extensionFields: invalid, commandID: nil, commandFields: []))
    }

    func testResetUsesValidDefaultAndEmptyPasswordDoesNotSetSecret() throws {
        let inputs = try fields(#"[{"name":"text","type":"textfield","required":true,"default":"default"},{"name":"secret","type":"password"}]"#)
        let schema = try RaycastStorePreferenceSchema(extensionFields: inputs, commandID: nil, commandFields: [])
        var changes = RaycastStorePreferenceChanges()
        let text = schema.entries[0], secret = schema.entries[1].id
        changes.values[text.id] = .reset
        changes.secrets[secret] = .set("")
        XCTAssertEqual(schema.value(for: text, snapshot: .init(values: [text.id: .string("stored")]), changes: changes), .string("default"))
        XCTAssertEqual(schema.validate(snapshot: .init(), changes: changes), [.invalidValue(secret)])
    }
}

private actor FixturePreferencePersistence: RaycastStorePreferencePersistence {
    let installationID: UUID
    let generation: UInt64
    let schema: RaycastStorePreferenceSchema
    var snapshot = RaycastStorePreferenceSnapshot()
    init(installationID: UUID, generation: UInt64, schema: RaycastStorePreferenceSchema) {
        self.installationID = installationID; self.generation = generation; self.schema = schema
    }
    func load(installationID: UUID, generation: UInt64) async throws -> RaycastStorePreferenceSnapshot {
        guard self.installationID == installationID, self.generation == generation else { throw CocoaError(.fileReadNoPermission) }
        return snapshot
    }
    func save(installationID: UUID, generation: UInt64, changes: RaycastStorePreferenceChanges) async throws {
        _ = try await load(installationID: installationID, generation: generation)
        guard schema.validate(snapshot: snapshot, changes: changes).isEmpty else { throw CocoaError(.fileReadNoPermission) }
        var values = snapshot.values
        var secrets = snapshot.storedSecretKeys
        for entry in schema.entries where entry.field.type != "password" {
            values[entry.id] = schema.value(for: entry, snapshot: snapshot, changes: changes)
        }
        for (key, change) in changes.secrets {
            switch change {
            case .set: secrets.insert(key) // Fixture remembers presence only, never secret contents.
            case .remove: secrets.remove(key)
            }
        }
        snapshot = .init(values: values, storedSecretKeys: secrets)
    }
}

extension RaycastStorePreferencesTests {
    func testInjectedPersistenceNeverReturnsSecretContentsAndRejectsStaleGeneration() async throws {
        let input = try fields(#"[{"name":"token","type":"password","required":true},{"name":"label","type":"textfield"}]"#)
        let schema = try RaycastStorePreferenceSchema(extensionFields: input, commandID: nil, commandFields: [])
        let id = UUID(), persistence = FixturePreferencePersistence(installationID: UUID(), generation: 2, schema: schema)
        var changes = RaycastStorePreferenceChanges()
        changes.secrets[schema.entries[0].id] = .set("synthetic-only")
        do { try await persistence.save(installationID: id, generation: 1, changes: changes); XCTFail() } catch {}
        let correctID = await persistence.installationID
        let unchanged = try await persistence.load(installationID: correctID, generation: 2)
        XCTAssertTrue(unchanged.storedSecretKeys.isEmpty)
        try await persistence.save(installationID: correctID, generation: 2, changes: changes)
        let saved = try await persistence.load(installationID: correctID, generation: 2)
        XCTAssertTrue(saved.storedSecretKeys.contains(schema.entries[0].id))
        XCTAssertNil(saved.values[schema.entries[0].id])
    }
}
