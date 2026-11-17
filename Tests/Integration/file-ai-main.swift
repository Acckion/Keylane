import Foundation
import Security
import KeylaneCore

final class FixtureProtocol: URLProtocol {
    static var mode = "ok"
    private var stopped = false
    private let lock = NSLock()
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.mode
        DispatchQueue.global().asyncAfter(deadline:.now()+(mode == "slow" ? 0.5 : 0.02)) {
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock(); if stopped { return }
            let code = mode == "error" ? 401 : 200
            let response = HTTPURLResponse(url:self.request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
            let text = mode == "bad" ? "{}" : "{\"choices\":[{\"message\":{\"content\":\"synthetic answer\"}}],\"usage\":{\"total_tokens\":3}}"
            self.client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            if mode == "stream" || mode == "incomplete" {
                let first = Data("data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\r\n\r\n".utf8)
                for byte in first { self.client?.urlProtocol(self, didLoad: Data([byte])) }
                if mode == "stream" {
                    let end = "data: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"total_tokens\":5}}\n\ndata: [DONE]\n\n"
                    self.client?.urlProtocol(self, didLoad: Data(end.utf8))
                }
            } else {
                self.client?.urlProtocol(self, didLoad: Data(text.utf8))
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
let suite = "org.keylane.file-ai-test."+UUID().uuidString
let prefs = UserDefaults(suiteName:suite)!
defer { prefs.removePersistentDomain(forName:suite) }
let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
let fresh = AIConfiguration(preferences: prefs)
precondition(!fresh.isAvailable && fresh.selected == nil)
prefs.set("http://localhost/v1", forKey: "fileAIEndpoint")
prefs.set("fixture-model", forKey: "fileAIModel")
let settings = AIConfiguration(preferences: prefs)
let legacy = settings.selected!
precondition(settings.isAvailable && legacy.mode == .complete && legacy.legacyAccount == "http://localhost/v1")
precondition(AIConfiguration(preferences: prefs).selected == legacy)
let controller = FileAIController(settings: settings, runtime: AIRuntime(configuration: configuration),
                                  preferences: prefs, readKey: { _ in nil })
func wait(_ label:String,_ condition:()->Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(),Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
    precondition(condition(),label+" "+controller.status)
}
controller.question = "fixture question"
controller.setFiles([URL(fileURLWithPath:"/synthetic/作业.pdf")])
controller.send(); wait("Successful response") { !controller.running }
precondition(controller.answer == "synthetic answer" && controller.status.contains("3 tokens"))
FixtureProtocol.mode = "error"; controller.send(); wait("HTTP failure") { !controller.running }; precondition(controller.status.contains("401"))
FixtureProtocol.mode = "bad"; controller.send(); wait("Malformed payload") { !controller.running }; precondition(controller.status.contains("请求未完成"))
FixtureProtocol.mode = "slow"; controller.send(); RunLoop.current.run(until:Date().addingTimeInterval(0.05)); controller.cancel()
RunLoop.current.run(until:Date().addingTimeInterval(0.7)); precondition(controller.status == "已取消" && controller.answer.isEmpty)
var invalid = legacy
invalid.endpoint = "http://external.example/v1"
precondition(!settings.save(invalid) && settings.selected == legacy)
let second = AIConnection(name: "second", endpoint: "http://127.0.0.1/v1", model: "fixture-model")
precondition(settings.save(second))
FixtureProtocol.mode = "stream"
controller.send(); wait("Streaming response") { !controller.running }
precondition(controller.answer == "你好" && controller.status.contains("5 tokens"))
FixtureProtocol.mode = "incomplete"
controller.send(); wait("Interrupted stream") { !controller.running }
precondition(controller.answer == "你" && controller.status.contains("不完整"))
FixtureProtocol.mode = "slow"
controller.send()
settings.setEnabled(false)
controller.send()
precondition(!controller.running && controller.status.contains("启用"))
settings.select(legacy.id)
precondition(AIConfiguration(preferences: prefs).selected == legacy)
print("PASS file AI fixture transport: response, usage, HTTP failure, malformed payload, cancellation/stale response, HTTPS validation, migration, Unicode SSE, truncation and disable; no external requests or real keys")

let credentialKey = kSecAttrService as String
let accountKey = kSecAttrAccount as String
var changed = legacy
changed.endpoint = "https://replacement.example/v1"
precondition(settings.save(changed))
let reloaded = AIConfiguration(preferences: prefs)
let edited = reloaded.selected!
let currentQueries = AIConfiguration.credentialQueries(for: edited)
precondition(currentQueries.count == 1 && currentQueries[0][credentialKey] as? String == "org.keylane.ai")
let removalQueries = AIConfiguration.credentialQueries(for: edited, includingPreviousEndpoints: true)
precondition(removalQueries.contains { $0[credentialKey] as? String == "org.keylane.file-ai"
    && $0[accountKey] as? String == legacy.legacyAccount })
precondition(removalQueries.contains { ($0[accountKey] as? String)?.hasSuffix("|http://localhost/v1/chat/completions") == true })
var restored = edited
restored.endpoint = "http://localhost/v1/"
precondition(reloaded.save(restored))
let restoredQueries = AIConfiguration.credentialQueries(for: reloaded.selected!)
precondition(restoredQueries.map { $0[credentialKey] as? String } == ["org.keylane.ai", "org.keylane.file-ai"])
print("PASS legacy credential routing: endpoint changes, reload, original endpoint restoration and removal queries")
settings.setEnabled(true)
settings.select(second.id)
let quick = QuickAIController(configuration: settings, runtime: AIRuntime(configuration: configuration), readKey: { _ in nil })
FixtureProtocol.mode = "stream"
precondition(!quick.submit("  "))
precondition(quick.submit("first") && !quick.submit("while busy"))
wait("Quick AI first answer") { !quick.running }
precondition(quick.turns.count == 1 && quick.turns[0].complete && quick.lastAnswer == "你好")
let followUp = quick.messages(for: "second")
precondition(followUp.map(\.role.rawValue) == ["user", "assistant", "user"])
precondition(followUp.map(\.content) == ["first", "你好", "second"])
precondition(quick.submit("second"))
wait("Quick AI follow-up") { !quick.running }
precondition(quick.turns.count == 2 && quick.turns[1].complete)
FixtureProtocol.mode = "slow"
precondition(quick.submit("cancelled"))
quick.stop()
RunLoop.current.run(until: Date().addingTimeInterval(0.7))
precondition(quick.status == "已停止。" && quick.turns.last?.answer.isEmpty == true)
settings.select(legacy.id)
precondition(quick.turns.isEmpty && !quick.running)
print("PASS Quick AI: initial prompt, complete-turn follow-up, single active request, cancellation and model isolation")

settings.select(second.id)
FixtureProtocol.mode = "stream"
precondition(quick.submit("handoff"))
let transferredTurn = quick.turns.first!.id
quick.beginChat()
quick.leaveLauncher()
precondition(quick.isInChat && quick.running && quick.turns.first?.id == transferredTurn)
wait("AI Chat receives active Quick AI answer") { !quick.running }
precondition(quick.turns.count == 1 && quick.turns.first?.id == transferredTurn && quick.lastAnswer == "你好")
FixtureProtocol.mode = "slow"
precondition(quick.submit("close while generating"))
quick.closeChat()
RunLoop.current.run(until: Date().addingTimeInterval(0.7))
precondition(!quick.isInChat && !quick.running && quick.turns.isEmpty)
print("PASS AI Chat handoff: same active turn after launcher leaves; closing discards the session and late results")

let historyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("keylane-history-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: historyDirectory) }
let historyURL = historyDirectory.appendingPathComponent("history.sqlite")
let history = AIChatHistory(url: historyURL)
let conversation = QuickAIController(configuration: settings, runtime: AIRuntime(configuration: configuration),
                                     history: history, readKey: { _ in nil })
FixtureProtocol.mode = "stream"
precondition(conversation.submit("保留这段对话"))
precondition(!FileManager.default.fileExists(atPath: historyURL.path))
conversation.beginChat()
let savedID = conversation.chatID!
let savedTurnID = conversation.turns.first!.id
conversation.leaveLauncher()
wait("Save handed-off response") { !conversation.running && conversation.chats.first?.id == savedID }
conversation.closeChat()

let reopened = QuickAIController(configuration: settings, runtime: AIRuntime(configuration: configuration),
                                 history: AIChatHistory(url: historyURL), readKey: { _ in nil })
reopened.beginChat(restoreLatest: true)
wait("Restore most recent chat from SQLite") { !reopened.loadingChat && reopened.chatID == savedID }
precondition(reopened.turns.first?.id == savedTurnID && reopened.turns.first?.complete == true)
precondition(reopened.lastAnswer == "你好")
settings.select(legacy.id)
precondition(!reopened.matchesCurrentModel && !reopened.submit("do not send history to another endpoint"))
settings.select(second.id)
precondition(reopened.matchesCurrentModel)

reopened.reset()
FixtureProtocol.mode = "slow"
precondition(reopened.submit("切换时的未完成问题"))
let interruptedID = reopened.chatID!
reopened.openChat(savedID)
wait("Switch while generating") { !reopened.loadingChat && reopened.chatID == savedID }
precondition(!reopened.running && reopened.turns.first?.id == savedTurnID)
reopened.openChat(interruptedID)
wait("Restore interrupted chat") { !reopened.loadingChat && reopened.chatID == interruptedID }
precondition(reopened.turns.count == 1 && !reopened.turns[0].complete)
precondition(reopened.lastAnswer == nil)
reopened.deleteChat(interruptedID)
wait("Delete chat") { reopened.chats.count == 1 && reopened.chats.first?.id == savedID }
precondition(reopened.chatID == nil && reopened.turns.isEmpty)
let recordsOnDisk = try history.list()
precondition(recordsOnDisk.map(\.id) == [savedID])
let permissions = try FileManager.default.attributesOfItem(atPath: historyURL.path)[.posixPermissions] as? NSNumber
precondition(permissions?.intValue == 0o600)
print("PASS AI Chat history: lazy SQLite, handoff, reopen, model isolation, interrupted turns, deletion and file permissions")
