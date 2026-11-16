import Foundation
import XCTest
@testable import KeylaneCore

final class ExtensionPrototypeSessionTests: XCTestCase {
    private func frame(
        _ session: ExtensionPrototypeSession,
        _ fields: [String: Any]
    ) throws -> Data {
        var values = fields
        values["session"] = values["session"] ?? session.id.uuidString
        values["generation"] = values["generation"] ?? session.generation
        return try JSONSerialization.data(withJSONObject: values)
    }

    private func request(_ id: Int, capability: String = "echo") -> [String: Any] {
        ["kind": "request", "version": 1, "requestID": id, "capability": capability, "text": "中文"]
    }

    func testNegotiatesAndChecksHostOwnedGrants() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [.echo])
        XCTAssertEqual(try session.receive(frame(session, ["kind": "hello", "versions": [2, 1]])), .ready(version: 1))
        XCTAssertEqual(try session.receive(frame(session, request(1))), .result(requestID: 1, text: "中文"))
        var forged = request(2, capability: "clipboard.read")
        forged["extensionID"] = "trusted"
        XCTAssertEqual(try session.receive(frame(session, forged)), .denied(requestID: 2))

        var ungranted = ExtensionPrototypeSession(generation: 1, grants: [])
        _ = try ungranted.receive(frame(ungranted, ["kind": "hello", "versions": [1]]))
        XCTAssertEqual(try ungranted.receive(frame(ungranted, request(1))), .denied(requestID: 1))
    }

    func testViewSessionGrantsOnlyViewCapabilities() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [.viewInput, .viewResult]) { _, _ in "" }
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]))
        XCTAssertEqual(try session.receive(frame(session, request(1, capability: "view.input"))), .result(requestID: 1, text: ""))
        XCTAssertEqual(try session.receive(frame(session, request(2, capability: "clipboard.copy"))), .denied(requestID: 2))
        XCTAssertEqual(try session.receive(frame(session, request(3, capability: "view.result"))), .result(requestID: 3, text: ""))
    }

    func testIgnoresEarlierInstallationAndCancelledSession() throws {
        var session = ExtensionPrototypeSession(generation: 2, grants: [.echo])
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]))
        var old = request(1)
        old["generation"] = 1
        assertRejection(.stale, try session.receive(frame(session, old)))
        old["generation"] = 2
        old["session"] = UUID().uuidString
        assertRejection(.stale, try session.receive(frame(session, old)))
        XCTAssertEqual(try session.receive(frame(session, request(1))), .result(requestID: 1, text: "中文"))
        session.cancel()
        assertRejection(.closed, try session.receive(frame(session, request(2))))
    }

    func testRejectsMalformedNegotiationAndReplay() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [.echo])
        assertRejection(.unsupportedVersion, try session.receive(frame(session, ["kind": "hello", "versions": [2]])))
        assertRejection(.closed, try session.receive(frame(session, request(1))))

        var malformed = ExtensionPrototypeSession(generation: 1, grants: [.echo])
        assertRejection(.malformed, try malformed.receive(Data("{".utf8)))

        var replay = ExtensionPrototypeSession(generation: 1, grants: [.echo])
        _ = try replay.receive(frame(replay, ["kind": "hello", "versions": [1]]))
        _ = try replay.receive(frame(replay, request(1)))
        assertRejection(.malformed, try replay.receive(frame(replay, request(1))))
    }

    func testBoundsFramesAndTotalMessages() throws {
        var large = ExtensionPrototypeSession(generation: 1, grants: [])
        assertRejection(.limit, try large.receive(Data(repeating: 0, count: ExtensionPrototypeSession.maxFrameBytes + 1)))

        var busy = ExtensionPrototypeSession(generation: 1, grants: [])
        let start = ContinuousClock.now
        _ = try busy.receive(frame(busy, ["kind": "hello", "versions": [1]]), now: start)
        for id in 1..<ExtensionPrototypeSession.messageBudget {
            let now = start.advanced(by: .seconds(id / ExtensionPrototypeSession.messagesPerSecond))
            _ = try busy.receive(frame(busy, request(id)), now: now)
        }
        assertRejection(.limit, try busy.receive(frame(busy, request(ExtensionPrototypeSession.messageBudget))))
    }

    func testStreamChunksDropStaleFramesAndBoundUnterminatedInput() throws {
        var session = ExtensionPrototypeSession(generation: 2, grants: [.echo])
        let hello = try frame(session, ["kind": "hello", "versions": [1]])
        var replies: [ExtensionPrototypeSession.Reply] = []
        try session.receiveBytes(Data(hello.prefix(7))) { replies.append($0) }
        XCTAssertTrue(replies.isEmpty)
        var chunk = Data(hello.dropFirst(7)) + Data([10])
        var stale = request(1)
        stale["generation"] = 1
        chunk += try frame(session, stale) + Data([10])
        chunk += try frame(session, request(1)) + Data([10])
        try session.receiveBytes(chunk) { replies.append($0) }
        XCTAssertEqual(replies, [.ready(version: 1), .result(requestID: 1, text: "中文")])
        XCTAssertThrowsError(try session.receiveBytes(Data(repeating: 65, count: ExtensionPrototypeSession.maxFrameBytes + 1), emit: { _ in })) {
            XCTAssertEqual($0 as? ExtensionPrototypeSession.Rejection, .limit)
        }
    }

    func testCommitsRepliesBeforeInvalidFrameRegardlessOfReadBoundary() throws {
        let id = UUID()
        let initial = ExtensionPrototypeSession(id: id, generation: 1, grants: [.echo])
        let hello = try frame(initial, ["kind": "hello", "versions": [1]]) + Data([10])
        let valid = hello + (try frame(initial, request(1))) + Data([10])
        let input = valid + Data("{bad}\n".utf8)
        for offset in 0...input.count {
            var session = initial
            var replies: [ExtensionPrototypeSession.Reply] = []
            XCTAssertThrowsError(try {
                for chunk in [input.prefix(offset), input.dropFirst(offset)] {
                    try session.receiveBytes(Data(chunk)) { replies.append($0) }
                }
            }()) {
                XCTAssertEqual($0 as? ExtensionPrototypeSession.Rejection, .malformed)
            }
            XCTAssertEqual(replies, [.ready(version: 1), .result(requestID: 1, text: "中文")])
        }
    }

    func testRejectsPartialFrameAtEOF() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [])
        let hello = try frame(session, ["kind": "hello", "versions": [1]]) + Data([10])
        try session.receiveBytes(hello + Data("{".utf8)) { _ in }
        XCTAssertThrowsError(try session.finishInput()) {
            XCTAssertEqual($0 as? ExtensionPrototypeSession.Rejection, .malformed)
        }
        assertRejection(.closed, try session.receive(frame(session, request(1))))
    }

    func testRejectsMessageBurstWithinOneSecond() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [])
        let now = ContinuousClock.now
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]), now: now)
        for id in 1..<ExtensionPrototypeSession.messagesPerSecond {
            _ = try session.receive(frame(session, request(id)), now: now)
        }
        assertRejection(.limit, try session.receive(frame(session, request(32)), now: now))
    }

    func testReportsHostFailureWithRequestIDWithoutClosingSession() throws {
        var session = ExtensionPrototypeSession(generation: 3, grants: [.echo]) { _, text in
            if text == "中文" { throw CocoaError(.fileWriteUnknown) }
            return text
        }
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]))
        let failure = try session.receive(frame(session, request(1)))
        XCTAssertEqual(failure, .failed(requestID: 1))
        let data = try ExtensionPrototypeSession.encode(failure, session: session.id, generation: 3)
        let fields = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["session"] as? String, session.id.uuidString)
        XCTAssertEqual(fields["generation"] as? Int, 3)
        XCTAssertEqual(fields["version"] as? Int, 1)
        XCTAssertEqual(fields["requestID"] as? Int, 1)
        XCTAssertEqual(fields["error"] as? String, "Host action failed")
        var next = request(2)
        next["text"] = "ok"
        XCTAssertEqual(try session.receive(frame(session, next)), .result(requestID: 2, text: "ok"))
    }

    private func assertRejection(
        _ expected: ExtensionPrototypeSession.Rejection,
        _ expression: @autoclosure () throws -> ExtensionPrototypeSession.Reply
    ) {
        XCTAssertThrowsError(try expression()) { XCTAssertEqual($0 as? ExtensionPrototypeSession.Rejection, expected) }
    }
}
