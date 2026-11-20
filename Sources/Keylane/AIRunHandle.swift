import Foundation
import KeylaneCore

/// One transport loop for conversations and module actions. No UI, sources or history here.
final class AIRunHandle {
    let id = UUID()
    private var task: Task<Void, Never>?
    private var active = true
    func cancel() { active = false; task?.cancel(); task = nil }
    deinit { task?.cancel() }

    static func start(runtime: AIRuntime, connection: AIConnection,
                      readKey: @escaping @Sendable (AIConnection) throws -> String?, messages: [AIMessage],
                      prepareTools: @escaping @MainActor () throws -> AIToolRun? = { nil },
                      progress: @escaping (AIResponseEvent) -> Void,
                      text: @escaping (String) -> Void,
                      completion: @escaping (Result<Int?, Error>) -> Void) -> AIRunHandle {
        let handle = AIRunHandle()
        handle.task = Task { @MainActor [weak handle] in
            do {
                try Task.checkCancellation()
                let tools = try prepareTools()
                let usage = try await runtime.generate(connection: connection, readKey: readKey, messages: messages, tools: tools,
                    progress: { event in await MainActor.run { if handle?.active == true { progress(event) } } }) { delta in
                    try await MainActor.run {
                        guard handle?.active == true else { throw CancellationError() }
                        text(delta)
                    }
                }
                guard let handle, handle.active else { return }
                handle.active = false; handle.task = nil; completion(.success(usage))
            } catch {
                guard let handle, handle.active else { return }
                handle.active = false; handle.task = nil; completion(.failure(error))
            }
        }
        return handle
    }
}

// Presentation-only catalog edits do not change an in-flight request's destination.
extension AIConnection {
    var executionSnapshot: AIConnection {
        var value = self; value.name = ""; value.hiddenFromPicker = nil; value.catalogName = nil
        return value
    }
}
