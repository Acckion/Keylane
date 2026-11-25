import CryptoKit
import XCTest
@testable import KeylaneCore

final class ProtectedReceiptFixtureStore: RaycastStoreProtectedReceiptStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var rejectNext = false

    func rejectReplacement() { lock.withLock { rejectNext = true } }
    func read() throws -> Data? { lock.withLock { value } }
    func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool {
        lock.withLock {
            if rejectNext { rejectNext = false; return false }
            guard value == expected else { return false }
            value = replacement
            return true
        }
    }
}

private struct RecoveryOnlyStoreService: RaycastStoreInstallationService {
    enum Unexpected: Error { case called }
    func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        throw Unexpected.called
    }
    func revoke(installationID: UUID, before generation: UInt64) async throws { throw Unexpected.called }
    func qualifiedAPIVersions() async throws -> Set<String> { throw Unexpected.called }
    func build(project: RaycastStoreBuildProject, source: RaycastStoreSource, installationID: UUID) async throws
        -> RaycastStoreInstallCoordinator.BuiltArtifact { throw Unexpected.called }
    func readiness(_ context: RaycastStoreInstallCoordinator.RunContext) async throws
        -> RaycastStoreLaunchReadiness { throw Unexpected.called }
    func runCurrent(_ context: RaycastStoreInstallCoordinator.RunContext) async throws { throw Unexpected.called }
}

final class RaycastStoreProtectedReceiptStateTests: XCTestCase {
    private let first = String(repeating: "a", count: 64)
    private let second = String(repeating: "b", count: 64)
    private let other = String(repeating: "c", count: 64)

    private func scheme(_ id: String = "signed-recipe", versions: Set<String> = ["1.0.0"]) -> RaycastStoreArtifactSeal.Recipe {
        .init(identifier: id, runtimeDigest: String(repeating: "0", count: 64), qualifiedAPIVersions: versions)
    }

    func testProtectedStorageNeedsExplicitSetupAndWillNotAdoptAnExistingFile() throws {
        let storage = ProtectedReceiptFixtureStore()
        let scoped = try RaycastStoreProtectedReceiptState(storage: storage, registryID: UUID(),
            publicKey: P256.Signing.PrivateKey().publicKey, recipe: scheme())
        XCTAssertEqual(scoped.recoveryStatus(observedRegistryDigest: nil), .setupRequired)
        XCTAssertEqual(scoped.recoveryStatus(observedRegistryDigest: first), .protectedStateMissing)
        XCTAssertThrowsError(try scoped.initializeNewRegistry(observedRegistryDigest: first))
        XCTAssertNil(try storage.read())
        try scoped.initializeNewRegistry(observedRegistryDigest: nil)
        try scoped.verify(expectedDigest: nil)
        XCTAssertThrowsError(try scoped.initializeNewRegistry(observedRegistryDigest: nil))
    }

    func testRestartRejectsOldHeadAndNeverClassifiesArbitraryFileAsReady() throws {
        let storage = ProtectedReceiptFixtureStore(), id = UUID(), key = P256.Signing.PrivateKey().publicKey
        let current = try RaycastStoreProtectedReceiptState(storage: storage, registryID: id, publicKey: key, recipe: scheme())
        try current.initializeNewRegistry(observedRegistryDigest: nil)
        try current.advance(previousDigest: nil, to: first)
        try current.advance(previousDigest: first, to: second)
        let restarted = try RaycastStoreProtectedReceiptState(storage: storage, registryID: id, publicKey: key, recipe: scheme())
        try restarted.verify(expectedDigest: second)
        XCTAssertEqual(restarted.recoveryStatus(observedRegistryDigest: first), .interruptedWriteOrRollback)
        XCTAssertEqual(restarted.recoveryStatus(observedRegistryDigest: other), .registryMismatch)
        XCTAssertThrowsError(try restarted.verify(expectedDigest: first))
        XCTAssertThrowsError(try restarted.advance(previousDigest: first, to: other))
        try restarted.verify(expectedDigest: second)
    }

