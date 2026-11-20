
// Tool tests use synthetic HTTP/CLI data and never load an account, real file or calendar.
@MainActor final class ToolFixtureOutput {
    var text = ""
    func append(_ delta: String) { text += delta }
}
@MainActor final class ToolFixtureAvailability { var allowed = true }

final class ToolFixtureProtocol: URLProtocol {
    static var bodies: [[String: Any]] = []
    static var rounds = 0
    static var scenario = "ok"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
            }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            Self.bodies.append(body); Self.rounds += 1
            let anthropic = request.url!.path.hasSuffix("/messages")
            precondition(request.value(forHTTPHeaderField: anthropic ? "x-api-key" : "Authorization") == (anthropic ? "synthetic-key" : "Bearer synthetic-key"))
            let messages = body["messages"] as! [[String: Any]]
            let next = Self.rounds > 1 && Self.scenario != "loop"
            if next {
                if anthropic {
                    let results = messages.last!["content"] as! [[String: Any]]
                    precondition(results[0]["tool_use_id"] as? String == "call-one")
                    precondition(results[0]["content"] as? String == "42")
                    let content = messages[messages.count-2]["content"] as! [[String: Any]]
                    precondition(content[0]["signature"] as? String == "opaque-fixture")
                } else {
                    precondition(messages.last!["tool_call_id"] as? String == "call-one")
                    precondition(messages.last!["content"] as? String == "42")
                }
            }
            let id = Self.scenario == "loop" ? "loop-\(Self.rounds)" : "call-one"
            let object: [String: Any]
            if anthropic {
                object = ["content": next ? [["type": "text", "text": "verified answer"]] : [
                    ["type": "thinking", "thinking": "fixture summary", "signature": "opaque-fixture"],
                    ["type": "tool_use", "id": id, "name": "fixture_add", "input": ["number": 21]]],
                    "stop_reason": next ? "end_turn" : "tool_use", "usage": ["input_tokens": 1, "output_tokens": 2]]
            } else {
                var message: [String: Any] = ["role": "assistant", "content": next ? "verified answer" : ""]
                if !next { message["tool_calls"] = [["id": id, "type": "function", "function": ["name": "fixture_add", "arguments": "{\"number\":21}"]]] }
                object = ["choices": [["message": message, "finish_reason": next ? "stop" : "tool_calls"]], "usage": ["total_tokens": 3]]
            }
            var responseData = try JSONSerialization.data(withJSONObject: object)
            if body["stream"] as? Bool == true {
                var events: [[String: Any]] = []
                if anthropic {
                    events.append(["type": "message_start", "message": ["usage": ["input_tokens": 1, "output_tokens": 0]]])
                    for (index, block) in (object["content"] as! [[String: Any]]).enumerated() {
                        events.append(["type": "content_block_start", "index": index, "content_block": block])
                        if next { events.append(["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": ""]]) }
                        events.append(["type": "content_block_stop", "index": index])
                    }
                    events.append(["type": "message_delta", "delta": ["stop_reason": object["stop_reason"]!], "usage": ["output_tokens": 2]])
                    events.append(["type": "message_stop"])
                } else {
                    let choice = (object["choices"] as! [[String: Any]])[0]
                    var delta = choice["message"] as! [String: Any]
                    if var calls = delta["tool_calls"] as? [[String: Any]] { calls[0]["index"] = 0; delta["tool_calls"] = calls }
                    events = [["choices": [["delta": delta, "finish_reason": choice["finish_reason"]!]], "usage": ["total_tokens": 3]]]
                }
                responseData = Data(try events.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined().utf8)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

let toolDefinition = try AIToolDefinition(name: "fixture_add", title: "Synthetic calculation", description: "Synthetic test only", parameters: [
    .init("number", description: "Number", kind: .integer(minimum: 1, maximum: 100))])
