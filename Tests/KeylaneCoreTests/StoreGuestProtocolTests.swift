import CryptoKit
import Foundation
import XCTest
@testable import KeylaneCore

final class StoreGuestProtocolTests: XCTestCase {
    func frame(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json)
    }

    func pull(_ value: inout StoreGuestProtocol, bytes: Int) throws {
        let descriptor = try JSONSerialization.jsonObject(with: value.begin()) as! [String: Any]
        for offset in stride(from: 0, to: bytes, by: 8192) {
            let request = try frame(["transfer": descriptor["transfer"]!, "offset": offset, "length": min(8192, bytes - offset)])
            guard case .send = try value.consume(request) else { return XCTFail("no chunk") }
        }
        _ = try value.consume(frame(["kind": "received"]))
    }

    func testBuildReturnsOnlyFullyVerifiedArtifact() throws {
        let envelope = Data(repeating: 1, count: 9500)
        var value = try StoreGuestProtocol(phase: .build, envelope: envelope)
        try pull(&value, bytes: envelope.count)
        let artifact = Data(repeating: 29, count: 8193)
        let digest = SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
        _ = try value.consume(frame(["kind": "artifact-start", "bytes": artifact.count, "sha256": digest]))
        for offset in stride(from: 0, to: artifact.count, by: 8192) {
            let chunk = artifact.subdata(in: offset ..< min(offset + 8192, artifact.count))
            _ = try value.consume(frame(["kind": "artifact-chunk", "offset": offset, "body": chunk.base64EncodedString()]))
        }
        guard case let .built(actual) = try value.consume(frame(["kind": "artifact-done", "sha256": digest])) else {
            return XCTFail("no built artifact")
        }
        XCTAssertEqual(actual, artifact)
        XCTAssertThrowsError(try value.consume(frame(["kind": "artifact-done", "sha256": digest])))
    }

    func testBuildRejectsPrematureAcknowledgementAndStaysClosed() throws {
        var value = try StoreGuestProtocol(phase: .build, envelope: Data([1]))
        XCTAssertThrowsError(try value.consume(frame(["kind": "received"])))
        XCTAssertThrowsError(try pull(&value, bytes: 1))
    }

    func testRunForwardsBrokerWithoutInterpretingCapability() throws {
        var value = try StoreGuestProtocol(phase: .run, envelope: Data([1]))
        try pull(&value, bytes: 1)
        let request = try frame(["kind": "request", "capability": "test-denied-by-broker"])
        guard case let .broker(bytes) = try value.consume(request) else { return XCTFail("broker bytes not returned") }
        XCTAssertEqual(request, bytes)
        guard case .ran = try value.consume(frame(["kind": "command-done"])) else { return XCTFail("no terminal report") }
    }
}
