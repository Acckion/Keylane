import AppKit
import Combine
import KeylaneCore

final class DictationController: ObservableObject {
    enum Destination { case application, note, ai, field(UUID, (String) -> Void) }
    let settings: DictationSettings
    let configuration: AIConfiguration
    private let runtime: AIRuntime
    let history: DictationHistory
    @Published private(set) var phase = DictationSession.Phase.idle
    @Published private(set) var level = 0.0
    @Published private(set) var elapsed = 0.0
    @Published private(set) var records: [DictationRecord] = []
    @Published private(set) var message = ""
    @Published var selectedID: UUID?
    @Published var forcedStyleID: UUID?
    @Published var historyQuery = ""
    @Published var requestedDeletion: UUID?
    @Published var requestsClearHistory = false
    private var session = DictationSession()
    private var capture: DictationCapture?
    private var task: Task<Void, Never>?
    private var clock: Timer?
    private var startedAt: Date?
    private var finishRequested = false
    private var activeRecord: DictationRecord?
    private var activeOptions = DictationOptions()
    private var activeStyle: DictationStyle?
    private var target: DictationTarget?
    private var destination = Destination.application
    private var audioURL: URL?
    private var subscriptions: Set<AnyCancellable> = []
    private(set) var shortcutsSuspended = false
    private var keyMonitor: DictationKeys?
    private lazy var panel = DictationPanel(controller: self)
    private let audioDucking = DictationAudioDucking()
    var canRun: () -> Bool = { true }
    var canPaste: () -> Bool = { false }
    var previousApplication: () -> NSRunningApplication? = { nil }
    var openSettings: () -> Void = {}
    var hideLauncher: () -> Void = {}
    var deliverNote: (String) -> Void = { _ in }
    var deliverAI: (String, Bool) -> Void = { _, _ in }
    var feedback: (String, ToastStyle) -> Void = { _, _ in }
    var commandShortcutAssigned: () -> Bool = { false }
    var invokeDefaultShortcut: () -> Void = {}

    init(configuration: AIConfiguration, runtime: AIRuntime, settings: DictationSettings = .init(), directory: URL? = nil) {
        self.configuration = configuration; self.runtime = runtime; self.settings = settings
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keylane/Dictation", isDirectory: true)
        history = DictationHistory(directory: root)
    }
    var busy: Bool { phase != .idle && phase != .failed }
    var recording: Bool { phase == .recording || phase == .starting }
    var matches: [DictationRecord] { records.filter {
        historyQuery.isEmpty || ($0.text + $0.rawText + $0.application).localizedCaseInsensitiveContains(historyQuery)
    } }
    var selected: DictationRecord? { records.first { $0.id == selectedID } }
    var statistics: DictationStatistics { .init(records: records) }
    var updates: AnyPublisher<Void, Never> {
        Publishers.MergeMany($records.map { _ in () }.eraseToAnyPublisher(),
                             $selectedID.map { _ in () }.eraseToAnyPublisher(),
                             $phase.map { _ in () }.eraseToAnyPublisher()).eraseToAnyPublisher()
    }
    var statusTitle: String {
        switch phase {
        case .idle: "听写"
        case .starting: "正在打开麦克风…"
        case .recording: "正在聆听"
        case .transcribing: "正在转写…"
        case .formatting: "正在整理文字…"
        case .delivering: "正在插入文字…"
        case .failed: "听写未完成"
        }
    }
    var cleanupConnection: AIConnection? {
        if let id = settings.options.cleanupModelID {
            guard configuration.state.enabled else { return nil }
            return configuration.state.connections.first { $0.id == id && $0.isConfigured }
        }
        return configuration.state.connection(for: .commands)
    }

