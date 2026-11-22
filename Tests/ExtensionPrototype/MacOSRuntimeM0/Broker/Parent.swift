import Foundation
import Darwin

// Signed first-party authority root, only synthetic installation records. Scenario
// selection belongs to this test controller, not to __m0Request/guest metadata.
@main struct BrokerParent {
    static func fail(_ code: Int32 = 70) -> Never { exit(code) }
    static func send(_ data: Data, fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var position = 0
            while position < buffer.count {
                let count = write(fd, buffer.baseAddress! + position, buffer.count - position)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                position += count
            }
            return true
        }
    }
    static func receive(_ count: Int, fd: Int32) -> Data? {
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            var position = 0
            while position < count {
                let size = read(fd, buffer.baseAddress! + position, count - position)
                if size < 0 && errno == EINTR { continue }
                if size <= 0 { return false }
                position += size
            }
            return true
        }
        return complete ? data : nil
    }
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGALRM, { _ in _exit(74) })
        alarm(8) // bounded native deadline; EOF watcher also works while JS is stuck
        var input = Data()
        while true {
            let chunk = FileHandle.standardInput.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            guard input.count + chunk.count <= 65536 else { fail(71) }
            input.append(chunk)
        }
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              Set(object.keys) == ["source", "scenario"], let source = object["source"] as? String,
              let scenario = object["scenario"] as? String,
              ["a", "b", "off-on", "replace", "read-revoke", "uninstall", "close", "bad-admission"].contains(scenario) else { fail(71) }
        let broker = M0Broker(), seal = String(repeating: "a", count: 64)
        broker.install("a", seal: seal, initial: ["item": "synthetic-a"])
        broker.install("b", seal: seal, initial: ["item": "synthetic-b"])
        let owner = scenario == "b" ? "b" : "a"
        guard let binding = broker.admit(owner, generation: 1, seal: scenario == "bad-admission" ? "wrong" : seal) else {
            print("{\"admissionRejected\":true,\"spawned\":false}"); return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let helper = root.appendingPathComponent("Capsule.app/Contents/MacOS/helper").path
        var life: [Int32] = [0,0], channel: [Int32] = [0,0], sourcePipe: [Int32] = [0,0]
        guard pipe(&life) == 0, socketpair(AF_UNIX, SOCK_STREAM, 0, &channel) == 0, pipe(&sourcePipe) == 0 else { fail() }
        let childLife = fcntl(life[0], F_DUPFD_CLOEXEC, 20)
        let childRPC = fcntl(channel[1], F_DUPFD_CLOEXEC, 20)
        let childInput = fcntl(sourcePipe[0], F_DUPFD_CLOEXEC, 20)
        guard childLife >= 0, childRPC >= 0, childInput >= 0 else { fail() }
        close(life[0]); close(channel[1]); close(sourcePipe[0])
        var attributes: posix_spawnattr_t?, actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0, posix_spawn_file_actions_init(&actions) == 0 else { fail() }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { fail() }
        for (from, to) in [(childInput, Int32(0)), (Int32(1), Int32(1)), (Int32(2), Int32(2)), (childLife, Int32(3)), (childRPC, Int32(4))] {
            guard posix_spawn_file_actions_adddup2(&actions, from, to) == 0 else { fail() }
        }
        var arguments = [strdup(helper), nil], environment = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = -1
        let code = posix_spawn(&pid, helper, &actions, &attributes, &arguments, &environment)
        posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions)
        close(childLife); close(childRPC); close(childInput)
        guard code == 0 else { fail() }
        // Parent/installation IDs never go through JS. The dedicated native channel
        // is bound once to this opaque binding, regardless of guest request fields.
        let payload = try! JSONSerialization.data(withJSONObject: ["source": source])
        guard send(payload, fd: sourcePipe[1]) else { kill(pid, SIGKILL); fail() }
        close(sourcePipe[1])
        var requests = 0
        while let header = receive(4, fd: channel[0]) {
            let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size > 0, size <= 4096, requests < 32, let request = receive(Int(size), fd: channel[0]) else {
                kill(pid, SIGKILL); break
            }
            requests += 1
            let response: Data
            if let work = broker.prepare(request, binding: binding) {
                if requests == 1 {
                    if scenario == "off-on" { broker.setEnabled(owner, false); broker.setEnabled(owner, true) }
                    if scenario == "replace" { broker.replace(owner) }
                    if scenario == "uninstall" { broker.uninstall(owner) }
                }
                let reply = broker.execute(work)
                if requests == 1 {
                    if scenario == "read-revoke" { broker.revokeRead(owner) }
                    if scenario == "close" { broker.close(binding) }
                }
                response = broker.publish(reply)
            } else { response = broker.denied }
            var length = UInt32(response.count).bigEndian
            guard send(Data(bytes: &length, count: 4), fd: channel[0]), send(response, fd: channel[0]) else { break }
        }
        close(channel[0])
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 { if errno != EINTR { fail() } }
        broker.close(binding); close(life[1]); alarm(0)
        let audit: [String: Any] = ["audit": true, "otherNamespaceIntact": broker.audit(owner == "a" ? "b" : "a", key: "item") == (owner == "a" ? "synthetic-b" : "synthetic-a"), "requests": requests]
        FileHandle.standardError.write(try! JSONSerialization.data(withJSONObject: audit))
        // Darwin wait status macros are unavailable to Swift; encode the same bits.
        exit((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }
}
