import Foundation
import CryptoKit
import Darwin

extension AIFileToolService {
    static let mutationTools: Set<String> = ["keylane_copy_file", "keylane_edit_file", "keylane_replace_file", "keylane_move_file", "keylane_trash_file", "keylane_restore_file", "keylane_file_recovery"]
    struct MutationPlan {
        let tool: String
        let arguments: [String: AIToolValue]
        let destination: Prepared?
        let receipt: AIFileRecoveryRecord?
        let recovery: RecoveryPin?
        let displayArguments: [String: AIToolValue]
        let localSummary: String
    }
    func prepareMutation(_ tool: String, arguments: [String: AIToolValue], scopes: [AIFileToolScope], lease: AIFileAccessLease) throws -> Prepared {
        if tool == "keylane_file_recovery" {
            let roots = try prepare("keylane_file_roots", arguments: [:], scopes: scopes, lease: lease)
            return wrapping(roots, mutation: .init(tool: tool, arguments: arguments, destination: nil, receipt: nil, recovery: nil,
                displayArguments: arguments, localSummary: "仅列出仍在当前授权目录内、由本工具产生的恢复记录；不枚举系统废纸篓。"))
        }
        if tool == "keylane_restore_file" { return try prepareRestore(arguments, scopes: scopes, lease: lease) }
        let source = try prepare("keylane_read_file", arguments: arguments, scopes: scopes, lease: lease)
        guard let file = source.file, isRegular(try status(file)), source.relativePath != "." else { throw AIFileToolError.unsupported }
        // Mutating a movable descendant directory does not grant durable authority
        // over its parent. Users can explicitly authorize that parent as a root.
        if !source.parents.isEmpty { throw AIFileToolError.creationScope }
        if ["keylane_edit_file", "keylane_replace_file"].contains(tool) {
            let format = (source.relativePath as NSString).pathExtension.lowercased()
            guard !["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "rtf", "rtfd", "epub"].contains(format) else { throw AIFileToolError.unsupported }
        }
        let expected = string(arguments, "expected_revision")
        guard !expected.isEmpty, expected == source.fileRevision else { throw AIFileToolError.stale }
        var destination: Prepared?
        if ["keylane_copy_file", "keylane_move_file"].contains(tool) {
            destination = try prepare("keylane_write_file", arguments: ["root": .string(string(arguments, "destination_root").isEmpty ? source.rootID : string(arguments, "destination_root")), "path": .string(string(arguments, "destination_path"))], scopes: scopes, lease: lease)
            guard destination!.parents.isEmpty else { throw AIFileToolError.creationScope }
            guard try status(file).st_dev == status(destination!.roots[0].fd).st_dev else { throw AIFileToolError.mutationUnsupported }
        }
        if tool == "keylane_edit_file" {
            if let supplied = arguments["occurrences"] {
                guard case .number(let count) = supplied, count.isFinite, count.rounded() == count, (1...100).contains(count) else { throw AIFileToolError.invalidText }
            }
            guard case .string = arguments["new_text"], !string(arguments, "old_text").isEmpty, string(arguments, "old_text").utf8.count <= 12_000,
                  string(arguments, "new_text").utf8.count <= 12_000,
                  (1...100).contains(integer(arguments, "occurrences", default: 1)) else { throw AIFileToolError.invalidText }
        }
        if tool == "keylane_replace_file" {
            guard case .string(let content) = arguments["content"], content.utf8.count <= 12_000 else { throw AIFileToolError.tooLarge }
        }
        var display = source.displayArguments
        if let destination { display["destination_root"] = .string(destination.rootID); display["destination_path"] = .string(destination.relativePath) }
        let localDestination = destination.map { "\n目标（仅本机）：" + String(reflecting: $0.localTarget) } ?? ""
        return wrapping(source, mutation: .init(tool: tool, arguments: arguments, destination: destination, receipt: nil, recovery: nil,
            displayArguments: display, localSummary: "操作普通文件；目标冲突拒绝。编辑使用原子交换并保留旧版；移动/废纸篓保留恢复记录。原生协调不约束不合作的外部程序：最后核对后仍可能有并发变动，结果不确定时可能已发生改动，勿自动重试或回滚。" + localDestination))
    }

    private func prepareRestore(_ arguments: [String: AIToolValue], scopes: [AIFileToolScope], lease: AIFileAccessLease) throws -> Prepared {
        let vault = try RecoveryVault(mutationConfiguration.recoveryDirectory, create: false, service: self)
        let receipt = try vault.load(string(arguments, "recovery_id"), service: self)
        guard receipt.phase != "restored" else { throw AIFileToolError.stale }
        guard let scopeIndex = scopes.firstIndex(where: { Self.systemPath($0.path) == receipt.originalRoot }) else { throw AIFileToolError.outsideScope }
        let rootID = "root_\(scopeIndex + 1)", replace = arguments["replace_edited_file"] == .bool(true)
        let name = string(arguments, "destination_path").isEmpty ? receipt.originalName : string(arguments, "destination_path")
        guard RecoveryVault.name(name) else { throw AIFileToolError.invalidPath }
        let destination = try prepare(replace ? "keylane_read_file" : "keylane_write_file", arguments: ["root": .string(rootID), "path": .string(name)], scopes: scopes, lease: lease)
        guard mutationIdentity(try status(destination.roots[0].fd)) == receipt.originalRootIdentity else { throw AIFileToolError.stale }
        if replace {
            guard ["keylane_edit_file", "keylane_replace_file", "keylane_restore_file"].contains(receipt.operation), name == receipt.originalName,
                  string(arguments, "expected_revision") == destination.fileRevision, destination.file != nil else { throw AIFileToolError.stale }
        }
        let recovery: RecoveryPin
        if let payload = receipt.payload {
            let file = try openChild(vault.directory, payload), info = try status(file)
            // A prepared journal whose swap never happened still contains the NEW
            // data, not an old version. Never offer that as successful recovery.
            guard mutationIdentity(info) == (receipt.savedIdentity ?? receipt.originalIdentity) else { throw AIFileToolError.stale }
            recovery = .init(parent: vault.directory, file: file, parentPath: vault.path, name: payload, version: mutationContentVersion(info))
        } else if receipt.operation == "keylane_trash_file", let parent = receipt.trashParent, let name = receipt.trashName {
            let directory = try openDirectory(parent), file = try openChild(directory, name), info = try status(file)
            let parentIdentity = mutationIdentity(try status(directory))
            guard receipt.trashParentIdentity == nil || parentIdentity == receipt.trashParentIdentity,
                  mutationIdentity(info) == receipt.savedIdentity, receipt.savedIdentity == receipt.originalIdentity else { throw AIFileToolError.stale }
            recovery = .init(parent: directory, file: file, parentPath: parent, name: name, version: mutationContentVersion(info))
        } else if receipt.operation == "keylane_move_file", let root = receipt.destinationRoot, let name = receipt.destinationName,
                  let index = scopes.firstIndex(where: { Self.systemPath($0.path) == root }) {
            let moved = try prepare("keylane_read_file", arguments: ["root": .string("root_\(index + 1)"), "path": .string(name)], scopes: scopes, lease: lease)
            guard let file = moved.file, mutationIdentity(try status(moved.roots[0].fd)) == receipt.destinationRootIdentity,
                  mutationIdentity(try status(file)) == receipt.savedIdentity else { throw AIFileToolError.stale }
            recovery = .init(parent: moved.roots[0].fd, file: file, parentPath: root, name: name, version: mutationContentVersion(try status(file)), authorization: moved)
        } else { throw AIFileToolError.unavailable }
        if let expected = receipt.savedVersion, recovery.version != expected { throw AIFileToolError.stale }
        guard isRegular(try status(recovery.file)), try status(recovery.file).st_nlink == 1 else { throw AIFileToolError.unsupported }
        return wrapping(destination, mutation: .init(tool: "keylane_restore_file", arguments: arguments, destination: nil, receipt: receipt, recovery: recovery,
            displayArguments: arguments.merging(["root": .string(destination.rootID), "path": .string(destination.relativePath)]) { _, actual in actual },
            localSummary: replace ? "恢复此前编辑的旧版到原件，当前文件将作为新的可恢复版本保留。并发变化可能造成结果无法确认，不自动重试或回滚。" : "仅恢复本工具此前保存或移走的普通文件；目标已存在则拒绝，不扫描整个系统废纸篓。"))
    }

    private func mutationRootsCurrent(_ plan: Prepared) throws {
        for root in plan.roots {
            try policy(root.path)
            guard try pathOf(root.fd) == root.path, try same(openDirectory(root.path), root.fd) else { throw AIFileToolError.stale }
        }
    }
    private func result(_ values: [String: AIToolValue], error: Bool = false) throws -> AIToolResult {
        try .init(text: String(decoding: JSONEncoder().encode(values), as: UTF8.self), isError: error)
    }
    private func checkNativeMutation(_ value: CreationSyscalls.Result) throws {
        guard value.code == 0 else {
            if value.error == EEXIST { throw AIFileToolError.exists }
            if [ENOTSUP, EOPNOTSUPP, EXDEV, ENOSYS, EINVAL].contains(value.error) { throw AIFileToolError.mutationUnsupported }
            throw AIFileToolError.mutationUnconfirmed
        }
    }

    func executeMutation(_ plan: Prepared, lease: AIFileAccessLease, cancellation: AIFileAccessLease) throws -> AIToolResult {
        guard plan.lease === lease, let mutation = plan.mutation else { throw AIFileToolError.stale }
        func check() throws { try lease.check(); try cancellation.check() }
        try check()
        if mutation.tool == "keylane_file_recovery" {
            try mutationRootsCurrent(plan)
            guard FileManager.default.fileExists(atPath: mutationConfiguration.recoveryDirectory.path) else { return try result(["records": .array([])]) }
            let vault = try RecoveryVault(mutationConfiguration.recoveryDirectory, create: false, service: self)
            let all = try vault.records(enforceStorageBudget: false, service: self)
            var rows: [AIToolValue] = []
            for record in all {
                try check()
                guard let root = plan.roots.first(where: { $0.path == record.originalRoot }), mutationIdentity(try status(root.fd)) == record.originalRootIdentity else { continue }
                var row: [String: AIToolValue] = ["operation_id": .string(record.id), "operation": .string(record.operation), "root": .string(root.id),
                    "path": .string(record.originalName), "status": .string(record.phase), "created": .string(record.created.ISO8601Format())]
                if record.mayRecover { row["recovery_id"] = .string(record.id) }
                rows.append(.object(row))
            }
            let offset = integer(mutation.arguments, "offset", default: 0), limit = integer(mutation.arguments, "limit", default: 20)
            guard offset <= rows.count, (1...20).contains(limit) else { throw AIFileToolError.invalidPath }
            try check(); try mutationRootsCurrent(plan)
            return try result(["records": .array(Array(rows.dropFirst(offset).prefix(limit))), "next_offset": offset + limit < rows.count ? .number(Double(offset + limit)) : .null])
        }
        try validate(plan)
        if mutation.tool == "keylane_trash_file", let file = plan.file {
            let home = try openDirectory(FileManager.default.homeDirectoryForCurrentUser.path)
            guard try status(home).st_dev == status(file).st_dev else { throw AIFileToolError.mutationUnsupported }
        }
        if let receipt = mutation.receipt {
            let existing = try RecoveryVault(mutationConfiguration.recoveryDirectory, create: false, service: self).load(receipt.id, service: self)
            guard existing == receipt else { throw AIFileToolError.stale }
        }
        if let destination = mutation.destination { try validate(destination) }
        if let recovery = mutation.recovery { try validateRecovery(recovery) }
        let vault = try RecoveryVault(mutationConfiguration.recoveryDirectory, create: true, service: self)
        let isRestore = mutation.tool == "keylane_restore_file"
        let replace = mutation.tool == "keylane_edit_file" || mutation.tool == "keylane_replace_file" || mutation.arguments["replace_edited_file"] == .bool(true)
        // Exporting an existing backup to an absent name remains possible when
        // the storage quota is full. It creates no new private payload.
        if !isRestore || replace {
            let records = try vault.records(service: self)
            guard records.count < 256, records.filter(\.mayRecover).count < 64 || isRestore else { throw AIFileToolError.tooLarge }
        }
        let root = plan.roots[0], sourceInfo = try plan.file.map { try status($0) }
        var receipt = AIFileRecoveryRecord(id: UUID().uuidString, operation: mutation.tool, created: Date(), originalRoot: root.path,
            originalRootIdentity: mutationIdentity(try status(root.fd)), originalName: plan.relativePath,
            originalIdentity: sourceInfo.map(mutationIdentity) ?? "", phase: "prepared")
        var effectAttempted = false
        var staged: FD?
        var originalDigest: Data?
        var originalBackupPin: FD?
        var displacedIdentity: String?
        func commitNative(_ value: CreationSyscalls.Result) throws {
            if value.code != 0, [EEXIST, ENOTSUP, EOPNOTSUPP, EXDEV, ENOSYS, EINVAL].contains(value.error) { effectAttempted = false }
            try checkNativeMutation(value)
        }
        do {
            if replace {
                guard let original = plan.file, let sourceInfo, sourceInfo.st_size <= 1_048_576 else { throw AIFileToolError.tooLarge }
                let originalData = try read(original.raw, offset: 0, count: Int(sourceInfo.st_size), check: check)
                guard let originalText = String(data: originalData, encoding: .utf8), !originalText.contains("\0") else { throw AIFileToolError.invalidText }
                originalDigest = Data(SHA256.hash(data: originalData))
                let data: Data
                if isRestore {
                    guard let recovery = mutation.recovery else { throw AIFileToolError.stale }
                    let size = try status(recovery.file).st_size
                    guard size <= 1_048_576 else { throw AIFileToolError.tooLarge }
                    data = try read(recovery.file.raw, offset: 0, count: Int(size), check: check)
                } else if mutation.tool == "keylane_replace_file" { data = Data(string(mutation.arguments, "content").utf8) }
                else {
                    let text = originalText
                    let needle = string(mutation.arguments, "old_text"), parts = text.components(separatedBy: needle)
                    guard parts.count - 1 == integer(mutation.arguments, "occurrences", default: 1) else { throw AIFileToolError.editMismatch }
                    data = Data(parts.joined(separator: string(mutation.arguments, "new_text")).utf8)
                }
                guard data.count <= 1_048_576 else { throw AIFileToolError.tooLarge }
                guard !data.contains(0) else { throw AIFileToolError.invalidText }
                try check(); try validate(plan)
                guard try status(vault.directory).st_dev == sourceInfo.st_dev else { throw AIFileToolError.mutationUnsupported }
                let payload = receipt.id + ".payload"
                try checkNativeMutation(creationSyscalls.cloneFile(original.raw, vault.directory.raw, payload))
                let stage = try FD(openat(vault.directory.raw, payload, O_RDWR | O_NOFOLLOW | O_CLOEXEC))
                staged = stage; receipt.payload = payload
                let originalBackup = receipt.id + ".original"
                try checkNativeMutation(creationSyscalls.cloneFile(stage.raw, vault.directory.raw, originalBackup))
                let expectedBackup = try openChild(vault.directory, originalBackup)
                originalBackupPin = expectedBackup
                let backupData = try read(expectedBackup.raw, offset: 0, count: Int(sourceInfo.st_size), check: check)
                guard Data(SHA256.hash(data: backupData)) == originalDigest else { throw AIFileToolError.stale }
                guard fsync(expectedBackup.raw) == 0 else { throw AIFileToolError.unavailable }
                receipt.originalBackup = originalBackup
                guard isRegular(try status(stage)), try status(stage).st_nlink == 1 else { throw AIFileToolError.unsupported }
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        try check()
                        let count = pwrite(stage.raw, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                        guard count > 0 else { throw AIFileToolError.unavailable }; offset += count
                    }
                }
                guard ftruncate(stage.raw, off_t(data.count)) == 0, fsync(stage.raw) == 0 else { throw AIFileToolError.unavailable }
            }
            if let destination = mutation.destination {
                receipt.destinationRoot = destination.localRoot; receipt.destinationName = destination.relativePath
                receipt.destinationRootIdentity = mutationIdentity(try status(destination.roots[0].fd))
            }
            try vault.save(receipt, service: self)
            let sourceURL = URL(fileURLWithPath: plan.localTarget)
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?, actionError: Error?
            let operation = {
                do {
                    try check(); try self.beforeCommit()
                    try lease.withValidAccess { try cancellation.withValidAccess {
                        try self.validate(plan); try vault.validate(service: self)
                        if let destination = mutation.destination { try self.validate(destination) }
                        if let recovery = mutation.recovery { try self.validateRecovery(recovery) }
                        if let previous = mutation.receipt { guard try vault.load(previous.id, service: self) == previous else { throw AIFileToolError.stale } }
                        effectAttempted = true
                        switch mutation.tool {
                        case "keylane_copy_file":
                            guard let source = plan.file, let destination = mutation.destination, let size = sourceInfo?.st_size, size <= 67_108_864 else { effectAttempted = false; throw AIFileToolError.tooLarge }
                            try commitNative(self.creationSyscalls.cloneFile(source.raw, destination.roots[0].fd.raw, destination.relativePath))
                        case "keylane_edit_file", "keylane_replace_file":
                            try commitNative(self.mutationConfiguration.rename(vault.directory.raw, receipt.payload!, root.fd.raw, plan.relativePath, UInt32(RENAME_SWAP)))
                        case "keylane_move_file":
                            let destination = mutation.destination!
                            try commitNative(self.mutationConfiguration.rename(root.fd.raw, plan.relativePath, destination.roots[0].fd.raw, destination.relativePath, UInt32(RENAME_EXCL)))
                        case "keylane_trash_file":
                            let moved = try self.mutationConfiguration.trash(sourceURL)
                            let parentPath = Self.systemPath(moved.deletingLastPathComponent().path), name = moved.lastPathComponent
                            receipt.trashParent = parentPath; receipt.trashName = name
                            // Trashing a file need not grant enumeration access to
                            // the whole system Trash. Verify the exact original FD
                            // moved to the returned URL, without opening that folder.
                            guard let original = plan.file, try self.pathOf(original) == Self.systemPath(moved.path) else { throw AIFileToolError.mutationUnconfirmed }
                            let info = try self.status(original)
                            receipt.savedIdentity = self.mutationIdentity(info); receipt.savedVersion = self.mutationContentVersion(info)
                            if let parent = try? self.openDirectory(parentPath) { receipt.trashParentIdentity = self.mutationIdentity(try self.status(parent)) }
                        case "keylane_restore_file":
                            let recovery = mutation.recovery!
                            if replace {
                                try commitNative(self.mutationConfiguration.rename(vault.directory.raw, receipt.payload!, root.fd.raw, plan.relativePath, UInt32(RENAME_SWAP)))
                            } else if mutation.receipt?.payload != nil {
                                try commitNative(self.creationSyscalls.cloneFile(recovery.file.raw, root.fd.raw, plan.relativePath))
                            } else {
                                try commitNative(self.mutationConfiguration.rename(recovery.parent.raw, recovery.name, root.fd.raw, plan.relativePath, UInt32(RENAME_EXCL)))
                            }
                        default: throw AIFileToolError.unsupported
                        }
                    } }
                } catch { actionError = error }
            }
            if let destination = mutation.destination {
                coordinator.coordinate(writingItemAt: sourceURL, options: mutation.tool == "keylane_move_file" ? .forMoving : [], writingItemAt: URL(fileURLWithPath: destination.localTarget), options: [], error: &coordinationError) { from, to in
                    guard Self.systemPath(from.path) == plan.localTarget, Self.systemPath(to.path) == destination.localTarget else { actionError = AIFileToolError.stale; return }; operation()
                }
            } else {
                coordinator.coordinate(writingItemAt: sourceURL, options: mutation.tool == "keylane_trash_file" ? .forDeleting : .forReplacing, error: &coordinationError) { url in
                    guard Self.systemPath(url.path) == plan.localTarget else { actionError = AIFileToolError.stale; return }; operation()
                }
            }
            if let actionError { throw actionError }
            if let coordinationError { throw coordinationError }
            guard effectAttempted else { throw AIFileToolError.unavailable }
            try mutationConfiguration.afterEffect()
            // Record the actual recoverable object before checking the mutation's
            // final state, so an uncertain swap never deletes an unexpected old file.
            if let payload = receipt.payload {
                let saved = try openChild(vault.directory, payload), info = try status(saved)
                displacedIdentity = mutationIdentity(info)
                guard displacedIdentity == receipt.originalIdentity, info.st_nlink == 1 else {
                    // Preserve the unexpected displaced object but never turn it
                    // into an AI-readable recovery capability. Offer only the
                    // verified pre-edit backup, not the foreign inode.
                    if let originalBackupPin {
                        receipt.payload = receipt.originalBackup
                        receipt.savedIdentity = mutationIdentity(try status(originalBackupPin))
                        receipt.savedVersion = mutationContentVersion(try status(originalBackupPin))
                    }
                    throw AIFileToolError.mutationUnconfirmed
                }
                receipt.savedIdentity = displacedIdentity; receipt.savedVersion = mutationContentVersion(info)
                guard info.st_size <= 1_048_576 else { throw AIFileToolError.mutationUnconfirmed }
                // Freeze the displaced inode too: an uncoordinated writer may still
                // hold its old descriptor after SWAP. Both prior copies remain.
                let frozenName = receipt.id + ".displaced"
                try checkNativeMutation(creationSyscalls.cloneFile(saved.raw, vault.directory.raw, frozenName))
                let frozen = try openChild(vault.directory, frozenName), frozenInfo = try status(frozen)
                guard fsync(frozen.raw) == 0 else { throw AIFileToolError.unavailable }
                receipt.payload = frozenName
                receipt.savedIdentity = mutationIdentity(frozenInfo); receipt.savedVersion = mutationContentVersion(frozenInfo)
                let displacedData = try read(frozen.raw, offset: 0, count: Int(frozenInfo.st_size), check: {})
                if Data(SHA256.hash(data: displacedData)) != originalDigest { throw AIFileToolError.mutationUnconfirmed }
            }
            receipt.phase = "unconfirmed"; try vault.save(receipt, service: self)
            try check(); try mutationRootsCurrent(plan)
            if let destination = mutation.destination { try mutationRootsCurrent(destination) }
            if replace {
                guard let staged, displacedIdentity == receipt.originalIdentity,
                      try same(openChild(root.fd, plan.relativePath), staged) else { throw AIFileToolError.mutationUnconfirmed }
            } else if mutation.tool == "keylane_copy_file" {
                try validate(plan)
                let destination = mutation.destination!, file = try openChild(destination.roots[0].fd, destination.relativePath)
                guard isRegular(try status(file)), try status(file).st_size == sourceInfo?.st_size else { throw AIFileToolError.mutationUnconfirmed }
            } else if mutation.tool == "keylane_move_file" {
                let destination = mutation.destination!, file = try openChild(destination.roots[0].fd, destination.relativePath)
                guard try same(file, plan.file!) else { throw AIFileToolError.mutationUnconfirmed }
                try absent(root.fd, plan.relativePath)
                receipt.savedIdentity = mutationIdentity(try status(file)); receipt.savedVersion = mutationContentVersion(try status(file))
            } else if mutation.tool == "keylane_trash_file" {
                guard receipt.savedIdentity == receipt.originalIdentity else { throw AIFileToolError.mutationUnconfirmed }
                if let sourceInfo, let file = plan.file, mutationContentVersion(try status(file)) != mutationContentVersion(sourceInfo) { throw AIFileToolError.mutationUnconfirmed }
                try absent(root.fd, plan.relativePath)
            } else if isRestore {
                if mutation.receipt?.payload != nil { try validateRecovery(mutation.recovery!) }
                let restored = try openChild(root.fd, plan.relativePath)
                guard isRegular(try status(restored)) else { throw AIFileToolError.mutationUnconfirmed }
                if mutation.receipt?.payload == nil { guard try same(restored, mutation.recovery!.file) else { throw AIFileToolError.mutationUnconfirmed } }
            }
            for directory in plan.roots.map(\.fd) + (mutation.destination?.roots.map(\.fd) ?? []) {
                guard fsync(directory.raw) == 0 else { throw AIFileToolError.unavailable }
            }
            receipt.phase = "completed"; try vault.save(receipt, service: self)
            if isRestore, var previous = mutation.receipt { previous.phase = "restored"; try vault.save(previous, service: self) }
            var values: [String: AIToolValue] = ["root": .string(plan.rootID), "path": .string(plan.relativePath), "completed": .bool(true), "operation_id": .string(receipt.id)]
            if receipt.mayRecover { values["recovery_id"] = .string(receipt.id) }
            if let destination = mutation.destination { values["destination_root"] = .string(destination.rootID); values["destination_path"] = .string(destination.relativePath) }
            if replace || isRestore { values["revision"] = .string(revision(try status(openChild(root.fd, plan.relativePath)))) }
            return try result(values)
        } catch {
            // Known no-effect errors from EXCL/SWAP may be retried only via a new
            // preparation/approval. Unknown errors and cancellation preserve state.
            receipt.phase = effectAttempted ? "unconfirmed" : "not_committed"
            try? vault.save(receipt, service: self)
            if effectAttempted { return try result(["error": .string(AIFileToolError.mutationUnconfirmed.localizedDescription), "operation_id": .string(receipt.id), "recovery_id": receipt.mayRecover ? .string(receipt.id) : .null], error: true) }
            throw error
        }
    }
}
