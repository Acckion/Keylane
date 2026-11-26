import XCTest
@testable import KeylaneCore

private actor StoreFixtureBackend: RaycastStoreBackend {
    enum Behavior { case normal, failPrepare, indeterminatePrepare, invalidArtifact, failAfterCommit, cancelPrepare, suspendPrepare }
    let behavior: Behavior
    let manifest: RaycastExtensionManifest
    var receipt: RaycastStoreInstallation?
    var installs = 0
    var prepares = 0
    var launches = 0
    var inventoryFails = false
    var readiness: RaycastStoreLaunchReadiness = .ready
    func failInventory() { inventoryFails = true }
    func requirePreferences() { readiness = .preferencesRequired }
    func launchReadiness(installationID: UUID, commandID: String) async throws -> RaycastStoreLaunchReadiness { readiness }
    func installations() async throws -> [RaycastStoreInstallation] {
        if inventoryFails { throw CocoaError(.fileReadUnknown) }
        return receipt.map { [$0] } ?? []
    }
    var preparationGate: CheckedContinuation<Void, Never>?
    var preparingObserver: CheckedContinuation<Void, Never>?
    func awaitPreparing() async {
        if preparationGate != nil { return }
        await withCheckedContinuation { preparingObserver = $0 }
    }
    func releasePreparation() { preparationGate?.resume(); preparationGate = nil }
    init(behavior: Behavior, manifest: RaycastExtensionManifest) { self.behavior = behavior; self.manifest = manifest }
    func prepare(_ source: RaycastStoreSource) async throws -> RaycastStorePreparedArtifact {
        prepares += 1
        if behavior == .indeterminatePrepare {
            throw RaycastStoreDiskRegistry.Failure.protectedStateRecovery(.protectedWriteIndeterminate)
        }
        if behavior == .suspendPrepare {
            await withCheckedContinuation { continuation in
                preparationGate = continuation
                preparingObserver?.resume(); preparingObserver = nil
            }
        }
        if behavior == .failPrepare { throw CocoaError(.fileReadCorruptFile) }
        if behavior == .cancelPrepare { throw CancellationError() }
        return .init(id: UUID(), source: source, contentDigest: behavior == .invalidArtifact ? "bad" : String(repeating: "a", count: 64))
    }
    func install(_ artifact: RaycastStorePreparedArtifact) async throws -> RaycastStoreInstallation {
        installs += 1
        let result = RaycastStoreInstallation(id: UUID(), source: artifact.source, generation: 1, manifest: manifest, enabled: true)
        receipt = result
        if behavior == .failAfterCommit { throw CocoaError(.fileWriteUnknown) }
        return result
    }
    func launch(installationID: UUID, commandID: String) async throws { launches += 1 }
    func setEnabled(installationID: UUID, enabled: Bool) async throws -> RaycastStoreInstallation {
        let old = receipt!
        let next = RaycastStoreInstallation(id: old.id, source: old.source, generation: old.generation + 1, manifest: old.manifest, enabled: enabled)
        receipt = next
        return next
    }
    func installation(for slug: String) async throws -> RaycastStoreInstallation? { receipt }
    func uninstall(installationID: UUID) async throws { receipt = nil }
}

final class RaycastStoreInstallerTests: XCTestCase {
    private func source() throws -> RaycastStoreSource {
        try .init(slug: "any-official-extension", catalog: .init(revision: String(repeating: "a", count: 40), slugs: ["any-official-extension"]))
    }
    private func backend(_ behavior: StoreFixtureBackend.Behavior = .normal) throws -> StoreFixtureBackend {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data(#"{"name":"fixture","author":"tests","title":"Fixture","commands":[{"name":"hello","title":"Hello","mode":"no-view"}]}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        // Metadata parsing only: this file is never run.
        try Data("throw new Error('must never run')".utf8).write(to: root.appendingPathComponent("src/hello.js"))
        return try .init(behavior: behavior, manifest: RaycastExtensionManifest.read(directory: root))
    }

    func testInstallEnableLaunchAndUninstallUseConfirmedReceipts() async throws {
        let backend = try backend(), installer = RaycastStoreInstaller(backend: backend)
        let source = try source()
        let receipt = try await installer.prepareAndInstall(source)
        _ = try await installer.prepareAndInstall(source)
        let restarted = RaycastStoreInstaller(backend: backend)
        let recovered = try await restarted.prepareAndInstall(source)
        XCTAssertEqual(recovered.id, receipt.id)
        let installs = await backend.installs
        XCTAssertEqual(installs, 1)
        try await installer.launch(slug: source.slug, commandID: receipt.manifest.commands[0].id)
        try await installer.setEnabled(slug: source.slug, enabled: false)
        do { try await installer.launch(slug: source.slug, commandID: receipt.manifest.commands[0].id); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .notInstalled) }
        try await installer.setEnabled(slug: source.slug, enabled: true)
        try await installer.launch(slug: source.slug, commandID: receipt.manifest.commands[0].id)
        let launches = await backend.launches
        XCTAssertEqual(launches, 2)
        try await installer.uninstall(slug: source.slug)
        guard case .idle = await installer.state(for: source.slug) else { return XCTFail() }
    }

