import CryptoKit
import Foundation

/// Single-guest, host-owned data exchange. It never launches a process or
/// approves a capability. The supervisor must apply absolute deadlines and
/// dispatch broker frames exclusively through the live installation session.
public struct StoreGuestProtocol {
    public enum Phase: Sendable { case build, run }
    public enum Rejection: Error { case bounds, protocolOrder, identity }
    public enum Outcome: Sendable {
        case send(Data)
        case continueReading
        case broker(Data)
        case built(Data)
        case ran
    }

    private struct Pull: Decodable {
        let transfer: String
        let offset: Int
        let length: Int
    }

    private struct Frame: Decodable {
        let kind: String
        let bytes: Int?
        let sha256: String?
        let offset: Int?
        let body: String?
    }

    private static let chunkSize = 8192
    private static let maxFrame = 16384
    private static let maxArtifact = 4 * 1024 * 1024
    private let phase: Phase
    private let envelope: Data
    private let transfer: String
    private var sent = 0
    private var frameCount = 0
    private var received = false
    private var finished = false
    private var expectedArtifact: (count: Int, digest: String)?
    private var artifact = Data()

    public init(phase: Phase, envelope: Data) throws {
        let maximum = (phase == .build ? 46 : 6) * 1024 * 1024
        guard !envelope.isEmpty, envelope.count <= maximum else { throw Rejection.bounds }
        self.phase = phase
        self.envelope = envelope
        self.transfer = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func begin() throws -> Data {
        try Self.json(["transfer": transfer, "bytes": envelope.count, "sha256": Self.sha256(envelope)])
    }

    public mutating func consume(_ line: Data) throws -> Outcome {
        guard !finished else { throw Rejection.protocolOrder }
        do { return try consumeFrame(line) }
        catch {
            finished = true
            artifact.removeAll()
            throw error
        }
    }

    private mutating func consumeFrame(_ line: Data) throws -> Outcome {
        frameCount += 1
        guard !line.isEmpty, line.count <= Self.maxFrame,
              frameCount <= (envelope.count + Self.chunkSize - 1) / Self.chunkSize + 1024 else {
            throw Rejection.bounds
        }
        let decoder = JSONDecoder()
        if !received, let pull = try? decoder.decode(Pull.self, from: line) {
            let length = min(Self.chunkSize, envelope.count - sent)
            guard pull.transfer == transfer, pull.offset == sent, pull.length == length, length > 0 else {
                throw Rejection.protocolOrder
            }
            let chunk = envelope.subdata(in: sent ..< sent + length)
            sent += length
            return .send(try Self.json(["transfer": transfer, "offset": pull.offset, "body": chunk.base64EncodedString()]))
        }
        let frame = try decoder.decode(Frame.self, from: line)
        if !received {
            guard frame.kind == "received", sent == envelope.count else { throw Rejection.protocolOrder }
            received = true
            return .continueReading
        }
        switch (phase, frame.kind) {
        case (.build, "artifact-start"):
            guard expectedArtifact == nil, let count = frame.bytes, count > 0, count <= Self.maxArtifact,
                  let digest = frame.sha256, Self.isDigest(digest) else { throw Rejection.identity }
            artifact.reserveCapacity(count)
            expectedArtifact = (count, digest)
            return .continueReading
        case (.build, "artifact-chunk"):
            guard let expectedArtifact, frame.offset == artifact.count, let body = frame.body,
                  body.utf8.count <= 10924, let bytes = Data(base64Encoded: body),
                  bytes.base64EncodedString() == body, !bytes.isEmpty,
                  bytes.count == min(Self.chunkSize, expectedArtifact.count - artifact.count) else {
                throw Rejection.protocolOrder
            }
            artifact.append(bytes)
            return .continueReading
        case (.build, "artifact-done"):
            guard let expectedArtifact, artifact.count == expectedArtifact.count,
                  frame.sha256 == expectedArtifact.digest, Self.sha256(artifact) == expectedArtifact.digest else {
                throw Rejection.identity
            }
            finished = true
            return .built(artifact)
        case (.run, "hello"), (.run, "request"):
            return .broker(line)
        case (.run, "command-done"):
            // This is the extension's own guest report, not an authorization.
            // Any previous broker request must still have been approved by the live session.
            finished = true
            return .ran
        default:
            throw Rejection.protocolOrder
        }
    }

    private static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Stable structural exit information shared by the exact signed helper and
/// the app. Never pass raw guest stdout/stderr, URLs, or credential material.
public enum StoreGuestHelperStatus: Int32, Error, Sendable {
    case request = 64
    case signature = 65
    case channel = 66
    case configuration = 67
    case boot = 68
    case exchange = 69
    case deadline = 70
    case teardown = 71
    case callerClosed = 72
}
