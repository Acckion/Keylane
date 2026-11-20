import Foundation

/// An explicit, single-slot new-profile action. The selector is an independently
/// protected, preissued record for this installation, not a scan of app data.
/// Missing, interrupted or already active selectors are never reinitialized.
package struct RaycastStoreNewProfileSetup: Sendable {
    package typealias Scope = RaycastStoreReceiptEnrollment.Scope

    package enum Selection: Equatable, Sendable {
        case noProfile
        case active(Scope)
        case recoveryRequired
    }

    package enum Failure: Error, Equatable, Sendable {
        case approvalRejected, existingProfile, recoveryRequired
    }

    private struct Record: Codable {
        let version: Int
        let owner: UUID
        let phase: Phase
        let registryID: UUID?
        let binding: String?
        enum Phase: String, Codable { case independentlyIssuedVacancy, reserved, active }
    }

    private let owner: UUID
    private let selector: any RaycastStoreProtectedReceiptStorage

    /// Owner and selector identity must come from independently protected app
    /// configuration, not writable profiles, paths or a value recovered by scan.
    package init(owner: UUID, selector: any RaycastStoreProtectedReceiptStorage) {
        self.owner = owner
        self.selector = selector
    }

    /// Bytes for independent first issuance only, never a recovery fallback.
    package static func issuedVacancy(owner: UUID) throws -> Data {
        try encode(.init(version: 1, owner: owner, phase: .independentlyIssuedVacancy, registryID: nil, binding: nil))
    }

    /// Read path for restart. This never accepts an unverified active record
    /// and never changes selector or receipt state.
    package func selection(journal: any RaycastStoreEnrollmentJournal) -> Selection {
        do {
            let (_, record) = try verifiedRecord()
            switch record.phase {
            case .independentlyIssuedVacancy: return .noProfile
            case .reserved: return .recoveryRequired
            case .active:
                let scope = try scope(in: record)
                let observed = try journal.inspect(scope)
                guard observed.journal == .enrolled, observed.slotPresent, observed.lockPresent else { return .recoveryRequired }
                return .active(scope)
            }
        } catch {
            return .recoveryRequired
        }
    }

    /// Deliberately no automatic retry. Authenticate before reserving the only
    /// new-profile slot; after reservation any ambiguity requires review.
    package func enrollExplicitly(_ anchor: RaycastStoreProtectedReceiptState, approval: Data,
                                  verifier: any RaycastStoreFreshScopeVerifier,
                                  journal: any RaycastStoreEnrollmentJournal) throws {
        guard !approval.isEmpty, approval.count <= 1_024 else { throw Failure.approvalRejected }
        let (oldBytes, old) = try verifiedRecord()
        switch old.phase {
        case .active: throw Failure.existingProfile
        case .reserved: throw Failure.recoveryRequired
        case .independentlyIssuedVacancy: break
        }
        let transaction = RaycastStoreEnrollmentTransaction(verifier: verifier, journal: journal)
        let enrollment = try anchor.enrollment(authority: transaction)
        let scope = enrollment.scope
        guard try verifier.identifiesFreshlyIssued(scope), try verifier.authenticate(approval, scope: scope) != nil,
              enrollment.probe() == .independentlyVerifiedFresh else { throw Failure.approvalRejected }
        // Verify the same journal that will later recheck the new binding.
        let initial = try journal.inspect(scope)
        guard initial.journal == .pristine, !initial.registryPresent, !initial.lockPresent, !initial.slotPresent else {
            throw Failure.recoveryRequired
        }
        let reserved = try Self.encode(.init(version: 1, owner: owner, phase: .reserved,
                                            registryID: scope.registryID, binding: scope.bindingDigest))
        do {
            guard try selector.compareAndSwap(expected: oldBytes, replacement: reserved) else { throw Failure.recoveryRequired }
            try enrollment.enrollNewProfile(approval: approval)
            let observed = try journal.inspect(scope)
            guard observed.journal == .enrolled, !observed.registryPresent, observed.slotPresent, observed.lockPresent else {
                throw Failure.recoveryRequired
            }
            let active = try Self.encode(.init(version: 1, owner: owner, phase: .active,
                                              registryID: scope.registryID, binding: scope.bindingDigest))
            guard try selector.compareAndSwap(expected: reserved, replacement: active) else { throw Failure.recoveryRequired }
        } catch {
            throw Failure.recoveryRequired
        }
    }

    private func verifiedRecord() throws -> (Data, Record) {
        guard let raw = try? selector.read(), !raw.isEmpty, raw.count <= 1_024,
              let decoded = try? JSONDecoder().decode(Record.self, from: raw),
              decoded.version == 1, decoded.owner == owner else { throw Failure.recoveryRequired }
        switch decoded.phase {
        case .independentlyIssuedVacancy:
            guard decoded.registryID == nil, decoded.binding == nil else { throw Failure.recoveryRequired }
        case .reserved, .active:
            _ = try scope(in: decoded)
        }
        return (raw, decoded)
    }

    private func scope(in record: Record) throws -> Scope {
        guard let id = record.registryID, let binding = record.binding, binding.utf8.count == 64,
              binding.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.recoveryRequired }
        return .init(registryID: id, bindingDigest: binding)
    }

    private static func encode(_ record: Record) throws -> Data { try JSONEncoder().encode(record) }
}
