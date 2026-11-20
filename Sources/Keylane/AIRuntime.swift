import Foundation
import KeylaneCore

enum AIResponseMode: String, Codable, CaseIterable {
    case streaming, complete
}

enum AIModelTask: String, Codable, CaseIterable, Sendable {
    case text, openAITranscription, elevenLabsTranscription
    var title: String {
        switch self {
        case .text: "文字生成"
        case .openAITranscription: "语音转写（OpenAI 兼容）"
        case .elevenLabsTranscription: "语音转写（ElevenLabs）"
        }
    }
}

enum AIModelPurpose {
    case text, transcription, cloudText
    func accepts(_ connection: AIConnection) -> Bool {
        switch self {
        case .text: connection.taskKind == .text
        case .transcription: connection.transcriptionOptions() != nil
        case .cloudText: connection.taskKind == .text && connection.isCloudModel
        }
    }
}

struct AIConnection: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var endpoint = ""
    var model = ""
    var mode: AIResponseMode = .streaming
    var legacyAccount: String?
    var previousEndpoints: [String]?
    var hiddenFromPicker: Bool?
    var contextTokens: Int?
    var supportsImages: Bool?
    var supportsTools: Bool?
    var wireProtocol: AIWireProtocol?
    var providerID: String?
    var executablePath: String?
    var accountFolder: String?
    var subscriptionEnabled: Bool?
    var customConfigID: String?
    var additionalParametersJSON: String?
    var credentialOwnerID: UUID?
    var subscriptionAccountID: String?
    var modelTask: AIModelTask?

    var taskKind: AIModelTask {
        if protocolKind != .openAI { return .text }
        if let modelTask { return modelTask }
        let name = model.lowercased().split(separator: "/").last.map(String.init) ?? ""
        if providerID == "elevenlabs" || name == "scribe_v1" || name == "scribe_v2" || name == "scribe_v3" { return .elevenLabsTranscription }
        if name == "gpt-transcribe" || name == "gpt-transcribe-mini" || name == "gpt-4o-transcribe" || name == "gpt-4o-mini-transcribe"
            || name == "whisper-1" || name.hasPrefix("whisper-large-v3") { return .openAITranscription }
        return .text
    }
    var isCloudModel: Bool { !["ollama", "lmstudio"].contains(providerID ?? "") }

    func transcriptionOptions(language: String = "auto", vocabulary: [String] = []) -> AITranscriptionOptions? {
        guard isConfigured, isCloudModel, protocolKind == .openAI, taskKind != .text, let apiBaseURL else { return nil }
        let options = AITranscriptionOptions(provider: taskKind == .elevenLabsTranscription ? .elevenLabs : .openAI,
                                            endpoint: apiBaseURL.absoluteString, model: model, language: language, vocabulary: vocabulary)
        return options.isConfigured ? options : nil
    }

    var protocolKind: AIWireProtocol { wireProtocol ?? .openAI }
    var destinationLabel: String {
        if protocolKind.isSubscription {
            return "\(protocolKind == .codex ? "Codex" : "Claude Code") · \(accountFolder.flatMap { $0.isEmpty ? nil : $0 } ?? "默认账户目录")"
        }
        return transcriptionOptions()?.transcriptionURL?.absoluteString ?? completionURL?.absoluteString ?? endpoint
    }
    var requestIdentity: String {
        guard protocolKind.isSubscription else { return destinationLabel }
        return [protocolKind.rawValue, executablePath ?? "", accountFolder ?? "", subscriptionAccountID ?? ""].joined(separator: "\n")
    }

    var displayName: String { name.isEmpty ? model : name }
    var providerLabel: String {
        if protocolKind.isSubscription { return protocolKind == .codex ? "ChatGPT 订阅" : "Claude 订阅" }
        if let providerID, let preset = AIProviderPreset.all.first(where: { $0.id == providerID }) { return preset.name }
        guard let url = baseURL, let host = url.host else { return "无效接口" }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    var baseURL: URL? { Self.baseURL(for: endpoint) }
    var apiBaseURL: URL? {
        guard var url = baseURL else { return nil }
        for suffix in ["/chat/completions", "/audio/transcriptions", "/speech-to-text", "/messages"] where url.path.hasSuffix(suffix) {
            for _ in suffix.split(separator: "/") { url.deleteLastPathComponent() }
            break
        }
        return url
    }
    // Keep existing chat credential accounts stable; sibling models reuse the same provider key.
    var credentialURL: URL? {
        guard !protocolKind.isSubscription, let apiBaseURL else { return nil }
        return apiBaseURL.appendingPathComponent(protocolKind == .anthropic ? "messages" : "chat/completions")
    }

    private static func baseURL(for endpoint: String) -> URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()))
        else { return nil }
        return url
    }

    var completionURL: URL? {
        guard !protocolKind.isSubscription else { return nil }
        if protocolKind == .anthropic {
            guard let url = baseURL else { return nil }
            return url.path.hasSuffix("/messages") ? url : url.appendingPathComponent("messages")
        }
        return Self.completionURL(for: endpoint)
    }
    var modelsURL: URL? {
        apiBaseURL?.appendingPathComponent("models")
    }

    static func completionURL(for endpoint: String) -> URL? {
        guard let url = baseURL(for: endpoint) else { return nil }
        return url.path.hasSuffix("/chat/completions") ? url : url.appendingPathComponent("chat/completions")
    }

    /// Credential checks must not depend on access to a particular model.
    var keyVerificationURL: URL? {
        guard providerID == "openrouter", protocolKind == .openAI,
              let base = baseURL, base.scheme == "https", base.host == "openrouter.ai",
              base.port == nil || base.port == 443,
              base.path == "/api/v1" || base.path == "/api/v1/" else { return nil }
        return base.appendingPathComponent("key")
    }

    var isConfigured: Bool {
        isValidConfiguration && (!protocolKind.isSubscription || (subscriptionEnabled == true && model != "default"))
    }
    var isValidConfiguration: Bool {
        (protocolKind.isSubscription || baseURL != nil) && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AIMessage: Encodable, Sendable {
    enum Role: String, Encodable, Sendable { case system, user, assistant }
    let role: Role
    let content: String
}

private final class AIRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let first = task.originalRequest?.url, let next = request.url,
              !first.path.hasSuffix("/audio/transcriptions"), !first.path.hasSuffix("/speech-to-text"),
              first.scheme == next.scheme, first.host == next.host, first.port == next.port,
              next.user == nil, next.password == nil, task.originalRequest?.httpMethod == "POST", request.httpMethod == "POST"
        else { completionHandler(nil); return }
        completionHandler(request)
    }
}

