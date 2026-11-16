import Foundation

public struct ScriptMetadata: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case silent, compact, fullOutput, inline
    }

    public struct Argument: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable { case text, password, dropdown }
        public struct Choice: Codable, Equatable, Sendable {
            public var title: String
            public var value: String
            public init(title: String, value: String) { self.title = title; self.value = value }
        }

        public var type: Kind
        public var placeholder: String
        public var optional: Bool?
        public var percentEncoded: Bool?
        public var data: [Choice]?
        private var secure: Bool?

        public init(type: Kind = .text, placeholder: String, optional: Bool? = nil,
                    percentEncoded: Bool? = nil, data: [Choice]? = nil) {
            self.type = type
            self.placeholder = placeholder
            self.optional = optional
            self.percentEncoded = percentEncoded
            self.data = data
        }

        private enum CodingKeys: String, CodingKey {
            case type, placeholder, optional, percentEncoded, data, secure
        }

        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            type = try fields.decodeIfPresent(Kind.self, forKey: .type) ?? .text
            placeholder = try fields.decode(String.self, forKey: .placeholder)
            optional = try fields.decodeIfPresent(Bool.self, forKey: .optional)
            percentEncoded = try fields.decodeIfPresent(Bool.self, forKey: .percentEncoded)
            data = try fields.decodeIfPresent([Choice].self, forKey: .data)
            secure = try fields.decodeIfPresent(Bool.self, forKey: .secure)
        }

        public var kind: Kind { secure == true && type == .text ? .password : type }

        public func value(_ input: String) throws -> String {
            guard !input.isEmpty || optional == true else { throw ValidationError.required(placeholder) }
            if kind == .dropdown, !input.isEmpty, data?.contains(where: { $0.value == input }) != true {
                throw ValidationError.invalidChoice(placeholder)
            }
            guard percentEncoded == true else { return input }
            let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            return input.addingPercentEncoding(withAllowedCharacters: unreserved) ?? input
        }
    }

    public enum ValidationError: LocalizedError {
        case invalidHeader, required(String), invalidChoice(String)
        public var errorDescription: String? {
            switch self {
            case .invalidHeader: return "脚本元数据无效或不支持此平台。"
            case .required(let field): return "请填写「\(field)」。"
            case .invalidChoice(let field): return "请为「\(field)」选择有效选项。"
            }
        }
    }

    public var title = ""
    public var mode: Mode = .silent
    public var description = ""
    public var packageName = ""
    public var author = ""
    public var authorURL = ""
    public var icon = ""
    public var iconDark = ""
    public var currentDirectoryPath = ""
    public var needsConfirmation = false
    public var refreshTime = ""
    public var arguments: [Argument] = []

    public init() {}

    public var refreshInterval: TimeInterval? {
        let text = refreshTime.lowercased()
        guard let unit = text.last, let value = Double(text.dropLast()), value.isFinite, value > 0,
              let multiplier = ["s": 1.0, "m": 60, "h": 3600, "d": 86400][String(unit)],
              (value * multiplier).isFinite else { return nil }
        return max(10, value * multiplier)
    }

    public var effectiveMode: Mode {
        mode == .inline && (refreshInterval == nil || !arguments.isEmpty) ? .compact : mode
    }

    public static func parse(_ source: String) throws -> Self? {
        var keylaneFields: [String: String] = [:]
        var raycastFields: [String: String] = [:]
        for line in source.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let marker = ["#", "//", "--", ";"].first(where: text.hasPrefix) else { continue }
            let comment = text.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            let parts = comment.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if parts[0].hasPrefix("@keylane.") {
                keylaneFields[String(parts[0].dropFirst("@keylane.".count))] = value
            } else if parts[0].hasPrefix("@raycast.") {
                raycastFields[String(parts[0].dropFirst("@raycast.".count))] = value
            }
        }
        let fields = raycastFields.merging(keylaneFields) { _, native in native }
        guard !fields.isEmpty else { return nil }
        guard fields["schemaVersion"] == "1", let title = fields["title"], !title.isEmpty,
              let rawMode = fields["mode"], let mode = Mode(rawValue: rawMode),
              (fields["platform"] ?? "macos").lowercased() == "macos" else { throw ValidationError.invalidHeader }
        var result = Self()
        result.title = title
        result.mode = mode
        result.description = fields["description"] ?? ""
        result.packageName = fields["packageName"] ?? ""
        result.author = fields["author"] ?? ""
        result.authorURL = fields["authorURL"] ?? ""
        result.icon = fields["icon"] ?? ""
        result.iconDark = fields["iconDark"] ?? ""
        result.currentDirectoryPath = fields["currentDirectoryPath"] ?? ""
        result.needsConfirmation = fields["needsConfirmation"]?.lowercased() == "true"
        result.refreshTime = fields["refreshTime"] ?? ""
        for index in 1...3 {
            guard let raw = fields["argument\(index)"] else { continue }
            guard index == result.arguments.count + 1,
                  let argument = try? JSONDecoder().decode(Argument.self, from: Data(raw.utf8)),
                  !argument.placeholder.isEmpty,
                  argument.kind != .dropdown || argument.data?.isEmpty == false else {
                throw ValidationError.invalidHeader
            }
            if argument.kind == .dropdown,
               let values = argument.data?.map(\.value),
               values.contains("") || Set(values).count != values.count {
                throw ValidationError.invalidHeader
            }
            result.arguments.append(argument)
        }
        return result
    }

    public func header(comment: String) throws -> String {
        let clean = { (value: String) in value.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
        let title = clean(title)
        guard !title.isEmpty, arguments.count <= 3 else { throw ValidationError.invalidHeader }
        var fields = [("schemaVersion", "1"), ("title", title), ("mode", mode.rawValue)]
        fields += [("description", description), ("packageName", packageName), ("author", author), ("authorURL", authorURL),
                   ("icon", icon), ("iconDark", iconDark), ("currentDirectoryPath", currentDirectoryPath),
                   ("refreshTime", mode == .inline ? refreshTime : "")]
        if needsConfirmation { fields.append(("needsConfirmation", "true")) }
        for (index, argument) in arguments.enumerated() {
            let json = try JSONEncoder().encode(argument)
            fields.append(("argument\(index + 1)", String(decoding: json, as: UTF8.self)))
        }
        return fields.compactMap { key, value in
            let value = clean(value)
            return value.isEmpty ? nil : "\(comment) @keylane.\(key) \(value)"
        }.joined(separator: "\n")
    }
}

