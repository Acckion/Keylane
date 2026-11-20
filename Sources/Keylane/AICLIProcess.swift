import Darwin
import Foundation

enum AISubscriptionError: LocalizedError {
    case missingExecutable, invalidFolder, failed, timeout, unsupported, accountChanged
    var errorDescription: String? {
        switch self {
        case .missingExecutable: "找不到 CLI。请先安装并登录，或在 Advanced 中选择可执行文件。"
        case .invalidFolder: "账户目录须为有效的绝对目录路径。"
        case .failed: "CLI 请求失败。请检查版本、订阅登录状态和所选模型。"
        case .timeout: "CLI 响应超时。"
        case .accountChanged: "账户已变化，请重新连接账户、刷新用量并再次确认。"
        case .unsupported: "当前 CLI 未提供此功能，请更新后重试。"
        }
    }
}

/// Each invocation owns its pipes and process. Output and lifetime are bounded.
final class AICLIProcess: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private let inputLock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stopped = false
    private var bytes = 0

    init(connection: AIConnection, arguments: [String], directory: URL) throws {
        process.executableURL = try Self.executable(connection)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = [String: String]()
        for key in ["PATH", "HOME", "LANG", "TMPDIR"] {
            environment[key] = ProcessInfo.processInfo.environment[key]
        }
        environment["PATH"] = [process.executableURL!.deletingLastPathComponent().path,
                               environment["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        if let folder = connection.accountFolder, !folder.isEmpty {
            var isDirectory: ObjCBool = false
            guard folder.hasPrefix("/"), FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw AISubscriptionError.invalidFolder }
            environment[connection.protocolKind == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = folder
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    static func executable(_ connection: AIConnection) throws -> URL {
        let name = connection.protocolKind == .codex ? "codex" : "claude"
        let candidates: [String]
        if let explicit = connection.executablePath, !explicit.isEmpty {
            guard explicit.hasPrefix("/") else { throw AISubscriptionError.missingExecutable }
            candidates = [explicit]
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
                + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                   "/Applications/Codex.app/Contents/Resources", "/Applications/ChatGPT.app/Contents/Resources"]
            candidates = directories.map { $0 + "/" + name }
        }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AISubscriptionError.missingExecutable
        }
        return URL(fileURLWithPath: path)
    }

    func start() throws -> AsyncThrowingStream<Data, Error> {
        let stream = AsyncThrowingStream<Data, Error> { continuation = $0 }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.lock()
            self.bytes += data.count
            let exceeds = self.bytes > 2_097_152
            let continuation = self.continuation
            self.lock.unlock()
            if exceeds { self.stop(error: AISubscriptionError.failed) }
            else if data.isEmpty { continuation?.finish() }
            else { continuation?.yield(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            try process.run()
        }
        return stream
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try inputLock.withLock { try input.fileHandleForWriting.write(contentsOf: data) }
    }

    func sendText(_ text: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try input.fileHandleForWriting.close()
    }

    func stop(error: Error? = nil) {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            if process.isRunning {
                process.terminate()
                let ownedProcess = process
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if ownedProcess.isRunning { kill(ownedProcess.processIdentifier, SIGKILL) }
                }
            }
            continuation?.finish(throwing: error)
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
    }
}
