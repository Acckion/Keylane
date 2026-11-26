import Foundation
import Darwin
#if SWIFT_PACKAGE
import KeylaneCore
#endif

// First-party signed integration fixture. Not shipped or selectable by manifest.
// It uses the real Core data contract; product profile/XPC enrollment is pending.
private final class Supervisor: @unchecked Sendable {
    private let lock = NSLock()
    private var child: pid_t?
    private(set) var stopped = false
    func stop() { lock.withLock { stopped = true; if let child { kill(child, SIGKILL) } } }
    func spawn(_ body: () throws -> pid_t) throws -> pid_t {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            let pid = try body(); child = pid; return pid
        }
    }
    func wait(_ pid: pid_t) throws {
        // Observe without reaping so cancellation cannot signal a reused PID.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileReadUnknown) }
        }
        try lock.withLock {
            var status: Int32 = 0
            guard waitpid(pid, &status, 0) == pid else { throw CocoaError(.fileReadUnknown) }
            child = nil
            guard !stopped else { throw CancellationError() }
            guard status == 0 else { throw MacOSExtensionBuild.Failure.project }
        }
    }
    var isStopped: Bool { lock.withLock { stopped } }
    func cleanup() {
        lock.withLock {
            guard let pid = child else { return }
            stopped = true; kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 { if errno != EINTR { break } }
            child = nil
        }
    }
}

