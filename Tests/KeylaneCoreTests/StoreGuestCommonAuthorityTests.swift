import Darwin
import Foundation
import XCTest
@testable import KeylaneCore

final class StoreGuestCommonAuthorityTests: XCTestCase {
    @MainActor private final class Transport: StoreGuestTicketHost.Process {
        let id: UUID
        var effect: (@MainActor (String, String) throws -> String)?
        var release: CheckedContinuation<Void, Never>?
        private(set) var associations: [UUID] = []
        var acknowledge = false
        init(_ id: UUID) { self.id = id }
        func run(effect: @escaping @MainActor (String, String) throws -> String) async throws -> StoreGuestTicketHost.ExitEvidence {
            self.effect = effect
            await withCheckedContinuation { release = $0 }
            return .init(ticketID: id, authenticatedCompletion: true, helperExited: true)
        }
        func finish() { release?.resume(); release = nil }
        func prepareStop(_ request: StoreGuestTicketHost.Revocation) { associations.append(request.id) }
        func stop(_ request: StoreGuestTicketHost.Revocation, deadline: ContinuousClock.Instant) async throws -> StoreGuestTicketHost.StopEvidence {
            XCTAssertThrowsError(try effect?("feedback.toast", "too late"))
            if acknowledge { finish() }
            return .init(ticketID: id, revocationID: request.id, acknowledged: acknowledge, helperExited: acknowledge)
        }
    }

    func testPinnedOwnerRejectsSecondOwnerAndPrivateReplacements() throws {
        let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("store-authority.lock")
        func makeLock() throws {
            let fd = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            close(fd)
        }
        try makeLock()
        var dirInfo = stat(), fileInfo = stat()
        XCTAssertEqual(lstat(root.path, &dirInfo), 0)
        XCTAssertEqual(lstat(file.path, &fileInfo), 0)
        let profile = UUID()
        let binding = RaycastStoreProtectedReceiptState.OwnerBinding(
            profileID: profile, rootPath: root.path, rootDevice: Int64(dirInfo.st_dev), rootInode: UInt64(dirInfo.st_ino),
            lockDevice: Int64(fileInfo.st_dev), lockInode: UInt64(fileInfo.st_ino)
        )
        typealias Owner = StoreGuestCommonAuthority.ProfileOwner
        XCTAssertThrowsError(try Owner(root: root, profileID: UUID(), expected: binding))
        let owner = try Owner(root: root, profileID: profile, expected: binding)
        XCTAssertTrue(owner.isCurrent())
        XCTAssertThrowsError(try Owner(root: root, profileID: profile, expected: binding))
        let movedLock = root.appendingPathComponent("held-original")
        try FileManager.default.moveItem(at: file, to: movedLock)
        try makeLock()
        XCTAssertFalse(owner.isCurrent())
        XCTAssertThrowsError(try Owner(root: root, profileID: profile, expected: binding))

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: movedLock, to: file)
        XCTAssertFalse(owner.isCurrent(), "Continuity loss cannot be cleared by restoring the pathname")
        let movedRoot = scratch.appendingPathComponent("held-root")
        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try makeLock()
        XCTAssertFalse(owner.isCurrent())
        XCTAssertThrowsError(try Owner(root: root, profileID: profile, expected: binding))
    }

    @MainActor
    func testConcreteCommonAuthorityDeniesTamperingAndRetryUsesSameAuthenticatedRevocation() async throws {
        let profile = UUID(), installationID = UUID()
        let installation = StoreRuntimeBridge.Installation(id: installationID.uuidString, generation: 1)
        let digest = String(repeating: "a", count: 64)
        let receipt = StoreRuntimeBridge.Receipt(provenance: .init(installation: .init(id: installation.id, generation: 0),
            entry: "src/test.ts", projectDigest: digest, runtimeDigest: digest), artifactDigest: digest)
        let authority = try StoreGuestCommonAuthority(profileID: profile, grants: ["feedback.toast"])
        func request(_ generation: UInt64) -> RaycastStoreSignedInstallationService.Admission {
            .init(profileID: profile, commandID: "real", installation: .init(id: installation.id, generation: generation),
                  artifact: receipt, capabilities: ["feedback.toast"], launchContext: .init())
        }
        let admission = request(1)
        let lease = try authority.admit(admission)
        let transport = Transport(admission.launchID)
        var effects = 0, starts = 0
        let host = StoreGuestTicketHost(authority: authority, spawn: { _, _, _ in starts += 1; return transport },
                                       sink: { _, _, text in effects += 1; return text })
        try authority.bind(host)
        XCTAssertThrowsError(try authority.bind(host))
        let resources = StoreSignedGuestEngine.Resources(kernelURL: URL(fileURLWithPath: "/inert/one"),
            ramdiskURL: URL(fileURLWithPath: "/inert/two"), digest: digest, recipeIdentifier: "test")
        func ticket(command: String) -> StoreGuestRunTicket {
            .init(id: admission.launchID, profileID: profile, installation: installation, receipt: receipt, commandID: command,
                  capabilities: ["feedback.toast"], launchContext: .init(), liveLease: lease.isCurrent)
        }
        do { try await host.run(resources: resources, artifact: Data(), ticket: ticket(command: "wrong")); XCTFail() }
        catch { XCTAssertEqual(error as? StoreGuestCommonAuthority.Failure, .denied) }
        XCTAssertEqual(starts, 0)
        let task = Task { try await host.run(resources: resources, artifact: Data(), ticket: ticket(command: "real")) }
        defer { transport.finish(); task.cancel() }
        for _ in 0..<200 where transport.effect == nil { try await Task.sleep(for: .milliseconds(2)) }
        let effect = try XCTUnwrap(transport.effect)
        XCTAssertEqual(try effect("feedback.toast", "first"), "first")
        XCTAssertEqual(starts, 1)
        try authority.quarantine(profileID: profile, installationID: installationID, before: 2)
        XCTAssertFalse(lease.isCurrent())
        XCTAssertThrowsError(try effect("feedback.toast", "during quarantine"))
        XCTAssertFalse(try authority.permits(request(2)))
        let fake = StoreGuestTicketHost.Revocation(id: UUID(), profileID: profile, installationID: installation.id, beforeGeneration: 2)
        do { try await host.revoke(fake, timeout: .seconds(1)); XCTFail() }
        catch { XCTAssertEqual(error as? StoreGuestCommonAuthority.Failure, .denied) }
        XCTAssertTrue(transport.associations.isEmpty)

        do { try await authority.revoke(profileID: profile, installationID: installationID, before: 2); XCTFail() }
        catch { XCTAssertEqual(error as? StoreGuestTicketHost.Failure, .stopUnconfirmed) }
        XCTAssertFalse(try authority.permits(request(2)))
        try authority.quarantine(profileID: profile, installationID: installationID, before: 3)
        transport.acknowledge = true
        try await authority.revoke(profileID: profile, installationID: installationID, before: 3)
        try await task.value
        XCTAssertEqual(transport.associations.count, 2)
        XCTAssertEqual(Set(transport.associations).count, 1)
        XCTAssertFalse(try authority.permits(request(2)))
        XCTAssertTrue(try authority.permits(request(3)))
        XCTAssertEqual(effects, 1)
    }
}
