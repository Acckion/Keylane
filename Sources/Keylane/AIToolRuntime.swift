import Combine
import Foundation
import KeylaneCore

struct AIToolRecipient: Sendable {
    let destination: String
    let model: String
}

struct AIToolPreparedOperation: Sendable {
    static let unapprovedResult = "目标未获核实与披露许可。本次未执行；不得据此判断目标是否存在，请用户在本机检查设置。不要重试或声称成功。"
    let displayArguments: String
    let approvalArguments: String
    let perform: @MainActor @Sendable () async throws -> AIToolResult
}

/// A module contributes declarations and handlers; catalog reads never execute handlers.
struct AIToolRegistration: Sendable {
    let definition: AIToolDefinition
    var owner: ModuleID?
    var ownerTitle: String?
    var requiresConfirmation = false
    var prepare: (@MainActor @Sendable ([String: AIToolValue], AIToolRecipient?) async throws -> AIToolPreparedOperation)? = nil
    var available: @MainActor @Sendable () -> Bool = { true }
    var snapshotAvailability: (@MainActor @Sendable () -> (@MainActor @Sendable () -> Bool))? = nil
    var confirmationDetail: (@MainActor @Sendable ([String: AIToolValue], AIToolRunScope) throws -> String)? = nil
    var performInRun: (@MainActor @Sendable ([String: AIToolValue], AIToolRunScope) async throws -> AIToolResult)? = nil
    var perform: @MainActor @Sendable ([String: AIToolValue]) async throws -> AIToolResult = { _ in throw AIToolContractError.unavailable }

    init(definition: AIToolDefinition, requiresConfirmation: Bool = false,
         prepare: (@MainActor @Sendable ([String: AIToolValue], AIToolRecipient?) async throws -> AIToolPreparedOperation)? = nil,
         available: @escaping @MainActor @Sendable () -> Bool = { true },
         perform: @escaping @MainActor @Sendable ([String: AIToolValue]) async throws -> AIToolResult) {
        self.definition = definition; self.requiresConfirmation = requiresConfirmation
        self.prepare = prepare
        self.available = available; self.perform = perform
    }

    init(definition: AIToolDefinition, requiresConfirmation: Bool = false,
         available: @escaping @MainActor @Sendable () -> Bool = { true },
         snapshotAvailability: @escaping @MainActor @Sendable () -> (@MainActor @Sendable () -> Bool),
         confirmationDetail: (@MainActor @Sendable ([String: AIToolValue], AIToolRunScope) throws -> String)? = nil,
         performInRun: @escaping @MainActor @Sendable ([String: AIToolValue], AIToolRunScope) async throws -> AIToolResult) {
        self.definition = definition; self.requiresConfirmation = requiresConfirmation
        self.available = available; self.snapshotAvailability = snapshotAvailability
        self.confirmationDetail = confirmationDetail; self.performInRun = performInRun
    }

    @MainActor func forRun() -> Self {
        var copy = self
        if let snapshotAvailability {
            let live = available
            let lease = snapshotAvailability()
            copy.available = { live() && lease() }
            copy.snapshotAvailability = nil
        }
        return copy
    }
}

/// Private references live for one model run, never in history or a global registry.
final class AIToolRunScope: @unchecked Sendable {
    private var storage: [ObjectIdentifier: AnyObject] = [:]
    @MainActor func state<T: AnyObject>(_ type: T.Type, create: () -> T) -> T {
        let key = ObjectIdentifier(type)
        if let value = storage[key] as? T { return value }
        let value = create(); storage[key] = value; return value
    }
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
    private let recipient: AIToolRecipient?
    private let isCurrent: @MainActor @Sendable () -> Bool
    private let approve: @MainActor @Sendable (String, String) async -> Bool
    private let runScope = AIToolRunScope()
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

    init(registrations: [AIToolRegistration], recipient: AIToolRecipient? = nil, isCurrent: @escaping @MainActor @Sendable () -> Bool,
         approve: @escaping @MainActor @Sendable (String, String) async -> Bool) throws {
        guard registrations.allSatisfy({ $0.snapshotAvailability == nil }) else { throw AIToolContractError.unavailable }
        catalog = try AIToolCatalog(registrations.map(\.definition))
        self.registrations = Dictionary(uniqueKeysWithValues: registrations.map { ($0.definition.name, $0) })
        self.recipient = recipient
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
        let registration = registrations[call.name]
        var arguments = registration?.prepare == nil ? try AIToolWire.string(call.arguments) : "目标尚未核实"
        let name = registrations[call.name]?.definition.title ?? call.name
        var result: AIToolResult
        var disclosureAllowed = false
        do {
            try catalog.validate(call)
            guard let tool = registrations[call.name], await tool.available() else { throw AIToolContractError.unavailable }
            let prepared = try await tool.prepare?(call.arguments, recipient)
            if let prepared { arguments = prepared.displayArguments }
            try await validateCurrent()
            guard await tool.available() else { throw AIToolContractError.unavailable }
            await progress(.tool(id: ledgerID, name: name, arguments: arguments, state: .requested))
            if tool.requiresConfirmation || prepared != nil {
                var review = prepared?.approvalArguments ?? arguments
                if prepared == nil, let detail = tool.confirmationDetail {
                    review = try await detail(call.arguments, runScope)
                }
                try await validateCurrent()
                guard await tool.available() else { throw AIToolContractError.unavailable }
                guard await approve(name, review) else {
                    try await validateCurrent()
                    let denied = try AIToolResult(text: prepared == nil ? "用户未允许本次操作。不要重试该操作，向用户说明未执行。" : AIToolPreparedOperation.unapprovedResult, isError: true)
                    try budget.record(denied, for: call.id)
                    await progress(.tool(id: ledgerID, name: name, arguments: arguments, state: .notExecuted))
                    await progress(.toolResult(id: ledgerID, text: denied.text))
                    return denied
                }
            }
            disclosureAllowed = true
            try await validateCurrent()
            guard await tool.available() else { throw AIToolContractError.unavailable }
            await progress(.tool(id: ledgerID, name: name, arguments: arguments, state: .running))
            let isCurrent = self.isCurrent
            let runScope = self.runScope
            let invoke: @MainActor @Sendable () async throws -> AIToolResult = {
                // Check and enter the native handler on the same actor as stop/disable.
                try Task.checkCancellation()
                guard isCurrent(), tool.available() else { throw CancellationError() }
                if let prepared { return try await prepared.perform() }
                if let scoped = tool.performInRun { return try await scoped(call.arguments, runScope) }
                return try await tool.perform(call.arguments)
            }
            result = try await invoke()
            try await validateCurrent()
            guard await tool.available() else { throw AIToolContractError.unavailable }
        } catch is CancellationError { throw CancellationError() }
        catch {
            if registration?.prepare != nil, !disclosureAllowed {
                // Match denied approval exactly: errors must not become an
                // unapproved existence/protected-path oracle through tool results.
                result = try AIToolResult(text: AIToolPreparedOperation.unapprovedResult, isError: true)
            } else {
                let detail = (error as? AIToolContractError)?.localizedDescription ??
                    (error as? AIFileToolError)?.localizedDescription ?? "功能无法完成，数据可能不可用。"
                result = try AIToolResult(text: "工具未完成：" + detail + " 不要声称操作成功。", isError: true)
            }
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
