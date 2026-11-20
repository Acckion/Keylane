import CryptoKit
import Foundation
import XCTest
@testable import KeylaneCore

private struct InertFreshScopeVerifier: RaycastStoreFreshScopeVerifier {
    let scope: RaycastStoreReceiptEnrollment.Scope
    let approval: Data
    let proofID: UUID
    func identifiesFreshlyIssued(_ scope: RaycastStoreReceiptEnrollment.Scope) throws -> Bool { scope == self.scope }
    func authenticate(_ approval: Data, scope: RaycastStoreReceiptEnrollment.Scope) throws -> UUID? {
        scope == self.scope && approval == self.approval ? proofID : nil
    }
}

private final class InertSetupJournal: RaycastStoreEnrollmentJournal, RaycastStoreExclusiveEnrollment, @unchecked Sendable {
    typealias Scope = RaycastStoreReceiptEnrollment.Scope
    typealias State = RaycastStoreEnrollmentTransaction.State
    enum Stop: CaseIterable { case afterPending, afterLock, afterSlot, afterFinish }
    enum Interrupted: Error { case crash }
    private let mutex = NSLock()
    private let stop: Stop?
    private var status: State.Journal
    private var consumed: Set<UUID> = []
    private var lockPresent = false
    private var slot: Data?
    private var changes: [String] = []
    private let registryPresent: Bool

    init(stop: Stop? = nil, status: State.Journal = .pristine,
         registryPresent: Bool = false, previouslyConsumed: Set<UUID> = []) {
        self.stop = stop
        self.status = status
        self.registryPresent = registryPresent
        self.consumed = previouslyConsumed
    }

    func inspect(_ scope: Scope) throws -> State { try mutex.withLock { try inspect() } }
    func withExclusive<T>(_ scope: Scope, _ body: (any RaycastStoreExclusiveEnrollment) throws -> T) throws -> T {
        try mutex.withLock { try body(self) }
    }

    func inspect() throws -> State {
        .init(journal: status, registryPresent: registryPresent, lockPresent: lockPresent, slotPresent: slot != nil)
    }

    func beginConsuming(proofID: UUID) throws -> Bool {
        guard !registryPresent, !lockPresent, slot == nil, status == .pristine,
              consumed.insert(proofID).inserted else { return false }
        status = .pending
        changes.append("pending")
        if stop == .afterPending { throw Interrupted.crash }
        return true
    }

    func createOwnedLock() throws -> RaycastStoreSerializedReceiptStorage.LockIdentity {
        precondition(status == .pending && !lockPresent)
        lockPresent = true
        changes.append("lock")
        if stop == .afterLock { throw Interrupted.crash }
        return .init(device: 1, inode: 2)
    }

    func createProtectedSlot(initialRecord: Data, lock: RaycastStoreSerializedReceiptStorage.LockIdentity) throws {
        precondition(status == .pending && lockPresent && slot == nil)
        slot = initialRecord
        changes.append("slot")
        if stop == .afterSlot { throw Interrupted.crash }
    }

    func finishEnrollment(lock: RaycastStoreSerializedReceiptStorage.LockIdentity) throws {
        precondition(status == .pending && lockPresent && slot != nil)
        status = .enrolled
        changes.append("enrolled")
        if stop == .afterFinish { throw Interrupted.crash }
    }

    var recordedChanges: [String] { mutex.withLock { changes } }
}

final class RaycastStoreEnrollmentTransactionTests: XCTestCase {
    typealias Transaction = RaycastStoreEnrollmentTransaction
    typealias Scope = RaycastStoreReceiptEnrollment.Scope
    private let scope = Scope(registryID: UUID(), bindingDigest: String(repeating: "a", count: 64))
    private let approval = Data([3, 0, 4])
    private let initialRecord = Data([7])
    private let token = UUID()

    private func transaction(_ journal: InertSetupJournal) -> Transaction {
        Transaction(verifier: InertFreshScopeVerifier(scope: scope, approval: approval, proofID: token), journal: journal)
    }

