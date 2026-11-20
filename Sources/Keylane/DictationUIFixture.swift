#if DEBUG
import AppKit
import KeylaneCore
import SwiftUI

/// Renders only synthetic dictation data, before constructing the app's real Model or services.
enum DictationUIFixture {
    static func run() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/keylane-dictation-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let domain = "org.keylane.dictation-fixture." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let settings = DictationSettings(defaults: preferences)
        settings.options.vocabulary = ["Keylane", "SwiftUI", "项目验收"]
        settings.options.instructions = "保留中英混排。产品名写为 Keylane，按自然段落整理，不改变原意。"
        let configuration = AIConfiguration(preferences: preferences)
        let speech = AIConnection(name: "云端语音转写", endpoint: "https://speech.fixture.test/v1", model: "gpt-transcribe")
        _ = configuration.save(speech, selectAsDefault: false)
        configuration.setEnabled(true)
        settings.options.transcriptionModelID = speech.id
        try render(AnyView(SettingsPageSections {
            DictationTranscriptionPreferences(settings: settings, configuration: configuration, manageModels: {})
        }), name: "shared-models", directory: directory)
        let draft = DictationStyleDraft()
        draft.prepare(.init(name: "工作邮件", symbol: "envelope", prompt: "整理为简洁清楚的邮件，保留原语言，按段落排版，不补充未提到的信息。", applications: ["com.apple.mail"], websites: ["mail.google.com"]))
        try render(AnyView(DictationPersonalization(settings: settings)), name: "personalization", directory: directory)
        try render(AnyView(DictationStyleEditor(draft: draft)), name: "style-editor", directory: directory)
        let controller = DictationController(configuration: AIConfiguration(preferences: preferences), runtime: AIRuntime(),
                                              settings: settings, directory: directory.appendingPathComponent("history"))
        let record = DictationRecord(duration: 12, rawText: "明天我们讨论一下 Keylane 的听写功能，然后确认验收步骤。", text: "明天讨论 Keylane 的听写功能，并确认验收步骤。", application: "邮件", styleName: "工作邮件")
        var ready = false
        let observation = controller.$records.sink { if !$0.isEmpty { ready = true } }
        Task { @MainActor in
            do { try await controller.history.save(record, retainRecording: false); controller.loadHistory() }
            catch { ready = true }
        }
        let deadline = Date().addingTimeInterval(5)
        while !ready && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        observation.cancel()
        guard ready, !controller.records.isEmpty else { throw AITranscriptionError.invalidResponse }
        try render(AnyView(DictationHistoryView(controller: controller)), name: "history", directory: directory)
        print("Dictation UI fixtures rendered: \(directory.path). No recording or real app data was used.")
    }

    private static func render(_ content: AnyView, name: String, directory: URL) throws {
        let view = NSHostingView(rootView: content.frame(width: 1060, height: 720)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1060, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 1060, height: 720)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AITranscriptionError.invalidResponse }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AITranscriptionError.invalidResponse }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        window.contentView = nil; window.close()
    }
}
#endif
