import CryptoKit
import XCTest
@testable import KeylaneCore

private final class FixtureRegistryAnchor: RaycastStoreRegistryAnchor, @unchecked Sendable {
    private let lock = NSLock()
    private var digest: String?
    func verify(expectedDigest: String?) throws {
        try lock.withLock {
            guard digest == expectedDigest else { throw RaycastStoreDiskRegistry.Failure.anchor }
        }
    }
    func advance(previousDigest: String?, to nextDigest: String) throws {
        try lock.withLock {
            guard digest == previousDigest else { throw RaycastStoreDiskRegistry.Failure.anchor }
            digest = nextDigest
        }
    }
}

private struct FixtureSealTrust: RaycastStoreArtifactTrust {
    let seal: RaycastStoreArtifactSeal
    var failRevocation = false

    func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        try seal.verify(bytes: bytes, source: source, installationID: installationID)
    }
    func revoke(installationID: UUID, before generation: UInt64) async throws {
        if failRevocation { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor
private final class SyntheticSealDriver: StoreRuntimeBridge.IsolatedEngine {
    private(set) var buildCount = 0
    private(set) var runGenerations: [UInt64] = []
    func verifiedRuntimeDigest() throws -> String { String(repeating: "b", count: 64) }
    func build(projectEnvelope envelope: Data, entry: String, runtimeDigest: String) async throws -> Data {
        guard runtimeDigest == (try verifiedRuntimeDigest()), !envelope.isEmpty, entry == "src/hello.js" else {
            throw StoreRuntimeBridge.Rejection.runtimeIdentity
        }
        buildCount += 1
        return Data("self-authored inert artifact contents".utf8)
    }
    func run(artifact: Data,
                         receipt: StoreRuntimeBridge.Receipt, installation: StoreRuntimeBridge.Installation) async throws {
        guard receipt.provenance.runtimeDigest == (try verifiedRuntimeDigest()), artifact == Data("self-authored inert artifact contents".utf8),
              receipt.provenance.installation.id == installation.id else {
            throw StoreRuntimeBridge.Rejection.artifactIdentity
        }
        runGenerations.append(installation.generation)
    }
}

final class RaycastStoreArtifactSealTests: XCTestCase {
    private let digest = String(repeating: "b", count: 64)
    private let commandID = "extension:raycast:fixture/seal-fixture/hello"

    @MainActor
    private func fixture() async throws -> (RaycastStoreArtifactSeal, RaycastStoreInstallCoordinator.BuiltArtifact,
                                             RaycastStoreSource, UUID, P256.Signing.PublicKey) {
        let privateKey = P256.Signing.PrivateKey() // Disposable in-memory test only.
        let recipe = RaycastStoreArtifactSeal.Recipe(identifier: "test-only", runtimeDigest: digest, qualifiedAPIVersions: [])
        let seal = try RaycastStoreArtifactSeal(publicKey: privateKey.publicKey, recipe: recipe)
        let revision = String(repeating: "a", count: 40)
        let source = try RaycastStoreSource(slug: "seal-fixture", catalog: .init(revision: revision, slugs: ["seal-fixture"]))
        let files = [
            "package.json": Data(#"{"name":"seal-fixture","author":"fixture","title":"Seal","commands":[{"name":"hello","title":"Hello","mode":"no-view"}]}"#.utf8),
            "src/hello.js": Data("// self-authored fixture; never executed".utf8)
        ]
        let tree = files.map { path, data -> [String: Any] in
            let sha = Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
            return ["path": path, "sha": sha, "size": data.count, "mode": "100644", "type": "blob"]
        } + [["path": "src", "sha": revision, "mode": "040000", "type": "tree"]]
        let snapshot = try RaycastStoreSnapshot(source: source, treeSHA: revision,
            recursiveTreeJSON: JSONSerialization.data(withJSONObject: ["sha": revision, "truncated": false, "tree": tree]))
        let project = try RaycastStoreBuildProject(source: .init(snapshot: snapshot, files: files), supportedRuntimeAPIVersions: [], tarballs: [:])
        let id = UUID()
        let driver = SyntheticSealDriver()
        let bridge = StoreRuntimeBridge(engine: engine(driver)) { identity, operation in
            identity.id == id.uuidString && identity.generation == 0 && operation == .stagingBuild
        }
        let command = try await bridge.prepare(installation: .init(id: id.uuidString, generation: 0), entry: "src/hello.js",
            files: project.files.map { .init(path: $0.path, body: $0.body) })
        XCTAssertEqual(driver.buildCount, 1)
        let issued = try seal.issue(source: source, installationID: id, project: project, built: [command],
            capabilities: ["toast"], sign: { try privateKey.signature(for: $0) })
        return (seal, issued, source, id, privateKey.publicKey)
    }

    @MainActor
    private func engine(_ driver: SyntheticSealDriver) -> any StoreRuntimeBridge.IsolatedEngine { driver }

    @MainActor
    func testDurableEnvelopeRecoversUnderSamePublicKeyButRejectsDifferentKeyRecipeOrIdentity() async throws {
        let (seal, issued, source, id, key) = try await fixture()
        let trusted = try seal.verify(bytes: issued.bytes, source: source, installationID: id)
        XCTAssertEqual(trusted.manifest.commands.first?.id, commandID)
        XCTAssertEqual(trusted.requiredCapabilities, ["toast"])
        XCTAssertThrowsError(try seal.verify(bytes: issued.bytes, source: source, installationID: UUID())) {
            XCTAssertEqual($0 as? RaycastStoreArtifactSeal.Failure, .identity)
        }
        let shadowKey = P256.Signing.PrivateKey()
        let changedKey = try RaycastStoreArtifactSeal(publicKey: shadowKey.publicKey,
            recipe: .init(identifier: "test-only", runtimeDigest: digest, qualifiedAPIVersions: []))
        XCTAssertThrowsError(try changedKey.verify(bytes: issued.bytes, source: source, installationID: id)) {
            XCTAssertEqual($0 as? RaycastStoreArtifactSeal.Failure, .untrusted)
        }
        let changedRuntime = try RaycastStoreArtifactSeal(publicKey: key,
            recipe: .init(identifier: "test-only", runtimeDigest: String(repeating: "c", count: 64), qualifiedAPIVersions: []))
        XCTAssertThrowsError(try changedRuntime.verify(bytes: issued.bytes, source: source, installationID: id)) {
            XCTAssertEqual($0 as? RaycastStoreArtifactSeal.Failure, .recipe)
        }
        var modified = try XCTUnwrap(JSONSerialization.jsonObject(with: issued.bytes) as? [String: Any])
        let oldPayload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(modified["payload"] as? String)))
        modified["payload"] = (oldPayload + Data([0x20])).base64EncodedString()
        let forged = try JSONSerialization.data(withJSONObject: modified)
        XCTAssertThrowsError(try seal.verify(bytes: forged, source: source, installationID: id)) {
            XCTAssertEqual($0 as? RaycastStoreArtifactSeal.Failure, .untrusted)
        }
    }

    @MainActor
    func testReopenedRegistryRejectsRollbackAfterFailedRevocation() async throws {
        let (seal, issued, source, id, key) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let anchor = FixtureRegistryAnchor()
        let first = try RaycastStoreDiskRegistry(root: root, trust: FixtureSealTrust(seal: seal, failRevocation: true), anchor: anchor)
        let staged = try await first.prepare(bytes: issued.bytes, expectedDigest: issued.digest, source: source,
                                             grantedCapabilities: issued.capabilities, installationID: id)
        let active = try await first.activate(staged)
        let path = root.appendingPathComponent("registry.json")
        let oldActiveState = try Data(contentsOf: path)
        let current = try RaycastStoreArtifactSeal(publicKey: key,
            recipe: .init(identifier: "test-only", runtimeDigest: digest, qualifiedAPIVersions: []))
        let reopened = try RaycastStoreDiskRegistry(root: root, trust: FixtureSealTrust(seal: current), anchor: anchor)
        let restored = try await reopened.installations()
        XCTAssertEqual(restored.first?.id, id)
        let artifact = try await reopened.validate(installationID: id, generation: 1, commandID: commandID, capabilities: ["toast"])
        let command = try current.open(artifact, installation: active, commandID: commandID)
        XCTAssertEqual(command.receipt.provenance.installation.id, id.uuidString)
        XCTAssertEqual(command.receipt.provenance.installation.generation, 0)
        let runDriver = SyntheticSealDriver()
        let bridge = StoreRuntimeBridge(engine: engine(runDriver)) { installation, operation in
            guard operation == .enabledRun, installation.id == id.uuidString else { return false }
            return (try? await reopened.validate(installationID: id, generation: installation.generation,
                                                 commandID: self.commandID, capabilities: ["toast"])) != nil
        }
        let enabled = StoreRuntimeBridge.Installation(id: id.uuidString, generation: 1)
        try await bridge.run(artifact: command.bytes, expectedReceipt: command.receipt, installation: enabled)
        XCTAssertEqual(runDriver.runGenerations, [1])
        do { try await first.uninstall(installationID: id, expectedGeneration: 1); XCTFail() }
        catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown) }
        let quarantined = try await reopened.installations()
        XCTAssertEqual(quarantined.first?.enabled, false)
        XCTAssertEqual(quarantined.first?.generation, 2)
        do { try await bridge.run(artifact: command.bytes, expectedReceipt: command.receipt, installation: enabled); XCTFail() }
        catch { XCTAssertEqual(error as? StoreRuntimeBridge.Rejection, .staleInstallation) }
        XCTAssertEqual(runDriver.runGenerations, [1])
        do { _ = try await reopened.validate(installationID: id, generation: 2, commandID: commandID, capabilities: []); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .inactive) }

        try oldActiveState.write(to: path, options: .atomic)
        do { _ = try await reopened.installations(); XCTFail("Old valid signature must not revive this version of the registry") }
        catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .anchor) }
        try FileManager.default.removeItem(at: path)
        do { _ = try await reopened.installations(); XCTFail("Deletion must not reset established authority") }
        catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .anchor) }
    }
}
