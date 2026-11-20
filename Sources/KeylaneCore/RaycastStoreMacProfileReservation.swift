import CryptoKit
import Darwin
import Foundation
import Security

/// Create-only protected reservations. The production initializer declares the
/// native query but does not query or mutate credentials at construction.
package struct RaycastStoreMacProfileReservation: Sendable {
    package enum Insert: Sendable { case inserted, duplicate }
    package enum Failure: Error { case invalidConfiguration, unsafeRoot, indeterminate, store(OSStatus) }
    package typealias Allocation = RaycastStoreEmptyProfileBootstrap.Allocation
    package typealias Namespace = RaycastStoreEmptyProfileBootstrap.Namespace
    package typealias LockIdentity = RaycastStoreSerializedReceiptStorage.LockIdentity

    package struct Permit: Sendable {
        fileprivate let allocation: Allocation
        fileprivate let root: LockIdentity
        fileprivate let profile: LockIdentity
        fileprivate let backingID: UUID
    }

    package enum Reservation: Sendable { case reserved(Permit), denied, collision }

    private let backingID = UUID()
    private let root: URL
    private let rootIdentity: LockIdentity
    private let authenticate: @Sendable (Data) throws -> UUID?
    private let insert: @Sendable (String, Data) throws -> Insert

    package init(root: URL, rootIdentity: LockIdentity,
                 authenticate: @escaping @Sendable (Data) throws -> UUID?,
                 insert: @escaping @Sendable (String, Data) throws -> Insert) {
        self.root = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent, isDirectory: true).standardizedFileURL
        self.rootIdentity = rootIdentity
        self.authenticate = authenticate
        self.insert = insert
    }

    package init(root: URL, rootIdentity: LockIdentity, accessGroup: String, service: String,
                 authenticate: @escaping @Sendable (Data) throws -> UUID?) {
        self.init(root: root, rootIdentity: rootIdentity, authenticate: authenticate) { account, bytes in
            guard !accessGroup.isEmpty, !service.isEmpty else { throw Failure.invalidConfiguration }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecValueData as String: bytes
            ]
            switch SecItemAdd(query as CFDictionary, nil) {
            case errSecSuccess: return .inserted
            case errSecDuplicateItem: return .duplicate
            case let status: throw Failure.store(status)
            }
        }
    }

    /// Commit a protected, immutable pending record before filesystem side
    /// effects. Duplicate requests do not reopen or read any prior namespace.
    package func reserveNew(_ allocation: Allocation, explicitRequest: Data) throws -> Reservation {
        guard !explicitRequest.isEmpty, explicitRequest.count <= 1_024,
              let requestID = try authenticate(explicitRequest) else { return .denied }
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let profileName = allocation.profileID.uuidString
        let pending = try JSONEncoder().encode(Pending(profile: allocation.profileID, registry: allocation.registryID))
        guard pending.count <= 1_024 else { throw Failure.invalidConfiguration }
        guard try insert("request:" + requestID.uuidString, pending) == .inserted else { return .denied }
        // A second request cannot reopen the same protected profile reservation.
        guard try insert("profile:" + profileName, pending) == .inserted else { return .collision }
        try verifyRoot(rootFD)
        guard mkdirat(rootFD, profileName, S_IRWXU) == 0 else {
            if errno == EEXIST { return .collision }
            throw Failure.indeterminate
        }
        try verifyRoot(rootFD)
        var created = stat()
        guard fstatat(rootFD, profileName, &created, AT_SYMLINK_NOFOLLOW) == 0,
              Self.privateOwned(created, type: S_IFDIR), fsync(rootFD) == 0 else { throw Failure.indeterminate }
        return .reserved(.init(allocation: allocation, root: rootIdentity,
                               profile: .init(device: created.st_dev, inode: created.st_ino), backingID: backingID))
    }

    package struct StagedLocks: Sendable {
        package let profile: LockIdentity
        package let owner: LockIdentity
        package let journal: LockIdentity
        package let receipt: LockIdentity
    }

    /// The staged receipt lock does not occupy the live receipt lock name.
    /// Publication is a separate enrolled adapter operation and must prove
    /// this exact staged inode. No file is truncated, replaced, or removed.
    package func stageOwnedLocks(_ permit: Permit) throws -> StagedLocks {
        guard permit.root == rootIdentity, permit.backingID == backingID else { throw Failure.unsafeRoot }
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let name = permit.allocation.profileID.uuidString
        let fd = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafeRoot }
        defer { close(fd) }
        var profile = stat()
        guard fstat(fd, &profile) == 0, Self.privateOwned(profile, type: S_IFDIR) else { throw Failure.unsafeRoot }
        let identity = LockIdentity(device: profile.st_dev, inode: profile.st_ino)
        guard identity == permit.profile else { throw Failure.unsafeRoot }
        func verifyProfile() throws {
            try verifyRoot(rootFD)
            var named = stat()
            guard fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.privateOwned(named, type: S_IFDIR), named.st_dev == identity.device, named.st_ino == identity.inode
            else { throw Failure.unsafeRoot }
        }
        func create(_ lock: String) throws -> LockIdentity {
            try verifyProfile()
            let lockFD = openat(fd, lock, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard lockFD >= 0 else { throw Failure.indeterminate }
            defer { close(lockFD) }
            var actual = stat(), named = stat()
            guard fstat(lockFD, &actual) == 0, fstatat(fd, lock, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.privateOwned(actual, type: S_IFREG), Self.privateOwned(named, type: S_IFREG),
                  actual.st_nlink == 1, named.st_nlink == 1,
                  actual.st_dev == named.st_dev, actual.st_ino == named.st_ino,
                  fsync(lockFD) == 0 else { throw Failure.indeterminate }
            return .init(device: actual.st_dev, inode: actual.st_ino)
        }
        let owner = try create(RaycastStoreProtectedReceiptState.OwnerBinding.lockName)
        let journal = try create("journal.pending.lock")
        let receipt = try create("receipt.pending.lock")
        try verifyProfile()
        guard fsync(fd) == 0, fsync(rootFD) == 0 else { throw Failure.indeterminate }
        return .init(profile: identity, owner: owner, journal: journal, receipt: receipt)
    }

    /// Supply these callbacks only to the existing protected enrollment
    /// journal. Its exclusive pending transaction is the write authority;
    /// this capability is valid only for this in-memory reservation.
    package struct ReceiptPublication: Sendable {
        package let publishLock: @Sendable () throws -> LockIdentity
        package let publishSlot: @Sendable (Data, LockIdentity) throws -> Void
        package let verifyLock: @Sendable (LockIdentity) throws -> Bool
    }

    package struct FinalizedEnrollment: Sendable {
        package let namespace: Namespace
        package let ownerBinding: RaycastStoreProtectedReceiptState.OwnerBinding
        fileprivate let permit: Permit
        fileprivate let locks: StagedLocks
    }

    /// Mint the finalized scope only from this exact reservation and its
    /// verified staged inodes. The raw allocation cannot publish a receipt.
    package func finalize(permit: Permit, locks: StagedLocks, publicKey: P256.Signing.PublicKey,
                          recipe: RaycastStoreArtifactSeal.Recipe) throws -> FinalizedEnrollment {
        guard permit.root == rootIdentity, permit.backingID == backingID, locks.profile == permit.profile else {
            throw Failure.unsafeRoot
        }
        return try withProfile(permit) { fd, validate in
            try verifyStage(fd, locks, receiptName: "receipt.pending.lock")
            try validate()
            let owner = RaycastStoreProtectedReceiptState.OwnerBinding(profileID: permit.allocation.profileID,
                rootPath: root.appendingPathComponent(permit.allocation.profileID.uuidString, isDirectory: true).path,
                rootDevice: Int64(locks.profile.device), rootInode: locks.profile.inode,
                lockDevice: Int64(locks.owner.device), lockInode: locks.owner.inode)
            let anchor = try RaycastStoreProtectedReceiptState(storage: BindingOnlyStore(),
                registryID: permit.allocation.registryID, publicKey: publicKey, recipe: recipe, owner: owner)
            return .init(namespace: .init(profileID: permit.allocation.profileID, scope: anchor.enrollmentScope),
                         ownerBinding: owner, permit: permit, locks: locks)
        }
    }

    private struct BindingOnlyStore: RaycastStoreProtectedReceiptStorage {
        func read() throws -> Data? { throw Failure.invalidConfiguration }
        func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool { throw Failure.invalidConfiguration }
    }

    package func receiptPublication(_ finalized: FinalizedEnrollment) throws -> ReceiptPublication {
        let (permit, locks) = (finalized.permit, finalized.locks)
        guard permit.root == rootIdentity, permit.backingID == backingID, locks.profile == permit.profile
        else { throw Failure.unsafeRoot }
        let pending = finalized.namespace
        let entry = try JSONEncoder().encode(JournalBinding(pending: pending, locks: locks))
        guard entry.count <= 1_024 else { throw Failure.invalidConfiguration }
        let live = "receipt-authority.lock"
        return .init(publishLock: {
            try withProfile(permit) { profileFD, validateProfile in
                try verifyStage(profileFD, locks, receiptName: "receipt.pending.lock")
                // Durable immutable binding precedes live receipt lock publication.
                guard try insert("binding:" + pending.profileID.uuidString, entry) == .inserted
                else { throw Failure.indeterminate }
                try validateProfile()
                try verifyStage(profileFD, locks, receiptName: "receipt.pending.lock")
                guard renameatx_np(profileFD, "receipt.pending.lock", profileFD, live, UInt32(RENAME_EXCL)) == 0
                else { throw Failure.indeterminate }
                try verifyStage(profileFD, locks, receiptName: live)
                guard fsync(profileFD) == 0 else { throw Failure.indeterminate }
                return locks.receipt
            }
        }, publishSlot: { record, lock in
            guard lock == locks.receipt, !record.isEmpty, record.count <= 1_024,
                  let initial = try? JSONDecoder().decode(InitialReceipt.self, from: record),
                  initial.schema == 1, initial.registryID == pending.scope.registryID,
                  initial.binding == pending.scope.bindingDigest, initial.sequence == 0,
                  initial.previous == nil, initial.head == nil else { throw Failure.invalidConfiguration }
            try withProfile(permit) { profileFD, validateProfile in
                try verifyStage(profileFD, locks, receiptName: live)
                try validateProfile()
                // Account equals the scoped reader account in SerializedReceiptStorage.
                // Duplicate means possible prior publication; never update/adopt.
                guard try insert(pending.scope.registryID.uuidString, record) == .inserted
                else { throw Failure.indeterminate }
                try verifyStage(profileFD, locks, receiptName: live)
            }
        }, verifyLock: { lock in
            guard lock == locks.receipt else { return false }
            try withProfile(permit) { profileFD, _ in
                try verifyStage(profileFD, locks, receiptName: live)
            }
            return true
        })
    }

    private struct InitialReceipt: Decodable {
        let schema: Int
        let registryID: UUID
        let binding: String
        let sequence: UInt64
        let previous: String?
        let head: String?
    }

    private struct JournalBinding: Encodable {
        let phase = "receipt-bound"
        let profile: UUID
        let registry: UUID
        let binding: String
        let lockIDs: [[UInt64]]

        init(pending: Namespace, locks: StagedLocks) {
            profile = pending.profileID
            registry = pending.scope.registryID
            binding = pending.scope.bindingDigest
            lockIDs = [locks.profile, locks.owner, locks.journal, locks.receipt].map {
                [UInt64(UInt32(bitPattern: $0.device)), $0.inode]
            }
        }
    }

    private func withProfile<T>(_ permit: Permit, _ body: (Int32, () throws -> Void) throws -> T) throws -> T {
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let name = permit.allocation.profileID.uuidString
        let profileFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard profileFD >= 0 else { throw Failure.unsafeRoot }
        defer { close(profileFD) }
        func validate() throws {
            try verifyRoot(rootFD)
            var current = stat(), named = stat()
            guard fstat(profileFD, &current) == 0, fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.privateOwned(current, type: S_IFDIR), Self.privateOwned(named, type: S_IFDIR),
                  current.st_dev == permit.profile.device, current.st_ino == permit.profile.inode,
                  named.st_dev == permit.profile.device, named.st_ino == permit.profile.inode
            else { throw Failure.unsafeRoot }
        }
        try validate()
        let result = try body(profileFD, validate)
        try validate()
        return result
    }

    private func verifyStage(_ fd: Int32, _ locks: StagedLocks, receiptName: String) throws {
        let expected = [(RaycastStoreProtectedReceiptState.OwnerBinding.lockName, locks.owner), ("journal.pending.lock", locks.journal), (receiptName, locks.receipt)]
        for (name, identity) in expected {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, Self.privateOwned(info, type: S_IFREG),
                  info.st_nlink == 1, info.st_dev == identity.device, info.st_ino == identity.inode else { throw Failure.unsafeRoot }
        }
    }

    private struct Pending: Encodable {
        let phase = "pending"
        let profile: UUID
        let registry: UUID
    }

    private func openRoot() throws -> Int32 {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafeRoot }
        do { try verifyRoot(fd); return fd }
        catch { close(fd); throw error }
    }

    private func verifyRoot(_ fd: Int32) throws {
        var descriptor = stat(), named = stat()
        guard fstat(fd, &descriptor) == 0, lstat(root.path, &named) == 0,
              Self.privateOwned(descriptor, type: S_IFDIR), Self.privateOwned(named, type: S_IFDIR),
              descriptor.st_dev == rootIdentity.device, descriptor.st_ino == rootIdentity.inode,
              named.st_dev == rootIdentity.device, named.st_ino == rootIdentity.inode else { throw Failure.unsafeRoot }
    }

    private static func privateOwned(_ value: stat, type: mode_t) -> Bool {
        value.st_mode & S_IFMT == type && value.st_uid == geteuid() && value.st_mode & 0o077 == 0
    }
}
