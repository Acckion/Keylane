
// Tool tests use synthetic HTTP/CLI data and never load an account, real file or calendar.
@MainActor final class ToolFixtureOutput {
    var text = ""
    var events: [AIResponseEvent] = []
    func event(_ event: AIResponseEvent) { events.append(event) }
    func append(_ delta: String) { text += delta }
}
@MainActor final class ToolFixtureReferences { var reference: String? }
@MainActor final class ToolFixtureAvailability { var allowed = true }
@MainActor final class ToolFixtureLease { var revision = UUID(); var enabled = true }

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
            var object: [String: Any]
            if anthropic {
                object = ["content": next ? [["type": "text", "text": "verified answer"]] : [
                    ["type": "thinking", "thinking": "fixture summary", "signature": "opaque-fixture"],
                    ["type": "tool_use", "id": id, "name": "fixture_add", "input": ["number": 21]]],
                    "stop_reason": next ? "end_turn" : "tool_use", "usage": ["input_tokens": 1, "output_tokens": 2]]
            } else {
                var message: [String: Any] = ["role": "assistant", "content": next ? "verified answer" : "", "reasoning_summary": "synthetic public reasoning"]
                if !next { message["tool_calls"] = [["id": id, "type": "function", "function": ["name": "fixture_add", "arguments": "{\"number\":21}"]]] }
                object = ["choices": [["message": message, "finish_reason": next ? "stop" : "tool_calls"]], "usage": ["total_tokens": 3]]
            }
            if Self.scenario == "scoped-revocation", !next {
                precondition(!anthropic && body["stream"] as? Bool != true)
                object = ["choices": [["message": ["role": "assistant", "content": "", "tool_calls": [
                    ["id": "private-one", "type": "function", "function": ["name": "fixture_private", "arguments": "{}"]],
                    ["id": "confirm-two", "type": "function", "function": ["name": "fixture_confirm", "arguments": "{}"]]
                ]], "finish_reason": "tool_calls"]]]
            }
            object["error"] = NSNull()
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
                events = events.map { event in var value = event; value["error"] = NSNull(); return value }
                responseData = Data(try events.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0, options: .prettyPrinted), as: UTF8.self).replacingOccurrences(of: "\n", with: "\ndata: ") + "\n\n" }.joined().utf8)
            }
            if Self.scenario == "held-open", !anthropic { responseData.append(Data("data: [DONE]\n\n".utf8)) }
            if Self.scenario == "held-open" { responseData.append(Data((":" + String(repeating: " ", count: 65_536) + "\n\n").utf8)) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": body["stream"] as? Bool == true ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            if Self.scenario != "held-open" { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

let toolDefinition = try AIToolDefinition(name: "fixture_add", title: "Synthetic calculation", description: "Synthetic test only", parameters: [
    .init("number", description: "Number", kind: .integer(minimum: 1, maximum: 100))])
var toolsFinished = false
Task { @MainActor in
    do {
        let capabilitySuite = "org.keylane.capability.fixture.\(UUID())"
        let capabilityPreferences = UserDefaults(suiteName: capabilitySuite)!
        defer { capabilityPreferences.removePersistentDomain(forName: capabilitySuite) }
        let capabilitySession = AIConversationSession(configuration: AIConfiguration(preferences: capabilityPreferences),
            runtime: AIRuntime(), readKey: { _ in nil })
        let capabilityInteraction = AIInteractionPreferences(preferences: capabilityPreferences)
        let firstOwner = ModuleID(rawValue: "fixture.a"), secondOwner = ModuleID(rawValue: "fixture.b")
        var firstLeaseCount = 0, secondLeaseCount = 0
        var firstTool = AIToolRegistration(definition: toolDefinition) { _ in try .init(text: "a") }
        firstTool.owner = firstOwner; firstTool.ownerTitle = "A"
        firstTool.snapshotAvailability = { firstLeaseCount += 1; return { true } }
        var secondTool = AIToolRegistration(definition: try .init(name: "fixture_b", title: "B", description: "Fixture")) { _ in try .init(text: "b") }
        secondTool.owner = secondOwner; secondTool.ownerTitle = "B"
        secondTool.snapshotAvailability = { secondLeaseCount += 1; return { true } }
        var discoveryNames: [String] = []
        capabilitySession.configureTools(preferences: capabilityInteraction, discovery: { tools in
            discoveryNames = tools.map { $0.definition.name }
            return .init(definition: try! .init(name: "fixture_discovery", title: "Discover", description: "Fixture")) { _ in try .init(text: "metadata") }
        }) { [firstTool, secondTool] in [firstTool, secondTool] }
        precondition(capabilitySession.toolCapabilities.map(\.id) == [firstOwner, secondOwner])
        precondition(capabilitySession.availableTools.count == 3)
        capabilitySession.setToolCapability(secondOwner, enabled: false)
        precondition(capabilitySession.availableTools.map(\.name) == [toolDefinition.name, "fixture_discovery"])
        precondition(discoveryNames == [toolDefinition.name])
        precondition(firstLeaseCount == 0 && secondLeaseCount == 0, "Browsing must not snapshot private provider state")
        capabilityInteraction.toolsEnabled = true
        let selectedRequest = try capabilitySession.toolRegistrationsForRequest(supportsTools: true)
        precondition(selectedRequest.map { $0.definition.name } == [toolDefinition.name, "fixture_discovery"])
        precondition(firstLeaseCount == 1 && secondLeaseCount == 0, "Only selected providers may freeze a lease")
        capabilitySession.setToolCapability(firstOwner, enabled: false)
        precondition(capabilitySession.availableTools.isEmpty)
        capabilityInteraction.toolsEnabled = true
        let noRequestedTools = try capabilitySession.toolRegistrationsForRequest(supportsTools: false)
        precondition(noRequestedTools.isEmpty && firstLeaseCount == 1 && secondLeaseCount == 0)
        capabilitySession.resetToolCapabilities()
        precondition(capabilitySession.availableTools.count == 3)
        do { _ = try capabilitySession.toolRegistrationsForRequest(supportsTools: false); preconditionFailure("Unsupported model received tools") }
        catch AIResponseError.toolsUnavailable { }
        capabilityInteraction.toolsEnabled = false
        let globallyDisabledTools = try capabilitySession.toolRegistrationsForRequest(supportsTools: false)
        precondition(globallyDisabledTools.isEmpty && firstLeaseCount == 1 && secondLeaseCount == 0)
        print("PASS session module selection, explicit empty catalog and discovery restricted to selected capabilities")
        var performed = 0
        let availability = ToolFixtureAvailability()
        let registration = AIToolRegistration(definition: toolDefinition, available: { availability.allowed }) { arguments in
            performed += 1
            guard case .number(21) = arguments["number"] else { throw AIToolContractError.invalidArguments }
            let resource = try AIResourceReference(moduleID: .init(rawValue: "fixture"), sourceID: "synthetic")
            return try .init(text: "42", resourceSnapshot: .init(reference: resource, revision: "v1", text: "42"))
        }
        func run(_ registrations: [AIToolRegistration]? = nil) throws -> AIToolRun {
            try AIToolRun(registrations: registrations ?? [registration], isCurrent: { true }, approve: { _, _ in true })
        }
        for proto in [AIWireProtocol.openAI, .anthropic] {
            for stream in [false, true] {
                ToolFixtureProtocol.bodies = []; ToolFixtureProtocol.rounds = 0
                ToolFixtureProtocol.scenario = stream ? "held-open" : "ok"
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ToolFixtureProtocol.self]
                let runtime = AIRuntime(configuration: config)
                let endpoint = proto == .anthropic ? "https://synthetic.invalid/v1" : (stream ? "http://127.0.0.1:11434/v1" : "https://custom.invalid/advanced/v1")
                var connection = AIConnection(endpoint: endpoint, model: "synthetic", mode: stream ? .streaming : .complete, wireProtocol: proto)
                connection.additionalParametersJSON = "{\"temperature\":0.2}"
                let output = ToolFixtureOutput()
                let tokens = try await runtime.generate(connection: connection, readKey: { _ in "synthetic-key" }, messages: [.init(role: .user, content: "fixture")], tools: run(), progress: { await output.event($0) }) { await output.append($0) }
                precondition(output.text == "verified answer" && tokens == 6 && ToolFixtureProtocol.rounds == 2)
                let wireBodies = String(decoding: try JSONSerialization.data(withJSONObject: ToolFixtureProtocol.bodies), as: UTF8.self)
                precondition(!wireBodies.contains("keylane-resource"), "Host resource metadata must not be transmitted as authority")
                precondition(ToolFixtureProtocol.bodies[0]["temperature"] as? Double == 0.2)
                let thoughts = output.events.compactMap { event -> String? in if case .thinking(_, let delta) = event { return delta }; return nil }.joined()
                precondition(!thoughts.isEmpty && !thoughts.contains("opaque-fixture"))
            }
        }
        ToolFixtureProtocol.scenario = "ok"
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
        // Capabilities are private to this run and require a human-readable confirmation.
        let referenceDefinition = try AIToolDefinition(name: "fixture_reference", title: "Read fixture", description: "Fixture", parameters: [])
        var revision = UUID()
        var reads = 0
        let scoped = AIToolRegistration(definition: referenceDefinition, requiresConfirmation: true,
            snapshotAvailability: { let expected = revision; return { revision == expected } },
            confirmationDetail: { _, scope in
                let store = scope.state(ToolFixtureReferences.self) { ToolFixtureReferences() }
                return store.reference ?? "synthetic document.txt"
            }, performInRun: { _, scope in
                reads += 1
                let store = scope.state(ToolFixtureReferences.self) { ToolFixtureReferences() }
                let result = store.reference ?? "new-run"
                store.reference = "same-run"
                return try .init(text: result)
            })
        do { _ = try run([scoped]); preconditionFailure("Unfrozen private-data tool accepted") }
        catch AIToolContractError.unavailable { }
        let frozen = scoped.forRun()
        let referenceRun = try AIToolRun(registrations: [frozen], isCurrent: { true }, approve: { _, detail in
            precondition(detail == "synthetic document.txt" || detail == "same-run"); return true
        })
        let firstReference = try AIToolCall(id: "ref-one", name: "fixture_reference", arguments: [:])
        let secondReference = try AIToolCall(id: "ref-two", name: "fixture_reference", arguments: [:])
        let firstResult = try await referenceRun.execute(firstReference, scope: "fixture", progress: { _ in })
        let secondResult = try await referenceRun.execute(secondReference, scope: "fixture", progress: { _ in })
        precondition(firstResult.text == "new-run" && secondResult.text == "same-run")
        let separateRun = try run([frozen])
        let separateResult = try await separateRun.execute(firstReference, scope: "fixture", progress: { _ in })
        precondition(separateResult.text == "new-run")
        let deniedReference = try AIToolRun(registrations: [frozen], isCurrent: { true }, approve: { _, _ in false })
        let beforeReads = reads
        _ = try await deniedReference.execute(firstReference, scope: "fixture", progress: { _ in })
        precondition(reads == beforeReads)
        let revokedReference = try AIToolRun(registrations: [frozen], isCurrent: { true }, approve: { _, _ in revision = UUID(); return true })
        let revokedResult = try await revokedReference.execute(firstReference, scope: "fixture", progress: { _ in })
        precondition(revokedResult.isError && reads == beforeReads)
        print("PASS run-scoped tools: frozen feature lease, human confirmation, isolated references, denial and revocation before read")
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
            ["type": "reasoning.encrypted", "id": "opaque-one", "data": "opaque-one"]]]]]])
        _ = try collector.consume(["choices": [["delta": ["reasoning_details": [
            ["index": 0, "type": "reasoning.text", "text": "second"],
            ["type": "reasoning.encrypted", "id": "opaque-two", "data": "opaque-two"]]]]]])
        precondition(collector.lastThinking == "second")
        _ = try collector.consume(["choices": [["delta": ["reasoning_content": "complete reasoning"]]]])
        _ = try collector.consume(["choices": [["delta": ["reasoning_content": NSNull(), "content": NSNull()]]]])
        _ = try collector.consume(["choices": [["delta": ["tool_calls": [["index": 0, "id": NSNull(), "function": ["name": NSNull(), "arguments": NSNull()]]]]]]])
        let fragmented = try collector.finish()
        precondition(fragmented.assistant["reasoning_content"] as? String == "complete reasoning")
        let continuation = fragmented.assistant["reasoning_details"] as! [[String: Any]]
        precondition(continuation[0]["text"] as? String == "First second" && continuation.count == 3 && continuation[1]["data"] as? String == "opaque-one" && continuation[2]["data"] as? String == "opaque-two")
        precondition(fragmented.calls.first?.name == "fixture_add" && fragmented.calls.first?.arguments["number"] == .number(21))
        do { _ = try AIToolHTTPTransport.decode(["choices": [["message": ["content": "cut"], "finish_reason": "length"]]], anthropic: false); preconditionFailure("Truncation accepted") }
        catch AIResponseError.incomplete { }
        do { _ = try AIToolHTTPTransport.decode(["error": ["message": "Synthetic failure"]], anthropic: false); preconditionFailure("Service error accepted") }
        catch AIResponseError.serviceError { }
        precondition(AIToolHTTPTransport.publicThinking(["reasoning_details": [["type": "reasoning.encrypted", "data": "opaque"], ["type": "reasoning.summary", "summary": "public summary"]]]) == "public summary")
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
        elif method == 'config/read':
            assert 'features.plugins=false' in sys.argv and 'features.skill_mcp_dependency_install=false' in sys.argv
            result = {'config':{'mcp_servers':{'external-fixture':{'command':'must-not-start'}}}}
        elif method == 'thread/start':
            assert request['params']['config']['mcp_servers']['external-fixture']['enabled'] is False
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

