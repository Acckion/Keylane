import Foundation

struct AppleNoteResult: Identifiable, Equatable {
    let id: String
    let title: String
}

enum AppleNotesAutomation {
    static func search(_ query: String, request: ExtensionProcessRequest, titlesOnly: Bool = false) throws -> [AppleNoteResult] {
        let source = """
        set query to \(literal(query))
        tell application id "com.apple.Notes"
            if query is "" then
                set matches to every note\(titlesOnly ? " whose password protected is false" : "")
                set bodyMatches to {}
            else
                ignoring case and diacriticals
                    set matches to every note whose name contains query\(titlesOnly ? " and password protected is false" : "")
                    \(titlesOnly ? "set bodyMatches to {}" : "set bodyMatches to every note whose password protected is false and plaintext contains query")
                end ignoring
            end if
            set deletedIDs to my deletedNoteIDs()
            set seenIDs to {}
            set output to ""
            repeat with aNote in (matches & bodyMatches)
                if (count of seenIDs) ≥ 60 then exit repeat
                set noteID to id of aNote
                if noteID is not in seenIDs and noteID is not in deletedIDs then
                    set end of seenIDs to noteID
                    set output to output & noteID & tab & my singleLine(name of aNote) & linefeed
                end if
            end repeat
            return output
        end tell
        """
        return try execute(source, request: request).split(separator: "\n").compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let title = String(line[line.index(after: tab)...])
            return AppleNoteResult(id: String(line[..<tab]), title: title.isEmpty ? "未命名" : title)
        }
    }

    /// Read one selected, unlocked, non-deleted note. Never request an unlock or enumerate bodies.
    static func readText(_ id: String, request: ExtensionProcessRequest,
                         run: ((String, ExtensionProcessRequest) throws -> String)? = nil) throws -> String {
        let script = """
        tell application id "com.apple.Notes"
            set selectedID to \(literal(id))
            if selectedID is in my deletedNoteIDs() then error number -1728
            set selectedNote to note id selectedID
            if password protected of selectedNote then error number -10006
            set selectedText to plaintext of selectedNote
            if (length of selectedText) > 32000 then error number -2750
            return "KEYLANE_TEXT:" & selectedText
        end tell
        """
        let value = try run?(script, request) ?? execute(script, request: request, preservingText: true)
        guard value.hasPrefix("KEYLANE_TEXT:") else { throw Failure(code: 0) }
        let text = String(value.dropFirst("KEYLANE_TEXT:".count))
        guard text.utf8.count <= 32_000 else { throw Failure(code: -2750) }
        return text
    }

    static func show(_ id: String, request: ExtensionProcessRequest) throws {
        _ = try execute("""
        tell application id "com.apple.Notes"
            set selectedID to \(literal(id))
            if selectedID is in my deletedNoteIDs() then error number -1728
            show note id selectedID with separately
            activate
        end tell
        """, request: request)
    }

    static func create(title: String, body: String, request: ExtensionProcessRequest) throws -> String {
        let heading = title.isEmpty ? "" : "<div><b>\(html(title))</b></div>"
        let content = heading + "<div>\(html(body))</div>"
        let id = try execute("""
        tell application id "com.apple.Notes"
            set targetFolder to default folder of default account
            set createdNote to make new note at targetFolder with properties {body:\(literal(content))}
            return id of createdNote
        end tell
        """, request: request)
        guard !id.isEmpty else { throw Failure(code: 0) }
        return id
    }

    struct Failure: LocalizedError {
        let code: Int
        var errorDescription: String? {
            switch code {
            case -1743, -1744: return "请在「系统设置 → 隐私与安全性 → 自动化」中允许 Keylane 控制备忘录。"
            case -1712: return "备忘录响应超时。若系统正在请求授权，请先完成授权。"
            case -1728: return "备忘录或默认文件夹已不可用。请在 Apple 备忘录中检查。"
            case -10006: return "不能读取受密码保护的备忘录，请选择其他笔记。"
            case -2750: return "备忘录文字超过本次处理上限，请缩小范围。"
            case -128: return "备忘录操作已取消。"
            default: return "无法完成备忘录操作。请打开 Apple 备忘录检查账户后重试。"
            }
        }
    }

    static let recentlyDeletedFolderNames: [String] = {
        // Read the system's translations without loading any Notes framework code.
        let path = "/System/Library/PrivateFrameworks/NotesShared.framework"
        guard let resources = Bundle(path: path) else { return [] }
        let key = "Recently Deleted"
        let names = Set(resources.localizations.map { localization in
            resources.localizedString(forKey: key, value: key, table: nil,
                                      localizations: [Locale.Language(identifier: localization)])
        })
        // A bundle with no translated matches may be missing the string table.
        guard names.contains(where: { $0 != key }) else { return [] }
        return names.union([key]).sorted()
    }()

    private static func execute(_ source: String, request: ExtensionProcessRequest, preservingText: Bool = false) throws -> String {
        // Pass the script over stdin so queries and drafts never appear in process arguments.
        let folderNames = recentlyDeletedFolderNames.map(literal).joined(separator: ", ")
        let script = """
        on deletedNoteIDs()
            set localizedNames to {\(folderNames)}
            if localizedNames is {} then error number -2700
            tell application id "com.apple.Notes"
                set deletedIDs to {}
                set availableNames to name of every folder
                repeat with folderName in localizedNames
                    if (contents of folderName) is in availableNames then
                        set foldersFound to every folder whose name is (contents of folderName)
                        repeat with deletedFolder in foldersFound
                            set deletedIDs to deletedIDs & (id of every note of deletedFolder)
                        end repeat
                    end if
                end repeat
                return deletedIDs
            end tell
        end deletedNoteIDs
        on singleLine(value)
            set AppleScript's text item delimiters to {tab, return, linefeed}
            set segments to text items of value
            set AppleScript's text item delimiters to " "
            set output to segments as text
            set AppleScript's text item delimiters to ""
            return output
        end singleLine
        try
            with timeout of 12 seconds
                \(source)
            end timeout
        on error ignoredMessage number errorNumber
            return "KEYLANE_ERROR:" & errorNumber
        end try
        """
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try request.launch(process)
        defer { request.finished() }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            throw Failure(code: 0)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let result = String(data: data, encoding: .utf8) else { throw Failure(code: 0) }
        let value = preservingText ? (result.hasSuffix("\n") ? String(result.dropLast()) : result) : result.trimmingCharacters(in: .newlines)
        let prefix = "KEYLANE_ERROR:"
        if value.hasPrefix(prefix) { throw Failure(code: Int(value.dropFirst(prefix.count)) ?? 0) }
        return value
    }

    private static func literal(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\0", with: "")
        return "\"" + escaped + "\""
    }

    private static func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
