import Foundation

struct AppleNoteResult: Identifiable, Equatable {
    let id: String
    let title: String
}

enum AppleNotesAutomation {
    static func search(_ query: String) throws -> [AppleNoteResult] {
        let source = """
        set query to \(literal(query))
        tell application id "com.apple.Notes"
            if query is "" then
                set matches to every note
                set bodyMatches to {}
            else
                ignoring case and diacriticals
                    set matches to every note whose name contains query
                    set bodyMatches to every note whose password protected is false and plaintext contains query
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
        return try execute(source).split(separator: "\n").compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let title = String(line[line.index(after: tab)...])
            return AppleNoteResult(id: String(line[..<tab]), title: title.isEmpty ? "未命名" : title)
        }
    }

    static func show(_ id: String) throws {
        _ = try execute("""
        tell application id "com.apple.Notes"
            set selectedID to \(literal(id))
            if selectedID is in my deletedNoteIDs() then error number -1728
            show note id selectedID with separately
            activate
        end tell
        """)
    }

    static func create(title: String, body: String) throws -> String {
        let heading = title.isEmpty ? "" : "<div><b>\(html(title))</b></div>"
        let content = heading + "<div>\(html(body))</div>"
        let id = try execute("""
        tell application id "com.apple.Notes"
            set targetFolder to default folder of default account
            set createdNote to make new note at targetFolder with properties {body:\(literal(content))}
            return id of createdNote
        end tell
        """)
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
            case -128: return "备忘录操作已取消。"
            default: return "无法完成备忘录操作。请打开 Apple 备忘录检查账户后重试。"
            }
        }
    }

    private static func execute(_ source: String) throws -> String {
        // Pass the script over stdin so queries and drafts never appear in process arguments.
        let script = """
        on deletedNoteIDs()
            tell application id "com.apple.Notes"
                set deletedIDs to {}
                repeat with folderName in {"Recently Deleted", "最近删除", "最近刪除"}
                    set foldersFound to every folder whose name is (contents of folderName)
                    repeat with deletedFolder in foldersFound
                        set deletedIDs to deletedIDs & (id of every note of deletedFolder)
                    end repeat
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
        try process.run()
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
        let value = result.trimmingCharacters(in: .newlines)
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