    func testSignerRecipeOrScopeChangesRequireMigrationAndDoNotWrite() throws {
        let storage = ProtectedReceiptFixtureStore(), id = UUID(), key = P256.Signing.PrivateKey().publicKey
        let initial = try RaycastStoreProtectedReceiptState(storage: storage, registryID: id, publicKey: key, recipe: scheme())
        try initial.initializeNewRegistry(observedRegistryDigest: nil)
        try initial.advance(previousDigest: nil, to: first)
        let original = try storage.read()
        let variants = [
            try RaycastStoreProtectedReceiptState(storage: storage, registryID: UUID(), publicKey: key, recipe: scheme()),
            try RaycastStoreProtectedReceiptState(storage: storage, registryID: id, publicKey: P256.Signing.PrivateKey().publicKey, recipe: scheme()),
            try RaycastStoreProtectedReceiptState(storage: storage, registryID: id, publicKey: key, recipe: scheme("another-recipe")),
            try RaycastStoreProtectedReceiptState(storage: storage, registryID: id, publicKey: key, recipe: scheme(versions: ["2.0.0"]))
        ]
        for changed in variants {
            XCTAssertEqual(changed.recoveryStatus(observedRegistryDigest: first), .migrationRequired)
            XCTAssertThrowsError(try changed.advance(previousDigest: first, to: second))
            XCTAssertEqual(try storage.read(), original)
        }
    }

    func testInstallerPreservesProtectedRecoveryWithoutAdoptingOrResettingDiskState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("registry.json")
        let storage = ProtectedReceiptFixtureStore(), id = UUID(), key = P256.Signing.PrivateKey().publicKey
        func state(_ recipe: RaycastStoreArtifactSeal.Recipe) throws -> RaycastStoreProtectedReceiptState {
            try .init(storage: storage, registryID: id, publicKey: key, recipe: recipe)
        }
        func installer(_ anchor: RaycastStoreProtectedReceiptState) throws -> RaycastStoreInstaller {
            .init(backend: try RaycastStoreInstallCoordinator(root: root, service: RecoveryOnlyStoreService(), anchor: anchor))
        }
        func expect(_ reason: RaycastStoreProtectedReceiptState.Recovery,
                    from installer: RaycastStoreInstaller) async {
            do {
                _ = try await installer.refreshInstalled()
                XCTFail("expected protected-state review instead of admitting inventory")
            } catch {
                XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .protectedStateRecovery(reason))
            }
        }
        let anchor = try state(scheme())
        let initial = try installer(anchor)
        await expect(.setupRequired, from: initial)
        XCTAssertNil(try storage.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))

        let disk = Data(#"{"version":1,"records":[]}"#.utf8)
        try disk.write(to: path)
        await expect(.protectedStateMissing, from: initial)
        XCTAssertNil(try storage.read())
        XCTAssertEqual(try Data(contentsOf: path), disk)

        // Only the test initializes a new scope after removing the synthetic file.
        try FileManager.default.removeItem(at: path)
        try anchor.initializeNewRegistry(observedRegistryDigest: nil)
        let diskDigest = SHA256.hash(data: disk).map { String(format: "%02x", $0) }.joined()
        try anchor.advance(previousDigest: nil, to: diskDigest)
        try disk.write(to: path)
        let restarted = try installer(state(scheme()))
        let restored = try await restarted.refreshInstalled()
        XCTAssertTrue(restored.isEmpty)

        await expect(.migrationRequired, from: try installer(state(scheme("other-recipe"))))
        try anchor.advance(previousDigest: diskDigest, to: second)
        let authority = try storage.read()
        await expect(.interruptedWriteOrRollback, from: try installer(state(scheme())))
        XCTAssertEqual(try storage.read(), authority)
        XCTAssertEqual(try Data(contentsOf: path), disk)
    }

    func testConflictingOrUnreadableProtectedWritesFailClosed() throws {
        let storage = ProtectedReceiptFixtureStore()
        let current = try RaycastStoreProtectedReceiptState(storage: storage, registryID: UUID(),
            publicKey: P256.Signing.PrivateKey().publicKey, recipe: scheme())
        try current.initializeNewRegistry(observedRegistryDigest: nil)
        try current.advance(previousDigest: nil, to: first)
        storage.rejectReplacement()
        XCTAssertThrowsError(try current.advance(previousDigest: first, to: second)) {
            XCTAssertEqual($0 as? RaycastStoreProtectedReceiptState.Failure, .conflict)
        }
        try current.verify(expectedDigest: first)
        XCTAssertTrue(try storage.compareAndSwap(expected: storage.read(), replacement: Data([0xff])))
        XCTAssertEqual(current.recoveryStatus(observedRegistryDigest: first), .unreadable)
        XCTAssertThrowsError(try current.verify(expectedDigest: first))
    }
}
