import Foundation
import KeylaneCore

enum AIResponseMode: String, Codable, CaseIterable {
    case streaming, complete
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

    var protocolKind: AIWireProtocol { wireProtocol ?? .openAI }
    var destinationLabel: String {
        if protocolKind.isSubscription {
            return "\(protocolKind == .codex ? "Codex" : "Claude Code") · \(accountFolder.flatMap { $0.isEmpty ? nil : $0 } ?? "默认账户目录")"
        }
        return completionURL?.absoluteString ?? endpoint
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
        guard let url = baseURL else { return nil }
        let prefix = url.path.hasSuffix("/chat/completions")
            ? url.deletingLastPathComponent().deletingLastPathComponent()
            : url.path.hasSuffix("/messages") ? url.deletingLastPathComponent() : url
        return prefix.appendingPathComponent("models")
    }

    static func completionURL(for endpoint: String) -> URL? {
        guard let url = baseURL(for: endpoint) else { return nil }
        return url.path.hasSuffix("/chat/completions") ? url : url.appendingPathComponent("chat/completions")
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
        guard let list = try? JSONDecoder().decode(ModelList.self, from: body) else { throw AIResponseError.invalidResponse }
        return Set(list.data.map(\.id).filter {
            !$0.isEmpty && $0.utf8.count <= 512 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }).sorted()
    }

    func generate(connection: AIConnection, readKey: @Sendable (AIConnection) throws -> String?, messages: [AIMessage],
                  emit: @Sendable (String) async throws -> Void) async throws -> Int? {
        if connection.protocolKind.isSubscription {
            return try await AISubscriptionTransport.generate(connection, messages: messages, emit: emit)
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
            return try await AnthropicAIProtocol.receive(bytes, streaming: streaming, emit: emit)
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
            guard let text = reply.choices?.first?.message?.content else { throw AIResponseError.invalidResponse }
            try Task.checkCancellation()
            try await emit(text)
            return reply.usage?.totalTokens
        }

        var parser = AIStreamDecoder()
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
        guard receivedText else { throw AIResponseError.invalidResponse }
        return usage
    }

    private func authorize(_ request: inout URLRequest, connection: AIConnection, key: String?) {
        if connection.protocolKind == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let key { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        } else if let key, !key.isEmpty {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
    }
}
