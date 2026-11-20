import Foundation
import CryptoKit
import Darwin

/// One profile-bound authority for anchored admission, native start and host
/// effects. The lock ordering is registry flock -> policy lock; policy sinks
/// must not subscribe to or use the registry synchronously.
package final class StoreGuestCommonAuthority: RaycastStoreSignedInstallationService.Authority, @unchecked Sendable {
    package enum Failure: Error, Equatable { case denied, capacity, stopPending }
    private typealias Admission = RaycastStoreSignedInstallationService.Admission
    private typealias Revocation = StoreGuestTicketHost.Revocation
    private struct State {
        var active: [UUID: Admission] = [:]
        var watermarks: [String: UInt64] = [:]
        var pending: [String: Revocation] = [:]
    }
    private let profileID: UUID
    private let grants: Set<String>
    private let lock = NSRecursiveLock()
    private var state = State()
    @MainActor private weak var host: StoreGuestTicketHost?
    @MainActor private var boundOnce = false
    private let owner: ProfileOwner?

    /// Holds one authority for a registry root across app processes. This
    /// protection is additional to transaction flocking, which alone cannot
    /// serialize effects from multiple independent live brokers.
    package final class ProfileOwner {
        private static let lockName = RaycastStoreProtectedReceiptState.OwnerBinding.lockName
        private let rootFD: Int32
        private let descriptor: Int32
        private let expected: RaycastStoreProtectedReceiptState.OwnerBinding
        private let continuity = NSLock()
        private var lost = false

        package init(root: URL, profileID: UUID, expected: RaycastStoreProtectedReceiptState.OwnerBinding) throws {
            guard root.isFileURL, root.path == expected.rootPath, profileID == expected.profileID else { throw Failure.denied }
            let dir = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dir >= 0 else { throw Failure.denied }
            let fd = openat(dir, Self.lockName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { close(dir); throw Failure.denied }
            guard Self.matches(dir, fd, expected), flock(fd, LOCK_EX | LOCK_NB) == 0,
                  Self.matches(dir, fd, expected) else {
                close(fd); close(dir); throw Failure.denied
            }
            rootFD = dir; descriptor = fd; self.expected = expected
        }

        package func isCurrent() -> Bool {
            continuity.lock(); defer { continuity.unlock() }
            if !lost { lost = !Self.matches(rootFD, descriptor, expected) }
            return !lost
        }

        private static func matches(_ rootFD: Int32, _ fd: Int32,
                                    _ expected: RaycastStoreProtectedReceiptState.OwnerBinding) -> Bool {
            var root = stat(), namedRoot = stat(), lock = stat(), namedLock = stat()
            guard fstat(rootFD, &root) == 0, lstat(expected.rootPath, &namedRoot) == 0,
                  fstat(fd, &lock) == 0, fstatat(rootFD, lockName, &namedLock, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            func privateNode(_ info: stat, _ kind: mode_t, _ device: Int64, _ inode: UInt64) -> Bool {
                info.st_mode & S_IFMT == kind && info.st_uid == geteuid() && info.st_mode & 0o077 == 0 &&
                    Int64(info.st_dev) == device && UInt64(info.st_ino) == inode
            }
            return privateNode(root, S_IFDIR, expected.rootDevice, expected.rootInode) &&
                privateNode(namedRoot, S_IFDIR, expected.rootDevice, expected.rootInode) &&
                privateNode(lock, S_IFREG, expected.lockDevice, expected.lockInode) &&
                privateNode(namedLock, S_IFREG, expected.lockDevice, expected.lockInode) &&
                lock.st_nlink == 1 && namedLock.st_nlink == 1
        }

        deinit { flock(descriptor, LOCK_UN); close(descriptor); close(rootFD) }
    }

    package convenience init(profileID: UUID, grants: Set<String>) throws {
        try self.init(profileID: profileID, grants: grants, owner: nil)
    }

    private init(profileID: UUID, grants: Set<String>, owner: ProfileOwner?) throws {
        guard grants.isSubset(of: ["feedback.toast", "feedback.hud", "clipboard.copy", "preferences.read"]) else {
            throw Failure.denied
        }
        self.profileID = profileID; self.grants = grants; self.owner = owner
    }

    @MainActor package func bind(_ host: StoreGuestTicketHost) throws {
        guard !boundOnce else { throw Failure.denied }
        boundOnce = true; self.host = host
    }

    /// Candidate for app-owned enrollment only. Merely opening the candidate
    /// does not initialize or repair a missing protected registry.
    @MainActor package static func installedCandidate(application: Bundle, root: URL, profileID: UUID, registryID: UUID,
        teamIdentifier: String, recipe: RaycastStoreArtifactSeal.Recipe,
        publicKey: P256.Signing.PublicKey, anchor: RaycastStoreProtectedReceiptState, ownerBinding: RaycastStoreProtectedReceiptState.OwnerBinding, grants: Set<String>,
        sign: @escaping @Sendable @MainActor (Data) throws -> P256.Signing.ECDSASignature,
        sink: @escaping (StoreGuestRunTicket, String, String) throws -> String) async throws -> RaycastStoreInstallCoordinator {
        try await makeInstalledCandidate(application: application, root: root, profileID: profileID, registryID: registryID,
            teamIdentifier: teamIdentifier, recipe: recipe, publicKey: publicKey, anchor: anchor, ownerBinding: ownerBinding,
            grants: grants, sign: sign, sink: sink) { ownedRoot, service in
                try RaycastStoreInstallCoordinator(root: ownedRoot, service: service, anchor: anchor, requiresExistingRoot: true)
            }
    }

    #if DEBUG
    @MainActor package static func offlineInstalledCandidate(application: Bundle, root: URL, profileID: UUID, registryID: UUID,
        teamIdentifier: String, recipe: RaycastStoreArtifactSeal.Recipe,
        publicKey: P256.Signing.PublicKey, anchor: RaycastStoreProtectedReceiptState, ownerBinding: RaycastStoreProtectedReceiptState.OwnerBinding, grants: Set<String>,
        sign: @escaping @Sendable @MainActor (Data) throws -> P256.Signing.ECDSASignature,
        sink: @escaping (StoreGuestRunTicket, String, String) throws -> String,
        fixture: RaycastStoreAppCapability.OfflineFixture) async throws -> RaycastStoreInstallCoordinator {
        try await makeInstalledCandidate(application: application, root: root, profileID: profileID, registryID: registryID,
            teamIdentifier: teamIdentifier, recipe: recipe, publicKey: publicKey, anchor: anchor, ownerBinding: ownerBinding,
            grants: grants, sign: sign, sink: sink) { ownedRoot, service in
                try fixture.makeCoordinator(root: ownedRoot, service: service, anchor: anchor)
            }
    }
    #endif

    @MainActor private static func makeInstalledCandidate(application: Bundle, root: URL, profileID: UUID, registryID: UUID,
        teamIdentifier: String, recipe: RaycastStoreArtifactSeal.Recipe,
        publicKey: P256.Signing.PublicKey, anchor: RaycastStoreProtectedReceiptState, ownerBinding: RaycastStoreProtectedReceiptState.OwnerBinding, grants: Set<String>,
        sign: @escaping @Sendable @MainActor (Data) throws -> P256.Signing.ECDSASignature,
        sink: @escaping (StoreGuestRunTicket, String, String) throws -> String,
        makeCoordinator: (URL, RaycastStoreSignedInstallationService) throws -> RaycastStoreInstallCoordinator) async throws -> RaycastStoreInstallCoordinator {
        guard root.isFileURL, anchor.matchesEnrollment(registryID: registryID, publicKey: publicKey, recipe: recipe, owner: ownerBinding)
        else { throw Failure.denied }
        let ownedRoot = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent, isDirectory: true).standardizedFileURL
        let authority = try StoreGuestCommonAuthority(profileID: profileID, grants: grants,
                                                       owner: ProfileOwner(root: ownedRoot, profileID: profileID, expected: ownerBinding))
        let host = StoreGuestProcessDriver.nativeTicketHost(application: application, teamIdentifier: teamIdentifier,
            recipeIdentifier: recipe.identifier, authority: authority, sink: sink)
        try authority.bind(host)
        let driver = StoreGuestProcessDriver(teamIdentifier: teamIdentifier, ticketHost: host)
        let engine = try StoreSignedGuestEngine.installed(in: application, expectedTeam: teamIdentifier,
                                                         recipeIdentifier: recipe.identifier, driver: driver)
        guard try engine.verifiedRuntimeDigest() == recipe.runtimeDigest else { throw Failure.denied }
        let service = try RaycastStoreSignedInstallationService(profileID: profileID, recipe: recipe,
            publicKey: publicKey, sign: sign, engine: engine, authority: authority)
        let coordinator = try makeCoordinator(ownedRoot, service)
        try await coordinator.verifyExistingProtectedRegistry()
        guard authority.owner?.isCurrent() == true else { throw Failure.denied }
        return coordinator
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    package func verifyRegistryAccess(profileID: UUID) throws {
        guard profileID == self.profileID, owner?.isCurrent() != false else { throw Failure.denied }
    }

    /// Grants are selected by the enrolled app profile; never taken from the guest.
    package func buildCapabilities(profileID: UUID, manifest: RaycastExtensionManifest) throws -> Set<String> {
        guard profileID == self.profileID, owner?.isCurrent() != false else { throw Failure.denied }
        return grants
    }

    private func allowed(_ request: Admission) -> Bool {
        owner?.isCurrent() != false && request.profileID == profileID && request.installation.generation > 0 &&
        state.pending[request.installation.id] == nil &&
        request.installation.generation >= state.watermarks[request.installation.id, default: 1] &&
        request.capabilities.isSubset(of: grants)
    }

    package func permits(_ admission: RaycastStoreSignedInstallationService.Admission) throws -> Bool {
        locked { allowed(admission) && state.active.count < 128 }
    }

    package func admit(_ admission: RaycastStoreSignedInstallationService.Admission) throws -> RaycastStoreSignedInstallationService.Lease {
        try locked {
            guard allowed(admission), state.active[admission.launchID] == nil else { throw Failure.denied }
            guard state.active.count < 128 else { throw Failure.capacity }
            state.active[admission.launchID] = admission
        }
        return .init(isCurrent: { [weak self] in
            self?.isCurrent(admission.launchID) ?? false
        }, finish: { [weak self] in
            guard let self else { return }
            self.locked { self.state.active[admission.launchID] = nil }
        })
    }

    private func isCurrent(_ id: UUID) -> Bool {
        locked { state.active[id].map(allowed) ?? false }
    }

    package func quarantine(profileID: UUID, installationID: UUID, before generation: UInt64) throws {
        try locked {
            guard owner?.isCurrent() != false, profileID == self.profileID, generation > 1 else { throw Failure.denied }
            let key = installationID.uuidString
            let existing = state.pending[key]
            guard existing != nil || state.pending.count < 128 else {
                // The durable mutation has not happened; fail without advancing it.
                throw Failure.capacity
            }
            let watermark = max(generation, state.watermarks[key, default: 1])
            guard state.watermarks[key] != nil || state.watermarks.count < 4096 else { throw Failure.capacity }
            state.watermarks[key] = watermark
            // A failed cooperative stop remains associated with the original
            // request ID, even when a registry retry advances its generation.
            state.pending[key] = .init(id: existing?.id ?? UUID(), profileID: profileID,
                                      installationID: key, beforeGeneration: watermark)
        }
    }

    @MainActor package func revoke(profileID: UUID, installationID: UUID, before generation: UInt64) async throws {
        let key = installationID.uuidString
        guard let host, let request = locked({ state.pending[key] }),
              request.profileID == profileID, request.beforeGeneration >= generation else { throw Failure.denied }
        try await host.revoke(request, timeout: .seconds(3))
        try locked {
            guard let pending = state.pending[key], pending.id == request.id,
                  pending.beforeGeneration == request.beforeGeneration else { throw Failure.stopPending }
            state.pending[key] = nil
            state.active = state.active.filter {
                $0.value.installation.id != key || $0.value.installation.generation >= request.beforeGeneration
            }
        }
    }

    private func matches(_ ticket: StoreGuestRunTicket) -> Bool {
        guard let request = state.active[ticket.id], allowed(request),
              let launch = try? request.launchContext.launchData(loadPreferences: true),
              let preferences = try? request.launchContext.preferencesReply() else { return false }
        return ticket.profileID == request.profileID && ticket.installation == request.installation &&
            ticket.commandID == request.commandID && ticket.receipt == request.artifact && ticket.capabilities == request.capabilities &&
            (try? ticket.launchContext.launchData(loadPreferences: true)) == launch &&
            (try? ticket.launchContext.preferencesReply()) == preferences
    }
}

extension StoreGuestCommonAuthority: StoreGuestTicketHost.Authority {
    @MainActor package func start(_ ticket: StoreGuestRunTicket, spawn: () throws -> any StoreGuestTicketHost.Process) throws -> any StoreGuestTicketHost.Process {
        try locked { guard matches(ticket) else { throw Failure.denied }; return try spawn() }
    }
    @MainActor package func effect(_ ticket: StoreGuestRunTicket, capability: String, apply: () throws -> String) throws -> String {
        try locked {
            guard matches(ticket), ticket.capabilities.contains(capability) else { throw Failure.denied }
            return try apply()
        }
    }
    @MainActor package func authorizeRevocation(_ request: StoreGuestTicketHost.Revocation) throws {
        try locked {
            guard request.profileID == profileID, let pending = state.pending[request.installationID],
                  pending.id == request.id, pending.beforeGeneration == request.beforeGeneration
            else { throw Failure.denied }
        }
    }
}
