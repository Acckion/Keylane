import Foundation
import CryptoKit
@testable import M0Store

// Uses unmodified #222 algorithms; key/CAS provider are disposable fixture roots.
// No product enrollment or protected backend is installed by this experiment.
private final class ReceiptCAS: RaycastStoreProtectedReceiptStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    var rejectNext = false // parent serial fixture controller only
    func read() throws -> Data? { lock.withLock { value } }
    func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool {
        lock.withLock {
            if rejectNext { rejectNext = false; return false }
            guard value == expected else { return false }
            value = replacement; return true
        }
    }
    func removeForControl() { lock.withLock { value = nil } }
}
private final class ReceiptLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var child: Int32?
    private(set) var stopConfirmed = false
    func current() -> Bool { lock.withLock { active } }
    func attach(_ pid: Int32) { lock.withLock { precondition(active && child == nil); child = pid } }
    func revoke() throws {
        let pid = lock.withLock { active = false; return child }
        if let pid {
            guard M0StopChildUnreaped(pid) == 1 else { throw M0ReceiptGate.Failure.unexpected }
            stopConfirmed = true
        }
    }
}
private final class ReceiptTrust: RaycastStoreArtifactTrust, @unchecked Sendable {
    let seal: RaycastStoreArtifactSeal
    private let lock = NSLock()
    private var watermarks: [UUID: UInt64] = [:]
    private var leases: [(UUID, UInt64, ReceiptLease)] = []
    init(_ seal: RaycastStoreArtifactSeal) { self.seal = seal }
    func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        try seal.verify(bytes: bytes, source: source, installationID: installationID)
    }
    func bind(_ installation: RaycastStoreInstallation) throws -> ReceiptLease {
        try lock.withLock {
            guard installation.enabled, installation.generation >= watermarks[installation.id, default: 1] else {
                throw M0ReceiptGate.Failure.rejected
            }
            let lease = ReceiptLease(); leases.append((installation.id, installation.generation, lease)); return lease
        }
    }
    func quarantine(installationID: UUID, before generation: UInt64) throws {
        let stale = lock.withLock {
            watermarks[installationID] = max(generation, watermarks[installationID, default: 1])
            return leases.filter { $0.0 == installationID && $0.1 < generation }.map { $0.2 }
        }
        // Invalidate and confirm the owned helper exited BEFORE registry may enable.
        for lease in stale { try lease.revoke() }
    }
    func revoke(installationID: UUID, before generation: UInt64) async throws {
        try quarantine(installationID: installationID, before: generation)
    }
}

@MainActor final class M0ReceiptGate {
    enum Failure: Error { case rejected, unexpected }
    static let modes = ["valid", "source-injection", "signature", "inner-digest", "wrong-key", "wrong-runtime",
                        "wrong-installation", "wrong-command", "wrong-revision", "grant-mismatch",
                        "registry-rollback", "anchor-missing", "ticket-replay", "disable-before",
                        "disable-after", "off-on", "uninstall", "replace", "cas-failure"]
    private static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    // Only this first-party program is sealed/executed. stdin never supplies JS.
    private static let program = """
    __m0Entered();
    const r=JSON.parse(__m0Request('{"v":1,"id":1,"op":"storage.get","key":"item"}'));
    JSON.stringify({valid:r.ok&&r.value==="synthetic-a",injected:typeof injected!=="undefined"});
    """
    let source: String
    let digest: String
    let ticket: StoreGuestRunTicket
    private let lease: ReceiptLease
    private let trust: ReceiptTrust
    private let registry: RaycastStoreDiskRegistry
    private let storage: ReceiptCAS
    private let installed: RaycastStoreInstallation
    private let key: P256.Signing.PrivateKey
    private let project: RaycastStoreBuildProject
    private let root: URL
    private(set) var freshAdmission = false
    var current: Bool { ticket.isCurrent() }
    var stopped: Bool { lease.stopConfirmed }
    func attach(_ pid: Int32) { lease.attach(pid) }

