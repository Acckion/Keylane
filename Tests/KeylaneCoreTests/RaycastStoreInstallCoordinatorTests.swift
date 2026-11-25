import CryptoKit
import XCTest
@testable import KeylaneCore

private actor CoordinatorFixtureService: RaycastStoreInstallationService {
    private nonisolated let manifest: RaycastExtensionManifest
    private var minimumGeneration: [UUID: UInt64] = [:]
    private var availablePreferences = false
    private var dispatched: [UInt64] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var admissionObserver: CheckedContinuation<Void, Never>?
    private var suspendAdmission = false
    private var suspendBuild = false
    private var rejectNextBuild = false
    private var buildGate: CheckedContinuation<Void, Never>?
    private var buildObserver: CheckedContinuation<Void, Never>?
    private(set) var builds = 0

    init(manifest: RaycastExtensionManifest) { self.manifest = manifest }

    nonisolated private func fixtureBytes(source: RaycastStoreSource, installationID: UUID) -> Data {
        Data(("self-authored fixture only:" + source.slug + ":" + source.revision + ":" + installationID.uuidString).utf8)
    }

    nonisolated func verify(bytes: Data, source: RaycastStoreSource,
                            installationID: UUID) throws -> RaycastStoreTrustedDescription {
        guard bytes == fixtureBytes(source: source, installationID: installationID) else {
            throw RaycastStoreDiskRegistry.Failure.integrity
        }
        return .init(extensionID: source.slug, manifest: manifest, requiredCapabilities: ["toast"])
    }

    func qualifiedAPIVersions() async throws -> Set<String> { [] }

    func build(project: RaycastStoreBuildProject, source: RaycastStoreSource,
               installationID: UUID) async throws -> RaycastStoreInstallCoordinator.BuiltArtifact {
        builds += 1
        if suspendBuild {
            suspendBuild = false
            await withCheckedContinuation {
                buildGate = $0; buildObserver?.resume(); buildObserver = nil
            }
        }
        if rejectNextBuild { rejectNextBuild = false; throw RaycastStoreInstaller.Failure.preparationFailed }
        guard project.files.contains(where: { $0.path == "src/hello.js" }) else {
            throw RaycastStoreInstaller.Failure.invalidArtifact
        }
        let bytes = fixtureBytes(source: source, installationID: installationID)
        return .init(bytes: bytes, digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), capabilities: ["toast"])
    }

    func delayBuild() { suspendBuild = true }
    func rejectBuild() { rejectNextBuild = true }
    func allowBuild() { buildGate?.resume(); buildGate = nil }
    func awaitBuild() async {
        if buildGate != nil { return }
        await withCheckedContinuation { buildObserver = $0 }
    }

    func configure() { availablePreferences = true }
    func delayAdmission() { suspendAdmission = true }
    func allowAdmission() { gate?.resume(); gate = nil }
    func awaitAdmission() async {
        if gate != nil { return }
        await withCheckedContinuation { admissionObserver = $0 }
    }
    func runGenerations() -> [UInt64] { dispatched }

    func readiness(_ context: RaycastStoreInstallCoordinator.RunContext) async throws -> RaycastStoreLaunchReadiness {
        guard context.installation.generation >= minimumGeneration[context.installation.id, default: 1] else { return .runtimeUnavailable }
        return availablePreferences ? .ready : .preferencesRequired
    }

    func runCurrent(_ context: RaycastStoreInstallCoordinator.RunContext) async throws {
        if suspendAdmission {
            suspendAdmission = false
            await withCheckedContinuation {
                gate = $0; admissionObserver?.resume(); admissionObserver = nil
            }
        }
        // No suspension between checking live generation/preferences and
        // registering this synthetic broker dispatch.
        guard context.installation.generation >= minimumGeneration[context.installation.id, default: 1] else {
            throw RaycastStoreDiskRegistry.Failure.stale
        }
        guard availablePreferences else { throw RaycastStoreInstaller.Failure.preferencesRequired }
        dispatched.append(context.installation.generation)
    }

    func revoke(installationID: UUID, before generation: UInt64) async throws {
        minimumGeneration[installationID] = max(generation, minimumGeneration[installationID, default: 1])
    }
}

