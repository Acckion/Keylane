import CryptoKit
import Darwin
import Foundation
import Security

/// App-side part of the nested signed helper. It shares no host file or user
/// environment; the sole effects available to a guest are what the app broker
/// explicitly grants to this currently enabled installation.
@MainActor
public struct StoreGuestProcessDriver: StoreSignedGuestEngine.Driver {
    public enum Failure: Error {
        case revoked, channel, helper, artifact, childStopUnconfirmed
        case helperStatus(StoreGuestHelperStatus)
    }
    public enum Capability: Sendable { case toast, clipboardCopy, hud, preferencesRead }

    private let teamIdentifier: String
    private let isCurrent: @MainActor (StoreRuntimeBridge.Installation) -> Bool
    private let launchContext: @MainActor (StoreRuntimeBridge.Installation, StoreRuntimeBridge.Receipt) throws -> StoreGuestLaunchContext
    private let grants: @MainActor (StoreRuntimeBridge.Installation) -> Set<Capability>
    private let ticketHost: StoreGuestTicketHost?
    private let handle: @MainActor (StoreRuntimeBridge.Installation, Capability, String) throws -> String

    public init(
        teamIdentifier: String,
        isCurrent: @escaping @MainActor (StoreRuntimeBridge.Installation) -> Bool,
        grants: @escaping @MainActor (StoreRuntimeBridge.Installation) -> Set<Capability>,
        launchContext: @escaping @MainActor (StoreRuntimeBridge.Installation, StoreRuntimeBridge.Receipt) throws -> StoreGuestLaunchContext = { _, _ in .init() },
        handle: @escaping @MainActor (StoreRuntimeBridge.Installation, Capability, String) throws -> String
    ) {
        self.ticketHost = nil
        self.teamIdentifier = teamIdentifier
        self.isCurrent = isCurrent
        self.grants = grants
        self.launchContext = launchContext
        self.handle = handle
    }

    /// Deliberately package-only and inactive until an app-owned native
    /// transport owns Child spawn, authenticated replies and confirmed exit.
    package init(teamIdentifier: String, ticketHost: StoreGuestTicketHost) {
        self.teamIdentifier = teamIdentifier
        self.ticketHost = ticketHost
        self.isCurrent = { _ in false }
        self.grants = { _ in [] }
        self.launchContext = { _, _ in throw Failure.revoked }
        self.handle = { _, _, _ in throw Failure.revoked }
    }

    /// Still has no normal product caller. The native child is never derived
    /// from a public Resources value alone: capture the actual installed
    /// app's signed helper, verify its seal, then authenticate its exact PID.
    package static func nativeTicketHost(application: Bundle, teamIdentifier: String, recipeIdentifier: String,
        authority: any StoreGuestTicketHost.Authority,
        sink: @escaping (StoreGuestRunTicket, String, String) throws -> String) -> StoreGuestTicketHost {
        StoreGuestTicketHost(authority: authority, spawn: { resources, artifact, ticket in
            let path = application.bundleURL.resolvingSymlinksInPath().appendingPathComponent("Contents/Helpers/KeylaneStoreGuest.app")
            guard path.resolvingSymlinksInPath().path == path.path, let bundle = Bundle(url: path) else { throw Failure.helper }
            let verified = try StoreSignedGuestEngine.verifiedResources(in: bundle, trust: .init(
                signingIdentifier: "org.keylane.launcher.store-guest", teamIdentifier: teamIdentifier, recipeIdentifier: recipeIdentifier))
            guard resources.digest == verified.digest, resources.recipeIdentifier == verified.recipeIdentifier,
                  let expectedCode = verified.codeDirectoryHash,
                  resources.codeDirectoryHash == expectedCode,
                  bundle.object(forInfoDictionaryKey: "KeylaneStoreGuestRecipe") as? String == recipeIdentifier else { throw Failure.helper }
            let envelope = try TicketChild.envelope(artifact: artifact, ticket: ticket)
            let executable = try helperExecutable(resources: verified)
            let child = try Child(executable: executable,
                arguments: ["run-ticket", teamIdentifier, recipeIdentifier, ticket.id.uuidString, "-"])
            do { try child.authenticateTicketHelper(team: teamIdentifier, expectedCode: expectedCode) }
            catch { child.requestStop(); Task.detached { try? child.confirmStop() }; throw error }
            return TicketChild(ticket: ticket, envelope: envelope, io: .init(
                send: { data in try await Task.detached {
                    // Repeat PID-bound check immediately before writing data;
                    // no old process identity stands in for a live recipient.
                    try child.authenticateTicketHelper(team: teamIdentifier, expectedCode: expectedCode)
                    try child.sendEnvelope(data, maximum: 6 * 1024 * 1024)
                }.value },
                read: { try await Task.detached { try child.io.readLine() }.value },
                reply: { data in try await Task.detached { try child.io.write(data) }.value },
                halfClose: { try child.requestTicketStop() },
                prove: { frame, id, outcome in
                    try await Task.detached { try child.requireTicketStopProof(frame, session: id, outcome: outcome) }.value
                },
                interrupt: { child.requestStop(); Task.detached { try? child.confirmStop() } }))
        }, sink: sink)
    }

