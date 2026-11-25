import CryptoKit
import XCTest
@testable import KeylaneCore

private struct DiskRegistryFixtureTrust: RaycastStoreArtifactTrust {
    let source: RaycastStoreSource
    let bytes: Data
    let manifest: RaycastExtensionManifest
    var revocationFails = false
    var expectedInstallationID: UUID?
    var grants: Set<String> = ["toast"]

    func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        guard bytes == self.bytes, source == self.source, expectedInstallationID == nil || installationID == expectedInstallationID else { throw RaycastStoreDiskRegistry.Failure.integrity }
        return .init(extensionID: source.slug, manifest: manifest, requiredCapabilities: grants)
    }

    func revoke(installationID: UUID, before generation: UInt64) async throws {
        if revocationFails { throw CocoaError(.fileWriteUnknown) }
    }
}

final class RaycastStoreDiskRegistryTests: XCTestCase {
    private typealias Failure = RaycastStoreDiskRegistry.Failure

    private func source(revision: String = String(repeating: "a", count: 40)) throws -> RaycastStoreSource {
        try .init(slug: "demo", catalog: .init(revision: revision, slugs: ["demo"]))
    }

    private func fixture(withPreferences: Bool = false) throws -> (root: URL, trust: DiskRegistryFixtureTrust, digest: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manifestRoot = root.appendingPathComponent("manifest")
        try FileManager.default.createDirectory(at: manifestRoot.appendingPathComponent("src"), withIntermediateDirectories: true)
        let manifest = withPreferences
            ? #"{"name":"demo","author":"tests","title":"Fixture","preferences":[{"name":"value","type":"textfield"},{"name":"password","type":"password"},{"name":"path","type":"file"}],"commands":[{"name":"hello","title":"Hello","mode":"no-view","preferences":[{"name":"value","type":"checkbox"},{"name":"option","type":"dropdown","data":[{"title":"A","value":"a"}]}]}]}"#
            : #"{"name":"demo","author":"tests","title":"Fixture","commands":[{"name":"hello","title":"Hello","mode":"no-view"}]}"#
        try Data(manifest.utf8).write(to: manifestRoot.appendingPathComponent("package.json"))
        try Data("// metadata only".utf8).write(to: manifestRoot.appendingPathComponent("src/hello.js"))
        let bytes = Data("synthetic verified test artifact".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (root, try .init(source: source(), bytes: bytes, manifest: .read(directory: manifestRoot)), digest)
    }

    func testBootstrapVerifiesExistingProfileWithoutCreatingRootOrLock() async throws {
        let (root, trust, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registryRoot = root.appendingPathComponent("existing-registry")
        let storage = ProtectedReceiptFixtureStore()
        let recipe = RaycastStoreArtifactSeal.Recipe(identifier: "synthetic", runtimeDigest: String(repeating: "0", count: 64),
                                                   qualifiedAPIVersions: [])
        let anchor = try RaycastStoreProtectedReceiptState(storage: storage, registryID: UUID(),
            publicKey: P256.Signing.PrivateKey().publicKey, recipe: recipe)
        XCTAssertThrowsError(try RaycastStoreDiskRegistry(root: registryRoot, trust: trust, anchor: anchor,
                                                          requiresExistingRoot: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.path))

        try FileManager.default.createDirectory(at: registryRoot, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let registry = try RaycastStoreDiskRegistry(root: registryRoot, trust: trust, anchor: anchor,
                                                    requiresExistingRoot: true)
        do {
            try await registry.verifyExistingProtectedRegistry()
            XCTFail("Unenrolled profile may not activate Store")
        } catch { XCTAssertEqual(error as? Failure, .protectedStateRecovery(.setupRequired)) }
        XCTAssertNil(try storage.read())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: registryRoot.path), [])

        try anchor.initializeNewRegistry(observedRegistryDigest: nil) // Inert fixture only.
        let enrolled = try storage.read()
        try await registry.verifyExistingProtectedRegistry()
        XCTAssertEqual(try storage.read(), enrolled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: registryRoot.path), [])
    }

