import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import KeylaneCore

private final class InertCreateOnlyItems: @unchecked Sendable {
    private let mutex = NSLock()
    private var items: [String: Data] = [:]
    private var interruptedAccount: String?
    private let backing: URL?
    init(backing: URL? = nil) { self.backing = backing }

    private func file(_ account: String) -> URL? {
        guard !account.isEmpty, account.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 58
        }) else { return nil }
        return backing?.appendingPathComponent(account)
    }

    func failAfterAdd(account: String) { mutex.withLock { interruptedAccount = account } }
    func value(account: String) -> Data? {
        mutex.withLock {
            if let path = file(account) { return try? Data(contentsOf: path) }
            return items[account]
        }
    }

    func add(_ account: String, _ bytes: Data) throws -> RaycastStoreMacProfileReservation.Insert {
        try mutex.withLock {
            if let path = file(account) {
                do { try bytes.write(to: path, options: .withoutOverwriting) }
                catch let error as CocoaError where error.code == .fileWriteFileExists { return .duplicate }
                return .inserted
            }
            guard items[account] == nil else { return .duplicate }
            items[account] = bytes
            if interruptedAccount == account { throw CocoaError(.fileWriteUnknown) }
            return .inserted
        }
    }

    func replace(account: String, with bytes: Data) throws {
        try mutex.withLock {
            guard let path = file(account), FileManager.default.fileExists(atPath: path.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try bytes.write(to: path, options: .atomic)
        }
    }

    var count: Int { mutex.withLock { items.count } }
}

private struct RestartScopeSlot: RaycastStoreProtectedReceiptSlot {
    let api: InertCreateOnlyItems
    let account: String
    enum Override: Sendable { case actual, absent, corrupt }
    let override: Override
    func readExisting() throws -> Data? {
        switch override {
        case .actual: api.value(account: account)
        case .absent: nil
        case .corrupt: Data([0xff])
        }
    }
    func replaceExisting(with bytes: Data) throws {
        guard case .actual = override else { throw CocoaError(.fileWriteNoPermission) }
        try api.replace(account: account, with: bytes)
    }
}

/// Records only a deterministic test result; never interprets or executes artifact bytes.
private actor RestartFakeExecution {
    private(set) var attempts = 0
    private(set) var output: String?
    let installationID: UUID
    let commandID: String

    init(installationID: UUID, commandID: String) {
        self.installationID = installationID
        self.commandID = commandID
    }

    func accept(_ context: RaycastStoreInstallCoordinator.RunContext) throws {
        attempts += 1
        guard attempts == 1, context.installation.id == installationID,
              context.installation.enabled, context.installation.generation == 1,
              context.commandID == commandID, context.artifact.bytes == RestartScopeService.artifact,
              context.artifact.source == context.installation.source else {
            throw RaycastStoreDiskRegistry.Failure.integrity
        }
        output = "inert-restart-accepted"
    }
}

private struct RestartScopeService: RaycastStoreInstallationService, @unchecked Sendable {
    let owner: StoreGuestCommonAuthority.ProfileOwner
    let source: RaycastStoreSource
    let manifest: RaycastExtensionManifest
    let runtime: RestartFakeExecution?
    static let artifact = Data("inert-self-authored-fixture".utf8)
    static let grants: Set<String> = ["preferences.read"]

    func verifyRegistryAccess() throws {
        guard owner.isCurrent() else { throw RaycastStoreDiskRegistry.Failure.anchor }
    }