    func testReadOnlyDoesNotWriteAndCommitCreatesInPendingFirstOrder() throws {
        let journal = InertSetupJournal()
        let transaction = transaction(journal)
        XCTAssertEqual(try transaction.probe(scope: scope), .independentlyVerifiedFresh)
        XCTAssertTrue(journal.recordedChanges.isEmpty)
        XCTAssertEqual(try transaction.commitFreshEnrollment(scope: scope, approval: approval, initialRecord: initialRecord), .enrolled)
        XCTAssertEqual(journal.recordedChanges, ["pending", "lock", "slot", "enrolled"])
        XCTAssertEqual(try transaction.commitFreshEnrollment(scope: scope, approval: approval, initialRecord: initialRecord), .existingInstallation)
        XCTAssertEqual(journal.recordedChanges, ["pending", "lock", "slot", "enrolled"])
    }

    func testEveryInjectedInterruptionRefusesRestartWithoutReset() throws {
        for stop in InertSetupJournal.Stop.allCases {
            let journal = InertSetupJournal(stop: stop)
            XCTAssertThrowsError(try transaction(journal).commitFreshEnrollment(scope: scope, approval: approval, initialRecord: initialRecord))
            let prior = journal.recordedChanges
            let reopened = transaction(journal)
            XCTAssertEqual(try reopened.probe(scope: scope), stop == .afterFinish ? .existingInstallation : .ambiguous)
            XCTAssertEqual(try reopened.commitFreshEnrollment(scope: scope, approval: approval, initialRecord: initialRecord),
                           stop == .afterFinish ? .existingInstallation : .ambiguous)
            XCTAssertEqual(journal.recordedChanges, prior)
        }
    }

    func testMissingHistoryOccupiedRegistryWrongScopeAndReplayedProofDoNotWrite() throws {
        let unknown = InertSetupJournal(status: .unknown)
        XCTAssertEqual(try transaction(unknown).probe(scope: scope), .ambiguous)
        XCTAssertEqual(try transaction(unknown).commitFreshEnrollment(scope: scope, approval: approval, initialRecord: initialRecord), .ambiguous)
        XCTAssertTrue(unknown.recordedChanges.isEmpty)
        let occupied = InertSetupJournal(registryPresent: true)
        XCTAssertEqual(try transaction(occupied).commitFreshEnrollment(scope: scope, approval: approval, initialRecord: initialRecord), .existingInstallation)
        XCTAssertTrue(occupied.recordedChanges.isEmpty)
        let replayed = InertSetupJournal(previouslyConsumed: [token])
        let candidate = transaction(replayed)
        let wrong = Scope(registryID: UUID(), bindingDigest: scope.bindingDigest)
        XCTAssertEqual(try candidate.probe(scope: wrong), .ambiguous)
        XCTAssertEqual(try candidate.commitFreshEnrollment(scope: wrong, approval: approval, initialRecord: initialRecord), .approvalRejected)
        XCTAssertEqual(try candidate.commitFreshEnrollment(scope: scope, approval: approval, initialRecord: initialRecord), .approvalRejected)
        XCTAssertTrue(replayed.recordedChanges.isEmpty)
    }
}

private final class InertProfileSelector: RaycastStoreProtectedReceiptStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    init(_ bytes: Data?) { self.bytes = bytes }
    func read() throws -> Data? { lock.withLock { bytes } }
    func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool {
        lock.withLock {
            guard expected != nil, bytes == expected else { return false }
            bytes = replacement
            return true
        }
    }
}

final class RaycastStoreNewProfileSetupTests: XCTestCase {
    private let owner = UUID()
    private let approval = Data([4, 2])

    private func anchor(_ selector: InertProfileSelector) throws -> RaycastStoreProtectedReceiptState {
        let generatorPoint: [UInt8] = [0x03, 0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5, 0x63, 0xa4, 0x40,
                                               0xf2, 0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96]
        return try .init(storage: selector, registryID: UUID(),
            publicKey: P256.Signing.PublicKey(compressedRepresentation: Data(generatorPoint)),
            recipe: .init(identifier: "synthetic-setup", runtimeDigest: String(repeating: "0", count: 64), qualifiedAPIVersions: []))
    }

    private func scope(_ anchor: RaycastStoreProtectedReceiptState, journal: InertSetupJournal) throws -> RaycastStoreReceiptEnrollment.Scope {
        let placeholder = RaycastStoreReceiptEnrollment.Scope(registryID: UUID(), bindingDigest: String(repeating: "1", count: 64))
        let verifier = InertFreshScopeVerifier(scope: placeholder, approval: approval, proofID: UUID())
        return try anchor.enrollment(authority: RaycastStoreEnrollmentTransaction(verifier: verifier, journal: journal)).scope
    }

