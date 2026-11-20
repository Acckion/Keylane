import Foundation

/// Immutable selection from the complete official source catalogue. This is source
/// identity, not an installation receipt or a claim of runtime compatibility.
public struct RaycastStoreSource: Equatable, Sendable {
    public let slug: String
    public let revision: String
    public var manifestURL: URL { sourceURL.appendingPathComponent("package.json") }
    public var sourceURL: URL {
        URL(string: "https://raw.githubusercontent.com/raycast/extensions")!
            .appendingPathComponent(revision).appendingPathComponent("extensions").appendingPathComponent(slug)
    }

    public enum Failure: Error, Equatable {
        case invalidRevision, invalidSlug, notInCatalog
    }

    public init(slug: String, catalog: RaycastPublicCatalog.Index) throws {
        guard Self.validRevision(catalog.revision) else { throw Failure.invalidRevision }
        guard Self.validSlug(slug) else { throw Failure.invalidSlug }
        guard catalog.slugs.contains(slug) else { throw Failure.notInCatalog }
        self.slug = slug
        revision = catalog.revision
    }

    static func validRevision(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validSlug(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value != "." && value != ".." && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}