public enum ScriptTemplate: String, CaseIterable, Sendable {
    case bash, zsh, sh, appleScript, swift, python, node, typescript, go, ruby, csharp, php, powerShell

    public var title: String {
        switch self {
        case .bash: "Shell (Bash)"
        case .zsh: "Shell (Zsh)"
        case .sh: "Shell (sh)"
        case .python: "Python 3"
        case .node: "JavaScript (Node.js)"
        case .typescript: "TypeScript (Node.js)"
        case .go: "Go"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .swift: "Swift"
        case .appleScript: "AppleScript"
        case .csharp: "C# (.NET 10)"
        case .powerShell: "PowerShell"
        }
    }

    public var fileExtension: String {
        switch self {
        case .python: "py"
        case .node: "js"
        case .typescript: "ts"
        case .ruby: "rb"
        case .appleScript: "applescript"
        case .csharp: "cs"
        case .powerShell: "ps1"
        default: rawValue
        }
    }

    public func create(at url: URL, metadata: ScriptMetadata) throws {
        let prefix: String
        let comment: String
        let body: String
        switch self {
        case .bash, .zsh, .sh:
            (prefix, comment, body) = ("#!/bin/\(rawValue)", "#", "printf '%s\\n' 'Hello from Keylane'")
        case .python: (prefix, comment, body) = ("#!/usr/bin/env python3", "#", "print('Hello from Keylane')")
        case .node: (prefix, comment, body) = ("#!/usr/bin/env node", "//", "console.log('Hello from Keylane');")
        case .typescript:
            (prefix, comment, body) = ("#!/usr/bin/env node", "//", "const message: string = \"Hello from Keylane\";\nconsole.log(message);")
        case .go:
            (prefix, comment, body) = ("", "//", "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Hello from Keylane\")\n}")
        case .ruby: (prefix, comment, body) = ("#!/usr/bin/env ruby", "#", "puts 'Hello from Keylane'")
        case .php: (prefix, comment, body) = ("<?php", "//", "echo \"Hello from Keylane\\n\";")
        case .swift: (prefix, comment, body) = ("#!/usr/bin/swift", "//", "print(\"Hello from Keylane\")")
        case .appleScript: (prefix, comment, body) = ("#!/usr/bin/osascript", "--", "return \"Hello from Keylane\"")
        case .csharp: (prefix, comment, body) = ("#!/usr/bin/env -S dotnet --", "//", "System.Console.WriteLine(\"Hello from Keylane\");")
        case .powerShell: (prefix, comment, body) = ("#!/usr/bin/env pwsh", "#", "Write-Output 'Hello from Keylane'")
        }
        let destinationExtension = url.pathExtension.lowercased()
        guard destinationExtension == fileExtension || (self == .node && ["mjs", "cjs"].contains(destinationExtension)) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: url.path])
        }
        let header = try metadata.header(comment: comment)
        let source = [prefix, header, body].filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
        _ = try ScriptMetadata.parse(source)
        try Data(source.utf8).write(to: url, options: .withoutOverwriting)
    }
}
