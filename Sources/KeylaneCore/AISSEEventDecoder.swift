import Foundation

/// Bounded byte framing shared by all AI SSE transports. JSON is decoded only after a blank line.
public struct AISSEEventDecoder {
    private var line = Data()
    private var event = Data()
    private var skipLineFeed = false
    private let limit = 262_144
    public init() {}
    public var hasPendingData: Bool { !line.isEmpty || !event.isEmpty }

    public mutating func consume(_ byte: UInt8) throws -> Data? {
        if skipLineFeed {
            skipLineFeed = false
            if byte == 10 { return nil }
        }
        guard byte == 10 || byte == 13 else {
            guard line.count < limit else { throw AIResponseError.tooLarge }
            line.append(byte)
            return nil
        }
        skipLineFeed = byte == 13
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !event.isEmpty else { return nil }
            defer { event.removeAll(keepingCapacity: true) }
            return event
        }
        if line.starts(with: "data:".utf8) {
            var payload = line.dropFirst(5)
            if payload.first == 32 { payload = payload.dropFirst() }
            guard event.count + payload.count + 1 <= limit else { throw AIResponseError.tooLarge }
            if !event.isEmpty { event.append(10) }
            event.append(contentsOf: payload)
        }
        return nil
    }
}
