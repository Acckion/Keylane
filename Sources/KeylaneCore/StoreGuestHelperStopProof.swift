import Foundation

/// A terminal frame emitted by the signed helper on its private socket, not
/// by the extension. The caller must independently observe successful exit
/// of that exact Child. A process exit or socket EOF is insufficient alone.
package enum StoreGuestHelperStopProof {
    package enum Outcome: String, Sendable { case completed, callerClosed }

    package static func frame(session: UUID, outcome: Outcome) -> Data {
        Data(("{\"kind\":\"ticket-stop\",\"outcome\":\"" + outcome.rawValue +
              "\",\"session\":\"" + session.uuidString + "\"}").utf8)
    }

    package static func verify(_ received: Data, session: UUID, outcome: Outcome,
                               helperExitedSuccessfully: Bool) -> Bool {
        helperExitedSuccessfully && received == frame(session: session, outcome: outcome)
    }
}