    func testExplicitSetupPersistsSelectionAndCannotReplaceActiveProfile() throws {
        let selector = InertProfileSelector(try RaycastStoreNewProfileSetup.issuedVacancy(owner: owner))
        let setup = RaycastStoreNewProfileSetup(owner: owner, selector: selector)
        let journal = InertSetupJournal()
        let anchor = try anchor(selector)
        let scope = try scope(anchor, journal: journal)
        let verifier = InertFreshScopeVerifier(scope: scope, approval: approval, proofID: UUID())
        XCTAssertEqual(setup.selection(journal: journal), .noProfile)
        XCTAssertThrowsError(try setup.enrollExplicitly(anchor, approval: Data([0]), verifier: verifier, journal: journal))
        XCTAssertEqual(setup.selection(journal: journal), .noProfile)
        try setup.enrollExplicitly(anchor, approval: approval, verifier: verifier, journal: journal)
        let restarted = RaycastStoreNewProfileSetup(owner: owner, selector: selector)
        XCTAssertEqual(restarted.selection(journal: journal), .active(scope))
        // A different journal with no witnessed receipt footmarks is never accepted.
        XCTAssertEqual(restarted.selection(journal: InertSetupJournal()), .recoveryRequired)
        let active = try selector.read()
        XCTAssertThrowsError(try restarted.enrollExplicitly(anchor, approval: approval, verifier: verifier, journal: journal)) {
            XCTAssertEqual($0 as? RaycastStoreNewProfileSetup.Failure, .existingProfile)
        }
        XCTAssertEqual(try selector.read(), active)
    }

    func testPendingOrMissingSelectorNeverAdoptsReceiptOnRestart() throws {
        let selector = InertProfileSelector(try RaycastStoreNewProfileSetup.issuedVacancy(owner: owner))
        let setup = RaycastStoreNewProfileSetup(owner: owner, selector: selector)
        let journal = InertSetupJournal(stop: .afterFinish)
        let anchor = try anchor(selector)
        let scope = try scope(anchor, journal: journal)
        let verifier = InertFreshScopeVerifier(scope: scope, approval: approval, proofID: UUID())
        XCTAssertThrowsError(try setup.enrollExplicitly(anchor, approval: approval, verifier: verifier, journal: journal))
        let reserved = try selector.read()
        let restarted = RaycastStoreNewProfileSetup(owner: owner, selector: selector)
        XCTAssertEqual(restarted.selection(journal: journal), .recoveryRequired)
        XCTAssertThrowsError(try restarted.enrollExplicitly(anchor, approval: approval, verifier: verifier, journal: journal))
        XCTAssertEqual(try selector.read(), reserved)
        let lost = InertProfileSelector(nil)
        let missing = RaycastStoreNewProfileSetup(owner: owner, selector: lost)
        XCTAssertEqual(missing.selection(journal: journal), .recoveryRequired)
        XCTAssertThrowsError(try missing.enrollExplicitly(anchor, approval: approval, verifier: verifier, journal: journal))
        XCTAssertNil(try lost.read())
    }
}

private final class InertNamespaceIssuer: RaycastStoreEmptyProfileBootstrap.Storage, @unchecked Sendable {
    typealias Bootstrap = RaycastStoreEmptyProfileBootstrap
    private let mutex = NSLock()
    private let journal = InertSetupJournal()
    private let outcome: Bootstrap.Reservation
    private let interrupted: Bool
    private var bound: Bootstrap.Allocation?
    private var steps: [String] = []
    private let oldSelection: InertProfileSelector

    init(outcome: Bootstrap.Reservation = .reserved, interrupted: Bool = false, oldSelection: InertProfileSelector) {
        self.outcome = outcome
        self.interrupted = interrupted
        self.oldSelection = oldSelection
    }

    func reserveNew(_ namespace: Bootstrap.Allocation, explicitRequest: Data) throws -> Bootstrap.Reservation {
        mutex.withLock {
            steps.append("reserve")
            guard explicitRequest == Data([9]) else { return .denied }
            guard bound == nil else { return .collision }
            if outcome == .reserved { bound = namespace }
            return outcome
        }
    }

