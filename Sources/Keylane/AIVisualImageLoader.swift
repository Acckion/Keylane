import Foundation
import Darwin
import ImageIO
import KeylaneCore
import UniformTypeIdentifiers
import Vision

/// Decode a bounded thumbnail and re-encode pixels only: no source EXIF/location metadata is forwarded.
enum AIVisualImageLoader {
    static func read(_ url: URL) async throws -> AIConversationAttachment {
        let task = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw AIResponseError.invalidImage }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var fileInfo = stat()
            guard fstat(descriptor, &fileInfo) == 0, fileInfo.st_mode & S_IFMT == S_IFREG,
                  fileInfo.st_size > 0, fileInfo.st_size <= 20_000_000 else { throw AIResponseError.invalidImage }
            let data = try file.read(upToCount: 20_000_001) ?? Data()
            guard data.count <= 20_000_000,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = info[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = info[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0, height.intValue > 0, width.doubleValue * height.doubleValue <= 40_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw AIResponseError.invalidImage }
            try Task.checkCancellation()
            let result = try encode(image)
            var after = stat()
            guard fstat(descriptor, &after) == 0, AIFileReadVersion(fileInfo) == AIFileReadVersion(after),
                  try AIFileReadVersion(url) == AIFileReadVersion(after) else { throw AIResponseError.invalidImage }
            return result
        }
        let image = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return .init(title: url.lastPathComponent, text: "用户显式选择的图像，按图像内容分析。", symbol: "photo", image: image)
    }

    static func encode(_ image: CGImage) throws -> AIImageInput {
        var edge = min(2048, max(image.width, image.height))
        while edge > 0 {
            try Task.checkCancellation()
            let scale = min(1, Double(edge) / Double(max(image.width, image.height)))
            let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AIResponseError.invalidImage }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let pixels = context.makeImage() else { throw AIResponseError.invalidImage }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw AIResponseError.invalidImage }
            CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw AIResponseError.invalidImage }
            if data.length <= AIImageInput.maximumBytes { return try .init(data: data as Data, mediaType: "image/jpeg", width: width, height: height) }
            guard edge > 256 else { break }
            edge = max(256, edge * 3 / 4)
        }
        throw AIResponseError.invalidImage
    }

    static func attachment(image: CGImage, title: String, accessibility: [String], source: AIVisualSource) async throws -> AIConversationAttachment {
        let work = ImageTextRecognitionWork()
        let task = Task.detached(priority: .userInitiated) {
            let payload = try encode(image)
            let ocr = (try? ImageTextRecognition.ocr.recognize(in: VNImageRequestHandler(cgImage: image), accurate: true, work: work)) ?? ""
            try Task.checkCancellation()
            let text = "来源：\(source.application) · \(source.windowTitle)\n采集时间：\(source.capturedAt.ISO8601Format())\n\n" + AIVisualText.merge(accessibility: accessibility, ocr: ocr)
            return AIConversationAttachment(title: title, text: text, symbol: "viewfinder", image: payload, visualSource: source)
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { work.cancel(); task.cancel() }
        try Task.checkCancellation()
        try AIVisualInputPolicy.validateSources([source])
        return result
    }
}