var scopedPublicationFinished = false
Task { @MainActor in
    do {
        defer { ToolFixtureProtocol.scenario = "ok"; ToolFixtureProtocol.rounds = 0; ToolFixtureProtocol.bodies = [] }
        for reenable in [false, true] {
            let lease = ToolFixtureLease()
            let privateDefinition = try AIToolDefinition(name: "fixture_private", title: "Read private fixture", description: "Synthetic private source", parameters: [])
            let confirmDefinition = try AIToolDefinition(name: "fixture_confirm", title: "Confirm second fixture", description: "Synthetic approval", parameters: [])
            var reads = 0
            var secondExecutions = 0
            let scoped = AIToolRegistration(definition: privateDefinition, requiresConfirmation: true,
                snapshotAvailability: { let revision = lease.revision; return { lease.enabled && lease.revision == revision } },
                confirmationDetail: { _, _ in "Synthetic source preview" },
                performInRun: { _, _ in reads += 1; return try .init(text: "SECRET_NOT_FOR_REVOKED_POST") })
            let second = AIToolRegistration(definition: confirmDefinition, requiresConfirmation: true) { _ in secondExecutions += 1; return try .init(text: "second") }
            let broker = AIToolApprovalBroker()
            var waitedForSecond = false
            let tools = try AIToolRun(registrations: [scoped.forRun(), second],
                recipient: .init(destination: "https://synthetic.invalid", model: "synthetic"), isCurrent: { true },
                approve: { title, detail in
                    guard title == "Confirm second fixture" else { return true }
                    let approval = Task { @MainActor in await broker.request(title: title, arguments: detail) }
                    while broker.pending == nil { await Task.yield() }
                    waitedForSecond = true
                    lease.enabled = false; lease.revision = UUID()
                    if reenable { lease.enabled = true }
                    broker.resolve(broker.pending!.id, allow: true)
                    return await approval.value
                })
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ToolFixtureProtocol.self]
            ToolFixtureProtocol.scenario = "scoped-revocation"; ToolFixtureProtocol.rounds = 0; ToolFixtureProtocol.bodies = []
            do {
                _ = try await AIRuntime(configuration: configuration).generate(
                    connection: .init(endpoint: "https://synthetic.invalid/v1", model: "synthetic", mode: .complete),
                    readKey: { _ in "synthetic-key" }, messages: [.init(role: .user, content: "Synthetic revocation fixture")], tools: tools) { _ in }
                preconditionFailure("Revoked private result reached a follow-up model request")
            } catch is CancellationError { }
            precondition(reads == 1 && secondExecutions == 0 && waitedForSecond && ToolFixtureProtocol.rounds == 1)
            let sent = String(decoding: try JSONSerialization.data(withJSONObject: ToolFixtureProtocol.bodies), as: UTF8.self)
            precondition(!sent.contains("SECRET_NOT_FOR_REVOKED_POST"))
        }
        print("PASS scoped disclosure: first private result revoked during second approval cancels before follow-up POST; disable and off/on both withhold transcript")
    } catch { fatalError("Scoped disclosure fixture: \(error)") }
    scopedPublicationFinished = true
}
wait("Scoped tool revocation before transport publication") { scopedPublicationFinished }

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
        var tool = AIToolRegistration(definition: toolDefinition, requiresConfirmation: true) { _ in count += 1; return try .init(text: "42") }
        let capabilityOwner = ModuleID(rawValue: "fixture.session-tools")
        tool.owner = capabilityOwner
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
        interaction.toolsEnabled = true
        session.reset(); ToolFixtureProtocol.rounds = 0
        precondition(session.submit("Synthetic selection-change fixture"))
        let selectionApproval = try await pending()
        session.setToolCapability(capabilityOwner, enabled: false)
        precondition(!session.running && session.toolApproval.pending == nil && session.availableTools.isEmpty)
        session.toolApproval.resolve(selectionApproval.id, allow: true)
        try await Task.sleep(for: .milliseconds(50))
        precondition(count == 1 && ToolFixtureProtocol.rounds == 1)
        session.resetToolCapabilities()
        precondition(!session.running && count == 1 && ToolFixtureProtocol.rounds == 1)
        print("PASS module selection change cancels pending approval; restore does not resume or resend")
        print("PASS shared tool session: pending Quick AI confirmation transfers to AI Chat without resending; tool disable cancels pending action and rejects stale approval")
    } catch { fatalError("Tool session fixture failed: \(error)") }
    toolSessionFinished = true
}
wait("Shared tool session and approval handoff") { toolSessionFinished }

