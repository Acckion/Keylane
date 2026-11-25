import Darwin
import Foundation

/// Participants share the profile's pinned lock while building. A runtime owner
/// excludes other participants until the host and its last helper have closed it.
final class MacOSStoreOwnership: Sendable {
    let descriptor: Int32

    init(path: URL, device: Int64, inode: UInt64, exclusive: Bool) throws {
        let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MacOSBuildProfile.Failure.unsafeRoot }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1, Int64(info.st_dev) == device, info.st_ino == inode else {
            close(fd)
            throw MacOSBuildProfile.Failure.unsafeRoot
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(fd)
            throw RaycastStoreDiskRegistry.Failure.busy
        }
        descriptor = fd
    }

    deinit {
        // An explicit LOCK_UN would also unlock the inherited description.
        close(descriptor)
    }
}
