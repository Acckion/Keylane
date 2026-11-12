import Foundation

public struct FileResultOperations {
    public struct Target {
        public let url: URL
        fileprivate let identity: NSObject
        fileprivate let canonicalPath: String
    }

    public enum Failure: LocalizedError {
        case changed, unsupported, duplicateLimit
        public var errorDescription: String? {
            switch self {
            case .changed: "文件在操作前已移动或被替换。"
            case .unsupported: "无法修改此项目。搜索范围根目录和符号链接仅支持查看。"
            case .duplicateLimit: "没有可用的副本名称。"
            }
        }
    }

    public static func target(for requestedURL: URL) throws -> Target {
        let url = URL(fileURLWithPath: requestedURL.path)
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw Failure.unsupported }
        guard let identity = values.fileResourceIdentifier as? NSObject,
              let canonicalPath = FileSearchLocation.canonicalPath(url.path) else { throw Failure.changed }
        return Target(url: url, identity: identity, canonicalPath: canonicalPath)
    }

    private static func validate(_ target: Target) throws {
        let current = try Self.target(for: target.url)
        guard current.identity == target.identity, current.canonicalPath == target.canonicalPath else { throw Failure.changed }
    }

    public static func duplicate(_ target: Target) throws -> URL {
        try validate(target)
        let files = FileManager.default
        let parent = target.url.deletingLastPathComponent()
        // Publish the copy only after all of its contents have been written.
        let staging = parent.appendingPathComponent(".keylane-copy-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let stagedCopy = staging.appendingPathComponent(target.url.lastPathComponent)
        try files.copyItem(at: target.url, to: stagedCopy)
        let stem = target.url.deletingPathExtension().lastPathComponent
        let ext = target.url.pathExtension
        for index in 1...1000 {
            let suffix = index == 1 ? " 副本" : " 副本 \(index)"
            let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let destination = parent.appendingPathComponent(name)
            do {
                try files.moveItem(at: stagedCopy, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw Failure.duplicateLimit
    }

    @discardableResult
    public static func trash(_ target: Target) throws -> URL? {
        try validate(target)
        var result: NSURL?
        try FileManager.default.trashItem(at: target.url, resultingItemURL: &result)
        return result as URL?
    }
}