    public var supportsTicketedLaunch: Bool { ticketHost != nil }

    public func runInFreshGuest(resources: StoreSignedGuestEngine.Resources, artifact: Data,
                                ticket: StoreGuestRunTicket) async throws {
        guard let ticketHost else { throw Failure.revoked }
        try await ticketHost.run(resources: resources, artifact: artifact, ticket: ticket)
    }

    public func buildInFreshGuest(
        resources: StoreSignedGuestEngine.Resources, envelope: Data, entry: String
    ) async throws -> Data {
        let process = try start(resources: resources, mode: "build", id: UUID(), entry: entry)
        let artifact = try await process.supervise {
            try await Task.detached {
                try process.sendEnvelope(envelope, maximum: 46 * 1024 * 1024)
                var parsed = ArtifactFrames()
                while let bytes = try process.io.readLine() {
                    if let data = try parsed.consume(bytes) {
                        try process.requireSuccess()
                        return data
                    }
                }
                try process.requireSuccess()
                throw Failure.helper
            }.value
        }
        try Task.checkCancellation()
        return artifact
    }

    public func runInFreshGuest(
        resources: StoreSignedGuestEngine.Resources, artifact: Data, receipt: StoreRuntimeBridge.Receipt,
        installation: StoreRuntimeBridge.Installation
    ) async throws {
        guard isCurrent(installation) else { throw Failure.revoked }
        let capabilities = grants(installation)
        let context = try launchContext(installation, receipt)
        let launch = try context.launchData(loadPreferences: capabilities.contains(.preferencesRead))
        let ordinaryPreferences = capabilities.contains(.preferencesRead) ? try context.preferencesReply() : nil
        let launchHash = SHA256.hash(data: launch).map { String(format: "%02x", $0) }.joined()
        let envelope = try JSONSerialization.data(withJSONObject: ["version": 1, "files": [
            ["path": "bundle.cjs", "body": artifact.base64EncodedString(), "sha256": receipt.artifactDigest],
            ["path": "launch.json", "body": launch.base64EncodedString(), "sha256": launchHash]
        ]])
        let id = UUID()
        let session = Broker(id: id, installation: installation, isCurrent: isCurrent, grants: capabilities, ordinaryPreferences: ordinaryPreferences, handle: handle)
        let process = try start(resources: resources, mode: "run", id: id, entry: "-")
        let watch = Task { @MainActor in
            while !Task.isCancelled, process.process.isRunning {
                guard isCurrent(installation) else {
                    session.cancel()
                    process.requestStop()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            watch.cancel()
            session.cancel()
        }
        try await process.supervise {
            try await Task.detached {
                try process.sendEnvelope(envelope, maximum: 6 * 1024 * 1024)
                while let bytes = try process.io.readLine() {
                    let header = try JSONDecoder().decode(Kind.self, from: bytes)
                    if header.kind == "stopped" {
                        try await session.finish()
                        try process.requireSuccess()
                        return
                    }
                    guard header.kind == "hello" || header.kind == "request" else { throw Failure.channel }
                    try process.io.write(try await session.receive(bytes))
                }
                try process.requireSuccess()
                throw Failure.helper
            }.value
        }
        guard isCurrent(installation) else { throw Failure.revoked }
        try Task.checkCancellation()
    }

    private func start(resources: StoreSignedGuestEngine.Resources, mode: String, id: UUID, entry: String) throws -> Child {
        let executable = try Self.helperExecutable(resources: resources)
        return try Child(executable: executable,
                         arguments: [mode, teamIdentifier, resources.recipeIdentifier, id.uuidString, entry])
    }

    static func helperExecutable(resources: StoreSignedGuestEngine.Resources) throws -> URL {
        // Compare resolved filesystem paths, not URL object equality: Cocoa
        // may add a different directory hint/URL representation without
        // changing the signed executable at that filesystem path.
        let contents = resources.kernelURL.deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let executable = contents.appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("KeylaneStoreGuest", isDirectory: false)
        let resolved = executable.resolvingSymlinksInPath()
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resolved.path == executable.path,
              resolved.deletingLastPathComponent().deletingLastPathComponent().path == contents.path,
              values.isRegularFile == true, values.isSymbolicLink == false else { throw Failure.helper }
        return resolved
    }

    private struct Kind: Decodable { let kind: String }

    @MainActor
    final class Broker {
        private var session: ExtensionPrototypeSession
        private let installation: StoreRuntimeBridge.Installation
        private let isCurrent: @MainActor (StoreRuntimeBridge.Installation) -> Bool
        init(id: UUID, installation: StoreRuntimeBridge.Installation,
             isCurrent: @escaping @MainActor (StoreRuntimeBridge.Installation) -> Bool, grants: Set<Capability>,
             ordinaryPreferences: String? = nil,
             authorize: (@MainActor (Capability, String) throws -> String)? = nil,
             handle: @escaping @MainActor (StoreRuntimeBridge.Installation, Capability, String) throws -> String) {
            self.installation = installation
            self.isCurrent = isCurrent
            // Wire generation 1 is a fresh guest's handshake, distinct from
            // the durable installation generation pinned by this closure.
            let configured: Set<ExtensionPrototypeSession.Capability> = Set(grants.map { grant in
                switch grant {
                case .toast: return .toast
                case .hud: return .hud
                case .clipboardCopy: return .clipboardCopy
                case .preferencesRead: return .preferencesRead
                }
            })
            session = ExtensionPrototypeSession(id: id, generation: 1, grants: configured) { cap, text in
                try MainActor.assumeIsolated {
                    @MainActor func perform(_ capability: Capability, _ input: String) throws -> String {
                        if let authorize { return try authorize(capability, input) }
                        return try handle(installation, capability, input)
                    }
                    switch cap {
                    case .toast: return try perform(.toast, text)
                    case .clipboardCopy:
                        guard text.utf8.count <= 4096 else { throw Failure.channel }
                        return try perform(.clipboardCopy, text)
                    case .hud:
                        let feedback = try JSONDecoder().decode(HUD.self, from: Data(text.utf8))
                        guard feedback.text.utf8.count <= 2048 else { throw Failure.channel }
                        // Do not pass guest navigation/clear-search fields up.
                        return try perform(.hud, feedback.text)
                    case .preferencesRead:
                        guard text.isEmpty else { throw Failure.channel }
                        if let authorize { return try authorize(.preferencesRead, text) }
                        guard let ordinaryPreferences else { throw Failure.channel }
                        return ordinaryPreferences
                    default: throw Failure.revoked
                    }
                }
            }
        }
        private struct HUD: Decodable { let text: String }

        func receive(_ line: Data) throws -> Data {
            // One MainActor turn: no suspension between authorization and effect.
            guard isCurrent(installation) else { cancel(); throw Failure.revoked }
            do {
                return try ExtensionPrototypeSession.encode(session.receive(line), session: session.id, generation: session.generation)
            } catch ExtensionPrototypeSession.Rejection.stale {
                // The existing guest API uses a stale generation probe at
                // connection time. Count it but never send it a guest reply.
                return Data("{\"kind\":\"ignored-stale\"}\n".utf8)
            }
        }
        func finish() throws {
            guard isCurrent(installation) else { cancel(); throw Failure.revoked }
            try session.finishInput()
        }
        func cancel() { session.cancel() }
    }

    @MainActor final class TicketChild: StoreGuestTicketHost.Process {
        struct IO {
            let send: (Data) async throws -> Void
            let read: () async throws -> Data?
            let reply: (Data) async throws -> Void
            let halfClose: () throws -> Void
            let prove: (Data, UUID, StoreGuestHelperStopProof.Outcome) async throws -> Void
            var interrupt: () -> Void = {}
        }
        private let ticket: StoreGuestRunTicket
        private let envelope: Data
        private let io: IO
        private var reading = false
        private var terminal = false
        private var stopRequest: UUID?
        private var confirmedStop: UUID?
        init(ticket: StoreGuestRunTicket, envelope: Data, io: IO) { self.ticket = ticket; self.envelope = envelope; self.io = io }

        static func envelope(artifact: Data, ticket: StoreGuestRunTicket) throws -> Data {
            guard !artifact.isEmpty, artifact.count <= 4 * 1024 * 1024,
                  SHA256.hash(data: artifact).map({ String(format: "%02x", $0) }).joined() == ticket.receipt.artifactDigest
            else { throw Failure.artifact }
            let launch = try ticket.launchContext.launchData(loadPreferences: ticket.capabilities.contains("preferences.read"))
            let hash = SHA256.hash(data: launch).map { String(format: "%02x", $0) }.joined()
            return try JSONSerialization.data(withJSONObject: ["version": 1, "files": [
                ["path": "bundle.cjs", "body": artifact.base64EncodedString(), "sha256": ticket.receipt.artifactDigest],
                ["path": "launch.json", "body": launch.base64EncodedString(), "sha256": hash]
            ]])
        }

        func run(effect: @escaping @MainActor (String, String) throws -> String) async throws -> StoreGuestTicketHost.ExitEvidence {
            guard !reading, !terminal else { throw Failure.channel }
            reading = true
            defer {
                reading = false
                terminal = true
                io.interrupt()
            }
            let available: [(String, Capability)] = [("feedback.toast", .toast), ("clipboard.copy", .clipboardCopy),
                ("feedback.hud", .hud), ("preferences.read", .preferencesRead)]
            let capabilities = Set(available.filter { ticket.capabilities.contains($0.0) }.map { $0.1 })
            let broker = Broker(id: ticket.id, installation: ticket.installation, isCurrent: { [ticket] _ in ticket.isCurrent() },
                grants: capabilities, authorize: { capability, input in
                    guard let key = available.first(where: { $0.1 == capability })?.0 else { throw Failure.revoked }
                    return try effect(key, input)
                }) { _, _, _ in throw Failure.revoked }
            defer { broker.cancel() }
            try await io.send(envelope)
            // Sole reader for both broker events and helper-authored terminal proof.
            while let frame = try await io.read() {
                let kind = try JSONDecoder().decode(Kind.self, from: frame).kind
                if kind == "ticket-stop" {
                    let request = stopRequest
                    // A natural completion racing a revoke is never
                    // relabeled as that revoke's acknowledgment. A mismatch
                    // leaves the installation quarantined, even if Child exited.
                    let outcome: StoreGuestHelperStopProof.Outcome = request == nil ? .completed : .callerClosed
                    try await io.prove(frame, ticket.id, outcome)
                    if let request { confirmedStop = request } else { try broker.finish() }
                    return .init(ticketID: ticket.id, authenticatedCompletion: true, helperExited: true)
                }
                guard kind == "hello" || kind == "request" else { throw Failure.channel }
                if stopRequest != nil { continue }
                // Policy and sink run synchronously on the MainActor. A stop
                // during the async reply can make that write fail; keep reading
                // instead of tearing down the private proof channel.
                let answer = try broker.receive(frame)
                do { try await io.reply(answer) }
                catch { if stopRequest == nil { throw error } }
            }
            throw Failure.childStopUnconfirmed
        }

        func prepareStop(_ request: StoreGuestTicketHost.Revocation) throws {
            guard request.profileID == ticket.profileID, request.installationID == ticket.installation.id,
                  ticket.installation.generation < request.beforeGeneration else { throw Failure.revoked }
            if let pending = stopRequest { guard pending == request.id else { throw Failure.childStopUnconfirmed } }
            else {
                guard !terminal else { throw Failure.childStopUnconfirmed }
                try io.halfClose()
                stopRequest = request.id
            }
        }
        func stop(_ request: StoreGuestTicketHost.Revocation,
                  deadline: ContinuousClock.Instant) async throws -> StoreGuestTicketHost.StopEvidence {
            try prepareStop(request)
            while confirmedStop != request.id {
                guard !terminal, ContinuousClock.now < deadline else { throw Failure.childStopUnconfirmed }
                try await Task.sleep(for: .milliseconds(5))
            }
            return .init(ticketID: ticket.id, revocationID: request.id, acknowledged: true, helperExited: true)
        }
    }

    struct ArtifactFrames {
        private struct Frame: Decodable {
            let kind: String
            let bytes: Int?
            let sha256: String?
            let offset: Int?
            let body: String?
        }
        private var size: Int?
        private var digest: String?
        private var content = Data()

        mutating func consume(_ data: Data) throws -> Data? {
            let frame = try JSONDecoder().decode(Frame.self, from: data)
            switch frame.kind {
            case "artifact-start":
                guard size == nil, let length = frame.bytes, 1...4 * 1024 * 1024 ~= length,
                      let digest = frame.sha256, digest.utf8.count == 64,
                      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.artifact }
                size = length
                self.digest = digest
                return nil
            case "artifact-chunk":
                guard let size, frame.offset == content.count, let body = frame.body, body.utf8.count <= 10924,
                      let part = Data(base64Encoded: body), part.base64EncodedString() == body,
                      !part.isEmpty, part.count == min(8192, size - content.count) else { throw Failure.artifact }
                content.append(part)
                return nil
            case "artifact-done":
                guard let size, let digest, content.count == size, frame.sha256 == digest,
                      SHA256.hash(data: content).map({ String(format: "%02x", $0) }).joined() == digest else { throw Failure.artifact }
                return content
            default: throw Failure.artifact
            }
        }
    }

    final class Child: @unchecked Sendable {
        let process = Process()
        fileprivate let io: SocketIO
        init(executable: URL, arguments: [String]) throws {
            var sockets: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw Failure.channel }
            let child = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
            do { try SocketIO.configure(sockets[0]) }
            catch { _ = Darwin.close(sockets[0]); throw error }
            io = SocketIO(fd: sockets[0])
            process.executableURL = executable
            process.arguments = arguments
            process.environment = [:]
            process.standardInput = child
            process.standardOutput = child
            process.standardError = FileHandle.nullDevice
            do { try process.run() }
            catch { try? child.close(); throw error }
            try? child.close()
        }
        func sendEnvelope(_ envelope: Data, maximum: Int) throws {
            guard !envelope.isEmpty, envelope.count <= maximum else { throw Failure.channel }
            var size = UInt32(envelope.count).bigEndian
            try io.write(withUnsafeBytes(of: &size) { Data($0) })
            try io.write(envelope)
        }
        func requestStop() { io.interrupt() }

        /// Ticketed cooperative stop closes only app-to-helper traffic so
        /// the sole reader can receive the signed helper's final proof.
        /// Never reinterpret the legacy full shutdown as this request.
        func requestTicketStop() throws { try io.finishWriting() }

        /// Check the actually spawned PID against the exact sealed CodeDirectory
        /// before sending it bytes. The runtime requirement verifies the CDHash
        /// tied to the live SecCode, not a fresh pathname lookup alone.
        func authenticateTicketHelper(team: String, expectedCode: Data) throws {
            guard process.isRunning else { throw Failure.helper }
            var requirement: SecRequirement?
            var running: SecCode?
            var runningStatic: SecStaticCode?
            let identity = try Self.exactCodeRequirement(team: team, expectedCode: expectedCode)
            guard SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
                  let requirement,
                  SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: process.processIdentifier] as CFDictionary, [], &running) == errSecSuccess,
                  let running, SecCodeCheckValidity(running, [], requirement) == errSecSuccess,
                  SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
                  Self.matchesCode(expected: expectedCode, observed: StoreSignedGuestEngine.codeDirectoryHash(runningStatic),
                                   stillRunning: process.isRunning) else { throw Failure.helper }
        }

        static func exactCodeRequirement(team: String, expectedCode: Data) throws -> String {
            guard expectedCode.count == 20, !team.isEmpty, team.utf8.count <= 128,
                  team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { throw Failure.helper }
            let exact = expectedCode.map { String(format: "%02x", $0) }.joined()
            return "anchor apple generic and identifier \"org.keylane.launcher.store-guest\" and certificate leaf[subject.OU] = \"\(team)\" and cdhash H\"\(exact)\""
        }

        static func matchesCode(expected: Data, observed: Data?, stillRunning: Bool) -> Bool {
            stillRunning && expected.count == 20 && observed == expected
        }

        func requireTicketStopProof(_ frame: Data, session: UUID, outcome: StoreGuestHelperStopProof.Outcome) throws {
            try requireSuccess()
            guard StoreGuestHelperStopProof.verify(frame, session: session, outcome: outcome,
                                                     helperExitedSuccessfully: true) else {
                throw Failure.childStopUnconfirmed
            }
        }

        @MainActor
        func supervise<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
            let result: Result<T, Error>
            do {
                result = .success(try await withTaskCancellationHandler(operation: operation) { self.requestStop() })
            } catch {
                result = .failure(error)
            }
            try await Task.detached { try self.confirmStop() }.value
            return try result.get()
        }

        /// Socket shutdown is the cooperative stop. If it does not stop our
        /// owned one-shot helper, send TERM and independently observe its exit.
        /// Never tell the app this stopped the VM unless it returned its own
        /// confirmed Virtualization stop receipt in the normal successful path.
        func confirmStop() throws {
            requestStop()
            wait(for: .now() + 1)
            if process.isRunning { process.terminate() }
            wait(for: .now() + 2)
            guard !process.isRunning else { throw Failure.childStopUnconfirmed }
        }

        func requireSuccess() throws {
            wait(for: io.deadline)
            guard !process.isRunning, process.terminationReason == .exit else { throw Failure.helper }
            if process.terminationStatus == 0 { return }
            if let status = StoreGuestHelperStatus(rawValue: process.terminationStatus) { throw Failure.helperStatus(status) }
            throw Failure.helper
        }

        private func wait(for deadline: DispatchTime) {
            while process.isRunning && deadline > .now() { Thread.sleep(forTimeInterval: 0.005) }
        }
    }

    fileprivate final class SocketIO: @unchecked Sendable {
        let fd: Int32
        let deadline = DispatchTime.now() + 35
        init(fd: Int32) { self.fd = fd }
        static func configure(_ fd: Int32) throws {
            var noSignal: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.channel }
        }
        deinit { _ = Darwin.close(fd) }
        func interrupt() { _ = shutdown(fd, SHUT_RDWR) }
        func finishWriting() throws {
            guard shutdown(fd, SHUT_WR) == 0 else { throw Failure.channel }
        }

        private func ready(_ events: Int16) throws {
            let remaining = deadline.uptimeNanoseconds
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < remaining else { throw Failure.channel }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            guard poll(&descriptor, 1, Int32(clamping: (remaining - now) / 1_000_000 + 1)) > 0,
                  descriptor.revents & (events | Int16(POLLHUP)) != 0 else { throw Failure.channel }
        }

        func readLine() throws -> Data? {
            var line = Data()
            for _ in 0...16384 {
                try ready(Int16(POLLIN))
                var byte: UInt8 = 0
                let count = Darwin.read(fd, &byte, 1)
                if count == 0 && line.isEmpty { return nil }
                guard count == 1 else { throw Failure.channel }
                if byte == 10 { return line }
                line.append(byte)
            }
            throw Failure.channel
        }

        func write(_ data: Data) throws {
            var offset = 0
            while offset < data.count {
                try ready(Int16(POLLOUT))
                let count = data.withUnsafeBytes {
                    Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
                }
                guard count > 0 else { throw Failure.channel }
                offset += count
            }
        }
    }
}
