import Foundation

public struct ClipRepresentation: Codable, Equatable {
    public let type: String
    public let data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
}
public struct ClipSnapshotItem: Codable, Equatable {
    public let representations: [ClipRepresentation]
    public init(_ representations: [ClipRepresentation]) { self.representations = representations }
}
/// Only standard content types are retained. App-private objects, owner tokens,
/// credentials and promised-data providers are never serialized.
public struct ClipSnapshot: Codable, Equatable {
    public static let allowedTypes: Set<String> = ["public.utf8-plain-text","public.utf16-plain-text","public.url","public.file-url","public.rtf","com.apple.flat-rtfd","public.html","public.png","public.jpeg","public.tiff","public.heic","org.webmproject.webp","com.compuserve.gif","com.adobe.pdf"]
    public let items: [ClipSnapshotItem]
    public let plainText: String
    public init(items: [ClipSnapshotItem], plainText: String = "") { self.items = items; self.plainText = plainText }
    public var formats: [String] { Array(Set(items.flatMap { $0.representations.map(\.type) })).sorted() }
    public var hasRichText: Bool { formats.contains { ["public.rtf","com.apple.flat-rtfd","public.html"].contains($0) } }
    public func encoded() throws -> Data {
        guard !items.isEmpty, items.count <= 128, plainText.utf8.count <= 1_048_576 else { throw ClipboardError.oversized }
        var size = 0
        for item in items {
            guard !item.representations.isEmpty, item.representations.count <= Self.allowedTypes.count else { throw ClipboardError.oversized }
            var seen = Set<String>()
            for representation in item.representations {
                guard Self.allowedTypes.contains(representation.type), seen.insert(representation.type).inserted, !representation.data.isEmpty, representation.data.count <= 16 * 1024 * 1024 else { throw ClipboardError.oversized }
                size += representation.data.count
                guard size <= 32 * 1024 * 1024 else { throw ClipboardError.oversized }
            }
        }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= 34 * 1024 * 1024 else { throw ClipboardError.oversized }
        return data
    }
    /// Preserve the old plain-text/file identity. Rich or mixed representations
    /// distinguish identically worded clips with different formatting/content.
    public func identitySupplement(kind: ClipKind) -> Data {
        let imageTypes: Set<String> = ["public.png","public.jpeg","public.tiff","public.heic","org.webmproject.webp","com.compuserve.gif"]
        let simpleText = items.count == 1 && formats.allSatisfy { $0 == "public.utf8-plain-text" || $0 == "public.utf16-plain-text" }
        let simpleFiles = kind == .files && formats.allSatisfy { $0 == "public.file-url" }
        let simpleImage = kind == .image && items.count == 1 && formats.allSatisfy { imageTypes.contains($0) }
        if simpleText || simpleFiles || simpleImage { return Data() }
        var result = Data()
        func append(_ data: Data) { var length = UInt64(data.count).bigEndian; withUnsafeBytes(of:&length) { result.append(contentsOf:$0) }; result.append(data) }
        for item in items {
            append(Data("item".utf8))
            for representation in item.representations.sorted(by: { $0.type < $1.type }) { append(Data(representation.type.utf8)); append(representation.data) }
        }
        return result
    }
}
