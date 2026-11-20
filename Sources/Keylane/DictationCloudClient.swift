import Foundation
import KeylaneCore

private final class DictationRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // An audio upload and its credential never follow an HTTP redirect.
        completionHandler(nil)
    }
}

struct DictationCloudClient {
    var configuration: URLSessionConfiguration = .ephemeral
    var readKey: @Sendable (DictationOptions) throws -> String? = { try DictationCredentials.read($0) }
    func transcribe(audio: URL, options: DictationOptions) async throws -> String {
        let data = try await Task.detached(priority: .userInitiated) {
            let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= DictationCloudRequest.maximumAudioBytes else { throw DictationError.audioTooLarge }
            return try Data(contentsOf: audio)
        }.value
        try Task.checkCancellation()
        guard let key = try readKey(options) else { throw DictationError.missingKey }
        let request = try DictationCloudRequest.make(options: options, key: key, audio: data)
        let config = configuration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 240
        let session = URLSession(configuration: config, delegate: DictationRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw DictationError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw DictationError.http(response.statusCode) }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < DictationCloudRequest.maximumResponseBytes else { throw DictationError.responseTooLarge }
            body.append(byte)
        }
        struct Reply: Decodable { let text: String }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: body) else { throw DictationError.invalidResponse }
        guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DictationError.emptyTranscript }
        return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