    func stageOwnedLocks(_ namespace: Bootstrap.Allocation) throws -> RaycastStoreProtectedReceiptState.OwnerBinding {
        try mutex.withLock {
            precondition(bound == namespace)
            steps.append("owned-locks-staged")
            if interrupted { throw CocoaError(.fileWriteUnknown) }
            return .init(profileID: namespace.profileID, rootPath: "/inert/" + namespace.profileID.uuidString,
                         rootDevice: 1, rootInode: 2, lockDevice: 1, lockInode: 3)
        }
    }

    func prepareEnrollment(_ namespace: Bootstrap.Namespace) throws -> Bootstrap.EnrollmentInputs {
        mutex.withLock {
            precondition(bound?.profileID == namespace.profileID && bound?.registryID == namespace.scope.registryID)
            steps.append("new-profile-enrollment")
            let approval = Data([4])
            return .init(verifier: InertFreshScopeVerifier(scope: namespace.scope, approval: approval, proofID: UUID()),
                         journal: journal, approval: approval)
        }
    }

    func finishUnselected(_ namespace: Bootstrap.Namespace) throws {
        mutex.withLock {
            precondition(bound?.profileID == namespace.profileID && bound?.registryID == namespace.scope.registryID)
            precondition(journal.recordedChanges == ["pending", "lock", "slot", "enrolled"])
            steps.append("unselected")
        }
    }

    var events: [String] { mutex.withLock { steps } }
    var selection: Data? { try? oldSelection.read() }
}

final class RaycastStoreEmptyProfileBootstrapTests: XCTestCase {
    typealias Bootstrap = RaycastStoreEmptyProfileBootstrap
    private let recipe = RaycastStoreArtifactSeal.Recipe(
        identifier: "synthetic-empty", runtimeDigest: String(repeating: "0", count: 64), qualifiedAPIVersions: [])

    private func key() throws -> P256.Signing.PublicKey {
        try .init(compressedRepresentation: Data([0x03, 0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5,
            0x63, 0xa4, 0x40, 0xf2, 0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96]))
    }

    func testNewNamespaceIsUnselectedWithOrWithoutOldSelection() throws {
        let existing = InertProfileSelector(Data([7]))
        let missing = InertProfileSelector(nil)
        let a = InertNamespaceIssuer(oldSelection: existing), b = InertNamespaceIssuer(oldSelection: missing)
        let first = try Bootstrap(storage: a).createUnselected(explicitRequest: Data([9]), publicKey: key(), recipe: recipe)
        let second = try Bootstrap(storage: b).createUnselected(explicitRequest: Data([9]), publicKey: key(), recipe: recipe)
        XCTAssertTrue(first.requiresSeparateActivation)
        XCTAssertTrue(second.requiresSeparateActivation)
        XCTAssertNotEqual(first.namespace.profileID, second.namespace.profileID)
        XCTAssertNotEqual(first.namespace.scope.registryID, second.namespace.scope.registryID)
        XCTAssertNotEqual(first.namespace.scope.bindingDigest, second.namespace.scope.bindingDigest)
        XCTAssertEqual(a.events, ["reserve", "owned-locks-staged", "new-profile-enrollment", "unselected"])
        XCTAssertEqual(a.selection, Data([7]))
        XCTAssertNil(b.selection)
    }

    func testCollisionAndInterruptedPrepareNeverAdoptOrRetry() throws {
        let existing = InertProfileSelector(Data([7]))
        let collided = InertNamespaceIssuer(outcome: .collision, oldSelection: existing)
        XCTAssertThrowsError(try Bootstrap(storage: collided).createUnselected(explicitRequest: Data([9]), publicKey: key(), recipe: recipe)) {
            XCTAssertEqual($0 as? Bootstrap.Failure, .collision)
        }
        XCTAssertEqual(collided.events, ["reserve"])
        let interrupted = InertNamespaceIssuer(interrupted: true, oldSelection: existing)
        XCTAssertThrowsError(try Bootstrap(storage: interrupted).createUnselected(explicitRequest: Data([9]), publicKey: key(), recipe: recipe)) {
            XCTAssertEqual($0 as? Bootstrap.Failure, .recoveryRequired)
        }
        XCTAssertEqual(interrupted.events, ["reserve", "owned-locks-staged"])
        XCTAssertEqual(interrupted.selection, Data([7]))
    }
}
