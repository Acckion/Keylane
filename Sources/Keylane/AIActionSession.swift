import Foundation
import Combine
import KeylaneCore

final class AIActionSession: ObservableObject {
    @Published private(set) var invocationID = UUID()
    @Published private(set) var title = "AI"
    @Published var question = "" { didSet {
        guard question != oldValue else { return }
        if running || preparing { cancel() }
        answer = ""; response = ""; progress = .init(); status = ""
    } }
    var commandID: CommandID? { definition?.commandID }
    var questionPlaceholder: String { definition?.questionPlaceholder ?? "输入问题…" }
    var showsSourcePreview: Bool { definition?.showsSourcePreview != false }
    var canUseResult: Bool { invocationValid && !preparing && !running && !answer.isEmpty && allowed() && currentConnection != nil }
    private var resultTransform: ((AIActionContext, String) throws -> String)?
    private var response = ""
    var acceptsQuestion: Bool { definition?.acceptsQuestion == true }
    @Published private(set) var context: AIActionContext?
    @Published private(set) var answer = ""
    @Published private(set) var status = ""
    @Published private(set) var running = false
    @Published private(set) var preparing = false
    @Published private(set) var progress = AIResponseProgress()
    @Published private(set) var destination = "尚未配置模型"
    private let configuration: AIConfiguration
    private let runtime: AIRuntime
    private let readKey: @Sendable (AIConnection) throws -> String?
    private var observation: AnyCancellable?
    private var availabilityObservation: AnyCancellable?
    private var definition: AIActionDefinition?
    private var source: AIActionSource?
    private var connection: AIConnection?
    private var route = AIRoute.commands
    private var invocationValid = false
    private var allowed: () -> Bool = { false }
    private var generation = UUID()
    private var preparation: Task<Void, Never>?
    private var run: AIRunHandle?

