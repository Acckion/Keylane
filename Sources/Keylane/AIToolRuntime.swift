import Combine
import Foundation
import KeylaneCore

/// A module contributes declarations and handlers; catalog reads never execute handlers.
struct AIToolRegistration: Sendable {
    let definition: AIToolDefinition
    var requiresConfirmation = false
    var confirmationRequired: @MainActor @Sendable ([String: AIToolValue]) -> Bool = { _ in false }
    var available: @MainActor @Sendable () -> Bool = { true }
    let perform: @MainActor @Sendable ([String: AIToolValue]) async throws -> AIToolResult
}

struct AIToolApproval: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let arguments: String
}

/// The owning conversation cancels this broker on stop/reset; old buttons cannot approve a new request.
final class AIToolApprovalBroker: ObservableObject {
    @Published private(set) var pending: AIToolApproval?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?

    @MainActor func request(title: String, arguments: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let request = AIToolApproval(title: title, arguments: arguments)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { reply in
                guard !Task.isCancelled else { reply.resume(returning: false); return }
                cancel()
                pending = request
                continuation = reply
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self?.resolve(request.id, allow: false)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolve(request.id, allow: false) } }
    }

    func resolve(_ id: UUID, allow: Bool) {
        guard pending?.id == id else { return }
        let reply = continuation
        continuation = nil
        pending = nil
        timeout?.cancel(); timeout = nil
        reply?.resume(returning: allow)
    }

    func cancel() {
        if let id = pending?.id { resolve(id, allow: false) }
    }
}

/// One run, one frozen advertised catalog and bounded ledger. Availability is checked live.
actor AIToolRun {
    nonisolated let catalog: AIToolCatalog
    private let registrations: [String: AIToolRegistration]
    private let isCurrent: @MainActor @Sendable () -> Bool
    private let approve: @MainActor @Sendable (String, String) async -> Bool
    private var budget = AIToolRunBudget()
    private var executing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !executing { executing = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { executing = false }
        else { waiters.removeFirst().resume() }
    }

    init(registrations: [AIToolRegistration], isCurrent: @escaping @MainActor @Sendable () -> Bool,
         approve: @escaping @MainActor @Sendable (String, String) async -> Bool) throws {
        catalog = try AIToolCatalog(registrations.map(\.definition))
        self.registrations = Dictionary(uniqueKeysWithValues: registrations.map { ($0.definition.name, $0) })
        self.isCurrent = isCurrent
        self.approve = approve
    }

    func nextRound() async throws {
        try await validateCurrent()
        try budget.beginRound()
    }

    func validateCurrent() async throws {
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
    }

    func execute(_ call: AIToolCall, scope: String,
                 progress: @Sendable (AIResponseEvent) async -> Void) async throws -> AIToolResult {
        await acquire()
        defer { release() }
        try await validateCurrent()
        let ledgerID = scope + ":" + call.id
        // Reserve a whole bounded result before an operation can have effects.
        guard budget.resultBytes <= 131_072 - 32_768 else { throw AIToolContractError.limitReached }
        try budget.admit([call])
        let arguments = try AIToolWire.string(call.arguments)
        let name = registrations[call.name]?.definition.title ?? call.name
        await progress(.tool(id: ledgerID, name: name, arguments: arguments, state: .requested))
        var result: AIToolResult
        do {
            try catalog.validate(call)
            guard let tool = registrations[call.name], await tool.available() else { throw AIToolContractError.unavailable }
            let needsConfirmation = await tool.confirmationRequired(call.arguments)
            if tool.requiresConfirmation || needsConfirmation {
                guard await approve(name, arguments) else {
                    try await validateCurrent()
                    let denied = try AIToolResult(text: "用户未允许本次操作。不要重试该操作，向用户说明未执行。", isError: true)
                    try budget.record(denied, for: call.id)
                    await progress(.tool(id: ledgerID, name: name, arguments: arguments, state: .notExecuted))
                    await progress(.toolResult(id: ledgerID, text: denied.text))
                    return denied
                }
            }
            try await validateCurrent()
            guard await tool.available() else { throw AIToolContractError.unavailable }
            await progress(.tool(id: ledgerID, name: name, arguments: arguments, state: .running))
            let isCurrent = self.isCurrent
            let invoke: @MainActor @Sendable () async throws -> AIToolResult = {
                // Check and enter the native handler on the same actor as stop/disable.
                try Task.checkCancellation()
                guard isCurrent(), tool.available() else { throw CancellationError() }
                return try await tool.perform(call.arguments)
            }
            result = try await invoke()
            try await validateCurrent()
            guard await tool.available() else { throw AIToolContractError.unavailable }
        } catch is CancellationError { throw CancellationError() }
        catch {
            let detail = (error as? AIToolContractError)?.localizedDescription ?? "功能无法完成，数据可能不可用。"
            result = try AIToolResult(text: "工具未完成：" + detail + " 不要声称操作成功。", isError: true)
        }
        try budget.record(result, for: call.id)
        await progress(.tool(id: ledgerID, name: name, arguments: arguments, state: result.isError ? .failed : .completed))
        await progress(.toolResult(id: ledgerID, text: result.text))
        return result
    }
}

enum AIToolWire {
    static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed) }
    static func string<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func arguments(_ object: Any) throws -> [String: AIToolValue] {
        guard JSONSerialization.isValidJSONObject(object) else { throw AIToolContractError.invalidArguments }
        return try AIToolValue.arguments(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    static func result(_ object: [String: AIToolValue]) throws -> AIToolResult { try .init(text: string(object)) }
}
