import AppKit

/// A reviewed extension result can write one pasteboard item with alternate representations.
public struct ExtensionClipboardContent: Codable {
    public let text: String?
    public let html: String?
    public let file: String?

    public init(text: String) {
        self.text = text
        html = nil
        file = nil
    }

    public var isValid: Bool {
        guard (text?.utf8.count ?? 0) <= 4_096, (html?.utf8.count ?? 0) <= 4_096 else { return false }
        if let file { return text == nil && html == nil && ExtensionFinderRevealEvent.isValidPath(file) }
        return text != nil || html != nil
    }

    public func write(to board: NSPasteboard, concealed: Bool = false) -> Bool {
        guard isValid else { return false }
        let item = NSPasteboardItem()
        if let file {
            let url = URL(fileURLWithPath: file).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  item.setString(url.absoluteString, forType: .fileURL) else { return false }
        } else {
            if let text, !item.setString(text, forType: .string) { return false }
            if let html, !item.setString(html, forType: .html) { return false }
        }
        if concealed, !item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")) { return false }
        board.clearContents()
        return board.writeObjects([item])
    }
}

public struct ExtensionClipboardWriteEvent: Codable {
    public struct Request: Codable {
        public let content: ExtensionClipboardContent
        public let concealed: Bool
    }

    public static let prefix = "guest-write-clipboard="
    public let id: UUID
    public let request: Request

    public func replyFrame(written: Bool) -> Data {
        Data("clipboard-write:\(id.uuidString):\(written ? "written" : "rejected")\n".utf8)
    }
}


public struct ExtensionClipboardHistoryReadEvent: Codable {
    public static let prefix = "guest-read-clipboard-history="
    public let id: UUID
    public let offset: Int
    public let includesRichContent: Bool

    public var isValid: Bool { (1...5).contains(offset) }

    public var confirmation: ExtensionAlertEvent {
        ExtensionAlertEvent(id: id, request: ExtensionAlertRequest(
            title: "允许此扩展读取剪贴板历史？", message: "读取当前剪贴板之前的第\(offset)条记录，仅限本次请求。",
            primaryAction: .init(title: "允许读取", style: .default),
            dismissAction: .init(title: "取消", style: .cancel),
            rememberUserChoice: false, icon: nil
        ))
    }

    private var replyPrefix: String { "clipboard-history:\(id.uuidString):" }

    public func statusFrame(shown: Bool) -> Data {
        Data((replyPrefix + (shown ? "shown" : "rejected") + "\n").utf8)
    }

    public func contentFrame(_ fields: [String: String]) -> Data {
        guard let payload = try? ExtensionClipboardReadTransport.encode(fields) else { return statusFrame(shown: false) }
        return Data((replyPrefix + "content:" + Data(payload.utf8).base64EncodedString() + "\n").utf8)
    }

    func decodeReply(_ line: String) -> String? {
        guard line.hasPrefix(replyPrefix) else { return nil }
        let reply = line.dropFirst(replyPrefix.count)
        if reply == "shown" || reply == "rejected" { return String(reply) }
        guard reply.hasPrefix("content:"),
              let data = Data(base64Encoded: String(reply.dropFirst("content:".count))),
              data.count <= ExtensionClipboardReadTransport.maximumPayloadBytes,
              let fields = try? JSONDecoder().decode([String: String].self, from: data),
              includesRichContent || Set(fields.keys).isSubset(of: ["text"])
        else { return nil }
        return try? ExtensionClipboardReadTransport.encode(fields)
    }

    public static let maximumReplyLineBytes = 80 + (ExtensionClipboardReadTransport.maximumPayloadBytes + 2) / 3 * 4
}

/// Clipboard snapshots can exceed one broker frame. Bounds apply before transferring any data.
enum ExtensionClipboardReadTransport {
    static let maximumPayloadBytes = 64 * 1024
    static let chunkBytes = 11 * 1024
    // One pass through offsets 0...5 with each public reader.
    static let maximumReads = 12
    static let chunksPerRead = (maximumPayloadBytes + chunkBytes - 1) / chunkBytes
    static let maximumChunks = maximumReads * chunksPerRead
    // Account for Base64 and the broker envelopes in each bounded session.
    static let maximumTrafficBytes = maximumReads * (chunksPerRead * ((chunkBytes + 2) / 3 * 4 + 256) + 256)

    static func encode(_ fields: [String: String]) throws -> String {
        let limits = ["text": 32 * 1024, "html": 32 * 1024, "file": 2_048]
        guard fields.allSatisfy({ key, value in
            limits[key].map { value.utf8.count <= $0 } == true &&
                (key != "file" || ExtensionFinderRevealEvent.isValidPath(value))
        }) else { throw CocoaError(.fileReadTooLarge) }
        let data = try JSONSerialization.data(withJSONObject: fields, options: .withoutEscapingSlashes)
        guard data.count <= maximumPayloadBytes else { throw CocoaError(.fileReadTooLarge) }
        return String(decoding: data, as: UTF8.self)
    }
}
