import Foundation

/// Request configuration is derived from the shared AI model catalog, never stored by a feature.
public enum AITranscriptionAPI: String, Codable, CaseIterable, Sendable {
    case openAI, elevenLabs
}

public struct AITranscriptionOptions: Sendable {
    public var provider: AITranscriptionAPI
    public var endpoint: String
    public var model: String
    public var language: String
    public var vocabulary: [String]
    public init(provider: AITranscriptionAPI = .openAI, endpoint: String = "https://api.openai.com/v1",
                model: String = "gpt-transcribe", language: String = "auto", vocabulary: [String] = []) {
        self.provider = provider; self.endpoint = endpoint; self.model = model
        self.language = language; self.vocabulary = vocabulary
    }
    public var transcriptionURL: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()))
        else { return nil }
        let suffix = provider == .elevenLabs ? "speech-to-text" : "audio/transcriptions"
        return url.path.hasSuffix("/" + suffix) ? url : url.appendingPathComponent(suffix)
    }
    public var isConfigured: Bool {
        transcriptionURL != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.utf8.count <= 256 && model.rangeOfCharacter(from: .controlCharacters) == nil
    }
    public var validVocabulary: [String] { Self.sanitizedVocabulary(vocabulary) }
    public static func sanitizedVocabulary(_ vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        return vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 20 && $0.rangeOfCharacter(from: .controlCharacters) == nil && seen.insert($0).inserted }
            .prefix(50).map { $0 }
    }
}
