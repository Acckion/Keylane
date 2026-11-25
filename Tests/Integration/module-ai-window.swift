import AppKit
import Foundation
import SwiftUI
import KeylaneCore
@testable import Keylane

private final class ModelFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        var content = "这是合成验证结果。所选内容已通过公共 AI 动作会话处理；没有修改原记录。"
        var input = request.httpBody ?? Data()
        if input.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; input.append(contentsOf: buffer.prefix(count)) }
        }
        if String(decoding: input, as: UTF8.self).contains("JSON array") { content = "[\"😄\",\"❤️\"]" }
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]], "usage": ["total_tokens": 12]])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class DeferredAINavigationState: ObservableObject {
    @Published var pageID = PageID(rawValue: "quick-ai")
    var presentation = LauncherPagePresentation()
    var callbacks = 0
    let session: AIConversationSession
    init(session: AIConversationSession) {
        self.session = session
        _ = presentation.update(page: pageID, visible: true)
    }
    func changed() {
        callbacks += 1
        let change = presentation.update(page: pageID, visible: true)
        if change.deactivation == PageID(rawValue: "quick-ai") { session.leaveLauncher() }
    }
}

private struct DeferredAINavigationView: View {
    @ObservedObject var state: DeferredAINavigationState
    var body: some View {
        Text("隔离的页面生命周期验证").onChange(of: state.pageID) { _, _ in state.changed() }
    }
}