    func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        try verifyRegistryAccess()
        guard bytes == Self.artifact, source == self.source else { throw RaycastStoreDiskRegistry.Failure.integrity }
        return .init(extensionID: source.slug, manifest: manifest, requiredCapabilities: Self.grants)
    }

    func qualifiedAPIVersions() async throws -> Set<String> { [] }
    func build(project: RaycastStoreBuildProject, source: RaycastStoreSource, installationID: UUID) async throws
        -> RaycastStoreInstallCoordinator.BuiltArtifact {
        guard project.source == self.source, source == self.source else { throw RaycastStoreDiskRegistry.Failure.identity }
        let digest = SHA256.hash(data: Self.artifact).map { String(format: "%02x", $0) }.joined()
        return .init(bytes: Self.artifact, digest: digest, capabilities: Self.grants)
    }

    func readiness(_ context: RaycastStoreInstallCoordinator.RunContext) async throws -> RaycastStoreLaunchReadiness {
        .runtimeUnavailable
    }

    func runCurrent(_ context: RaycastStoreInstallCoordinator.RunContext) async throws {
        try verifyRegistryAccess()
        guard let runtime else { throw RaycastStoreSignedInstallationService.Failure.runtime }
        try await runtime.accept(context)
    }

    func revoke(installationID: UUID, before generation: UInt64) async throws {
        // There are no executable sessions or hardware effects in this fixture.
        try verifyRegistryAccess()
        guard generation > 1 else { throw RaycastStoreDiskRegistry.Failure.stale }
    }
}

final class RaycastStoreMacProfileReservationTests: XCTestCase {
    typealias Backing = RaycastStoreMacProfileReservation
    private let request = Data([9])
    private let requestID = UUID()