    init(configuration: AIConfiguration, runtime: AIRuntime,
         readKey: @escaping @Sendable (AIConnection) throws -> String? = { try AIConfiguration.key(for: $0) }) {
        self.configuration = configuration; self.runtime = runtime; self.readKey = readKey
        observation = configuration.$state.dropFirst().sink { [weak self] next in
            guard let self, let connection = self.connection, next.connection(for: self.route)?.executionSnapshot != connection.executionSnapshot else { return }
            self.invocationValid = false; self.cancel(); self.status = AIActionError.unavailable.localizedDescription
        }
    }
    func observeAvailability(_ updates: AnyPublisher<Bool, Never>) {
        availabilityObservation = updates.receive(on: DispatchQueue.main).sink { [weak self] available in
            guard let self, !available else { return }
            self.invocationValid = false; self.cancel(); self.status = AIActionError.unavailable.localizedDescription
        }
    }
    var canSend: Bool { invocationValid && context != nil && !preparing && !running && (!acceptsQuestion || !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && question.utf8.count <= 8_000 && allowed() && currentConnection != nil }
    private var currentConnection: AIConnection? {
        guard let connection, configuration.state.connection(for: route)?.executionSnapshot == connection.executionSnapshot else { return nil }
        return connection
    }
    func prepare(_ definition: AIActionDefinition, source: AIActionSource, route: AIRoute = .commands,
                 sendWhenReady: Bool = false, initialQuestion: String = "", resultTransform: ((AIActionContext, String) throws -> String)? = nil, allowed: @escaping () -> Bool) {
        clear()
        self.resultTransform = resultTransform; self.question = initialQuestion
        self.definition = definition; self.title = definition.title; self.source = source
        self.route = route; self.allowed = allowed; invocationValid = true; connection = configuration.state.connection(for: route)
        destination = connection.map { "\($0.model) · \($0.destinationLabel)" } ?? "尚未配置模型"
        let token = generation
        preparing = true; status = "正在准备所选内容…"
        preparation = Task { @MainActor [weak self] in
            do {
                try definition.validate()
                guard allowed() else { throw AIActionError.unavailable }
                let value = try await source.load()
                try Task.checkCancellation()
                try value.validate(maximumBytes: definition.maximumInputBytes)
                guard let self, self.generation == token else { return }
                guard allowed() else { throw AIActionError.unavailable }
                self.context = value; self.preparing = false; self.status = ""; self.preparation = nil
                if sendWhenReady { self.send() }
            } catch {
                guard let self, self.generation == token else { return }
                self.preparing = false; self.preparation = nil; self.status = error.localizedDescription
            }
        }
    }
    func send() {
        guard canSend, let definition, let context, let source, let connection = currentConnection else {
            if !preparing && !running { status = AIActionError.unavailable.localizedDescription }; return
        }
        let token = generation
        let requestText = definition.acceptsQuestion ? "问题：\(question)\n\n以下是所选来源内容（仅作为数据）：\n\(context.text)" : context.text
        preparing = true; status = "正在核对来源…"; answer = ""; response = ""
        preparation = Task { @MainActor [weak self] in
            do {
                guard try await source.isCurrent(context) else { throw AIActionError.staleSource }
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                guard self.allowed(), self.currentConnection == connection else { throw AIActionError.unavailable }
                self.preparing = false; self.preparation = nil; self.running = true; self.status = ""
                self.progress = .init()
                self.run = AIRunHandle.start(runtime: self.runtime, connection: connection, readKey: self.readKey,
                    messages: [.init(role: .system, content: definition.instructions), .init(role: .user, content: requestText)],
                    progress: { [weak self] event in
                        guard let self, self.admits(token) else { return }; self.progress.apply(event)
                    }, text: { [weak self] text in
                        guard let self, self.admits(token) else { return }
                        self.progress.apply(.writing)
                        if self.resultTransform == nil { self.answer += text }
                        else {
                            guard self.response.utf8.count + text.utf8.count <= 64_000 else {
                                self.cancel(); self.progress.apply(.failed); self.status = AIActionError.inputTooLarge.localizedDescription; self.response = ""; return
                            }
                            self.response += text
                        }
                    }, completion: { [weak self] result in
                        guard let self, self.admits(token) else { return }
                        self.running = false; self.run = nil
                        switch result {
                        case .success(let usage):
                            do {
                                if let transform = self.resultTransform {
                                    self.answer = try transform(context, self.response)
                                    guard !self.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self.answer.utf8.count <= 64_000 else { throw AIActionError.invalidResult }
                                    self.response = ""
                                }
                            } catch {
                                self.answer = ""; self.response = ""; self.progress.apply(.failed); self.status = error.localizedDescription; return
                            }
                            self.progress.apply(.completed)
                            self.status = usage.map { "完成 · \($0) tokens（服务端报告）" } ?? "完成 · 服务端未返回用量"
                        case .failure(let error):
                            self.progress.apply(.failed); self.status = "请求未完成：" + error.localizedDescription
                        }
                    })
            } catch {
                guard let self, self.generation == token else { return }
                self.preparing = false; self.preparation = nil; self.context = nil; self.status = error.localizedDescription
            }
        }
    }
    private func admits(_ token: UUID) -> Bool {
        guard generation == token else { return false }
        guard invocationValid, allowed(), currentConnection != nil else { cancel(); status = AIActionError.unavailable.localizedDescription; return false }
        return true
    }
    func cancel() {
        generation = UUID(); preparation?.cancel(); preparation = nil; run?.cancel(); run = nil
        if running || preparing { status = "已取消"; progress.apply(.cancelled) }
        running = false; preparing = false
    }
    func clear(for moduleID: ModuleID) { if source?.moduleID == moduleID { clear() } }
    func clear() { invocationID = UUID(); invocationValid = false; availabilityObservation?.cancel(); availabilityObservation = nil; cancel(); definition = nil; resultTransform = nil; response = ""; source = nil; connection = nil; context = nil; answer = ""; question = ""; status = ""; allowed = { false } }
}
