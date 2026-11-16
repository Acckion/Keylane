import Foundation

/// Allocated bytes for a preview item. Only metadata is read.
public struct UninstallItemSize: Equatable, Sendable {
    public let bytes: Int64
    public let complete: Bool

    public static func measure(_ url: URL, cancelled: @escaping () -> Bool) -> Self? {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey,
                                         .isVolumeKey, .isMountTriggerKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard !cancelled() else { return nil }
        let root = URL(fileURLWithPath: url.path)
        var complete = true
        func read(_ url: URL) -> URLResourceValues? {
            guard let values = try? url.resourceValues(forKeys: keys) else {
                complete = false
                return nil
            }
            return values
        }
        func allocatedBytes(_ values: URLResourceValues) -> Int64 {
            guard values.isRegularFile == true else { return 0 }
            guard let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize else {
                complete = false
                return 0
            }
            return Int64(bytes)
        }

        guard let values = read(root), values.isSymbolicLink == false,
              values.isVolume != true, values.isMountTrigger != true else {
            return Self(bytes: 0, complete: false)
        }
        guard values.isDirectory == true else {
            let bytes = allocatedBytes(values)
            return Self(bytes: bytes, complete: complete)
        }
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                           errorHandler: { _, _ in
                                                               complete = false
                                                               return !cancelled()
                                                           }) else { return Self(bytes: 0, complete: false) }
        var bytes: Int64 = 0
        for case let child as URL in entries {
            guard !cancelled() else { return nil }
            guard let values = read(child) else {
                entries.skipDescendants()
                continue
            }
            if values.isVolume == true || values.isMountTrigger == true {
                entries.skipDescendants()
                complete = false
            } else if values.isSymbolicLink == false {
                bytes += allocatedBytes(values)
            }
        }
        return cancelled() ? nil : Self(bytes: bytes, complete: complete)
    }
}
