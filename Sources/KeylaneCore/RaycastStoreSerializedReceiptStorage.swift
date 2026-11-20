import Darwin
import Foundation
import Security

/// An independently protected, already provisioned slot. Only the serialized
/// storage adapter may call replace. A missing slot is never a new-scope signal.
package protocol RaycastStoreProtectedReceiptSlot: Sendable {
    func readExisting() throws -> Data?
    func replaceExisting(with bytes: Data) throws
}

/// Serializes cooperating app processes on one preprovisioned lock inode.
/// Callers must supply one fixed slot, one fixed lock directory, and an
/// app-owned trusted parent. This does not defend against arbitrary privileged
/// processes or another entitled writer bypassing this API. Loss is not setup.
public struct RaycastStoreSerializedReceiptStorage: RaycastStoreProtectedReceiptStorage {
    public enum Failure: Error, Equatable, Sendable {
        case unsafeLock, protectedStateMissing, invalidRecord, protectedStore(OSStatus)
    }

    package struct LockIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t

        package init(device: dev_t, inode: ino_t) {
            self.device = device
            self.inode = inode
        }
    }

    private static let lockName = "receipt-authority.lock"
    private let directory: URL
    private let lockIdentity: LockIdentity
    private let slot: any RaycastStoreProtectedReceiptSlot

    package init(directory: URL, lockIdentity: LockIdentity, slot: any RaycastStoreProtectedReceiptSlot) {
        self.directory = directory
        self.lockIdentity = lockIdentity
        self.slot = slot
    }

    /// No access, entitlement change or provisioning occurs at construction.
    /// Composition must supply an independently fixed app-owned access group
    /// and slot identity, never values read from editable registry contents.
    /// The expected lock identity must likewise come from enrollment, never
    /// be accepted merely because it was observed at the current pathname.
    package init(directory: URL, lockIdentity: LockIdentity, accessGroup: String, service: String, registryID: UUID) {
        self.init(directory: directory, lockIdentity: lockIdentity,
                  slot: KeychainSlot(accessGroup: accessGroup, service: service, registryID: registryID))
    }

    package func matchesEnrollment(directory expected: URL, identity: LockIdentity) -> Bool {
        directory.standardizedFileURL.path == expected.standardizedFileURL.path && lockIdentity == identity
    }

    public func read() throws -> Data? {
        do {
            return try withLock { _, _ in try existingBytes() }
        } catch Failure.protectedStateMissing {
            throw RaycastStoreProtectedReceiptState.Failure.review(.protectedStateMissing)
        }
    }

    public func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool {
        var replacementBegan = false
        do {
            return try withLock { directoryFD, lockFD in
                let actual = try existingBytes()
                // Never initialize or reset, even when the expected value is nil.
                guard actual == expected else { return false }
                guard !replacement.isEmpty, replacement.count <= 1_024 else { throw Failure.invalidRecord }
                try verifyLock(directoryFD, lockFD)
                replacementBegan = true
                try slot.replaceExisting(with: replacement)
                return true
            }
        } catch where replacementBegan {
            // Either the protected store threw after starting, or the post-write
            // lock validation failed. Neither proves that the old head survived.
            throw RaycastStoreProtectedReceiptState.Failure.review(.protectedWriteIndeterminate)
        }
    }

    /// The journal transaction lock is distinct from the protected journal
    /// slot's own CAS lock. Never acquire the same inode recursively.
    package func withExclusiveOperation<T>(excluding storage: Self, _ operation: (@escaping () throws -> Void) throws -> T) throws -> T {
        guard lockIdentity != storage.lockIdentity else { throw Failure.unsafeLock }
        return try withLock { directoryFD, lockFD in
            try operation { try verifyLock(directoryFD, lockFD) }
        }
    }

    private func existingBytes() throws -> Data {
        guard let value = try slot.readExisting() else { throw Failure.protectedStateMissing }
        guard !value.isEmpty, value.count <= 1_024 else { throw Failure.invalidRecord }
        return value
    }

    private func withLock<T>(_ operation: (Int32, Int32) throws -> T) throws -> T {
        let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { throw Failure.unsafeLock }
        defer { close(dirFD) }
        let lockFD = openat(dirFD, Self.lockName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard lockFD >= 0 else { throw Failure.unsafeLock }
        defer { close(lockFD) }
        try verifyLock(dirFD, lockFD)
        guard flock(lockFD, LOCK_EX) == 0 else { throw Failure.unsafeLock }
        defer { flock(lockFD, LOCK_UN) }
        try verifyLock(dirFD, lockFD)
        let result = try operation(dirFD, lockFD)
        try verifyLock(dirFD, lockFD)
        return result
    }

    private func verifyLock(_ dirFD: Int32, _ lockFD: Int32) throws {
        var dir = stat(), namedDir = stat(), file = stat(), namedFile = stat()
        guard fstat(dirFD, &dir) == 0, lstat(directory.path, &namedDir) == 0,
              fstat(lockFD, &file) == 0, fstatat(dirFD, Self.lockName, &namedFile, AT_SYMLINK_NOFOLLOW) == 0,
              Self.privateOwned(dir, type: S_IFDIR), Self.privateOwned(namedDir, type: S_IFDIR),
              Self.privateOwned(file, type: S_IFREG), Self.privateOwned(namedFile, type: S_IFREG),
              file.st_nlink == 1, namedFile.st_nlink == 1,
              dir.st_ino == namedDir.st_ino, dir.st_dev == namedDir.st_dev,
              file.st_ino == namedFile.st_ino, file.st_dev == namedFile.st_dev,
              file.st_ino == lockIdentity.inode, file.st_dev == lockIdentity.device else { throw Failure.unsafeLock }
    }

    private static func privateOwned(_ value: stat, type: mode_t) -> Bool {
        value.st_mode & S_IFMT == type && value.st_uid == geteuid() && value.st_mode & 0o077 == 0
    }

    private struct KeychainSlot: RaycastStoreProtectedReceiptSlot {
        let accessGroup: String
        let service: String
        let registryID: UUID

        private func query() throws -> [String: Any] {
            guard !accessGroup.isEmpty, !service.isEmpty else { throw Failure.invalidRecord }
            return [
                kSecClass as String: kSecClassGenericPassword,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrService as String: service,
                kSecAttrAccount as String: registryID.uuidString,
                kSecAttrSynchronizable as String: false
            ]
        }

        func readExisting() throws -> Data? {
            var query = try query()
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw Failure.protectedStore(status) }
            guard let bytes = result as? Data else { throw Failure.invalidRecord }
            return bytes
        }

        func replaceExisting(with bytes: Data) throws {
            let status = SecItemUpdate(try query() as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
            if status == errSecItemNotFound { throw Failure.protectedStateMissing }
            guard status == errSecSuccess else { throw Failure.protectedStore(status) }
        }
    }
}
