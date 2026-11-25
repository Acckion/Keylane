import CryptoKit
import Darwin
import os
import XCTest
@testable import KeylaneCore

private final class M1Anchor: RaycastStoreRegistryAnchor, @unchecked Sendable {
    let lock = NSLock(); var head: String?; var failAfterAdvance = false; var missing = false
    func verify(expectedDigest: String?) throws {
        try lock.withLock { guard !missing, head == expectedDigest else { throw RaycastStoreDiskRegistry.Failure.anchor } }
    }
    func advance(previousDigest: String?, to nextDigest: String) throws {
        try lock.withLock {
            guard !missing, head == previousDigest else { throw RaycastStoreDiskRegistry.Failure.anchor }
            head = nextDigest
            if failAfterAdvance { failAfterAdvance = false; throw CocoaError(.fileWriteUnknown) }
        }
    }
}
private final class M1Trust: RaycastStoreArtifactTrust, @unchecked Sendable {
    let seal: RaycastStoreArtifactSeal
    var stopFails = false
    var stopped: [UInt64] = []
    let admission: MacOSExtensionRunAdmission?
    init(_ seal: RaycastStoreArtifactSeal, admission: MacOSExtensionRunAdmission? = nil) {
        self.seal = seal
        self.admission = admission
    }
    func quarantine(installationID: UUID, before generation: UInt64) throws {
        admission?.quarantine(installationID: installationID, before: generation)
    }
    func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        try seal.verify(bytes: bytes, source: source, installationID: installationID)
    }
    func revoke(installationID: UUID, before generation: UInt64) async throws {
        await admission?.revoke(installationID: installationID, before: generation)
        if stopFails { throw CocoaError(.fileWriteUnknown) }; stopped.append(generation)
    }
}

@MainActor final class MacOSStoreBuildTests: XCTestCase {
    let key = P256.Signing.PrivateKey()
    func testReviewedCommandCohortsBindRevisionVersionModeAndGrants() throws {
        let all = MacOSReviewedRaycastCommand.entries
        XCTAssertEqual(Set(all.map(\.commandID)).count, 10)
        for (slug, count) in [("uuid-generator", 3), ("silent-mention", 2), ("lorem-ipsum", 5)] {
            let entry = try XCTUnwrap(all.first { $0.slug == slug })
            let source = try RaycastStoreSource(slug: slug, catalog: .init(revision: entry.revision, slugs: [slug]))
            let reviewed = try MacOSReviewedRaycastCommand.buildEntries(for: source, apiVersion: entry.apiVersion)
            XCTAssertEqual(reviewed.count, count)
            XCTAssertTrue(reviewed.allSatisfy { $0.mode == .noView && $0.capabilities == entry.capabilities })
            XCTAssertTrue(entry.capabilities.isSubset(of: MacOSNoViewCapabilities.supported))
            XCTAssertThrowsError(try MacOSReviewedRaycastCommand.buildEntries(for: source, apiVersion: "0.0.0"))
            let differentRevision = try RaycastStoreSource(slug: slug,
                catalog: .init(revision: String(repeating: "0", count: 40), slugs: [slug]))
            XCTAssertThrowsError(try MacOSReviewedRaycastCommand.buildEntries(for: differentRevision, apiVersion: entry.apiVersion))
        }
    }

    func testPreviouslySealedSingleCommandRemainsTheOnlyCommandOnReopen() throws {
        let entry = try XCTUnwrap(MacOSReviewedRaycastCommand.entry(forSlug: "lorem-ipsum"))
        let source = try RaycastStoreSource(slug: entry.slug, catalog: .init(revision: entry.revision, slugs: [entry.slug]))
        let data = try XCTUnwrap(MacOSReviewedRaycastCommand.cachedManifest(for: source))
        let files: Set<String> = ["src/markdown.tsx", "assets/icon.png"]
        let reopened = try MacOSReviewedRaycastCommand.manifest(
            data: data, files: files, source: source, apiVersion: entry.apiVersion, sealedEntries: ["src/markdown.tsx"]
        )
        XCTAssertEqual(reopened.commands.map(\.id), [entry.commandID])
    }

