import Darwin
import Foundation

public struct ScriptCommand: Identifiable, Equatable, Sendable {
    public static let namespace = "script:"
    public let url: URL
    public var id: String { Self.namespace + url.path }
    public var title: String { url.deletingPathExtension().lastPathComponent }

    public static func discover(in folders: [String]) -> (commands: [Self], unavailable: [String]) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var commands: [String: Self] = [:]
        var unavailable = Set<String>()
        for folder in folders {
            let root = URL(fileURLWithPath: folder, isDirectory: true).resolvingSymlinksInPath()
            guard manager.isReadableFile(atPath: root.path),
                  let children = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                    errorHandler: { _, _ in unavailable.insert(folder); return true }) else {
                unavailable.insert(folder)
                continue
            }
            for case let file as URL in children {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      values.isSymbolicLink != true, supports(file) else { continue }
                let command = Self(url: file.standardizedFileURL)
                commands[command.id] = command
            }
        }
        return (commands.values.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }, unavailable.sorted())
    }

    private static func supports(_ file: URL) -> Bool {
        if interpreters[file.pathExtension.lowercased()] != nil { return true }
        return file.pathExtension.isEmpty && FileManager.default.isExecutableFile(atPath: file.path) && hasShebang(file)
    }

    private static let interpreters = [
        "sh": "/bin/sh", "bash": "/bin/bash", "zsh": "/bin/zsh",
        "py": "python3", "js": "node", "mjs": "node", "cjs": "node"
    ]

    public static func createTemplate(at url: URL) throws {
        let content: String
        switch url.pathExtension.lowercased() {
        case "sh": content = "#!/bin/sh\nprintf '%s\\n' 'Hello from Keylane'\n"
        case "bash": content = "#!/bin/bash\nprintf '%s\\n' 'Hello from Keylane'\n"
        case "zsh": content = "#!/bin/zsh\nprintf '%s\\n' 'Hello from Keylane'\n"
        case "py": content = "print('Hello from Keylane')\n"
        case "js", "mjs", "cjs": content = "console.log('Hello from Keylane');\n"
        default: throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: url.path])
        }
        try Data(content.utf8).write(to: url, options: .withoutOverwriting)
    }

    private static func hasShebang(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data([0x23, 0x21])
    }

    fileprivate func invocation(arguments: [String]) throws -> (URL, [String]) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              values.isSymbolicLink != true, url.resolvingSymlinksInPath().path == url.path else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        if FileManager.default.isExecutableFile(atPath: url.path), Self.hasShebang(url) {
            return (url, arguments)
        }
        guard let interpreter = Self.interpreters[url.pathExtension.lowercased()] else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: url.path])
        }
        let args = [url.path] + arguments
        if interpreter.hasPrefix("/") { return (URL(fileURLWithPath: interpreter), args) }
        return (URL(fileURLWithPath: "/usr/bin/env"), [interpreter] + args)
    }
}

public enum ScriptRunner {
    public struct Result: Equatable, Sendable {
        public enum Status: Equatable, Sendable {
            case exited(Int32), signalled(Int32), cancelled, timedOut
        }
        public let status: Status
        public let output: String
        public let truncated: Bool
    }

    /// Call on a worker queue. Arguments are passed as argv without shell expansion.
    public static func run(_ script: ScriptCommand, arguments: [String], directory: URL,
                           timeout: TimeInterval, isCancelled: () -> Bool) throws -> Result {
        if isCancelled() { return .init(status: .cancelled, output: "", truncated: false) }
        let (executable, argv) = try script.invocation(arguments: arguments)
        let process = Process()
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let fd = reader.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw POSIXError(.EIO) }
        process.executableURL = executable
        process.arguments = argv
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (environment["PATH"] ?? defaultPath) + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid
        func signal(_ value: Int32) {
            if ownsGroup, kill(-pid, value) == 0 { return }
            if process.isRunning { _ = kill(pid, value) }
        }

        var output = Data()
        let limit = 256 * 1024
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            for _ in 0..<32 {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                let accepted = min(count, limit - output.count)
                output.append(contentsOf: buffer.prefix(accepted))
                truncated = truncated || accepted < count
            }
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var interruption: Result.Status?
        while process.isRunning {
            drain()
            if isCancelled() { interruption = .cancelled }
            else if ProcessInfo.processInfo.systemUptime >= deadline { interruption = .timedOut }
            if interruption != nil {
                signal(SIGTERM)
                Thread.sleep(forTimeInterval: 0.25)
                signal(SIGKILL)
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        drain()
        let status = interruption ?? (process.terminationReason == .exit
            ? .exited(process.terminationStatus) : .signalled(process.terminationStatus))
        return .init(status: status, output: String(decoding: output, as: UTF8.self), truncated: truncated)
    }
}
