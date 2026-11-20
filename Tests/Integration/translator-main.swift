import AppKit
import ApplicationServices
import Foundation
import KeylaneCore

final class TranslatorFixtureProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var mode = "normal"
    private var completion: DispatchWorkItem?
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
            if Self.mode == "hang" {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                return
            }
            if Self.mode == "stream" {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\n".utf8))
                let completion = DispatchWorkItem {
                    self.client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}\n\ndata: [DONE]\n\n".utf8))
                    self.client?.urlProtocolDidFinishLoading(self)
                }
                self.completion = completion
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: completion)
                return
            }
            let body = self.request.url?.path.contains("completions") == true
                ? #"{"choices":[{"message":{"content":"AI result"},"finish_reason":"stop"}]}"#
                : #"{"data":{"translations":[{"translatedText":"你好","detectedSourceLanguage":"en"}]}}"#
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { completion?.cancel() }
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
controller.resume()
wait("hidden launcher cancels and repeated resume restarts once", until: { controller.canUseOutput })
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
var streaming = connection
streaming.mode = .streaming
precondition(ai.save(streaming))
TranslatorFixtureProtocol.mode = "stream"
controller.begin(text: "stream translation")
wait("AI output appears before generation completes", until: { controller.output == "你" && controller.loading })
precondition(!controller.canUseOutput)
wait("AI stream completes with combined translation", until: { controller.canUseOutput })
precondition(controller.output == "你好")
controller.begin(text: "cancel partial stream")
wait("partial stream started", until: { controller.output == "你" && controller.loading })
controller.stop()
precondition(controller.output.isEmpty)
drain(0.5)
precondition(controller.output.isEmpty && !controller.loading)

let unrelated = AIConnection(name: "Other model", endpoint: "http://127.0.0.1:12345/v1", model: "other")
precondition(ai.save(unrelated))
TranslatorFixtureProtocol.mode = "hang"
let bounded = TranslatorController(ai: ai, runtime: runtime, defaults: defaults, requestTimeout: .milliseconds(1100), readAIKey: { _ in nil })
let beforeUnrelatedRefresh = TranslatorFixtureProtocol.requests.count
bounded.begin(text: "no response")
// Background catalog changes must not renew this request's deadline.
for index in 0..<9 {
    ai.setModelVisible(unrelated.id, visible: index.isMultiple(of: 2))
    drain(0.15)
}
precondition(!bounded.loading, "Unrelated AI updates repeatedly restarted the translation and postponed its timeout")
precondition(bounded.error.contains("超时") && !bounded.canUseOutput)
precondition(TranslatorFixtureProtocol.requests.count == beforeUnrelatedRefresh + 1)
print("PASS unrelated model refresh does not restart translation or postpone timeout")
TranslatorFixtureProtocol.mode = "stream"
bounded.retry()
wait("retry succeeds after AI timeout", until: { bounded.canUseOutput })
let completedRequestCount = TranslatorFixtureProtocol.requests.count
ai.setModelVisible(unrelated.id, visible: false)
drain(0.2)
precondition(bounded.output == "你好" && bounded.canUseOutput)
precondition(TranslatorFixtureProtocol.requests.count == completedRequestCount)
print("PASS unrelated AI updates preserve completed translations")
bounded.stop()
TranslatorFixtureProtocol.mode = "normal"
controller.begin(text: "discard on model disable")
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

let editor = TranslatorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
var committedText = ""
editor.onCommittedChange = { committedText = $0 }
precondition(editor.showsPlaceholder)
editor.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
precondition(editor.hasMarkedText() && !editor.showsPlaceholder && committedText.isEmpty)
editor.unmarkText()
precondition(!editor.hasMarkedText() && committedText == "a" && !editor.showsPlaceholder)
editor.string = ""
precondition(editor.showsPlaceholder)
editor.insertText("你好", replacementRange: NSRange(location: 0, length: 0))
precondition(committedText == "你好" && !editor.showsPlaceholder)
editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
editor.deleteBackward(nil)
precondition(committedText.isEmpty && editor.showsPlaceholder)
print("PASS native translator input: IME composition hides placeholder, commit publishes, deletion restores placeholder")

// Hiding a model affects the translation picker, but must not break an existing binding.
var hiddenModel = AIConnection(name: "Hidden selected", endpoint: "http://127.0.0.1:12345/v1", model: "hidden")
hiddenModel.hiddenFromPicker = true
var anotherHidden = hiddenModel
anotherHidden.id = UUID()
anotherHidden.model = "other-hidden"
precondition(ai.save(hiddenModel) && ai.save(anotherHidden))
controller.preferences.modelID = nil
precondition(!controller.modelCatalog.groups.flatMap(\.models).contains { $0.id == hiddenModel.id })
controller.preferences.modelID = hiddenModel.id
let visibleChoices = controller.modelCatalog.groups.flatMap(\.models).map(\.id)
precondition(visibleChoices.contains(hiddenModel.id) && !visibleChoices.contains(anotherHidden.id))
print("PASS translator model catalog hides excluded models and retains only the selected hidden model")

// The dispatch check must survive the earlier validation and the launcher being hidden.
controller.preferences.provider = .google
TranslatorFixtureProtocol.mode = "normal"
var capturedReplacement: TranslationReplacement?
var selectionIsCurrent = true
var dispatchChecks = 0
controller.replaceWithResult = { capturedReplacement = $0 }
let replacement = TranslationReplacement(target: .current, canStart: { true }, canDispatch: {
    dispatchChecks += 1
    return selectionIsCurrent
})
controller.begin(text: "replace selected text", replacement: replacement)
wait("automatic replacement carries dispatch-time validation", until: { capturedReplacement != nil })
precondition(dispatchChecks == 0 && capturedReplacement?.target === replacement.target)
controller.stop()
selectionIsCurrent = false
precondition(capturedReplacement?.canDispatch() == false && dispatchChecks == 1)
capturedReplacement = nil
controller.begin(text: "selection changed before copy", replacement: .init(target: .current, canStart: { false }, canDispatch: { true }))
wait("automatic replacement rejects a changed selection before dispatch", until: { !controller.loading })
precondition(capturedReplacement == nil && controller.error.contains("已更改"))
controller.stop()

let originalElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
let otherElement = AXUIElementCreateSystemWide()
let originalRange = CFRange(location: 2, length: 4)
let originalSelection = TranslationSelection(element: originalElement, range: originalRange, text: "same")
precondition(originalSelection.matches(element: originalElement, range: originalRange, text: "same"))
precondition(!originalSelection.matches(element: otherElement, range: originalRange, text: "same"))
precondition(!originalSelection.matches(element: originalElement, range: CFRange(location: 3, length: 4), text: "same"))
precondition(!originalSelection.matches(element: originalElement, range: CFRange(location: 2, length: 0), text: "same"))
precondition(!originalSelection.matches(element: originalElement, range: originalRange, text: "changed"))
print("PASS automatic replacement rejects a different field, selected range, caret or selected text")
