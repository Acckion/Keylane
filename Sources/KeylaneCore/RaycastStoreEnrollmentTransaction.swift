import Foundation

/// The platform adapter authenticates an app-signed, one-use proof for this
/// exact scope and confirms independently issued first-use status. It must
/// not inspect the absence of registry, lock or credential files as evidence.
package protocol RaycastStoreFreshScopeVerifier: Sendable {
    func identifiesFreshlyIssued(_ scope: RaycastStoreReceiptEnrollment.Scope) throws -> Bool
    func authenticate(_ approval: Data, scope: RaycastStoreReceiptEnrollment.Scope) throws -> UUID?
}

/// A native implementation must serialize across processes, return only
/// verified state (never normalize missing history to .pristine), and make
/// each journal write durable before returning. On uncertainty it must throw.
package protocol RaycastStoreEnrollmentJournal: Sendable {
    func inspect(_ scope: RaycastStoreReceiptEnrollment.Scope) throws -> RaycastStoreEnrollmentTransaction.State
    func withExclusive<T>(_ scope: RaycastStoreReceiptEnrollment.Scope,
                          _ body: (any RaycastStoreExclusiveEnrollment) throws -> T) throws -> T
}

package protocol RaycastStoreExclusiveEnrollment {
    func inspect() throws -> RaycastStoreEnrollmentTransaction.State
    /// Durably record .pending and consume the verified proof ID atomically.
    /// Return false for a replay or if pristine/empty state no longer holds.
    func beginConsuming(proofID: UUID) throws -> Bool
    /// These are exclusive create-only operations, not overwrite or adoption.
    func createOwnedLock() throws -> RaycastStoreSerializedReceiptStorage.LockIdentity
    func createProtectedSlot(initialRecord: Data, lock: RaycastStoreSerializedReceiptStorage.LockIdentity) throws
    /// Seal the enrolled binding after revalidating the new protected slot/lock.
    func finishEnrollment(lock: RaycastStoreSerializedReceiptStorage.LockIdentity) throws
}

/// Coordinates explicitly authorized creation without turning an interruption
/// into an implicit repair operation. No credential, filesystem, or key API
/// is called here, and no default Store backend installs this coordinator.
package struct RaycastStoreEnrollmentTransaction: RaycastStoreFreshProfileEnrollmentAuthority {
    package struct State: Sendable {
        package enum Journal: Sendable { case pristine, pending, enrolled, unknown }
        package let journal: Journal
        package let registryPresent: Bool
        package let lockPresent: Bool
        package let slotPresent: Bool

        package init(journal: Journal, registryPresent: Bool, lockPresent: Bool, slotPresent: Bool) {
            self.journal = journal
            self.registryPresent = registryPresent
            self.lockPresent = lockPresent
            self.slotPresent = slotPresent
        }

        fileprivate var disposition: RaycastStoreReceiptEnrollment.Observation {
            switch journal {
            case .pending, .unknown: return .ambiguous
            case .enrolled: return .existingInstallation
            case .pristine:
                if registryPresent { return .existingInstallation }
                return lockPresent || slotPresent ? .ambiguous : .independentlyVerifiedFresh
            }
        }
    }

    private let verifier: any RaycastStoreFreshScopeVerifier
    private let journal: any RaycastStoreEnrollmentJournal

    package init(verifier: any RaycastStoreFreshScopeVerifier, journal: any RaycastStoreEnrollmentJournal) {
        self.verifier = verifier
        self.journal = journal
    }

    package func probe(scope: RaycastStoreReceiptEnrollment.Scope) throws -> RaycastStoreReceiptEnrollment.Observation {
        let observed = try journal.inspect(scope).disposition
        guard observed == .independentlyVerifiedFresh else { return observed }
        return try verifier.identifiesFreshlyIssued(scope) ? observed : .ambiguous
    }

    package func commitFreshEnrollment(scope: RaycastStoreReceiptEnrollment.Scope, approval: Data, initialRecord: Data) throws
        -> RaycastStoreReceiptEnrollment.CommitResult {
        guard !approval.isEmpty, approval.count <= 1_024, !initialRecord.isEmpty, initialRecord.count <= 1_024 else {
            return .approvalRejected
        }
        return try journal.withExclusive(scope) { transaction in
            switch try transaction.inspect().disposition {
            case .existingInstallation: return .existingInstallation
            case .ambiguous: return .ambiguous
            case .independentlyVerifiedFresh: break
            }
            guard try verifier.identifiesFreshlyIssued(scope),
                  let proofID = try verifier.authenticate(approval, scope: scope),
                  try transaction.beginConsuming(proofID: proofID) else { return .approvalRejected }
            // Any failure leaves the pending journal and consumed proof intact.
            // Neither this transaction nor its caller deletes or resumes it.
            let lock = try transaction.createOwnedLock()
            try transaction.createProtectedSlot(initialRecord: initialRecord, lock: lock)
            try transaction.finishEnrollment(lock: lock)
            return .enrolled
        }
    }
}
