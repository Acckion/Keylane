import Darwin
import Foundation
import XCTest
@testable import KeylaneCore

final class StoreGuestHelperStopProofTests: XCTestCase {
    func testSessionOutcomeAndObservedExitAreAllRequired() {
        let session = UUID()
        let frame = StoreGuestHelperStopProof.frame(session: session, outcome: .callerClosed)
        XCTAssertTrue(StoreGuestHelperStopProof.verify(frame, session: session, outcome: .callerClosed,
                                                      helperExitedSuccessfully: true))
        XCTAssertFalse(StoreGuestHelperStopProof.verify(frame, session: session, outcome: .callerClosed,
                                                       helperExitedSuccessfully: false))
        XCTAssertFalse(StoreGuestHelperStopProof.verify(frame, session: UUID(), outcome: .callerClosed,
                                                       helperExitedSuccessfully: true))
        XCTAssertFalse(StoreGuestHelperStopProof.verify(frame, session: session, outcome: .completed,
                                                       helperExitedSuccessfully: true))
        XCTAssertFalse(StoreGuestHelperStopProof.verify(Data(#"{"kind":"stopped"}"#.utf8),
                                                       session: session, outcome: .callerClosed, helperExitedSuccessfully: true))
    }

    func testHalfCloseLeavesPrivateSocketAvailableForProof() throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { XCTFail("socketpair failed"); return }
        defer { pair.forEach { _ = close($0) } }
        let parent = pair[0], helper = pair[1]
        XCTAssertEqual(shutdown(parent, SHUT_WR), 0)
        XCTAssertTrue(StoreGuestPeerLiveness.peerClosed(helper))
        let session = UUID()
        let frame = StoreGuestHelperStopProof.frame(session: session, outcome: .callerClosed)
        let written = frame.withUnsafeBytes { write(helper, $0.baseAddress!, $0.count) }
        XCTAssertEqual(written, frame.count)
        var received = Data(count: frame.count)
        let count = received.withUnsafeMutableBytes { read(parent, $0.baseAddress!, $0.count) }
        XCTAssertEqual(count, frame.count)
        // The frame is real; exit observation is still independent and mandatory.
        XCTAssertFalse(StoreGuestHelperStopProof.verify(received, session: session, outcome: .callerClosed,
                                                       helperExitedSuccessfully: false))
    }
}