    func testProtectedPasswordAndFilePreferenceSurviveReopenWithoutDisclosingPasswordToSettings() async throws {
        let (root, original, digest) = try fixture(withPreferences: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryRoot = root.appendingPathComponent("protected-preferences")
        var configured = original
        configured.grants = [MacOSNoViewCapabilities.preferences, MacOSNoViewCapabilities.secretPreferences,
                             MacOSNoViewCapabilities.selectedPreferences]
        let trust = configured
        let profileID = UUID(), key = P256.Signing.PrivateKey()
        let vault = MacOSReviewedPreferenceVault(profileKey: key.rawRepresentation, profileID: profileID)
        let anchor = try RaycastStoreProtectedReceiptState(storage: ProtectedReceiptFixtureStore(), registryID: profileID,
            publicKey: key.publicKey, recipe: .init(identifier: "test", runtimeDigest: String(repeating: "0", count: 64),
                                                   qualifiedAPIVersions: []))
        try anchor.initializeNewRegistry(observedRegistryDigest: nil)
        let registry = try RaycastStoreDiskRegistry(root: registryRoot, trust: trust, anchor: anchor,
                                                    requiresExistingRoot: false, preferenceVault: vault)
        let prepared = try await registry.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source,
                                                  grantedCapabilities: trust.grants)
        let installation = try await registry.activate(prepared)
        let command = try XCTUnwrap(installation.manifest.commands.first)
        let password = RaycastStorePreferenceKey(scope: .extensionWide, name: "password")
        let path = RaycastStorePreferenceKey(scope: .extensionWide, name: "path")
        let plain = "synthesized-unit-test-password"
        var changes = RaycastStorePreferenceChanges()
        changes.secrets[password] = .set(plain)
        changes.values[path] = .set(.string("/test/selected.txt"))
        try await registry.save(installationID: installation.id, generation: installation.generation, changes: changes)

        let persisted = try Data(contentsOf: registryRoot.appendingPathComponent("registry.json"))
        XCTAssertNil(persisted.range(of: Data(plain.utf8)))
        let reopened = try RaycastStoreDiskRegistry(root: registryRoot, trust: trust, anchor: anchor,
                                                    requiresExistingRoot: true, preferenceVault: vault)
        let metadata = try await reopened.load(installationID: installation.id, generation: installation.generation)
        XCTAssertEqual(metadata.storedSecretKeys, [password])
        XCTAssertTrue(metadata.launchSecrets.isEmpty)
        XCTAssertEqual(metadata.values[path], .string("/test/selected.txt"))
        let artifact = try await reopened.validate(installationID: installation.id, generation: installation.generation,
                                                   commandID: command.id, capabilities: [])
        let run = RaycastStoreInstallCoordinator.RunContext(installation: installation, commandID: command.id,
                                                            artifact: artifact, registry: reopened)
        let secrets = try await reopened.withCurrentRun(run, includeSecrets: true) { _, _, snapshot in snapshot.launchSecrets }
        XCTAssertEqual(secrets[password], plain)
        let ciphertext = try vault.seal(secrets, installationID: installation.id)
        XCTAssertThrowsError(try vault.open(ciphertext, installationID: UUID()))
        try await reopened.uninstall(installationID: installation.id, expectedGeneration: installation.generation)
        let remaining = try await reopened.installations()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testOrdinaryPreferencesPersistAcrossReopenAndLifecycleButNotReinstall() async throws {
        let (root, trust, digest) = try fixture(withPreferences: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryRoot = root.appendingPathComponent("registry")
        let store = try RaycastStoreDiskRegistry(root: registryRoot, trust: trust)
        let prepared = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"])
        let installed = try await store.activate(prepared)
        let command = try XCTUnwrap(installed.manifest.commands.first)
        let regular = RaycastStorePreferenceKey(scope: .extensionWide, name: "value")
        let scoped = RaycastStorePreferenceKey(scope: .command(command.id), name: "value")
        var draft = RaycastStorePreferenceChanges()
        draft.values[regular] = .set(.string("synthetic"))
        draft.values[scoped] = .set(.bool(true))
        try await store.save(installationID: installed.id, generation: 1, changes: draft)

        let reopened = try RaycastStoreDiskRegistry(root: registryRoot, trust: trust)
        let first = try await reopened.load(installationID: installed.id, generation: 1)
        XCTAssertEqual(first.values, [regular: .string("synthetic"), scoped: .bool(true)])
        XCTAssertTrue(first.storedSecretKeys.isEmpty)
        do { try await reopened.save(installationID: UUID(), generation: 1, changes: draft); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .missing) }

        let disabled = try await store.setEnabled(installationID: installed.id, expectedGeneration: 1, enabled: false)
        do { try await reopened.save(installationID: installed.id, generation: 1, changes: draft); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .stale) }
        do { try await reopened.save(installationID: installed.id, generation: disabled.generation, changes: draft); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .inactive) }
        do { _ = try await reopened.load(installationID: installed.id, generation: disabled.generation); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .inactive) }

        let enabled = try await store.setEnabled(installationID: installed.id, expectedGeneration: disabled.generation, enabled: true)
        let retained = try await reopened.load(installationID: installed.id, generation: enabled.generation)
        XCTAssertEqual(retained.values, first.values)
        var reset = RaycastStorePreferenceChanges()
        reset.values[regular] = .reset
        try await reopened.save(installationID: installed.id, generation: enabled.generation, changes: reset)
        let resetSnapshot = try await store.load(installationID: installed.id, generation: enabled.generation)
        XCTAssertEqual(resetSnapshot.values, [scoped: .bool(true)])

        try await store.uninstall(installationID: installed.id, expectedGeneration: enabled.generation)
        do { try await reopened.save(installationID: installed.id, generation: enabled.generation, changes: draft); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .missing) }
        let preparedAgain = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"])
        let installedAgain = try await store.activate(preparedAgain)
        XCTAssertNotEqual(installed.id, installedAgain.id)
        let empty = try await reopened.load(installationID: installedAgain.id, generation: installedAgain.generation)
        XCTAssertTrue(empty.values.isEmpty)
    }

    func testOrdinaryPreferencesRejectEntireInvalidTransactionWithoutPersistingSecrets() async throws {
        let (root, trust, digest) = try fixture(withPreferences: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryRoot = root.appendingPathComponent("registry")
        let store = try RaycastStoreDiskRegistry(root: registryRoot, trust: trust)
        let prepared = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"])
        let installed = try await store.activate(prepared)
        let command = try XCTUnwrap(installed.manifest.commands.first)
        let regular = RaycastStorePreferenceKey(scope: .extensionWide, name: "value")
        let secret = RaycastStorePreferenceKey(scope: .extensionWide, name: "password")
        let original = try Data(contentsOf: registryRoot.appendingPathComponent("registry.json"))

        var invalid = RaycastStorePreferenceChanges()
        invalid.values[regular] = .set(.string("not committed"))
        invalid.secrets[secret] = .set("SYNTHETIC-CREDENTIAL")
        do { try await store.save(installationID: installed.id, generation: 1, changes: invalid); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .preference) }
        for (key, invalidValue) in [
            (secret, RaycastExtensionManifest.PreferenceValue.string("ordinary password bypass")),
            (.init(scope: .extensionWide, name: "path"), .string("synthetic-path")),
            (.init(scope: .command("unknown"), name: "value"), .bool(true)),
            (.init(scope: .command(command.id), name: "option"), .string("not-supported")),
            (regular, .string(String(repeating: "a", count: 4_097))),
        ] {
            var change = RaycastStorePreferenceChanges()
            change.values[key] = .set(invalidValue)
            do { try await store.save(installationID: installed.id, generation: 1, changes: change); XCTFail() }
            catch { XCTAssertEqual(error as? Failure, .preference) }
        }
        XCTAssertEqual(try Data(contentsOf: registryRoot.appendingPathComponent("registry.json")), original)
    }

    func testOrdinaryPreferencesUseProtectedHeadAndRejectRollbackOrFailedAdvance() async throws {
        let (root, trust, digest) = try fixture(withPreferences: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryRoot = root.appendingPathComponent("registry")
        let registryFile = registryRoot.appendingPathComponent("registry.json")
        let storage = ProtectedReceiptFixtureStore(), registryID = UUID()
        let testPublicKey = P256.Signing.PrivateKey().publicKey
        let recipe = RaycastStoreArtifactSeal.Recipe(identifier: "synthetic-recipe",
            runtimeDigest: String(repeating: "0", count: 64), qualifiedAPIVersions: [])
        func makeAnchor() throws -> RaycastStoreProtectedReceiptState {
            try .init(storage: storage, registryID: registryID, publicKey: testPublicKey, recipe: recipe)
        }
        let anchor = try makeAnchor()
        try anchor.initializeNewRegistry(observedRegistryDigest: nil)
        let store = try RaycastStoreDiskRegistry(root: registryRoot, trust: trust, anchor: anchor)
        let prepared = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"])
        let installed = try await store.activate(prepared)
        let oldBytes = try Data(contentsOf: registryFile)
        let key = RaycastStorePreferenceKey(scope: .extensionWide, name: "value")
        var accepted = RaycastStorePreferenceChanges()
        accepted.values[key] = .set(.string("synthetic ordinary value"))
        try await store.save(installationID: installed.id, generation: installed.generation, changes: accepted)

        let reopened = try RaycastStoreDiskRegistry(root: registryRoot, trust: trust, anchor: makeAnchor())
        let persisted = try await reopened.load(installationID: installed.id, generation: installed.generation)
        XCTAssertEqual(persisted.values[key], .string("synthetic ordinary value"))
        let newBytes = try Data(contentsOf: registryFile)
        XCTAssertNotEqual(oldBytes, newBytes)
        let newAnchor = try storage.read()

        var rejected = RaycastStorePreferenceChanges()
        rejected.values[key] = .set(.string("never committed"))
        storage.rejectReplacement()
        do {
            try await reopened.save(installationID: installed.id, generation: installed.generation, changes: rejected)
            XCTFail("Rejected anchor update must not commit")
        } catch { XCTAssertEqual(error as? Failure, .anchor) }
        XCTAssertEqual(try Data(contentsOf: registryFile), newBytes)
        XCTAssertEqual(try storage.read(), newAnchor)

        try oldBytes.write(to: registryFile, options: .atomic)
        do {
            _ = try await reopened.load(installationID: installed.id, generation: installed.generation)
            XCTFail("An older valid registry may not be revived")
        } catch { XCTAssertEqual(error as? Failure, .protectedStateRecovery(.interruptedWriteOrRollback)) }
        do {
            try await reopened.save(installationID: installed.id, generation: installed.generation, changes: rejected)
            XCTFail("An older valid registry may not be advanced")
        } catch { XCTAssertEqual(error as? Failure, .protectedStateRecovery(.interruptedWriteOrRollback)) }
        XCTAssertEqual(try Data(contentsOf: registryFile), oldBytes)
        XCTAssertEqual(try storage.read(), newAnchor)
    }

    func testRestartReusesUncommittedStageAndActivationPersists() async throws {
        let (root, fixtureTrust, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var trust = fixtureTrust
        let installationID = UUID()
        trust.expectedInstallationID = installationID
        let store = try RaycastStoreDiskRegistry(root: root, trust: trust)
        let pending = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"], installationID: installationID)
        let beforeActivation = try await store.installations()
        XCTAssertTrue(beforeActivation.isEmpty)

        let reopened = try RaycastStoreDiskRegistry(root: root, trust: trust)
        let persistedReceipt = try await reopened.stagedArtifact(for: trust.source)
        XCTAssertEqual(persistedReceipt?.id, installationID)
        XCTAssertEqual(persistedReceipt?.contentDigest, digest)
        let recovered = try await reopened.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"])
        XCTAssertEqual(recovered.id, pending.id)
        let installed = try await reopened.activate(recovered)
        XCTAssertTrue(installed.enabled)
        XCTAssertEqual(installed.generation, 1)

        let receipt = try await store.installations().first
        XCTAssertEqual(receipt?.id, installed.id)
        let command = try XCTUnwrap(installed.manifest.commands.first)
        let artifact = try await store.validate(installationID: installed.id, generation: 1, commandID: command.id, capabilities: ["toast"])
        XCTAssertEqual(artifact.bytes, trust.bytes)
        XCTAssertEqual(artifact.digest, digest)
        do {
            try await store.validate(installationID: installed.id, generation: 1, commandID: command.name, capabilities: [])
            XCTFail("Raw path is not a registered command identity")
        } catch { XCTAssertEqual(error as? Failure, .identity) }
        do {
            try await store.validate(installationID: installed.id, generation: 1, commandID: command.id, capabilities: ["clipboard"])
            XCTFail("A command cannot exceed the installed grant")
        } catch { XCTAssertEqual(error as? Failure, .capability) }
    }

    func testStagingRejectsUntrustedInputsAndDiscardCannotRemoveInstalledRecord() async throws {
        let (root, trust, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RaycastStoreDiskRegistry(root: root, trust: trust)
        do {
            _ = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: source(revision: String(repeating: "b", count: 40)), grantedCapabilities: ["toast"])
            XCTFail()
        } catch { XCTAssertEqual(error as? Failure, .integrity) }
        do {
            _ = try await store.prepare(bytes: Data("different".utf8), expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"])
            XCTFail()
        } catch { XCTAssertEqual(error as? Failure, .integrity) }
        do {
            _ = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: [])
            XCTFail()
        } catch { XCTAssertEqual(error as? Failure, .capability) }
        let valid = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"])
        try await store.discard(valid)
        let retry = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"])
        XCTAssertNotEqual(valid.id, retry.id)
        let spoofed = RaycastStorePreparedArtifact(id: retry.id, source: retry.source, contentDigest: String(repeating: "0", count: 64))
        do { _ = try await store.activate(spoofed); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .stale) }
        _ = try await store.activate(retry)
        do { try await store.discard(retry); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .stale) }
        let installed = try await store.installations()
        XCTAssertEqual(installed.map(\.id), [retry.id])
    }

    func testFailedRevocationRemainsDisabledAndRequiresNewGeneration() async throws {
        let (root, trust, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var failingTrust = trust
        failingTrust.revocationFails = true
        let store = try RaycastStoreDiskRegistry(root: root, trust: failingTrust)
        let staged = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"])
        let initial = try await store.activate(staged)
        do { try await store.uninstall(installationID: initial.id, expectedGeneration: initial.generation); XCTFail() }
        catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown) }

        let restored = try RaycastStoreDiskRegistry(root: root, trust: trust)
        let pending = try await restored.installations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].generation, 2)
        XCTAssertFalse(pending[0].enabled)
        do {
            try await restored.validate(installationID: initial.id, generation: 2, commandID: initial.manifest.commands[0].id, capabilities: [])
            XCTFail()
        } catch { XCTAssertEqual(error as? Failure, .inactive) }
        do { try await restored.uninstall(installationID: initial.id, expectedGeneration: 1); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .stale) }
        let enabled = try await restored.setEnabled(installationID: initial.id, expectedGeneration: 2, enabled: true)
        XCTAssertTrue(enabled.enabled)
        XCTAssertEqual(enabled.generation, 3)
        try await restored.uninstall(installationID: enabled.id, expectedGeneration: 3)
        let empty = try await store.installations()
        XCTAssertTrue(empty.isEmpty)
    }

    func testCorruptedOpaqueEnvelopeCannotBeRestored() async throws {
        let (root, trust, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RaycastStoreDiskRegistry(root: root, trust: trust)
        let staged = try await store.prepare(bytes: trust.bytes, expectedDigest: digest, source: trust.source, grantedCapabilities: ["toast"])
        _ = try await store.activate(staged)
        let stateURL = root.appendingPathComponent("registry.json")
        let clean = try Data(contentsOf: stateURL)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: clean) as? [String: Any])
        var rows = try XCTUnwrap(envelope["records"] as? [[String: Any]])
        rows[0]["grants"] = ["toast", "clipboard"]
        envelope["records"] = rows
        try JSONSerialization.data(withJSONObject: envelope).write(to: stateURL, options: .atomic)
        do { _ = try await store.installations(); XCTFail("A changed disk grant cannot expand artifact authority") }
        catch { XCTAssertEqual(error as? Failure, .capability) }
        rows[0]["grants"] = ["toast"]
        let changed = Data("changed".utf8)
        rows[0]["bytes"] = changed.base64EncodedString()
        rows[0]["digest"] = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
        envelope["records"] = rows
        try JSONSerialization.data(withJSONObject: envelope).write(to: stateURL, options: .atomic)
        do { _ = try await store.installations(); XCTFail("Checksum without trusted provenance is insufficient") }
        catch { XCTAssertEqual(error as? Failure, .integrity) }
    }

}
