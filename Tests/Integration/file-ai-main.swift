import Foundation
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
            self.client?.urlProtocol(self,didLoad:Data(text.utf8)); self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
let suite = "org.keylane.file-ai-test."+UUID().uuidString
let prefs = UserDefaults(suiteName:suite)!
defer { prefs.removePersistentDomain(forName:suite) }
let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
let controller = FileAIController(preferences:prefs,configuration:configuration,useKeychain:false)
func wait(_ label:String,_ condition:()->Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(),Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
    precondition(condition(),label+" "+controller.status)
}
controller.endpoint = "http://localhost/v1"; controller.modelName = "fixture-model"; controller.question = "fixture question"
controller.setFiles([URL(fileURLWithPath:"/synthetic/作业.pdf")])
controller.send(); wait("Successful response") { !controller.running }
precondition(controller.answer == "synthetic answer" && controller.status.contains("3 tokens"))
FixtureProtocol.mode = "error"; controller.send(); wait("HTTP failure") { !controller.running }; precondition(controller.status.contains("401"))
FixtureProtocol.mode = "bad"; controller.send(); wait("Malformed payload") { !controller.running }; precondition(controller.status.contains("请求未完成"))
FixtureProtocol.mode = "slow"; controller.send(); RunLoop.current.run(until:Date().addingTimeInterval(0.05)); controller.cancel()
RunLoop.current.run(until:Date().addingTimeInterval(0.7)); precondition(controller.status == "已取消" && controller.answer.isEmpty)
controller.endpoint = "http://external.example/v1"; controller.send(); precondition(controller.status.contains("HTTPS"))
print("PASS file AI fixture transport: response, usage, HTTP failure, malformed payload, cancellation/stale response, HTTPS validation; no external requests or real keys")