var toolsFinished = false
Task { @MainActor in
    do {
        var performed = 0
        let availability = ToolFixtureAvailability()
        let registration = AIToolRegistration(definition: toolDefinition, available: { availability.allowed }) { arguments in
            performed += 1
            guard case .number(21) = arguments["number"] else { throw AIToolContractError.invalidArguments }
            return try .init(text: "42")
        }
        func run(_ registrations: [AIToolRegistration]? = nil) throws -> AIToolRun {
            try AIToolRun(registrations: registrations ?? [registration], isCurrent: { true }, approve: { _, _ in true })
        }
        for proto in [AIWireProtocol.openAI, .anthropic] {
            for stream in [false, true] {
                ToolFixtureProtocol.bodies = []; ToolFixtureProtocol.rounds = 0
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ToolFixtureProtocol.self]
                let runtime = AIRuntime(configuration: config)
                let endpoint = proto == .anthropic ? "https://synthetic.invalid/v1" : (stream ? "http://127.0.0.1:11434/v1" : "https://custom.invalid/advanced/v1")
                var connection = AIConnection(endpoint: endpoint, model: "synthetic", mode: stream ? .streaming : .complete, wireProtocol: proto)
                connection.additionalParametersJSON = "{\"temperature\":0.2}"
                let output = ToolFixtureOutput()
                let tokens = try await runtime.generate(connection: connection, readKey: { _ in "synthetic-key" }, messages: [.init(role: .user, content: "fixture")], tools: run()) { await output.append($0) }
                precondition(output.text == "verified answer" && tokens == 6 && ToolFixtureProtocol.rounds == 2)
                precondition(ToolFixtureProtocol.bodies[0]["temperature"] as? Double == 0.2)
            }
        }
        precondition(performed == 4)
        let invalid = try AIToolCall(id: "invalid", name: "not_registered", arguments: [:])
        let invalidResult = try await run().execute(invalid, scope: "fixture", progress: { _ in })
        precondition(invalidResult.isError && performed == 4)
        let badArguments = try AIToolCall(id: "bad", name: "fixture_add", arguments: ["number": .number(21), "extra": .bool(true)])
        let badResult = try await run().execute(badArguments, scope: "fixture", progress: { _ in })
        precondition(badResult.isError && performed == 4)
        availability.allowed = false
        let call = try AIToolCall(id: "once", name: "fixture_add", arguments: ["number": .number(21)])
        let disabled = try await run().execute(call, scope: "fixture", progress: { _ in })
        precondition(disabled.isError && performed == 4)
        availability.allowed = true
        var action = registration; action.requiresConfirmation = true
        let denied = try AIToolRun(registrations: [action], isCurrent: { true }, approve: { _, _ in false })
        let deniedResult = try await denied.execute(call, scope: "fixture", progress: { _ in })
        precondition(deniedResult.isError)
        precondition(performed == 4)
        var current = true
        let revoked = try AIToolRun(registrations: [action], isCurrent: { current }, approve: { _, _ in current = false; return true })
        do { _ = try await revoked.execute(call, scope: "fixture", progress: { _ in }); preconditionFailure("Stale action executed") }
        catch is CancellationError { }
        precondition(performed == 4)
        let replay = try run()
        _ = try await replay.execute(call, scope: "fixture", progress: { _ in })
        do { _ = try await replay.execute(call, scope: "fixture", progress: { _ in }); preconditionFailure("Replayed call accepted") }
        catch AIToolContractError.invalidArguments { }
        catch AIToolContractError.limitReached { }
        precondition(performed == 5)
        let broker = AIToolApprovalBroker()
        let approval = Task { @MainActor in await broker.request(title: "Synthetic", arguments: "{}") }
        await Task.yield()
        let old = broker.pending?.id
        approval.cancel()
        let approved = await approval.value
        precondition(!approved && broker.pending == nil)
        if let old { broker.resolve(old, allow: true) }
        precondition(broker.pending == nil)
        let prefs = UserDefaults(suiteName: "keylane.tool-test." + UUID().uuidString)!
        precondition(!AIInteractionPreferences(preferences: prefs).toolsEnabled)
        var collector = AIToolHTTPTransport.StreamCollector(anthropic: false)
        _ = try collector.consume(["choices": [["delta": ["tool_calls": [["index": 0, "id": "fragment", "type": "function", "function": ["name": "fixture_", "arguments": "{\"num"]]]]]]])
        _ = try collector.consume(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["name": "add", "arguments": "ber\":21}"]]]], "finish_reason": "tool_calls"]]])
        _ = try collector.consume(["choices": [["delta": ["reasoning_details": [
            ["index": 0, "type": "reasoning.text", "text": "First "],
            ["index": 1, "type": "reasoning.encrypted", "data": "opaque-"]]]]]])
        _ = try collector.consume(["choices": [["delta": ["reasoning_details": [
            ["index": 0, "type": "reasoning.text", "text": "second"],
            ["index": 1, "type": "reasoning.encrypted", "data": "signature"]]]]]])
        let fragmented = try collector.finish()
        let continuation = fragmented.assistant["reasoning_details"] as! [[String: Any]]
        precondition(continuation[0]["text"] as? String == "First second" && continuation[1]["data"] as? String == "opaque-signature")
        precondition(fragmented.calls.first?.name == "fixture_add" && fragmented.calls.first?.arguments["number"] == .number(21))
        do { _ = try AIToolHTTPTransport.decode(["choices": [["message": ["content": "cut"], "finish_reason": "length"]]], anthropic: false); preconditionFailure("Truncation accepted") }
        catch AIResponseError.incomplete { }
        ToolFixtureProtocol.scenario = "loop"; ToolFixtureProtocol.rounds = 0
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ToolFixtureProtocol.self]
        do {
            _ = try await AIRuntime(configuration: config).generate(connection: AIConnection(endpoint: "http://localhost/v1", model: "synthetic", mode: .complete), readKey: { _ in "synthetic-key" }, messages: [.init(role: .user, content: "fixture")], tools: run()) { _ in }
            preconditionFailure("Unbounded loop")
        } catch AIToolContractError.limitReached { }
        precondition(ToolFixtureProtocol.rounds == 6)
        ToolFixtureProtocol.scenario = "ok"
        print("PASS tools: OpenAI/API/custom/Ollama and Anthropic streaming/complete round trips, fragmented calls, exact IDs, opaque continuation, bounds, denied/revoked/replayed operations and cancelled approvals")
    } catch { fatalError("Tool fixture failed: \(error)") }
    toolsFinished = true
}
wait("Tool protocol and cancellation fixtures") { toolsFinished }