final class RaycastStoreInstallCoordinatorTests: XCTestCase {
    private func fixture(revision: String = String(repeating: "a", count: 40)) throws -> (URL, RaycastStoreSource, RaycastStoreBuildProject, CoordinatorFixtureService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let manifestRoot = root.appendingPathComponent("manifest")
            try FileManager.default.createDirectory(at: manifestRoot.appendingPathComponent("src"), withIntermediateDirectories: true)
            let files = [
                "package.json": Data(#"{"name":"fixture","author":"tests","title":"Fixture","commands":[{"name":"hello","title":"Hello","mode":"no-view"}]}"#.utf8),
                "src/hello.js": Data("// self-authored bytes; not run by these tests".utf8)
            ]
            for (path, content) in files { try content.write(to: manifestRoot.appendingPathComponent(path)) }
            let source = try RaycastStoreSource(slug: "fixture", catalog: .init(revision: revision, slugs: ["fixture"]))
            let tree = files.map { path, bytes -> [String: Any] in
                let hash = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes).map { String(format: "%02x", $0) }.joined()
                return ["path": path, "size": bytes.count, "mode": "100644", "type": "blob", "sha": hash]
            } + [["path": "src", "mode": "040000", "type": "tree", "sha": revision]]
            let snapshot = try RaycastStoreSnapshot(source: source, treeSHA: revision,
                recursiveTreeJSON: JSONSerialization.data(withJSONObject: ["sha": revision, "truncated": false, "tree": tree]))
            let package = try RaycastStoreSourcePackage(snapshot: snapshot, files: files)
            let project = try RaycastStoreBuildProject(source: package, supportedRuntimeAPIVersions: [], tarballs: [:])
            return (root, source, project, .init(manifest: try RaycastExtensionManifest.read(directory: manifestRoot)))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func assertSameArtifact(_ lhs: RaycastStorePreparedArtifact, _ rhs: RaycastStorePreparedArtifact,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.id, rhs.id, file: file, line: line)
        XCTAssertEqual(lhs.source, rhs.source, file: file, line: line)
        XCTAssertEqual(lhs.contentDigest, rhs.contentDigest, file: file, line: line)
    }