@available(macOS 26.0, *)
@main private enum BuildHelper {
    typealias Build = MacOSExtensionBuild
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        var core = rlimit(rlim_cur: 0, rlim_max: 0); setrlimit(RLIMIT_CORE, &core)
        do { try run() } catch is CancellationError { exit(75) }
        catch { exit(70) } // never expose source bodies/compiler diagnostics
    }
    static func run() throws {
        guard fcntl(3, F_GETFD) >= 0 else { throw Build.Failure.project }
        let supervisor = Supervisor()
        defer { supervisor.cleanup() }
        let parent = DispatchSource.makeReadSource(fileDescriptor: 3, queue: .global())
        parent.setEventHandler { supervisor.stop() }; parent.resume()
        defer { parent.cancel() }
        var input = Data()
        while let part = try FileHandle.standardInput.read(upToCount: 65536), !part.isEmpty {
            guard part.count <= 46 * 1024 * 1024 - input.count else { throw Build.Failure.limit }
            input.append(part)
        }
        let request = try Build.Request.decode(input)
        guard !supervisor.isStopped else { throw CancellationError() }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let compiler = executable.deletingLastPathComponent().appendingPathComponent("esbuild")
        func verify() throws {
            guard Build.hash(try Data(contentsOf: executable)) == request.recipe.helperSHA256,
                  Build.hash(try Data(contentsOf: compiler)) == request.recipe.compilerSHA256 else { throw Build.Failure.toolchainChanged }
        }
        try verify()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keylane-m1-build-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
#if M1_FIXTURE
        // First-party negative control only: an existing, harmless neighboring
        // source demonstrates the metadata fence, rather than a missing path.
        let neighbor = scratch.deletingLastPathComponent().appendingPathComponent("keylane-m1-neighbor-" + request.id.uuidString + ".js")
        var neighborCreated = false, outsideInputRead = false
#endif
        defer {
            supervisor.cleanup()
            let removed: Bool
            do {
#if M1_FIXTURE
                if neighborCreated { try FileManager.default.removeItem(at: neighbor) }
#endif
                try FileManager.default.removeItem(at: scratch); removed = true
            } catch { removed = false }
#if M1_FIXTURE
            var record: [String: Bool] = ["scratchRemoved": removed, "cancelled": supervisor.isStopped]
            if outsideInputRead { record["outsideInputRead"] = true }
            if let data = try? Build.encode(record) { try? FileHandle.standardError.write(contentsOf: data) }
#endif
            if !removed { exit(74) }
        }
#if M1_FIXTURE
        try Data("export default 42;".utf8).write(to: neighbor, options: .withoutOverwriting)
        neighborCreated = true
#endif
        let deadline = DispatchSource.makeTimerSource(queue: .global())
        deadline.schedule(deadline: .now() + .seconds(20)); deadline.setEventHandler { supervisor.stop() }; deadline.resume()
        defer { deadline.cancel() }
        // The staging root is a new, private fixture directory. Every path was
        // validated before any write; no archive links or caller output path.
        for file in request.plan.files {
            if supervisor.isStopped { throw CancellationError() }
            let destination = scratch.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try file.body.write(to: destination, options: .withoutOverwriting)
        }
        var fileLimit = rlimit(rlim_cur: 8 * 1024 * 1024, rlim_max: 8 * 1024 * 1024)
        var cpuLimit = rlimit(rlim_cur: 20, rlim_max: 20)
        guard setrlimit(RLIMIT_FSIZE, &fileLimit) == 0, setrlimit(RLIMIT_CPU, &cpuLimit) == 0 else { throw Build.Failure.limit }
        var commands: [Build.File] = []
        var outputBytes = 0
        for (index, entry) in request.plan.entries.enumerated() {
            let out = "__m1-output-\(index).js", meta = "__m1-output-\(index).json"
            // Output names are outside src/assets/node_modules and reserved in
            // the input validation below, so source cannot prepopulate them.
            guard !request.plan.files.contains(where: { $0.path == out || $0.path == meta }) else { throw Build.Failure.collision }
            let arguments = [compiler.path, "./" + entry, "--bundle", "--platform=neutral", "--format=iife",
                             "--charset=utf8", "--main-fields=module,main", "--tsconfig-raw={}", "--log-level=error",
                             "--legal-comments=inline", "--outfile=" + out, "--metafile=" + meta]
            let pid = try supervisor.spawn {
                var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
                guard posix_spawn_file_actions_init(&actions) == 0 else { throw Build.Failure.project }
                defer { posix_spawn_file_actions_destroy(&actions) }
                guard posix_spawnattr_init(&attributes) == 0 else { throw Build.Failure.project }
                defer { posix_spawnattr_destroy(&attributes) }
                guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
                      posix_spawn_file_actions_addchdir(&actions, scratch.path) == 0 else { throw Build.Failure.project }
                for fd: Int32 in 0...2 {
                    guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0 else { throw Build.Failure.project }
                }
                let argv = arguments.map { strdup($0) } + [nil]
                let env = [strdup("PATH=/usr/bin:/bin"), nil]
                defer { for arg in argv { free(arg) }; for value in env { free(value) } }
                var pid: pid_t = 0
                let error = argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { environment in
                    posix_spawn(&pid, compiler.path, &actions, &attributes, args.baseAddress!, environment.baseAddress!)
                } }
                guard error == 0, pid > 0 else { throw Build.Failure.project }; return pid
            }
            try supervisor.wait(pid)
            let metadataURL = scratch.appendingPathComponent(meta)
            let size = try metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 8 * 1024 * 1024 else { throw Build.Failure.limit }
            guard let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any],
                  let inputs = metadata["inputs"] as? [String: Any],
                  let outputs = metadata["outputs"] as? [String: [String: Any]], outputs.count == 1,
                  let output = outputs[out], let imports = output["imports"] as? [Any], imports.isEmpty else { throw Build.Failure.response }
            guard Set(inputs.keys).isSubset(of: Set(request.plan.files.map(\.path))) else {
#if M1_FIXTURE
                outsideInputRead = true
#endif
                throw Build.Failure.response
            }
            let outputURL = scratch.appendingPathComponent(out)
            guard (try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw Build.Failure.limit }
            let body = try Data(contentsOf: outputURL)
            guard body.count <= 12 * 1024 * 1024 - outputBytes else { throw Build.Failure.limit }
            outputBytes += body.count; commands.append(.init(path: entry, body: body))
            try FileManager.default.removeItem(at: outputURL)
            try FileManager.default.removeItem(at: metadataURL)
        }
        try verify()
        if supervisor.isStopped { throw CancellationError() }
        let reply = try Build.Reply(id: request.id, recipeDigest: request.recipe.digest, projectDigest: request.plan.digest, commands: commands)
        _ = try Build.Artifact(request: request, reply: reply)
        try FileHandle.standardOutput.write(contentsOf: Build.encode(reply))
    }
}