    private static func built(_ project: RaycastStoreBuildProject, id: UUID, runtime: String) throws -> StoreRuntimeBridge.BuiltCommand {
        let bytes = Data(program.utf8)
        let digest = try StoreRuntimeBridge.projectDigest(entry: "src/hello.js", files: project.files.map { .init(path: $0.path, body: $0.body) })
        return .init(receipt: .init(provenance: .init(installation: .init(id: id.uuidString, generation: 0),
            entry: "src/hello.js", projectDigest: digest, runtimeDigest: runtime), artifactDigest: hex(bytes)), artifact: bytes)
    }
    static func open(helper: URL, mode: String) async throws -> M0ReceiptGate {
        guard modes.contains(mode) else { throw Failure.rejected }
        let key = P256.Signing.PrivateKey(), profile = UUID()
        let runtime = hex(try Data(contentsOf: helper))
        let recipe = RaycastStoreArtifactSeal.Recipe(identifier: "restricted-js-m0", runtimeDigest: runtime, qualifiedAPIVersions: [])
        let seal = try RaycastStoreArtifactSeal(publicKey: key.publicKey, recipe: recipe)
        let source = try RaycastStoreSource(slug: "m0-receipt", catalog: .init(revision: String(repeating: "a", count: 40), slugs: ["m0-receipt"]))
        let files = ["package.json": Data(#"{"name":"m0-receipt","title":"M0","author":"first-party","platforms":["macOS"],"commands":[{"name":"hello","title":"Hello","mode":"no-view"}]}"#.utf8),
                     "src/hello.js": Data(program.utf8)]
        let tree = files.map { path, bytes -> [String: Any] in
            let sha = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8)+bytes).map { String(format: "%02x", $0) }.joined()
            return ["path":path,"sha":sha,"size":bytes.count,"mode":"100644","type":"blob"]
        } + [["path":"src","sha":source.revision,"mode":"040000","type":"tree"]]
        let snapshot = try RaycastStoreSnapshot(source: source, treeSHA: source.revision,
            recursiveTreeJSON: JSONSerialization.data(withJSONObject: ["sha":source.revision,"truncated":false,"tree":tree]))
        let project = try RaycastStoreBuildProject(source: .init(snapshot: snapshot, files: files), supportedRuntimeAPIVersions: [], tarballs: [:])
        let id = UUID(), commandID = "extension:raycast:first-party/m0-receipt/hello"
        let built = try built(project, id: id, runtime: runtime)
        let issued = try seal.issue(source: source, installationID: id, project: project, built: [built],
                                    capabilities: ["storage.read","storage.write"], sign: { try key.signature(for: $0) })
        func expectSeal(_ expected: RaycastStoreArtifactSeal.Failure, _ operation: () throws -> Void) throws -> Never {
            do { try operation() } catch let failure as RaycastStoreArtifactSeal.Failure where failure == expected { throw Failure.rejected }
            throw Failure.unexpected
        }
        if mode == "signature" || mode == "inner-digest" {
            var envelope = try JSONSerialization.jsonObject(with: issued.bytes) as! [String: Any]
            var body = Data(base64Encoded: envelope["payload"] as! String)!
            if mode == "signature" { body.append(32) }
            else {
                var payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                var commands = payload["commands"] as! [[String: Any]]
                commands[0]["bytes"] = Data("tampered".utf8).base64EncodedString(); payload["commands"] = commands
                body = try JSONSerialization.data(withJSONObject: payload)
                envelope["signature"] = try key.signature(for: body).rawRepresentation.base64EncodedString()
            }
            envelope["payload"] = body.base64EncodedString()
            let tampered = try JSONSerialization.data(withJSONObject: envelope)
            try expectSeal(mode == "signature" ? .untrusted : .integrity) { _ = try seal.verify(bytes: tampered, source: source, installationID: id) }
        }
        if mode == "wrong-key" || mode == "wrong-runtime" {
            let other = try RaycastStoreArtifactSeal(publicKey: mode == "wrong-key" ? P256.Signing.PrivateKey().publicKey : key.publicKey,
                recipe: .init(identifier: recipe.identifier, runtimeDigest: mode == "wrong-runtime" ? String(repeating:"0",count:64) : runtime, qualifiedAPIVersions: []))
            try expectSeal(mode == "wrong-key" ? .untrusted : .recipe) { _ = try other.verify(bytes: issued.bytes, source: source, installationID: id) }
        }
        if mode == "wrong-installation" || mode == "wrong-revision" {
            let selected = mode == "wrong-revision" ? try RaycastStoreSource(slug: source.slug, catalog: .init(revision: String(repeating:"b",count:40),slugs:[source.slug])) : source
            try expectSeal(.identity) { _ = try seal.verify(bytes: issued.bytes, source: selected, installationID: mode == "wrong-installation" ? UUID() : id) }
        }
        let storage = ReceiptCAS()
        let anchor = try RaycastStoreProtectedReceiptState(storage: storage, registryID: profile, publicKey: key.publicKey, recipe: recipe)
        try anchor.initializeNewRegistry(observedRegistryDigest: nil)
        let root = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("receipt-"+UUID().uuidString)
        let trust = ReceiptTrust(seal)
        let registry = try RaycastStoreDiskRegistry(root: root, trust: trust, anchor: anchor)
        if mode == "grant-mismatch" {
            do { _ = try await registry.prepare(bytes: issued.bytes, expectedDigest: issued.digest, source: source, grantedCapabilities: ["storage.read"], installationID: id) }
            catch RaycastStoreDiskRegistry.Failure.capability { throw Failure.rejected }
            throw Failure.unexpected
        }
        let staged = try await registry.prepare(bytes: issued.bytes, expectedDigest: issued.digest, source: source, grantedCapabilities: issued.capabilities, installationID: id)
        let installed = try await registry.activate(staged)
        let command = installed.manifest.commands[0].id
        guard command == commandID else { throw Failure.unexpected }
        if mode == "wrong-command" {
            do { _ = try await registry.validate(installationID: id, generation: 1, commandID: command+"-other", capabilities: issued.capabilities) }
            catch RaycastStoreDiskRegistry.Failure.identity { throw Failure.rejected }
            throw Failure.unexpected
        }
        if mode == "registry-rollback" || mode == "anchor-missing" {
            if mode == "registry-rollback" {
                let old = try Data(contentsOf: root.appendingPathComponent("registry.json"))
                _ = try await registry.setEnabled(installationID: id, expectedGeneration: 1, enabled: false)
                try old.write(to: root.appendingPathComponent("registry.json"))
            } else { storage.removeForControl() }
            do { _ = try await registry.installations() }
            catch RaycastStoreDiskRegistry.Failure.protectedStateRecovery(let reason) {
                // Disable publishes pending and final heads. The saved active
                // snapshot is older than the immediate previous head.
                guard reason == (mode == "registry-rollback" ? .registryMismatch : .protectedStateMissing) else { throw Failure.unexpected }
                throw Failure.rejected
            }
            throw Failure.unexpected
        }
        // Reopen actual disk registry under the independent, still-live CAS anchor.
        let reopened = try RaycastStoreDiskRegistry(root: root, trust: trust, anchor: anchor)
        let artifact = try await reopened.validate(installationID: id, generation: 1, commandID: command, capabilities: issued.capabilities)
        let context = RaycastStoreInstallCoordinator.RunContext(installation: installed, commandID: command, artifact: artifact, registry: reopened)
        let (ticket, lease, run) = try await reopened.withCurrentRun(context) { current, _, _ in
            let lease = try trust.bind(current)
            let run = try seal.open(artifact, installation: current, commandID: command)
            let ticket = StoreGuestRunTicket(id: UUID(), profileID: profile, installation: .init(id: id.uuidString, generation: current.generation),
                receipt: run.receipt, commandID: command, capabilities: issued.capabilities,
                launchContext: .init(), liveLease: { lease.current() })
            return (ticket, lease, run)
        }
        guard ticket.consumeForStart() else { throw Failure.unexpected }
        if mode == "ticket-replay" {
            guard !ticket.consumeForStart() else { throw Failure.unexpected }; throw Failure.rejected
        }
        guard String(data: run.bytes, encoding: .utf8) == program else { throw Failure.unexpected }
        return M0ReceiptGate(source: program, digest: run.receipt.artifactDigest, ticket: ticket, lease: lease, trust: trust,
                             registry: reopened, storage: storage, installed: installed, key: key, project: project, root: root)
    }
    private init(source: String, digest: String, ticket: StoreGuestRunTicket, lease: ReceiptLease, trust: ReceiptTrust,
                 registry: RaycastStoreDiskRegistry, storage: ReceiptCAS, installed: RaycastStoreInstallation,
                 key: P256.Signing.PrivateKey, project: RaycastStoreBuildProject, root: URL) {
        self.source=source; self.digest=digest; self.ticket=ticket; self.lease=lease; self.trust=trust; self.registry=registry
        self.storage=storage; self.installed=installed; self.key=key; self.project=project; self.root=root
    }
    func advance(_ mode: String) async throws {
        if mode == "uninstall" || mode == "replace" {
            try await registry.uninstall(installationID: installed.id, expectedGeneration: installed.generation)
            if mode == "replace" {
                let id = UUID(), runtime = ticket.receipt.provenance.runtimeDigest
                let issued = try trust.seal.issue(source: installed.source, installationID: id, project: project,
                    built: [try Self.built(project, id: id, runtime: runtime)], capabilities: ticket.capabilities,
                    sign: { try self.key.signature(for: $0) })
                let staged = try await registry.prepare(bytes: issued.bytes, expectedDigest: issued.digest, source: installed.source,
                    grantedCapabilities: issued.capabilities, installationID: id)
                let active = try await registry.activate(staged)
                let artifact = try await registry.validate(installationID: id, generation: active.generation, commandID: ticket.commandID, capabilities: ticket.capabilities)
                _ = try trust.seal.open(artifact, installation: active, commandID: ticket.commandID)
                freshAdmission = try trust.bind(active).current()
            }
        } else {
            if mode == "cas-failure" { storage.rejectNext = true }
            do {
                let disabled = try await registry.setEnabled(installationID: installed.id, expectedGeneration: installed.generation, enabled: false)
                if mode == "off-on" {
                    let enabled = try await registry.setEnabled(installationID: disabled.id, expectedGeneration: disabled.generation, enabled: true)
                    _ = try await registry.validate(installationID: enabled.id, generation: enabled.generation, commandID: ticket.commandID, capabilities: ticket.capabilities)
                    freshAdmission = try trust.bind(enabled).current()
                }
                if mode == "cas-failure" { throw Failure.unexpected }
            } catch RaycastStoreDiskRegistry.Failure.anchor where mode == "cas-failure" {
                guard !current && stopped else { throw Failure.unexpected }
                // Registry intentionally wraps the CAS conflict as .anchor.
                // Even if the old enabled disk head survives, the independent
                // watermark must deny minting another lease at that generation.
                do { _ = try trust.bind(installed) }
                catch Failure.rejected { return }
                throw Failure.unexpected
            }
        }
        guard !current && stopped else { throw Failure.unexpected }
    }
}
