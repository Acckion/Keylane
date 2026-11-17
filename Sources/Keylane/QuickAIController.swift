import Combine
import Foundation

final class QuickAIController: ObservableObject {
    struct Turn: Identifiable, Sendable {
        let id = UUID()
        let question: String
        var answer = ""
        var complete = false
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var running = false
    @Published private(set) var status = ""
    private let configuration: AIConfiguration
    private let runtime: AIRuntime
    private let readKey: @Sendable (AIConnection) throws -> String?
    private var configurationChanges: AnyCancellable?
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    private let turnLimit = 24
    private(set) var isInChat = false

    init(configuration: AIConfiguration, runtime: AIRuntime,
         readKey: @escaping @Sendable (AIConnection) throws -> String? = { try AIConfiguration.key(for: $0) }) {
        self.configuration = configuration
        self.runtime = runtime
        self.readKey = readKey
        configurationChanges = configuration.$state
            .map { $0.enabled ? $0.selected : nil }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.reset() }
    }

    var lastAnswer: String? { turns.last(where: { !$0.answer.isEmpty })?.answer }

    @discardableResult
    func submit(_ input: String) -> Bool {
        guard !running, configuration.isAvailable, let connection = configuration.selected else { return false }
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return false }
        let maximumQuestionBytes = 32_000
        guard question.utf8.count <= maximumQuestionBytes else {
            status = "问题太长，请缩短后重试。"
            return false
        }

        let requestMessages = messages(for: question)
        if turns.count >= turnLimit { turns.removeFirst(turns.count - turnLimit + 1) }
        let turn = Turn(question: question)
        turns.append(turn)
        activeID = turn.id
        running = true
        status = ""
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
            } catch {
                guard let self, self.activeID == turn.id else { return }
                self.finish()
                self.status = error.localizedDescription
            }
        }
        return true
    }

    func messages(for question: String) -> [AIMessage] {
        var history = [AIMessage]()
        var remaining = 64_000 - question.utf8.count
        for previous in turns.reversed() where previous.complete {
            let size = previous.question.utf8.count + previous.answer.utf8.count
            guard size <= remaining else { break }
            history.append(AIMessage(role: .assistant, content: previous.answer))
            history.append(AIMessage(role: .user, content: previous.question))
            remaining -= size
        }
        var messages = Array(history.reversed())
        messages.append(AIMessage(role: .user, content: question))
        return messages
    }

    func stop() {
        guard running else { return }
        task?.cancel()
        finish()
        status = "已停止。"
    }

    func beginChat() {
        isInChat = true
    }

    func leaveLauncher() {
        if !isInChat { reset() }
    }

    func closeChat() {
        isInChat = false
        reset()
    }

    func reset() {
        stop()
        turns = []
        status = ""
    }

    private func finish() {
        activeID = nil
        task = nil
        running = false
    }
}
