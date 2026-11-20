import CryptoKit
import Darwin
import Foundation
import Security

/// Read-only reconstruction for a previously selected profile. Missing,
/// malformed or unverifiable facts never create a fallback profile.
package struct RaycastStoreSelectedProfileReader: Sendable {
    package typealias Lock = RaycastStoreSerializedReceiptStorage.LockIdentity
    package struct Capability: Equatable, Sendable {
        package let profileID: UUID
        package let scope: RaycastStoreReceiptEnrollment.Scope
        package let receiptLock: Lock
        package let ownerBinding: RaycastStoreProtectedReceiptState.OwnerBinding

        fileprivate init(profileID: UUID, scope: RaycastStoreReceiptEnrollment.Scope, receiptLock: Lock,
                         ownerBinding: RaycastStoreProtectedReceiptState.OwnerBinding) {
            self.profileID = profileID
            self.scope = scope
            self.receiptLock = receiptLock
            self.ownerBinding = ownerBinding
        }
    }

    private struct Pointer: Decodable {
        let version: Int
        let owner: UUID
        let profileID: UUID
        let registryID: UUID
        let binding: String
        let proofID: UUID
    }

    private struct Binding: Decodable {
        let phase: String
        let profile: UUID
        let registry: UUID
        let binding: String
        let lockIDs: [[UInt64]]
    }

    private struct Journal: Decodable {
        let version: Int
        let registryID: UUID
        let binding: String
        let phase: String
        let consumedProof: UUID
        let lockDevice: Int32
        let lockInode: UInt64
    }

    private let owner: UUID
    private let root: URL
    private let rootLock: Lock
    private let expectedTeam: String
    private let verifiedRuntime: @Sendable () throws -> (team: String, digest: String)
    private let key: P256.Signing.PublicKey
    private let recipe: RaycastStoreArtifactSeal.Recipe
    private let read: @Sendable (String) throws -> Data?

    /// verifiedRuntime must be obtained from the existing strict signed-helper
    /// locator. Caller key/recipe and root inode are independently app pinned.
    package init(owner: UUID, root: URL, rootLock: Lock, expectedTeam: String,
                 verifiedRuntime: @escaping @Sendable () throws -> (team: String, digest: String), key: P256.Signing.PublicKey,
                 recipe: RaycastStoreArtifactSeal.Recipe, read: @escaping @Sendable (String) throws -> Data?) {
        self.owner = owner
        self.root = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent, isDirectory: true).standardizedFileURL
        self.rootLock = rootLock
        self.expectedTeam = expectedTeam
        self.verifiedRuntime = verifiedRuntime
        self.key = key
        self.recipe = recipe
        self.read = read
    }

    package init(owner: UUID, root: URL, rootLock: Lock, expectedTeam: String,
                 verifiedRuntime: @escaping @Sendable () throws -> (team: String, digest: String), key: P256.Signing.PublicKey,
                 recipe: RaycastStoreArtifactSeal.Recipe, accessGroup: String, service: String) {
        self.init(owner: owner, root: root, rootLock: rootLock, expectedTeam: expectedTeam,
                  verifiedRuntime: verifiedRuntime, key: key, recipe: recipe) { account in
            var query = try RaycastStoreExplicitProfileActivation.query(account, accessGroup: accessGroup, service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let bytes = result as? Data else { throw Failure.invalid }
            return bytes
        }
    }

    package func selected() -> Capability? { try? verifiedSelection() }

    private func verifiedSelection() throws -> Capability {
        let runtime = try verifiedRuntime()
        guard !expectedTeam.isEmpty, runtime.team == expectedTeam, runtime.digest == recipe.runtimeDigest else { throw Failure.invalid }
        let ownerAccount = owner.uuidString
        let raw = try required("selected-profile:" + ownerAccount)
        guard try required("selection-attempt:" + ownerAccount) == raw else { throw Failure.invalid }
        let pointer = try JSONDecoder().decode(Pointer.self, from: raw)
        guard pointer.version == 1, pointer.owner == owner else { throw Failure.invalid }
        let binding = try JSONDecoder().decode(Binding.self, from: required("binding:" + pointer.profileID.uuidString))
        guard binding.phase == "receipt-bound", binding.profile == pointer.profileID,
              binding.registry == pointer.registryID, binding.binding == pointer.binding,
              binding.lockIDs.count == 4 else { throw Failure.invalid }
        let locks = try binding.lockIDs.map { row -> Lock in
            guard row.count == 2, let dev = UInt32(exactly: row[0]), row[1] > 0 else { throw Failure.invalid }
            return .init(device: Int32(bitPattern: dev), inode: row[1])
        }
        guard Set(binding.lockIDs).count == 4 else { throw Failure.invalid }
        let journal = try JSONDecoder().decode(Journal.self, from: required("journal:" + pointer.registryID.uuidString))
        guard journal.version == 1, journal.phase == "enrolled", journal.registryID == pointer.registryID,
              journal.binding == pointer.binding, journal.lockDevice == locks[3].device, journal.lockInode == locks[3].inode
        else { throw Failure.invalid }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure.invalid }
        defer { close(rootFD) }
        let profileName = pointer.profileID.uuidString
        let fd = openat(rootFD, profileName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalid }
        defer { close(fd) }
        func verifyInodes() throws {
            var a = stat(), b = stat(), c = stat(), d = stat()
            guard fstat(rootFD, &a) == 0, lstat(root.path, &b) == 0,
                  fstat(fd, &c) == 0, fstatat(rootFD, profileName, &d, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.matches(a, rootLock, type: S_IFDIR), Self.matches(b, rootLock, type: S_IFDIR),
                  Self.matches(c, locks[0], type: S_IFDIR), Self.matches(d, locks[0], type: S_IFDIR)
            else { throw Failure.invalid }
            let ownerName = RaycastStoreProtectedReceiptState.OwnerBinding.lockName
            for (name, lock) in zip([ownerName, "journal.pending.lock", "receipt-authority.lock"], locks.dropFirst()) {
                var file = stat()
                guard fstatat(fd, name, &file, AT_SYMLINK_NOFOLLOW) == 0, file.st_nlink == 1,
                      Self.matches(file, lock, type: S_IFREG) else { throw Failure.invalid }
            }
        }
        try verifyInodes()
        let ownerBinding = RaycastStoreProtectedReceiptState.OwnerBinding(
            profileID: pointer.profileID, rootPath: root.appendingPathComponent(profileName, isDirectory: true).path,
            rootDevice: Int64(locks[0].device), rootInode: locks[0].inode,
            lockDevice: Int64(locks[1].device), lockInode: locks[1].inode
        )
        let anchor = try RaycastStoreProtectedReceiptState(storage: InaccessibleReceiptStore(), registryID: pointer.registryID,
                                                           publicKey: key, recipe: recipe, owner: ownerBinding)
        guard anchor.enrollmentScope.bindingDigest == pointer.binding else { throw Failure.invalid }
        guard try anchor.matchesProtectedBinding(required(pointer.registryID.uuidString)) else { throw Failure.invalid }
        try verifyInodes()
        return .init(profileID: pointer.profileID, scope: anchor.enrollmentScope, receiptLock: locks[3],
                     ownerBinding: ownerBinding)
    }

    private func required(_ account: String) throws -> Data {
        guard let bytes = try read(account), !bytes.isEmpty, bytes.count <= 1_024 else { throw Failure.invalid }
        return bytes
    }

    private static func matches(_ info: stat, _ lock: Lock, type: mode_t) -> Bool {
        info.st_mode & S_IFMT == type && info.st_uid == geteuid() && info.st_mode & 0o077 == 0 &&
            info.st_dev == lock.device && info.st_ino == lock.inode
    }

    private enum Failure: Error { case invalid }
    private struct InaccessibleReceiptStore: RaycastStoreProtectedReceiptStorage {
        func read() throws -> Data? { throw Failure.invalid }
        func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool { throw Failure.invalid }
    }
}