@MainActor private final class ModuleAIWindowFixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let suite = "org.keylane.tests.module-ai-window." + UUID().uuidString
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleIdentifier == "org.keylane.tests.module-ai-window" else { exit(2) }
        Task { @MainActor in
            do {
                let prefs = UserDefaults(suiteName: suite)!
                prefs.set("http://127.0.0.1:43991/v1", forKey: "fileAIEndpoint"); prefs.set("fixture", forKey: "fileAIModel")
                let config = AIConfiguration(preferences: prefs)
                let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [ModelFixtureProtocol.self]
                let runtime = AIRuntime(configuration: transport)
                let conversation = AIConversationSession(configuration: config, runtime: runtime, readKey: { _ in nil })
                conversation.composer.text = "Existing unsent draft"
                conversation.composer.attachments = [.init(title: "Existing", text: "Synthetic attachment", symbol: "doc")]
                let draftID = conversation.composer.draftID
                let navigation = DeferredAINavigationState(session: conversation)
                try await display(AnyView(DeferredAINavigationView(state: navigation)), name: "deferred-ai-navigation")
                let turnsBeforeNavigation = conversation.turns.count
                let admitted = conversation.navigatePreservingLauncherConversation(currentPage: { navigation.pageID }, changes: navigation.$pageID.eraseToAnyPublisher()) {
                    navigation.pageID = .init(rawValue: "module-ai-action"); return true
                }
                precondition(admitted && navigation.callbacks == 0)
                try await wait { navigation.callbacks == 1 }
                precondition(conversation.composer.text == "Existing unsent draft" && conversation.composer.attachments.count == 1)
                precondition(conversation.composer.draftID == draftID && conversation.turns.count == turnsBeforeNavigation)
                navigation.pageID = .init(rawValue: "quick-ai")
                try await wait { navigation.callbacks == 2 }
                navigation.pageID = .root
                try await wait { navigation.callbacks == 3 }
                precondition(conversation.composer.text.isEmpty && conversation.composer.attachments.isEmpty)
                print("PASS PR212 native SwiftUI onChange: asynchronous page leave retains the draft once, normal later departure clears it")
                let session = AIActionSession(configuration: config, runtime: runtime, readKey: { _ in nil })
                for definition in ClipboardAIActions.definitions + ScreenshotAIActions.definitions + SnippetAIActions.definitions + AppleNotesAIActions.definitions + [EmojiAIActions.definition] {
                    let source = AIActionSource(moduleID: .init(rawValue: "keylane.clipboard"),
                        load: {
                            if definition.acceptsQuestion { try await Task.sleep(for: .milliseconds(150)) }
                            return .init(sourceID: "fixture", title: "合成剪贴板记录", text: "Keylane brings your commands together. This is sample text for the shared AI action UI.")
                        }, isCurrent: { _ in true })
                    session.prepare(definition, source: source, resultTransform: definition.commandID == EmojiAIActions.definition.commandID ? { _, result in try EmojiAIActions.output(result, allowed: ["😄", "❤️"]) } : nil, allowed: { true })
                    if definition.acceptsQuestion {
                        try await display(AnyView(LauncherCreationForm(back: {}, spacing: 16) {
                            Text(definition.title).font(.headline)
                        } fields: { AIActionForm(session: session).padding(.horizontal, 26) }), name: "clipboard-question-preview")
                        guard let editor = window?.firstResponder as? NSTextView, editor.isEditable, editor.string.isEmpty else {
                            throw CocoaError(.validationMissingMandatoryProperty)
                        }
                    }
                    try await wait { !session.preparing }
                    if definition.acceptsQuestion { session.question = "这条记录介绍了什么？" }
                    try await wait { session.canSend }; session.send()
                    try await wait { !session.running && !session.preparing }
                    guard !session.answer.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    try await display(AnyView(LauncherCreationForm(back: {}, spacing: 16) {
                        Text(definition.title).font(.headline)
                    } fields: { AIActionForm(session: session).padding(.horizontal, 26) }), name: definition.commandID.rawValue)
                    if definition.acceptsQuestion {
                        guard let editor = window?.firstResponder as? NSTextView, editor.string == session.question else {
                            throw CocoaError(.validationMissingMandatoryProperty)
                        }
                    }
                }
                let files = FileAIController(settings: config, runtime: runtime, preferences: prefs, readKey: { _ in nil })
                files.setFiles([URL(fileURLWithPath: "/synthetic/示例会议记录.txt")]); files.question = "请概括这个文件的内容。"
                files.send(); try await wait { !files.running }
                guard !files.answer.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try await display(AnyView(FileAIView(controller: files)), name: "file-question")
                let context = AIContextRegistration(id: "fixture", title: "合成模块上下文", symbol: "doc") { _ in
                    [.init(id: "fixture", title: "合成文本记录", detail: "选择后才读取正文", source: .init(moduleID: .init(rawValue: "fixture"), load: {
                        .init(sourceID: "fixture", title: "Fixture", text: "Synthetic selected data")
                    }, isCurrent: { _ in true }))]
                }
                try await display(AnyView(AIChatContextSheet(source: context, prepareReader: { $0 }, add: { _, _ in })), name: "module-context-picker")
                try await display(AnyView(AIResultContent(answer: "## 合成结果\n\n- **统一 Markdown**\n- 保留原始数据", status: "合成验证完成", running: false, progress: .init()).padding(26)), name: "shared-text-result")
                let emoji = EmojiSearchController(defaults: prefs)
                try await emoji.loadForAI(); emoji.start()
                emoji.query = "表达开心的心情"
                try emoji.showAIRecommendations("[\"😄\",\"❤️\"]", description: emoji.query)
                try await wait { !emoji.isSearching }
                guard emoji.sections.first?.id == "ai-results" else { throw CocoaError(.fileReadUnknown) }
                try await display(AnyView(EmojiSearchPage(controller: emoji, activate: { _ in })), name: "emoji-ai-grid")
                emoji.releaseCatalog()
                print("PASS sixteen production AI UI cases: twelve module actions, file question, generic context picker, shared text result and validated Emoji grid; synthetic transport only, no real history")
                prefs.removePersistentDomain(forName: suite)
                NSApp.terminate(nil)
            } catch { fputs("Module AI window fixture failed: \(error)\n", stderr); exit(1) }
        }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else { throw CocoaError(.fileReadUnknown) }
    }
    private func display(_ content: AnyView, name: String) async throws {
        window?.close()
        let panel = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.title = "Keylane AI · 隔离验证"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: content); panel.center(); panel.makeKeyAndOrderFront(nil)
        window = panel; NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(500))
        guard let output = ProcessInfo.processInfo.environment["KEYLANE_AI_UI_EVIDENCE"] else { throw CocoaError(.fileNoSuchFile) }
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), output + "/" + name + ".png"]
        try capture.run(); capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

@_cdecl("KeylaneModuleAIFixtureMain")
@MainActor public func moduleAIFixtureMain() -> Int32 {
    let app = NSApplication.shared
    let fixture = ModuleAIWindowFixture()
    app.setActivationPolicy(.regular); app.delegate = fixture
    withExtendedLifetime(fixture) { app.run() }
    return 0
}
