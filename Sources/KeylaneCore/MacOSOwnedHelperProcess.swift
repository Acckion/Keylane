import Darwin
import Foundation

/// Bounded pipe transport and stop supervision for signed native helpers.
final class MacOSOwnedHelperProcess: @unchecked Sendable {
    enum Failure: Error { case transport, failed }

    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }
    func run(helper: URL, input: Data, timeout: Duration, outputLimit: Int, ownership: Int32? = nil) throws -> Data {
        guard !input.isEmpty else { throw Failure.transport }
        if isCancelled { throw CancellationError() }
        func pipePair() throws -> [Int32] {
            var pair: [Int32] = [0,0]
            guard pipe(&pair) == 0 else { throw Failure.transport }
            for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return pair
        }
        var descriptors = Set<Int32>()
        defer { for fd in descriptors { close(fd) } }
        func makePipe() throws -> [Int32] { let p = try pipePair(); descriptors.formUnion(p); return p }
        func release(_ fd: Int32) { if descriptors.remove(fd) != nil { close(fd) } }
        let incoming = try makePipe(), outgoing = try makePipe(), diagnostics = try makePipe(), lifetime = try makePipe()
        guard fcntl(incoming[1], F_SETNOSIGPIPE, 1) == 0 else { throw Failure.transport }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.transport }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.transport }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw Failure.transport }
        var mappings: [(Int32, Int32)] = [(incoming[0], 0), (outgoing[1], 1), (diagnostics[1], 2), (lifetime[0], 3)]
        if let ownership {
            // Duplicate above all destination FDs before installing any mapping.
            let inherited = fcntl(ownership, F_DUPFD_CLOEXEC, 5)
            guard inherited >= 0 else { throw Failure.transport }
            descriptors.insert(inherited)
            mappings.append((inherited, 4))
        }
        for (source, target) in mappings {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw Failure.transport }
        }
        let argv = [strdup(helper.path), nil], environment = [strdup("PATH=/usr/bin:/bin"),nil]
        defer { for item in argv + environment { free(item) } }
        var pid: pid_t = 0
        let error = argv.withUnsafeBufferPointer { a in environment.withUnsafeBufferPointer { e in
            posix_spawn(&pid,helper.path,&actions,&attributes,a.baseAddress!,e.baseAddress!)
        } }
        guard error == 0, pid > 0 else { throw Failure.transport }
        release(incoming[0]); release(outgoing[1]); release(diagnostics[1]); release(lifetime[0])
        for fd in [incoming[1],outgoing[0],diagnostics[0]] { _ = fcntl(fd,F_SETFL,O_NONBLOCK) }
        var position = 0, output = Data(), diagnosticBytes = 0
        var inputOpen = true, outputOpen = true, errorOpen = true
        var exited = false, bad = false, stoppedAt: ContinuousClock.Instant?
        let deadline = ContinuousClock.now + timeout
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
            if observed != 0 && errno != EINTR {
                let waitError = errno
                release(lifetime[1])
                if waitError == ECHILD { throw Failure.transport }
                bad = true
            }
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
                        if count <= outputLimit - output.count { output.append(contentsOf:buffer.prefix(count)) } else { bad = true }
                    } else { diagnosticBytes += count; if diagnosticBytes > 4096 { bad = true } }
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    release(fd); if index == 1 { outputOpen = false } else { errorOpen = false }
                }
            }
        }
        var status: Int32 = 0
        while waitpid(pid,&status,0) < 0 { if errno != EINTR { throw Failure.transport } }
        if isCancelled { throw CancellationError() }
        guard !bad, stoppedAt == nil, status == 0 else { throw Failure.failed }
        return output
    }
}
