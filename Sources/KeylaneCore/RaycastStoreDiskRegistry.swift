import Foundation
import CryptoKit
import Darwin

/// Implemented only by the app-owned signed build verifier, never catalog metadata.
/// A matching caller digest alone does not establish trusted build provenance.
public protocol RaycastStoreArtifactTrust: Sendable {
    func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription
    /// Terminate/revoke every session older than generation before activation/removal.
    /// Synchronously invalidate live leases under the registry filesystem lock,
    /// before advancing the protected receipt or yielding to the broker.
    func verifyRegistryAccess() throws
    func quarantine(installationID: UUID, before generation: UInt64) throws
    func revoke(installationID: UUID, before generation: UInt64) async throws
}
extension RaycastStoreArtifactTrust {
    public func verifyRegistryAccess() throws {}
    public func quarantine(installationID: UUID, before generation: UInt64) throws {}
}
public struct RaycastStoreTrustedDescription: Sendable {
    public let extensionID: String
    public let manifest: RaycastExtensionManifest
    public let requiredCapabilities: Set<String>
    // Core verifier factory owns creation; tests use @testable controlled fixtures.
    init(extensionID: String, manifest: RaycastExtensionManifest, requiredCapabilities: Set<String>) {
        self.extensionID = extensionID; self.manifest = manifest; self.requiredCapabilities = requiredCapabilities
    }
}

/// App-owned, durable compare-and-swap authority, stored outside the registry
/// directory. It must distinguish a new registry from deletion or rollback and
/// never accept a value merely because it was read from the registry file.
public protocol RaycastStoreRegistryAnchor: Sendable {
    func verify(expectedDigest: String?) throws
    func advance(previousDigest: String?, to nextDigest: String) throws
}