    func testObsoleteUpdateCandidateIsAtomicallyReplacedAndExactRevisionRecovered() async throws {
        let (root, a, projectA, service) = try fixture()
        let (rootB, b, projectB, _) = try fixture(revision: String(repeating: "b", count: 40))
        let (rootC, c, projectC, _) = try fixture(revision: String(repeating: "c", count: 40))
        defer { for url in [root, rootB, rootC] { try? FileManager.default.removeItem(at: url) } }
        let storage = root.appendingPathComponent("registry")
        let backend = try RaycastStoreInstallCoordinator(root: storage, service: service) { source, _ in
            source == a ? projectA : source == b ? projectB : projectC
        }
        let installed = try await backend.install(backend.prepare(a))
        let obsolete = try await backend.prepareUpdate(b, replacing: installed)
        let beforeRecovery = await service.builds
        let restarted = try RaycastStoreInstallCoordinator(root: storage, service: service) { source, _ in
            guard source == c else { throw RaycastStoreInstaller.Failure.preparationFailed }
            return projectC
        }
        let recovered = try await restarted.prepareUpdate(b, replacing: installed)
        assertSameArtifact(recovered, obsolete)
        let afterRecovery = await service.builds
        XCTAssertEqual(beforeRecovery, afterRecovery, "Same revision recovers without acquiring or rebuilding")
        let latest = try await restarted.prepareUpdate(c, replacing: installed)
        let stillInstalled = try await restarted.installation(for: a.slug)
        XCTAssertEqual(stillInstalled?.source, a)
        XCTAssertEqual(stillInstalled?.generation, installed.generation)
        do { _ = try await backend.install(obsolete); XCTFail("Superseded candidate must not activate") }
        catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .stale) }
        let active = try await restarted.install(latest)
        XCTAssertEqual(active.id, installed.id); XCTAssertEqual(active.source, c)
        XCTAssertEqual(active.generation, installed.generation + 1)
    }

    func testFailedAndCancelledNewUpdatePreserveInstalledAndOldCandidate() async throws {
        let (root, a, projectA, service) = try fixture()
        let (rootB, b, projectB, _) = try fixture(revision: String(repeating: "b", count: 40))
        let (rootC, c, projectC, _) = try fixture(revision: String(repeating: "c", count: 40))
        defer { for url in [root, rootB, rootC] { try? FileManager.default.removeItem(at: url) } }
        let backend = try RaycastStoreInstallCoordinator(root: root.appendingPathComponent("registry"), service: service) { source, _ in
            source == a ? projectA : source == b ? projectB : projectC
        }
        let installed = try await backend.install(backend.prepare(a))
        let obsolete = try await backend.prepareUpdate(b, replacing: installed)
        await service.rejectBuild()
        do { _ = try await backend.prepareUpdate(c, replacing: installed); XCTFail("Synthetic build must fail") }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .preparationFailed) }
        let afterFailure = try await backend.prepareUpdate(b, replacing: installed)
        assertSameArtifact(afterFailure, obsolete)
        await service.delayBuild()
        let work = Task { try await backend.prepareUpdate(c, replacing: installed) }
        await service.awaitBuild(); work.cancel(); await service.allowBuild()
        do { _ = try await work.value; XCTFail("Cancelled build must not replace candidate") } catch is CancellationError { }
        let afterCancel = try await backend.prepareUpdate(b, replacing: installed)
        assertSameArtifact(afterCancel, obsolete)
        let unchanged = try await backend.installation(for: a.slug)
        XCTAssertEqual(unchanged?.source, installed.source); XCTAssertEqual(unchanged?.generation, installed.generation)
        let active = try await backend.install(obsolete)
        XCTAssertEqual(active.source, b)
    }

    func testCompetingCandidateChangeRejectsBuildForBothObservedPresenceAndAbsence() async throws {
        for hasCandidate in [false, true] {
            let (root, a, projectA, service) = try fixture()
            let (rootB, b, projectB, _) = try fixture(revision: String(repeating: "b", count: 40))
            let (rootC, c, projectC, _) = try fixture(revision: String(repeating: "c", count: 40))
            let (rootD, d, projectD, _) = try fixture(revision: String(repeating: "d", count: 40))
            defer { for url in [root, rootB, rootC, rootD] { try? FileManager.default.removeItem(at: url) } }
            let storage = root.appendingPathComponent("registry")
            let acquire: @Sendable (RaycastStoreSource, Set<String>) async throws -> RaycastStoreBuildProject = { source, _ in
                source == a ? projectA : source == b ? projectB : source == c ? projectC : projectD
            }
            let first = try RaycastStoreInstallCoordinator(root: storage, service: service, acquireProject: acquire)
            let second = try RaycastStoreInstallCoordinator(root: storage, service: service, acquireProject: acquire)
            let installed = try await first.install(first.prepare(a))
            if hasCandidate { _ = try await first.prepareUpdate(b, replacing: installed) }
            await service.delayBuild()
            let work = Task { try await first.prepareUpdate(c, replacing: installed) }
            await service.awaitBuild()
            let winner = try await second.prepareUpdate(d, replacing: installed)
            await service.allowBuild()
            do { _ = try await work.value; XCTFail("Changed candidate must reject stale commit") }
            catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .stale) }
            let recovered = try await first.prepareUpdate(d, replacing: installed)
            assertSameArtifact(recovered, winner)
            let unchanged = try await first.installation(for: a.slug)
            XCTAssertEqual(unchanged?.source, a); XCTAssertEqual(unchanged?.generation, installed.generation)
            let active = try await first.install(winner)
            XCTAssertEqual(active.source, d)
        }
    }

    func testConcurrentActivationOrDisableRejectsUpdateAgainstConfirmedBase() async throws {
        for activate in [false, true] {
            let (root, a, projectA, service) = try fixture()
            let (rootB, b, projectB, _) = try fixture(revision: String(repeating: "b", count: 40))
            let (rootC, c, projectC, _) = try fixture(revision: String(repeating: "c", count: 40))
            defer { for url in [root, rootB, rootC] { try? FileManager.default.removeItem(at: url) } }
            let storage = root.appendingPathComponent("registry")
            let acquire: @Sendable (RaycastStoreSource, Set<String>) async throws -> RaycastStoreBuildProject = { source, _ in
                source == a ? projectA : source == b ? projectB : projectC
            }
            let first = try RaycastStoreInstallCoordinator(root: storage, service: service, acquireProject: acquire)
            let second = try RaycastStoreInstallCoordinator(root: storage, service: service, acquireProject: acquire)
            let installed = try await first.install(first.prepare(a))
            let obsolete = try await first.prepareUpdate(b, replacing: installed)
            let registry = try RaycastStoreDiskRegistry(root: storage, trust: service)
            let observed = try await registry.updateCandidate(replacing: installed)
            await service.delayBuild()
            let work = Task { try await first.prepareUpdate(c, replacing: installed) }
            await service.awaitBuild()
            let winner: RaycastStoreInstallation
            if activate { winner = try await second.install(obsolete) }
            else { winner = try await second.setEnabled(installationID: installed.id, enabled: false) }
            await service.allowBuild()
            do { _ = try await work.value; XCTFail("Changed installed generation must reject stale build") }
            catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .stale) }
            // Exercise the registry's atomic boundary directly, beyond the coordinator's earlier inventory check.
            let built = try await service.build(project: projectC, source: c, installationID: installed.id)
            do {
                _ = try await registry.replaceUpdateCandidate(observed, replacing: installed, bytes: built.bytes,
                    expectedDigest: built.digest, source: c, grantedCapabilities: built.capabilities)
                XCTFail("Registry accepted stale confirmed base")
            } catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .stale) }
            let current = try await first.installation(for: a.slug)
            XCTAssertEqual(current?.generation, winner.generation); XCTAssertEqual(current?.source, winner.source)
            XCTAssertEqual(current?.enabled, winner.enabled)
        }
    }

    func testCoordinatorRestoresAndManagesFixtureWithoutTreatingReadinessAsAuthority() async throws {
        let (root, source, project, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("registry")
        let backend = try RaycastStoreInstallCoordinator(root: storage, service: service) { _, _ in project }
        let staged = try await backend.prepare(source)
        let restarted = try RaycastStoreInstallCoordinator(root: storage, service: service) { _, _ in
            throw RaycastStoreInstaller.Failure.preparationFailed
        }
        let recovered = try await restarted.prepare(source)
        XCTAssertEqual(staged.id, recovered.id)
        let installer = RaycastStoreInstaller(backend: restarted)
        let record = try await installer.prepareAndInstall(source)
        let command = try XCTUnwrap(record.manifest.commands.first).id
        let initialReadiness = try await installer.launchReadiness(slug: source.slug, commandID: command)
        XCTAssertEqual(initialReadiness, .preferencesRequired)
        do { try await backend.launch(installationID: record.id, commandID: command); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .preferencesRequired) }

        await service.configure()
        try await installer.launch(slug: source.slug, commandID: command)
        try await installer.setEnabled(slug: source.slug, enabled: false)
        try await installer.setEnabled(slug: source.slug, enabled: true)
        try await installer.launch(slug: source.slug, commandID: command)
        let generations = await service.runGenerations()
        XCTAssertEqual(generations, [1, 3])
        let builds = await service.builds
        XCTAssertEqual(builds, 1)
        try await installer.uninstall(slug: source.slug)
        let empty = try await backend.installations()
        XCTAssertTrue(empty.isEmpty)
    }

    func testFirstInstallCanReplaceAnObsoleteStageAfterRestart() async throws {
        let (root, old, oldProject, service) = try fixture()
        let (latestRoot, latest, latestProject, _) = try fixture(revision: String(repeating: "b", count: 40))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: latestRoot)
        }
        let storage = root.appendingPathComponent("registry")
        let recipe = RaycastStoreArtifactSeal.Recipe(identifier: "synthetic", runtimeDigest: String(repeating: "0", count: 64),
                                                   qualifiedAPIVersions: [])
        let protected = ProtectedReceiptFixtureStore()
        let anchor = try RaycastStoreProtectedReceiptState(storage: protected, registryID: UUID(),
            publicKey: P256.Signing.PrivateKey().publicKey, recipe: recipe)
        try anchor.initializeNewRegistry(observedRegistryDigest: nil)
        let first = try RaycastStoreInstallCoordinator(root: storage, service: service, anchor: anchor) { _, _ in oldProject }
        let obsolete = try await first.prepare(old)
        let second = try RaycastStoreInstallCoordinator(root: storage, service: service, anchor: anchor) { source, _ in
            guard source == latest else { throw RaycastStoreInstaller.Failure.preparationFailed }
            return latestProject
        }
        let sameRevision = try await second.prepare(old)
        XCTAssertEqual(sameRevision.id, obsolete.id)
        XCTAssertEqual(sameRevision.contentDigest, obsolete.contentDigest)

        let installer = RaycastStoreInstaller(backend: second)
        protected.rejectReplacement()
        do { _ = try await installer.prepareAndInstall(latest); XCTFail("Rejected anchor write must not activate") }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .preparationFailed) }
        let recoveredPublication = try await second.recoverPendingPublication()
        XCTAssertEqual(recoveredPublication, .discardedUncommitted)
        let recoveredStage = try await second.prepare(old)
        XCTAssertEqual(recoveredStage.id, obsolete.id)

        let installed = try await installer.prepareAndInstall(latest)
        XCTAssertEqual(installed.source, latest)
        XCTAssertEqual(installed.generation, 1)
        XCTAssertNotEqual(installed.id, obsolete.id)
        do { _ = try await first.install(obsolete); XCTFail("Old stage must not activate") }
        catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .missing) }
        let persisted = try await first.installations()
        XCTAssertEqual(persisted.map(\.id), [installed.id])
        let builds = await service.builds
        XCTAssertEqual(builds, 3)
    }

    func testFailedOrCancelledReplacementKeepsExactStage() async throws {
        let (root, old, oldProject, service) = try fixture()
        let (latestRoot, latest, latestProject, _) = try fixture(revision: String(repeating: "b", count: 40))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: latestRoot)
        }
        let storage = root.appendingPathComponent("registry")
        let first = try RaycastStoreInstallCoordinator(root: storage, service: service) { _, _ in oldProject }
        let obsolete = try await first.prepare(old)
        let failing = try RaycastStoreInstallCoordinator(root: storage, service: service) { _, _ in
            throw RaycastStoreInstaller.Failure.preparationFailed
        }
        do { _ = try await RaycastStoreInstaller(backend: failing).prepareAndInstall(latest); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .preparationFailed) }
        let recovered = try await failing.prepare(old)
        XCTAssertEqual(recovered.id, obsolete.id)
        XCTAssertEqual(recovered.contentDigest, obsolete.contentDigest)

        let second = try RaycastStoreInstallCoordinator(root: storage, service: service) { _, _ in latestProject }
        await service.delayBuild()
        let pending = Task { try await RaycastStoreInstaller(backend: second).prepareAndInstall(latest) }
        await service.awaitBuild()
        pending.cancel()
        await service.allowBuild()
        do { _ = try await pending.value; XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .cancelled) }
        let afterCancel = try await failing.prepare(old)
        XCTAssertEqual(afterCancel.id, obsolete.id)
        XCTAssertEqual(afterCancel.contentDigest, obsolete.contentDigest)
    }

    func testReplacementDoesNotOverwriteAnActivationDuringBuild() async throws {
        let (root, old, oldProject, service) = try fixture()
        let (latestRoot, latest, latestProject, _) = try fixture(revision: String(repeating: "b", count: 40))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: latestRoot)
        }
        let storage = root.appendingPathComponent("registry")
        let first = try RaycastStoreInstallCoordinator(root: storage, service: service) { _, _ in oldProject }
        let staged = try await first.prepare(old)
        let second = try RaycastStoreInstallCoordinator(root: storage, service: service) { _, _ in latestProject }
        await service.delayBuild()
        let pending = Task { try await second.prepare(latest) }
        await service.awaitBuild()
        let activated: RaycastStoreInstallation
        do { activated = try await first.install(staged) }
        catch { await service.allowBuild(); throw error }
        await service.allowBuild()
        do { _ = try await pending.value; XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .stale) }
        let installed = try await second.installations()
        XCTAssertEqual(installed.map(\.id), [activated.id])
        XCTAssertEqual(installed.map(\.source), [old])
    }

    func testRevocationAfterRegistryCheckButBeforeBrokerAdmissionRejectsOldGeneration() async throws {
        let (root, source, project, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try RaycastStoreInstallCoordinator(root: root.appendingPathComponent("registry"), service: service) { _, _ in project }
        let staged = try await backend.prepare(source)
        let record = try await backend.install(staged)
        let command = try XCTUnwrap(record.manifest.commands.first).id
        await service.configure()
        await service.delayAdmission()
        let pending = Task { try await backend.launch(installationID: record.id, commandID: command) }
        await service.awaitAdmission()
        let disabled = try await backend.setEnabled(installationID: record.id, enabled: false)
        await service.allowAdmission()
        XCTAssertEqual(disabled.generation, 2)
        do { try await pending.value; XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .stale) }
        let generations = await service.runGenerations()
        XCTAssertTrue(generations.isEmpty)
    }
}
