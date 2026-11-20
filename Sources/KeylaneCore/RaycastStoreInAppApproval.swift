import AppKit
import CryptoKit
import Foundation
import Security

/// Approval bridge only for explicitly new empty profiles. It is not an
/// attestation of first use and must never be used for recovery of an old scope.
package struct RaycastStoreInAppApproval: Sendable {
    package enum Intent: String, Codable, Sendable { case createEmpty, activateEmpty }
    package struct Scope: Codable, Equatable, Sendable {
        package let owner: UUID
        package let intent: Intent
        package let recipeDigest: String
        package let profileID: UUID?
        package let registryID: UUID?
        package let bindingDigest: String?
        package let runtimeDigest: String?
        package let locksDigest: String?

        package init(owner: UUID, intent: Intent, recipeDigest: String, profileID: UUID? = nil,
                     registryID: UUID? = nil, bindingDigest: String? = nil, runtimeDigest: String? = nil,
                     locksDigest: String? = nil) {
            self.owner = owner
            self.intent = intent
            self.recipeDigest = recipeDigest
            self.profileID = profileID
            self.registryID = registryID
            self.bindingDigest = bindingDigest
            self.runtimeDigest = runtimeDigest
            self.locksDigest = locksDigest
        }

        fileprivate var valid: Bool {
            guard Self.digest(recipeDigest) else { return false }
            switch intent {
            case .createEmpty:
                return profileID == nil && registryID == nil && bindingDigest == nil && runtimeDigest == nil && locksDigest == nil
            case .activateEmpty:
                return profileID != nil && registryID != nil && bindingDigest.map(Self.digest) == true &&
                    runtimeDigest.map(Self.digest) == true && locksDigest.map(Self.digest) == true
            }
        }

        private static func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }

    package enum ActivationAdmission: Sendable {
        /// Independently authenticated immutable new profile and trusted vacant
        /// selection. Missing local records by themselves are never sufficient.
        case verifiedBoundFreshProfileAndVacantSelection
        case occupied, unknown
    }

    package enum Failure: Error, Equatable { case untrustedApp, invalidApproval, declined, indeterminate, activationUnavailable }

    private struct Claims: Codable {
        let type: String
        let scope: Scope
        let proofID: UUID
        let issuerSession: UUID
        let expires: Int64
    }

    private struct Envelope: Codable { let canonical: Data; let signature: Data }
    private static let type = "keylane.store.empty-profile.approval.v1"
    private static let lifetime: Int64 = 120
    private final class IssuerSession: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var attempted: [UUID: Int64] = [:]

        func begin(_ proof: UUID, expires: Int64, now: Int64) -> Bool {
            lock.withLock {
                attempted = attempted.filter { $0.value > now }
                guard attempted.count < 256, attempted[proof] == nil else { return false }
                attempted[proof] = expires
                return true
            }
        }
    }

    private let session = IssuerSession()
    private let identity: @Sendable () throws -> Bool
    private let confirm: @MainActor @Sendable (Scope) -> Bool
    private let sign: @Sendable (Data) throws -> Data
    private let verify: @Sendable (Data, Data) -> Bool
    private let insertion: @Sendable (String, Data) throws -> RaycastStoreMacProfileReservation.Insert
    private let clock: @Sendable () -> Int64

    // Deliberately module-internal for inert tests; the app composition
    // receives only the initializer with the real, isolated confirmation UI.
    init(identity: @escaping @Sendable () throws -> Bool, confirm: @escaping @MainActor @Sendable (Scope) -> Bool,
         sign: @escaping @Sendable (Data) throws -> Data, verify: @escaping @Sendable (Data, Data) -> Bool,
         insertion: @escaping @Sendable (String, Data) throws -> RaycastStoreMacProfileReservation.Insert,
         clock: @escaping @Sendable () -> Int64) {
        self.identity = identity
        self.confirm = confirm
        self.sign = sign
        self.verify = verify
        self.insertion = insertion
        self.clock = clock
    }

    /// Native calls are deferred. Authenticated configuration must pin the
    /// exact app team/identifier, the private key lookup label and public key,
    /// and an app-exclusive non-sync Data Protection Keychain access group.
    package init(expectedTeam: String, bundleID: String, accessGroup: String, service: String,
                 approvalKeyTag: Data, pinnedPublicKey: P256.Signing.PublicKey) {
        self.init(identity: { try Self.verifyApp(expectedTeam: expectedTeam, bundleID: bundleID) },
                  confirm: { scope in Self.confirmEmptyProfile(scope) },
                  sign: { canonical in
            guard !accessGroup.isEmpty, (1...128).contains(approvalKeyTag.count) else { throw Failure.untrustedApp }
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrApplicationTag as String: approvalKeyTag,
                kSecAttrAccessGroup as String: accessGroup, kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: false, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnRef as String: true
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let item, CFGetTypeID(item) == SecKeyGetTypeID()
            else { throw Failure.untrustedApp }
            let key = item as! SecKey // CF type guard above; never exports private bytes.
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, canonical as CFData, &error)
            else {
                _ = error?.takeRetainedValue()
                throw Failure.untrustedApp
            }
            return signature as Data
        }, verify: { bytes, signature in
            guard let value = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            return pinnedPublicKey.isValidSignature(value, for: bytes)
        }, insertion: { account, bytes in
            var query = try RaycastStoreExplicitProfileActivation.query(account, accessGroup: accessGroup, service: service)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecValueData as String] = bytes
            switch SecItemAdd(query as CFDictionary, nil) {
            case errSecSuccess: return .inserted
            case errSecDuplicateItem: return .duplicate
            default: throw Failure.indeterminate
            }
        }, clock: { Int64(Date().timeIntervalSince1970) })
    }

    /// Only an actual affirmative app confirmation can reach native signing.
    /// The caller cannot pass its own acknowledgment Boolean.
    @MainActor package func issue(_ scope: Scope) throws -> Data {
        guard scope.intent == .createEmpty else { throw Failure.invalidApproval }
        return try confirmAndIssue(scope)
    }

    /// The verifier must compare the exact authenticated owner/profile,
    /// registry, runtime/recipe and immutable enrolled-lock binding to its
    /// trusted records, and independently establish selector eligibility.
    @MainActor package func issueActivation(_ scope: Scope,
        admission: @escaping @Sendable (Scope) throws -> ActivationAdmission) throws -> Data {
        guard scope.intent == .activateEmpty else { throw Failure.invalidApproval }
        return try confirmAndIssue(scope, admission: admission)
    }

    @MainActor private func confirmAndIssue(_ scope: Scope,
        admission: (@Sendable (Scope) throws -> ActivationAdmission)? = nil) throws -> Data {
        guard try identity() else { throw Failure.untrustedApp }
        guard scope.valid else { throw Failure.invalidApproval }
        try Self.requireActivationAdmission(scope, admission)
        guard confirm(scope) else { throw Failure.declined }
        guard try identity() else { throw Failure.untrustedApp }
        try Self.requireActivationAdmission(scope, admission)
        let now = clock()
        guard now > 0, now <= Int64.max - Self.lifetime else { throw Failure.invalidApproval }
        let canonical = try Self.encode(Claims(type: Self.type, scope: scope, proofID: UUID(), issuerSession: session.id, expires: now + Self.lifetime))
        let signature = try sign(canonical)
        guard signature.count <= 80, verify(canonical, signature) else { throw Failure.untrustedApp }
        let token = try Self.encode(Envelope(canonical: canonical, signature: signature))
        guard token.count <= 1_024 else { throw Failure.invalidApproval }
        return token
    }

    /// Called by the create-only reservation adapter after an isolated request
    /// is selected. Consumes the proof before returning a reservation ID.
    /// Creation records and tokens are never valid for the activation path.
    package func consumeForNewEmptyProfile(_ token: Data, for scope: Scope) throws -> UUID? {
        guard scope.intent == .createEmpty, let claims = try checkedClaims(token, scope: scope) else { return nil }
        return try consume(claims, prefix: "empty-consent:") ? claims.proofID : nil
    }

    /// Adapter for the selected-pointer second action. Existing activation
    /// still re-verifies the profile before invoking this durable consumer.
    package func activationApproval(_ token: Data, for scope: Scope, owner: UUID,
        candidate: RaycastStoreExplicitProfileActivation.Candidate, admission: @escaping @Sendable (Scope) throws -> ActivationAdmission) throws -> RaycastStoreExplicitProfileActivation.Approval? {
        guard scope.intent == .activateEmpty, scope.owner == owner, scope.profileID == candidate.profileID,
              scope.registryID == candidate.scope.registryID, scope.bindingDigest == candidate.scope.bindingDigest,
              let claims = try checkedClaims(token, scope: scope) else { return nil }
        try Self.requireActivationAdmission(scope, admission)
        return .init(proofID: claims.proofID, explicitlyAuthorizedEmptySelection: true, consume: {
            guard let rechecked = try checkedClaims(token, scope: scope) else { return false }
            try Self.requireActivationAdmission(scope, admission)
            return try consume(rechecked, prefix: "activate-empty-consent:")
        })
    }

    private func checkedClaims(_ token: Data, scope: Scope) throws -> Claims? {
        guard try identity() else { throw Failure.untrustedApp }
        guard scope.valid, !token.isEmpty, token.count <= 1_024,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: token),
              (1...768).contains(envelope.canonical.count), (1...80).contains(envelope.signature.count),
              let claims = try? JSONDecoder().decode(Claims.self, from: envelope.canonical), claims.scope == scope,
              claims.type == Self.type, claims.issuerSession == session.id, try Self.encode(claims) == envelope.canonical,
              verify(envelope.canonical, envelope.signature) else { return nil }
        let now = clock()
        guard now > 0, now <= Int64.max - Self.lifetime, claims.expires > now, claims.expires <= now + Self.lifetime else { return nil }
        return claims
    }

    private func consume(_ claims: Claims, prefix: String) throws -> Bool {
        // Same running issuer only; a crash invalidates outstanding proofs.
        // Mark locally before SecItemAdd so an uncertain no-write cannot replay.
        guard session.begin(claims.proofID, expires: claims.expires, now: clock()) else { return false }
        do {
            return try insertion(prefix + claims.scope.owner.uuidString + ":" + claims.proofID.uuidString,
                                 Self.encode(claims)) == .inserted
        } catch { throw Failure.indeterminate }
    }

    private static func requireActivationAdmission(_ scope: Scope,
        _ admission: (@Sendable (Scope) throws -> ActivationAdmission)?) throws {
        guard scope.intent == .activateEmpty else { return }
        guard let admission, case .verifiedBoundFreshProfileAndVacantSelection = try admission(scope) else {
            throw Failure.activationUnavailable
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    @MainActor private static func confirmEmptyProfile(_ scope: Scope) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let activate = scope.intent == .activateEmpty
        alert.messageText = activate ? "启用这份空白扩展配置？" : "新建空白扩展配置？"
        alert.informativeText = activate
            ? "只有当前这份空白配置会被启用。以前的安装记录不会恢复，也不会被覆盖。"
            : "此操作只新建一份未启用的空白配置，不会恢复或覆盖以前的安装记录。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: activate ? "启用空白配置" : "新建空白配置")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func verifyApp(expectedTeam: String, bundleID: String) throws -> Bool {
        func safe(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 &&
            value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 } }
        guard safe(expectedTeam), safe(bundleID), Bundle.main.bundleIdentifier == bundleID else { return false }
        var code: SecCode?
        var requirement: SecRequirement?
        let predicate = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(expectedTeam)\""
        guard SecRequirementCreateWithString(predicate as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
