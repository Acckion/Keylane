import Foundation

/// Host-owned admission state for a single extension process.
struct ExtensionPrototypeSession {
    static let maxFrameBytes = 16_384
    static let messageBudget = 128
    static let messagesPerSecond = 32

    enum Capability: String, Codable, Hashable {
        case echo
        case localStorage = "storage.request"
        case preferencesRead = "preferences.read"
        case viewInput = "view.input"
        case viewResult = "view.result"
        case applicationsQuery = "applications.query"
        case clipboardRead = "clipboard.read"
        case windowRead = "window.read"
        case clipboardCopy = "clipboard.copy"
        case clipboardPaste = "clipboard.paste"
        case hud = "feedback.hud"
        case toast = "feedback.toast"
    }

    struct Message: Decodable {
        enum Kind: String, Decodable { case hello, request }
        let kind: Kind
        let session: UUID
        let generation: UInt64
        let versions: [Int]?
        let version: Int?
        let requestID: UInt64?
        let capability: String?
        let text: String?
    }

    enum Reply: Equatable {
        case ready(version: Int)
        case result(requestID: UInt64, text: String)
        case denied(requestID: UInt64)
        case failed(requestID: UInt64)
    }

    enum Rejection: Error, Equatable {
        case closed, stale, limit, malformed, unsupportedVersion
    }

    let id: UUID
    let generation: UInt64
    private let grants: Set<Capability>
    private let handler: (Capability, String) throws -> String
    private var ready = false
    private var closed = false
    private var remaining = Self.messageBudget
    private var lastRequest: UInt64 = 0
    private var windowStart: ContinuousClock.Instant?
    private var messagesInWindow = 0
    private var partialFrame = Data()

    init(id: UUID = UUID(), generation: UInt64, grants: Set<Capability>,
         handler: @escaping (Capability, String) throws -> String = { capability, text in
             guard capability == .echo else { throw CocoaError(.featureUnsupported) }
             return text
         }) {
        self.id = id
        self.generation = generation
        self.grants = grants
        self.handler = handler
    }

    static func encode(_ reply: Reply, session: UUID, generation: UInt64) throws -> Data {
        var fields: [String: Any] = ["session": session.uuidString, "generation": generation, "version": 1]
        switch reply {
        case .ready(let version):
            fields["kind"] = "ready"
            fields["version"] = version
        case .result(let requestID, let text):
            fields["kind"] = "result"
            fields["requestID"] = requestID
            fields["text"] = text
        case .denied(let requestID):
            fields["kind"] = "denied"
            fields["requestID"] = requestID
            fields["error"] = "Capability unavailable for this command"
        case .failed(let requestID):
            fields["kind"] = "failed"
            fields["requestID"] = requestID
            fields["error"] = "Host action failed"
        }
        return try JSONSerialization.data(withJSONObject: fields) + Data([10])
    }

    mutating func cancel() {
        closed = true
        partialFrame.removeAll(keepingCapacity: false)
    }

    /// A frame is delivered only by the transport owned by this session.
    /// Fields inside the frame are routing assertions, never credentials.
    mutating func receiveBytes(
        _ bytes: Data, now: ContinuousClock.Instant = .now, emit: (Reply) throws -> Void
    ) throws {
        guard !closed else { throw Rejection.closed }
        for byte in bytes {
            if byte == 10 {
                let frame = partialFrame
                partialFrame.removeAll(keepingCapacity: true)
                let reply: Reply
                do {
                    reply = try receive(frame, now: now)
                } catch Rejection.stale {
                    continue
                }
                try emit(reply)
            } else {
                guard partialFrame.count < Self.maxFrameBytes else {
                    cancel()
                    throw Rejection.limit
                }
                partialFrame.append(byte)
            }
        }
    }

    mutating func finishInput() throws {
        guard !closed else { throw Rejection.closed }
        let complete = ready && partialFrame.isEmpty
        cancel()
        guard complete else { throw Rejection.malformed }
    }

    mutating func receive(_ frame: Data, now: ContinuousClock.Instant = .now) throws -> Reply {
        guard !closed else { throw Rejection.closed }
        guard remaining > 0, frame.count <= Self.maxFrameBytes else {
            cancel()
            throw Rejection.limit
        }
        if windowStart.map({ $0.duration(to: now) >= .seconds(1) }) ?? true {
            windowStart = now
            messagesInWindow = 0
        }
        guard messagesInWindow < Self.messagesPerSecond else {
            cancel()
            throw Rejection.limit
        }
        remaining -= 1
        messagesInWindow += 1
        guard let message = try? JSONDecoder().decode(Message.self, from: frame) else {
            cancel()
            throw Rejection.malformed
        }
        guard message.session == id, message.generation == generation else { throw Rejection.stale }

        switch message.kind {
        case .hello:
            guard !ready, let versions = message.versions, message.version == nil,
                  message.requestID == nil, message.capability == nil, message.text == nil else {
                cancel()
                throw Rejection.malformed
            }
            guard versions.contains(1) else {
                cancel()
                throw Rejection.unsupportedVersion
            }
            ready = true
            return .ready(version: 1)
        case .request:
            guard ready, message.version == 1, message.versions == nil,
                  let requestID = message.requestID, requestID > lastRequest,
                  let name = message.capability, let text = message.text else {
                cancel()
                throw Rejection.malformed
            }
            lastRequest = requestID
            guard let capability = Capability(rawValue: name), grants.contains(capability) else {
                return .denied(requestID: requestID)
            }
            do {
                return .result(requestID: requestID, text: try handler(capability, text))
            } catch {
                return .failed(requestID: requestID)
            }
        }
    }
}
