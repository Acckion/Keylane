import CryptoKit
import Foundation

/// Storage must provide durable atomic replacement with a cross-process
/// compare-and-swap. A plain preferences file or an unconditional Keychain
/// update does not satisfy this contract. No storage provider is installed by
/// default, and this type never queries the Keychain or writes app preferences.
public protocol RaycastStoreProtectedReceiptStorage: Sendable {
    func read() throws -> Data?
    func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool
}

/// Joins the independent registry head and the app-owned signer/recipe binding
/// in one protected record. The registry file itself remains a second resource:
/// advancing the protected head before publishing that file intentionally makes
/// a crash between writes fail closed rather than reviving an old generation.
public struct RaycastStoreProtectedReceiptState: RaycastStoreRegistryAnchor, Sendable {
    public enum Recovery: Equatable, Sendable {
        case ready
        case setupRequired
        case protectedStateMissing
        case unreadable
        case migrationRequired
        case protectedWriteIndeterminate
        case interruptedWriteOrRollback
        case registryMismatch

        /// Review-only app copy. None of these suggestions resets, re-enables,
        /// or claims to repair an existing installation.
        public var reviewMessage: String? {
            switch self {
            case .ready: return nil
            case .setupRequired: return "扩展安装存储尚未初始化，商店仍可浏览；暂不能安装或运行扩展。"
            case .protectedStateMissing, .unreadable:
                return "无法验证原有安装记录。扩展不会运行，也不会自动重置记录。"
            case .migrationRequired:
                return "签名身份或运行时已变更。请先检查迁移方案；旧扩展不会自动启用。"
            case .protectedWriteIndeterminate:
                return "无法确认受保护安装记录是否已写入。请先核对记录；不要重复操作或重置。"
            case .interruptedWriteOrRollback, .registryMismatch:
                return "扩展安装记录与受保护状态不一致，运行已停止。请先检查修复方案，不要用旧记录覆盖。"
            }
        }
    }

    public enum Failure: Error, Equatable {
        case review(Recovery)
        case conflict
    }

    private struct Record: Codable {
        let schema: Int
        let registryID: UUID
        let binding: String
        let sequence: UInt64
        let previous: String?
        let head: String?
    }

    package struct OwnerBinding: Encodable, Equatable, Sendable {
        package static let lockName = "store-authority.lock"
        package let profileID: UUID
        package let rootPath: String
        package let rootDevice: Int64
        package let rootInode: UInt64
        package let lockDevice: Int64
        package let lockInode: UInt64

        /// Values are supplied by independent enrollment, not self-adopted from the live path.
        package init(profileID: UUID, rootPath: String, rootDevice: Int64, rootInode: UInt64,
                     lockDevice: Int64, lockInode: UInt64) {
            self.profileID = profileID; self.rootPath = rootPath
            self.rootDevice = rootDevice; self.rootInode = rootInode
            self.lockDevice = lockDevice; self.lockInode = lockInode
        }
    }

    private struct Binding: Encodable {
        let context = "keylane.store.receipts.v1"
        let registryID: UUID
        let publicKeyDigest: String
        let recipeID: String
        let runtimeDigest: String
        let versions: [String]
        let buildRecipe: MacOSExtensionBuild.Recipe?
        let owner: OwnerBinding?
    }

    private let storage: any RaycastStoreProtectedReceiptStorage
    private let registryID: UUID
    private let bindingDigest: String

    /// The stable registry ID, expected public key, and signed recipe must come
    /// from app-owned configuration independent of the editable Store state.
    public init(storage: any RaycastStoreProtectedReceiptStorage, registryID: UUID,
                publicKey: P256.Signing.PublicKey, recipe: RaycastStoreArtifactSeal.Recipe) throws {
        try self.init(storage: storage, registryID: registryID, publicKey: publicKey, recipe: recipe, owner: nil)
    }