final class InstructionFixtureProtocol: URLProtocol {
    static var bodies: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
            }
            Self.bodies.append(try JSONSerialization.jsonObject(with: data) as! [String: Any])
            let object: [String: Any] = request.url!.path.hasSuffix("/messages")
                ? ["type": "message", "content": [["type": "text", "text": "done"]], "stop_reason": "end_turn"]
                : ["choices": [["message": ["role": "assistant", "content": "done"], "finish_reason": "stop"]]]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
var moduleInstructionsFinished = false
Task { @MainActor in
    do {
        for wire in [AIWireProtocol.openAI, .anthropic] {
            let suite = "keylane.instructions." + UUID().uuidString
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            var connection = AIConnection(endpoint: "https://synthetic.invalid/v1", model: "synthetic", mode: .complete, wireProtocol: wire)
            connection.supportsImages = true
            prefs.set(try JSONEncoder().encode(AIConfiguration.State(enabled: true, connections: [connection], selectedID: connection.id)), forKey: "aiConnections.v1")
            let configuration = AIConfiguration(preferences: prefs)
            let interaction = AIInteractionPreferences(preferences: prefs); interaction.toolsEnabled = true
            let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [InstructionFixtureProtocol.self]
            let session = AIConversationSession(configuration: configuration, runtime: AIRuntime(configuration: transport), readKey: { _ in nil })
            let firstOwner = ModuleID(rawValue: "fixture.first"), otherOwner = ModuleID(rawValue: "fixture.other")
            var leases = 0
            var first = AIToolRegistration(definition: try .init(name: "fixture_first", title: "First", description: "Fixture")) { _ in try .init(text: "data") }
            first.owner = firstOwner; first.moduleInstructions = .init("FIRST_ONLY_GUIDANCE")
            first.snapshotAvailability = { leases += 1; return { true } }
            var other = AIToolRegistration(definition: try .init(name: "fixture_other", title: "Other", description: "Fixture")) { _ in try .init(text: "data") }
            other.owner = otherOwner; other.moduleInstructions = .init("OTHER_ONLY_GUIDANCE")
            var catalog = [first, other]
            session.configureTools(preferences: interaction, source: { catalog })
            session.chatInstructions = "KEEP_USER_INSTRUCTIONS"
            session.setToolCapability(otherOwner, enabled: false)
            InstructionFixtureProtocol.bodies = []
            precondition(leases == 0 && session.submit("Synthetic instruction test"))
            catalog[0].moduleInstructions = .init("LATER_CATALOG_GUIDANCE")
            let deadline = Date().addingTimeInterval(3)
            while session.running, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            precondition(!session.running && session.lastAnswer == "done" && leases == 1)
            let request = InstructionFixtureProtocol.bodies[0]
            let system = wire == .anthropic ? request["system"] as! String : (request["messages"] as! [[String: Any]])[0]["content"] as! String
            precondition(system.contains("FIRST_ONLY_GUIDANCE") && system.hasSuffix("KEEP_USER_INSTRUCTIONS"))
            precondition(!system.contains("OTHER_ONLY_GUIDANCE") && !system.contains("LATER_CATALOG_GUIDANCE"))
            let tools = request["tools"] as! [[String: Any]]
            precondition(tools.count == 1 && session.chatInstructions == "KEEP_USER_INSTRUCTIONS")
            // Merge regression: the same production submit must preserve both
            // #229 image blocks and #234 frozen selected-module instructions.
            session.reset(); session.chatInstructions = "KEEP_USER_INSTRUCTIONS"
            catalog[0].moduleInstructions = first.moduleInstructions
            let raster = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let bytes = NSMutableData()
            let encoder = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(encoder, raster.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(encoder))
            let image = try AIImageInput(data: bytes as Data, mediaType: "image/jpeg", width: 2, height: 2)
            session.composer.attachments = [.init(title: "Synthetic image", text: "Fixture", image: image)]
            InstructionFixtureProtocol.bodies = []
            precondition(session.submit("Combined image and guidance"))
            catalog[0].moduleInstructions = .init("LATER_CATALOG_GUIDANCE")
            while session.running { try await Task.sleep(for: .milliseconds(10)) }
            precondition(session.lastAnswer == "done" && leases == 2)
            let combined = InstructionFixtureProtocol.bodies[0]
            let combinedMessages = combined["messages"] as! [[String: Any]]
            let combinedSystem = wire == .anthropic ? combined["system"] as! String : combinedMessages[0]["content"] as! String
            precondition(combinedSystem.contains("FIRST_ONLY_GUIDANCE") && combinedSystem.hasSuffix("KEEP_USER_INSTRUCTIONS"))
            precondition(!combinedSystem.contains("OTHER_ONLY_GUIDANCE") && !combinedSystem.contains("LATER_CATALOG_GUIDANCE"))
            let blocks = combinedMessages.first { $0["role"] as? String == "user" }!["content"] as! [[String: Any]]
            if wire == .anthropic {
                let encoded = blocks.first { $0["type"] as? String == "image" }!["source"] as! [String: String]
                precondition(encoded["data"] == image.data.base64EncodedString())
            } else {
                let encoded = blocks.first { $0["type"] as? String == "image_url" }!["image_url"] as! [String: String]
                precondition(encoded["url"] == "data:image/jpeg;base64," + image.data.base64EncodedString())
            }
            precondition((combined["tools"] as! [[String: Any]]).count == 1)
            session.reset(); session.chatInstructions = "KEEP_USER_INSTRUCTIONS"
            session.setToolCapability(firstOwner, enabled: false)
            InstructionFixtureProtocol.bodies = []
            precondition(session.submit("Explicit empty selection"))
            while session.running { try await Task.sleep(for: .milliseconds(10)) }
            precondition(session.lastAnswer == "done")
            let emptyBody = InstructionFixtureProtocol.bodies[0]
            let emptySystem = wire == .anthropic ? emptyBody["system"] as! String : (emptyBody["messages"] as! [[String: Any]])[0]["content"] as! String
            precondition(emptySystem == "KEEP_USER_INSTRUCTIONS" && emptyBody["tools"] == nil && leases == 2)
            session.reset(); session.resetToolCapabilities()
            catalog[0].moduleInstructions = .init(String(repeating: "x", count: 4097))
            session.composer.text = "Preserve rejected draft"
            let turns = session.turns
            precondition(!session.submit(session.composer.text))
            precondition(session.composer.text == "Preserve rejected draft" && session.turns == turns && leases == 2)
            interaction.toolsEnabled = false
            precondition(session.submit("Globally disabled tools"))
            while session.running { try await Task.sleep(for: .milliseconds(10)) }
            precondition(session.lastAnswer == "done" && leases == 2, "Global-off fixture wire=\(wire) status=\(session.status) answer=\(String(describing: session.lastAnswer)) leases=\(leases) requests=\(InstructionFixtureProtocol.bodies.count)")
        }
        print("PASS module guidance: combined image/frozen guidance payloads, selected-only OpenAI/Anthropic requests, atomic tool/instruction metadata snapshot, dispatch-only leases, base preservation, empty/global-off omit guidance, invalid guidance preserves draft")
    } catch { fatalError("Module instruction fixture failed: \(error)") }
    moduleInstructionsFinished = true
}
wait("Module instruction requests") { moduleInstructionsFinished }
