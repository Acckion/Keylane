import Foundation

/// Default-off native-driver composition boundary. Its transport is supplied
/// by app-owned code, never by a Store package or guest payload.
@MainActor
package final class StoreGuestTicketHost {
    package enum Failure: Error, Equatable { case denied, stopUnconfirmed }
    package struct Revocation: Sendable {
        let id: UUID
        let profileID: UUID
        let installationID: String
        let beforeGeneration: UInt64
    }
    package struct StopEvidence: Sendable {
        let ticketID: UUID
        let revocationID: UUID
        /// Attested by the app-owned transport after validating the private
        /// helper channel and observing exit of the spawned process.
        let acknowledged: Bool
        let helperExited: Bool
    }
    package struct ExitEvidence: Sendable {
        let ticketID: UUID
        let authenticatedCompletion: Bool
        let helperExited: Bool
    }
    @MainActor package protocol Process: AnyObject {
        func run(effect: @escaping @MainActor (String, String) throws -> String) async throws -> ExitEvidence
        func prepareStop(_ request: Revocation) throws
        func stop(_ request: Revocation, deadline: ContinuousClock.Instant) async throws -> StopEvidence
    }

    /// The synchronous authority invokes the supplied closure inside its own
    /// policy boundary. There is no Boolean authorization carried across a turn.
    @MainActor package protocol Authority: AnyObject {
        func start(_ ticket: StoreGuestRunTicket, spawn: () throws -> any Process) throws -> any Process
        func effect(_ ticket: StoreGuestRunTicket, capability: String, apply: () throws -> String) throws -> String
        func authorizeRevocation(_ request: Revocation) throws
    }

    private let authority: any Authority
    private let spawn: (StoreSignedGuestEngine.Resources, Data, StoreGuestRunTicket) throws -> any Process
    private let sink: (StoreGuestRunTicket, String, String) throws -> String
    private struct Session {
        let ticket: StoreGuestRunTicket
        let process: any Process
        var revocationID: UUID? = nil
        var unconfirmed = false
    }
    private var sessions: [UUID: Session] = [:]

    package init(authority: any Authority,
                 spawn: @escaping (StoreSignedGuestEngine.Resources, Data, StoreGuestRunTicket) throws -> any Process,
                 sink: @escaping (StoreGuestRunTicket, String, String) throws -> String) {
        self.authority = authority; self.spawn = spawn; self.sink = sink
    }

    func run(resources: StoreSignedGuestEngine.Resources, artifact: Data, ticket: StoreGuestRunTicket) async throws {
        guard sessions[ticket.id] == nil else { throw Failure.denied }
        let process = try authority.start(ticket) {
            guard ticket.consumeForStart() else { throw Failure.denied }
            return try spawn(resources, artifact, ticket)
        }
        sessions[ticket.id] = .init(ticket: ticket, process: process)
        do {
            let exit = try await process.run { [weak self] capability, input in
                guard let self, let session = self.sessions[ticket.id],
                      session.revocationID == nil, !session.unconfirmed else { throw Failure.denied }
                return try self.authority.effect(ticket, capability: capability) {
                    guard ticket.allowsEffect(capability) else { throw Failure.denied }
                    if capability == "preferences.read" {
                        guard input.isEmpty else { throw Failure.denied }
                        return try ticket.launchContext.preferencesReply()
                    }
                    return try self.sink(ticket, capability, input)
                }
            }
            // The transport may only return normally after authenticated
            // normal completion and observing helper exit.
            guard exit.ticketID == ticket.id, exit.authenticatedCompletion, exit.helperExited else {
                throw Failure.stopUnconfirmed
            }
            if sessions[ticket.id]?.revocationID == nil, sessions[ticket.id]?.unconfirmed == false {
                sessions[ticket.id] = nil
            }
        } catch {
            // A channel/error result is not positive proof the helper stopped.
            if sessions[ticket.id]?.revocationID == nil {
                sessions[ticket.id]?.unconfirmed = true
            }
            throw error
        }
    }

    /// Authenticator must verify the exact request and advance the same live
    /// authority watermark that bounds start/effects. It must not suspend.
    package func revoke(_ request: Revocation, timeout: Duration) async throws {
        try authority.authorizeRevocation(request)
        let affected = sessions.values.filter {
            $0.ticket.profileID == request.profileID && $0.ticket.installation.id == request.installationID &&
            $0.ticket.installation.generation < request.beforeGeneration
        }
        for session in affected {
            guard sessions[session.ticket.id]?.revocationID == nil else { throw Failure.stopUnconfirmed }
        }
        // Gate all affected sessions before the first asynchronous transport action.
        for session in affected { sessions[session.ticket.id]?.revocationID = request.id }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var failed = false
        var prepared: [Session] = []
        // Associate the authenticated request and close writes synchronously
        // before an already scheduled broker read/reply can resume.
        for session in affected {
            do { try session.process.prepareStop(request); prepared.append(session) }
            catch {
                failed = true
                sessions[session.ticket.id]?.revocationID = nil
                sessions[session.ticket.id]?.unconfirmed = true
            }
        }
        for session in prepared {
            let id = session.ticket.id
            do {
                let proof = try await awaitStop(session.process, request: request, deadline: deadline)
                guard ContinuousClock.now <= deadline, proof.ticketID == id, proof.revocationID == request.id,
                      proof.acknowledged, proof.helperExited else { throw Failure.stopUnconfirmed }
                sessions[id] = nil
            } catch {
                failed = true
                sessions[id]?.revocationID = nil
                sessions[id]?.unconfirmed = true
            }
        }
        guard !failed else { throw Failure.stopUnconfirmed }
    }
    @MainActor private final class StopAttempt {
        var completion: CheckedContinuation<StopEvidence, Error>?
        func resolve(_ result: Result<StopEvidence, Error>) {
            guard let continuation = completion else { return }
            completion = nil
            continuation.resume(with: result)
        }
    }

    private func awaitStop(_ process: any Process, request: Revocation,
                           deadline: ContinuousClock.Instant) async throws -> StopEvidence {
        guard ContinuousClock.now < deadline else { throw Failure.stopUnconfirmed }
        let attempt = StopAttempt()
        return try await withCheckedThrowingContinuation { continuation in
            attempt.completion = continuation
            let operation = Task { @MainActor in
                do { attempt.resolve(.success(try await process.stop(request, deadline: deadline))) }
                catch { attempt.resolve(.failure(error)) }
            }
            Task { @MainActor in
                try? await ContinuousClock().sleep(until: deadline)
                attempt.resolve(.failure(Failure.stopUnconfirmed))
                operation.cancel()
            }
        }
    }

}


extension StoreGuestTicketHost.Process {
    // Inert/alternate transports may have no synchronous write channel.
    package func prepareStop(_ request: StoreGuestTicketHost.Revocation) throws {}
}
