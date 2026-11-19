import Foundation
import KeylaneCore

final class TranslatorFixtureProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var mode = "normal"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.main.async {
            var recorded = self.request
            if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                recorded.httpBody = bytes
            }
            Self.requests.append(recorded)
            let status = Self.mode == "error" ? 401 : 200
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            let body = self.request.url?.path.contains("completions") == true
                ? #"{"choices":[{"message":{"content":"AI result"},"finish_reason":"stop"}]}"#
                : #"{"data":{"translations":[{"translatedText":"你好","detectedSourceLanguage":"en"}]}}"#
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

let domain = "org.keylane.test.translator." + UUID().uuidString
let defaults = UserDefaults(suiteName: domain)!
defer { defaults.removePersistentDomain(forName: domain) }
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [TranslatorFixtureProtocol.self]
let ai = AIConfiguration(preferences: defaults)
let runtime = AIRuntime(configuration: config)
let controller = TranslatorController(ai: ai, runtime: runtime, defaults: defaults, session: URLSession(configuration: config),
                                      readCredentials: { _ in .init(key: "fixture") }, readAIKey: { _ in nil })
func wait(_ label: String, timeout: TimeInterval = 4, until predicate: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < end { RunLoop.main.run(until: .now.addingTimeInterval(0.02)) }
    precondition(predicate(), label)
    print("PASS " + label)
}
func drain(_ seconds: TimeInterval) { RunLoop.main.run(until: .now.addingTimeInterval(seconds)) }

controller.preferences.provider = .google
controller.begin(text: "old request")
controller.input = "latest request"
wait("debounced latest input produces translation", until: { controller.canUseOutput })
precondition(TranslatorFixtureProtocol.requests.count == 1)
precondition(controller.output == "你好" && controller.detectedSource == "en")
let request = TranslatorFixtureProtocol.requests[0]
guard let data = request.httpBody, let body = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
    preconditionFailure("Missing captured request body")
}
precondition(body["q"] == "latest request")
controller.input = ""
precondition(controller.output.isEmpty && !controller.canUseOutput)
drain(0.55)
precondition(TranslatorFixtureProtocol.requests.count == 1)

controller.input = "cancel before request"
controller.stop()
drain(0.55)
precondition(TranslatorFixtureProtocol.requests.count == 1 && !controller.loading)
controller.resume()
wait("hidden launcher cancels and resume restarts", until: { controller.canUseOutput })
controller.swap()
precondition(controller.source == "zh-Hans" && controller.target == "en" && controller.input == "你好")
controller.stop()

TranslatorFixtureProtocol.mode = "error"
controller.begin(text: "unauthorized")
wait("HTTP errors clear pending output", until: { !controller.error.isEmpty })
precondition(controller.output.isEmpty && !controller.canUseOutput && controller.error.contains("401"))
TranslatorFixtureProtocol.mode = "normal"
controller.retry()
wait("retry after error succeeds", until: { controller.canUseOutput })
controller.stop()

let connection = AIConnection(name: "Fixture", endpoint: "http://127.0.0.1:12345/v1", model: "fixture", mode: .complete)
precondition(ai.save(connection))
ai.setEnabled(true)
controller.preferences.provider = .ai
controller.preferences.modelID = connection.id
controller.begin(text: "AI translation")
wait("AI translation uses shared runtime", until: { controller.canUseOutput })
precondition(controller.output == "AI result")
controller.input = "discard on model disable"
ai.setEnabled(false)
wait("model disable prevents translation", until: { !controller.error.isEmpty })
precondition(!controller.canUseOutput)
controller.stop()

var command = TranslateCommand()
command.name = "翻译成日语"
command.source = "en"
command.target = "ja"
command.replaceSelection = true
controller.preferences.commands = [command]
let restored = TranslatorController(ai: ai, runtime: runtime, defaults: defaults, readAIKey: { _ in nil })
precondition(restored.preferences.commands == [command] && restored.preferences.modelID == connection.id)
controller.preferences.provider = .google
controller.begin(text: String(repeating: "中", count: 1667))
precondition(controller.error == TranslationFailure.inputTooLong.localizedDescription && !controller.loading)
controller.stop()
print("TRANSLATOR_INTEGRATION_OK")
