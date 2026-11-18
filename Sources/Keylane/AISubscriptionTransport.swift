import Foundation
import KeylaneCore

struct AISubscriptionStatus: Sendable {
    struct Window: Identifiable, Sendable {
        let id: String
        let usedPercent: Double
        let resetsAt: Date?
    }
    var account = ""
    var accountID = ""
    var windows: [Window] = []
    var availableResets: Int?
    var updated = Date()
}

enum AISubscriptionTransport {
    enum Operation {
        case account, models, usage, reset(String, expectedAccountID: String), generate([AIMessage])
    }

    static func models(_ connection: AIConnection) async throws -> [String] {
        if connection.protocolKind == .claudeCode { return ["sonnet", "opus", "haiku"] }
        let result = try await codex(connection, operation: .models) { _ in }
        return (result["data"] as? [[String: Any]] ?? []).compactMap { $0["model"] as? String }
    }

    static func status(_ connection: AIConnection, usage: Bool = false) async throws -> AISubscriptionStatus {
        let result: [String: Any]
        if connection.protocolKind == .codex {
            result = try await codex(connection, operation: usage ? .usage : .account) { _ in }
        } else {
            let output = try await claude(connection, arguments: ["auth", "status", "--json"], input: nil) { _ in }
            guard let data = output.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  parsed["loggedIn"] as? Bool == true, parsed["authMethod"] as? String == "claude.ai" else {
                throw AISubscriptionError.failed
            }
            result = parsed
        }
        if !usage {
            let account = result["account"] as? [String: Any] ?? result
            guard connection.protocolKind != .codex || account["type"] as? String == "chatgpt" else { throw AISubscriptionError.failed }
            let fields = ["email", "planType", "subscriptionType"].compactMap { account[$0] as? String }
            return AISubscriptionStatus(account: fields.isEmpty ? "已登录" : fields.joined(separator: " · "),
                                        accountID: account["email"] as? String ?? "")
        }
        let account = result["checkedAccount"] as? [String: Any] ?? [:]
        var status = AISubscriptionStatus(account: account["email"] as? String ?? "", accountID: account["email"] as? String ?? "")
        if let limits = result["rateLimits"] as? [String: Any] {
            for (key, label) in [("primary", "主要额度"), ("secondary", "周期额度")] {
                if let window = limits[key] as? [String: Any], let used = window["usedPercent"] as? Double {
                    status.windows.append(.init(id: label, usedPercent: min(100, max(0, used)),
                                                resetsAt: (window["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))))
                }
            }
        }
        status.availableResets = (result["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? Int
        return status
    }

    static func reset(_ connection: AIConnection, expectedAccountID: String, idempotencyKey: String) async throws {
        guard !expectedAccountID.isEmpty, connection.subscriptionAccountID == expectedAccountID else {
            throw AISubscriptionError.accountChanged
        }
        let result = try await codex(connection, operation: .reset(idempotencyKey, expectedAccountID: expectedAccountID)) { _ in }
        guard ["reset", "alreadyRedeemed"].contains(result["outcome"] as? String ?? "") else { throw AISubscriptionError.failed }
    }

    static func generate(_ connection: AIConnection, messages: [AIMessage],
                         emit: @Sendable (String) async throws -> Void) async throws -> Int? {
        guard connection.isConfigured else { throw AISubscriptionError.failed }
        guard let expected = connection.subscriptionAccountID, !expected.isEmpty else { throw AISubscriptionError.accountChanged }
        if connection.protocolKind == .codex {
            // Check in the process that will receive the conversation, not a preflight process.
            _ = try await codex(connection, operation: .generate(messages), emit: emit)
            return nil
        }
        let account = try await status(connection)
        guard expected == account.accountID else { throw AISubscriptionError.accountChanged }
        let prompt = transcript(messages)
        let output = try await claude(connection, arguments: [
            "--print", "--output-format", "json", "--model", connection.model, "--tools", "",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "",
            "--settings", "{\"disableAllHooks\":true}", "--disable-slash-commands", "--no-chrome",
            "--no-session-persistence", "--permission-mode", "dontAsk",
            "--system-prompt", "Answer the supplied conversation. Use only the supplied text."
        ], input: prompt) { _ in }
        guard let data = output.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["is_error"] as? Bool != true, let text = result["result"] as? String, !text.isEmpty else {
            throw AISubscriptionError.failed
        }
        try await emit(text)
        return AnthropicAIProtocol.tokenTotal(result["usage"])
    }

    private static func verifiedAccount(_ result: [String: Any], expected: String?) throws -> [String: Any] {
        guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt",
              let id = account["email"] as? String, !id.isEmpty,
              expected == nil || expected == id else { throw AISubscriptionError.accountChanged }
        return account
    }

    private static func transcript(_ messages: [AIMessage]) -> String {
        messages.map { "<\($0.role.rawValue)>\n\($0.content)\n</\($0.role.rawValue)>" }.joined(separator: "\n")
    }

    private static func codex(_ connection: AIConnection, operation: Operation,
                              emit: @Sendable (String) async throws -> Void) async throws -> [String: Any] {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try AICLIProcess(connection: connection, arguments: [
            "app-server", "--stdio", "-c", "model_provider=\"openai\"", "-c", "mcp_servers={}",
            "-c", "web_search=\"disabled\"", "-c", "features.shell_tool=false", "-c", "features.apps=false",
            "-c", "features.multi_agent=false", "-c", "features.hooks=false", "-c", "features.view_image=false",
            "-c", "features.image_generation=false", "-c", "features.skill_search=false",
            "-c", "features.shell_snapshot=false"
        ], directory: directory)
        return try await withTaskCancellationHandler {
            let stream = try process.start()
            defer { process.stop() }
            let timeout = Task {
                try await Task.sleep(for: .seconds(300))
                process.stop(error: AISubscriptionError.timeout)
            }
            defer { timeout.cancel() }
            try process.send(["id": 0, "method": "initialize", "params": [
                "clientInfo": ["name": "keylane", "version":
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"]]])
            var checkedAccount: [String: Any]?
            var buffer = Data()
            var receivedText = false
            var pendingText = ""
            let clock = ContinuousClock()
            var nextUpdate = clock.now
            var modelPages = [[String: Any]]()
            var cursors = Set<String>()
            for try await chunk in stream {
                try Task.checkCancellation()
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw AISubscriptionError.failed
                    }
                    if message["error"] != nil { throw AISubscriptionError.unsupported }
                    if let id = message["id"] as? Int, let result = message["result"] as? [String: Any] {
                        if id == 0 {
                            try process.send(["method": "initialized", "params": [:]])
                            let method: String
                            var params: [String: Any] = [:]
                            switch operation {
                            case .account: method = "account/read"; params = ["refreshToken": false]
                            case .models: method = "model/list"; params = ["limit": 100, "includeHidden": false]
                            case .usage, .reset: method = "account/read"; params = ["refreshToken": false]
                            case .generate: method = "account/read"; params = ["refreshToken": false]
                            }
                            try process.send(["id": 1, "method": method, "params": params])
                        } else if id == 1 {
                            if case .models = operation {
                                modelPages += result["data"] as? [[String: Any]] ?? []
                                if let cursor = result["nextCursor"] as? String {
                                    guard cursors.count < 20, cursors.insert(cursor).inserted else { throw AISubscriptionError.failed }
                                    try process.send(["id": 1, "method": "model/list",
                                                      "params": ["limit": 100, "includeHidden": false, "cursor": cursor]])
                                } else { return ["data": modelPages] }
                            } else if case .usage = operation {
                                checkedAccount = try verifiedAccount(result, expected: nil)
                                try process.send(["id": 3, "method": "account/rateLimits/read", "params": [:]])
                            } else if case .reset(let key, let expected) = operation {
                                checkedAccount = try verifiedAccount(result, expected: expected)
                                try process.send(["id": 3, "method": "account/rateLimitResetCredit/consume",
                                                  "params": ["idempotencyKey": key]])
                            } else if case .generate = operation {
                                checkedAccount = try verifiedAccount(result, expected: connection.subscriptionAccountID)
                                try process.send(["id": 4, "method": "thread/start", "params": [
                                    "model": connection.model, "modelProvider": "openai", "cwd": directory.path,
                                    "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true,
                                    "baseInstructions": "Answer the supplied conversation using only its text.",
                                    "config": ["mcp_servers": [:], "web_search": "disabled"]]])
                            } else { return result }
                        } else if id == 4, case .generate(let messages) = operation, checkedAccount != nil {
                            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                                throw AISubscriptionError.failed
                            }
                            try process.send(["id": 2, "method": "turn/start", "params": [
                                "threadId": id, "input": [["type": "text", "text": transcript(messages)]]]])
                        } else if id == 3, let checkedAccount {
                            var response = result
                            response["checkedAccount"] = checkedAccount
                            return response
                        }
                    } else if let method = message["method"] as? String, let params = message["params"] as? [String: Any] {
                        if message["id"] != nil { throw AISubscriptionError.unsupported }
                        if method == "account/updated", checkedAccount != nil {
                            switch operation {
                            case .generate, .reset: throw AISubscriptionError.accountChanged
                            default: break
                            }
                        }
                        if method == "item/agentMessage/delta", let delta = params["delta"] as? String {
                            receivedText = true
                            pendingText += delta
                            if clock.now >= nextUpdate {
                                try await emit(pendingText)
                                pendingText = ""
                                nextUpdate = clock.now + .milliseconds(40)
                            }
                        } else if method == "turn/completed" {
                            if !pendingText.isEmpty { try await emit(pendingText) }
                            guard receivedText, (params["turn"] as? [String: Any])?["status"] as? String == "completed" else {
                                throw AISubscriptionError.failed
                            }
                            return [:]
                        }
                    }
                }
            }
            throw AISubscriptionError.failed
        } onCancel: { process.stop(error: CancellationError()) }
    }

    private static func claude(_ connection: AIConnection, arguments: [String], input: String?,
                               emit: @Sendable (String) async throws -> Void) async throws -> String {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try AICLIProcess(connection: connection, arguments: arguments, directory: directory)
        return try await withTaskCancellationHandler {
            let stream = try process.start()
            defer { process.stop() }
            let timeout = Task {
                try await Task.sleep(for: .seconds(300))
                process.stop(error: AISubscriptionError.timeout)
            }
            defer { timeout.cancel() }
            if let input { try process.sendText(input) }
            else { try process.sendText("") }
            var output = Data()
            for try await data in stream { try Task.checkCancellation(); output.append(data) }
            guard let text = String(data: output, encoding: .utf8) else { throw AISubscriptionError.failed }
            return text
        } onCancel: { process.stop(error: CancellationError()) }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneAI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }
}
