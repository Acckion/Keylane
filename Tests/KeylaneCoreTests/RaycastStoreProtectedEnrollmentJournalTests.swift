import Darwin
import Foundation
import XCTest
@testable import KeylaneCore

private final class InertJournalSlot: RaycastStoreProtectedReceiptSlot, @unchecked Sendable {
    private let mutex = NSLock()
    private var value: Data?
    init(_ value: Data?) { self.value = value }
    func readExisting() throws -> Data? { mutex.withLock { value } }
    func replaceExisting(with bytes: Data) throws { mutex.withLock { value = bytes } }
}

private final class JournalSyntheticFootprint: @unchecked Sendable {
    let lock = RaycastStoreSerializedReceiptStorage.LockIdentity(device: 3, inode: 7)
    private let mutex = NSLock()
    private var hasLock = false
    private var slot: Data?
    private let interrupt: Bool
    init(interrupt: Bool) { self.interrupt = interrupt }
    func inspect() -> RaycastStoreProtectedEnrollmentJournal.Footprint {
        mutex.withLock { .init(registryPresent: false, lockPresent: hasLock, slotPresent: slot != nil) }
    }
    func createLock() throws -> RaycastStoreSerializedReceiptStorage.LockIdentity {
        try mutex.withLock {
            guard !hasLock else { throw CocoaError(.fileWriteFileExists) }
            hasLock = true
            return lock
        }
    }
    func createSlot(_ bytes: Data, _ actualLock: RaycastStoreSerializedReceiptStorage.LockIdentity) throws {
        try mutex.withLock {
            guard hasLock, actualLock == lock, slot == nil else { throw CocoaError(.fileWriteFileExists) }
            slot = bytes
            if interrupt { throw CocoaError(.fileWriteUnknown) }
        }
    }
    func verified(_ actualLock: RaycastStoreSerializedReceiptStorage.LockIdentity) -> Bool {
        mutex.withLock { hasLock && slot != nil && actualLock == lock }
    }
}

private struct JournalTestVerifier: RaycastStoreFreshScopeVerifier {
    let expected: RaycastStoreReceiptEnrollment.Scope
    func identifiesFreshlyIssued(_ scope: RaycastStoreReceiptEnrollment.Scope) throws -> Bool { scope == expected }
    func authenticate(_ approval: Data, scope: RaycastStoreReceiptEnrollment.Scope) throws -> UUID? {
        guard scope == expected, approval == Data([3]) else { return nil }
        return UUID(uuidString: "00000000-0000-0000-0000-000000000123")
    }
}

final class RaycastStoreProtectedEnrollmentJournalTests: XCTestCase {
    typealias Journal = RaycastStoreProtectedEnrollmentJournal
    private let scope = RaycastStoreReceiptEnrollment.Scope(registryID: UUID(), bindingDigest: String(repeating: "a", count: 64))

    private func store(_ slot: InertJournalSlot) throws -> RaycastStoreSerializedReceiptStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("receipt-authority.lock").path
        guard FileManager.default.createFile(atPath: lock, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        var info = stat()
        guard lstat(lock, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return .init(directory: directory, lockIdentity: .init(device: info.st_dev, inode: info.st_ino), slot: slot)
    }

    private func journal(_ slot: RaycastStoreSerializedReceiptStorage, gate: RaycastStoreSerializedReceiptStorage,
                         footprint: JournalSyntheticFootprint) -> Journal {
        .init(scope: scope, storage: slot, transactionGate: gate, footprint: { footprint.inspect() },
              createLock: { try footprint.createLock() }, createSlot: { try footprint.createSlot($0, $1) },
              verifyBinding: { footprint.verified($0) })
    }

    func testProtectedPendingSurvivesSplitStateAndRejectsRestart() throws {
        let slot = InertJournalSlot(try Journal.pristineRecord(for: scope))
        let storage = try store(slot), gate = try store(InertJournalSlot(nil))
        let effects = JournalSyntheticFootprint(interrupt: true)
        let verifier = JournalTestVerifier(expected: scope)
        let first = RaycastStoreEnrollmentTransaction(verifier: verifier, journal: journal(storage, gate: gate, footprint: effects))
        XCTAssertThrowsError(try first.commitFreshEnrollment(scope: scope, approval: Data([3]), initialRecord: Data([8])))
        let after = try XCTUnwrap(slot.readExisting())
        XCTAssertTrue(String(decoding: after, as: UTF8.self).contains("pending"))
        XCTAssertTrue(effects.inspect().slotPresent)
        let reopened = RaycastStoreEnrollmentTransaction(verifier: verifier, journal: journal(storage, gate: gate, footprint: effects))
        XCTAssertEqual(try reopened.probe(scope: scope), .ambiguous)
        XCTAssertEqual(try reopened.commitFreshEnrollment(scope: scope, approval: Data([3]), initialRecord: Data([9])), .ambiguous)
        XCTAssertEqual(try slot.readExisting(), after)
    }

    func testEnrollmentIsSingleWinnerAndMissingJournalOrSameLockFailsClosed() async throws {
        let slot = InertJournalSlot(try Journal.pristineRecord(for: scope))
        let storage = try store(slot), gate = try store(InertJournalSlot(nil))
        let effects = JournalSyntheticFootprint(interrupt: false)
        let verifier = JournalTestVerifier(expected: scope)
        let first = RaycastStoreEnrollmentTransaction(verifier: verifier, journal: journal(storage, gate: gate, footprint: effects))
        let second = RaycastStoreEnrollmentTransaction(verifier: verifier, journal: journal(storage, gate: gate, footprint: effects))
        let currentScope = scope
        async let a = first.commitFreshEnrollment(scope: currentScope, approval: Data([3]), initialRecord: Data([8]))
        async let b = second.commitFreshEnrollment(scope: currentScope, approval: Data([3]), initialRecord: Data([8]))
        let results = try await [a, b]
        XCTAssertEqual(results.filter { $0 == .enrolled }.count, 1)
        XCTAssertEqual(results.filter { $0 == .existingInstallation }.count, 1)
        let missing = try store(InertJournalSlot(nil))
        XCTAssertThrowsError(try journal(missing, gate: gate, footprint: effects).inspect(scope))
        XCTAssertThrowsError(try journal(storage, gate: storage, footprint: effects).inspect(scope))
    }
}