    func testInventoryRestoresAfterRestartAndFailurePreservesVisibleRecords() async throws {
        let backend = try backend(), first = RaycastStoreInstaller(backend: backend)
        let receipt = try await first.prepareAndInstall(source())
        let restarted = RaycastStoreInstaller(backend: backend)
        let restored = try await restarted.refreshInstalled()
        XCTAssertEqual(restored.map(\.id), [receipt.id])
        await backend.failInventory()
        do { _ = try await restarted.refreshInstalled(); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .reconciliationFailed) }
        let retained = await restarted.installedList()
        XCTAssertEqual(retained.map(\.id), [receipt.id])
    }

    func testRequiredPreferencesBlockActualDispatch() async throws {
        let backend = try backend(), installer = RaycastStoreInstaller(backend: backend)
        let receipt = try await installer.prepareAndInstall(source())
        await backend.requirePreferences()
        do { try await installer.launch(slug: receipt.source.slug, commandID: receipt.manifest.commands[0].id); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .preferencesRequired) }
        let count = await backend.launches
        XCTAssertEqual(count, 0)
    }

    func testCachedReceiptDoesNotHideExternalRemoval() async throws {
        let backend = try backend(), installer = RaycastStoreInstaller(backend: backend)
        let source = try source()
        let original = try await installer.prepareAndInstall(source)
        try await backend.uninstall(installationID: original.id)
        let replacement = try await installer.prepareAndInstall(source)
        XCTAssertNotEqual(replacement.id, original.id)
        let count = await backend.installs
        XCTAssertEqual(count, 2)
    }

    func testConcurrentInstallForSameExtensionCannotCommitTwice() async throws {
        let backend = try backend(.suspendPrepare), installer = RaycastStoreInstaller(backend: backend)
        let source = try source()
        let first = Task { try await installer.prepareAndInstall(source) }
        await backend.awaitPreparing()
        do { _ = try await installer.prepareAndInstall(source); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .busy) }
        await backend.releasePreparation()
        _ = try await first.value
        let count = await backend.installs
        XCTAssertEqual(count, 1)
    }

    func testIndeterminatePreparationRequiresReconciliationBeforeRetry() async throws {
        let backend = try backend(.indeterminatePrepare)
        let installer = RaycastStoreInstaller(backend: backend)
        let source = try source()
        for expected in [RaycastStoreInstaller.Failure.operationOutcomeUnknown, .installationOutcomeUnknown] {
            do {
                _ = try await installer.prepareAndInstall(source)
                XCTFail("an indeterminate write must not proceed to installation")
            } catch {
                XCTAssertEqual(error as? RaycastStoreInstaller.Failure, expected)
            }
        }
        let prepares = await backend.prepares
        let installs = await backend.installs
        XCTAssertEqual(prepares, 1)
        XCTAssertEqual(installs, 0)
    }

    func testPreparationFailureNeverInstalls() async throws {
        let backend = try backend(.failPrepare), installer = RaycastStoreInstaller(backend: backend)
        do { _ = try await installer.prepareAndInstall(source()); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .preparationFailed) }
        let installs = await backend.installs
        XCTAssertEqual(installs, 0)
    }

    func testInvalidArtifactNeverInstalls() async throws {
        let backend = try backend(.invalidArtifact), installer = RaycastStoreInstaller(backend: backend)
        do { _ = try await installer.prepareAndInstall(source()); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .invalidArtifact) }
        let installs = await backend.installs
        XCTAssertEqual(installs, 0)
    }

    func testAmbiguousInstallRequiresReconciliationAndDoesNotRetryCommit() async throws {
        let backend = try backend(.failAfterCommit), installer = RaycastStoreInstaller(backend: backend)
        let source = try source()
        for _ in 0..<2 {
            do { _ = try await installer.prepareAndInstall(source); XCTFail() }
            catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .installationOutcomeUnknown) }
        }
        let installs = await backend.installs
        XCTAssertEqual(installs, 1)
        try await installer.reconcile(slug: source.slug)
        guard case .installed = await installer.state(for: source.slug) else { return XCTFail() }
        _ = try await installer.prepareAndInstall(source)
        let finalCount = await backend.installs
        XCTAssertEqual(finalCount, 1)
    }

    func testCancelledPreparationNeverInstalls() async throws {
        let backend = try backend(.cancelPrepare), installer = RaycastStoreInstaller(backend: backend)
        do { _ = try await installer.prepareAndInstall(source()); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .cancelled) }
        let installs = await backend.installs
        XCTAssertEqual(installs, 0)
    }

    func testMissingProductionBackendIsNotASuccess() async throws {
        let installer = RaycastStoreInstaller()
        do { _ = try await installer.prepareAndInstall(source()); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .unavailable) }
    }
}