    func fixture(_ digit: String, id: UUID) async throws -> (RaycastStoreSource, RaycastStoreArtifactSeal, RaycastStoreInstallCoordinator.BuiltArtifact) {
        let source = try RaycastStoreSource(slug:"m1",catalog:.init(revision:String(repeating:digit,count:40),slugs:["m1"]))
        let files: [String:Data] = ["package.json":Data(#"{"name":"m1","title":"M1","author":"fixture","platforms":["macOS"],"commands":[{"name":"main","title":"Main","mode":"no-view"}]}"#.utf8),
                                 "src/main.ts":Data("globalThis.value=42;".utf8),"assets/icon.txt":Data(digit.utf8),"LICENSE":Data("First party fixture".utf8)]
        let tree = files.map { path,data -> [String:Any] in
            ["path":path,"sha":Insecure.SHA1.hash(data:Data("blob \(data.count)\0".utf8)+data).map { String(format:"%02x",$0) }.joined(),"size":data.count,"mode":"100644","type":"blob"]
        } + [["path":"src","sha":source.revision,"mode":"040000","type":"tree"],["path":"assets","sha":source.revision,"mode":"040000","type":"tree"]]
        let snapshot = try RaycastStoreSnapshot(source:source,treeSHA:source.revision,recursiveTreeJSON:JSONSerialization.data(withJSONObject:["sha":source.revision,"truncated":false,"tree":tree]))
        let project = try RaycastStoreBuildProject(source:.init(snapshot:snapshot,files:files),supportedRuntimeAPIVersions:[],tarballs:[:],target:.macOSArm64)
        let recipe = try MacOSExtensionBuild.Recipe(compilerSHA256:String(repeating:"1",count:64),helperSHA256:String(repeating:"2",count:64))
        let runtime = String(repeating:"3",count:64)
        let seal = try RaycastStoreArtifactSeal(publicKey:key.publicKey,recipe:.init(identifier:"m1-v2",runtimeDigest:runtime,qualifiedAPIVersions:[],buildRecipe:recipe))
        let plan = try MacOSExtensionBuild.Plan(files:project.files.map { .init(path:$0.path,body:$0.body) },entries:["src/main.ts"])
        let request = try MacOSExtensionBuild.Request(recipe:recipe,plan:plan)
        let commands = [MacOSExtensionBuild.File(path:"src/main.ts",body:Data("(()=>{globalThis.value=42})();".utf8))]
        let artifact = try MacOSExtensionBuild.Artifact(request:request,reply:.init(id:request.id,recipeDigest:recipe.digest,projectDigest:plan.digest,commands:commands))
        let digest = try StoreRuntimeBridge.projectDigest(entry:"src/main.ts",files:project.files.map { .init(path:$0.path,body:$0.body) })
        let built = commands.map { file in StoreRuntimeBridge.BuiltCommand(receipt:.init(provenance:.init(installation:.init(id:id.uuidString,generation:0),entry:file.path,projectDigest:digest,runtimeDigest:runtime),artifactDigest:MacOSExtensionBuild.hash(file.body)),artifact:file.body) }
        let sealed = try seal.issue(source:source,installationID:id,project:project,built:built,capabilities:[],buildArtifact:artifact,sign: { try self.key.signature(for:$0) })
        return (source,seal,sealed)
    }
    func testBufferedEffectsRejectRevocationAfterTicketConsumption() throws {
        let id = UUID()
        let installation = StoreRuntimeBridge.Installation(id: id.uuidString, generation: 1)
        let receipt = StoreRuntimeBridge.Receipt(
            provenance: .init(installation: installation, entry: "src/main.js", projectDigest: "", runtimeDigest: ""),
            artifactDigest: "")
        let lease = OSAllocatedUnfairLock(initialState: true)
        let ticket = StoreGuestRunTicket(id: UUID(), profileID: id, installation: installation, receipt: receipt,
            commandID: "fixture", capabilities: [MacOSNoViewCapabilities.clipboard], launchContext: .init(),
            macOSLease: lease, liveLease: { lease.withLock { $0 } })
        XCTAssertTrue(ticket.consumeForStart())
        var writes = 0
        XCTAssertThrowsError(try ticket.commitMacOSEffects([MacOSNoViewCapabilities.toast]) { writes += 1 })
        try ticket.commitMacOSEffects([MacOSNoViewCapabilities.clipboard]) { writes += 1 }
        lease.withLock { $0 = false }
        XCTAssertThrowsError(try ticket.commitMacOSEffects([MacOSNoViewCapabilities.clipboard]) { writes += 1 })
        XCTAssertEqual(writes, 1)
    }

    func testBufferedToastLifecyclePublishesOnlyTheFinalActiveToast() throws {
        let id = UUID()
        let installation = StoreRuntimeBridge.Installation(id: id.uuidString, generation: 1)
        let receipt = StoreRuntimeBridge.Receipt(
            provenance: .init(installation: installation, entry: "src/main.js", projectDigest: "", runtimeDigest: ""),
            artifactDigest: "")
        let ticket = StoreGuestRunTicket(id: UUID(), profileID: id, installation: installation, receipt: receipt,
            commandID: "fixture", capabilities: [MacOSNoViewCapabilities.toast], launchContext: .init(),
            macOSLease: .init(initialState: true), liveLease: { true })
        let show = #"{"operation":"show","id":1,"title":"Working","style":"ANIMATED"}"#
        let update = #"{"operation":"update","id":1,"title":"Ready","style":"SUCCESS"}"#
        let hide = #"{"operation":"hide","id":1}"#

        func validate(_ events: [String]) throws -> [MacOSNoViewCapabilities.Presentation] {
            let response = MacOSNoViewCapabilities.Response(effects: events.map { .init(kind: .toast, value: $0) })
            return try MacOSNoViewCapabilities.validate(response, ticket: ticket).0
        }

        let presentations = try validate([show, update])
        XCTAssertEqual(presentations.count, 1)
        guard case .toast(let final) = presentations.first else { return XCTFail("Expected a toast") }
        XCTAssertEqual(final.title, "Ready")
        XCTAssertTrue(try validate([show, update, hide]).isEmpty)
        XCTAssertThrowsError(try validate([show, hide, update]))
        XCTAssertThrowsError(try validate([show, hide, show]))
        XCTAssertThrowsError(try validate([show, #"{"operation":"hide","id":2}"#]))
    }

    func testStoreOwnershipRejectsOverlappingRuntimeAndUnpinnedLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("owner.lock")
        let fd = Darwin.open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        close(fd)
        var info = stat()
        XCTAssertEqual(lstat(path.path, &info), 0)
        func acquire(exclusive: Bool, inode: UInt64? = nil) throws -> MacOSStoreOwnership {
            try .init(path: path, device: Int64(info.st_dev), inode: inode ?? info.st_ino, exclusive: exclusive)
        }
        XCTAssertThrowsError(try acquire(exclusive: true, inode: info.st_ino ^ 1))
        do {
            let first = try acquire(exclusive: false)
            let second = try acquire(exclusive: false)
            try withExtendedLifetime((first, second)) {
                XCTAssertThrowsError(try acquire(exclusive: true)) {
                    XCTAssertEqual($0 as? RaycastStoreDiskRegistry.Failure, .busy)
                }
            }
        }
        let runtime = try acquire(exclusive: true)
        try withExtendedLifetime(runtime) {
            XCTAssertThrowsError(try acquire(exclusive: false)) {
                XCTAssertEqual($0 as? RaycastStoreDiskRegistry.Failure, .busy)
            }
        }
    }

    func testNoViewAdmissionRetiresTicketBeforeDisableAndWaitsForDriverExit() async throws {
        struct Driver: MacOSExtensionNoViewDriver {
            let received: AsyncStream<StoreGuestRunTicket>.Continuation
            let stopped: AsyncStream<Void>
            func run(bytes: Data, ticket: StoreGuestRunTicket) async throws {
                guard !bytes.isEmpty, ticket.consumeForStart() else { throw MacOSExtensionRunAdmission.Failure.retired }
                received.yield(ticket)
                // Detached waiter models a process that takes time to stop even
                // after its parent task receives cancellation.
                await Task.detached { for await _ in stopped { break } }.value
            }
        }
        let receipts = AsyncStream<StoreGuestRunTicket>.makeStream()
        let stop = AsyncStream<Void>.makeStream()
        defer { stop.continuation.finish(); receipts.continuation.finish() }
        let id = UUID(), (source, seal, built) = try await fixture("a", id: id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = MacOSExtensionRunAdmission()
        let registry = try RaycastStoreDiskRegistry(root: root, trust: M1Trust(seal, admission: admission), anchor: M1Anchor())
        let staged = try await registry.prepare(bytes: built.bytes, expectedDigest: built.digest, source: source,
                                                grantedCapabilities: [], installationID: id)
        let installed = try await registry.activate(staged)
        let command = installed.manifest.commands[0].id
        let artifact = try await registry.validate(installationID: id, generation: 1, commandID: command, capabilities: [])
        let context = RaycastStoreInstallCoordinator.RunContext(installation: installed, commandID: command, artifact: artifact, registry: registry)
        let driver = Driver(received: receipts.continuation, stopped: stop.stream)
        let running = Task {
            defer { receipts.continuation.finish() }
            try await admission.start(context, profileID: UUID(), seal: seal, driver: driver)
        }
        var iterator = receipts.stream.makeAsyncIterator()
        let first = await iterator.next()
        let ticket = try XCTUnwrap(first)
        XCTAssertFalse(ticket.consumeForStart())
        do {
            try await admission.start(context, profileID: UUID(), seal: seal, driver: driver)
            XCTFail("admitted a second process")
        } catch { XCTAssertEqual(error as? MacOSExtensionRunAdmission.Failure, .busy) }
        let disabling = Task { try await registry.setEnabled(installationID: id, expectedGeneration: 1, enabled: false) }
        let deadline = ContinuousClock.now + .seconds(2)
        while ticket.isCurrent(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(ticket.isCurrent())
        do {
            _ = try await registry.installations()
            XCTFail("disable should still hold the registry lock until exit")
        } catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .busy) }
        stop.continuation.finish()
        let disabled = try await disabling.value
        XCTAssertFalse(disabled.enabled)
        do { try await running.value; XCTFail("revoked invocation reported success") } catch is CancellationError {}
        _ = try await registry.setEnabled(installationID: id, expectedGeneration: 2, enabled: true)
        do {
            try await admission.start(context, profileID: UUID(), seal: seal, driver: driver)
            XCTFail("old generation admitted after re-enable")
        } catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .stale) }
        XCTAssertFalse(ticket.isCurrent())
    }

    func testV2ResourcesBoundAndLegacyEnvelopeCannotDowngrade() async throws {
        let id = UUID(), (source,seal,artifact) = try await fixture("a",id:id)
        _ = try seal.verify(bytes:artifact.bytes,source:source,installationID:id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let registry = try RaycastStoreDiskRegistry(root:root,trust:M1Trust(seal),anchor:M1Anchor())
        let handle = try await registry.prepare(bytes:artifact.bytes,expectedDigest:artifact.digest,source:source,grantedCapabilities:[],installationID:id)
        let installed = try await registry.activate(handle)
        let opened = try seal.open(.init(source:source,digest:artifact.digest,bytes:artifact.bytes),installation:installed,commandID:installed.manifest.commands[0].id)
        XCTAssertEqual(opened.resources.map(\.path),["LICENSE","assets/icon.txt"])
        for change in ["body","path","inventory","schema"] {
            var envelope = try JSONSerialization.jsonObject(with:artifact.bytes) as! [String:Any]
            var payload = try JSONSerialization.jsonObject(with:Data(base64Encoded:envelope["payload"] as! String)!) as! [String:Any]
            if change == "schema" { envelope["schema"] = 1 }
            else {
                var build = payload["build"] as! [String:Any]
                if change == "inventory" {
                    var inventory = build["inventory"] as! [String:Any]; inventory["recipeDigest"] = String(repeating:"0",count:64); build["inventory"] = inventory
                } else {
                    var resources = build["resources"] as! [[String:Any]]
                    resources[0][change == "path" ? "path" : "body"] = change == "path" ? "../escape" : Data("changed".utf8).base64EncodedString()
                    build["resources"] = resources
                }
                payload["build"] = build
                let body = try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys])
                envelope["payload"] = body.base64EncodedString()
                envelope["signature"] = try key.signature(for:body).rawRepresentation.base64EncodedString()
            }
            // Even with a valid test signer, the independent schema/resource
            // policy must reject malformed content. Production keys stay native.
            XCTAssertThrowsError(try seal.verify(bytes:JSONSerialization.data(withJSONObject:envelope),source:source,installationID:id))
        }
    }
    func testCandidateSurvivesRestartAndStaleUpdateCannotOverrideDisable() async throws {
        let id = UUID(), (a,seal,one) = try await fixture("a",id:id), (b,_,two) = try await fixture("b",id:id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let anchor = M1Anchor(), trust = M1Trust(seal)
        let registry = try RaycastStoreDiskRegistry(root:root,trust:trust,anchor:anchor)
        let h = try await registry.prepare(bytes:one.bytes,expectedDigest:one.digest,source:a,grantedCapabilities:[],installationID:id)
        _ = try await registry.activate(h)
        let candidate = try await registry.prepare(bytes:two.bytes,expectedDigest:two.digest,source:b,grantedCapabilities:[],installationID:id)
        let reopened = try RaycastStoreDiskRegistry(root:root,trust:trust,anchor:anchor)
        let restored = try await reopened.stagedArtifact(for:b)
        XCTAssertEqual(restored?.contentDigest,candidate.contentDigest)
        let during = try await reopened.installations(); XCTAssertEqual(during[0].source,a)
        _ = try await registry.setEnabled(installationID:id,expectedGeneration:1,enabled:false)
        do { _ = try await reopened.activate(candidate); XCTFail("stale update undid disable") } catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure,.stale) }
        let invalidated = try await reopened.stagedArtifact(for:b)
        XCTAssertNil(invalidated)
        let fresh = try await registry.prepare(bytes:two.bytes,expectedDigest:two.digest,source:b,grantedCapabilities:[],installationID:id)
        let result = try await registry.activate(fresh)
        XCTAssertEqual(result.generation,3); XCTAssertFalse(result.enabled); XCTAssertEqual(result.id,id)
    }
    func testLifecycleChangeAllowsAnotherRevisionWithoutUninstallOrDiscard() async throws {
        let id = UUID(), (a,seal,one) = try await fixture("a",id:id), (b,_,two) = try await fixture("b",id:id), (c,_,three) = try await fixture("c",id:id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let anchor = M1Anchor(), trust = M1Trust(seal)
        let registry = try RaycastStoreDiskRegistry(root:root,trust:trust,anchor:anchor)
        let initial = try await registry.prepare(bytes:one.bytes,expectedDigest:one.digest,source:a,grantedCapabilities:[],installationID:id)
        _ = try await registry.activate(initial)
        _ = try await registry.prepare(bytes:two.bytes,expectedDigest:two.digest,source:b,grantedCapabilities:[],installationID:id)
        _ = try await registry.setEnabled(installationID:id,expectedGeneration:1,enabled:false)
        let reopened = try RaycastStoreDiskRegistry(root:root,trust:trust,anchor:anchor)
        let stale = try await reopened.stagedArtifact(for:b); XCTAssertNil(stale)
        let replacement = try await reopened.prepare(bytes:three.bytes,expectedDigest:three.digest,source:c,grantedCapabilities:[],installationID:id)
        _ = try await reopened.setEnabled(installationID:id,expectedGeneration:2,enabled:true)
        let invalidated = try await reopened.stagedArtifact(for:c); XCTAssertNil(invalidated)
        let fresh = try await reopened.prepare(bytes:two.bytes,expectedDigest:two.digest,source:b,grantedCapabilities:[],installationID:id)
        do { _ = try await reopened.activate(replacement); XCTFail("outdated confirmation applied") } catch {}
        let result = try await reopened.activate(fresh)
        XCTAssertEqual(result.generation,4); XCTAssertTrue(result.enabled); XCTAssertEqual(result.source,b)
    }
    func testFailedRevocationLeavesDurableQuarantineAndExactRetryFinishes() async throws {
        let id = UUID(), (a,seal,one) = try await fixture("a",id:id), (b,_,two) = try await fixture("b",id:id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let anchor = M1Anchor(), trust = M1Trust(seal)
        let registry = try RaycastStoreDiskRegistry(root:root,trust:trust,anchor:anchor)
        let initial = try await registry.prepare(bytes:one.bytes,expectedDigest:one.digest,source:a,grantedCapabilities:[],installationID:id)
        _ = try await registry.activate(initial)
        let candidate = try await registry.prepare(bytes:two.bytes,expectedDigest:two.digest,source:b,grantedCapabilities:[],installationID:id)
        trust.stopFails = true
        do { _ = try await registry.activate(candidate); XCTFail() } catch {}
        let pending = try await registry.installations(); XCTAssertFalse(pending[0].enabled); XCTAssertEqual(pending[0].generation,2)
        let reopened = try RaycastStoreDiskRegistry(root:root,trust:trust,anchor:anchor)
        trust.stopFails = false
        let result = try await reopened.activate(candidate); XCTAssertEqual(result.generation,2); XCTAssertEqual(result.source,b)
    }
    func testInterruptedProtectedCommitCompletesOnlyFromIndependentHead() async throws {
        let id = UUID(), (source,seal,artifact) = try await fixture("a",id:id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let anchor = M1Anchor();anchor.failAfterAdvance = true
        let registry = try RaycastStoreDiskRegistry(root:root,trust:M1Trust(seal),anchor:anchor)
        do { _ = try await registry.prepare(bytes:artifact.bytes,expectedDigest:artifact.digest,source:source,grantedCapabilities:[],installationID:id); XCTFail() } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("registry.pending").path))
        anchor.missing = true
        do { _ = try await registry.recoverPendingPublication(); XCTFail("missing authority adopted disk") } catch {}
        anchor.missing = false
        let recovered = try await registry.recoverPendingPublication(); XCTAssertEqual(recovered,.completed)
        let staged = try await registry.stagedArtifact(for:source); XCTAssertEqual(staged?.id,id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("registry.pending").path))
    }
    func testNoImplicitSetupApproval() { XCTAssertThrowsError(try MacOSBuildProfile.Approval(userConfirmed:false)) }
    func testProtectedStorageRequiresExactSignedApplicationIdentity() throws {
        let team = "TESTTEAM01", identifier = "org.keylane.synthetic"
        let group = team + "." + identifier
        let rights: [String:Any] = ["com.apple.application-identifier":group,
                                   "com.apple.developer.team-identifier":team,"keychain-access-groups":[group]]
        XCTAssertEqual(try MacOSBuildProfile.protectedAccessGroup(entitlements:rights,identifier:identifier,team:team),group)
        var implicit = rights; implicit.removeValue(forKey:"keychain-access-groups")
        XCTAssertEqual(try MacOSBuildProfile.protectedAccessGroup(entitlements:implicit,identifier:identifier,team:team),group)
        XCTAssertThrowsError(try MacOSBuildProfile.protectedAccessGroup(entitlements:[:],identifier:identifier,team:team))
        for (key,value) in [("com.apple.application-identifier","TESTTEAM01.org.keylane.foreign" as Any),
                            ("com.apple.developer.team-identifier","OTHERTEAM1" as Any),
                            ("keychain-access-groups",[group,"TESTTEAM01.shared"] as Any),
                            ("keychain-access-groups",["TESTTEAM01.foreign"] as Any),
                            ("keychain-access-groups",group as Any)] {
            var changed = rights; changed[key] = value
            XCTAssertThrowsError(try MacOSBuildProfile.protectedAccessGroup(entitlements:changed,identifier:identifier,team:team))
        }
        XCTAssertThrowsError(try MacOSBuildProfile.protectedAccessGroup(entitlements:rights,identifier:identifier,team:"*"))
    }
    func testUninstallRemovesStagedReplacementWithoutCorruptingRegistry() async throws {
        let id = UUID(), (a,seal,one) = try await fixture("a",id:id), (b,_,two) = try await fixture("b",id:id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let registry = try RaycastStoreDiskRegistry(root:root,trust:M1Trust(seal),anchor:M1Anchor())
        let first = try await registry.prepare(bytes:one.bytes,expectedDigest:one.digest,source:a,grantedCapabilities:[],installationID:id)
        _ = try await registry.activate(first)
        _ = try await registry.prepare(bytes:two.bytes,expectedDigest:two.digest,source:b,grantedCapabilities:[],installationID:id)
        try await registry.uninstall(installationID:id,expectedGeneration:1)
        let list = try await registry.installations(); XCTAssertTrue(list.isEmpty)
        let staged = try await registry.stagedArtifact(for:b); XCTAssertNil(staged)
    }
}
