import AppKit
import ApplicationServices
import Foundation
import KeylaneCore

/// The same image blocks feed ordinary and tool-enabled HTTP requests.
extension AIMessage {
    struct ImageBlock: Encodable {
        let type: String
        var text: String?
        var image_url: [String: String]?
        var source: [String: String]?
    }
    func blocks(anthropic: Bool) -> [ImageBlock] {
        [.init(type: "text", text: content)] + images.map { image in
            let base64 = image.data.base64EncodedString()
            if anthropic {
                return .init(type: "image", source: ["type": "base64", "media_type": image.mediaType, "data": base64])
            }
            return .init(type: "image_url", image_url: ["url": "data:\(image.mediaType);base64,\(base64)"])
        }
    }
    func wireValue(anthropic: Bool) throws -> [String: Any] {
        let value: Any = images.isEmpty ? content : try JSONSerialization.jsonObject(with: JSONEncoder().encode(blocks(anthropic: anthropic)))
        return ["role": role.rawValue, "content": value]
    }
}

enum AIVisualInputPolicy {
    static func maximumWireBytes(for messages: [AIMessage]) -> Int {
        messages.contains { !$0.images.isEmpty } ? 6_291_456 : 1_048_576
    }
    static func supports(_ connection: AIConnection) -> Bool {
        connection.supportsImages == true && !connection.protocolKind.isSubscription
    }
    static func validate(_ messages: [AIMessage], connection: AIConnection,
                         screenAllowed: () -> Bool = { CGPreflightScreenCaptureAccess() },
                         accessibilityAllowed: () -> Bool = { AXIsProcessTrusted() }) throws {
        try validateSources(messages.flatMap(\.visualSources), screenAllowed: screenAllowed, accessibilityAllowed: accessibilityAllowed)
        let images = messages.flatMap(\.images)
        guard !images.isEmpty else { return }
        guard supports(connection) else { throw AIResponseError.visionUnavailable }
        guard images.count <= 5, images.reduce(0, { $0 + $1.data.count }) <= AIImageInput.maximumRequestBytes,
              messages.allSatisfy({ $0.images.isEmpty || $0.role == .user }) else { throw AIResponseError.requestTooLarge }
        try images.forEach { try $0.validate() }
    }
    static func validateSources(_ sources: [AIVisualSource],
                                screenAllowed: () -> Bool = { CGPreflightScreenCaptureAccess() },
                                accessibilityAllowed: () -> Bool = { AXIsProcessTrusted() }) throws {
        guard !sources.contains(where: \.requiresScreenCapture) || screenAllowed(),
              !sources.contains(where: \.usedAccessibility) || accessibilityAllowed() else { throw AIResponseError.visualSourceRevoked }
    }
}
