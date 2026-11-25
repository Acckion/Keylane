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
    @MainActor static func main() async {
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
        var scenarios = ["a", "b", "off-on", "replace", "read-revoke", "uninstall", "close", "bad-admission"]
#if M0_REPLY_FAULTS
        scenarios += ["reply-zero", "reply-huge", "reply-short-header", "reply-short-body", "reply-utf8", "reply-stall"]
#endif
#if M0_RECEIPT
        scenarios = ["receipt"]
#endif
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              Set(object.keys) == ["source", "scenario"], var source = object["source"] as? String,
              let scenario = object["scenario"] as? String,
              scenarios.contains(scenario) else { fail(71) }
        let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let helper = root.appendingPathComponent("Capsule.app/Contents/MacOS/helper").path
        var seal = String(repeating: "a", count: 64)
#if M0_RECEIPT
        let mode = source
        let gate: M0ReceiptGate
        do { gate = try await M0ReceiptGate.open(helper: URL(fileURLWithPath: helper), mode: mode) }
        catch M0ReceiptGate.Failure.rejected {
            print("{\"admissionRejected\":true,\"spawned\":false}"); return
        } catch { fail() }
        source = gate.source; seal = gate.digest
        let ticket = gate.ticket
        let live = { ticket.isCurrent() }
#else
        let live = { true }
#endif
        let broker = M0Broker()
#if M0_RECEIPT
        let owner = ticket.installation.id
        let generation = ticket.installation.generation
        broker.install(owner, seal: seal, initial: ["item": "synthetic-a"], generation: generation,
                       read: ticket.capabilities.contains("storage.read"), write: ticket.capabilities.contains("storage.write"))
#else
        let generation: UInt64 = 1
        broker.install("a", seal: seal, initial: ["item": "synthetic-a"])
        let owner = scenario == "b" ? "b" : "a"
#endif
        broker.install("b", seal: seal, initial: ["item": "synthetic-b"])
        guard let binding = broker.admit(owner, generation: generation, seal: scenario == "bad-admission" ? "wrong" : seal, live: live) else {
            print("{\"admissionRejected\":true,\"spawned\":false}"); return
        }
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
#if M0_RECEIPT
        gate.attach(pid)
#endif
#if M0_MEMORY_OBSERVE_ONLY
        let enforce: Int32 = 0
#else
        let enforce: Int32 = 1
#endif
        guard let memory = M0MemoryGuardStart(pid, 64 * 1024 * 1024, enforce) else { kill(pid, SIGKILL); fail() }
        // Parent/installation IDs never go through JS. The dedicated native channel
        // is bound once to this opaque binding, regardless of guest request fields.
        let payload = try! JSONSerialization.data(withJSONObject: ["source": source])
        guard send(payload, fd: sourcePipe[1]) else { kill(pid, SIGKILL); fail() }
        close(sourcePipe[1])
        var requests = 0
        var transportRejected = false
        var receiptReplyWithheld = false
        channelLoop: while true {
            let request: Data
            switch M0FrameChannel.receive(fd: channel[0]) {
            case .end: break channelLoop
            case .invalid:
                transportRejected = true; kill(pid, SIGKILL); break channelLoop
            case .data(let data): request = data
            }
            guard requests < 32 else {
                kill(pid, SIGKILL); break
            }
            requests += 1
            let response: Data
            if let work = broker.prepare(request, binding: binding) {
#if M0_RECEIPT
                if requests == 1 && ["disable-before", "off-on", "uninstall", "replace", "cas-failure"].contains(mode) {
                    do { try await gate.advance(mode) } catch { fail() }
                }
#endif
                if requests == 1 {
                    if scenario == "off-on" { broker.setEnabled(owner, false); broker.setEnabled(owner, true) }
                    if scenario == "replace" { broker.replace(owner) }
                    if scenario == "uninstall" { broker.uninstall(owner) }
                }
                let reply = broker.execute(work)
#if M0_RECEIPT
                if requests == 1 && mode == "disable-after" {
                    do { try await gate.advance(mode) } catch { fail() }
                }
#endif
                if requests == 1 {
                    if scenario == "read-revoke" { broker.revokeRead(owner) }
                    if scenario == "close" { broker.close(binding) }
                }
                response = broker.publish(reply)
#if M0_RECEIPT
                receiptReplyWithheld = response == broker.denied && !gate.current
#endif
            } else { response = broker.denied }
#if M0_REPLY_FAULTS
            // First-party signed negative-control binary only. Not a JS API.
            if requests == 1 && scenario.hasPrefix("reply-") {
                if scenario == "reply-stall" {
                    FileHandle.standardError.write(Data("{\"replyHeld\":true}\n".utf8))
                    continue // native receive blocks; deadline/EOF must still work
                }
                let bad: Data
                switch scenario {
                case "reply-zero": bad = Data([0,0,0,0])
                case "reply-huge": bad = Data([255,255,255,255])
                case "reply-short-header": bad = Data([0,0])
                case "reply-short-body": bad = Data([0,0,0,10,123])
                default: bad = Data([0,0,0,1,255])
                }
                _ = send(bad, fd: channel[0]); shutdown(channel[0], SHUT_WR)
                continue
            }
#endif
            var length = UInt32(response.count).bigEndian
            guard send(Data(bytes: &length, count: 4), fd: channel[0]), send(response, fd: channel[0]) else { break }
        }
        close(channel[0])
        // Join before reaping: watcher only signals our unreaped child's PID.
        var peak: UInt64 = 0
        var exceeded: Int32 = 0, observationFailed: Int32 = 0
        M0MemoryGuardStop(memory, &peak, &exceeded, &observationFailed)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 { if errno != EINTR { fail() } }
        broker.close(binding); close(life[1]); alarm(0)
        var audit: [String: Any] = ["audit": true, "otherNamespaceIntact": broker.audit(owner == "b" ? "a" : "b", key: "item") == (owner == "b" ? "synthetic-a" : "synthetic-b"), "requests": requests,
                                   "transportRejected": transportRejected, "peakResidentBytes": peak,
                                   "memoryExceeded": exceeded != 0, "memoryObservationFailed": observationFailed != 0]
#if M0_RECEIPT
        audit["receiptCurrent"] = gate.current; audit["receiptReplyWithheld"] = receiptReplyWithheld
        audit["stopConfirmed"] = gate.stopped; audit["freshAdmission"] = gate.freshAdmission
#endif
        FileHandle.standardError.write(try! JSONSerialization.data(withJSONObject: audit))
        // Darwin wait status macros are unavailable to Swift; encode the same bits.
        if observationFailed != 0 { fail() }
        if transportRejected { fail(71) }
        exit((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }
}
