import CryptoKit
import Darwin
import Foundation
import KeylaneCore
import Virtualization

private typealias GuestFailure = StoreGuestHelperStatus

/// Bounded helper IPC framing. No path, executable, share, or arguments are
/// obtained from the incoming data envelope, broker messages, or extension.
private struct Channel {
    let fd: Int32
    let deadline: DispatchTime
    private func ready(_ mask: Int16) throws {
        try StoreGuestPeerLiveness.waitForSocket(fd, events: mask, until: deadline)
    }
    func read(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        var offset = 0
        while offset < count {
            try ready(Int16(POLLIN))
            let read = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset)
            }
            guard read > 0 else { throw GuestFailure.channel }
            offset += read
        }
        return bytes
    }
    func line() throws -> Data {
        var bytes = Data()
        for _ in 0...16384 {
            let byte = try read(1)
            if byte.first == 10 { return bytes }
            bytes.append(byte)
        }
        throw GuestFailure.channel
    }
    func writeLine(_ value: Data) throws {
        guard !value.isEmpty, value.count <= 16384, !value.contains(10) else { throw GuestFailure.channel }
        var bytes = value
        bytes.append(10)
        var offset = 0
        while offset < bytes.count {
            try ready(Int16(POLLOUT))
            let count = bytes.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            guard count > 0 else { throw GuestFailure.channel }
            offset += count
        }
    }
}

private enum GuestResult: Sendable { case artifact(Data), ran }

@MainActor
private final class GuestRun: NSObject, VZVirtioSocketListenerDelegate {
    let vm: VZVirtualMachine
    let listener = VZVirtioSocketListener()
    let phase: StoreGuestProtocol.Phase
    let envelope: Data
    let deadline: DispatchTime
    var connection: VZVirtioSocketConnection?
    var continuation: CheckedContinuation<GuestResult, Error>?
    var completed = false
    var started = false
    var acknowledgedStop = false
    var pendingStop: GuestFailure?
    var callerMonitor: DispatchSourceTimer?

    init(resources: StoreSignedGuestEngine.Resources, phase: StoreGuestProtocol.Phase, entry: String?,
         session: UUID, envelope: Data, deadline: DispatchTime) throws {
        self.phase = phase
        self.envelope = envelope
        self.deadline = deadline
        let boot = VZLinuxBootLoader(kernelURL: resources.kernelURL)
        boot.initialRamdiskURL = resources.ramdiskURL
        let phaseName = phase == .build ? "store-build" : "store-run"
        boot.commandLine = "console=hvc0 rdinit=/init KEYLANE_PHASE=\(phaseName) KEYLANE_SESSION=\(session.uuidString)"
        if let entry { boot.commandLine += " KEYLANE_STORE_ENTRY=\(entry)" }

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = boot
        config.cpuCount = 1
        config.memorySize = 512 * 1024 * 1024
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        // Deliberately no guest network, shared directory, storage or device permissions.
        do { try config.validate() } catch { throw GuestFailure.configuration }
        vm = VZVirtualMachine(configuration: config, queue: .main)
        super.init()
        listener.delegate = self
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else { throw GuestFailure.request }
        device.setSocketListener(listener, forPort: 4050)
    }

    func execute() async throws -> GuestResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // This observes only app-side EOF; it cannot consume or reorder
            // broker replies. Stop promptly even if the guest is silent.
            let monitor = DispatchSource.makeTimerSource(queue: .main)
            monitor.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(5))
            monitor.setEventHandler { [weak self] in
                if StoreGuestPeerLiveness.peerClosed(STDIN_FILENO) {
                    self?.requestStop(.callerClosed)
                }
            }
            callerMonitor = monitor
            monitor.resume()
            vm.start { result in
                switch result {
                case .success:
                    self.started = true
                    if let failure = self.pendingStop { self.finish(.failure(failure)) }
                case .failure:
                    self.finish(.failure(GuestFailure.boot), started: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: deadline) { self.requestStop(.deadline) }
        }
    }

    private func requestStop(_ failure: GuestFailure) {
        guard !completed, pendingStop == nil else { return }
        pendingStop = failure
        if started { finish(.failure(failure)) }
        else {
            // Bound a start callback that never arrives; cannot claim stop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !self.started && !self.completed { Darwin.exit(GuestFailure.teardown.rawValue) }
            }
        }
    }

    private func finish(_ result: Result<GuestResult, Error>, started: Bool = true) {
        guard !completed, let continuation else { return }
        completed = true
        callerMonitor?.cancel()
        callerMonitor = nil
        self.continuation = nil
        if let connection { _ = shutdown(connection.fileDescriptor, SHUT_RDWR) }
        if !started {
            continuation.resume(with: result)
            return
        }
        // A terminal guest message is insufficient: require confirmed VM stop.
        vm.stop { error in
            self.acknowledgedStop = true
            if error != nil { continuation.resume(throwing: GuestFailure.teardown) }
            else { continuation.resume(with: result) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            // This one-shot process is the owning hypervisor. A stalled
            // Virtualization.framework teardown must not keep an orphan helper.
            if !self.acknowledgedStop { Darwin.exit(GuestFailure.teardown.rawValue) }
        }
    }

    nonisolated func listener(_ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice) -> Bool {
        MainActor.assumeIsolated {
            guard self.connection == nil, !completed else { return false }
            self.connection = connection
            let phase = phase, envelope = envelope, deadline = deadline
            let fd = connection.fileDescriptor
            DispatchQueue.global().async { [self] in
                let result = Result { try GuestRun.serve(phase: phase, envelope: envelope, fd: fd, deadline: deadline) }
                DispatchQueue.main.async {
                    if StoreGuestPeerLiveness.peerClosed(STDIN_FILENO) {
                        self.requestStop(.callerClosed)
                    } else if case let .failure(error) = result {
                        if let failure = error as? GuestFailure, failure == .deadline {
                            self.requestStop(.deadline)
                        } else {
                            self.finish(.failure(GuestFailure.exchange))
                        }
                    } else { self.finish(result) }
                }
            }
            return true
        }
    }

    nonisolated static func serve(phase: StoreGuestProtocol.Phase, envelope: Data, fd: Int32,
                                  deadline: DispatchTime) throws -> GuestResult {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw GuestFailure.channel }
        let guest = Channel(fd: fd, deadline: deadline)
        let caller = Channel(fd: STDIN_FILENO, deadline: deadline)
        let reply = Channel(fd: STDOUT_FILENO, deadline: deadline)
        var protocolState = try StoreGuestProtocol(phase: phase, envelope: envelope)
        try guest.writeLine(protocolState.begin())
        while true {
            switch try protocolState.consume(guest.line()) {
            case let .send(data): try guest.writeLine(data)
            case .continueReading: continue
            case let .broker(data):
                // The app alone interprets/approves this frame against the
                // current generation. The helper cannot invoke host APIs.
                try reply.writeLine(data)
                let answer = try caller.line()
                if answer != Data("{\"kind\":\"ignored-stale\"}".utf8) {
                    try guest.writeLine(answer)
                }
            case let .built(bytes): return .artifact(bytes)
            case .ran: return .ran
            }
        }
    }
}

