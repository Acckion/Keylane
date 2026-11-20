import Combine
import Foundation

/// Shared lifecycle for synchronous and asynchronous context sources.
final class AIContextLoadState: ObservableObject {
    @Published private(set) var loading = false
    private var generation = UUID()

    @discardableResult
    func begin() -> UUID {
        generation = UUID()
        loading = true
        return generation
    }

    @discardableResult
    func complete(_ request: UUID) -> Bool {
        guard generation == request else { return false }
        loading = false
        return true
    }

    func performSynchronously(_ operation: () -> Void) {
        let request = begin()
        defer { complete(request) }
        operation()
    }

    func cancel() {
        generation = UUID()
        loading = false
    }
}
