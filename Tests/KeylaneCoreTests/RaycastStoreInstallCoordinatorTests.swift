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
        guard project.files.contains(where: { $0.path == "src/hello.js" }) else {
            throw RaycastStoreInstaller.Failure.invalidArtifact
        }
        let bytes = fixtureBytes(source: source, installationID: installationID)
        return .init(bytes: bytes, digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), capabilities: ["toast"])
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
    private func fixture() throws -> (URL, RaycastStoreSource, RaycastStoreBuildProject, CoordinatorFixtureService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let manifestRoot = root.appendingPathComponent("manifest")
            try FileManager.default.createDirectory(at: manifestRoot.appendingPathComponent("src"), withIntermediateDirectories: true)
            let files = [
                "package.json": Data(#"{"name":"fixture","author":"tests","title":"Fixture","commands":[{"name":"hello","title":"Hello","mode":"no-view"}]}"#.utf8),
                "src/hello.js": Data("// self-authored bytes; not run by these tests".utf8)
            ]
            for (path, content) in files { try content.write(to: manifestRoot.appendingPathComponent(path)) }
            let revision = String(repeating: "a", count: 40)
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
