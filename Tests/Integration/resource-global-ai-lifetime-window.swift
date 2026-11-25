import AppKit
import Combine
import Foundation
import SwiftUI
import KeylaneCore
@testable import Keylane

@MainActor private final class GlobalFixture: ObservableObject {
    let configuration: AIConfiguration
    let interaction: AIInteractionPreferences
    let session: AIConversationSession
    let file: URL
    @Published var showsContext = false
    var pause = false
    var pending: CheckedContinuation<Void, Never>?
    init(preferences: UserDefaults, file: URL) throws {
        self.file = file
        let connection = AIConnection(endpoint: "https://synthetic.invalid/v1", model: "synthetic", mode: .complete)
        preferences.set(try JSONEncoder().encode(AIConfiguration.State(enabled: true, connections: [connection], selectedID: connection.id)), forKey: "aiConnections.v1")
        configuration = AIConfiguration(preferences: preferences)
        interaction = AIInteractionPreferences(preferences: preferences)
        // Independent chat deliberately skips default connection observation.
        session = AIConversationSession(configuration: configuration, runtime: AIRuntime(), observesDefaultConnection: false,
            readKey: { _ in fatalError("Never read credentials or call a provider") })
        session.composer.text = "保留未发送草稿"
    }
    var context: AIContextRegistration {
        .init(id: "synthetic", title: "合成上下文选择器", symbol: "doc.text", search: { [weak self] _ in
            [.init(id: "record", title: "选择合成上下文", detail: "测试资料", source: .init(moduleID: .init(rawValue: "fixture"), load: {
                if self?.pause == true { await withCheckedContinuation { self?.pending = $0 } }
                return .init(sourceID: "record", title: "合成上下文", text: "接受后固定的上下文快照")
            }, isCurrent: { _ in true }))]
        })
    }
}
private struct GlobalFixtureView: View {
    @ObservedObject var state: GlobalFixture
    @ObservedObject var configuration: AIConfiguration
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("全局 AI", isOn: Binding(get: { configuration.state.enabled }, set: configuration.setEnabled))
            Button("选择合成文件") { state.session.composer.attachFiles([state.file]) }
            Button("打开上下文选择器") { state.showsContext = true }
            AIConversationComposerView(controller: state.session, configuration: configuration,
                interaction: state.interaction, composer: state.session.composer, canSubmit: false,
                submit: { fatalError("Never send") }, newChat: {}, chooseModel: { _ in }, showUsage: {}, openAISettings: {})
            if state.showsContext {
                AIChatContextSheet(source: state.context, prepareReader: state.session.composer.prepareResourceReader) { attachment, reader in
                    _ = state.session.composer.appendResourceAttachment(attachment, reader: reader, for: state.session.composer.draftID)
                    state.showsContext = false
                }
            }
        }.padding(20)
    }
}
@MainActor private final class Preview: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var host: NSHostingView<GlobalFixtureView>!
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); NSApp.terminate(nil) }
            catch { fputs("Global AI lifetime UI failed: \(error)\n", stderr); exit(1) }
        }
    }
    func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { throw NSError(domain: label, code: 1) }
    }
    func elements() -> [AnyObject] {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject, depth: Int) -> [AnyObject] {
            guard depth < 30, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            return [object] + (object.accessibilityChildren?() ?? []).flatMap { visit($0 as AnyObject, depth: depth + 1) }
        }
        return visit(host, depth: 0)
    }
    func click(_ title: String) throws {
        guard elements().filter({ ($0.accessibilityLabel?() ?? "").contains(title) }).contains(where: { $0.accessibilityPerformPress?() == true }) else {
            throw NSError(domain: "Missing actionable button: " + title, code: 2)
        }
    }
    func capture(_ name: String) throws {
        let output = ProcessInfo.processInfo.environment["KEYLANE_AI_UI_EVIDENCE"]!
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output + "/" + name + ".png"]
        try capture.run(); capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw NSError(domain: "Own-window capture", code: 3) }
    }
    func run() async throws {
        let suite = "org.keylane.global-ai-lifetime." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("keylane-global-ui-" + UUID().uuidString + ".txt")
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file); window?.close() }
        try Data("已接受的合成文件快照".utf8).write(to: file)
        let state = try GlobalFixture(preferences: prefs, file: file)
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 850), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Keylane · 全局 AI 附件撤权验证"
        host = NSHostingView(rootView: GlobalFixtureView(state: state, configuration: state.configuration)); window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(300))
        let composer = state.session.composer
        try click("选择合成文件")
        try await wait("attachFiles callback") { composer.attachments.count == 1 && !composer.loadingFiles }
        try click("打开上下文选择器")
        try await wait("Context candidate visible") { self.elements().contains { ($0.accessibilityLabel?() ?? "").contains("选择合成上下文") } }
        try click("选择合成上下文")
        try await wait("Actual context sheet selection") { composer.attachments.count == 2 }
        let saved = composer.snapshot, accepted = composer.attachments
        precondition(accepted.allSatisfy(composer.canReread))
        try capture("01-file-and-context")
        try click("全局 AI"); try click("全局 AI")
        precondition(state.configuration.state.enabled && composer.attachments == accepted)
        precondition(accepted.allSatisfy { !composer.canReread($0) })
        composer.restore(saved)
        precondition(accepted.allSatisfy { !composer.canReread($0) })
        try await Task.sleep(for: .milliseconds(80))
        precondition(elements().filter { $0.accessibilityLabel?() == "重新读取" }.isEmpty)
        try capture("02-off-on-fixed-snapshots")
        try click("选择合成文件")
        try await wait("Fresh file selection") { composer.attachments.count == 3 && !composer.loadingFiles }
        precondition(composer.canReread(composer.attachments[2]))
        state.pause = true
        try click("打开上下文选择器")
        try await wait("Context row again") { self.elements().contains { ($0.accessibilityLabel?() ?? "").contains("选择合成上下文") } }
        try click("选择合成上下文")
        try await wait("Context read in flight") { state.pending != nil }
        try click("全局 AI"); try click("全局 AI")
        state.pending?.resume(); state.pending = nil
        try await Task.sleep(for: .milliseconds(100))
        precondition(composer.attachments.count == 3 && composer.attachments.prefix(2) == accepted[...])
        state.showsContext = false; state.pause = false
        try click("打开上下文选择器")
        try await wait("Fresh context row") { self.elements().contains { ($0.accessibilityLabel?() ?? "").contains("选择合成上下文") } }
        try click("选择合成上下文")
        try await wait("Fresh context selected") { composer.attachments.count == 4 }
        precondition(composer.canReread(composer.attachments[3]))
        state.pause = true
        try click("重新读取")
        try await wait("Context refresh in flight") { state.pending != nil }
        let before = composer.attachments
        try click("全局 AI"); try click("全局 AI")
        state.pending?.resume(); state.pending = nil
        try await Task.sleep(for: .milliseconds(100))
        precondition(composer.attachments == before && !composer.loadingFiles && composer.text == "保留未发送草稿")
        precondition(before.allSatisfy { !composer.canReread($0) })
        try capture("03-pending-revoked")
        print("PASS global AI production UI: independent AIConversationSession observesDefaultConnection=false; actual attachFiles callback, actual AIChatContextSheet row, actual Composer refresh, global AIConfiguration Toggle; snapshots/draft/copies retained, old readers dead, fresh selection allowed, pending selection and refresh rejected. Synthetic only; no successful OS file-panel selection or installed app/settings integration tested.")
    }
}
@_cdecl("KeylaneModuleAIFixtureMain")
@MainActor public func globalReaderFixtureMain() -> Int32 {
    let app = NSApplication.shared, fixture = Preview()
    app.setActivationPolicy(.regular); app.delegate = fixture
    withExtendedLifetime(fixture) { app.run() }; return 0
}
