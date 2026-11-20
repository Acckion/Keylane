import AppKit
import KeylaneCore
import Combine
import Foundation

final class QuickAIController: ObservableObject {
    struct Turn: Identifiable, Codable, Sendable {
        var id = UUID()
        let question: String
        var answer = ""
        var complete = false
        var files: [AIFileAttachment]?
        var progress: AIResponseProgress?
        var requestQuestion: String { AIFileAttachment.prompt(question, files: files ?? []) }
    }

    @Published private(set) var turns: [Turn] = []
    @Published var pendingFiles: [AIFileAttachment] = []
    @Published private(set) var loadingFiles = false
    @Published var fileError = ""
    @Published var textScale: Double = 1
    @Published private(set) var quickModelIsAutomatic = true
    let revealMessage = PassthroughSubject<UUID, Never>()
    private var revealedMessage: UUID?
    private var fileLoadRevision = UUID()
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var chats: [AIChatSummary] = []
    @Published private(set) var chatID: UUID?
    @Published private(set) var loadingChat = false
    @Published private(set) var historyError = ""
    @Published var chatInstructions = "" {
        didSet { if chatInstructions != oldValue && !restoringChat { saveChat() } }
    }
    /// Emitted after successfully restoring history, independently of first-send ID allocation.
    let historyOpened = PassthroughSubject<UUID, Never>()
    private var historyRevision = UUID()
    @Published private var conversationModel: AIChatRecord.ModelReference?
    private var restoringChat = false
    private let history: AIChatHistory?
    private let configuration: AIConfiguration
    private let runtime: AIRuntime
    private let preferredQuickModel: (() -> UUID?)?
    private let readKey: @Sendable (AIConnection) throws -> String?
    private var configurationChanges: AnyCancellable?
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    private let turnLimit = 24
    private(set) var isInChat = false

    init(configuration: AIConfiguration, runtime: AIRuntime, history: AIChatHistory? = nil,
         observesDefaultConnection: Bool = true, preferredQuickModel: (() -> UUID?)? = nil,
         readKey: @escaping @Sendable (AIConnection) throws -> String? = { try AIConfiguration.key(for: $0) }) {
        self.configuration = configuration
        self.runtime = runtime
        self.history = history
        self.readKey = readKey
        self.preferredQuickModel = preferredQuickModel
        refreshHistory(restoreLatest: false)
        guard observesDefaultConnection else { return }
        configurationChanges = configuration.$state.dropFirst()
            .sink { [weak self] next in
                guard let self else { return }
                let current = self.connection(in: self.configuration.state)
                let updated = self.connection(in: next)
                let oldDefault = self.configuration.state.connection(for: .quick)
                let newDefault = next.connection(for: .quick)
                let changedAutomaticDefault = !self.isInChat && self.quickModelIsAutomatic &&
                    (oldDefault.map(AIChatRecord.ModelReference.init) != newDefault.map(AIChatRecord.ModelReference.init)
                     || oldDefault?.mode != newDefault?.mode)
                guard changedAutomaticDefault || current.map(AIChatRecord.ModelReference.init) != updated.map(AIChatRecord.ModelReference.init)
                    || current?.mode != updated?.mode else { return }
                if self.isInChat { self.stop() }
                else { self.reset() }
            }
    }

    var lastAnswer: String? { turns.last(where: { !$0.answer.isEmpty })?.answer }
    var currentConnection: AIConnection? { connection(in: configuration.state) }

    private func connection(in state: AIConfiguration.State) -> AIConnection? {
        guard state.enabled else { return nil }
        if let conversationModel {
            return state.connections.first {
                $0.id == conversationModel.profileID && $0.isConfigured && AIChatRecord.ModelReference($0) == conversationModel
            }
        }
        if !isInChat, let id = preferredQuickModel?(),
           let connection = state.connections.first(where: { $0.id == id && $0.isConfigured }) { return connection }
        return state.connection(for: isInChat ? .chat : .quick)
    }

    var matchesCurrentModel: Bool {
        guard let conversationModel else { return true }
        return currentConnection.map(AIChatRecord.ModelReference.init) == conversationModel
    }

