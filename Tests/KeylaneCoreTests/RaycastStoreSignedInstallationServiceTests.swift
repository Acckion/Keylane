import CryptoKit
import XCTest
@testable import KeylaneCore

private func fixtureDigest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

@MainActor
private final class AdapterFixtureDriver: StoreSignedGuestEngine.Driver {
    var runtimeDigest = String(repeating: "c", count: 64)
    var generations: [UInt64] = []
    var supportsTicketedLaunch = true
    var holdsStarts = false
    var waiting: [UUID: (StoreGuestRunTicket, CheckedContinuation<Void, Never>)] = [:]
    func releaseStarts() {
        holdsStarts = false
        let pending = waiting
        waiting = [:]
        for (_, gate) in pending.values { gate.resume() }
    }
    func awaitStarts(_ count: Int) async throws {
        for _ in 0..<500 {
            if waiting.count == count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw StoreRuntimeBridge.Rejection.staleInstallation
    }
    let commandBytes = Data("inert synthetic command".utf8)
    func buildInFreshGuest(resources: StoreSignedGuestEngine.Resources, envelope: Data, entry: String) async throws -> Data { commandBytes }
    func runInFreshGuest(resources: StoreSignedGuestEngine.Resources, artifact: Data, receipt: StoreRuntimeBridge.Receipt,
                         installation: StoreRuntimeBridge.Installation) async throws {
        XCTFail("Adapter fell back to legacy start")
        throw StoreRuntimeBridge.Rejection.staleInstallation
    }
    func runInFreshGuest(resources: StoreSignedGuestEngine.Resources, artifact: Data, ticket: StoreGuestRunTicket) async throws {
        if holdsStarts {
            await withCheckedContinuation { waiting[ticket.id] = (ticket, $0) }
        }
        guard ticket.consumeForStart() else { throw StoreRuntimeBridge.Rejection.staleInstallation }
        XCTAssertEqual(artifact, commandBytes)
        XCTAssertTrue(ticket.allowsEffect("preferences.read"))
        XCTAssertFalse(ticket.allowsEffect("clipboard.copy"))
        XCTAssertFalse(ticket.consumeForStart())
        generations.append(ticket.installation.generation)
    }
}

private final class AdapterFixtureAuthority: RaycastStoreSignedInstallationService.Authority, @unchecked Sendable {
    typealias Service = RaycastStoreSignedInstallationService
    private struct State {
        var profile: UUID
        var watermarks: [String: UInt64] = [:]
        var sessions: [UUID: Service.Admission] = [:]
        var observed: [Service.Admission] = []
    }
    private var state: State
    private let lock = NSLock()
    init(profile: UUID) { state = .init(profile: profile) }
    private func use<T>(_ body: (inout State) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&state)
    }
    var observations: [Service.Admission] { use { $0.observed } }
    var live: Int { use { $0.sessions.count } }
    func useOtherProfile() { use { $0.profile = UUID() } }
    func buildCapabilities(profileID: UUID, manifest: RaycastExtensionManifest) throws -> Set<String> {
        guard use({ $0.profile == profileID }) else { throw Service.Failure.capabilities }
        return ["preferences.read"]
    }
    private func permits(_ request: Service.Admission, state: State) -> Bool {
        request.profileID == state.profile &&
        request.installation.generation >= state.watermarks[request.installation.id, default: 1] &&
        request.capabilities == ["preferences.read"]
    }
    func permits(_ request: Service.Admission) throws -> Bool { use { permits(request, state: $0) } }
    func admit(_ request: Service.Admission) throws -> Service.Lease {
        let ticket = request.launchID
        let accepted = use { state in
            guard permits(request, state: state) else { return false }
            state.observed.append(request); state.sessions[ticket] = request
            return true
        }
        guard accepted else { throw Service.Failure.capabilities }
        return .init(isCurrent: { self.use { $0.sessions[ticket] != nil && self.permits(request, state: $0) } },
                     finish: { self.use { $0.sessions[ticket] = nil } })
    }
    func revoke(profileID: UUID, installationID: UUID, before generation: UInt64) async throws {
        use { state in
            let key = installationID.uuidString
            state.watermarks[key] = max(generation, state.watermarks[key, default: 1])
            state.sessions = state.sessions.filter { $0.value.installation.id != key || $0.value.installation.generation >= generation }
        }
    }
}

