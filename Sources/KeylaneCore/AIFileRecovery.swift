import Foundation
import Darwin

/// Private, persistent journal. It is never a tool-controlled destination and is
/// excluded from general file tools. Payloads remain after uncertain commits.
struct AIFileRecoveryRecord: Codable, Equatable {
    let id: String
    let operation: String
    let created: Date
    let originalRoot: String
    let originalRootIdentity: String
    let originalName: String
    let originalIdentity: String
    var destinationRoot: String?
    var destinationRootIdentity: String?
    var destinationName: String?
    var originalBackup: String?
    var payload: String?
    var savedIdentity: String?
    var savedVersion: String?
    var trashParent: String?
    var trashParentIdentity: String?
    var trashName: String?
    var phase: String
    var mayRecover: Bool {
        !["restored", "not_committed"].contains(phase) &&
            (payload != nil || operation == "keylane_move_file" && savedIdentity != nil || operation == "keylane_trash_file" && savedIdentity == originalIdentity)
    }
}

extension AIFileToolService {
    struct MutationConfiguration: Sendable {
        var afterEffect: @Sendable () throws -> Void = {}
        var recoveryDirectory: URL
        /// Test-only replacement uses a newly owned synthetic directory, never system Trash.
        var trash: @Sendable (URL) throws -> URL
        var rename: @Sendable (Int32, String, Int32, String, UInt32) -> CreationSyscalls.Result
        static let live = Self(recoveryDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keylane/.keylane-ai-recovery", isDirectory: true), trash: { source in
                var destination: NSURL?
                try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
                guard let destination else { throw AIFileToolError.mutationUnconfirmed }
                return destination as URL
            }, rename: { from, name, to, target, flags in
                let code = renameatx_np(from, name, to, target, flags)
                return .init(code: code, error: code == 0 ? 0 : errno)
            })
    }

    /// Both directory and file pins are retained by a prepared recovery operation.
    struct RecoveryPin {
        let parent: FD
        let file: FD
        let parentPath: String
        let name: String
        let version: String
        var authorization: Prepared? = nil
    }

    final class RecoveryVault {
        let path: String
        let directory: FD
        init(_ url: URL, create: Bool, service: isolated AIFileToolService) throws {
            guard url.lastPathComponent == ".keylane-ai-recovery" else { throw AIFileToolError.restricted }
            path = AIFileToolService.systemPath(url.path)
            var parent = try service.openDirectory("/")
            for component in path.split(separator: "/") {
                let name = String(component)
                var child = openat(parent.raw, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT, create {
                    guard mkdirat(parent.raw, name, 0o700) == 0 || errno == EEXIST else { throw AIFileToolError.unavailable }
                    child = openat(parent.raw, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                parent = try FD(child)
            }
            directory = parent
            let info = try service.status(directory)
            guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw AIFileToolError.restricted }
        }
        func validate(service: isolated AIFileToolService) throws {
            guard try service.pathOf(directory) == path,
                  try service.same(service.openDirectory(path), directory) else { throw AIFileToolError.stale }
        }
        func records(enforceStorageBudget: Bool = true, service: isolated AIFileToolService) throws -> [AIFileRecoveryRecord] {
            try validate(service: service)
            // A duplicate descriptor gives this enumeration its own directory offset.
            let scan = openat(directory.raw, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard scan >= 0, let stream = fdopendir(scan) else { if scan >= 0 { close(scan) }; throw AIFileToolError.unavailable }
            defer { closedir(stream) }
            var records: [AIFileRecoveryRecord] = [], visited = 0, payloadBytes: Int64 = 0
            while let entry = readdir(stream) {
                try Task.checkCancellation(); visited += 1
                guard visited <= 2048 else { throw AIFileToolError.tooLarge }
                var raw = entry.pointee.d_name
                let capacity = MemoryLayout.size(ofValue: raw)
                let name = withUnsafePointer(to: &raw) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) } }
                if name.hasSuffix(".json"), let record = try? load(String(name.dropLast(5)), service: service) { records.append(record) }
                if [".payload", ".original", ".displaced"].contains(where: name.hasSuffix) {
                    let file = try service.openChild(directory, name)
                    payloadBytes += try service.status(file).st_size
                }
                guard records.count <= 256, !enforceStorageBudget || payloadBytes <= 268_435_456 else { throw AIFileToolError.tooLarge }
            }
            return records.sorted { $0.created > $1.created }
        }
        func load(_ id: String, service: isolated AIFileToolService) throws -> AIFileRecoveryRecord {
            guard UUID(uuidString: id) != nil else { throw AIFileToolError.invalidPath }
            try validate(service: service)
            let file = try service.openChild(directory, id + ".json"), info = try service.status(file)
            guard service.isRegular(info), info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
                  info.st_size <= 32_768 else { throw AIFileToolError.restricted }
            let data = try service.read(file.raw, offset: 0, count: Int(info.st_size), check: {})
            let record = try JSONDecoder().decode(AIFileRecoveryRecord.self, from: data)
            guard record.id == id, Self.name(record.originalName), record.payload == nil || [id + ".payload", id + ".displaced", id + ".original"].contains(record.payload!),
                  record.originalBackup == nil || record.originalBackup == id + ".original",
                  record.destinationName.map(Self.name) ?? true, record.trashName.map(Self.name) ?? true else { throw AIFileToolError.restricted }
            return record
        }
        func save(_ record: AIFileRecoveryRecord, service: isolated AIFileToolService) throws {
            try validate(service: service)
            let data = try JSONEncoder().encode(record)
            guard data.count <= 32_768 else { throw AIFileToolError.tooLarge }
            let temporary = UUID().uuidString + ".pending"
            let fd = try FD(openat(directory.raw, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
            var complete = false
            defer { if !complete { _ = unlinkat(directory.raw, temporary, 0) } }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd.raw, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw AIFileToolError.unavailable }; offset += count
                }
            }
            guard fsync(fd.raw) == 0 else { throw AIFileToolError.unavailable }
            try validate(service: service)
            guard renameat(directory.raw, temporary, directory.raw, record.id + ".json") == 0 else { throw AIFileToolError.unavailable }
            complete = true
            guard fsync(directory.raw) == 0 else { throw AIFileToolError.unavailable }
        }
        static func name(_ value: String) -> Bool { !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0") && value.utf8.count <= 255 }
    }

    func mutationIdentity(_ info: stat) -> String { "\(info.st_dev):\(info.st_ino)" }
    /// A rename changes ctime; content/identity checks following a move must not
    /// mistake that expected metadata change for new file contents.
    func mutationContentVersion(_ info: stat) -> String {
        "\(mutationIdentity(info)):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_mode):\(info.st_flags)"
    }
    func validateRecovery(_ pin: RecoveryPin) throws {
        if let authorization = pin.authorization { try validate(authorization) }
        guard try pathOf(pin.parent) == pin.parentPath,
              try same(openDirectory(pin.parentPath), pin.parent),
              try same(openChild(pin.parent, pin.name), pin.file),
              mutationContentVersion(try status(pin.file)) == pin.version else { throw AIFileToolError.stale }
    }
}
