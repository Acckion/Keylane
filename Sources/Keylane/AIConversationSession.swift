import KeylaneCore
import Combine
import Foundation

final class AIConversationSession: ObservableObject {
    typealias Turn = AIConversationTurn

    @Published private(set) var turns: [Turn] = []
    let composer = AIConversationComposer()
    let toolApproval = AIToolApprovalBroker()
    private var toolSource: @MainActor () -> [AIToolRegistration] = { [] }
    private var toolEnabled: () -> Bool = { false }
    private var toolChanges: AnyCancellable?
    @MainActor var availableTools: [AIToolDefinition] { toolSource().map(\.definition) }

    func configureTools(preferences: AIInteractionPreferences, source: @escaping @MainActor () -> [AIToolRegistration]) {
        toolSource = source
        toolEnabled = { [weak preferences] in preferences?.toolsEnabled == true }
        toolChanges = preferences.$toolsEnabled.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.stop() }
        }
    }
    @Published var textScale: Double = 1
    @Published private(set) var quickModelIsAutomatic = true
    let revealMessage = PassthroughSubject<UUID, Never>()
    private var revealedMessage: UUID?
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var projects: [AIChatProject] = []
    @Published private(set) var currentProjectID: UUID?
    @Published private(set) var projectError = ""
    var currentProject: AIChatProject? { projects.first { $0.id == currentProjectID } }
    var effectiveInstructions: String? {
        let parts = [currentProject?.instructions ?? "", chatInstructions].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
    @Published private(set) var chats: [AIChatSummary] = []
    @Published private(set) var chatID: UUID?
    @Published private(set) var loadingChat = false
    @Published private(set) var historyError = ""
    @Published private(set) var chatTitle = ""
    @Published var chatInstructions = "" {
        didSet { if chatInstructions != oldValue && !restoringChat { scheduleChatSave() } }
    }
    /// Emitted after successfully restoring history, independently of first-send ID allocation.
    let historyOpened = PassthroughSubject<UUID, Never>()
    /// A controller reset invalidates the whole draft, including asynchronous context work.
    let chatReset = PassthroughSubject<Void, Never>()
    private var historyRevision = UUID()
    @Published private var conversationModel: AIChatRecord.ModelReference?
    private var restoringChat = false
    private let history: AIConversationRepository?
    private let configuration: AIConfiguration
    private let runtime: AIRuntime
    private let preferredQuickModel: (() -> UUID?)?
    private let readKey: @Sendable (AIConnection) throws -> String?
    private var configurationChanges: AnyCancellable?
    private var task: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?
    private var activeID: UUID?
    enum Presentation { case quick, chat }
    @Published private(set) var presentation = Presentation.quick
    var isInChat: Bool { presentation == .chat }

    init(configuration: AIConfiguration, runtime: AIRuntime, history: AIConversationRepository? = nil,
         observesDefaultConnection: Bool = true, preferredQuickModel: (() -> UUID?)? = nil,
         readKey: @escaping @Sendable (AIConnection) throws -> String? = { try AIConfiguration.key(for: $0) }) {
        self.configuration = configuration
        self.runtime = runtime
        self.history = history
        self.readKey = readKey
        self.preferredQuickModel = preferredQuickModel
        refreshProjects()
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

    enum ViewScope { case sidebar, conversation, settings }

    func viewUpdates(_ scope: ViewScope) -> [AnyPublisher<Void, Never>] {
        func changes<P: Publisher>(_ source: P) -> AnyPublisher<Void, Never> where P.Output: Equatable, P.Failure == Never {
            source.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        switch scope {
        case .conversation: return [objectWillChange.eraseToAnyPublisher()]
        case .sidebar:
            return [changes($chats), changes($projects), changes($chatID), changes($currentProjectID), changes($historyError), changes($loadingChat)]
        case .settings:
            return [changes($conversationModel), changes($chatTitle), changes($chatInstructions), changes($projects),
                    changes($currentProjectID), changes($loadingChat), changes($running)]
        }
    }

    var canSendDraft: Bool {
        !running && !loadingChat && !composer.loadingFiles && matchesCurrentModel && currentConnection != nil &&
        (!composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composer.attachments.isEmpty)
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
    func submit(_ input: String, instructions: String? = nil, connection override: AIConnection? = nil, attachments suppliedAttachments: [AIConversationAttachment]? = nil) -> Bool {
        guard !running, !loadingChat, !composer.loadingFiles, configuration.state.enabled,
              !isInChat || override == nil,
              let connection = override ?? currentConnection, connection.isConfigured,
              configuration.state.connections.contains(connection),
              conversationModel == nil || conversationModel == AIChatRecord.ModelReference(connection) else { return false }
        let attachments = suppliedAttachments ?? composer.attachments
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = raw.isEmpty && !attachments.isEmpty ? "请分析所附内容。" : raw
        guard !question.isEmpty else { return false }
        let maximumQuestionBytes = 32_000
        let requestText = AIConversationAttachment.requestText(question: question, attachments: attachments)
        guard requestText.utf8.count <= maximumQuestionBytes else {
            status = "问题太长，请缩短后重试。"
            return false
        }

        let system = instructions ?? effectiveInstructions
        guard validateInstructions(system) else { return false }
        let requestMessages = messages(for: requestText, instructions: system)
        let turn = Turn(question: question, attachments: attachments.isEmpty ? nil : attachments, progress: .init())
        composer.clear()
        revealedMessage = nil
        conversationModel = AIChatRecord.ModelReference(connection)
        turns.append(turn)
        if chatTitle.isEmpty {
            chatTitle = String(question.split(whereSeparator: \.isNewline).first?.prefix(72) ?? "")
        }
        activeID = turn.id
        running = true
        status = ""
        saveChat()
        task = Task { @MainActor [weak self, runtime, readKey] in
            do {
                var tools: AIToolRun?
                if let self, self.toolEnabled() {
                    guard connection.supportsTools != false else { throw AIResponseError.toolsUnavailable }
                    tools = try AIToolRun(registrations: self.toolSource(), isCurrent: { [weak self] in
                        guard let self else { return false }
                        return self.activeID == turn.id && self.toolEnabled() && self.configuration.state.enabled &&
                            self.currentConnection == connection
                    }, approve: { [weak self] title, arguments in
                        guard let self else { return false }
                        return await self.toolApproval.request(title: title, arguments: arguments)
                    })
                }
                _ = try await runtime.generate(connection: connection, readKey: readKey, messages: requestMessages, tools: tools, progress: { [weak self] event in
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
            let size = previous.requestText.utf8.count + previous.answer.utf8.count
            guard size <= remaining else { break }
            history.append(AIMessage(role: .assistant, content: previous.answer))
            history.append(AIMessage(role: .user, content: previous.requestText))
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
        presentation = .chat
        refreshProjects()
        if !turns.isEmpty {
            if chatTitle.isEmpty { chatTitle = String(turns[0].question.split(whereSeparator: \.isNewline).first?.prefix(72) ?? "") }
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
        saveChat()
        let revision = UUID()
        historyRevision = revision
        loadingChat = true
        history.perform({ store in (try store.load(id), try store.list(), try store.projects()) }) { [weak self] result in
            guard let self, self.historyRevision == revision else { return }
            self.loadingChat = false
            switch result {
            case .success(let (record?, summaries, projects)):
                self.projects = projects
                self.applyHistory(.success(summaries))
                self.restoringChat = true
                defer { self.restoringChat = false }
                self.currentProjectID = self.chats.first { $0.id == record.id }?.projectID
                self.chatTitle = self.chats.first { $0.id == record.id }?.title ?? ""
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
                self.composer.clear()
                self.revealedMessage = nil
                self.quickModelIsAutomatic = false
                self.chatInstructions = record.content.instructions ?? ""
                self.status = ""
                self.historyError = ""
                self.historyOpened.send(record.id)
            case .success, .failure:
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

    func updateChat(_ id: UUID, change: AIConversationRepository.Change) {
        guard let history else { return }
        if id == chatID, case .rename(let title) = change {
            chatTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        }
        history.perform({ store in try store.update(id, change: change); return try store.list() }) { [weak self] result in
            guard let self else { return }
            self.applyHistory(result)
            // An incoming load may have captured metadata before this edit.
            if case .rename = change, case .success(let rows) = result,
               self.chatID == id, let row = rows.first(where: { $0.id == id }) {
                self.chatTitle = row.title
            }
            // A load queued before the move can restore the source's old group.
            if case .project = change, case .success(let rows) = result,
               self.chatID == id,
               let row = rows.first(where: { $0.id == id }), self.currentProjectID != row.projectID {
                self.currentProjectID = row.projectID
                self.stop()
                self.saveChat()
            }
        }
    }

    func duplicateChat(_ id: UUID) {
        guard let history else { return }
        // Queue the displayed snapshot before the copy, including partial output
        // and instruction edits still inside the save debounce.
        if id == chatID { saveChat() }
        let revision = historyRevision
        history.perform({ try $0.duplicate(id) }) { [weak self] result in
            guard let self, self.historyRevision == revision else { return }
            if case .success(let id?) = result { self.openChat(id) }
            else { self.historyError = "无法创建对话分支。" }
        }
    }

    func transcript(_ id: UUID, completion: @escaping (String?) -> Void) {
        if id == chatID {
            completion(Self.transcript(turns))
            return
        }
        guard let history else { completion(nil); return }
        history.perform({ try $0.load(id) }) { result in
            guard case .success(let record?) = result else { completion(nil); return }
            completion(Self.transcript(record.content.turns))
        }
    }

    private static func transcript(_ turns: [Turn]) -> String {
        turns.map { "## 用户\n\n" + $0.requestText + "\n\n## 助手\n\n" + $0.answer }.joined(separator: "\n\n")
    }

    enum ModelChange { case emptyOnly, forkContinuation }

    @discardableResult
    func chooseModel(_ id: UUID, behavior: ModelChange = .emptyOnly, automatic: Bool = false) -> Bool {
        guard !running, !loadingChat, !composer.loadingFiles, configuration.state.enabled,
              let connection = configuration.state.connections.first(where: { $0.id == id && $0.isConfigured }) else { return false }
        if !turns.isEmpty {
            guard behavior == .forkContinuation, matchesCurrentModel, currentConnection != nil else { return false }
            if currentConnection?.id != id { startBranch(with: turns) }
        }
        conversationModel = AIChatRecord.ModelReference(connection)
        quickModelIsAutomatic = automatic
        saveChat()
        return true
    }

    /// Edits and retries create a new conversation so later messages and the
    /// original answer remain available in history. All forks retain the exact
    /// model/account reference; they cannot bypass unavailable-model checks.
    @discardableResult
    func resubmit(_ turnID: UUID, question: String? = nil, modelID: UUID? = nil) -> Bool {
        guard canRevise, let index = turns.firstIndex(where: { $0.id == turnID }) else { return false }
        let input = (question ?? turns[index].question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 32_000 else { return false }
        let attachments = turns[index].attachments ?? []
        guard AIConversationAttachment.requestText(question: input, attachments: attachments).utf8.count <= 32_000 else { return false }
        guard validateInstructions(effectiveInstructions) else { return false }
        let nextModel: AIConnection?
        if let modelID {
            guard let candidate = configuration.state.connections.first(where: { $0.id == modelID && $0.isConfigured }) else { return false }
            nextModel = candidate
        } else { nextModel = nil }
        let draft = composer.snapshot
        startBranch(with: Array(turns.prefix(index)))
        if let nextModel { conversationModel = AIChatRecord.ModelReference(nextModel) }
        let accepted = submit(input, attachments: attachments)
        composer.restore(draft)
        return accepted
    }

    @discardableResult
    func branch(after turnID: UUID) -> Bool {
        guard canRevise, let index = turns.firstIndex(where: { $0.id == turnID }), turns[index].complete else { return false }
        startBranch(with: Array(turns.prefix(index + 1)))
        saveChat()
        return true
    }

    var canRevise: Bool {
        !running && !loadingChat && !composer.loadingFiles && matchesCurrentModel && currentConnection != nil
    }

    func renameCurrentChat(_ title: String) {
        guard !loadingChat else { return }
        chatTitle = String(title.prefix(120))
        scheduleChatSave()
    }

    private func validateInstructions(_ instructions: String?) -> Bool {
        guard (instructions?.utf8.count ?? 0) <= 32_000 else {
            status = "项目与会话指令过长，请缩短后重试。"
            return false
        }
        return true
    }

    private func startBranch(with prefix: [Turn]) {
        saveChat()
        historyRevision = UUID()
        let sourceTitle = chatTitle.isEmpty ? String(turns.first?.question.prefix(72) ?? "") : chatTitle
        chatID = nil
        chatTitle = String((sourceTitle + " · 分支").prefix(120))
        turns = prefix
        status = ""
    }

    func setProject(_ id: UUID?) {
        guard !loadingChat, id == nil || projects.contains(where: { $0.id == id }) else { return }
        if currentProjectID == id { return }
        stop()
        currentProjectID = id
        saveChat()
    }

    func moveChat(_ id: UUID, to projectID: UUID?) {
        guard projectID == nil || projects.contains(where: { $0.id == projectID }) else { return }
        if id == chatID { setProject(projectID) }
        else { updateChat(id, change: .project(projectID)) }
    }

    func saveProject(_ project: AIChatProject, completion: @escaping (Bool) -> Void) {
        guard let history else { completion(false); return }
        history.perform({ store in try store.saveProject(project); return try store.projects() }) { [weak self] result in
            guard let self else { completion(false); return }
            switch result {
            case .success(let projects): self.projects = projects; self.projectError = ""; completion(true)
            case .failure: self.projectError = "无法保存项目。"; completion(false)
            }
        }
    }

    func removeProject(_ id: UUID) {
        guard let history else { return }
        if currentProjectID == id { setProject(nil) }
        history.perform({ store in try store.removeProject(id); return (try store.projects(), try store.list()) }) { [weak self] result in
            guard let self else { return }
            if case .success(let (projects, chats)) = result {
                self.projects = projects
                self.chats = chats
                self.projectError = ""
                // A queued open may have restored the removed group after the
                // initial check. Reconcile before stopping/saving any response.
                if self.currentProjectID == id {
                    self.currentProjectID = nil
                    self.stop()
                    self.saveChat()
                }
            } else { self.projectError = "无法移除项目。" }
        }
    }

    private func refreshProjects() {
        history?.perform({ try $0.projects() }) { [weak self] result in
            guard let self else { return }
            if case .success(let projects) = result { self.projects = projects }
            else { self.projectError = "无法读取项目。" }
        }
    }

    func leaveLauncher() {
        if !isInChat { reset() }
    }

    func closeChat() {
        reset()
        presentation = .quick
        // Catalogs belong to the shared session, not the lifetime of the window.
        historyError = ""
    }

    func reset(projectID: UUID? = nil) {
        stop()
        saveChat()
        historyRevision = UUID()
        loadingChat = false
        chatID = nil
        currentProjectID = projectID.flatMap { id in projects.contains { $0.id == id } ? id : nil }
        conversationModel = nil
        turns = []
        chatTitle = ""
        restoringChat = true
        chatInstructions = ""
        restoringChat = false
        status = ""
        composer.clear()
        revealedMessage = nil
        quickModelIsAutomatic = true
        chatReset.send()
    }

    private func scheduleChatSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) }
            catch { return }
            self?.saveChat()
        }
    }

    private func saveChat() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let history, let conversationModel, !turns.isEmpty else { return }
        let id = chatID ?? UUID()
        chatID = id
        let record = AIChatRecord(id: id, content: .init(model: conversationModel, turns: turns, instructions: chatInstructions.isEmpty ? nil : chatInstructions))
        let title = chatTitle
        let projectID = currentProjectID
        history.perform({ store in
            try store.save(record, title: title, projectID: projectID)
            return try store.list()
        }) { [weak self] result in
            self?.applyHistory(result)
        }
    }

    private func refreshHistory(restoreLatest: Bool) {
        guard let history else { return }
        let revision = historyRevision
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
        toolApproval.cancel()
        activeID = nil
        task = nil
        running = false
    }
}

extension AIConversationSession {
    var conversationTitle: String {
        let title = chats.first(where: { $0.id == chatID })?.title ?? turns.first?.question ?? "新对话"
        return String(title.split(separator: "\n").first.map(String.init)?.prefix(60) ?? "新对话")
    }
    var canRegenerate: Bool { canRevise && !turns.isEmpty }

    @discardableResult
    func regenerate(modelID: UUID? = nil) -> Bool {
        guard canRegenerate, let last = turns.last else { return false }
        return resubmit(last.id, modelID: modelID)
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

}