final class RaycastStoreSignedInstallationServiceTests: XCTestCase {
    @MainActor
    func testInertProjectUsesAnchoredCoordinatorAndCurrentPreferencesProfileAndRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = Data(#"{"name":"demo","title":"Test","author":"fixture","platforms":["macOS"],"preferences":[{"name":"intro","type":"textfield","required":true}],"commands":[{"name":"hello","title":"Hello","mode":"no-view","preferences":[{"name":"sample","type":"checkbox","default":true}]},{"name":"other","title":"Other","mode":"no-view","preferences":[{"name":"privateOther","type":"textfield","default":"not for hello"}]}]}"#.utf8)
        let files = ["package.json": shell, "src/hello.js": Data("// inert".utf8), "src/other.js": Data("// inert".utf8)]
        let revision = String(repeating: "a", count: 40)
        let source = try RaycastStoreSource(slug: "demo", catalog: .init(revision: revision, slugs: ["demo"]))
        let tree = files.map { path, bytes -> [String: Any] in
            let git = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes).map { String(format: "%02x", $0) }.joined()
            return ["path": path, "size": bytes.count, "mode": "100644", "type": "blob", "sha": git]
        } + [["path": "src", "mode": "040000", "type": "tree", "sha": revision]]
        let snapshot = try RaycastStoreSnapshot(source: source, treeSHA: revision,
            recursiveTreeJSON: JSONSerialization.data(withJSONObject: ["sha": revision, "truncated": false, "tree": tree]))
        let project = try RaycastStoreBuildProject(source: .init(snapshot: snapshot, files: files),
                                                  supportedRuntimeAPIVersions: [], tarballs: [:])
        let manifest = try RaycastExtensionManifest.readStoreManifest(shell, files: Set(files.keys))
        let profile = UUID(), engine = AdapterFixtureDriver()
        let signedEngine = StoreSignedGuestEngine(driver: engine) {
            .init(kernelURL: URL(fileURLWithPath: "/inert/Image"),
                  ramdiskURL: URL(fileURLWithPath: "/inert/ingress.cpio"),
                  digest: engine.runtimeDigest, recipeIdentifier: "synthetic")
        }
        let authority = AdapterFixtureAuthority(profile: profile)
        let runtimeDigest = engine.runtimeDigest
        let bytes = engine.commandBytes
        let grants: Set<String> = ["preferences.read"]
        let envelope: @Sendable (UUID) -> Data = { Data(("inert fixture receipt:" + $0.uuidString).utf8) }
        let service = RaycastStoreSignedInstallationService(profileID: profile,
            recipe: .init(identifier: "synthetic", runtimeDigest: runtimeDigest, qualifiedAPIVersions: []),
            engine: signedEngine, authority: authority, artifacts: .init(
               verify: { supplied, original, id in
                   guard supplied == envelope(id), original == source else { throw RaycastStoreArtifactSeal.Failure.identity }
                   return .init(extensionID: source.slug, manifest: manifest, requiredCapabilities: grants)
               },
               open: { _, installed, commandID in
                   let command = try XCTUnwrap(manifest.commands.first { $0.id == commandID })
                   return .init(receipt: .init(provenance: .init(installation: .init(id: installed.id.uuidString, generation: 0),
                       entry: command.entry, projectDigest: String(repeating: "b", count: 64), runtimeDigest: runtimeDigest),
                       artifactDigest: fixtureDigest(bytes)), bytes: bytes)
               },
               issue: { _, id, _, built, capabilities in
                   XCTAssertEqual(built.count, 2)
                   XCTAssertEqual(capabilities, grants)
                   let data = envelope(id)
                   return .init(bytes: data, digest: fixtureDigest(data), capabilities: grants)
               }))
        let anchor = AdapterTestAnchor()
        #if DEBUG
        let pinned = "1bba20ebadde672986edb348026837c7b381cf91b6e7887fd74c2853e3791370"
        XCTAssertThrowsError(try RaycastStoreAppCapability.OfflineFixture(
            project: project, expectedDigest: String(repeating: "0", count: 64)
        ))
        let fixture = try RaycastStoreAppCapability.OfflineFixture(project: project, expectedDigest: pinned)
        XCTAssertEqual(fixture.index.slugs, ["demo"])
        XCTAssertEqual(try fixture.details(slug: "demo", revision: revision).title, "Test")
        let otherRevision = String(repeating: "b", count: 40)
        XCTAssertThrowsError(try fixture.details(slug: "demo", revision: otherRevision))
        let otherSource = try RaycastStoreSource(slug: "demo", catalog: .init(revision: otherRevision, slugs: ["demo"]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            _ = try await RaycastStoreAppCapability.verifiedOfflineFixture(
                fixture, root: root.appendingPathComponent("not-an-isolated-root"), service: service, anchor: anchor
            )
            XCTFail("The fixture cannot use arbitrary registry paths")
        } catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .invalidArtifact) }
        let capability = try await RaycastStoreAppCapability.verifiedOfflineFixture(
            fixture, root: root, service: service, anchor: anchor
        )
        let initialBackend = capability.coordinator
        do {
            _ = try await initialBackend.prepare(otherSource)
            XCTFail("Different revision cannot prepare or fall back to the public catalog")
        } catch { XCTAssertEqual(error as? RaycastStoreInstaller.Failure, .invalidArtifact) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        #else
        let initialBackend = try RaycastStoreInstallCoordinator(root: root, service: service, anchor: anchor) { _, _ in project }
        #endif
        let prepared = try await initialBackend.prepare(source)
        let installed = try await initialBackend.install(prepared)
        let command = try XCTUnwrap(manifest.commands.first(where: { $0.entry == "src/hello.js" })?.id)
        engine.supportsTicketedLaunch = false
        let unavailable = try await initialBackend.launchReadiness(installationID: installed.id, commandID: command)
        XCTAssertEqual(unavailable, .runtimeUnavailable)
        do { try await initialBackend.launch(installationID: installed.id, commandID: command); XCTFail("Legacy driver cannot receive lease") }
        catch { XCTAssertEqual(error as? RaycastStoreSignedInstallationService.Failure, .runtime) }
        engine.supportsTicketedLaunch = true
        let blocked = try await initialBackend.launchReadiness(installationID: installed.id, commandID: command)
        XCTAssertEqual(blocked, .preferencesRequired)
        var changes = RaycastStorePreferenceChanges()
        changes.values[.init(scope: .extensionWide, name: "intro")] = .set(.string("synthetic"))
        try await initialBackend.save(installationID: installed.id, generation: installed.generation, changes: changes)
        // Reopen from the same anchored registry before any command reaches the driver.
        #if DEBUG
        let reopened = try await RaycastStoreAppCapability.verifiedOfflineFixture(
            fixture, root: root, service: service, anchor: anchor
        )
        let backend = reopened.coordinator
        #else
        let backend = try RaycastStoreInstallCoordinator(root: root, service: service, anchor: anchor) { _, _ in project }
        #endif
        let ready = try await backend.launchReadiness(installationID: installed.id, commandID: command)
        XCTAssertEqual(ready, .ready)
        try await backend.launch(installationID: installed.id, commandID: command)
        XCTAssertEqual(engine.generations, [1])
        XCTAssertEqual(authority.live, 0)
        let admitted = try XCTUnwrap(authority.observations.last)
        XCTAssertEqual(Set(admitted.launchContext.ordinaryPreferences.keys), ["intro", "sample"])
        // Concurrent commands share an installed generation, not a launch token
        // or the other command's preference snapshot.
        let otherCommand = try XCTUnwrap(manifest.commands.first(where: { $0.id != command })?.id)
        engine.holdsStarts = true
        let original = Task { try await backend.launch(installationID: installed.id, commandID: command) }
        let other = Task { try await backend.launch(installationID: installed.id, commandID: otherCommand) }
        defer { engine.releaseStarts(); original.cancel(); other.cancel() }
        try await engine.awaitStarts(2)
        let tickets = engine.waiting.values.map { $0.0 }
        XCTAssertEqual(Set(tickets.map(\.id)).count, 2)
        XCTAssertEqual(Set(tickets.map(\.id)), Set(authority.observations.suffix(2).map(\.launchID)))
        XCTAssertEqual(Set(tickets.map(\.profileID)), [profile])
        XCTAssertEqual(Set(tickets.map { $0.installation.generation }), [1])
        let originalTicket = try XCTUnwrap(tickets.first { $0.commandID == command })
        let otherTicket = try XCTUnwrap(tickets.first { $0.commandID == otherCommand })
        XCTAssertNotEqual(originalTicket.receipt, otherTicket.receipt)
        XCTAssertEqual(Set(originalTicket.launchContext.ordinaryPreferences.keys), ["intro", "sample"])
        XCTAssertEqual(Set(otherTicket.launchContext.ordinaryPreferences.keys), ["intro", "privateOther"])
        XCTAssertFalse(originalTicket.allowsEffect("preferences.read")) // not started
        engine.releaseStarts()
        try await original.value
        try await other.value
        XCTAssertFalse(originalTicket.allowsEffect("preferences.read")) // finished lease

        engine.holdsStarts = true
        let stalled = Task { try await backend.launch(installationID: installed.id, commandID: command) }
        defer { engine.releaseStarts(); stalled.cancel() }
        try await engine.awaitStarts(1)
        let stalledTicket = try XCTUnwrap(engine.waiting.values.first?.0)
        _ = try await backend.setEnabled(installationID: installed.id, enabled: false)
        engine.releaseStarts()
        do { try await stalled.value; XCTFail("A revoked admission must not start") }
        catch { XCTAssertEqual(error as? StoreRuntimeBridge.Rejection, .staleInstallation) }
        XCTAssertFalse(stalledTicket.allowsEffect("preferences.read"))
        do { try await backend.launch(installationID: installed.id, commandID: command); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .inactive) }
        _ = try await backend.setEnabled(installationID: installed.id, enabled: true)
        engine.runtimeDigest = String(repeating: "d", count: 64)
        do { try await backend.launch(installationID: installed.id, commandID: command); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreSignedInstallationService.Failure, .runtime) }
        engine.runtimeDigest = runtimeDigest
        authority.useOtherProfile()
        do { try await backend.launch(installationID: installed.id, commandID: command); XCTFail() }
        catch { XCTAssertEqual(error as? RaycastStoreSignedInstallationService.Failure, .capabilities) }
        XCTAssertEqual(engine.generations, [1, 1, 1])
    }
}

private final class AdapterTestAnchor: RaycastStoreRegistryAnchor, @unchecked Sendable {
    private let lock = NSLock()
    private var head: String?
    func verify(expectedDigest: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard head == expectedDigest else { throw RaycastStoreDiskRegistry.Failure.anchor }
    }
    func advance(previousDigest: String?, to nextDigest: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard head == previousDigest else { throw RaycastStoreDiskRegistry.Failure.anchor }
        head = nextDigest
    }
}
