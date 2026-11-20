import Foundation

/// A scoped, preconfigured journal. The protected CAS slot and the outer
/// transaction lock must be separately enrolled, fixed and distinct. Neither
/// is created here. The normal receipt lock/slot are created only by explicit
/// caller-supplied create-only operations after the pending record is durable.
package struct RaycastStoreProtectedEnrollmentJournal: RaycastStoreEnrollmentJournal {
    package typealias Scope = RaycastStoreReceiptEnrollment.Scope
    package typealias State = RaycastStoreEnrollmentTransaction.State
    package typealias Lock = RaycastStoreSerializedReceiptStorage.LockIdentity

    package enum Failure: Error { case invalidJournal, invalidTransition, conflict }

    package struct Footprint: Sendable {
        package let registryPresent: Bool
        package let lockPresent: Bool
        package let slotPresent: Bool

        package init(registryPresent: Bool, lockPresent: Bool, slotPresent: Bool) {
            self.registryPresent = registryPresent
            self.lockPresent = lockPresent
            self.slotPresent = slotPresent
        }
    }

    private struct Record: Codable {
        let version: Int
        let registryID: UUID
        let binding: String
        var phase: Phase
        var consumedProof: UUID?
        var lockDevice: Int32?
        var lockInode: UInt64?
        enum Phase: String, Codable { case pristine, pending, enrolled }
    }

    private let scope: Scope
    private let storage: RaycastStoreSerializedReceiptStorage
    private let transactionGate: RaycastStoreSerializedReceiptStorage
    private let footprint: @Sendable () throws -> Footprint
    private let createLock: @Sendable () throws -> Lock
    private let createSlot: @Sendable (Data, Lock) throws -> Void
    private let verifyBinding: @Sendable (Lock) throws -> Bool

    package init(scope: Scope, storage: RaycastStoreSerializedReceiptStorage,
                 transactionGate: RaycastStoreSerializedReceiptStorage,
                 footprint: @escaping @Sendable () throws -> Footprint,
                 createLock: @escaping @Sendable () throws -> Lock,
                 createSlot: @escaping @Sendable (Data, Lock) throws -> Void,
                 verifyBinding: @escaping @Sendable (Lock) throws -> Bool) {
        self.scope = scope
        self.storage = storage
        self.transactionGate = transactionGate
        self.footprint = footprint
        self.createLock = createLock
        self.createSlot = createSlot
        self.verifyBinding = verifyBinding
    }

    /// Bytes for the *independent* issuer to provision at profile issuance,
    /// not for startup or setup to synthesize from absent credentials.
    package static func pristineRecord(for scope: Scope) throws -> Data {
        try JSONEncoder().encode(Record(version: 1, registryID: scope.registryID,
                                       binding: scope.bindingDigest, phase: .pristine))
    }

    package func inspect(_ scope: Scope) throws -> State {
        try withExclusive(scope) { try $0.inspect() }
    }

    package func withExclusive<T>(_ scope: Scope, _ body: (any RaycastStoreExclusiveEnrollment) throws -> T) throws -> T {
        guard scope == self.scope else { throw Failure.invalidJournal }
        return try transactionGate.withExclusiveOperation(excluding: storage) { validateLock in
            let session = Session(owner: self, validateLock: validateLock)
            defer { session.active = false }
            return try body(session)
        }
    }

    private final class Session: RaycastStoreExclusiveEnrollment {
        let owner: RaycastStoreProtectedEnrollmentJournal
        private let validateLock: () throws -> Void
        var active = true

        init(owner: RaycastStoreProtectedEnrollmentJournal, validateLock: @escaping () throws -> Void) {
            self.owner = owner
            self.validateLock = validateLock
        }

        private func read() throws -> (Data, Record) {
            guard active else { throw Failure.invalidTransition }
            try validateLock()
            guard let raw = try owner.storage.read(),
                  let record = try? JSONDecoder().decode(Record.self, from: raw),
                  record.version == 1, record.registryID == owner.scope.registryID, record.binding == owner.scope.bindingDigest else {
                throw Failure.invalidJournal
            }
            switch record.phase {
            case .pristine:
                guard record.consumedProof == nil, record.lockDevice == nil, record.lockInode == nil else { throw Failure.invalidJournal }
            case .pending:
                guard record.consumedProof != nil, record.lockDevice == nil, record.lockInode == nil else { throw Failure.invalidJournal }
            case .enrolled:
                guard record.consumedProof != nil, record.lockDevice != nil, record.lockInode != nil else { throw Failure.invalidJournal }
            }
            return (raw, record)
        }

        private func replace(_ value: Record, expected: Data) throws {
            try validateLock()
            guard try owner.storage.compareAndSwap(expected: expected, replacement: JSONEncoder().encode(value))
            else { throw Failure.conflict }
        }

        func inspect() throws -> State {
            let (_, record) = try read()
            let footprint = try owner.footprint()
            let phase: State.Journal
            switch record.phase {
            case .pristine: phase = .pristine
            case .pending: phase = .pending
            case .enrolled:
                guard let device = record.lockDevice, let inode = record.lockInode,
                      footprint.lockPresent, footprint.slotPresent,
                      try owner.verifyBinding(.init(device: device, inode: inode)) else { throw Failure.invalidJournal }
                phase = .enrolled
            }
            return .init(journal: phase, registryPresent: footprint.registryPresent,
                         lockPresent: footprint.lockPresent, slotPresent: footprint.slotPresent)
        }

        func beginConsuming(proofID: UUID) throws -> Bool {
            let (raw, record) = try read()
            let observed = try owner.footprint()
            guard record.phase == .pristine, !observed.registryPresent, !observed.lockPresent, !observed.slotPresent else { return false }
            var pending = record
            pending.phase = .pending
            pending.consumedProof = proofID
            try replace(pending, expected: raw)
            return true
        }

        func createOwnedLock() throws -> Lock {
            guard try read().1.phase == .pending else { throw Failure.invalidTransition }
            try validateLock()
            return try owner.createLock()
        }

        func createProtectedSlot(initialRecord: Data, lock: Lock) throws {
            guard try read().1.phase == .pending else { throw Failure.invalidTransition }
            try validateLock()
            try owner.createSlot(initialRecord, lock)
        }

        func finishEnrollment(lock: Lock) throws {
            let (raw, record) = try read()
            let observed = try owner.footprint()
            guard record.phase == .pending, !observed.registryPresent, observed.lockPresent,
                  observed.slotPresent, try owner.verifyBinding(lock) else { throw Failure.invalidTransition }
            var enrolled = record
            enrolled.phase = .enrolled
            enrolled.lockDevice = lock.device
            enrolled.lockInode = lock.inode
            try replace(enrolled, expected: raw)
        }
    }
}
