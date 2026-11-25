import CryptoKit
import Darwin
import Foundation
import Security
import MachO

/// App-owned macOS build profile. No default selection, automatic enrollment,
/// repair, Keychain enumeration or credential forwarding to a child process.
package final class MacOSBuildProfile: @unchecked Sendable {
    package enum Failure: Error { case unavailable, signature, identity, buildRecipeChanged, missing, pending, store(OSStatus), unsafeRoot }
    package struct Configuration: Codable, Sendable {
        package let schema: Int
        package let mode: String
        package let storage: String
        package let runHelperSHA256: String?
        package let recipe: MacOSExtensionBuild.Recipe
    }
    package struct Approval: Sendable {
        package let profileID = UUID()
        fileprivate let proof = UUID()
        // Construct only after the native setup UI confirms a NEW profile.
        package init(userConfirmed: Bool) throws { guard userConfirmed else { throw Failure.unavailable } }
    }
    private struct Identity: Codable, Equatable {
        let device: Int64
        let inode: UInt64
        init(_ value: stat) { device = Int64(value.st_dev); inode = value.st_ino }
    }
    private struct Record: Codable {
        var phase: String
        let id: UUID
        let host: String
        let recipe: MacOSExtensionBuild.Recipe
        let root: String
        var directory: Identity?
        var owner: Identity?
        var receiptLock: Identity?
        var buildLock: Identity?
        let key: Data
    }
    private enum KeychainBackend {
        case dataProtection(group: String)
        case legacy(service: String)
    }
    private let record: Record
    package let configuration: Configuration
    package let application: Bundle
    package let helper: URL
    package let compiler: URL
    private let requirement: String
    private let backend: KeychainBackend
    package var root: URL { URL(fileURLWithPath: record.root) }
    package var id: UUID { record.id }
    package var publicKey: P256.Signing.PublicKey { get throws { try P256.Signing.PrivateKey(rawRepresentation: record.key).publicKey } }
    package var sealRecipe: RaycastStoreArtifactSeal.Recipe {
        get throws {
            .init(identifier: "macos-build-v1-" + (try configuration.recipe.digest),
                  runtimeDigest: configuration.runHelperSHA256 ?? MacOSExtensionBuild.hash(Data("restricted-jsc/build-only/M1".utf8)),
                  qualifiedAPIVersions: configuration.runHelperSHA256 == nil ? [] : Set(MacOSReviewedRaycastCommand.entries.map(\.apiVersion)), buildRecipe: configuration.recipe)
        }
    }
    package var anchor: RaycastStoreProtectedReceiptState {
        get throws {
            guard let identity = record.receiptLock, let directory = record.directory, let owner = record.owner else { throw Failure.pending }
            let storage = RaycastStoreSerializedReceiptStorage(directory: root,
                lockIdentity: .init(device: dev_t(identity.device), inode: identity.inode),
                slot: Slot(id: id, suffix: "head", backend: backend))
            let binding = RaycastStoreProtectedReceiptState.OwnerBinding(profileID: id, rootPath: root.path,
                rootDevice: directory.device, rootInode: directory.inode, lockDevice: owner.device, lockInode: owner.inode)
            return try .init(storage: storage, registryID: id, publicKey: publicKey, recipe: sealRecipe, owner: binding)
        }
    }

    private init(application: Bundle, record: Record, configuration: Configuration, requirement: String, backend: KeychainBackend) throws {
        self.application = application; self.record = record; self.configuration = configuration; self.requirement = requirement; self.backend = backend
        helper = application.bundleURL.resolvingSymlinksInPath().appendingPathComponent("Contents/Helpers/KeylaneExtensionBuild.app/Contents/MacOS/keylane-extension-build")
        compiler = helper.deletingLastPathComponent().appendingPathComponent("esbuild")
        try verify()
    }

    /// Read an enrolled record from the backend bound to the signed bundle.
    /// The legacy preview backend has no OS-enforced application access group.
    package static func open(id: UUID, application: Bundle, hostIdentifier: String = "org.keylane.launcher") throws -> MacOSBuildProfile {
        let (configuration, requirement, backend) = try configuration(application, identifier: hostIdentifier)
        guard let data = try Slot(id: id, suffix: "profile", backend: backend).readExisting(), data.count <= 16384 else { throw Failure.missing }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.id == id, record.phase == "enrolled" else { throw Failure.pending }
        return try .init(application: application, record: record, configuration: configuration, requirement: requirement, backend: backend)
    }

    package static func verifyRuntimeConfiguration(application: Bundle, hostIdentifier: String = "org.keylane.launcher") throws {
        let (configuration, _, _) = try configuration(application, identifier: hostIdentifier)
        guard configuration.runHelperSHA256 != nil else { throw Failure.unavailable }
    }

    /// Explicit create-only enrollment. The successful protected reservation is
    /// the fresh-scope proof; absence of a registry/lock/Keychain item is not.
    package static func enroll(_ approval: Approval, root: URL, application: Bundle,
                               hostIdentifier: String = "org.keylane.launcher") async throws -> MacOSBuildProfile {
        let (configuration, requirement, backend) = try configuration(application, identifier: hostIdentifier)
        let root = root.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent)
        guard root.isFileURL, root.lastPathComponent == approval.profileID.uuidString else { throw Failure.unsafeRoot }
        let slot = Slot(id: approval.profileID, suffix: "profile", backend: backend)
        var record = Record(phase: "pending", id: approval.profileID, host: try executablePath(), recipe: configuration.recipe,
                            root: root.path, key: P256.Signing.PrivateKey().rawRepresentation)
        try slot.create(MacOSExtensionBuild.encode(record)) // durable reservation; never overwrite/retry on loss
        guard mkdir(root.path, 0o700) == 0 else { throw Failure.unsafeRoot }
        var directory = stat()
        guard lstat(root.path, &directory) == 0, privateOwned(directory, type: S_IFDIR) else { throw Failure.unsafeRoot }
        record.directory = Identity(directory)
        func lock(_ name: String) throws -> Identity {
            let fd = Darwin.open(root.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.unsafeRoot }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, privateOwned(info, type: S_IFREG), fsync(fd) == 0 else { throw Failure.unsafeRoot }
            return Identity(info)
        }
        record.owner = try lock("store-authority.lock")
        record.receiptLock = try lock("receipt-authority.lock")
        record.buildLock = try lock("build.lock")
        _ = try lock("registry.lock")
        let directoryFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw Failure.unsafeRoot }
        let synced = fsync(directoryFD); close(directoryFD); guard synced == 0 else { throw Failure.unsafeRoot }
        // Profile is still pending. Only this in-memory, freshly reserved native
        // operation can construct the authority for the existing enrollment seam.
        try slot.replaceExisting(with: MacOSExtensionBuild.encode(record))
        let provisional = try Self(application: application, record: record, configuration: configuration, requirement: requirement, backend: backend)
        let authority = Enrollment(record: record, approval: approval, slot: slot, scope: try provisional.anchor.enrollmentScope)
        try provisional.anchor.enrollment(authority: authority).enrollNewProfile(approval: Data(approval.proof.uuidString.utf8))
        return try open(id: approval.profileID, application: application, hostIdentifier: hostIdentifier)
    }

    package func sign(_ bytes: Data) throws -> P256.Signing.ECDSASignature {
        try verify(); return try P256.Signing.PrivateKey(rawRepresentation: record.key).signature(for: bytes)
    }
    package var preferenceVault: MacOSReviewedPreferenceVault? {
        guard case .dataProtection = backend else { return nil }
        return .init(profileKey: record.key, profileID: id)
    }
    func acquireStoreOwnership() throws -> MacOSStoreOwnership {
        try verify()
        guard let owner = record.owner else { throw Failure.pending }
        return try MacOSStoreOwnership(
            path: root.appendingPathComponent(RaycastStoreProtectedReceiptState.OwnerBinding.lockName),
            device: owner.device, inode: owner.inode, exclusive: configuration.runHelperSHA256 != nil)
    }

    func runDriver(ownership: MacOSStoreOwnership, deliver: MacOSNoViewCapabilities.Presenter?) -> MacOSRestrictedNoViewDriver? {
        guard let digest = configuration.runHelperSHA256, let identifier = application.bundleIdentifier else { return nil }
        let runRequirement = requirement.replacingOccurrences(of: "identifier \""+identifier+"\"",
                                                              with: "identifier \"org.keylane.extension-run\"")
        return MacOSRestrictedNoViewDriver(application: application, expectedDigest: digest,
                                           signingRequirement: runRequirement, ownership: ownership, deliver: deliver,
                                           storage: MacOSReviewedRaycastStorage(root: root))
    }

    package func acquireBuildLock() throws -> Int32 {
        try verify()
        let fd = Darwin.open(root.appendingPathComponent("build.lock").path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafeRoot }
        var info = stat()
        guard fstat(fd, &info) == 0, Self.privateOwned(info, type: S_IFREG), info.st_nlink == 1, record.buildLock == Identity(info) else {
            close(fd); throw Failure.unsafeRoot
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw MacOSExtensionBuild.Failure.busy }
        return fd
    }
    package func verify() throws {
        guard try Self.executablePath() == record.host else { throw Failure.identity }
        guard record.recipe == configuration.recipe else { throw Failure.buildRecipeChanged }
        try Self.check(application.bundleURL, requirement: requirement, entitlements: nil)
        guard let identifier = application.bundleIdentifier else { throw Failure.identity }
        let helperApp = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard helperApp.resolvingSymlinksInPath() == helperApp.standardizedFileURL,
              compiler.resolvingSymlinksInPath() == compiler.standardizedFileURL else { throw Failure.identity }
        try Self.check(helperApp, requirement: requirement.replacingOccurrences(of: "identifier \"" + identifier + "\"", with: "identifier \"org.keylane.extension-build\""), entitlements: ["com.apple.security.app-sandbox":true])
        try Self.check(compiler, requirement: requirement.replacingOccurrences(of: "identifier \"" + identifier + "\"", with: "identifier \"org.keylane.extension-compiler\""), entitlements: ["com.apple.security.app-sandbox":true,"com.apple.security.inherit":true])
        guard MacOSExtensionBuild.hash(try Data(contentsOf: helper)) == configuration.recipe.helperSHA256,
              MacOSExtensionBuild.hash(try Data(contentsOf: compiler)) == configuration.recipe.compilerSHA256 else { throw Failure.identity }
        var dir = stat(), owner = stat(), receipt = stat(), build = stat()
        guard lstat(root.path, &dir) == 0, Self.privateOwned(dir, type: S_IFDIR), record.directory == Identity(dir),
              lstat(root.appendingPathComponent("store-authority.lock").path, &owner) == 0, Self.privateOwned(owner, type: S_IFREG), owner.st_nlink == 1, record.owner == Identity(owner),
              lstat(root.appendingPathComponent("receipt-authority.lock").path, &receipt) == 0, Self.privateOwned(receipt, type: S_IFREG), receipt.st_nlink == 1, record.receiptLock == Identity(receipt),
              lstat(root.appendingPathComponent("build.lock").path, &build) == 0, Self.privateOwned(build, type: S_IFREG), build.st_nlink == 1, record.buildLock == Identity(build) else { throw Failure.unsafeRoot }
        // Re-read the protected reservation so deletion or an interrupted setup
        // cannot be masked by this object's cached signing material.
        guard let current = try Slot(id: id, suffix: "profile", backend: backend).readExisting(),
              let stored = try? JSONDecoder().decode(Record.self, from: current), stored.id == id,
              stored.phase == record.phase, stored.host == record.host, stored.recipe == record.recipe,
              stored.key == record.key, stored.root == record.root, stored.directory == record.directory, stored.owner == record.owner,
              stored.receiptLock == record.receiptLock, stored.buildLock == record.buildLock else { throw Failure.missing }
    }
    private static func privateOwned(_ value: stat, type: mode_t) -> Bool {
        value.st_uid == geteuid() && value.st_mode & S_IFMT == type && value.st_mode & 0o077 == 0
    }
    private static func executablePath() throws -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw Failure.signature }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }
    private static func configuration(_ application: Bundle, identifier: String) throws -> (Configuration, String, KeychainBackend) {
        guard identifier == application.bundleIdentifier, !identifier.isEmpty,
              identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46].contains($0) }),
              application.executableURL?.resolvingSymlinksInPath().path == (try executablePath()) else { throw Failure.identity }
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else { throw Failure.signature }
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { throw Failure.signature }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format:"%02x", $0) }.joined()
        let requirement = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf = H\"\(fingerprint)\""
        try check(application.bundleURL, requirement: requirement, entitlements: nil)
        let path = application.bundleURL.appendingPathComponent("Contents/Resources/ExtensionBuild.json")
        let data = try Data(contentsOf: path)
        guard data.count <= 16384 else { throw Failure.unavailable }
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        guard configuration.schema == 2 else { throw Failure.unavailable }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let backend: KeychainBackend
        switch configuration.storage {
        case "data-protection-keychain-v2":
            backend = .dataProtection(group: try protectedAccessGroup(entitlements: entitlements, identifier: identifier, team: team))
        case "legacy-login-keychain-preview-v1":
            guard configuration.mode == "restricted-no-view",
                  entitlements["keychain-access-groups"] == nil,
                  entitlements["com.apple.application-identifier"] == nil else { throw Failure.identity }
            backend = .legacy(service: "org.keylane.extension-build.legacy-preview.v1." + team + "." + identifier)
        default: throw Failure.unavailable
        }
        switch (configuration.mode, configuration.runHelperSHA256) {
        case ("build-only", nil): break
        case ("restricted-no-view", .some(let digest)):
            guard digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.unavailable }
        default: throw Failure.unavailable
        }
        try configuration.recipe.validate(); return (configuration, requirement, backend)
    }
    /// OS-enforced application identity, not an item attribute or a caller's
    /// chosen access group. Provisioning must authorize these signed rights;
    /// the Keychain additionally enforces them on every operation.
    package static func protectedAccessGroup(entitlements: [String: Any], identifier: String, team: String) throws -> String {
        guard !team.isEmpty, team.utf8.count <= 64,
              team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { throw Failure.identity }
        let expected = team + "." + identifier
        guard entitlements["com.apple.application-identifier"] as? String == expected,
              entitlements["com.apple.developer.team-identifier"] as? String == team else { throw Failure.identity }
        if let groups = entitlements["keychain-access-groups"] {
            guard let groups = groups as? [String], groups == [expected] else { throw Failure.identity }
        }
        return expected
    }
    static func check(_ url: URL, requirement text: String, entitlements expected: [String: Bool]?) throws {
        var code: SecStaticCode?, requirement: SecRequirement?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let flags = info[kSecCodeInfoFlags as String] as? UInt32,
              flags & 0x10000 != 0 else { throw Failure.signature }
        let rights = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        if let expected { guard NSDictionary(dictionary: rights).isEqual(to: expected) else { throw Failure.signature } }
        guard !["com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.allow-unsigned-executable-memory", "com.apple.security.get-task-allow"].contains(where: { rights[$0] as? Bool == true }) else { throw Failure.signature }
    }
    private struct Slot: RaycastStoreProtectedReceiptSlot {
        let id: UUID
        let suffix: String
        let backend: KeychainBackend
        private var query: [String: Any] {
            var attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: id.uuidString + ":" + suffix,
                kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
            ]
            switch backend {
            case .dataProtection(let group):
                attributes[kSecAttrService as String] = "org.keylane.extension-build.protected.v2"
                attributes[kSecUseDataProtectionKeychain as String] = true
                attributes[kSecAttrAccessGroup as String] = group
            case .legacy(let service):
                attributes[kSecAttrService as String] = service
            }
            return attributes
        }
        func readExisting() throws -> Data? {
            var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let bytes = result as? Data, bytes.count <= 16384 else { throw Failure.store(status) }; return bytes
        }
        func replaceExisting(with bytes: Data) throws {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String:bytes] as CFDictionary)
            guard status == errSecSuccess else { throw Failure.store(status) }
        }
        func create(_ bytes: Data) throws {
            var q = query; q[kSecValueData as String] = bytes
            if case .dataProtection = backend {
                q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let status = SecItemAdd(q as CFDictionary, nil); guard status == errSecSuccess else { throw Failure.store(status) }
        }
    }
    private final class Enrollment: RaycastStoreFreshProfileEnrollmentAuthority, @unchecked Sendable {
        let lock = NSLock(); var used = false
        var record: Record; let approval: Approval; let slot: Slot
        let scope: RaycastStoreReceiptEnrollment.Scope
        init(record: Record, approval: Approval, slot: Slot, scope: RaycastStoreReceiptEnrollment.Scope) { self.record = record; self.approval = approval; self.slot = slot; self.scope = scope }
        func probe(scope: RaycastStoreReceiptEnrollment.Scope) throws -> RaycastStoreReceiptEnrollment.Observation {
            lock.withLock { !used && scope == self.scope ? .independentlyVerifiedFresh : .ambiguous }
        }
        func commitFreshEnrollment(scope: RaycastStoreReceiptEnrollment.Scope, approval proof: Data, initialRecord: Data) throws -> RaycastStoreReceiptEnrollment.CommitResult {
            try lock.withLock {
                guard !used, scope == self.scope, proof == Data(approval.proof.uuidString.utf8) else { return .approvalRejected }
                used = true
                try Slot(id: record.id, suffix: "head", backend: slot.backend).create(initialRecord)
                record.phase = "enrolled"; try slot.replaceExisting(with: MacOSExtensionBuild.encode(record))
                return .enrolled
            }
        }
    }
}