    package init(storage: any RaycastStoreProtectedReceiptStorage, registryID: UUID,
                 publicKey: P256.Signing.PublicKey, recipe: RaycastStoreArtifactSeal.Recipe,
                 owner: OwnerBinding?) throws {
        _ = try RaycastStoreArtifactSeal(publicKey: publicKey, recipe: recipe)
        self.storage = storage
        self.registryID = registryID
        let binding = Binding(registryID: registryID, publicKeyDigest: Self.digest(publicKey.x963Representation),
                              recipeID: recipe.identifier, runtimeDigest: recipe.runtimeDigest,
                              versions: recipe.qualifiedAPIVersions.sorted(), buildRecipe: recipe.buildRecipe, owner: owner)
        bindingDigest = Self.digest(try Self.encode(binding))
    }

    package func matchesEnrollment(registryID: UUID, publicKey: P256.Signing.PublicKey,
                                   recipe: RaycastStoreArtifactSeal.Recipe, owner: OwnerBinding) -> Bool {
        let binding = Binding(registryID: registryID, publicKeyDigest: Self.digest(publicKey.x963Representation),
                              recipeID: recipe.identifier, runtimeDigest: recipe.runtimeDigest,
                              versions: recipe.qualifiedAPIVersions.sorted(), buildRecipe: recipe.buildRecipe, owner: owner)
        guard let encoded = try? Self.encode(binding) else { return false }
        return registryID == self.registryID && Self.digest(encoded) == bindingDigest
    }

    /// Inert package fixtures only. Production storage does not allow nil CAS;
    /// new app profiles must use the independently authorized enrollment seam.
    package func initializeNewRegistry(observedRegistryDigest: String?) throws {
        guard observedRegistryDigest == nil else { throw Failure.review(.protectedStateMissing) }
        guard try storage.compareAndSwap(expected: nil, replacement: initialRecord()) else { throw Failure.conflict }
    }

    private func initialRecord() throws -> Data {
        try Self.encode(Record(schema: 1, registryID: registryID, binding: bindingDigest,
                               sequence: 0, previous: nil, head: nil))
    }

    /// Safe diagnostic for a future app repair screen; never mutates or
    /// accidentally trusts the observed disk. No key, receipt, or digest returned.
    public func recoveryStatus(observedRegistryDigest: String?) -> Recovery {
        do {
            let current = try storage.read()
            guard let current else { return observedRegistryDigest == nil ? .setupRequired : .protectedStateMissing }
            let record = try readRecord(current)
            return status(record, observed: observedRegistryDigest)
        } catch Failure.review(let reason) {
            return reason
        } catch {
            return .unreadable
        }
    }

    public func verify(expectedDigest: String?) throws {
        let result = recoveryStatus(observedRegistryDigest: expectedDigest)
        guard result == .ready else { throw Failure.review(result) }
    }

    public func advance(previousDigest: String?, to nextDigest: String) throws {
        guard Self.validDigest(nextDigest) else { throw Failure.review(.unreadable) }
        guard let raw = try storage.read() else {
            throw Failure.review(previousDigest == nil ? .setupRequired : .protectedStateMissing)
        }
        let current = try readRecord(raw)
        let result = status(current, observed: previousDigest)
        guard result == .ready, current.sequence < UInt64.max else {
            throw Failure.review(result == .ready ? .unreadable : result)
        }
        if current.head == nextDigest {
            guard try storage.compareAndSwap(expected: raw, replacement: raw) else { throw Failure.conflict }
            return
        }
        let next = Record(schema: 1, registryID: registryID, binding: bindingDigest,
                          sequence: current.sequence + 1, previous: current.head, head: nextDigest)
        guard try storage.compareAndSwap(expected: raw, replacement: Self.encode(next)) else { throw Failure.conflict }
    }

    private func status(_ record: Record, observed: String?) -> Recovery {
        if record.head == observed { return .ready }
        if record.previous == observed { return .interruptedWriteOrRollback }
        return .registryMismatch
    }

    /// Validates the protected anchor's exact registry and signing/runtime
    /// binding. Launch still requires comparing its head to the disk registry.
    package func matchesProtectedBinding(_ data: Data) -> Bool {
        (try? readRecord(data)) != nil
    }

