import Foundation
import CommonCrypto
import CryptoKit
import zlib

/// Independently implemented from observed public SuperCMD v1 interchange fields.
/// No subprocesses, plaintext temp files, downloads or permission changes.
public enum RaycastConfiguration {
    public struct Preview {
        public var archive: ConfigurationArchive
        public let warnings: [String]
        public var categories: [RaycastImportCategory] = []
        public var data = RaycastMigrationData()
    }
    public static func decode(_ data: Data, password: String = "", applicationPaths: Set<String> = []) throws -> Preview {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw ConfigurationError("Raycast 文件为空或超过 16 MB。") }
        var plain = data
        if (try? JSONSerialization.jsonObject(with: data)) == nil {
            guard !password.isEmpty else { throw ConfigurationError("需要 Raycast 导出备份时设置的密码。") }
            plain = try decrypt(data, password: password)
        }
        if let array = try JSONSerialization.jsonObject(with: plain) as? [[String: Any]] {
            var archive = ConfigurationArchive()
            archive.quicklinks = try QuicklinkLibrary(links: []).importJSON(JSONSerialization.data(withJSONObject: array)).links
            return Preview(archive: archive, warnings: ["这是 Quicklinks JSON，只迁移链接；不含全局设置、快捷键或别名。"])
        }
        guard let root = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw ConfigurationError("Raycast 数据格式无效。")
        }
        if root["settings"] != nil || root["quicklinks"] != nil ||
            (root["raycast_version"] == nil && root.values.contains { ($0 as? [String: Any])?["schemaVersion"] is Int }) {
            return try modern(root, applicationPaths: applicationPaths)
        }
        guard root["raycast_version"] is String else {
            throw ConfigurationError("无法识别 Raycast 备份格式。请从 Raycast 导出 .rayconfig 或 Quicklinks JSON。")
        }
        var archive = ConfigurationArchive(), warnings: [String] = ["旧版 CBC 备份没有认证保护；仅使用来源可信的文件。"]
        func object(_ root: [String: Any], _ key: String) -> [String: Any] { root[key] as? [String: Any] ?? [:] }
        let prefs = object(root, "builtin_package_raycastPreferences")
        let general = object(prefs, "preferencesGeneral"), appearance = object(prefs, "preferencesAppearance"), advanced = object(prefs, "preferencesAdvanced")
        if let mode = appearance["raycastPreferredWindowMode"] as? String {
            if ["compact", "expanded", "default"].contains(mode) { archive.preferences["windowMode"] = .string(mode == "compact" ? "compact" : "expanded") }
            else { warnings.append("已跳过不能对应的窗口模式。") }
        }
        if let navigation = advanced["navigationCommandStyleIdentifierKey"] as? String {
            if ["macos", "vim"].contains(navigation) { archive.preferences["navigation"] = .string(navigation == "macos" ? "arrows" : "vim") }
            else { warnings.append("已跳过不能对应的导航模式。") }
        }
        if let timeout = advanced["popToRootTimeout"] as? Int, [-1, 0, 30, 90, 300].contains(timeout) { archive.preferences["launcherReturnDelay"] = .integer(timeout) }
        var shortcuts: [String: Shortcut] = [:]
        if let raw = general["raycastGlobalHotkey"] as? String {
            if let shortcut = hotkey(raw) { shortcuts["launcher"] = shortcut }
            else { warnings.append("已跳过无法解码的全局热键。") }
        }
        let package = object(root, "builtin_package_quicklinks")
        var links: [Quicklink] = []
        if let rawLinks = package["quicklinks"] {
            guard let records = rawLinks as? [[String: Any]] else { throw ConfigurationError("Raycast Quicklinks 格式损坏。") }
            for record in records {
                guard let name = record["name"] as? String, let url = record["url"] as? String,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationError("Raycast Quicklink 记录损坏。") }
                // Stable identity makes repeated imports idempotent, even for backups without UUIDs.
                let source = (record["uuid"] as? String) ?? (name + "\u{0}" + url)
                let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
                var link = Quicklink(id: "quicklink:raycast:" + digest, title: name, template: url)
                do { _ = try link.parsedTemplate() } catch { warnings.append("已跳过包含不支持占位符或目标的 Quicklink。 "); continue }
                link.hiddenFromRoot = record["isEnabled"] as? Bool == false
                links.append(link)
            }
        }
        if !links.isEmpty { archive.quicklinks = links }
        let map = ["builtin_command_clipboardHistory": "clipboard", "builtin_command_searchEmoji": "emoji-symbols",
                   "builtin_command_lockScreen": "lock-screen", "builtin_command_openCamera": "show-camera"]
        let rootPackage = object(root, "builtin_package_rootSearch")
        if let records = rootPackage["rootSearch"] as? [[String: Any]] {
            for record in records {
                guard let raw = record["hotkey"] as? String, !raw.isEmpty else { continue }
                let key = record["key"] as? String ?? ""
                // Only explicitly verified built-in IDs are mapped. No guessing extension/app IDs.
                guard let id = map[key], let value = hotkey(raw) else { warnings.append("已跳过无法对应的命令热键。"); continue }
                if shortcuts.values.contains(value) { warnings.append("已跳过 Raycast 备份中的重复热键。"); continue }
                shortcuts[id] = value
            }
        }
        if !shortcuts.isEmpty { archive.shortcuts = shortcuts }
        let supported: Set<String> = ["raycast_version", "builtin_package_raycastPreferences", "builtin_package_quicklinks", "builtin_package_rootSearch"]
        let other = root.keys.filter { !supported.contains($0) }.count
        warnings.append("未迁移的其他数据分组：\(other)。不迁移别名/searchTerms、扩展及扩展设置/凭据、脚本、片段、笔记、AI、剪贴板、固定项和系统权限。")
        warnings.append("仅映射窗口模式、导航方式、支持的返回延迟、启动器及四个内置命令热键和 Quicklinks。其余偏好与命令映射不支持；不安装或执行任何扩展。")
        return Preview(archive: archive, warnings: warnings)
    }
    private static func modern(_ root: [String: Any], applicationPaths: Set<String>) throws -> Preview {
        var archive = ConfigurationArchive(), warnings: [String] = []
        var links: [Quicklink] = [], aliases: [String: String] = [:], shortcuts: [String: Shortcut] = [:], enabledCommands: [String: Bool] = [:]
        var skipped = 0
        // Deliberately small allowlist: no fuzzy name matching or extension namespace guessing.
        let commandIDs = ["builtin_command_clipboardHistory": "clipboard", "builtin_command_searchEmoji": "emoji-symbols",
                          "builtin_command_lockScreen": "lock-screen", "builtin_command_openCamera": "show-camera",
                          "c:r:clipboard-history::-::history": "clipboard", "c:r:clipboard-history::-::pasteSequential": "paste-sequentially",
                          "c:r:emoji-picker::-::searchEmoji": "emoji-symbols", "c:r:system::-::lockScreen": "lock-screen",
                          "c:r:raycast-core::-::openCamera": "show-camera"]
        for (name, raw) in root {
            guard let category = raw as? [String: Any], let version = category["schemaVersion"] as? Int else {
                warnings.append("有一个无法识别版本的数据类别，已跳过。"); continue
            }
            if name == "settings" {
                guard version == 1, let commands = category["commands"] as? [[String: Any]] else { warnings.append("设置类别版本或结构不支持，已跳过。"); continue }
                if let general = category["general"] as? [String: Any] {
                    let scalarKeys = ["appearance": "appearance", "windowMode": "windowMode", "navigationBindings": "navigation",
                                      "escapeKeyBehavior": "launcherEscapeBehavior", "pageNavigationKeys": "pageNavigationKeys",
                                      "rootSearchSensitivity": "rootSearchSensitivity", "windowActivationBehavior": "windowActivationBehavior"]
                    for (source, destination) in scalarKeys {
                        if let value = general[source] as? String {
                            if ConfigurationArchive.enums[destination]?.contains(value) == true { archive.preferences[destination] = .string(value) }
                            else { skipped += 1 }
                        }
                    }
                    if let value = general["escapeKeyClosesWindow"] as? Bool {
                        archive.preferences["escapeClosesUtilityWindows"] = .bool(value)
                    }
                    if let n = general["popToRootTimeout"] as? Int, [-1, 0, 30, 90, 300].contains(n) { archive.preferences["launcherReturnDelay"] = .integer(n) }
                    if let raw = general["globalHotkey"] as? [String: Any] {
                        if let value = modernHotkey(raw) { shortcuts["launcher"] = value } else { skipped += 1 }
                    }
                }
                warnings.append("检测到命令配置 \(commands.count) 项。仅迁移可靠对应的内置命令和已发现的应用；其余命令跳过。")
                for command in commands {
                    guard let sourceID = command["id"] as? String else { skipped += 1; continue }
                    let appPath = sourceID.components(separatedBy: "::=::").dropFirst().joined(separator: "::=::")
                    let knownApp = appPath.hasPrefix("/") && appPath.hasSuffix(".app") && applicationPaths.contains(appPath) ? appPath : nil
                    guard let id = commandIDs[sourceID] ?? knownApp else { skipped += 1; continue }
                    if let alias = command["alias"] as? String, !alias.isEmpty { aliases[id] = alias }
                    if let enabled = command["enabled"] as? Bool { enabledCommands[id] = enabled }
                    if let rawHotkey = command["macosHotkey"] as? [String: Any] {
                        if let value = modernHotkey(rawHotkey), !shortcuts.values.contains(value) { shortcuts[id] = value }
                        else { skipped += 1 }
                    }
                }
            } else if name == "quicklinks" {
                guard version == 1, let records = category["quicklinks"] as? [[String: Any]] else { warnings.append("Quicklinks 类别版本或结构不支持，已跳过。"); continue }
                warnings.append("检测到 Quicklinks \(records.count) 条。")
                for record in records {
                    guard let title = record["name"] as? String, let url = (record["link"] ?? record["url"]) as? String, !title.isEmpty else { skipped += 1; continue }
                    let identity = (record["id"] as? String) ?? (record["uuid"] as? String) ?? (title + "\u{0}" + url)
                    let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                    var link = Quicklink(id: "quicklink:raycast:" + digest, title: title, template: url)
                    do { _ = try link.parsedTemplate() } catch { skipped += 1; continue }
                    link.hiddenFromRoot = record["isEnabled"] as? Bool == false
                    links.append(link)
                }
            }

        }
        if !links.isEmpty { archive.quicklinks = links }
        if !aliases.isEmpty { archive.aliases = aliases }
        if !shortcuts.isEmpty { archive.shortcuts = shortcuts }
        if !enabledCommands.isEmpty { archive.commandEnabled = enabledCommands }
        warnings.append("跳过不能可靠对应或不支持的记录 \(skipped) 项。未映射的偏好、扩展 storedValues、笔记、脚本和权限不迁移。数据类别的转换结果在下方列出。")
        let categories = RaycastImportCategory.inventory(root)
        warnings += categories.map(\.summary)
        return Preview(archive: archive, warnings: warnings, categories: categories, data: RaycastMigrationData.parse(root))
    }
    private static func modernHotkey(_ raw: [String: Any]) -> Shortcut? {
        guard (raw["locality"] as? String)?.lowercased() == "global", let kind = raw["kind"] as? [String: Any],
              let shortcut = kind["shortcut"] as? [String: Any] else { return nil }
        if let type = kind["type"] as? String, !["shortcut", "SingleStep"].contains(type) { return nil }
        let key: Int?
        if let object = shortcut["key"] as? [String: Any] {
            guard ["code", "LayoutIndependent"].contains(object["type"] as? String ?? "") else { return nil }
            key = object["code"] as? Int
        }
        else { key = shortcut["key"] as? Int }
        guard let key, key >= 0, key < 128 else { return nil }
        let modifiers: [String]
        if let records = shortcut["modifiers"] as? [[String: Any]] {
            let parsed = records.compactMap { $0["modifier"] as? String }
            guard parsed.count == records.count else { return nil }
            modifiers = parsed
        } else if let strings = shortcut["modifiers"] as? [String] { modifiers = strings }
        else { return nil }
        return hotkey((modifiers + [String(key)]).joined(separator: "-"))
    }
    static func hotkey(_ raw: String) -> Shortcut? {
        let parts = raw.lowercased().split(separator: "-").map(String.init)
        guard let last = parts.last, let key = UInt32(last), key < 128 else { return nil }
        let map: [String: UInt32] = ["command": 256, "cmd": 256, "meta": 256, "shift": 512, "option": 2048, "alt": 2048, "control": 4096, "ctrl": 4096]
        var modifiers: UInt32 = 0
        for part in parts.dropLast() { guard let flag = map[part] else { return nil }; modifiers |= flag }
        let result = Shortcut(key: key, modifiers: modifiers)
        return ShortcutValidation.conflict(in: ["import": result]) == nil ? result : nil
    }
    private static func decrypt(_ input: Data, password: String) throws -> Data {
        // Raycast legacy backup: OpenSSL enc AES-256-CBC, unsalted EVP_BytesToKey,
        // then a short header and gzip JSON. Try both legacy digest defaults.
        if input.starts(with: Data("RAYCFG3".utf8)) { return try decryptV3(input, password: password) }
        if input.starts(with: Data("RAYCFG".utf8)) { throw ConfigurationError("不支持此 Raycast 备份版本。") }
        for md5 in [false, true] {
            var material = Data(), previous = Data()
            while material.count < 48 {
                let source = previous + Data(password.utf8)
                previous = md5 ? Data(Insecure.MD5.hash(data: source)) : Data(SHA256.hash(data: source))
                material.append(previous)
            }
            let key = material.prefix(32), iv = material.subdata(in: 32..<48)
            var output = Data(count: input.count + kCCBlockSizeAES128), written = 0
            let capacity = output.count
            let status = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { source in key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key.baseAddress, 32, iv.baseAddress, source.baseAddress, input.count, out.baseAddress, capacity, &written)
            } } } }
            guard status == kCCSuccess else { continue }
            output.count = written
            guard output.count >= 3 else { continue }
            for offset in 0..<min(64, output.count - 2) where output[offset] == 0x1f && output[offset + 1] == 0x8b && output[offset + 2] == 8 {
                if let data = try? gunzip(output.subdata(in: offset..<output.count)), (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
            }
        }
        throw ConfigurationError("密码错误、文件损坏或此 Raycast 加密格式不支持。未写入配置。")
    }
    private static func hex(_ text: String) -> Data? {
        guard text.count == 32 else { return nil }
        let bytes = Array(text.utf8)
        var result = Data()
        for i in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[i...i+1], as: UTF8.self), radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }
    private static func decryptV3(_ input: Data, password: String) throws -> Data {
        guard input.count > 28, input.prefix(8) == Data("RAYCFG3\n".utf8) else { throw ConfigurationError("Raycast RAYCFG3 文件头损坏。") }
        let count = Int(input[8]) | Int(input[9]) << 8 | Int(input[10]) << 16 | Int(input[11]) << 24
        guard count > 0, count <= 64 * 1024, 12 + count + 16 < input.count else { throw ConfigurationError("Raycast 文件头长度无效。") }
        let headerData = try gunzip(input.subdata(in: 12..<(12 + count)), maximumBytes: 64 * 1024)
        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["schemaVersion"] as? Int == 3,
              let encryption = header["encryption"] as? [String: Any],
              let saltString = encryption["salt"] as? String, let salt = hex(saltString), salt.count == 16,
              let ivString = encryption["iv"] as? String, let iv = hex(ivString), iv.count == 16 else {
            throw ConfigurationError("Raycast 加密参数不受支持。")
        }
        let key = try RaycastScrypt.derive(password: Data(password.utf8), salt: salt)
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: input.subdata(in: (12 + count)..<(input.count - 16)), tag: input.suffix(16))
        let compressed: Data
        do { compressed = try AES.GCM.open(sealed, using: SymmetricKey(data: key)) }
        catch { throw ConfigurationError("Raycast 备份认证失败：密码错误或文件已损坏。") }
        return try gunzip(compressed)
    }
    static func gunzip(_ input: Data, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ConfigurationError("无法解压备份。") }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(input.count)
            var result = Data(), status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: 32768)
                let produced = buffer.withUnsafeMutableBytes { out -> Int in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = 32768
                    status = inflate(&stream, Z_NO_FLUSH)
                    return 32768 - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END, result.count + produced <= maximumBytes, produced > 0 || status == Z_STREAM_END else { throw ConfigurationError("备份损坏或超过允许的解压大小。") }
                result.append(contentsOf: buffer.prefix(produced))
            } while status != Z_STREAM_END
            return result
        }
    }
}
