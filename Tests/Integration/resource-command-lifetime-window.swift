import AppKit
import Combine
import Foundation
import SwiftUI
import KeylaneCore
@testable import Keylane

@MainActor private final class AttachmentFixture: ObservableObject {
    @Published var disabledCommands: Set<String> = []
    let enabled = CurrentValueSubject<Bool, Never>(true)
    let session: AIConversationSession
    let configuration: AIConfiguration
    let interaction: AIInteractionPreferences
    var registry: LauncherModuleRegistry!
    var snippet = Snippet(id: "synthetic-snippet", title: "合成文字片段", text: "已接受的固定快照")
    var reads = 0
    var pause = false
    var pending: CheckedContinuation<Void, Never>?
    private(set) var admitted = 0
    var commandEnabled: Bool { !disabledCommands.contains(SnippetAIActions.attachID.rawValue) }
    init(preferences: UserDefaults) throws {
        let connection = AIConnection(endpoint: "https://synthetic.invalid/v1", model: "synthetic", mode: .complete)
        preferences.set(try JSONEncoder().encode(AIConfiguration.State(enabled: true, connections: [connection], selectedID: connection.id)), forKey: "aiConnections.v1")
        configuration = AIConfiguration(preferences: preferences)
        interaction = AIInteractionPreferences(preferences: preferences)
        session = AIConversationSession(configuration: configuration, runtime: AIRuntime(), readKey: { _ in
            fatalError("Attachment preview cannot read credentials or contact a model")
        })
        let command = LauncherModule.Command(declaration: .init(id: SnippetAIActions.attachID, title: "附加文字片段到 AI 聊天", detail: "", symbol: "sparkles", keywords: []),
            available: { [weak self] in self?.commandEnabled == true }, isAICommand: true,
            aiExecute: { [weak self] _, source in
                guard let self, let source else { return }
                if AIModule.attachResourceContext(to: self.session.composer, source: source,
                    commandID: SnippetAIActions.attachID, registry: self.registry,
                    disabledCommands: self.$disabledCommands.eraseToAnyPublisher(), enabled: self.enabled.eraseToAnyPublisher(),
                    available: { [weak self] in self?.commandEnabled == true && self?.enabled.value == true }) {
                    self.admitted += 1
                }
            })
        registry = try LauncherModuleRegistry(modules: [.init(id: SnippetAIActions.moduleID, commands: [command])], preferences: preferences)
        session.composer.text = "保留这段未发送的草稿"
    }
    func attachViaCommand() {
        let original = SnippetAIContextSource.make(id: snippet.id, read: { [weak self] in
            self?.reads += 1; return self?.snippet
        })
        let source = AIActionSource(moduleID: original.moduleID, load: { [weak self] in
            guard let self else { throw AIActionError.unavailable }
            if self.pause { await withCheckedContinuation { self.pending = $0 } }
            try Task.checkCancellation()
            return try await original.load()
        }, isCurrent: original.isCurrent)
        precondition(registry.invoke(SnippetAIActions.attachID, origin: .menu, aiSource: source, navigate: { _ in }))
    }
    func toggle(_ enabled: Bool) {
        if enabled { disabledCommands.remove(SnippetAIActions.attachID.rawValue) }
        else { disabledCommands.insert(SnippetAIActions.attachID.rawValue) }
    }
}

private struct AttachmentFixtureView: View {
    @ObservedObject var state: AttachmentFixture
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("文字片段附加命令 · 独立合成预览").font(.headline)
            Toggle("启用附加命令", isOn: Binding(get: { state.commandEnabled }, set: state.toggle))
            Button("附加所选文字片段到聊天", action: state.attachViaCommand).buttonStyle(.bordered)
            AIConversationComposerView(controller: state.session, configuration: state.configuration,
                interaction: state.interaction, composer: state.session.composer, canSubmit: false,
                submit: { fatalError("Preview never sends a model request") }, newChat: {}, chooseModel: { _ in }, showUsage: {}, openAISettings: {})
        }.padding(24)
    }
}

@MainActor private final class Preview: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var host: NSHostingView<AttachmentFixtureView>!
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); NSApp.terminate(nil) }
            catch { fputs("Reader lifetime UI fixture failed: \(error)\n", stderr); exit(1) }
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
        guard elements().filter({ $0.accessibilityLabel?() == title }).contains(where: { $0.accessibilityPerformPress?() == true }) else {
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
        let suite = "org.keylane.reader-lifetime." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); window?.close() }
        let state = try AttachmentFixture(preferences: prefs)
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Keylane · 旧附件读取撤销验证"
        window.appearance = NSAppearance(named: .darkAqua)
        host = NSHostingView(rootView: AttachmentFixtureView(state: state)); window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(300))
        try click("附加所选文字片段到聊天")
        try await wait("Production attach route") { state.session.composer.attachments.count == 1 && !state.session.composer.loadingFiles }
        let composer = state.session.composer, first = composer.attachments[0]
        let reads = state.reads
        precondition(composer.canReread(first) && state.admitted == 1)
        try capture("01-attached")
        try click("启用附加命令"); try click("启用附加命令")
        try await Task.sleep(for: .milliseconds(100))
        precondition(state.commandEnabled && !composer.canReread(first) && composer.attachments == [first])
        precondition(elements().filter { $0.accessibilityLabel?() == "重新读取" }.isEmpty)
        composer.rereadAttachment(first.id)
        precondition(state.reads == reads && !composer.loadingFiles)
        try capture("02-off-on-old-snapshot-only")
        state.snippet.text = "明确重新选择后的新快照"
        try click("附加所选文字片段到聊天")
        try await wait("Fresh explicit selection") { composer.attachments.count == 2 && !composer.loadingFiles }
        let fresh = composer.attachments[1]
        precondition(composer.canReread(fresh) && !composer.canReread(first) && state.admitted == 2)
        state.snippet.text = "用户显式重新读取后的版本"
        try click("重新读取")
        try await wait("Actual refresh button") { !composer.loadingFiles && composer.attachments[1].text == state.snippet.text }
        precondition(composer.attachments[0] == first && composer.text == "保留这段未发送的草稿")
        try capture("03-fresh-selection-reread")
        let accepted = composer.attachments
        state.pause = true; state.snippet.text = "撤权后不能覆盖快照"
        try click("重新读取")
        try await wait("Pending resource read") { state.pending != nil }
        try click("启用附加命令"); try click("启用附加命令")
        precondition(!composer.loadingFiles)
        state.pending?.resume(); state.pending = nil
        try await Task.sleep(for: .milliseconds(100))
        precondition(composer.attachments == accepted && !composer.canReread(accepted[1]))
        precondition(composer.text == "保留这段未发送的草稿")
        try capture("04-revoked-during-reread")
        print("PASS P1 production route/UI: snippet-ai-chat registry admission -> AIModule attachment route -> actual composer refresh; off/on permanently removes old reader, copied data survives, explicit new selection/refresh works, pending revocation never replaces accepted snapshots; zero model or user-data access")
    }
}

@_cdecl("KeylaneModuleAIFixtureMain")
@MainActor public func retainedReaderFixtureMain() -> Int32 {
    let app = NSApplication.shared, fixture = Preview()
    app.setActivationPolicy(.regular); app.delegate = fixture
    withExtendedLifetime(fixture) { app.run() }; return 0
}
