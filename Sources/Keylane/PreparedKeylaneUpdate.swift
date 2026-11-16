import AppKit
import CryptoKit
import Darwin

final class PreparedKeylaneUpdate {
    private let target: URL
    private let staging: URL
    private let replacement: URL
    private let originalID: String

    private init(target: URL, staging: URL, replacement: URL, originalID: String) {
        self.target = target
        self.staging = staging
        self.replacement = replacement
        self.originalID = originalID
    }

    deinit { try? FileManager.default.removeItem(at: staging) }

    static let currentTeam: String? = {
        guard let output = try? run("/usr/bin/codesign", ["-dv", Bundle.main.bundlePath]) else { return nil }
        return output.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil ? $0 : nil }
    }()

    static func prepare(_ update: KeylaneReleaseCheck.Update) async throws -> PreparedKeylaneUpdate {
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard let team = currentTeam else { throw UpdateError.noTrustedTeam }
        guard target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.installLocation
        }

        let originalID = try codeHash(target)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let checksumURL = update.asset(update.release.checksumName)
        let request = URLRequest(url: checksumURL, timeoutInterval: 30)
        let (checksum, response) = try await URLSession.shared.data(for: request)
        try verifyResponse(response)
        let fields = String(decoding: checksum, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[1] == update.release.imageName,
              fields[0].range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw UpdateError.checksum
        }

        let (download, downloadResponse) = try await URLSession.shared.download(
            for: URLRequest(url: update.asset(update.release.imageName), timeoutInterval: 60))
        defer { try? FileManager.default.removeItem(at: download) }
        try verifyResponse(downloadResponse)
        let image = directory.appendingPathComponent(update.release.imageName)
        try FileManager.default.moveItem(at: download, to: image)
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .utility) {
            guard try digest(image) == fields[0].lowercased() else { throw UpdateError.checksum }
            return try stage(update, image: image, directory: directory, target: target, team: team, originalID: originalID)
        }.value
        try Task.checkCancellation()
        return result
    }

    private static func stage(_ update: KeylaneReleaseCheck.Update, image: URL, directory: URL,
                              target: URL, team: String, originalID: String) throws -> PreparedKeylaneUpdate {
        let developerID = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        try verifySignature(image, requirement: developerID)
        let assessment = try? run("/usr/sbin/spctl", [
            "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", image.path,
        ])
        guard assessment?.contains("source=Notarized Developer ID") == true else { throw UpdateError.untrusted }
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path]) }

        let application = mount.appendingPathComponent("Keylane.app", isDirectory: true)
        let requirement = developerID + " and identifier \"org.keylane.launcher\""
        try verifySignature(application, requirement: requirement)
        guard let bundle = Bundle(url: application),
              bundle.bundleIdentifier == "org.keylane.launcher",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == update.release.version,
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == String(update.build) else {
            throw UpdateError.version
        }

        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: target, create: true)
        let replacement = staging.appendingPathComponent("Keylane.app", isDirectory: true)
        do {
            try run("/usr/bin/ditto", [application.path, replacement.path])
            try verifySignature(replacement, requirement: requirement)
            return PreparedKeylaneUpdate(target: target, staging: staging, replacement: replacement, originalID: originalID)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func install(relaunch: Bool) throws {
        // Serialize cooperating instances and recheck the destination before the atomic swap.
        let parent = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw Self.posixError() }
        defer { close(parent) }
        guard flock(parent, LOCK_EX | LOCK_NB) == 0 else { throw UpdateError.changed }
        guard try Self.codeHash(target) == originalID else { throw UpdateError.changed }
        try swap()
        guard relaunch else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            for attempt in $(/usr/bin/seq 1 100); do
                if ! kill -0 "$1" 2>/dev/null; then exec /usr/bin/open "$2"; fi
                /bin/sleep 0.1
            done
            """, "keylane-relaunch", String(getpid()), target.path]
        do { try process.run() }
        catch {
            try swap()
            throw error
        }
    }

    private func swap() throws {
        let result = target.withUnsafeFileSystemRepresentation { destination in
            replacement.withUnsafeFileSystemRepresentation { candidate in
                renameatx_np(AT_FDCWD, destination, AT_FDCWD, candidate, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else { throw Self.posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func verifyResponse(_ response: URLResponse) throws {
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https" else {
            throw URLError(.badServerResponse)
        }
    }

    private static func verifySignature(_ url: URL, requirement: String) throws {
        do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", url.path]) }
        catch { throw UpdateError.untrusted }
    }

    private static func codeHash(_ url: URL) throws -> String {
        let result = try run("/usr/bin/codesign", ["-dv", "--verbose=4", url.path])
        guard let line = result.split(separator: "\n").first(where: { $0.hasPrefix("CDHash=") }) else {
            throw UpdateError.changed
        }
        return String(line)
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { sha.update(data: data) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, value in value }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.verification }
        return String(decoding: data, as: UTF8.self)
    }

    private enum UpdateError: LocalizedError {
        case noTrustedTeam, installLocation, checksum, untrusted, version, changed, verification

        var errorDescription: String? {
            switch self {
            case .noTrustedTeam: "当前构建没有可用于验证更新的开发团队签名。"
            case .installLocation: "请先把 Keylane 移到可写的「应用程序」目录。"
            case .checksum: "下载文件的 SHA-256 校验未通过。"
            case .untrusted: "更新包未通过同一开发团队签名和 Apple 公证验证。"
            case .version: "安装包版本与 GitHub 发布记录不符。"
            case .changed: "已安装的 Keylane 在更新期间发生了变化。"
            case .verification: "无法验证或准备安装包。"
            }
        }
    }
}