    private func readRecord(_ data: Data) throws -> Record {
        guard !data.isEmpty, data.count <= 1_024,
              let record = try? JSONDecoder().decode(Record.self, from: data), record.schema == 1,
              Self.validDigest(record.binding),
              record.head.map(Self.validDigest) ?? true,
              record.previous.map(Self.validDigest) ?? true,
              (record.sequence == 0 ? record.head == nil && record.previous == nil : record.head != nil),
              record.previous == nil || record.previous != record.head else { throw Failure.review(.unreadable) }
        guard record.registryID == registryID, record.binding == bindingDigest else { throw Failure.review(.migrationRequired) }
        return record
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}


/// App-owned setup authority, independent of mutable receipt paths. A provider
/// must not infer fresh enrollment from missing disk or Keychain records.
package protocol RaycastStoreFreshProfileEnrollmentAuthority: Sendable {
    func probe(scope: RaycastStoreReceiptEnrollment.Scope) throws -> RaycastStoreReceiptEnrollment.Observation

    /// In one serialized enrollment transaction, independently authenticate the
    /// one-use approval for this exact scope, re-confirm there is no installation
    /// or partial enrollment, consume the approval, and commit the protected
    /// initial record and enrolled lock binding. If atomic completion is not
    /// possible, journal partial enrollment so later probes refuse to start over.
    func commitFreshEnrollment(scope: RaycastStoreReceiptEnrollment.Scope, approval: Data, initialRecord: Data) throws
        -> RaycastStoreReceiptEnrollment.CommitResult
}

package struct RaycastStoreReceiptEnrollment: Sendable {
    package struct Scope: Equatable, Sendable {
        package let registryID: UUID
        package let bindingDigest: String
    }

    package enum Observation: Equatable, Sendable {
        case independentlyVerifiedFresh, existingInstallation, ambiguous
    }

    package enum CommitResult: Equatable, Sendable {
        case enrolled, approvalRejected, existingInstallation, ambiguous
    }

    package enum Failure: Error, Equatable, Sendable {
        case approvalRejected, existingInstallation, ambiguous, indeterminate
    }

    package let scope: Scope
    private let initialRecord: Data
    private let authority: any RaycastStoreFreshProfileEnrollmentAuthority

    fileprivate init(scope: Scope, initialRecord: Data, authority: any RaycastStoreFreshProfileEnrollmentAuthority) {
        self.scope = scope
        self.initialRecord = initialRecord
        self.authority = authority
    }

    /// Diagnostic only. Even a fresh result is not permission to enroll.
    package func probe() -> Observation {
        (try? authority.probe(scope: scope)) ?? .ambiguous
    }

    /// Called only by an explicit new-profile setup action with an opaque proof
    /// from the independent authenticator. Empty, invalid, replayed, mismatched,
    /// partial, or unknown state is never converted to a bootstrap.
    package func enrollNewProfile(approval: Data) throws {
        guard !approval.isEmpty, approval.count <= 1_024 else { throw Failure.approvalRejected }
        switch probe() {
        case .existingInstallation: throw Failure.existingInstallation
        case .ambiguous: throw Failure.ambiguous
        case .independentlyVerifiedFresh: break
        }
        let result: CommitResult
        do {
            result = try authority.commitFreshEnrollment(scope: scope, approval: approval, initialRecord: initialRecord)
        } catch {
            // An external write can already have happened. Do not retry here.
            throw Failure.indeterminate
        }
        switch result {
        case .enrolled: return
        case .approvalRejected: throw Failure.approvalRejected
        case .existingInstallation: throw Failure.existingInstallation
        case .ambiguous: throw Failure.ambiguous
        }
    }
}

extension RaycastStoreProtectedReceiptState {
    package var enrollmentScope: RaycastStoreReceiptEnrollment.Scope {
        .init(registryID: registryID, bindingDigest: bindingDigest)
    }

    package func enrollment(authority: any RaycastStoreFreshProfileEnrollmentAuthority) throws -> RaycastStoreReceiptEnrollment {
        try .init(scope: enrollmentScope,
                  initialRecord: initialRecord(), authority: authority)
    }
}