actor AIRuntime {
    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private struct Payload: Encodable {
        let model: String
        let stream: Bool
        let messages: [AIMessage]
    }

    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: configuration, delegate: AIRedirectPolicy(), delegateQueue: nil)

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        self.configuration = configuration
    }

    func verifyAPIKey(connection: AIConnection, readKey: @Sendable (AIConnection) throws -> String?) async throws {
        guard let url = connection.keyVerificationURL else {
            _ = try await testConnection(connection, readKey: readKey)
            return
        }
        try Task.checkCancellation()
        guard let key = try readKey(connection), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIResponseError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request, connection: connection, key: key)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw AIResponseError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw AIResponseError.http(response.statusCode) }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < 65_536 else { throw AIResponseError.tooLarge }
            body.append(byte)
        }
        struct KeyEnvelope: Decodable {
            struct Info: Decodable { let label: String }
            let data: Info
        }
        guard (try? JSONDecoder().decode(KeyEnvelope.self, from: body)) != nil else {
            throw AIResponseError.invalidResponse
        }
        try Task.checkCancellation()
    }

    func listModels(connection: AIConnection, readKey: @Sendable (AIConnection) throws -> String?) async throws -> [String] {
        if connection.protocolKind.isSubscription {
            return try await AISubscriptionTransport.models(connection)
        }
        guard let url = connection.modelsURL else { throw AIResponseError.invalidResponse }
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request, connection: connection, key: try readKey(connection))
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw AIResponseError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw AIResponseError.http(response.statusCode) }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < 1_048_576 else { throw AIResponseError.tooLarge }
            body.append(byte)
        }
        let models: [String]
        if connection.taskKind == .elevenLabsTranscription {
            struct ElevenModel: Decodable { let model_id: String }
            guard let list = try? JSONDecoder().decode([ElevenModel].self, from: body) else { throw AIResponseError.invalidResponse }
            models = list.map(\.model_id).filter { $0.hasPrefix("scribe_") }
        } else {
            guard let list = try? JSONDecoder().decode(ModelList.self, from: body) else { throw AIResponseError.invalidResponse }
            models = list.data.map(\.id)
        }
        return Set(models.filter {
            !$0.isEmpty && $0.utf8.count <= 512 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }).sorted()
    }

    /// Audio and text requests share the same configured models, credentials, session and cancellation policy.
    func transcribe(audio: URL, connection: AIConnection, language: String = "auto", vocabulary: [String] = [],
                    readKey: @Sendable (AIConnection) throws -> String?) async throws -> String {
        guard let options = connection.transcriptionOptions(language: language, vocabulary: vocabulary) else { throw AITranscriptionError.configuration }
        try Task.checkCancellation()
        guard let key = try readKey(connection), !key.isEmpty else { throw AITranscriptionError.missingKey }
        let data = try await Task.detached(priority: .userInitiated) {
            let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= AITranscriptionRequest.maximumAudioBytes else { throw AITranscriptionError.audioTooLarge }
            return try Data(contentsOf: audio)
        }.value
        try Task.checkCancellation()
        let request = try AITranscriptionRequest.make(options: options, key: key, audio: data)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw AITranscriptionError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw AITranscriptionError.http(response.statusCode) }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < AITranscriptionRequest.maximumResponseBytes else { throw AITranscriptionError.responseTooLarge }
            body.append(byte)
        }
        return try AITranscriptionRequest.text(from: body, status: response.statusCode)
    }

    func testConnection(_ connection: AIConnection, readKey: @Sendable (AIConnection) throws -> String?) async throws -> String {
        if connection.taskKind == .text {
            _ = try await generate(connection: connection, readKey: readKey, messages: [.init(role: .user, content: "Reply with OK.")]) { _ in }
            return "模型已成功响应。"
        }
        if connection.taskKind == .elevenLabsTranscription {
            guard let url = connection.apiBaseURL?.appendingPathComponent("user"), let key = try readKey(connection), !key.isEmpty else {
                throw AITranscriptionError.missingKey
            }
            var request = URLRequest(url: url, timeoutInterval: 15)
            authorize(&request, connection: connection, key: key)
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw AIResponseError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw AIResponseError.http(response.statusCode) }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { throw AIResponseError.tooLarge }
                data.append(byte)
            }
            struct Account: Decodable { let user_id: String }
            guard let account = try? JSONDecoder().decode(Account.self, from: data), !account.user_id.isEmpty else { throw AIResponseError.invalidResponse }
            return "账户接口认证通过；实际语音识别与模型权限仍需在听写中实测。"
        }
        let models = try await listModels(connection: connection, readKey: readKey)
        guard !models.isEmpty else { throw AIResponseError.invalidResponse }
        return "提供方模型目录可访问；语音识别效果及模型权限仍需在听写中实测。"
    }

    func generate(connection: AIConnection, readKey: @Sendable (AIConnection) throws -> String?, messages: [AIMessage],
                  subscriptionReasoningEffort: String? = nil,
                  progress: @Sendable (AIResponseEvent) async -> Void = { _ in },
                  emit: @Sendable (String) async throws -> Void) async throws -> Int? {
        guard connection.taskKind == .text else { throw AIResponseError.invalidResponse }
        if connection.protocolKind.isSubscription {
            return try await AISubscriptionTransport.generate(connection, messages: messages, effort: subscriptionReasoningEffort, progress: progress, emit: emit)
        }
        guard let url = connection.completionURL, connection.isConfigured else { throw AIResponseError.invalidResponse }
        try Task.checkCancellation()
        let streaming = connection.mode == .streaming
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        authorize(&request, connection: connection, key: try readKey(connection))
        var body = connection.protocolKind == .anthropic
            ? try AnthropicAIProtocol.body(connection: connection, messages: messages)
            : try JSONEncoder().encode(Payload(model: connection.model, stream: streaming, messages: messages))
        if let parameters = connection.additionalParametersJSON,
           let data = parameters.data(using: .utf8),
           let extra = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           var payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            guard Set(extra.keys).isDisjoint(with: ["model", "messages", "stream", "tools", "tool_choice", "system"]) else {
                throw AIResponseError.invalidResponse
            }
            payload.merge(extra) { _, added in added }
            body = try JSONSerialization.data(withJSONObject: payload)
        }
        guard body.count <= 1_048_576 else { throw AIResponseError.requestTooLarge }
        request.httpBody = body
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw AIResponseError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw AIResponseError.http(response.statusCode) }
        if connection.protocolKind == .anthropic {
            return try await AnthropicAIProtocol.receive(bytes, streaming: streaming, progress: progress, emit: emit)
        }
        let limit = 1_048_576
        if !streaming {
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < limit else { throw AIResponseError.tooLarge }
                body.append(byte)
            }
            let reply = try JSONDecoder().decode(AICompletionEnvelope.self, from: body)
            guard !reply.failed else { throw AIResponseError.serviceError }
            guard let message = reply.choices?.first?.message else { throw AIResponseError.invalidResponse }
            var progressBuffer = OpenAIProgressBuffer()
            for event in try progressBuffer.events(message, delta: false) { await progress(event) }
            if progressBuffer.requestedTools { throw AIResponseError.toolsUnavailable }
            guard let text = message.content else { throw AIResponseError.invalidResponse }
            try Task.checkCancellation()
            try await emit(text)
            return reply.usage?.totalTokens
        }

        var parser = AIStreamDecoder()
        var progressBuffer = OpenAIProgressBuffer()
        var count = 0
        var usage: Int?
        var pending = ""
        var receivedText = false
        let clock = ContinuousClock()
        var nextUpdate = clock.now
        for try await byte in bytes {
            try Task.checkCancellation()
            count += 1
            guard count <= limit else { throw AIResponseError.tooLarge }
            if let event = try parser.consume(byte) {
                usage = event.usage?.totalTokens ?? usage
                if let metadata = event.choices?.first?.delta {
                    for update in try progressBuffer.events(metadata, delta: true) { await progress(update) }
                }
                if let delta = event.choices?.first?.delta?.content, !delta.isEmpty {
                    receivedText = true
                    pending += delta
                }
                if !pending.isEmpty, clock.now >= nextUpdate {
                    try await emit(pending)
                    pending = ""
                    nextUpdate = clock.now + .milliseconds(40)
                }
            }
            if parser.isDone { break }
        }
        if !pending.isEmpty { try await emit(pending) }
        try parser.validateEnd()
        if progressBuffer.requestedTools { throw AIResponseError.toolsUnavailable }
        guard receivedText else { throw AIResponseError.invalidResponse }
        return usage
    }

    private func authorize(_ request: inout URLRequest, connection: AIConnection, key: String?) {
        if connection.taskKind == .elevenLabsTranscription {
            if let key { request.setValue(key, forHTTPHeaderField: "xi-api-key") }
        } else if connection.protocolKind == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let key { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        } else if let key, !key.isEmpty {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
    }
}