    private func fixture() throws -> (URL, Backing, InertCreateOnlyItems) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let api = InertCreateOnlyItems()
        let id = requestID
        let backing = Backing(root: root, rootIdentity: .init(device: info.st_dev, inode: info.st_ino),
                              authenticate: { $0 == Data([9]) ? id : nil }, insert: { try api.add($0, $1) })
        return (root, backing, api)
    }

    private func namespace() -> Backing.Allocation {
        .init(profileID: UUID(), registryID: UUID())
    }

    func testReservationCreatesOnlyNewInodesAndDuplicateRequestDoesNotAllocate() throws {
        let (root, backing, api) = try fixture()
        let new = namespace()
        guard case .reserved(let permit) = try backing.reserveNew(new, explicitRequest: request) else { return XCTFail() }
        let staged = try backing.stageOwnedLocks(permit)
        let finalized = try finalize(backing, permit, staged)
        let owner = try StoreGuestCommonAuthority.ProfileOwner(
            root: URL(fileURLWithPath: finalized.ownerBinding.rootPath), profileID: new.profileID,
            expected: finalized.ownerBinding)
        XCTAssertTrue(owner.isCurrent())
        XCTAssertNotEqual(staged.owner, staged.journal)
        XCTAssertNotEqual(staged.journal, staged.receipt)
        XCTAssertEqual(api.count, 2)
        let other = namespace()
        guard case .denied = try backing.reserveNew(other, explicitRequest: request) else { return XCTFail() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [new.profileID.uuidString])
        XCTAssertEqual(api.count, 2)
        XCTAssertThrowsError(try backing.stageOwnedLocks(permit))
        XCTAssertEqual(api.count, 2)
    }

    private let recipe = RaycastStoreArtifactSeal.Recipe(
        identifier: "inert-reservation", runtimeDigest: String(repeating: "0", count: 64), qualifiedAPIVersions: [])

    private func publicKey() throws -> P256.Signing.PublicKey {
        try P256.Signing.PublicKey(compressedRepresentation: Data([0x03, 0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5,
            0x63, 0xa4, 0x40, 0xf2, 0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96]))
    }

    private func finalize(_ backing: Backing, _ permit: Backing.Permit, _ locks: Backing.StagedLocks)
        throws -> Backing.FinalizedEnrollment {
        try backing.finalize(permit: permit, locks: locks, publicKey: publicKey(), recipe: recipe)
    }

    private func initial(_ namespace: Backing.Namespace) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema": 1, "registryID": namespace.scope.registryID.uuidString,
            "binding": namespace.scope.bindingDigest, "sequence": 0
        ], options: [.sortedKeys])
    }

    private func createSelection(root: URL, backing: Backing, api: InertCreateOnlyItems, owner: UUID)
        throws -> (Backing.FinalizedEnrollment, RaycastStoreSerializedReceiptStorage.LockIdentity) {
        let request = namespace()
        guard case .reserved(let permit) = try backing.reserveNew(request, explicitRequest: self.request) else { throw CocoaError(.fileWriteUnknown) }
        let locks = try backing.stageOwnedLocks(permit)
        let finalized = try finalize(backing, permit, locks)
        let allocationAccount = "profile:" + request.profileID.uuidString
        let allocated = try XCTUnwrap(api.value(account: allocationAccount))
        let allocation = try JSONSerialization.jsonObject(with: allocated) as? [String: Any]
        XCTAssertNil(allocation?["binding"], "An unfinalized request is not protected enrollment")
        let publication = try backing.receiptPublication(finalized)
        let receiptLock = try publication.publishLock()
        try publication.publishSlot(initial(finalized.namespace), receiptLock)

        let scope = finalized.namespace.scope
        // Inert durable-journal output for the composition edge; no platform enrollment is used.
        let journal = try JSONSerialization.data(withJSONObject: ["version": 1, "registryID": scope.registryID.uuidString,
            "binding": scope.bindingDigest, "phase": "enrolled", "consumedProof": UUID().uuidString,
            "lockDevice": receiptLock.device, "lockInode": receiptLock.inode])
        _ = try api.add("journal:" + scope.registryID.uuidString, journal)
        let approval = UUID()
        let candidate = RaycastStoreExplicitProfileActivation.Candidate(profileID: request.profileID, scope: scope)
        let activation = RaycastStoreExplicitProfileActivation(owner: owner, read: { api.value(account: $0) },
            add: { try api.add($0, $1) }, authenticate: { _, selected, _ in
                selected == candidate ? .init(proofID: approval, explicitlyAuthorizedEmptySelection: true, consume: { true }) : nil
            }, verifyBoundEmpty: { _, selected in
                guard selected == candidate else { return false }
                return try publication.verifyLock(receiptLock)
            })
        try activation.activate(candidate, explicitApproval: Data([1]))
        return (finalized, receiptLock)
    }

    private func makeReader(root: URL, owner: UUID, pinned: RaycastStoreSerializedReceiptStorage.LockIdentity? = nil,
                            read: @escaping @Sendable (String) throws -> Data?) throws -> RaycastStoreSelectedProfileReader {
        var info = stat()
        XCTAssertEqual(lstat(root.path, &info), 0)
        let digest = recipe.runtimeDigest
        return try RaycastStoreSelectedProfileReader(owner: owner, root: root,
            rootLock: pinned ?? .init(device: info.st_dev, inode: info.st_ino), expectedTeam: "fixture",
            verifiedRuntime: { ("fixture", digest) }, key: publicKey(), recipe: recipe,
            read: read)
    }

    func testFinalizedReservationAndSelectedReadbackGiveSameLiveOwner() throws {
        let (root, backing, api) = try fixture()
        let owner = UUID()
        let (finalized, receiptLock) = try createSelection(root: root, backing: backing, api: api, owner: owner)
        let reader = try makeReader(root: root, owner: owner, read: { api.value(account: $0) })
        let selected = try XCTUnwrap(reader.selected())
        XCTAssertEqual(selected.scope, finalized.namespace.scope)
        XCTAssertEqual(selected.ownerBinding, finalized.ownerBinding)
        XCTAssertEqual(selected.receiptLock, receiptLock)
        let liveOwner = try StoreGuestCommonAuthority.ProfileOwner(
            root: URL(fileURLWithPath: selected.ownerBinding.rootPath), profileID: selected.profileID,
            expected: selected.ownerBinding)
        XCTAssertTrue(liveOwner.isCurrent())
        XCTAssertThrowsError(try StoreGuestCommonAuthority.ProfileOwner(
            root: URL(fileURLWithPath: selected.ownerBinding.rootPath), profileID: selected.profileID,
            expected: selected.ownerBinding))
    }

    private func restartCoordinator(selection: RaycastStoreSelectedProfileReader.Capability,
                                    owner: StoreGuestCommonAuthority.ProfileOwner, api: InertCreateOnlyItems,
                                    override: RestartScopeSlot.Override = .actual,
                                    runtime: RestartFakeExecution? = nil) throws
        -> (RaycastStoreInstallCoordinator, RaycastStoreSource, RaycastStoreProtectedReceiptState) {
        let root = URL(fileURLWithPath: selection.ownerBinding.rootPath, isDirectory: true)
        let receipt = RaycastStoreSerializedReceiptStorage(directory: root, lockIdentity: selection.receiptLock,
            slot: RestartScopeSlot(api: api, account: selection.scope.registryID.uuidString, override: override))
        let anchor = try RaycastStoreProtectedReceiptState(storage: receipt, registryID: selection.scope.registryID,
            publicKey: publicKey(), recipe: recipe, owner: selection.ownerBinding)
        guard anchor.enrollmentScope == selection.scope else { throw RaycastStoreDiskRegistry.Failure.anchor }
        let manifestData = Data(#"{"name":"synthetic-restart","title":"Restart","author":"fixture","preferences":[{"name":"marker","type":"textfield"}],"commands":[{"name":"hello","title":"Hello","mode":"no-view"}]}"#.utf8)
        let files = ["package.json": manifestData, "src/hello.js": Data("// self-authored inert input".utf8)]
        let revision = String(repeating: "a", count: 40)
        let source = try RaycastStoreSource(slug: "synthetic-restart", catalog: .init(revision: revision, slugs: ["synthetic-restart"]))
        let tree = files.map { path, bytes -> [String: Any] in
            let digest = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes)
                .map { String(format: "%02x", $0) }.joined()
            return ["path": path, "sha": digest, "size": bytes.count, "mode": "100644", "type": "blob"]
        } + [["path": "src", "sha": revision, "mode": "040000", "type": "tree"]]
        let snapshot = try RaycastStoreSnapshot(source: source, treeSHA: revision,
            recursiveTreeJSON: JSONSerialization.data(withJSONObject: ["sha": revision, "truncated": false, "tree": tree]))
        let project = try RaycastStoreBuildProject(source: .init(snapshot: snapshot, files: files),
            supportedRuntimeAPIVersions: [], tarballs: [:])
        let manifest = try RaycastExtensionManifest.readStoreManifest(manifestData, files: Set(files.keys))
        let coordinator = try RaycastStoreInstallCoordinator(root: root,
            service: RestartScopeService(owner: owner, source: source, manifest: manifest, runtime: runtime), anchor: anchor,
            requiresExistingRoot: true, validateSource: { if $0 != source { throw RaycastStoreDiskRegistry.Failure.identity } },
            acquireProject: { _, _ in project })
        return (coordinator, source, anchor)
    }

    /// Run by two explicit xctest processes against one disposable directory.
    /// File-backed test slots are not assertions about macOS credential storage.
    func testProcessIsolatedSelectedReadback() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let staging = env["KEYLANE_SYNTHETIC_RESTART_ROOT"],
              let phase = env["KEYLANE_SYNTHETIC_RESTART_PHASE"] else { throw XCTSkip("Explicit two-process fixture only") }
        let expectation = env["KEYLANE_SYNTHETIC_RESTART_EXPECTATION"] ?? "disabled"
        guard ["enabled", "disabled"].contains(expectation) else { throw CocoaError(.fileReadCorruptFile) }
        let shouldEnable = expectation == "enabled"
        let expectedGeneration: UInt64 = shouldEnable ? 1 : 2
        let root = URL(fileURLWithPath: staging, isDirectory: true)
        let canonical = root.resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        guard canonical.deletingLastPathComponent().pathComponents == temporary.pathComponents,
              canonical.lastPathComponent.hasPrefix("keylane-store-synthetic-restart."),
              canonical.lastPathComponent == root.lastPathComponent else { throw CocoaError(.fileReadNoPermission) }
        let profiles = canonical.appendingPathComponent("profiles")
        let slots = canonical.appendingPathComponent("slots")
        let metadata = canonical.appendingPathComponent("test-receipt.json")
        let api = InertCreateOnlyItems(backing: slots)
        let owner = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000701"))
        struct Pin: Codable {
            let pid: Int32
            let profile: UUID
            let registry: UUID
            let digest: String
            let rootDevice: Int32
            let rootInode: UInt64
            let installation: UUID
            let command: String
            let enabled: Bool
        }
        let marker = "synthetic-ordinary-preference"
        let pref = RaycastStorePreferenceKey(scope: .extensionWide, name: "marker")
        var info = stat()
        if phase == "publish" {
            try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: slots, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            XCTAssertEqual(lstat(profiles.path, &info), 0)
            let backing = Backing(root: profiles, rootIdentity: .init(device: info.st_dev, inode: info.st_ino),
                authenticate: { $0 == Data([9]) ? owner : nil }, insert: { try api.add($0, $1) })
            let (result, _) = try createSelection(root: profiles, backing: backing, api: api, owner: owner)
            let reader = try makeReader(root: profiles, owner: owner, read: { api.value(account: $0) })
            let selection = try XCTUnwrap(reader.selected())
            let guardLock = try StoreGuestCommonAuthority.ProfileOwner(root: URL(fileURLWithPath: selection.ownerBinding.rootPath),
                profileID: selection.profileID, expected: selection.ownerBinding)
            let (coordinator, source, _) = try restartCoordinator(selection: selection, owner: guardLock, api: api)
            try await coordinator.verifyExistingProtectedRegistry()
            let staged = try await coordinator.prepare(source)
            let installed = try await coordinator.install(staged)
            let command = try XCTUnwrap(installed.manifest.commands.first)
            var changes = RaycastStorePreferenceChanges()
            changes.values[pref] = .set(.string(marker))
            try await coordinator.save(installationID: installed.id, generation: installed.generation, changes: changes)
            let saved = try await coordinator.load(installationID: installed.id, generation: installed.generation)
            XCTAssertEqual(saved.values[pref], .string(marker))
            let final = if shouldEnable { installed } else {
                try await coordinator.setEnabled(installationID: installed.id, enabled: false)
            }
            XCTAssertEqual(final.generation, expectedGeneration)
            XCTAssertEqual(final.enabled, shouldEnable)
            let pin = Pin(pid: getpid(), profile: result.namespace.profileID, registry: result.namespace.scope.registryID,
                digest: result.namespace.scope.bindingDigest, rootDevice: info.st_dev, rootInode: info.st_ino,
                installation: installed.id, command: command.id, enabled: shouldEnable)
            try JSONEncoder().encode(pin).write(to: metadata, options: .withoutOverwriting)
            print("synthetic-publish pid=\(getpid()) state=\(expectation)")
        } else if phase == "readback" {
            let pin = try JSONDecoder().decode(Pin.self, from: Data(contentsOf: metadata))
            XCTAssertNotEqual(pin.pid, getpid())
            XCTAssertEqual(pin.enabled, shouldEnable)
            let identity = RaycastStoreSerializedReceiptStorage.LockIdentity(device: pin.rootDevice, inode: pin.rootInode)
            let reader = try makeReader(root: profiles, owner: owner, pinned: identity, read: { api.value(account: $0) })
            let selected = try XCTUnwrap(reader.selected())
            XCTAssertEqual(selected.profileID, pin.profile)
            XCTAssertEqual(selected.scope.registryID, pin.registry)
            XCTAssertEqual(selected.scope.bindingDigest, pin.digest)
            let ownerLock = try StoreGuestCommonAuthority.ProfileOwner(
                root: URL(fileURLWithPath: selected.ownerBinding.rootPath), profileID: selected.profileID,
                expected: selected.ownerBinding)
            XCTAssertTrue(ownerLock.isCurrent())
            let runtime = RestartFakeExecution(installationID: pin.installation, commandID: pin.command)
            let (coordinator, _, anchor) = try restartCoordinator(selection: selected, owner: ownerLock, api: api,
                                                                 runtime: runtime)
            try await coordinator.verifyExistingProtectedRegistry()
            let restored = try await coordinator.installations()
            XCTAssertEqual(restored.count, 1)
            XCTAssertEqual(restored.first?.id, pin.installation)
            XCTAssertEqual(restored.first?.generation, expectedGeneration)
            XCTAssertEqual(restored.first?.enabled, shouldEnable)
            if shouldEnable {
                let values = try await coordinator.load(installationID: pin.installation, generation: expectedGeneration)
                XCTAssertEqual(values.values[pref], .string(marker))
                try await coordinator.launch(installationID: pin.installation, commandID: pin.command)
            } else {
                do {
                    try await coordinator.launch(installationID: pin.installation, commandID: pin.command)
                    XCTFail("Disabled command may not reach the fixture runtime")
                } catch { XCTAssertEqual(error as? RaycastStoreDiskRegistry.Failure, .inactive) }
            }
            let attempts = await runtime.attempts
            let output = await runtime.output
            XCTAssertEqual(attempts, shouldEnable ? 1 : 0)
            XCTAssertEqual(output, shouldEnable ? "inert-restart-accepted" : nil)
            // Disabled profiles cannot use the normal editing API. Verify the
            // exact anchored registry body instead, without re-enabling/writing.
            struct Saved: Decodable {
                struct Entry: Decodable {
                    struct Preference: Decodable {
                        let name: String
                        let value: RaycastExtensionManifest.PreferenceValue
                    }
                    let id: UUID
                    let preferences: [Preference]
                }
                let records: [Entry]
            }
            let file = URL(fileURLWithPath: selected.ownerBinding.rootPath).appendingPathComponent("registry.json")
            let bytes = try Data(contentsOf: file)
            try anchor.verify(expectedDigest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            let saved = try JSONDecoder().decode(Saved.self, from: bytes)
            let record = try XCTUnwrap(saved.records.first { $0.id == pin.installation })
            XCTAssertEqual(record.preferences.first { $0.name == "marker" }?.value, .string(marker))
            for invalid in [RestartScopeSlot.Override.absent, .corrupt] {
                let (invalidCoordinator, _, _) = try restartCoordinator(selection: selected, owner: ownerLock,
                                                                        api: api, override: invalid)
                do {
                    _ = try await invalidCoordinator.setEnabled(installationID: pin.installation, enabled: true)
                    XCTFail("An unauthenticated protected head cannot write")
                } catch {
                    guard case .protectedStateRecovery = error as? RaycastStoreDiskRegistry.Failure else {
                        return XCTFail("Expected protected rejection")
                    }
                }
            }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            let protectedAccount = pin.registry.uuidString
            for corrupt in [nil, Data([0xff])] as [Data?] {
                let negative = try makeReader(root: profiles, owner: owner, pinned: identity, read: {
                    $0 == protectedAccount ? corrupt : api.value(account: $0)
                })
                XCTAssertNil(negative.selected())
            }
            print("synthetic-readback pid=\(getpid()) state=\(expectation) fake-runtime-attempts=\(attempts)")
        } else {
            XCTFail("Unknown fixture phase")
        }
    }

    func testPublishedSlotErrorPreservesBindingAndNeverOverwrites() throws {
        let (root, backing, api) = try fixture()
        let new = namespace()
        guard case .reserved(let permit) = try backing.reserveNew(new, explicitRequest: request) else { return XCTFail() }
        let locks = try backing.stageOwnedLocks(permit)
        let finalized = try finalize(backing, permit, locks)
        let publication = try backing.receiptPublication(finalized)
        let account = finalized.namespace.scope.registryID.uuidString
        let bindingAccount = "binding:" + new.profileID.uuidString
        XCTAssertNil(api.value(account: bindingAccount))
        XCTAssertEqual(try publication.publishLock(), locks.receipt)
        let binding = try XCTUnwrap(api.value(account: bindingAccount))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(new.profileID.uuidString + "/receipt.pending.lock").path))
        let record = try initial(finalized.namespace)
        api.failAfterAdd(account: account)
        XCTAssertThrowsError(try publication.publishSlot(record, locks.receipt))
        XCTAssertEqual(api.value(account: account), record)
        XCTAssertThrowsError(try publication.publishSlot(record, locks.receipt))
        XCTAssertThrowsError(try publication.publishLock())
        XCTAssertEqual(api.value(account: bindingAccount), binding)
        XCTAssertEqual(api.value(account: account), record)
        XCTAssertEqual(api.count, 4)
    }

    func testReplacedStagedOrLiveInodeRejectsBeforeProtectedWrites() throws {
        let (root, backing, api) = try fixture()
        let new = namespace()
        guard case .reserved(let permit) = try backing.reserveNew(new, explicitRequest: request) else { return XCTFail() }
        let locks = try backing.stageOwnedLocks(permit)
        let finalized = try finalize(backing, permit, locks)
        let publication = try backing.receiptPublication(finalized)
        let profile = root.appendingPathComponent(new.profileID.uuidString)
        let staged = profile.appendingPathComponent("receipt.pending.lock")
        let moved = profile.appendingPathComponent("displaced")
        try FileManager.default.moveItem(at: staged, to: moved)
        XCTAssertTrue(FileManager.default.createFile(atPath: staged.path, contents: Data([7]), attributes: [.posixPermissions: 0o600]))
        XCTAssertThrowsError(try publication.publishLock())
        XCTAssertEqual(api.count, 2)
        try FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: moved, to: staged)
        XCTAssertEqual(try publication.publishLock(), locks.receipt)
        let live = profile.appendingPathComponent("receipt-authority.lock")
        try FileManager.default.moveItem(at: live, to: moved)
        XCTAssertTrue(FileManager.default.createFile(atPath: live.path, contents: Data([9]), attributes: [.posixPermissions: 0o600]))
        XCTAssertThrowsError(try publication.publishSlot(initial(finalized.namespace), locks.receipt))
        XCTAssertEqual(api.count, 3)
        XCTAssertEqual(try Data(contentsOf: live), Data([9]))
    }

    func testFilesystemCollisionNeverTruncatesExistingDirectory() throws {
        let (root, backing, api) = try fixture()
        let new = namespace()
        let old = root.appendingPathComponent(new.profileID.uuidString)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        let marker = old.appendingPathComponent("prior")
        try Data([7]).write(to: marker)
        guard case .collision = try backing.reserveNew(new, explicitRequest: request) else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: marker), Data([7]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: old.path), ["prior"])
        // Reservation was already protected; do not replay or clean it up.
        XCTAssertEqual(api.count, 2)
    }

    func testSubstitutedDirectoryRejectsStagingWithoutTouchingContents() throws {
        let (root, backing, _) = try fixture()
        let new = namespace()
        guard case .reserved(let permit) = try backing.reserveNew(new, explicitRequest: request) else { return XCTFail() }
        let profile = root.appendingPathComponent(new.profileID.uuidString)
        let moved = root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: profile, to: moved)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try backing.stageOwnedLocks(permit))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: profile.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }
}
