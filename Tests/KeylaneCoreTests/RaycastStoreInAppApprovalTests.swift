import CryptoKit
import Foundation
import XCTest
@testable import KeylaneCore

private final class InertConsentInsertion: @unchecked Sendable {
    private let lock = NSLock()
    private let interrupt: Bool
    private var attempts = 0
    private var protectedRows: [String: Data] = [:]

    init(interrupt: Bool = false) { self.interrupt = interrupt }

    func add(_ account: String, _ value: Data) throws -> RaycastStoreMacProfileReservation.Insert {
        try lock.withLock {
            attempts += 1
            if interrupt { throw CocoaError(.fileWriteUnknown) }
            guard protectedRows[account] == nil else { return .duplicate }
            protectedRows[account] = value
            return .inserted
        }
    }
    func read(_ account: String) -> Data? { lock.withLock { protectedRows[account] } }
    var accounts: [String] { lock.withLock { Array(protectedRows.keys) } }
    var writes: Int { lock.withLock { attempts } }
}

final class RaycastStoreInAppApprovalTests: XCTestCase {
    typealias Issuer = RaycastStoreInAppApproval
    private let scope = Issuer.Scope(owner: UUID(), intent: .createEmpty, recipeDigest: String(repeating: "a", count: 64))

    private func issuer(_ store: InertConsentInsertion, identity: Bool = true, confirmed: Bool = true) -> Issuer {
        .init(identity: { identity }, confirm: { _ in confirmed },
              sign: { Data(SHA256.hash(data: $0)) },
              verify: { Data(SHA256.hash(data: $0)) == $1 },
              insertion: { try store.add($0, $1) }, clock: { 1_000 })
    }

    @MainActor func testOnlyAffirmativeSignedAppAndExactScopeCanConsumeOnce() async throws {
        let store = InertConsentInsertion()
        XCTAssertThrowsError(try issuer(store, identity: false).issue(scope)) {
            XCTAssertEqual($0 as? Issuer.Failure, .untrustedApp)
        }
        XCTAssertThrowsError(try issuer(store, confirmed: false).issue(scope)) {
            XCTAssertEqual($0 as? Issuer.Failure, .declined)
        }
        let original = issuer(store)
        let approval = try original.issue(scope)
        let anotherRecipe = Issuer.Scope(owner: scope.owner, intent: .createEmpty, recipeDigest: String(repeating: "b", count: 64))
        let anotherOwner = Issuer.Scope(owner: UUID(), intent: .createEmpty, recipeDigest: scope.recipeDigest)
        XCTAssertNil(try original.consumeForNewEmptyProfile(approval, for: anotherRecipe))
        XCTAssertNil(try original.consumeForNewEmptyProfile(approval, for: anotherOwner))
        XCTAssertThrowsError(try issuer(store, identity: false).consumeForNewEmptyProfile(approval, for: scope))
        XCTAssertEqual(store.writes, 0)
        XCTAssertNotNil(try original.consumeForNewEmptyProfile(approval, for: scope))
        XCTAssertNil(try original.consumeForNewEmptyProfile(approval, for: scope))
        XCTAssertNil(try issuer(store).consumeForNewEmptyProfile(approval, for: scope))
        XCTAssertEqual(store.writes, 1)
    }

    @MainActor func testIndeterminateConsumeWithoutWrittenRowCannotReplayLocallyOrAfterRestart() async throws {
        let store = InertConsentInsertion(interrupt: true)
        let original = issuer(store)
        let approval = try original.issue(scope)
        XCTAssertThrowsError(try original.consumeForNewEmptyProfile(approval, for: scope)) {
            XCTAssertEqual($0 as? Issuer.Failure, .indeterminate)
        }
        XCTAssertNil(try original.consumeForNewEmptyProfile(approval, for: scope))
        XCTAssertNil(try issuer(store).consumeForNewEmptyProfile(approval, for: scope))
        XCTAssertEqual(store.writes, 1)
    }

    @MainActor func testSecondIntentRequiresIndependentKnownVacancyAndExactBinding() async throws {
        let store = InertConsentInsertion()
        let issuer = issuer(store)
        let digest = String(repeating: "d", count: 64)
        let candidate = Issuer.Scope(owner: scope.owner, intent: .activateEmpty, recipeDigest: scope.recipeDigest,
            profileID: UUID(), registryID: UUID(), bindingDigest: digest, runtimeDigest: digest, locksDigest: digest)
        let ready: @Sendable (Issuer.Scope) throws -> Issuer.ActivationAdmission = {
            $0 == candidate ? .verifiedBoundFreshProfileAndVacantSelection : .unknown
        }
        XCTAssertThrowsError(try issuer.issue(candidate)) {
            XCTAssertEqual($0 as? Issuer.Failure, .invalidApproval)
        }
        for blocked: Issuer.ActivationAdmission in [.unknown, .occupied] {
            XCTAssertThrowsError(try issuer.issueActivation(candidate, admission: { _ in blocked })) {
                XCTAssertEqual($0 as? Issuer.Failure, .activationUnavailable)
            }
        }
        let enrolled = RaycastStoreExplicitProfileActivation.Candidate(profileID: try XCTUnwrap(candidate.profileID),
            scope: .init(registryID: try XCTUnwrap(candidate.registryID), bindingDigest: digest))
        let created = try issuer.issue(scope)
        XCTAssertNil(try issuer.activationApproval(created, for: candidate, owner: candidate.owner, candidate: enrolled, admission: ready))
        let activated = try issuer.issueActivation(candidate, admission: ready)
        XCTAssertNil(try issuer.consumeForNewEmptyProfile(activated, for: scope))
        let wrongLocks = Issuer.Scope(owner: candidate.owner, intent: .activateEmpty, recipeDigest: candidate.recipeDigest,
            profileID: candidate.profileID, registryID: candidate.registryID, bindingDigest: digest, runtimeDigest: digest,
            locksDigest: String(repeating: "e", count: 64))
        XCTAssertNil(try issuer.activationApproval(activated, for: wrongLocks, owner: candidate.owner, candidate: enrolled, admission: ready))
        XCTAssertThrowsError(try issuer.activationApproval(activated, for: candidate, owner: candidate.owner, candidate: enrolled, admission: { _ in .occupied }))
        XCTAssertEqual(store.writes, 0)
        let selector = RaycastStoreExplicitProfileActivation(owner: candidate.owner, read: { store.read($0) },
            add: { try store.add($0, $1) }, authenticate: { owner, enrolled, token in
                try issuer.activationApproval(token, for: candidate, owner: owner, candidate: enrolled, admission: ready)
            }, verifyBoundEmpty: { _, _ in true })
        try selector.activate(enrolled, explicitApproval: activated)
        XCTAssertEqual(store.accounts.filter { $0.hasPrefix("activate-empty-consent:") }.count, 1)
        XCTAssertFalse(store.accounts.contains { $0.hasPrefix("empty-consent:") })
        XCTAssertThrowsError(try selector.activate(enrolled, explicitApproval: activated))
        XCTAssertEqual(store.writes, 3)
    }

}
