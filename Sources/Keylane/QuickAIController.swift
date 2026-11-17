import Combine
import Foundation

final class QuickAIController: ObservableObject {
    struct Turn: Identifiable, Codable, Sendable {
        var id = UUID()
        let question: String
        var answer = ""
        var complete = false
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var chats: [AIChatSummary] = []
    @Published private(set) var chatID: UUID?
    @Published private(set) var loadingChat = false
    @Published private(set) var historyError = ""
    private var historyRevision = UUID()
    private var conversationModel: AIChatRecord.ModelReference?
    private let history: AIChatHistory?
    private let configuration: AIConfiguration
    private let runtime: AIRuntime
    private let readKey: @Sendable (AIConnection) throws -> String?
    private var configurationChanges: AnyCancellable?
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    private let turnLimit = 24
    private(set) var isInChat = false

    init(configuration: AIConfiguration, runtime: AIRuntime, history: AIChatHistory? = nil,
         readKey: @escaping @Sendable (AIConnection) throws -> String? = { try AIConfiguration.key(for: $0) }) {
        self.configuration = configuration
        self.runtime = runtime
        self.history = history
        self.readKey = readKey
        configurationChanges = configuration.$state
            .map { $0.enabled ? $0.selected : nil }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                if self.isInChat { self.stop() }
                else { self.reset() }
            }
    }

    var lastAnswer: String? { turns.last(where: { !$0.answer.isEmpty })?.answer }

    var matchesCurrentModel: Bool {
        guard let conversationModel else { return true }
        return configuration.selected.map(AIChatRecord.ModelReference.init) == conversationModel
    }

    @discardableResult
    func submit(_ input: String, instructions: String? = nil) -> Bool {
        guard !running, !loadingChat, matchesCurrentModel, configuration.isAvailable,
              let connection = configuration.selected else { return false }
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return false }
        let maximumQuestionBytes = 32_000
        guard question.utf8.count <= maximumQuestionBytes else {
            status = "问题太长，请缩短后重试。"
            return false
        }

        let requestMessages = messages(for: question, instructions: instructions)
        if !isInChat && turns.count >= turnLimit { turns.removeFirst(turns.count - turnLimit + 1) }
        let turn = Turn(question: question)
        conversationModel = AIChatRecord.ModelReference(connection)
        turns.append(turn)
        activeID = turn.id
        running = true
        status = ""
        saveChat()
        task = Task { @MainActor [weak self, runtime, readKey] in
            do {
                _ = try await runtime.generate(connection: connection, readKey: readKey, messages: requestMessages) { [weak self] delta in
                    try await MainActor.run { [weak self] in
                        guard let self, self.activeID == turn.id, let index = self.turns.indices.last
                        else { throw CancellationError() }
                        self.turns[index].answer += delta
                    }
                }
                guard let self, self.activeID == turn.id, let index = self.turns.indices.last else { return }
                self.turns[index].complete = true
                self.finish()
                self.saveChat()
            } catch {
                guard let self, self.activeID == turn.id else { return }
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
            let size = previous.question.utf8.count + previous.answer.utf8.count
            guard size <= remaining else { break }
            history.append(AIMessage(role: .assistant, content: previous.answer))
            history.append(AIMessage(role: .user, content: previous.question))
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
        finish()
        status = "已停止。"
        saveChat()
    }

    func beginChat(restoreLatest: Bool = false) {
        guard !isInChat else { return }
        isInChat = true
        if !turns.isEmpty { saveChat() }
        else { refreshHistory(restoreLatest: restoreLatest) }
    }

    func openChat(_ id: UUID) {
        guard isInChat, let history else { return }
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
            guard let self, self.isInChat, self.historyRevision == revision else { return }
            self.loadingChat = false
            switch result {
            case .success(let record?):
                self.chatID = record.id
                self.conversationModel = record.content.model
                self.turns = record.content.turns
                self.status = ""
                self.historyError = ""
            case .success(nil), .failure:
                self.historyError = "无法读取这段对话。"
            }
        }
    }

    func deleteChat(_ id: UUID) {
        guard isInChat, let history else { return }
        if chatID == id { reset() }
        else if loadingChat {
            historyRevision = UUID()
            loadingChat = false
        }
        history.perform({ store in try store.remove(id); return try store.list() }) { [weak self] result in
            self?.applyHistory(result)
        }
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
        status = ""
    }

    private func saveChat() {
        guard isInChat, let history, let conversationModel, !turns.isEmpty else { return }
        let id = chatID ?? UUID()
        chatID = id
        let record = AIChatRecord(id: id, content: .init(model: conversationModel, turns: turns))
        history.perform({ store in try store.save(record); return try store.list() }) { [weak self] result in
            self?.applyHistory(result)
        }
    }

    private func refreshHistory(restoreLatest: Bool) {
        guard let history else { return }
        let revision = historyRevision
        loadingChat = restoreLatest
        history.perform({ try $0.list() }) { [weak self] result in
            guard let self, self.isInChat else { return }
            self.applyHistory(result)
            guard self.historyRevision == revision else { return }
            self.loadingChat = false
            if restoreLatest, let latest = self.chats.first { self.openChat(latest.id) }
        }
    }

    private func applyHistory(_ result: Result<[AIChatSummary], Error>) {
        guard isInChat else { return }
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