    /// A nonempty entry is a submission, not a composer prefill. Keep it only if rejected.
    func consumeEntry(_ input: String) -> String? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return submit(input) ? "" : input
    }

    @discardableResult
    func submit(_ input: String, instructions: String? = nil, connection override: AIConnection? = nil) -> Bool {
        guard !running, !loadingChat, !loadingFiles, configuration.state.enabled,
              !isInChat || override == nil,
              let connection = override ?? currentConnection, connection.isConfigured,
              configuration.state.connections.contains(connection),
              conversationModel == nil || conversationModel == AIChatRecord.ModelReference(connection) else { return false }
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = raw.isEmpty && !pendingFiles.isEmpty ? "请查看附加文件。" : raw
        guard !question.isEmpty else { return false }
        let maximumQuestionBytes = 32_000
        let requestQuestion = AIFileAttachment.prompt(question, files: pendingFiles)
        guard requestQuestion.utf8.count <= maximumQuestionBytes else {
            status = "问题太长，请缩短后重试。"
            return false
        }

        let requestMessages = messages(for: requestQuestion, instructions: instructions ?? (isInChat && !chatInstructions.isEmpty ? chatInstructions : nil))
        if !isInChat && turns.count >= turnLimit { turns.removeFirst(turns.count - turnLimit + 1) }
        let turn = Turn(question: question, files: pendingFiles.isEmpty ? nil : pendingFiles, progress: .init())
        pendingFiles = []
        fileError = ""
        revealedMessage = nil
        conversationModel = AIChatRecord.ModelReference(connection)
        turns.append(turn)
        activeID = turn.id
        running = true
        status = ""
        saveChat()
        task = Task { @MainActor [weak self, runtime, readKey] in
            do {
                _ = try await runtime.generate(connection: connection, readKey: readKey, messages: requestMessages, progress: { [weak self] event in
                    await MainActor.run { [weak self] in
                        guard let self, self.activeID == turn.id, let index = self.turns.indices.last else { return }
                        self.turns[index].progress?.apply(event)
                    }
                }) { [weak self] delta in
                    try await MainActor.run { [weak self] in
                        guard let self, self.activeID == turn.id, let index = self.turns.indices.last
                        else { throw CancellationError() }
                        self.turns[index].progress?.apply(.writing)
                        self.turns[index].answer += delta
                    }
                }
                guard let self, self.activeID == turn.id, let index = self.turns.indices.last else { return }
                self.turns[index].progress?.apply(.completed)
                self.turns[index].complete = true
                self.finish()
                if self.isInChat { self.configuration.recordChatModel(connection.id) }
                self.saveChat()
            } catch {
                guard let self, self.activeID == turn.id else { return }
                if let index = self.turns.indices.last { self.turns[index].progress?.apply(.failed) }
                self.finish()
                self.saveChat()
                self.status = error.localizedDescription
            }
        }
        return true
    }

    func messages(for question: String, instructions: String? = nil) -> [AIMessage] {
        var history = [AIMessage]()
        var remaining = 64_000 - question.utf8.count
        for previous in turns.reversed() where previous.complete {
            let size = previous.requestQuestion.utf8.count + previous.answer.utf8.count
            guard size <= remaining else { break }
            history.append(AIMessage(role: .assistant, content: previous.answer))
            history.append(AIMessage(role: .user, content: previous.requestQuestion))
            remaining -= size
        }
        var messages = instructions.map { [AIMessage(role: .system, content: $0)] } ?? []
        messages.append(contentsOf: history.reversed())
        messages.append(AIMessage(role: .user, content: question))
        return messages
    }

    func stop() {
        guard running else { return }
        task?.cancel()
        if let index = turns.indices.last { turns[index].progress?.apply(.cancelled) }
        finish()
        status = "已停止。"
        saveChat()
    }

    func beginChat(restoreLatest: Bool = false) {
        guard !isInChat else { return }
        isInChat = true
        if !turns.isEmpty {
            if turns.contains(where: \.complete), let connection = currentConnection {
                configuration.recordChatModel(connection.id)
            }
            saveChat()
        }
        else { refreshHistory(restoreLatest: restoreLatest) }
    }

    func openChat(_ id: UUID) {
        guard let history else { return }
        if chatID == id {
            historyRevision = UUID()
            loadingChat = false
            return
        }
        stop()
        let revision = UUID()
        historyRevision = revision
        loadingChat = true
        history.perform({ try $0.load(id) }) { [weak self] result in
            guard let self, self.historyRevision == revision else { return }
            self.loadingChat = false
            switch result {
            case .success(let record?):
                self.restoringChat = true
                defer { self.restoringChat = false }
                self.chatID = record.id
                self.conversationModel = record.content.model
                self.turns = record.content.turns.map { stored in
                    var turn = stored
                    if var trace = turn.progress, trace.active {
                        trace.apply(turn.complete ? .completed : .cancelled)
                        turn.progress = trace
                    }
                    return turn
                }
                self.pendingFiles = []
                self.fileError = ""
                self.fileLoadRevision = UUID()
                self.loadingFiles = false
                self.revealedMessage = nil
                self.quickModelIsAutomatic = false
                self.chatInstructions = record.content.instructions ?? ""
                self.status = ""
                self.historyError = ""
                self.historyOpened.send(record.id)
            case .success(nil), .failure:
                self.historyError = "无法读取这段对话。"
            }
        }
    }

    func deleteChat(_ id: UUID) {
        guard let history else { return }
        if chatID == id { reset() }
        else if loadingChat {
            historyRevision = UUID()
            loadingChat = false
        }
        history.perform({ store in try store.remove(id); return try store.list() }) { [weak self] result in
            self?.applyHistory(result)
        }
    }

    func updateChat(_ id: UUID, change: AIChatHistory.Change) {
        guard isInChat, let history else { return }
        history.perform({ store in try store.update(id, change: change); return try store.list() }) { [weak self] result in
            self?.applyHistory(result)
        }
    }

    @discardableResult
    func chooseChatModel(_ id: UUID) -> Bool {
        guard isInChat, turns.isEmpty, !loadingChat, configuration.state.enabled,
              let connection = configuration.state.connections.first(where: { $0.id == id && $0.isConfigured }) else { return false }
        conversationModel = AIChatRecord.ModelReference(connection)
        return true
    }

    func leaveLauncher() {
        if !isInChat { reset() }
    }

    func closeChat() {
        reset()
        isInChat = false
        chats = []
        historyError = ""
    }

    func reset() {
        stop()
        historyRevision = UUID()
        loadingChat = false
        chatID = nil
        conversationModel = nil
        turns = []
        pendingFiles = []
        fileError = ""
        fileLoadRevision = UUID()
        loadingFiles = false
        revealedMessage = nil
        quickModelIsAutomatic = true
        chatInstructions = ""
        status = ""
    }

    private func saveChat() {
        guard let history, let conversationModel, !turns.isEmpty else { return }
        let id = chatID ?? UUID()
        chatID = id
        let record = AIChatRecord(id: id, content: .init(model: conversationModel, turns: turns, instructions: chatInstructions.isEmpty ? nil : chatInstructions))
        history.perform({ store in try store.save(record); return try store.list() }) { [weak self] result in
            self?.applyHistory(result)
        }
    }

    private func refreshHistory(restoreLatest: Bool) {
        guard let history else { return }
        let revision = UUID()
        historyRevision = revision
        loadingChat = restoreLatest
        history.perform({ try $0.list() }) { [weak self] result in
            guard let self else { return }
            self.applyHistory(result)
            guard self.historyRevision == revision else { return }
            self.loadingChat = false
            if restoreLatest, let latest = self.chats.first(where: { !$0.archived }) { self.openChat(latest.id) }
        }
    }

    private func applyHistory(_ result: Result<[AIChatSummary], Error>) {
        switch result {
        case .success(let summaries): chats = summaries; historyError = ""
        case .failure: historyError = "无法更新本地对话历史。"
        }
    }

    private func finish() {
        activeID = nil
        task = nil
        running = false
    }
}

