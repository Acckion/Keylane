import Foundation
import XCTest
@testable import KeylaneCore

private final class InertActivationItems: @unchecked Sendable {
    private var values: [String: Data] = [:]
    private var started: [String] = []
    private var consumedProof: UUID?
    private let mutex = NSLock()
    private let failAccount: String?
    private let commitBeforeThrow: Bool

    init(failAccount: String? = nil, commitBeforeThrow: Bool = false) {
        self.failAccount = failAccount
        self.commitBeforeThrow = commitBeforeThrow
    }

    func read(_ account: String) -> Data? { mutex.withLock { values[account] } }
    func seed(_ account: String, value: Data) { mutex.withLock { values[account] = value } }
    func add(_ account: String, _ bytes: Data) throws -> RaycastStoreMacProfileReservation.Insert {
        try mutex.withLock {
            started.append(account)
            guard values[account] == nil else { return .duplicate }
            if failAccount != account || commitBeforeThrow { values[account] = bytes }
            if failAccount == account { throw CocoaError(.fileWriteUnknown) }
            return .inserted
        }
    }
    func consume(_ proof: UUID) -> Bool {
        mutex.withLock {
            guard consumedProof == nil else { return false }
            consumedProof = proof
            return true
        }
    }
    var writes: [String] { mutex.withLock { started } }
}

final class RaycastStoreExplicitProfileActivationTests: XCTestCase {
    typealias Activation = RaycastStoreExplicitProfileActivation
    private let owner = UUID()
    private let proof = UUID()
    private let candidate = Activation.Candidate(profileID: UUID(),
        scope: .init(registryID: UUID(), bindingDigest: String(repeating: "a", count: 64)))
    private let approval = Data([8])
    private var pointer: String { "selected-profile:" + owner.uuidString }
    private var attempt: String { "selection-attempt:" + owner.uuidString }

    private func activation(_ items: InertActivationItems, disclosed: Bool = true, validProfile: Bool = true) -> Activation {
        let expected = candidate, expectedOwner = owner, approved = approval, proofID = proof
        return Activation(owner: owner, read: { items.read($0) }, add: { try items.add($0, $1) },
                          authenticate: { owner, candidate, approval in
            guard owner == expectedOwner, candidate == expected, approval == approved else { return nil }
            return .init(proofID: proofID, explicitlyAuthorizedEmptySelection: disclosed,
                         consume: { items.consume(proofID) })
        }, verifyBoundEmpty: { owner, candidate in
            validProfile && owner == expectedOwner && candidate == expected
        })
    }

    func testMandatoryDisclosureAndExactBindingBeforeAnyWrite() throws {
        let items = InertActivationItems()
        XCTAssertThrowsError(try activation(items, disclosed: false).activate(candidate, explicitApproval: approval)) {
            XCTAssertEqual($0 as? Activation.Failure, .approvalRejected)
        }
        XCTAssertThrowsError(try activation(items, validProfile: false).activate(candidate, explicitApproval: approval)) {
            XCTAssertEqual($0 as? Activation.Failure, .boundProfileInvalid)
        }
        XCTAssertTrue(items.writes.isEmpty)
    }

    func testOnlyCreatesOnceAndRefusesOccupiedPendingOrMalformed() throws {
        let items = InertActivationItems()
        try activation(items).activate(candidate, explicitApproval: approval)
        XCTAssertEqual(items.writes, [attempt, pointer])
        let original = try XCTUnwrap(items.read(pointer))
        XCTAssertThrowsError(try activation(items).activate(candidate, explicitApproval: approval)) {
            XCTAssertEqual($0 as? Activation.Failure, .occupied)
        }
        XCTAssertEqual(items.read(pointer), original)
        XCTAssertEqual(items.writes, [attempt, pointer])

        let pending = InertActivationItems()
        pending.seed(attempt, value: Data([1]))
        XCTAssertThrowsError(try activation(pending).activate(candidate, explicitApproval: approval)) {
            XCTAssertEqual($0 as? Activation.Failure, .recoveryRequired)
        }
        XCTAssertTrue(pending.writes.isEmpty)
        let malformed = InertActivationItems()
        malformed.seed(pointer, value: Data([2]))
        XCTAssertThrowsError(try activation(malformed).activate(candidate, explicitApproval: approval)) {
            XCTAssertEqual($0 as? Activation.Failure, .recoveryRequired)
        }
        XCTAssertTrue(malformed.writes.isEmpty)
    }

    func testIndeterminateNativeAddRetainsAttemptAndBlocksBlindRetry() throws {
        for committed in [false, true] {
            let items = InertActivationItems(failAccount: pointer, commitBeforeThrow: committed)
            XCTAssertThrowsError(try activation(items).activate(candidate, explicitApproval: approval)) {
                XCTAssertEqual($0 as? Activation.Failure, .indeterminate)
            }
            XCTAssertNotNil(items.read(attempt))
            XCTAssertEqual(items.read(pointer) != nil, committed)
            XCTAssertThrowsError(try activation(items).activate(candidate, explicitApproval: approval)) {
                XCTAssertEqual($0 as? Activation.Failure, committed ? .occupied : .recoveryRequired)
            }
            XCTAssertEqual(items.writes, [attempt, pointer])
        }
    }

    func testIndeterminateFirstAddWithNoRecordStillCannotReplayProof() throws {
        let items = InertActivationItems(failAccount: attempt, commitBeforeThrow: false)
        XCTAssertThrowsError(try activation(items).activate(candidate, explicitApproval: approval)) {
            XCTAssertEqual($0 as? Activation.Failure, .indeterminate)
        }
        XCTAssertNil(items.read(attempt))
        XCTAssertNil(items.read(pointer))
        XCTAssertThrowsError(try activation(items).activate(candidate, explicitApproval: approval)) {
            XCTAssertEqual($0 as? Activation.Failure, .approvalRejected)
        }
        XCTAssertEqual(items.writes, [attempt])
    }

}
