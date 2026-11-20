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
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "这是合成验证结果。所选内容已通过公共 AI 动作会话处理；没有修改原记录。"]]], "usage": ["total_tokens": 12]])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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
                let session = AIActionSession(configuration: config, runtime: runtime, readKey: { _ in nil })
                for (index, definition) in ClipboardAIActions.definitions.enumerated() {
                    let source = AIActionSource(moduleID: .init(rawValue: "keylane.clipboard"),
                        load: { .init(sourceID: "fixture", title: "合成剪贴板记录", text: "Keylane brings your commands together. This is sample text for the shared AI action UI.") }, isCurrent: { _ in true })
                    session.prepare(definition, source: source, allowed: { true })
                    try await wait { session.canSend }; session.send()
                    try await wait { !session.running && !session.preparing }
                    guard !session.answer.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    try await display(AnyView(LauncherCreationForm(back: {}, spacing: 16) {
                        Text(definition.title).font(.headline)
                    } fields: { AIActionForm(session: session).padding(.horizontal, 26) }), name: index == 0 ? "clipboard-summary" : "clipboard-translation")
                }
                let files = FileAIController(settings: config, runtime: runtime, preferences: prefs, readKey: { _ in nil })
                files.setFiles([URL(fileURLWithPath: "/synthetic/示例会议记录.txt")]); files.question = "请概括这个文件的内容。"
                files.send(); try await wait { !files.running }
                guard !files.answer.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try await display(AnyView(FileAIView(controller: files)), name: "file-question")
                print("PASS three production module AI windows, synthetic transport only, metadata-only files, no real clipboard or user history")
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
