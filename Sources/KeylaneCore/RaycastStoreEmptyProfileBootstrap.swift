import CryptoKit
import Foundation

/// Builds only a new, unselected profile. This type has no selector handle
/// and cannot infer first use, recover an old scope, or activate a profile.
package struct RaycastStoreEmptyProfileBootstrap: Sendable {
    /// Allocated request identity only. This is never an enrollment scope.
    package struct Allocation: Equatable, Sendable {
        package let profileID: UUID
        package let registryID: UUID
    }

    package struct Namespace: Equatable, Sendable {
        package let profileID: UUID
        package let scope: RaycastStoreReceiptEnrollment.Scope
    }

    package enum Reservation: Equatable, Sendable { case reserved, denied, collision }

    package enum Failure: Error, Equatable, Sendable {
        case approvalRejected, collision, recoveryRequired
    }

    package struct UnselectedProfile: Equatable, Sendable {
        package let namespace: Namespace
        package let ownerBinding: RaycastStoreProtectedReceiptState.OwnerBinding
        package let requiresSeparateActivation = true
    }

    /// App-signed native composition must authenticate/consume the explicit
    /// request and create an immutable pending namespace exclusively, or
    /// return denied/collision without touching anything. No read, enumeration,
    /// deletion or reopen of prior namespaces belongs to this interface.
    package protocol Storage: Sendable {
        func reserveNew(_ allocation: Allocation, explicitRequest: Data) throws -> Reservation
        /// Precreate owner, journal and receipt lock inodes exclusively in
        /// this pending namespace. Keep the receipt lock staged and absent
        /// from the live footprint until existing enrollment publishes it
        /// through its create-only receipt-lock step, after journal pending.
        func stageOwnedLocks(_ allocation: Allocation) throws -> RaycastStoreProtectedReceiptState.OwnerBinding
        func prepareEnrollment(_ namespace: Namespace) throws -> EnrollmentInputs
        /// Seal the completed profile as unselected. Must verify full binding,
        /// exact lock/slot/journal scope, and the prior immutable pending record.
        func finishUnselected(_ namespace: Namespace) throws
    }

    package struct EnrollmentInputs: Sendable {
        package let verifier: any RaycastStoreFreshScopeVerifier
        package let journal: any RaycastStoreEnrollmentJournal
        package let approval: Data

        package init(verifier: any RaycastStoreFreshScopeVerifier, journal: any RaycastStoreEnrollmentJournal, approval: Data) {
            self.verifier = verifier
            self.journal = journal
            self.approval = approval
        }
    }

    private let storage: any Storage

    package init(storage: any Storage) { self.storage = storage }

    package func createUnselected(explicitRequest: Data, publicKey: P256.Signing.PublicKey,
                                  recipe: RaycastStoreArtifactSeal.Recipe) throws -> UnselectedProfile {
        guard !explicitRequest.isEmpty, explicitRequest.count <= 1_024 else { throw Failure.approvalRejected }
        let allocation = Allocation(profileID: UUID(), registryID: UUID())
        let reservation: Reservation
        do { reservation = try storage.reserveNew(allocation, explicitRequest: explicitRequest) }
        catch { throw Failure.recoveryRequired }
        switch reservation {
        case .denied: throw Failure.approvalRejected
        case .collision: throw Failure.collision
        case .reserved: break
        }
        do {
            let owner = try storage.stageOwnedLocks(allocation)
            guard owner.profileID == allocation.profileID, owner.rootInode > 0, owner.lockInode > 0,
                  URL(fileURLWithPath: owner.rootPath).lastPathComponent == allocation.profileID.uuidString else {
                throw Failure.recoveryRequired
            }
            let anchor = try RaycastStoreProtectedReceiptState(storage: InaccessibleReceiptStore(),
                registryID: allocation.registryID, publicKey: publicKey, recipe: recipe, owner: owner)
            let scope = anchor.enrollmentScope
            let namespace = Namespace(profileID: allocation.profileID, scope: scope)
            let inputs = try storage.prepareEnrollment(namespace)
            let transaction = RaycastStoreEnrollmentTransaction(verifier: inputs.verifier, journal: inputs.journal)
            let setup = try anchor.enrollment(authority: transaction)
            try setup.enrollNewProfile(approval: inputs.approval)
            let observed = try inputs.journal.inspect(scope)
            guard observed.journal == .enrolled, !observed.registryPresent, observed.lockPresent, observed.slotPresent else {
                throw Failure.recoveryRequired
            }
            try storage.finishUnselected(namespace)
            return .init(namespace: namespace, ownerBinding: owner)
        } catch {
            // No reset, cleanup, or retry if any create may have taken effect.
            throw Failure.recoveryRequired
        }
    }

    /// The anchor above encodes the initial record; it does not get any live
    /// slot or authorize recovery through this dependency.
    private struct InaccessibleReceiptStore: RaycastStoreProtectedReceiptStorage {
        func read() throws -> Data? { throw Failure.recoveryRequired }
        func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool { throw Failure.recoveryRequired }
    }
}
