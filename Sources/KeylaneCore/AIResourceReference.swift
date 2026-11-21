import Foundation

/// A stable identity, never a bearer capability, filesystem URL or permission grant.
/// Source identifiers are hashed so the URI does not reveal private paths or database IDs.
public struct AIResourceReference: Hashable, Codable, Sendable {
    private let module: String
    public let key: String
    public var moduleID: ModuleID { .init(rawValue: module) }
    public var uri: String {
        let owner = Data(module.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "keylane-resource://v1/\(owner)/\(key)"
    }

    public init(moduleID: ModuleID, sourceID: String) throws {
        guard !moduleID.rawValue.isEmpty, moduleID.rawValue.utf8.count <= 256,
              !sourceID.isEmpty, sourceID.utf8.count <= 16_384 else { throw AIActionError.invalidDefinition }
        module = moduleID.rawValue
        key = AIActionContext.digest(sourceID)
    }

    public init(uri: String) throws {
        guard uri.utf8.count <= 1_024,
              let url = URLComponents(string: uri), url.scheme == "keylane-resource", url.host == "v1",
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil else {
            throw AIActionError.invalidDefinition
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { throw AIActionError.invalidDefinition }
        var owner = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        owner += String(repeating: "=", count: (4 - owner.count % 4) % 4)
        guard let data = Data(base64Encoded: owner), let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty, decoded.utf8.count <= 256,
              parts[2].utf8.count == 64, parts[2].allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw AIActionError.invalidDefinition
        }
        module = decoded; key = String(parts[2])
        guard self.uri == uri else { throw AIActionError.invalidDefinition }
    }

    public init(from decoder: Decoder) throws {
        try self.init(uri: decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(uri)
    }
}

/// Evidence about one immutable extraction. Neither this value nor a decoded URI can read data.
public struct AIResourceSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let reference: AIResourceReference
    public let revision: String
    public let contentDigest: String
    public let capturedAt: Date
    public init(reference: AIResourceReference, revision: String, text: String, capturedAt: Date = Date()) {
        id = UUID(); self.reference = reference; self.revision = revision
        contentDigest = AIActionContext.digest(text); self.capturedAt = capturedAt
    }
    public func matches(_ text: String) -> Bool { contentDigest == AIActionContext.digest(text) }
}