let toolCLIExecutable = cliDirectory.appendingPathComponent("tool-fixture-cli")
try #"""
#!/usr/bin/python3
import sys, json

def send(value): print(json.dumps(value), flush=True)
if sys.argv[1:3] == ['auth', 'status']:
    send({'loggedIn': True, 'authMethod': 'claude.ai', 'email': 'fixture@example.invalid'})
elif '--print' in sys.argv:
    assert sys.argv[sys.argv.index('--tools')+1] == ''
    assert sys.argv[sys.argv.index('--allowedTools')+1] == 'mcp__keylane__*'
    assert '--dangerously-skip-permissions' not in sys.argv
    init = json.loads(sys.stdin.readline())
    assert init['request']['subtype'] == 'initialize'
    send({'type':'control_response', 'response':{'subtype':'success','request_id':init['request_id'],'response':{}}})
    user = json.loads(sys.stdin.readline()); assert user['type'] == 'user'
    def mcp(rid, method, params={}):
        send({'type':'control_request','request_id':rid,'request':{'subtype':'mcp_message','server_name':'keylane','message':{'jsonrpc':'2.0','id':rid,'method':method,'params':params}}})
        response = json.loads(sys.stdin.readline())
        assert response['response']['request_id'] == rid
        return response['response']['response']['mcp_response']['result']
    result = mcp('init', 'initialize'); assert 'tools' in result['capabilities']
    result = mcp('list', 'tools/list'); assert result['tools'][0]['name'] == 'fixture_add'
    result = mcp('call', 'tools/call', {'name':'fixture_add','arguments':{'number':21}})
    assert result['content'][0]['text'] == '42' and result['isError'] is False
    send({'type':'assistant','message':{'id':'answer','content':[{'type':'thinking','thinking':'Synthetic summary'}]}})
    send({'type':'assistant','message':{'id':'answer','content':[{'type':'text','text':'CLI tool answer'}]}})
    send({'type':'result','subtype':'success','is_error':False,'result':'CLI tool answer','usage':{'input_tokens':1,'output_tokens':2}})
else:
    assert sys.argv[1] == 'app-server' and 'features.shell_tool=false' in sys.argv
    assert 'mcp_servers={}' in sys.argv
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get('method'); rid = request.get('id')
        if method == 'initialized': continue
        if method == 'initialize':
            assert request['params']['capabilities']['experimentalApi'] is True
            result = {}
        elif method == 'account/read': result = {'account':{'type':'chatgpt','email':'fixture@example.invalid'}}
        elif method == 'thread/start':
            tools = request['params']['dynamicTools']
            assert tools[0]['name'] == 'fixture_add' and tools[0]['type'] == 'function'
            assert tools[0]['inputSchema']['additionalProperties'] is False
            result = {'thread':{'id':'tools-thread'}}
        elif method == 'turn/start':
            send({'id':rid,'result':{'turn':{'id':'tools-turn'}}})
            send({'id':'server-call','method':'item/tool/call','params':{'threadId':'tools-thread','turnId':'tools-turn','callId':'call-one','tool':'fixture_add','arguments':{'number':21}}})
            continue
        elif rid == 'server-call':
            assert request['result']['success'] is True
            assert request['result']['contentItems'][0]['text'] == '42'
            send({'method':'item/agentMessage/delta','params':{'threadId':'tools-thread','delta':'CLI tool answer'}})
            send({'method':'turn/completed','params':{'threadId':'tools-thread','turn':{'id':'tools-turn','status':'completed'}}})
            continue
        else: raise RuntimeError('Unexpected method ' + str(method))
        send({'id':rid,'result':result})
