import Darwin
import Foundation

public struct ScriptCommand: Identifiable, Equatable, Sendable {
    public static let namespace = "script:"
    public let url: URL
    public let metadata: ScriptMetadata?
    public var id: String { Self.namespace + url.path }
    public var title: String { metadata?.title ?? url.deletingPathExtension().lastPathComponent }
    public var workingDirectory: URL {
        let base = url.deletingLastPathComponent()
        guard let configured = metadata?.currentDirectoryPath, !configured.isEmpty else { return base }
        let path = (configured as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true, relativeTo: base).standardizedFileURL
    }

    public static func read(_ file: URL) throws -> Self {
        let metadata: ScriptMetadata?
        if file.pathExtension.lowercased() == "scpt" {
            metadata = nil
        } else {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 64 * 1024) ?? Data()
            metadata = try ScriptMetadata.parse(String(decoding: prefix, as: UTF8.self))
        }
        return Self(url: file.standardizedFileURL, metadata: metadata)
    }

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
                      values.isSymbolicLink != true, supports(file),
                      let command = try? Self.read(file) else { continue }
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
        return (file.pathExtension.isEmpty || FileManager.default.isExecutableFile(atPath: file.path))
            && shebang(file) != nil
    }

    private static let interpreters = [
        "sh": "/bin/sh", "bash": "/bin/bash", "zsh": "/bin/zsh",
        "py": "python3", "js": "node", "mjs": "node", "cjs": "node",
        "rb": "ruby", "php": "php", "swift": "/usr/bin/swift",
        "applescript": "/usr/bin/osascript", "scpt": "/usr/bin/osascript",
        "ps1": "pwsh"
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

    private static func shebang(_ file: URL) -> (String, [String])? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512),
              let line = String(decoding: data, as: UTF8.self).split(maxSplits: 1, whereSeparator: \.isNewline).first,
              line.hasPrefix("#!") else { return nil }
        let parts = line.dropFirst(2).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let interpreter = parts.first, interpreter.hasPrefix("/") else { return nil }
        return (String(interpreter), parts.dropFirst().map(String.init))
    }

    fileprivate func invocation(arguments: [String]) throws -> (URL, [String]) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              values.isSymbolicLink != true, url.resolvingSymlinksInPath().path == url.path else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        if let (interpreter, options) = Self.shebang(url) {
            if FileManager.default.isExecutableFile(atPath: url.path) { return (url, arguments) }
            return (URL(fileURLWithPath: interpreter), options + [url.path] + arguments)
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
        public let standardOutput: String
        public let truncated: Bool
    }

    /// Call on a worker queue. Arguments are passed as argv without shell expansion.
    public static func run(_ script: ScriptCommand, arguments: [String], directory: URL,
                           timeout: TimeInterval, isCancelled: () -> Bool, onOutput: ((String) -> Void)? = nil) throws -> Result {
        if isCancelled() { return .init(status: .cancelled, output: "", standardOutput: "", truncated: false) }
        let (executable, argv) = try script.invocation(arguments: arguments)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let descriptors = [stdout, stderr].map { $0.fileHandleForReading.fileDescriptor }
        guard descriptors.allSatisfy({ fcntl($0, F_SETFL, O_NONBLOCK) != -1 }) else { throw POSIXError(.EIO) }
        process.executableURL = executable
        process.arguments = argv
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (environment["PATH"] ?? defaultPath) + ":/opt/homebrew/bin:/usr/local/bin"
        if environment["LANG"]?.isEmpty != false {
            let identifier = Locale.current.identifier.split(separator: "@", maxSplits: 1).first ?? "en_US"
            let preferred = String(identifier) + ".UTF-8"
            if let locale = newlocale(LC_CTYPE_MASK, preferred, nil) {
                freelocale(locale)
                environment["LANG"] = preferred
            } else {
                environment["LANG"] = "C.UTF-8"
            }
        }
        if environment["TERM"]?.isEmpty != false { environment["TERM"] = "linux" }
        process.environment = environment
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid
        func signal(_ value: Int32) {
            if ownsGroup, kill(-pid, value) == 0 { return }
            if process.isRunning { _ = kill(pid, value) }
        }

        var output = Data()
        var standardOutput = Data()
        let limit = 256 * 1024
        var truncated = false
        var publishedBytes = 0
        var lastOutput = ProcessInfo.processInfo.systemUptime
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            for (index, descriptor) in descriptors.enumerated() {
                for _ in 0..<16 {
                    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                    guard count > 0 else { break }
                    let accepted = min(count, limit - output.count)
                    output.append(contentsOf: buffer.prefix(accepted))
                    if index == 0 { standardOutput.append(contentsOf: buffer.prefix(min(count, limit - standardOutput.count))) }
                    truncated = truncated || accepted < count
                }
            }
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var interruption: Result.Status?
        while process.isRunning {
            drain()
            let now = ProcessInfo.processInfo.systemUptime
            if output.count != publishedBytes, now - lastOutput >= 0.1, let onOutput {
                lastOutput = now
                publishedBytes = output.count
                onOutput(String(decoding: output, as: UTF8.self))
            }
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
        return .init(status: status, output: String(decoding: output, as: UTF8.self),
                     standardOutput: String(decoding: standardOutput, as: UTF8.self), truncated: truncated)
    }
}