@main
private struct StoreGuestMain {
    @MainActor
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        do { try await run() }
        catch {
            // No guest frames, paths or secrets in diagnostics.
            FileHandle.standardError.write(Data("Keylane Store guest unavailable or rejected the request.\n".utf8))
            Darwin.exit((error as? GuestFailure ?? .request).rawValue)
        }
    }

    @MainActor
    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 5, let session = UUID(uuidString: arguments[3]),
              ["build", "run", "run-ticket"].contains(arguments[0]) else { throw GuestFailure.request }
        let ticketed = arguments[0] == "run-ticket"
        let phase: StoreGuestProtocol.Phase = arguments[0] == "build" ? .build : .run
        let entry = arguments[4]
        guard (phase == .run && entry == "-") || (phase == .build && validEntry(entry)) else { throw GuestFailure.request }
        let own = Bundle.main
        guard own.object(forInfoDictionaryKey: "KeylaneStoreGuestRecipe") as? String == arguments[2] else { throw GuestFailure.signature }
        let resources: StoreSignedGuestEngine.Resources
        do {
            resources = try StoreSignedGuestEngine.verifiedResources(in: own, trust: .init(
                signingIdentifier: "org.keylane.launcher.store-guest", teamIdentifier: arguments[1],
                recipeIdentifier: arguments[2]))
        } catch { throw GuestFailure.signature }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw GuestFailure.channel }
        }
        // The guest PID1 independently keeps its existing 25-second alarm
        // starting at boot. This earlier supervisor deadline leaves the host
        // responsible for requesting and confirming a typed timeout teardown.
        let deadline = DispatchTime.now() + 24
        let input = Channel(fd: STDIN_FILENO, deadline: deadline)
        let header = try input.read(4)
        let length = header.reduce(0) { $0 * 256 + Int($1) }
        guard length > 0, length <= (phase == .build ? 46 : 6) * 1024 * 1024 else { throw GuestFailure.request }
        let envelope = try input.read(length)
        let run = try GuestRun(resources: resources, phase: phase, entry: phase == .build ? entry : nil,
                               session: session, envelope: envelope, deadline: deadline)
        let output = Channel(fd: STDOUT_FILENO, deadline: deadline)
        let result: GuestResult
        do { result = try await run.execute() }
        catch GuestFailure.callerClosed where ticketed {
            // The host half-closed its write side. GuestRun emits this error
            // only after Virtualization confirmed stop; if boot/teardown did
            // not complete there is no terminal proof.
            try Channel(fd: STDOUT_FILENO, deadline: .now() + 1)
                .writeLine(StoreGuestHelperStopProof.frame(session: session, outcome: .callerClosed))
            return
        }
        switch result {
        case .ran:
            if ticketed {
                try output.writeLine(StoreGuestHelperStopProof.frame(session: session, outcome: .completed))
            } else {
                try output.writeLine(Data("{\"kind\":\"stopped\"}".utf8))
            }
        case let .artifact(data):
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try output.writeLine(JSONSerialization.data(withJSONObject: ["kind": "artifact-start", "bytes": data.count, "sha256": hash]))
            for offset in stride(from: 0, to: data.count, by: 8192) {
                let body = data.subdata(in: offset ..< min(offset + 8192, data.count))
                try output.writeLine(JSONSerialization.data(withJSONObject: ["kind": "artifact-chunk", "offset": offset,
                                                                                "body": body.base64EncodedString()]))
            }
            try output.writeLine(JSONSerialization.data(withJSONObject: ["kind": "artifact-done", "sha256": hash]))
        }
    }

    private static func validEntry(_ value: String) -> Bool {
        guard value.hasPrefix("src/"), value.utf8.count <= 1024,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || [45, 46, 47, 64, 95, 43].contains($0) }) else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix("-") && $0 != "." && $0 != ".."
        }
    }
}
