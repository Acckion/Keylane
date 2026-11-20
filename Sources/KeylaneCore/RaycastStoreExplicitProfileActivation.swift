import Foundation
import Security

/// Second explicit action: publish exactly one previously enrolled, unselected
/// empty profile. No method switches, overwrites, repairs, or deletes selection.
package struct RaycastStoreExplicitProfileActivation: Sendable {
    package struct Candidate: Equatable, Sendable {
        package let profileID: UUID
        package let scope: RaycastStoreReceiptEnrollment.Scope

        package init(profileID: UUID, scope: RaycastStoreReceiptEnrollment.Scope) {
            self.profileID = profileID
            self.scope = scope
        }
    }

    package enum Failure: Error, Equatable, Sendable {
        case approvalRejected, boundProfileInvalid, occupied, recoveryRequired, indeterminate
    }

    package struct Approval: Sendable {
        package let proofID: UUID
        /// User saw that an old profile will not be recovered; independent app
        /// trust authorized this selector scope, not merely a missing query.
        package let explicitlyAuthorizedEmptySelection: Bool
        /// The independent issuer consumes this proof durably after preflight
        /// and before any uncertain local mutation. It must never replay across
        /// processes, including when the first local Add definitely did not land.
        fileprivate let consume: @Sendable () throws -> Bool

        package init(proofID: UUID, explicitlyAuthorizedEmptySelection: Bool,
                     consume: @escaping @Sendable () throws -> Bool) {
            self.proofID = proofID
            self.explicitlyAuthorizedEmptySelection = explicitlyAuthorizedEmptySelection
            self.consume = consume
        }
    }

    private struct Record: Codable {
        let version: Int
        let owner: UUID
        let profileID: UUID
        let registryID: UUID
        let binding: String
        let proofID: UUID
    }

    private let owner: UUID
    private let read: @Sendable (String) throws -> Data?
    private let add: @Sendable (String, Data) throws -> RaycastStoreMacProfileReservation.Insert
    private let authenticate: @Sendable (UUID, Candidate, Data) throws -> Approval?
    private let verifyBoundEmpty: @Sendable (UUID, Candidate) throws -> Bool

    /// Authenticate must verify a separately signed, unexpired activation
    /// approval bound to owner, exact candidate, and explicit no-recovery
    /// disclosure. verifyBoundEmpty must read the exact immutable journal and
    /// signer/recipe/receipt/owner-lock bindings, and cannot write.
    package init(owner: UUID,
                 read: @escaping @Sendable (String) throws -> Data?,
                 add: @escaping @Sendable (String, Data) throws -> RaycastStoreMacProfileReservation.Insert,
                 authenticate: @escaping @Sendable (UUID, Candidate, Data) throws -> Approval?,
                 verifyBoundEmpty: @escaping @Sendable (UUID, Candidate) throws -> Bool) {
        self.owner = owner
        self.read = read
        self.add = add
        self.authenticate = authenticate
        self.verifyBoundEmpty = verifyBoundEmpty
    }

    /// Native factory: no platform API is called during construction.
    package init(owner: UUID, accessGroup: String, service: String,
                 authenticate: @escaping @Sendable (UUID, Candidate, Data) throws -> Approval?,
                 verifyBoundEmpty: @escaping @Sendable (UUID, Candidate) throws -> Bool) {
        self.init(owner: owner, read: { account in
            var query = try Self.query(account, accessGroup: accessGroup, service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let bytes = result as? Data else { throw Failure.recoveryRequired }
            return bytes
        }, add: { account, bytes in
            var query = try Self.query(account, accessGroup: accessGroup, service: service)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecValueData as String] = bytes
            switch SecItemAdd(query as CFDictionary, nil) {
            case errSecSuccess: return .inserted
            case errSecDuplicateItem: return .duplicate
            default: throw Failure.indeterminate
            }
        }, authenticate: authenticate, verifyBoundEmpty: verifyBoundEmpty)
    }

    private var pointer: String { "selected-profile:" + owner.uuidString }
    private var attempt: String { "selection-attempt:" + owner.uuidString }

    package func activate(_ candidate: Candidate, explicitApproval: Data) throws {
        guard !explicitApproval.isEmpty, explicitApproval.count <= 1_024,
              let grant = try authenticate(owner, candidate, explicitApproval),
              grant.explicitlyAuthorizedEmptySelection else { throw Failure.approvalRejected }
        try checkVacant()
        guard candidate.scope.bindingDigest.utf8.count == 64,
              candidate.scope.bindingDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              try verifyBoundEmpty(owner, candidate) else { throw Failure.boundProfileInvalid }
        let record = try JSONEncoder().encode(Record(version: 1, owner: owner, profileID: candidate.profileID,
                                                     registryID: candidate.scope.registryID,
                                                     binding: candidate.scope.bindingDigest, proofID: grant.proofID))
        let consumed: Bool
        do { consumed = try grant.consume() }
        catch { throw Failure.indeterminate }
        guard consumed else { throw Failure.approvalRejected }
        // Independent no-recovery approval is required even when both queries
        // are absent. The immutable owner-scoped attempt fences duplicates,
        // including after a crash/indeterminate native add.
        do {
            guard try add(attempt, record) == .inserted else { throw Failure.recoveryRequired }
        } catch let error as Failure where error == .recoveryRequired {
            throw error
        } catch {
            throw Failure.indeterminate
        }
        do {
            // Recheck the same validated scope while the sole create attempt is
            // reserved. Any split state stays reserved and is not cleaned up.
            guard try read(pointer) == nil, try verifyBoundEmpty(owner, candidate) else { throw Failure.indeterminate }
            guard try add(pointer, record) == .inserted else { throw Failure.indeterminate }
        } catch {
            throw Failure.indeterminate
        }
    }

    private func checkVacant() throws {
        if let current = try read(pointer) {
            guard !current.isEmpty, current.count <= 1_024,
                  let record = try? JSONDecoder().decode(Record.self, from: current),
                  record.version == 1, record.owner == owner,
                  record.binding.utf8.count == 64,
                  record.binding.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw Failure.recoveryRequired }
            throw Failure.occupied
        }
        guard try read(attempt) == nil else { throw Failure.recoveryRequired }
    }

    package static func query(_ account: String, accessGroup: String, service: String) throws -> [String: Any] {
        guard !accessGroup.isEmpty, !service.isEmpty else { throw Failure.recoveryRequired }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
