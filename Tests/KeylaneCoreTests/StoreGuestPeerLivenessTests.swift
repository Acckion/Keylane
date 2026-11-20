import Darwin
import Foundation
import XCTest
@testable import KeylaneCore

final class StoreGuestPeerLivenessTests: XCTestCase {
    func testIdleConnectedPeerAndNormalFramesAreNotConsumed() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { _ = Darwin.close($0) } }
        XCTAssertFalse(StoreGuestPeerLiveness.peerClosed(pair[0]))
        let frames = Data("{\"kind\":\"ready\"}\n{\"kind\":\"result\"}\n".utf8)
        XCTAssertEqual(frames.withUnsafeBytes { Darwin.write(pair[1], $0.baseAddress!, $0.count) }, frames.count)
        for _ in 0 ..< 16 { XCTAssertFalse(StoreGuestPeerLiveness.peerClosed(pair[0])) }
        var received = Data(count: frames.count)
        let count = received.withUnsafeMutableBytes { Darwin.read(pair[0], $0.baseAddress!, $0.count) }
        XCTAssertEqual(count, frames.count)
        XCTAssertEqual(received, frames)
        XCTAssertFalse(StoreGuestPeerLiveness.peerClosed(pair[0]))
    }

    func testSocketDeadlineAndDisconnectRemainDistinct() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { _ = Darwin.close($0) } }
        XCTAssertThrowsError(try StoreGuestPeerLiveness.waitForSocket(pair[0], events: Int16(POLLIN),
                                                                     until: .now() + .milliseconds(10))) { error in
            XCTAssertEqual(error as? StoreGuestHelperStatus, .deadline)
        }
        var byte: UInt8 = 17
        XCTAssertEqual(Darwin.write(pair[1], &byte, 1), 1)
        XCTAssertNoThrow(try StoreGuestPeerLiveness.waitForSocket(pair[0], events: Int16(POLLIN),
                                                                 until: .now() + .milliseconds(100)))
        XCTAssertEqual(Darwin.read(pair[0], &byte, 1), 1)
        XCTAssertEqual(byte, 17)
        XCTAssertEqual(shutdown(pair[1], SHUT_RDWR), 0)
        XCTAssertTrue(StoreGuestPeerLiveness.peerClosed(pair[0]))
        // Some kernels report readable EOF, which the actual read rejects.
        // In either case this readiness/EOF must not be called a deadline.
        do {
            try StoreGuestPeerLiveness.waitForSocket(pair[0], events: Int16(POLLIN),
                                                      until: .now() + .milliseconds(100))
            XCTAssertEqual(Darwin.read(pair[0], &byte, 1), 0)
        } catch {
            XCTAssertEqual(error as? StoreGuestHelperStatus, .channel)
        }
    }

    func testPeerEOFFoundPromptlyWithNoApplicationBytes() {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { _ = Darwin.close($0) } }
        let started = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(shutdown(pair[1], SHUT_RDWR), 0)
        XCTAssertTrue(StoreGuestPeerLiveness.peerClosed(pair[0]))
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - started, 50_000_000)
    }
}
