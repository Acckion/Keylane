import XCTest
@testable import KeylaneCore

final class AIResponseProgressTests: XCTestCase {
    func testTextOnlyReplyDoesNotInventThinkingOrTools() {
        var progress = AIResponseProgress()
        XCTAssertTrue(progress.active)
        XCTAssertTrue(progress.activities.isEmpty)
        progress.apply(.writing)
        progress.apply(.completed)
        XCTAssertEqual(progress.phase, .completed)
        XCTAssertEqual(progress.title, "已生成回复")
        XCTAssertTrue(progress.activities.isEmpty)
    }

    func testThinkingToolLifecycleAndPersistentDetails() throws {
        var progress = AIResponseProgress()
        progress.apply(.thinking(id: "r1", delta: "提供方摘要"))
        progress.apply(.thinking(id: "r1", delta: "的第二段"))
        XCTAssertEqual(progress.activities.count, 1)
        progress.apply(.tool(id: "t1", name: "Read", arguments: #"{"path":"/Example","limit":200,"api_key":"private","nested":{"token":"private"}}"#, state: .running))
        XCTAssertEqual(progress.activities.first?.state, .completed)
        XCTAssertFalse(progress.activities[1].arguments.contains("private"))
        XCTAssertTrue(progress.activities[1].arguments.contains("已隐藏"))
        progress.apply(.tool(id: "t1", name: "Read", arguments: #"{"path":"/Example"}"#, state: .completed))
        XCTAssertEqual(progress.title, "正在整理回复…")
        progress.apply(.writing)
        progress.apply(.completed)
        XCTAssertEqual(progress.completedToolCount, 1)
        XCTAssertEqual(progress.activities.count, 2)
        XCTAssertEqual(progress.activities.first?.text, "提供方摘要的第二段")
        XCTAssertEqual(try JSONDecoder().decode(AIResponseProgress.self, from: JSONEncoder().encode(progress)), progress)
        progress.apply(.thinking(id: "late", delta: "迟到的数据"))
        XCTAssertEqual(progress.activities.count, 2)
    }

    func testUnexecutedOrUnconfirmedToolsNeverBecomeSuccessful() {
        var requested = AIResponseProgress()
        requested.apply(.tool(id: "t", name: "Read", arguments: "{}", state: .requested))
        requested.apply(.failed)
        XCTAssertEqual(requested.activities.first?.state, .notExecuted)
        XCTAssertEqual(requested.completedToolCount, 0)
        XCTAssertEqual(requested.title, "工具请求未执行")
        var running = AIResponseProgress()
        running.apply(.tool(id: "t", name: "Search", arguments: "{}", state: .running))
        running.apply(.completed)
        XCTAssertEqual(running.activities.first?.state, .unconfirmed)
        XCTAssertEqual(running.completedToolCount, 0)
    }

    func testCancellationAndBounds() {
        var progress = AIResponseProgress()
        progress.apply(.thinking(id: "r", delta: String(repeating: "汉", count: 20_000)))
        XCTAssertLessThanOrEqual(progress.activities[0].text.utf8.count, 16_000)
        progress.apply(.cancelled)
        XCTAssertEqual(progress.activities[0].state, .cancelled)
        progress.apply(.writing)
        XCTAssertEqual(progress.phase, .cancelled)
        XCTAssertEqual(AIResponseProgress.sanitizedArguments("{\"token\":"), "")
        var many = AIResponseProgress()
        for index in 0..<100 { many.apply(.thinking(id: "\(index)", delta: "")) }
        XCTAssertEqual(many.activities.count, 64)
    }

    func testReasoningEnvelopeAndToolRequestParsing() throws {
        let data = Data(#"{"choices":[{"delta":{"reasoning_content":"summary","tool_calls":[{"index":0,"id":"t","function":{"name":"read","arguments":"{}"}}]}}]}"#.utf8)
        let envelope = try JSONDecoder().decode(AICompletionEnvelope.self, from: data)
        XCTAssertEqual(envelope.choices?.first?.delta?.reasoning, "summary")
        XCTAssertEqual(envelope.choices?.first?.delta?.toolCalls?.first?.function?.name, "read")
    }
}