"""#.write(to: toolCLIExecutable, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: toolCLIExecutable.path)
var toolCLIFinished = false
Task { @MainActor in
    do {
        for proto in [AIWireProtocol.codex, .claudeCode] {
            var count = 0
            let tools = try AIToolRun(registrations: [.init(definition: toolDefinition) { _ in count += 1; return try .init(text: "42") }], isCurrent: { true }, approve: { _, _ in true })
            let connection = AIConnection(model: "synthetic", wireProtocol: proto, executablePath: toolCLIExecutable.path,
                accountFolder: cliDirectory.path, subscriptionEnabled: true, subscriptionAccountID: "fixture@example.invalid")
            let output = ToolFixtureOutput()
            _ = try await AISubscriptionTransport.generate(connection, messages: [.init(role: .user, content: "Synthetic tool fixture")], tools: tools) { await output.append($0) }
            precondition(output.text == "CLI tool answer" && count == 1)
        }
        print("PASS subscription tools: Codex dynamic-tool RPC and Claude SDK MCP initialize/list/call/results, native tools disabled, same host executor")
    } catch { fatalError("CLI tool fixture failed: \(error)") }
    toolCLIFinished = true
}
wait("Subscription tool fixtures") { toolCLIFinished }

var toolSessionFinished = false
Task { @MainActor in
    do {
        let suite = "keylane.tool-session." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let connection = AIConnection(endpoint: "http://localhost/v1", model: "synthetic", mode: .complete)
        prefs.set(try JSONEncoder().encode(AIConfiguration.State(enabled: true, connections: [connection], selectedID: connection.id)), forKey: "aiConnections.v1")
        let settings = AIConfiguration(preferences: prefs)
        let interaction = AIInteractionPreferences(preferences: prefs)
        interaction.toolsEnabled = true
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ToolFixtureProtocol.self]
        let session = AIConversationSession(configuration: settings, runtime: AIRuntime(configuration: config), readKey: { _ in "synthetic-key" })
        var count = 0
        let tool = AIToolRegistration(definition: toolDefinition, requiresConfirmation: true) { _ in count += 1; return try .init(text: "42") }
        session.configureTools(preferences: interaction, source: { [tool] })
        func pending() async throws -> AIToolApproval {
            let deadline = Date().addingTimeInterval(2)
            while session.toolApproval.pending == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard let request = session.toolApproval.pending else { fatalError("Missing approval: " + session.status) }
            return request
        }
        ToolFixtureProtocol.rounds = 0
        precondition(session.submit("Synthetic fixture"))
        let first = try await pending()
        session.beginChat()
        precondition(session.running && session.toolApproval.pending?.id == first.id && ToolFixtureProtocol.rounds == 1)
        session.toolApproval.resolve(first.id, allow: true)
        let deadline = Date().addingTimeInterval(2)
        while session.running, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(count == 1 && session.lastAnswer == "verified answer" && ToolFixtureProtocol.rounds == 2)
        session.reset(); ToolFixtureProtocol.rounds = 0
        precondition(session.submit("Synthetic cancelled fixture"))
        let stale = try await pending()
        interaction.toolsEnabled = false
        precondition(!session.running && session.toolApproval.pending == nil)
        session.toolApproval.resolve(stale.id, allow: true)
        try await Task.sleep(for: .milliseconds(50))
        precondition(count == 1 && ToolFixtureProtocol.rounds == 1)
        print("PASS shared tool session: pending Quick AI confirmation transfers to AI Chat without resending; tool disable cancels pending action and rejects stale approval")
    } catch { fatalError("Tool session fixture failed: \(error)") }
    toolSessionFinished = true
}
wait("Shared tool session and approval handoff") { toolSessionFinished }