extension QuickAIController {
    var conversationTitle: String {
        let title = chats.first(where: { $0.id == chatID })?.title ?? turns.first?.question ?? "新对话"
        return String(title.split(separator: "\n").first.map(String.init)?.prefix(60) ?? "新对话")
    }
    var canRegenerate: Bool { !running && !loadingChat && !loadingFiles && !turns.isEmpty }

    @discardableResult
    func chooseQuickModel(_ id: UUID, automatic: Bool = false) -> Bool {
        guard !running, !loadingChat, !isInChat, configuration.state.enabled,
              let connection = configuration.state.connections.first(where: { $0.id == id && $0.isConfigured }) else { return false }
        guard turns.isEmpty || currentConnection != nil else {
            status = "这段历史的原模型不可用，请先新建对话。"
            return false
        }
        conversationModel = AIChatRecord.ModelReference(connection)
        quickModelIsAutomatic = automatic
        saveChat()
        return true
    }

    @discardableResult
    func regenerate(modelID: UUID? = nil) -> Bool {
        guard canRegenerate, let last = turns.last else { return false }
        let oldModel = conversationModel
        let oldAutomatic = quickModelIsAutomatic
        let oldFiles = pendingFiles
        if let modelID, !chooseQuickModel(modelID) { return false }
        turns.removeLast()
        pendingFiles = last.files ?? []
        if submit(last.question) { pendingFiles = oldFiles; return true }
        turns.append(last)
        pendingFiles = oldFiles
        conversationModel = oldModel
        quickModelIsAutomatic = oldAutomatic
        saveChat()
        return false
    }

