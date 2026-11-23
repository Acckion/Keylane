import Darwin
import Foundation

/// The only native adapter for the fixed signed builder. No manifest path, argv,
/// npm command, PATH lookup, fixture evaluator or runtime fallback is accepted.
package final class MacOSSignedBuildService: MacOSExtensionBuild.Service, @unchecked Sendable {
    private final class Gate: @unchecked Sendable { let lock = NSLock(); var active = false }
    private static let gate = Gate()
    private let profile: MacOSBuildProfile
    private let lock = NSLock()
    private var active: (UUID, Session)?
    private var cancelled: [UUID] = []
    package init(profile: MacOSBuildProfile) throws { try profile.verify(); self.profile = profile }
    package func verifiedRecipe() throws -> MacOSExtensionBuild.Recipe {
        try profile.verify(); return profile.configuration.recipe
    }
    package func cancel(_ id: UUID) {
        lock.withLock {
            if let active, active.0 == id { active.1.cancel() }
            else { cancelled.append(id); if cancelled.count > 64 { cancelled.removeFirst() } }
        }
    }
    package func compile(_ request: MacOSExtensionBuild.Request) async throws -> MacOSExtensionBuild.Reply {
        guard try verifiedRecipe() == request.recipe else { throw MacOSExtensionBuild.Failure.toolchainChanged }
        let session = Session()
        try Self.gate.lock.withLock {
            guard !Self.gate.active else { throw MacOSExtensionBuild.Failure.busy }; Self.gate.active = true
        }
        var registered = false
        defer { if !registered { Self.gate.lock.withLock { Self.gate.active = false } } }
        try lock.withLock {
            guard active == nil else { throw MacOSExtensionBuild.Failure.busy }
            if cancelled.contains(request.id) { cancelled.removeAll { $0 == request.id }; throw CancellationError() }
            active = (request.id, session)
        }
        registered = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    let result = Result {
                        let buildLock = try profile.acquireBuildLock()
                        defer { flock(buildLock, LOCK_UN); close(buildLock) }
                        let bytes = try session.run(helper: profile.helper, input: request.encoded())
                        guard try verifiedRecipe() == request.recipe else { throw MacOSExtensionBuild.Failure.toolchainChanged }
                        let reply = try JSONDecoder().decode(MacOSExtensionBuild.Reply.self, from: bytes)
                        _ = try MacOSExtensionBuild.Artifact(request: request, reply: reply)
                        return reply
                    }
                    lock.withLock { active = nil }
                    Self.gate.lock.withLock { Self.gate.active = false }
                    continuation.resume(with: result)
                }
            }
        } onCancel: { session.cancel() }
    }

    private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        private var isCancelled: Bool { lock.withLock { cancelled } }
        func run(helper: URL, input: Data) throws -> Data {
            if isCancelled { throw CancellationError() }
            func pipePair() throws -> [Int32] {
                var pair: [Int32] = [0,0]
                guard pipe(&pair) == 0 else { throw MacOSExtensionBuild.Failure.response }
                for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
                return pair
            }
            var descriptors = Set<Int32>()
            defer { for fd in descriptors { close(fd) } }
            func makePipe() throws -> [Int32] { let p = try pipePair(); descriptors.formUnion(p); return p }
            func release(_ fd: Int32) { if descriptors.remove(fd) != nil { close(fd) } }
            let incoming = try makePipe(), outgoing = try makePipe(), diagnostics = try makePipe(), lifetime = try makePipe()
            guard fcntl(incoming[1], F_SETNOSIGPIPE, 1) == 0 else { throw MacOSExtensionBuild.Failure.response }
            var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw MacOSExtensionBuild.Failure.response }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawnattr_init(&attributes) == 0 else { throw MacOSExtensionBuild.Failure.response }
            defer { posix_spawnattr_destroy(&attributes) }
            guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)) == 0,
                  posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw MacOSExtensionBuild.Failure.response }
            // Avoid descriptor-source aliasing: lifetime is mapped last to FD3,
            // while every source pipe descriptor is distinct and remains open.
            for (source,target): (Int32,Int32) in [(incoming[0],0),(outgoing[1],1),(diagnostics[1],2),(lifetime[0],3)] {
                guard posix_spawn_file_actions_adddup2(&actions,source,target) == 0 else { throw MacOSExtensionBuild.Failure.response }
            }
            let argv = [strdup(helper.path), nil], environment = [strdup("PATH=/usr/bin:/bin"),nil]
            defer { for item in argv + environment { free(item) } }
            var pid: pid_t = 0
            let error = argv.withUnsafeBufferPointer { a in environment.withUnsafeBufferPointer { e in
                posix_spawn(&pid,helper.path,&actions,&attributes,a.baseAddress!,e.baseAddress!)
            } }
            guard error == 0, pid > 0 else { throw MacOSExtensionBuild.Failure.response }
            release(incoming[0]); release(outgoing[1]); release(diagnostics[1]); release(lifetime[0])
            for fd in [incoming[1],outgoing[0],diagnostics[0]] { _ = fcntl(fd,F_SETFL,O_NONBLOCK) }
            var position = 0, output = Data(), diagnosticBytes = 0
            var inputOpen = true, outputOpen = true, errorOpen = true
            var exited = false, bad = false, stoppedAt: ContinuousClock.Instant?
            let deadline = ContinuousClock.now + .seconds(30)
            // This loop owns the PID until waitpid. Cancellation only sets a flag,
            // so no other thread can reap a child then signal a recycled PID.
            while !exited || outputOpen || errorOpen {
                if isCancelled || bad || ContinuousClock.now >= deadline {
                    if stoppedAt == nil { release(lifetime[1]); stoppedAt = .now }
                    if !exited, stoppedAt!.duration(to: .now) > .seconds(1) { kill(-pid,SIGKILL) }
                }
                var status = siginfo_t()
                let observed = waitid(P_PID,id_t(pid),&status,WEXITED | WNOHANG | WNOWAIT)
                if observed == 0 && status.si_pid == pid && !exited {
                    exited = true
                    // The leader is still unreaped, pinning this owned group ID.
                    // Also stop a fixed compiler if the helper crashed mid-build.
                    kill(-pid,SIGKILL)
                }
                if observed != 0 && errno != EINTR { bad = true; release(lifetime[1]) }
                var polls = [pollfd(fd: inputOpen ? incoming[1] : -1,events: Int16(POLLOUT),revents:0),
                             pollfd(fd: outputOpen ? outgoing[0] : -1,events:Int16(POLLIN),revents:0),
                             pollfd(fd: errorOpen ? diagnostics[0] : -1,events:Int16(POLLIN),revents:0)]
                _ = Darwin.poll(&polls,nfds_t(polls.count),50)
                if inputOpen && polls[0].revents != 0 {
                    let count = input.withUnsafeBytes { bytes in
                        Darwin.write(incoming[1],bytes.baseAddress!.advanced(by:position),min(65536,bytes.count-position))
                    }
                    if count > 0 { position += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { bad = true; position = input.count }
                    if position == input.count { release(incoming[1]); inputOpen = false }
                }
                for index in 1...2 where polls[index].revents != 0 {
                    let fd = polls[index].fd
                    var buffer = [UInt8](repeating:0,count:65536)
                    let count = Darwin.read(fd,&buffer,buffer.count)
                    if count > 0 {
                        if index == 1 {
                            if count <= 20 * 1024 * 1024 - output.count { output.append(contentsOf:buffer.prefix(count)) } else { bad = true }
                        } else { diagnosticBytes += count; if diagnosticBytes > 4096 { bad = true } }
                    } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        release(fd); if index == 1 { outputOpen = false } else { errorOpen = false }
                    }
                }
            }
            var status: Int32 = 0
            while waitpid(pid,&status,0) < 0 { if errno != EINTR { throw MacOSExtensionBuild.Failure.response } }
            if isCancelled { throw CancellationError() }
            guard !bad, stoppedAt == nil, status == 0 else { throw MacOSExtensionBuild.Failure.project }
            return output
        }
    }
}
