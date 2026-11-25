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

/// Shared-session user actions with synthetic history and transport, never OS permissions.
private final class VisualConversationProtocol: URLProtocol {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [[String: Any]] = []
        func append(_ body: [String: Any]) { lock.lock(); defer { lock.unlock() }; bodies.append(body) }
        var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return bodies }
        func clear() { lock.lock(); defer { lock.unlock() }; bodies = [] }
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
            Self.state.append(try JSONSerialization.jsonObject(with: data) as! [String: Any])
            let response = Data(#"{"choices":[{"message":{"content":"Synthetic answer"},"finish_reason":"stop"}]}"#.utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@MainActor func verifyVisualConversationRegressions(image: AIImageInput) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("keylane-visual-retry-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "keylane.visual-retry." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    var vision = AIConnection(endpoint: "https://synthetic.invalid/v1", model: "visual-retry", mode: .complete)
    vision.supportsImages = true
    var text = AIConnection(endpoint: "https://synthetic.invalid/v1", model: "text-retry", mode: .complete)
    text.supportsImages = false
    preferences.set(try JSONEncoder().encode(AIConfiguration.State(enabled: true, connections: [vision, text], selectedID: vision.id)), forKey: "aiConnections.v1")
    let configuration = AIConfiguration(preferences: preferences)
    let transport = URLSessionConfiguration.ephemeral
    transport.protocolClasses = [VisualConversationProtocol.self]
    let runtime = AIRuntime(configuration: transport)
    let repository = AIConversationRepository(url: root.appendingPathComponent("history.sqlite"))
    func settled(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Synthetic conversation did not settle")
    }
    func completed(_ question: String, _ answer: String, attachments: [AIConversationAttachment] = []) -> AIConversationTurn {
        var turn = AIConversationTurn(question: question, attachments: attachments.isEmpty ? nil : attachments)
        turn.answer = answer; turn.complete = true
        return turn
    }
    for accessibilityOnly in [false, true] {
        let source = AIVisualSource(application: "Synthetic app", windowTitle: "Synthetic window", windowID: 42,
                                    capturedAt: Date(timeIntervalSince1970: 1), usedAccessibility: accessibilityOnly,
                                    requiresScreenCapture: !accessibilityOnly)
        let context = AIConversationAttachment(title: "Synthetic context", text: "Synthetic selected text", image: accessibilityOnly ? nil : image, visualSource: source)
        let turns = [completed("Original visual question", "Original answer", attachments: [context]), completed("Later question", "Later answer")]
        let record = AIChatRecord(id: UUID(), content: .init(model: .init(vision), turns: turns, instructions: "Keep instructions"))
        try repository.save(record, title: "Keep original title", projectID: nil)
        var allowed = false
        let session = AIConversationSession(configuration: configuration, runtime: runtime, history: repository,
            validateVisualInput: { messages, connection in
                try AIVisualInputPolicy.validate(messages, connection: connection, screenAllowed: { allowed }, accessibilityAllowed: { allowed })
            }, readKey: { _ in "synthetic-key" })
        session.beginChat(); session.openChat(record.id)
        try await settled { !session.loadingChat && session.chatID == record.id }
        session.composer.text = "Keep draft"; session.composer.selection = NSRange(location: 2, length: 3)
        session.composer.attachments = [.init(title: "Draft attachment", text: "Keep draft context")]
        let draft = session.composer.snapshot, draftID = session.composer.draftID, contextGeneration = session.composer.contextGeneration
        VisualConversationProtocol.state.clear()
        // Edit/retry earlier turn and regenerate the latest turn both preserve the active branch on rejection.
        for retry in [{ session.resubmit(turns[0].id, question: "Edited visual question") }, { session.regenerate() }] {
            precondition(!retry())
            precondition(session.status == AIResponseError.visualSourceRevoked.localizedDescription)
            precondition(session.chatID == record.id && session.chatTitle == "Keep original title" && session.turns == turns && session.chatInstructions == "Keep instructions")
            precondition(session.composer.text == draft.text && session.composer.selection == draft.selection && session.composer.attachments == draft.attachments)
            precondition(session.composer.draftID == draftID && session.composer.contextGeneration == contextGeneration)
            precondition(!session.running && VisualConversationProtocol.state.requests.isEmpty)
        }
        // Re-authorized retry passes session preparation without reopening history.
        // The runtime independently checks actual OS permission and may refuse our synthetic marker.
        allowed = true
        precondition(session.resubmit(turns[0].id, question: "Retry after authorization"))
        try await settled { !session.running }
        // No OS capture permission is requested: a source marker may be refused again by the real runtime.
        precondition(session.chatID != record.id && session.turns.count == 1 && session.turns[0].question == "Retry after authorization")
        precondition(session.composer.text == draft.text && session.composer.attachments == draft.attachments)
        let original = try repository.load(record.id)
        precondition(original?.content.turns == turns)
    }
    print("PASS visual retry rejection: screen/AX revocation preserves ID/title/turns/instructions/draft and generations for edit and regenerate")

    // A normal local-image retry remains fully successful, independently of host OS permissions.
    let localTurn = completed("Local image retry", "Original local answer", attachments: [.init(title: "Local", text: "", image: image)])
    let localRecord = AIChatRecord(id: UUID(), content: .init(model: .init(vision), turns: [localTurn]))
    try repository.save(localRecord)
    let localSession = AIConversationSession(configuration: configuration, runtime: runtime, history: repository, readKey: { _ in "synthetic-key" })
    localSession.beginChat(); localSession.openChat(localRecord.id)
    try await settled { !localSession.loadingChat && localSession.chatID == localRecord.id }
    VisualConversationProtocol.state.clear()
    precondition(localSession.regenerate())
    try await settled { !localSession.running }
    precondition(localSession.turns.last?.complete == true && localSession.chatID != localRecord.id && VisualConversationProtocol.state.requests.count == 1)
    print("PASS normal visual regenerate creates a completed branch through the shared session and synthetic transport")

    let oldImage = completed("OLD_IMAGE_SENTINEL", String(repeating: "o", count: 4000), attachments: [.init(title: "Old image", text: "Old image text", image: image)])
    let recent = completed("Recent", String(repeating: "r", count: 58000))
    let record = AIChatRecord(id: UUID(), content: .init(model: .init(text), turns: [oldImage, recent]))
    try repository.save(record)
    let session = AIConversationSession(configuration: configuration, runtime: runtime, history: repository, readKey: { _ in "synthetic-key" })
    session.beginChat(); session.openChat(record.id)
    try await settled { !session.loadingChat && session.chatID == record.id }
    // Short draft retains the old image: both composer gating and direct submission reject it.
    session.composer.text = "Short"
    precondition(session.visualInputIssue != nil && !session.canSendDraft)
    VisualConversationProtocol.state.clear()
    precondition(!session.submit(session.composer.text) && VisualConversationProtocol.state.requests.isEmpty && session.turns.count == 2)
    // Current draft plus context consumes enough of the same UTF-8 budget to exclude the old image.
    session.composer.text = "Continue"
    session.composer.attachments = [.init(title: "New text context", text: String(repeating: "n", count: 2000))]
    precondition(session.visualInputIssue == nil && session.canSendDraft)
    let expected = session.messages(for: AIConversationAttachment.requestText(question: session.composer.text, attachments: session.composer.attachments))
    precondition(expected.allSatisfy { $0.images.isEmpty } && expected.contains { $0.content == recent.answer })
    precondition(session.submit(session.composer.text))
    try await settled { !session.running }
    precondition(session.turns.last?.complete == true && session.turns[0] == oldImage)
    let requests = VisualConversationProtocol.state.requests
    precondition(requests.count == 1)
    let wireMessages = requests[0]["messages"] as! [[String: Any]]
    precondition(wireMessages.map { $0["content"] as! String } == expected.map(\.content))
    let wireText = String(decoding: try JSONSerialization.data(withJSONObject: requests[0]), as: UTF8.self)
    precondition(!wireText.contains("OLD_IMAGE_SENTINEL"))
    session.composer.text = "Current image"
    session.composer.attachments = [.init(title: "Current", text: "", image: image)]
    precondition(session.visualInputIssue != nil && !session.canSendDraft && !session.submit(session.composer.text))
    precondition(VisualConversationProtocol.state.requests.count == 1)
    print("PASS bounded visual model gating: retained old/current images blocked; local-only old image allows exact text-only outbound history")
}
