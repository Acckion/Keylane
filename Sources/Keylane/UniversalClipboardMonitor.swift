import Foundation

/// The log message supplies a generation hint. The pasteboard still has to
/// advertise the remote type and match that generation before anything is saved.
final class UniversalClipboardMonitor {
    private static let arrival = "Current generation after remote pasteboard change:"
    private var process: Process?
    private var output: FileHandle?
    private var buffer = Data()

    func start(onArrival: @escaping (Int) -> Void) {
        guard process == nil else { return }
        let task = Process()
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = [
            "stream", "--style", "ndjson", "--level", "debug", "--no-backtrace",
            "--predicate", "process == \"pboard\" AND eventMessage BEGINSWITH \"\(Self.arrival)\""
        ]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        process = task
        output = reader
        reader.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self, let task, self.process === task else { return }
                if data.isEmpty {
                    self.stop()
                    return
                }
                for generation in self.consume(data) { onArrival(generation) }
            }
        }
        do { try task.run() }
        catch { stop() }
    }

    func stop() {
        output?.readabilityHandler = nil
        output = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        buffer.removeAll()
    }

    deinit { stop() }

    private func consume(_ data: Data) -> [Int] {
        buffer.append(data)
        var generations: [Int] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            if let generation = Self.generation(in: buffer.prefix(upTo: end)) {
                generations.append(generation)
            }
            buffer.removeSubrange(...end)
        }
        if buffer.count > 16_384 { buffer.removeAll() }
        return generations
    }

    static func generation(in line: Data) -> Int? {
        guard let record = try? JSONDecoder().decode(LogRecord.self, from: line),
              let message = record.eventMessage, message.hasPrefix(arrival),
              let number = Int(message.dropFirst(arrival.count).trimmingCharacters(in: .whitespaces)),
              number >= 0 else { return nil }
        return number
    }

    private struct LogRecord: Decodable {
        let eventMessage: String?
    }
}