    func startService() {
        audioDucking.recover()
        settings.permission.startObserving()
        keyMonitor = DictationKeys(controller: self)
        NotificationCenter.default.publisher(for: .init("KeylaneShortcutsSuspended")).sink { [weak self] event in
            guard let self else { return }
            self.shortcutsSuspended = event.userInfo?["suspended"] as? Bool ?? false
            if self.shortcutsSuspended { self.cancel() }
            self.keyMonitor?.configureModifier()
        }.store(in: &subscriptions)
        settings.permission.settingsUpdates.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self else { return }
            if !self.settings.permission.available { self.cancel() }
            self.keyMonitor?.configureModifier()
        }.store(in: &subscriptions)
        settings.$options.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.keyMonitor?.configureModifier() }
        }.store(in: &subscriptions)
        configuration.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            if !state.enabled, self?.phase == .formatting { self?.cancel() }
        }.store(in: &subscriptions)
        keyMonitor?.configureModifier()
    }
    func stopService() {
        cancel(); keyMonitor?.stop(); keyMonitor = nil
        subscriptions.removeAll(); settings.permission.stopObserving()
    }
    func refreshActivation() {
        if !canRun() { cancel() }
        keyMonitor?.configureModifier()
    }
    func toggle(_ destination: Destination = .application) {
        if recording { finish(); return }
        guard !busy else { return }
        begin(destination)
    }
    func releaseShortcut() { if activeOptions.holdToTalk && recording { finish() } }

    private func begin(_ destination: Destination) {
        guard !shortcutsSuspended else { return }
        guard canRun(), settings.permission.available, settings.options.isConfigured else { openSettings(); return }
        if settings.options.cleanup, cleanupConnection == nil {
            message = "请先配置文字整理模型，或关闭「整理口头表达」后直接使用原始转写。"
            openSettings(); return
        }
        do {
            guard try DictationCredentials.read(settings.options) != nil else { message = DictationError.missingKey.localizedDescription; openSettings(); return }
        } catch { message = error.localizedDescription; openSettings(); return }
        cancel()
        activeOptions = settings.options
        finishRequested = false
        self.destination = destination
        let app = NSWorkspace.shared.frontmostApplication
        let original: NSRunningApplication?
        if case .field = destination { original = .current }
        else { original = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApplication() : app }
        target = original.map { DictationTarget(application: $0, includeContext: activeOptions.appContext) }
        activeStyle = forcedStyleID.flatMap { id in activeOptions.styles.first { $0.id == id } }
            ?? (activeOptions.autoStyling ? DictationStyle.matching(activeOptions.styles, application: original?.bundleIdentifier, website: target?.website) : nil)
        let record = DictationRecord(duration: 0, application: original?.localizedName ?? "", styleName: activeStyle?.name)
        activeRecord = record
        let token = session.begin()
        updatePhase(.starting, token: token)
        message = ""; level = 0; elapsed = 0
        if case .field = destination { /* Keep the composer window and its focus. */ }
        else {
            hideLauncher()
            if let original, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { original.activate() }
        }
        panel.show()
        keyMonitor?.watchSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.session.accepts(token), self.phase == .starting else { return }
            self.fail(Failure("麦克风未能启动，请检查设备连接后重试。"), token: token)
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await history.recordingURL(record.id)
                guard session.accepts(token), !Task.isCancelled else { try? await history.discardRecording(record.id); return }
                audioURL = url
                let capture = DictationCapture()
                self.capture = capture
                capture.start(url: url, preferredDevices: activeOptions.microphoneIDs, started: { [weak self] in
                    guard let self, self.session.accepts(token), self.phase == .starting else { return }
                    self.startedAt = Date()
                    self.updatePhase(.recording, token: token)
                    if self.activeOptions.playSounds { NSSound(named: "Pop")?.play() }
                    if self.activeOptions.lowerAudio { self.audioDucking.lower() }
                    self.clock = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                        guard let self, self.session.accepts(token), let start = self.startedAt else { return }
                        self.elapsed = Date().timeIntervalSince(start)
                        if self.elapsed >= 1200 { self.finish() }
                    }
                    if let clock = self.clock { RunLoop.main.add(clock, forMode: .common) }
                    if self.finishRequested { self.finish() }
                }, meter: { [weak self] level in
                    guard self?.session.accepts(token) == true else { return }
                    self?.level = level
                }, failure: { [weak self] error in self?.fail(error, token: token) })
            } catch { fail(error, token: token) }
        }
    }

    func finish() {
        guard recording else { return }
        finishRequested = true
        guard phase == .recording else { return }
        let token = session.generation
        guard let capture else { cancel(); return }
        activeRecord?.duration = elapsed
        activeStyle = forcedStyleID.flatMap { id in activeOptions.styles.first { $0.id == id } }
            ?? (activeOptions.autoStyling ? DictationStyle.matching(activeOptions.styles, application: target?.application.bundleIdentifier, website: target?.website) : nil)
        activeRecord?.styleName = activeStyle?.name
        clock?.invalidate(); clock = nil
        audioDucking.restore()
        if activeOptions.playSounds { NSSound(named: "Tink")?.play() }
        updatePhase(.transcribing, token: token)
        capture.finish { [weak self] result in
            guard let self, self.session.accepts(token) else { return }
            self.capture = nil
            switch result {
            case .success:
                if let url = self.audioURL { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
                self.process(token: token)
            case .failure(let error): self.fail(error, token: token)
            }
        }
    }

    private func process(token: UUID) {
        let options = activeOptions
        let style = activeStyle
        let context = target?.nearbyText
        let app = activeRecord?.application
        let connection = cleanupConnection
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard var record = activeRecord, let audioURL else { throw DictationError.invalidAudio }
                let raw: String
                if !record.rawText.isEmpty { raw = record.rawText }
                else { raw = try await DictationCloudClient().transcribe(audio: audioURL, options: options) }
                try Task.checkCancellation()
                guard session.accepts(token) else { return }
                record.rawText = raw; record.text = raw; activeRecord = record
                if options.cleanup {
                    guard let connection else { throw Failure("转写已保留。请在 AI 设置中配置文字整理模型，或关闭听写的文字整理。") }
                    guard !["ollama", "lmstudio"].contains(connection.providerID ?? "") else {
                        throw Failure("此版本只使用云端模型，请选择云端文字整理模型。")
                    }
                    updatePhase(.formatting, token: token)
                    let collector = DictationTextCollector()
                    _ = try await runtime.generate(connection: connection, readKey: { try AIConfiguration.key(for: $0) },
                                                   messages: [.init(role: .system, content: DictationText.cleanupPrompt(options: options, style: style, context: context)),
                                                              .init(role: .user, content: try DictationText.cleanupPayload(transcript: raw, application: options.appContext ? app : nil, context: context))], emit: { text in
                        try await collector.append(text)
                    })
                    record.text = await collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !record.text.isEmpty else { throw DictationError.emptyTranscript }
                }
                try Task.checkCancellation()
                guard session.accepts(token), canRun(), settings.permission.available else { return }
                record.error = nil
                try await history.save(record, retainRecording: options.keepRecordings)
                guard session.accepts(token), !Task.isCancelled else { return }
                activeRecord = record
                await reloadHistory()
                guard session.accepts(token), !Task.isCancelled else { return }
                updatePhase(.delivering, token: token)
                deliver(record.text, token: token)
            } catch is CancellationError { }
            catch { fail(error, token: token) }
        }
    }

    private func deliver(_ text: String, token: UUID) {
        switch destination {
        case .note: deliverNote(text); complete(token: token)
        case .ai: deliverAI(text, activeOptions.dictateToChat); complete(token: token)
        case .field(_, let insert): insert(text); complete(token: token)
        case .application:
            guard activeOptions.output != .copy else {
                _ = DictationDelivery.copy(text); feedback("听写已复制到剪贴板", .success); complete(token: token); return
            }
            guard canPaste(), let target else { fallback(text, token: token); return }
            var submission = DictationText.submission(text, options: activeOptions)
            if activeOptions.contextAwarePaste, let position = target.position {
                let original = position.text as NSString
                submission.text = DictationText.contextual(submission.text,
                    before: original.substring(to: position.range.location),
                    after: original.substring(from: position.range.location + position.range.length))
            }
            guard !submission.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { complete(token: token); return }
            DictationDelivery.paste(submission.text, target: target, keepCopy: activeOptions.output == .pasteAndCopy,
                                    submit: submission.submit, shift: activeOptions.submitWithShift,
                                    isCurrent: { [weak self] in self?.session.accepts(token) == true && self?.canRun() == true && self?.canPaste() == true }) { [weak self] pasted in
                guard let self, self.session.accepts(token) else { return }
                if pasted { self.complete(token: token) }
                else { self.fallback(text, token: token) }
            }
        }
    }
    private func fallback(_ text: String, token: UUID) {
        _ = DictationDelivery.copy(text)
        feedback("听写已保存并复制。目标输入框或粘贴权限发生变化，请手动粘贴。", .failure)
        complete(token: token)
    }
    private func complete(token: UUID) {
        guard session.accepts(token) else { return }
        session.cancel(); phase = .idle; panel.close(); keyMonitor?.stopWatchingSession()
        task = nil; target = nil; audioURL = nil; activeRecord = nil; destination = .application
    }
    private func fail(_ error: Error, token: UUID) {
        guard session.accepts(token) else { return }
        clock?.invalidate(); clock = nil
        capture?.cancel(); capture = nil; audioDucking.restore()
        updatePhase(.failed, token: token)
        message = error is AIResponseError ? "文字整理服务未完成。原始转写已保留，可从历史中重试。" : error.localizedDescription
        keyMonitor?.stopWatchingSession()
        if var record = activeRecord {
            record.error = message
            activeRecord = record
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await history.save(record, retainRecording: true); await reloadHistory() }
                catch { if self.session.generation == token { self.message += "\n历史保存失败，请检查本机存储空间。" } }
            }
        }
    }
    func cancel() {
        let id = activeRecord?.id
        let removeAudio = phase != .failed && activeRecord?.error == nil
        session.cancel(); task?.cancel(); task = nil
        capture?.cancel(); capture = nil; clock?.invalidate(); clock = nil
        keyMonitor?.stopWatchingSession(); audioDucking.restore(); panel.close()
        phase = .idle; target = nil; audioURL = nil; activeRecord = nil; destination = .application
        if let id, removeAudio { Task { try? await history.discardRecording(id) } }
    }
    func cancelField(_ id: UUID) { if case .field(let current, _) = destination, current == id { cancel() } }
    func isRecordingField(_ id: UUID) -> Bool { if case .field(let current, _) = destination { return current == id && recording }; return false }
    func retry(_ record: DictationRecord) {
        guard !busy else { return }
        guard canRun(), settings.permission.available else { openSettings(); return }
        cancel()
        // A retry never pastes into a stale application from an earlier session.
        activeOptions = settings.options; activeOptions.output = .copy
        activeRecord = record; activeRecord?.error = nil
        activeStyle = record.styleName.flatMap { name in activeOptions.styles.first { $0.name == name } }
        destination = .application
        let token = session.begin(); updatePhase(.transcribing, token: token); panel.show()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                audioURL = try await history.recordingURL(record.id)
                guard session.accepts(token), !Task.isCancelled else { return }
                process(token: token)
            } catch { fail(error, token: token) }
        }
    }
    func loadHistory() { Task { @MainActor in await reloadHistory() } }
    func loadLastTranscription() {
        Task { @MainActor in
            await reloadHistory()
            if let record = records.first(where: { $0.error == nil && !$0.text.isEmpty }) { use(record, copyOnly: true) }
            else { feedback("还没有可复制的听写。", .neutral) }
        }
    }
    private func reloadHistory() async {
        do {
            records = try await history.list()
            if !matches.contains(where: { $0.id == selectedID }) { selectedID = matches.first?.id }
        } catch { message = "无法读取听写历史，请检查本机存储空间。"; feedback(message, .failure) }
    }
    func remove(_ id: UUID) {
        if activeRecord?.id == id { cancel() }
        Task { @MainActor in
            do { try await history.remove(id); await reloadHistory() }
            catch { feedback("无法删除听写记录。", .failure) }
        }
    }
    func removeAll() {
        cancel()
        Task { @MainActor in
            do { try await history.removeAll(); await reloadHistory() }
            catch { feedback("无法清空听写历史。", .failure) }
        }
    }
    func move(_ delta: Int) {
        let rows = matches
        guard !rows.isEmpty else { selectedID = nil; return }
        let index = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        selectedID = rows[min(rows.count - 1, max(0, index + delta))].id
    }
    func use(_ record: DictationRecord?, copyOnly: Bool) {
        guard let record, !record.text.isEmpty else { return }
        guard copyOnly == false, canPaste(), let app = previousApplication() else {
            _ = DictationDelivery.copy(record.text); feedback("听写已复制到剪贴板", .success); return
        }
        let target = DictationTarget(application: app, includeContext: false)
        hideLauncher(); app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            DictationDelivery.paste(record.text, target: target, keepCopy: false, submit: false, shift: false,
                                    isCurrent: { self.canRun() && self.canPaste() }) { pasted in
                if !pasted { _ = DictationDelivery.copy(record.text); self.feedback("听写已复制，请手动粘贴。", .failure) }
            }
        }
    }
    private func updatePhase(_ next: DictationSession.Phase, token: UUID) {
        if session.transition(next, token: token) { phase = next }
    }
    struct Failure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
}

private actor DictationTextCollector {
    var text = ""
    func append(_ value: String) throws {
        guard text.utf8.count + value.utf8.count <= 1_048_576 else { throw DictationError.responseTooLarge }
        text += value
    }
}
