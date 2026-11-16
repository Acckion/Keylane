import Foundation

/// Owns a module's child process and serializes cancellation against launch.
final class ExtensionProcessRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func launch(_ process: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run()
            self.process = process
        }
    }

    func finished() {
        lock.withLock { process = nil }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }
}