    func neighboringChat(_ direction: Int) -> UUID? {
        let ids = chats.filter { !$0.archived }.sorted { $0.updated < $1.updated }.map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let chatID, let index = ids.firstIndex(of: chatID) else { return direction < 0 ? ids.last : nil }
        let next = index + (direction < 0 ? -1 : 1)
        return ids.indices.contains(next) ? ids[next] : nil
    }

    func navigateChat(_ direction: Int) {
        guard !running, let id = neighboringChat(direction) else { return }
        openChat(id)
    }

    func previousMessage() {
        guard !turns.isEmpty else { return }
        let index = revealedMessage.flatMap { id in turns.firstIndex { $0.id == id } } ?? turns.count
        let target = turns[max(0, index - 1)].id
        revealedMessage = target
        revealMessage.send(target)
    }

    func chooseFiles() {
        guard let window = NSApp.keyWindow else { return }
        chooseFiles(in: window)
    }

    func chooseFiles(in window: NSWindow) {
        guard !loadingFiles, !loadingChat, window.attachedSheet == nil else { return }
        let revision = UUID()
        fileLoadRevision = revision
        let panel = NSOpenPanel()
        panel.title = "附加文件"
        panel.message = "支持 UTF-8 文本、代码和有文字的 PDF。文件仅在发送问题时交给所选模型。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // The Launcher's focus/outside-click handlers already retain windows with a sheet.
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, self.fileLoadRevision == revision else { return }
            self.attachFiles(panel.urls)
        }
    }

    func attachFiles(_ urls: [URL]) {
        guard !loadingFiles, !loadingChat else { return }
        guard pendingFiles.count + urls.count <= 5 else { fileError = "每条消息最多附加 5 个文件。"; return }
        let revision = UUID()
        fileLoadRevision = revision
        loadingFiles = true
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try urls.map(AIFileAttachment.read) }
            }.value
            guard let self, self.fileLoadRevision == revision else { return }
            self.loadingFiles = false
            switch result {
            case .success(let files):
                let combined = self.pendingFiles + files
                guard AIFileAttachment.prompt("", files: combined).utf8.count <= 30_000 else {
                    self.fileError = "附件文字总量超过 30,000 字节，请减少附件。"; return
                }
                self.pendingFiles = combined
                self.fileError = ""
            case .failure(let error): self.fileError = error.localizedDescription
            }
        }
    }

    func copyChatData() {
        struct Export: Encodable { let version = 1; let title: String; let turns: [Turn] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Export(title: conversationTitle, turns: turns)),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyDeeplink() {
        guard let chatID else { return }
        let text = AIChatLink.make(chatID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func confirmDelete() {
        guard let chatID else { reset(); return }
        let alert = NSAlert()
        alert.messageText = "删除这段对话？"
        alert.informativeText = "这会移除本机保存的这段对话。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { deleteChat(chatID) }
    }
}