/// Injected persistence seam, not the default backend and not a runtime launcher.
/// Only app-owned paths are accepted by the composition root. Ordinary preferences
/// share the anchored transaction; secrets never enter it. Use disposable test roots.
public actor RaycastStoreDiskRegistry {
    public enum Failure: Error, Equatable, Sendable {
        case busy, corrupt, limit, integrity, identity, capability, stale, inactive, missing, anchor, io, preference
        case protectedStateRecovery(RaycastStoreProtectedReceiptState.Recovery)
    }
    /// Opaque signed envelope bytes for the app-owned runner. This is not a durable
    /// authorization: runner capability and generation checks must be repeated at dispatch.
    public struct LaunchArtifact: Sendable {
        public let source: RaycastStoreSource
        public let digest: String
        public let bytes: Data
    }
    private struct OrdinaryPreference: Codable {
        let command: String?
        let name: String
        let value: RaycastExtensionManifest.PreferenceValue

        var key: RaycastStorePreferenceKey {
            .init(scope: command.map { .command($0) } ?? .extensionWide, name: name)
        }
    }

    private enum Phase: String, Codable { case prepared, active, pending }
    private struct Record: Codable {
        var id: UUID; var slug: String; var revision: String; var digest: String
        var bytes: Data; var grants: Set<String>; var generation: UInt64
        var enabled: Bool; var phase: Phase
        var preferences: [OrdinaryPreference]? = nil
        var baseGeneration: UInt64? = nil
        var baseEnabled: Bool? = nil
        var source: RaycastStoreSource { get throws { try .init(slug: slug, catalog: .init(revision: revision, slugs: [slug])) } }
    }
    private struct State: Codable { var version = 1; var records: [Record] = []; var candidates: [Record]? = nil }
    private let root: URL
    private let trust: any RaycastStoreArtifactTrust
    private let anchor: (any RaycastStoreRegistryAnchor)?
    // Accessed only inside the locked filesystem transaction.
    private var verifiedStateDigest: String?

    public init(root: URL, trust: any RaycastStoreArtifactTrust, anchor: (any RaycastStoreRegistryAnchor)? = nil) throws {
        try self.init(root: root, trust: trust, anchor: anchor, requiresExistingRoot: false)
    }

    package init(root: URL, trust: any RaycastStoreArtifactTrust, anchor: (any RaycastStoreRegistryAnchor)?,
                 requiresExistingRoot: Bool) throws {
        // Caller selects app-owned location; resolving it does not grant arbitrary
        // writes. No default Application Support or Keychain path is created.
        self.root = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent, isDirectory: true).standardizedFileURL
        self.trust = trust
        self.anchor = anchor
        if !requiresExistingRoot {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(self.root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.io }
        if anchor != nil {
            guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.io }
        }
    }
    /// App bootstrap is a snapshot, not a launch grant. Do not create a
    /// lock or write state just to determine whether the existing profile is usable.
    package func verifyExistingProtectedRegistry() throws {
        guard anchor != nil else { throw Failure.anchor }
        _ = try read(rememberVerifiedState: false)
    }

    private func lock() throws -> Int32 {
        try trust.verifyRegistryAccess()
        let fd = open(root.appendingPathComponent("registry.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.io }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); throw Failure.io }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure.busy }
        return fd
    }
    private func unlock(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }
    private func read(rememberVerifiedState: Bool = true) throws -> State {
        try trust.verifyRegistryAccess()
        let path = root.appendingPathComponent("registry.json").path
        // Check metadata first: on restricted macOS executors, a read-open of a
        // missing path may return EPERM. Only a confirmed absence initializes state.
        var info = stat()
        let (exists, statError) = path.withCString { cPath in
            let result = lstat(cPath, &info)
            return (result == 0, errno)
        }
        if !exists {
            if statError == ENOENT {
                try verifyStateDigest(nil, remember: rememberVerifiedState)
                return State()
            }
            throw POSIXError(POSIXErrorCode(rawValue: statError) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.io }
        let (fd, openError) = path.withCString { cPath in
            let descriptor = open(cPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            return (descriptor, errno)
        }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: openError) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 64 * 1024 * 1024 else { throw Failure.limit }
        let bytes = try handle.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 64 * 1024 * 1024 else { throw Failure.limit }
        try verifyStateDigest(anchor == nil ? nil : Self.digest(bytes), remember: rememberVerifiedState)
        return try decode(bytes)
    }
    private func decode(_ bytes: Data) throws -> State {
        guard let state = try? JSONDecoder().decode(State.self, from: bytes), state.version == 1,
              state.records.count <= 128,
              Set(state.records.map(\.id)).count == state.records.count,
              Set(state.records.map { $0.slug.lowercased() }).count == state.records.count else { throw Failure.corrupt }
        for record in state.records {
            guard record.baseGeneration == nil, record.baseEnabled == nil else { throw Failure.corrupt }
            _ = try verified(record)
        }
        let candidates = state.candidates ?? []
        guard candidates.count <= 128, Set(candidates.map(\.id)).count == candidates.count,
              Set(candidates.map(\.slug)).count == candidates.count else { throw Failure.corrupt }
        for record in candidates {
            guard record.phase == .prepared, let base = record.baseGeneration, base > 0, record.baseEnabled != nil,
                  state.records.contains(where: { $0.id == record.id && $0.slug == record.slug && $0.phase != .prepared && $0.generation >= base }) else { throw Failure.corrupt }
            _ = try verified(record)
        }
        return state
    }
    private func write(_ state: State) throws {
        try trust.verifyRegistryAccess()
        let data = try JSONEncoder().encode(state)
        guard data.count <= 64 * 1024 * 1024, state.records.count <= 128 else { throw Failure.limit }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.io }; defer { close(directory) }
        let fd = openat(directory, "registry.pending", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io }
        var authorityBegan = false, published = false
        defer {
            close(fd)
            if !authorityBegan && !published { unlinkat(directory, "registry.pending", 0) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }; offset += count
            }
        }
        guard fsync(fd) == 0, fsync(directory) == 0 else { throw Failure.io }
        if let anchor {
            let digest = Self.digest(data)
            // Advance the independent authority FIRST. If the disk replacement is
            // interrupted, fail closed on the mismatch rather than restoring a
            // stale enabled generation. Explicit repair is outside the Store UI.
            authorityBegan = true
            do { try anchor.advance(previousDigest: verifiedStateDigest, to: digest) }
            catch RaycastStoreProtectedReceiptState.Failure.review(let recovery) { throw Failure.protectedStateRecovery(recovery) }
            catch { throw Failure.anchor }
        }
        guard renameat(directory, "registry.pending", directory, "registry.json") == 0,
              fsync(directory) == 0 else { throw Failure.io }
        published = true; verifiedStateDigest = anchor == nil ? nil : Self.digest(data)
    }

    public enum PublicationRecovery: Sendable, Equatable { case nothing, completed, discardedUncommitted }
    /// Complete only a durable candidate already named by the independent head,
    /// or discard an uncommitted candidate when the old head is independently
    /// verified. Never adopt a missing anchor or roll back a committed generation.
    public func recoverPendingPublication() throws -> PublicationRecovery {
        guard let anchor else { throw Failure.anchor }
        let lockFD = try lock(); defer { unlock(lockFD) }
        func bytes(_ name: String) throws -> Data? {
            let path = root.appendingPathComponent(name).path
            var info = stat()
            if lstat(path, &info) != 0 { if errno == ENOENT { return nil }; throw Failure.io }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
                  opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1, opened.st_uid == geteuid(),
                  opened.st_size <= 64 * 1024 * 1024 else { throw Failure.io }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let body = try file.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
            guard body.count <= 64 * 1024 * 1024 else { throw Failure.limit }; return body
        }
        guard let pending = try bytes("registry.pending") else { _ = try read(); return .nothing }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.io }; defer { close(directory) }
        let committed: Bool
        do { try anchor.verify(expectedDigest: Self.digest(pending)); committed = true } catch { committed = false }
        if committed {
            _ = try decode(pending); try trust.verifyRegistryAccess()
            guard renameat(directory, "registry.pending", directory, "registry.json") == 0, fsync(directory) == 0 else { throw Failure.io }
            _ = try read(); return .completed
        }
        let live = try bytes("registry.json")
        try anchor.verify(expectedDigest: live.map(Self.digest))
        if let live { _ = try decode(live) }
        try trust.verifyRegistryAccess()
        guard unlinkat(directory, "registry.pending", 0) == 0, fsync(directory) == 0 else { throw Failure.io }
        return .discardedUncommitted
    }

    private func verifyStateDigest(_ digest: String?, remember: Bool) throws {
        do { try anchor?.verify(expectedDigest: digest) }
        catch RaycastStoreProtectedReceiptState.Failure.review(let recovery) { throw Failure.protectedStateRecovery(recovery) }
        catch { throw Failure.anchor }
        if remember { verifiedStateDigest = digest }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func verified(_ record: Record) throws -> RaycastStoreTrustedDescription {
        guard !record.bytes.isEmpty, record.bytes.count <= 32 * 1024 * 1024 else { throw Failure.limit }
        let digest = Self.digest(record.bytes)
        guard digest == record.digest else { throw Failure.integrity }
        let description = try trust.verify(bytes: record.bytes, source: record.source, installationID: record.id)
        guard description.extensionID == record.slug else { throw Failure.identity }
        guard record.grants.count <= 128, record.grants.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              description.requiredCapabilities == record.grants else { throw Failure.capability }
        guard record.phase == .prepared ? record.generation == 0 && !record.enabled : record.generation > 0,
              record.phase != .pending || !record.enabled else { throw Failure.corrupt }
        _ = try preferenceValues(record, manifest: description.manifest)
        return description
    }
    private func receipt(_ record: Record) throws -> RaycastStoreInstallation {
        let description = try verified(record)
        return .init(id: record.id, source: try record.source, generation: record.generation, manifest: description.manifest, enabled: record.enabled && record.phase == .active, pendingOperation: record.phase == .pending)
    }
    /// Trusted bridge supplies bytes plus its expected digest. Both are reverified
    /// through artifact trust before durable staging; handle is scoped to this state.
    public func prepare(bytes: Data, expectedDigest: String, source: RaycastStoreSource, grantedCapabilities: Set<String>, installationID: UUID? = nil) throws -> RaycastStorePreparedArtifact {
        let fd = try lock(); defer { unlock(fd) }
        var state = try read()
        if let existing = state.records.first(where: { $0.slug.lowercased() == source.slug.lowercased() }) {
            if existing.phase != .prepared {
                guard installationID == existing.id else { throw Failure.stale }
                if let candidate = state.candidates?.first(where: { $0.id == existing.id }) {
                    guard try candidate.source == source, candidate.digest == expectedDigest, candidate.bytes == bytes,
                          candidate.grants == grantedCapabilities else { throw Failure.stale }
                    return .init(id: existing.id, source: source, contentDigest: expectedDigest)
                }
                guard existing.phase == .active, existing.generation < UInt64.max else { throw Failure.stale }
                let record = Record(id: existing.id, slug: source.slug, revision: source.revision, digest: expectedDigest,
                    bytes: bytes, grants: grantedCapabilities, generation: 0, enabled: false, phase: .prepared,
                    baseGeneration: existing.generation, baseEnabled: existing.enabled)
                _ = try verified(record); state.candidates = (state.candidates ?? []) + [record]; try write(state)
                return .init(id: record.id, source: source, contentDigest: expectedDigest)
            }
            // Reconcile a crash after durable staging without allocating another
            // installation or mistaking a different build for the same one.
            guard existing.phase == .prepared, try existing.source == source,
                  (installationID == nil || installationID == existing.id),
                  existing.digest == expectedDigest, existing.bytes == bytes,
                  existing.grants == grantedCapabilities else { throw Failure.stale }
            return .init(id: existing.id, source: source, contentDigest: expectedDigest)
        }
        guard state.records.count < 128 else { throw Failure.limit }
        let id = installationID ?? UUID()
        guard !state.records.contains(where: { $0.id == id }) else { throw Failure.stale }
        let record = Record(id: id, slug: source.slug, revision: source.revision, digest: expectedDigest, bytes: bytes, grants: grantedCapabilities, generation: 0, enabled: false, phase: .prepared)
        _ = try verified(record); state.records.append(record); try write(state)
        return .init(id: record.id, source: source, contentDigest: expectedDigest)
    }
    /// Recover the exact verified staged receipt on restart without rebuilding the command.
    public func stagedArtifact(for source: RaycastStoreSource) throws -> RaycastStorePreparedArtifact? {
        let fd = try lock(); defer { unlock(fd) }
        let state = try read()
        guard let record = ((state.candidates ?? []) + state.records).first(where: {
            $0.phase == .prepared && $0.slug == source.slug && $0.revision == source.revision
        }) else { return nil }
        return .init(id: record.id, source: source, contentDigest: record.digest)
    }
    public func discard(_ artifact: RaycastStorePreparedArtifact) throws {
        let fd = try lock(); defer { unlock(fd) }
        var state = try read()
        if let index = state.candidates?.firstIndex(where: { $0.id == artifact.id && $0.digest == artifact.contentDigest }) {
            guard try state.candidates![index].source == artifact.source else { throw Failure.stale }
            state.candidates!.remove(at: index); try write(state); return
        }
        guard let index = state.records.firstIndex(where: { $0.id == artifact.id }) else { return }
        let record = state.records[index]
        guard record.phase == .prepared, try record.source == artifact.source, record.digest == artifact.contentDigest else { throw Failure.stale }
        state.records.remove(at: index)
        try write(state)
    }
    public func activate(_ artifact: RaycastStorePreparedArtifact) async throws -> RaycastStoreInstallation {
        let fd = try lock(); defer { unlock(fd) }
        var state = try read()
        if let candidateIndex = state.candidates?.firstIndex(where: { $0.id == artifact.id && $0.digest == artifact.contentDigest }) {
            var candidate = state.candidates![candidateIndex]
            guard try candidate.source == artifact.source, let base = candidate.baseGeneration,
                  base < UInt64.max, let index = state.records.firstIndex(where: { $0.id == candidate.id }) else { throw Failure.stale }
            var old = state.records[index]
            let target = base + 1
            guard (old.phase == .active && old.generation == base) || (old.phase == .pending && old.generation == target) else { throw Failure.stale }
            candidate.generation = target; candidate.phase = .active; candidate.enabled = candidate.baseEnabled == true
            candidate.preferences = old.preferences; candidate.baseGeneration = nil; candidate.baseEnabled = nil
            _ = try verified(candidate) // incompatible preference schema fails before old state is touched
            try Task.checkCancellation()
            try trust.quarantine(installationID: old.id, before: target)
            if old.phase != .pending {
                old.generation = target; old.phase = .pending; old.enabled = false; state.records[index] = old
                try write(state)
            }
            try await trust.revoke(installationID: old.id, before: target)
            // After durable quarantine, finish only this exact committed update.
            state.records[index] = candidate; state.candidates!.remove(at: candidateIndex); try write(state)
            return try receipt(candidate)
        }
        guard let index = state.records.firstIndex(where: { $0.id == artifact.id }) else { throw Failure.missing }
        var record = state.records[index]
        guard record.phase == .prepared, try record.source == artifact.source, record.digest == artifact.contentDigest else { throw Failure.stale }
        record.generation = 1; record.phase = .active; record.enabled = true
        _ = try verified(record); state.records[index] = record; try write(state)
        return try receipt(record)
    }
    public func installations() throws -> [RaycastStoreInstallation] {
        let fd = try lock(); defer { unlock(fd) }
        return try read().records.filter { $0.phase != .prepared }.map(receipt)
    }
    /// An active registry token only. Caller must STILL check preferences and runner
    /// capability authority atomically at dispatch; this is not launch readiness.
    @discardableResult
    public func validate(installationID: UUID, generation: UInt64, commandID: String, capabilities: Set<String>) throws -> LaunchArtifact {
        let fd = try lock(); defer { unlock(fd) }
        guard let record = try read().records.first(where: { $0.id == installationID }) else { throw Failure.missing }
        guard record.generation == generation else { throw Failure.stale }
        guard record.phase == .active, record.enabled else { throw Failure.inactive }
        let description = try verified(record)
        guard description.manifest.commands.contains(where: { $0.id == commandID }) else { throw Failure.identity }
        guard capabilities.isSubset(of: record.grants) else { throw Failure.capability }
        return .init(source: try record.source, digest: record.digest, bytes: record.bytes)
    }
    /// Takes an exact anchored launch snapshot and optionally registers a broker
    /// lease before releasing the registry lock. The admission callback must be
    /// synchronous and never call back into the registry.
    func withCurrentRun<T: Sendable>(_ context: RaycastStoreInstallCoordinator.RunContext,
        _ body: @Sendable (RaycastStoreInstallation, RaycastStoreTrustedDescription, RaycastStorePreferenceSnapshot) throws -> T
    ) throws -> T {
        guard anchor != nil else { throw Failure.anchor }
        let fd = try lock(); defer { unlock(fd) }
        let state = try read()
        let index = try preferenceIndex(state, installationID: context.installation.id,
                                        generation: context.installation.generation)
        let record = state.records[index]
        guard try record.source == context.artifact.source, record.digest == context.artifact.digest,
              record.bytes == context.artifact.bytes else { throw Failure.integrity }
        let trusted = try verified(record)
        guard trusted.manifest.commands.contains(where: { $0.id == context.commandID }) else { throw Failure.identity }
        return try body(try receipt(record), trusted, .init(values: preferenceValues(record, manifest: trusted.manifest)))
    }

    /// Reads the latest non-secret values only for the exact enabled generation.
    public func load(installationID: UUID, generation: UInt64) throws -> RaycastStorePreferenceSnapshot {
        let fd = try lock(); defer { unlock(fd) }
        let state = try read()
        let index = try preferenceIndex(state, installationID: installationID, generation: generation)
        let record = state.records[index]
        return try .init(values: preferenceValues(record, manifest: verified(record).manifest))
    }

    /// The same lock/anchor covers installation lookup, validation and commit;
    /// disabling or uninstalling cannot interleave between the guard and write.
    /// Missing required input is allowed while editing; launch still validates
    /// the complete schema. Credentials and host file/application values are out of scope.
    public func save(installationID: UUID, generation: UInt64, changes: RaycastStorePreferenceChanges) throws {
        let fd = try lock(); defer { unlock(fd) }
        var state = try read()
        let index = try preferenceIndex(state, installationID: installationID, generation: generation)
        guard changes.secrets.isEmpty, changes.values.count <= 128 else { throw Failure.preference }

        let manifest = try verified(state.records[index]).manifest
        var values = try preferenceValues(state.records[index], manifest: manifest)
        let previous = values
        for (key, change) in changes.values {
            let field = try preferenceField(key, manifest: manifest)
            switch change {
            case .reset: values.removeValue(forKey: key)
            case .set(let value):
                guard Self.acceptsOrdinaryPreference(field, value) else { throw Failure.preference }
                values[key] = value
            }
        }
        guard values.count <= 128 else { throw Failure.limit }
        guard values != previous else { return }
        state.records[index].preferences = values.isEmpty ? nil : values.map { key, value in
            let command: String?
            switch key.scope {
            case .extensionWide: command = nil
            case .command(let id): command = id
            }
            return OrdinaryPreference(command: command, name: key.name, value: value)
        }.sorted { ($0.command ?? "", $0.name) < ($1.command ?? "", $1.name) }
        try write(state)
    }

    private func preferenceIndex(_ state: State, installationID: UUID, generation: UInt64) throws -> Int {
        guard let index = state.records.firstIndex(where: { $0.id == installationID }) else { throw Failure.missing }
        let record = state.records[index]
        guard record.generation == generation else { throw Failure.stale }
        guard record.phase == .active, record.enabled else { throw Failure.inactive }
        return index
    }

    private func preferenceValues(_ record: Record, manifest: RaycastExtensionManifest) throws
        -> [RaycastStorePreferenceKey: RaycastExtensionManifest.PreferenceValue] {
        var result: [RaycastStorePreferenceKey: RaycastExtensionManifest.PreferenceValue] = [:]
        let preferences = record.preferences ?? []
        guard preferences.count <= 128 else { throw Failure.limit }
        for item in preferences {
            let field = try preferenceField(item.key, manifest: manifest)
            guard result[item.key] == nil, Self.acceptsOrdinaryPreference(field, item.value) else { throw Failure.preference }
            result[item.key] = item.value
        }
        return result
    }

    private func preferenceField(_ key: RaycastStorePreferenceKey, manifest: RaycastExtensionManifest) throws
        -> RaycastExtensionManifest.Field {
        let fields: [RaycastExtensionManifest.Field]
        switch key.scope {
        case .extensionWide: fields = manifest.preferences
        case .command(let id):
            guard let command = manifest.commands.first(where: { $0.id == id }) else { throw Failure.preference }
            fields = command.preferences
        }
        let matches = fields.filter { $0.name == key.name }
        guard !key.name.isEmpty, key.name.utf8.count <= 256,
              !key.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              matches.count == 1, let field = matches.first,
              ["textfield", "checkbox", "dropdown"].contains(field.type) else { throw Failure.preference }
        return field
    }

    private static func acceptsOrdinaryPreference(_ field: RaycastExtensionManifest.Field,
                                                  _ value: RaycastExtensionManifest.PreferenceValue) -> Bool {
        guard field.accepts(value) else { return false }
        if case .string(let text) = value { return text.utf8.count <= 4_096 }
        return true
    }

    public func setEnabled(installationID: UUID, expectedGeneration: UInt64, enabled: Bool) async throws -> RaycastStoreInstallation {
        guard let receipt = try await mutate(installationID: installationID, expectedGeneration: expectedGeneration, enabled: enabled, remove: false) else {
            throw Failure.corrupt
        }
        return receipt
    }
    public func uninstall(installationID: UUID, expectedGeneration: UInt64) async throws {
        _ = try await mutate(installationID: installationID, expectedGeneration: expectedGeneration, enabled: false, remove: true)
    }
    private func mutate(installationID: UUID, expectedGeneration: UInt64, enabled: Bool, remove: Bool) async throws -> RaycastStoreInstallation? {
        let fd = try lock(); defer { unlock(fd) }
        var state = try read()
        guard let index = state.records.firstIndex(where: { $0.id == installationID }) else { throw Failure.missing }
        var record = state.records[index]
        guard record.generation == expectedGeneration, record.phase != .prepared, record.generation < UInt64.max else { throw Failure.stale }
        record.generation += 1; record.enabled = false; record.phase = .pending
        try trust.quarantine(installationID: record.id, before: record.generation)
        state.records[index] = record
        do { try write(state) }
        catch {
            // The independent anchor may have advanced even if local replacement
            // failed. Immediately request revocation of any old live sessions;
            // never report success or proceed to enable/remove in this case.
            let writeFailure = error
            try? await trust.revoke(installationID: record.id, before: record.generation)
            throw writeFailure
        }
        // Durable quarantine precedes the await. Failed/aborted termination leaves
        // pending disabled state visible on restart; explicit retry requires new gen.
        try await trust.revoke(installationID: record.id, before: record.generation)
        if remove {
            state.records.remove(at: index); state.candidates?.removeAll { $0.id == record.id }
            try write(state); return nil
        }
        record.phase = .active; record.enabled = enabled; state.records[index] = record
        try write(state); return try receipt(record)
    }
}
