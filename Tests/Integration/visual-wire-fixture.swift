import AppKit
import Foundation
import ImageIO
import KeylaneCore
#if KEYLANE_LINKED_PRODUCTION_TEST
@testable import Keylane
#endif

final class VisualProtocol: URLProtocol {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var expected = Data()
        var bodies: [[String: Any]] = []
        func begin(_ data: Data) { lock.lock(); defer { lock.unlock() }; expected = data; bodies = [] }
        var count: Int { lock.lock(); defer { lock.unlock() }; return bodies.count }
        func receive(_ object: [String: Any], anthropic: Bool) throws -> Int {
            lock.lock(); defer { lock.unlock() }
            let messages = object["messages"] as! [[String: Any]]
            let user = messages.first { $0["role"] as? String == "user" }!
            let blocks = user["content"] as! [[String: Any]]
            let images = blocks.filter { $0["type"] as? String == (anthropic ? "image" : "image_url") }
            precondition(images.count == 1)
            let encoded: String
            if anthropic {
                let source = images[0]["source"] as! [String: String]
                precondition(source["type"] == "base64" && source["media_type"] == "image/jpeg")
                encoded = source["data"]!
            } else {
                let url = (images[0]["image_url"] as! [String: String])["url"]!
                precondition(url.hasPrefix("data:image/jpeg;base64,")); encoded = String(url.split(separator: ",", maxSplits: 1)[1])
            }
            precondition(Data(base64Encoded: encoded) == expected, "Actual sanitized raster must reach every model round")
            let wire = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            precondition(!wire.contains("requiresScreenCapture") && !wire.contains("visualSources"))
            bodies.append(object); return bodies.count
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
            }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let anthropic = request.url!.path.hasSuffix("/messages")
            let round = try Self.state.receive(body, anthropic: anthropic)
            let call = body["tools"] != nil && round == 1
            let tool: [String: Any] = ["id": "visual-call", "type": "function", "function": ["name": "fixture_time", "arguments": "{}"], "index": 0]
            var object: [String: Any]
            if anthropic {
                object = ["type": "message", "content": call ? [["type": "tool_use", "id": "visual-call", "name": "fixture_time", "input": [:]]] : [["type": "text", "text": "visual answer"]], "stop_reason": call ? "tool_use" : "end_turn"]
            } else {
                var message: [String: Any] = ["role": "assistant", "content": call ? "" : "visual answer"]
                if call { message["tool_calls"] = [tool] }
                object = ["choices": [["message": message, "finish_reason": call ? "tool_calls" : "stop"]]]
            }
            let streaming = body["stream"] as? Bool == true
            var response = try JSONSerialization.data(withJSONObject: object)
            if streaming {
                var events: [[String: Any]] = []
                if anthropic {
                    events = [["type": "message_start", "message": ["usage": ["input_tokens": 1]]]]
                    for (index, block) in (object["content"] as! [[String: Any]]).enumerated() {
                        events.append(["type": "content_block_start", "index": index, "content_block": block])
                        if !call { events.append(["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": ""]]) }
                        events.append(["type": "content_block_stop", "index": index])
                    }
                    events += [["type": "message_delta", "delta": ["stop_reason": call ? "tool_use" : "end_turn"], "usage": ["output_tokens": 1]], ["type": "message_stop"]]
                } else {
                    var delta: [String: Any] = ["content": call ? "" : "visual answer"]
                    if call { delta["tool_calls"] = [tool] }
                    events = [["choices": [["delta": delta, "finish_reason": call ? "tool_calls" : "stop"]]]]
                }
                response = Data(try events.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined().utf8)
                if !anthropic { response.append(Data("data: [DONE]\n\n".utf8)) }
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
@MainActor private final class VisualOutput { var text = ""; var keys = 0 }


@MainActor func verifyVisualWire(image: AIImageInput) async throws {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [VisualProtocol.self]
    for proto in [AIWireProtocol.openAI, .anthropic] {
        for streaming in [false, true] {
            for enabledTools in [false, true] {
                var connection = AIConnection(endpoint: "https://synthetic.invalid/v1", model: "synthetic-vision", mode: streaming ? .streaming : .complete, wireProtocol: proto)
                connection.supportsImages = true
                let definition = try AIToolDefinition(name: "fixture_time", title: "Synthetic time", description: "Only synthetic data", parameters: [])
                let tools = enabledTools ? try AIToolRun(registrations: [.init(definition: definition) { _ in try .init(text: "synthetic time") }], isCurrent: { true }, approve: { _, _ in true }) : nil
                VisualProtocol.state.begin(image.data)
                let output = VisualOutput()
                _ = try await AIRuntime(configuration: sessionConfiguration).generate(connection: connection, readKey: { _ in "synthetic-key" }, messages: [.init(role: .user, content: "Read the synthetic chart", images: [image])], tools: tools) { text in await MainActor.run { output.text += text } }
                precondition(output.text == "visual answer" && VisualProtocol.state.count == (enabledTools ? 2 : 1))
            }
        }
    }
    print("PASS vision wire: OpenAI/Anthropic, streaming/complete, ordinary/tool-enabled; original raster retained through tool continuation (8 paths)")

    for flag in [Bool?.none, false, true] {
        var connection = AIConnection(endpoint: "https://synthetic.invalid/v1", model: "synthetic", mode: .complete)
        connection.supportsImages = flag
        if flag == true { connection.wireProtocol = .codex }
        VisualProtocol.state.begin(image.data)
        do {
            _ = try await AIRuntime(configuration: sessionConfiguration).generate(connection: connection, readKey: { _ in preconditionFailure("Unsupported image path must not read credentials") }, messages: [.init(role: .user, content: "fixture", images: [image])]) { _ in }
            preconditionFailure("Unsupported image input was silently flattened")
        } catch AIResponseError.visionUnavailable { }
        precondition(VisualProtocol.state.count == 0)
    }
    var vision = AIConnection(endpoint: "https://synthetic.invalid/v1", model: "synthetic-vision", mode: .complete)
    vision.supportsImages = true
    let source = AIVisualSource(application: "Synthetic", windowTitle: "Fixture", windowID: 42, capturedAt: Date(), usedAccessibility: true)
    do {
        try AIVisualInputPolicy.validate([.init(role: .user, content: "fixture", images: [image], visualSources: [source])], connection: vision, screenAllowed: { false }, accessibilityAllowed: { true })
        preconditionFailure("Revoked screen data accepted")
    } catch AIResponseError.visualSourceRevoked { }
    do {
        try AIVisualInputPolicy.validate([.init(role: .user, content: "fixture", images: [image], visualSources: [source])], connection: vision, screenAllowed: { true }, accessibilityAllowed: { false })
        preconditionFailure("Revoked AX data accepted")
    } catch AIResponseError.visualSourceRevoked { }
    var axOnly = source; axOnly.requiresScreenCapture = false
    try AIVisualInputPolicy.validate([.init(role: .user, content: "AX text", visualSources: [axOnly])], connection: vision, screenAllowed: { preconditionFailure("AX-only should never request screen permission") }, accessibilityAllowed: { true })
    print("PASS capability/privacy: unknown/non-vision/CLI rejected before credentials or network; independent AX/screen permission checks")

}
