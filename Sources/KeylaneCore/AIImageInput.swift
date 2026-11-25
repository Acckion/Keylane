import Foundation
import ImageIO

/// Bounded, metadata-free raster data shared by conversation persistence and wire encoders.
public struct AIImageInput: Codable, Equatable, Sendable {
    public static let maximumBytes = 786_432
    public static let maximumRequestBytes = 3_145_728
    public let data: Data
    public let mediaType: String
    public let width: Int
    public let height: Int

    public init(data: Data, mediaType: String, width: Int, height: Int) throws {
        self.data = data; self.mediaType = mediaType; self.width = width; self.height = height
        try validate()
    }
    public func validate() throws {
        let jpeg = mediaType == "image/jpeg" && data.starts(with: [0xff, 0xd8, 0xff])
        let png = mediaType == "image/png" && data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        guard jpeg || png, !data.isEmpty, data.count <= Self.maximumBytes,
              (1...2048).contains(width), (1...2048).contains(height),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height else { throw AIResponseError.invalidImage }
    }
    private enum CodingKeys: String, CodingKey { case data, mediaType, width, height }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(data: c.decode(Data.self, forKey: .data), mediaType: c.decode(String.self, forKey: .mediaType),
                      width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height))
    }
}
