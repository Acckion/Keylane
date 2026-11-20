import Foundation
import Darwin

/// An unlinked private result file. No pathname or descriptor is sent to a model,
/// inherited by a provider CLI, retained in history, or restored after restart.
final class AITemporaryReadResult: @unchecked Sendable {
    let count: Int
    private let fd: Int32
    init(_ data: Data) throws {
        guard data.count <= 2_097_152 else { throw AIFileToolError.tooLarge }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneAIResult-" + UUID().uuidString).path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AIFileToolError.unavailable }
        guard unlink(path) == 0 else { Darwin.close(descriptor); throw AIFileToolError.unavailable }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let n = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard n > 0 else { throw AIFileToolError.unavailable }; offset += n
                }
            }
        } catch { Darwin.close(descriptor); throw error }
        fd = descriptor; count = data.count
    }
    deinit { Darwin.close(fd) }
    func read(offset: Int = 0, limit: Int? = nil, check: () throws -> Void) throws -> Data {
        guard (0...count).contains(offset) else { throw AIFileToolError.invalidPath }
        let size = min(limit ?? count, count - offset)
        guard size >= 0 else { throw AIFileToolError.invalidPath }
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(max(size, 1), 16_384))
        while data.count < size {
            try check()
            let n = pread(fd, &buffer, min(buffer.count, size - data.count), off_t(offset + data.count))
            guard n > 0 else { throw AIFileToolError.unavailable }
            data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
}
