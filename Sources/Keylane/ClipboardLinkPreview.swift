import AppKit
import Combine
import ImageIO
import KeylaneCore
import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardLinkMetadata {
    let title: String?
    let image: NSImage?
    let icon: NSImage?

    var aspectRatio: CGFloat {
        guard let size = image?.size, size.height > 0 else { return 2 }
        return min(2.4, max(1.8, size.width / size.height))
    }
}

struct ClipboardLinkPreview: View {
    let url: URL
    let metadata: ClipboardLinkMetadata?

    var body: some View {
        Link(destination: url) {
            GeometryReader { geometry in
                if let image = metadata?.image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            if let icon = metadata?.icon {
                                Image(nsImage: icon).renderingMode(icon.isTemplate ? .template : .original)
                                    .resizable().scaledToFit().frame(width: 22, height: 22)
                            } else {
                                Image(systemName: "globe").font(.system(size: 18))
                            }
                            Text(url.host() ?? url.absoluteString).font(.callout).lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                        Text(metadata?.title ?? url.absoluteString)
                            .font(.title3.weight(.semibold))
                            .lineLimit(3)
                    }
                    .padding(18)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                    .background(.primary.opacity(0.06))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(metadata?.title ?? url.absoluteString)
        .accessibilityHint("在浏览器中打开链接")
    }
}

@MainActor
final class ClipboardLinkPreviews {
    static let shared = ClipboardLinkPreviews()
    let iconUpdates = PassthroughSubject<(URL, NSImage), Never>()
    private let pages = RequestCache<ClipboardLinkMetadata>(count: 48, bytes: 24 * 1024 * 1024, lifetime: 900)
    private let icons = RequestCache<NSImage>(count: 128, bytes: 4 * 1024 * 1024, lifetime: 3600)

    func preview(for url: URL) async -> ClipboardLinkMetadata? {
        let result = await pages.value(for: url, cost: { Self.imageCost($0.image) + Self.imageCost($0.icon) }) {
            let metadata = await Self.fetch(url)
            async let previewImage = Self.loadImage(metadata?.imageProvider, maximum: 1200)
            async let siteIcon = Self.loadImage(metadata?.iconProvider, maximum: 64)
            let (image, icon) = await (previewImage, siteIcon)
            let title = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let image, let title, !title.isEmpty, let icon {
                return ClipboardLinkMetadata(title: title, image: image, icon: icon)
            }
            let head = await Self.webPageHead(at: url)
            async let fallbackImage = Self.downloadImage(image == nil ? head?.image : nil, maximum: 1200)
            async let fallbackIcon = Self.downloadImage(icon == nil ? head?.icon : nil, maximum: 64)
            let (downloadedImage, downloadedIcon) = await (fallbackImage, fallbackIcon)
            guard metadata != nil || head != nil else { return nil }
            return ClipboardLinkMetadata(title: head?.title ?? title, image: image ?? downloadedImage, icon: icon ?? downloadedIcon)
        }
        if let icon = result?.icon, let origin = Self.origin(for: url), icons.cachedValue(for: origin) == nil {
            icons.store(icon, for: origin, cost: Self.imageCost(icon))
            iconUpdates.send((origin, icon))
        }
        return result
    }

    func icon(for url: URL) async -> NSImage? {
        guard let origin = Self.origin(for: url) else { return nil }
        // Rows request only an origin's icon. Fetch the full URL only for the selected entry.
        return await icons.value(for: origin, cost: { Self.imageCost($0) }) {
            if let icon = await Self.downloadImage(origin.appendingPathComponent("favicon.ico"), maximum: 64) { return icon }
            let metadata = await Self.fetch(origin)
            if let icon = await Self.loadImage(metadata?.iconProvider, maximum: 64) { return icon }
            let head = await Self.webPageHead(at: origin)
            return await Self.downloadImage(head?.icon, maximum: 64)
        }
    }

    static func origin(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func fetch(_ url: URL) async -> LPLinkMetadata? {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        return try? await provider.startFetchingMetadata(for: request(for: url, accepts: "text/html"))
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration)
    }()

    private nonisolated static func request(for url: URL, accepts: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(accepts, forHTTPHeaderField: "Accept")
        return request
    }

    private nonisolated static func download(_ url: URL, accepts: String, limit: Int) async -> (Data, URL)? {
        guard let (bytes, response) = try? await session.bytes(for: request(for: url, accepts: accepts)),
              let response = response as? HTTPURLResponse, let finalURL = response.url else { return nil }
        guard (200..<300).contains(response.statusCode), response.expectedContentLength <= limit else {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else {
                    bytes.task.cancel()
                    return nil
                }
                data.append(byte)
            }
        } catch { return nil }
        return (data, finalURL)
    }

    private nonisolated static func downloadImage(_ url: URL?, maximum: Int) async -> NSImage? {
        guard let url, let (data, _) = await download(url, accepts: "image/*",
                                                      limit: maximum <= 64 ? 256 * 1024 : 5 * 1024 * 1024) else { return nil }
        return decode(data, maximum: maximum)
    }

    private nonisolated static func webPageHead(at url: URL) async -> (title: String?, image: URL?, icon: URL?)? {
        guard let (data, finalURL) = await download(url, accepts: "text/html", limit: 512 * 1024),
              let html = String(data: data, encoding: .utf8),
              let end = html.range(of: "</head>", options: .caseInsensitive),
              let document = try? XMLDocument(data: Data(html[..<end.upperBound].utf8),
                                              options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let nodes = try? document.nodes(forXPath: "//*[local-name()='head']/*") else { return nil }
        let elements = nodes.compactMap { $0 as? XMLElement }
        func value(_ names: [String]) -> String? {
            for name in names {
                if let meta = elements.first(where: {
                    ($0.localName ?? $0.name) == "meta" &&
                    ($0.attribute(forName: "property")?.stringValue ?? $0.attribute(forName: "name")?.stringValue) == name
                }), let content = meta.attribute(forName: "content")?.stringValue, !content.isEmpty { return content }
            }
            return nil
        }
        func resolve(_ text: String?) -> URL? {
            guard let text, let resolved = URL(string: text, relativeTo: finalURL)?.absoluteURL else { return nil }
            return ClipboardCategory.webURL(in: resolved.absoluteString)
        }
        let title = value(["og:title", "twitter:title"]) ?? elements.first { ($0.localName ?? $0.name) == "title" }?.stringValue
        let image = resolve(value(["og:image:secure_url", "og:image", "twitter:image"]))
        let icons = elements.filter {
            guard ($0.localName ?? $0.name) == "link",
                  let rel = $0.attribute(forName: "rel")?.stringValue?.lowercased() else { return false }
            return rel.split(whereSeparator: \.isWhitespace).contains("icon") || rel == "apple-touch-icon"
        }
        let iconElement = icons.first { $0.attribute(forName: "type")?.stringValue == "image/png" } ?? icons.first
        let icon = resolve(iconElement?.attribute(forName: "href")?.stringValue)
        return (title, image, icon)
    }

    private static func loadImage(_ provider: NSItemProvider?, maximum: Int) async -> NSImage? {
        guard let provider,
              let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data.flatMap { decode($0, maximum: maximum) })
            }
        }
    }

    private nonisolated static func decode(_ data: Data, maximum: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let icon = CGImageSourceGetType(source) == UTType.ico.identifier as CFString
        let index = icon ? (0..<CGImageSourceGetCount(source)).max(by: { imageWidth(source, $0) < imageWidth(source, $1) }) ?? 0 : 0
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum
        ] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        if maximum <= 64 { result.isTemplate = isDarkGlyph(image) }
        return result
    }

    /// A dark monochrome mark on transparency can use the system foreground in either appearance.
    private nonisolated static func isDarkGlyph(_ image: CGImage) -> Bool {
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            var visible = 0
            var dark = 0
            var transparent = 0
            for index in stride(from: 0, to: buffer.count, by: 4) {
                let alpha = Int(buffer[index + 3])
                if alpha < 24 { transparent += 1 }
                guard alpha >= 96 else { continue }
                visible += 1
                let maximum = Int(max(buffer[index], buffer[index + 1], buffer[index + 2]))
                let minimum = Int(min(buffer[index], buffer[index + 1], buffer[index + 2]))
                if maximum * 2 < alpha, (maximum - minimum) * 6 < alpha { dark += 1 }
            }
            return transparent > size && visible > size && dark * 10 >= visible * 9
        }
    }

    private nonisolated static func imageWidth(_ source: CGImageSource, _ index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    }

    private static func imageCost(_ image: NSImage?) -> Int {
        guard let size = image?.size else { return 0 }
        return Int(size.width * size.height) * 4
    }
}

/// Coalesce visible rows and retain successful and failed requests briefly in memory.
@MainActor
private final class RequestCache<Value> {
    private final class Entry {
        let value: Value?
        let expires: Date
        init(_ value: Value?, expires: Date) {
            self.value = value
            self.expires = expires
        }
    }

    private let cache = NSCache<NSURL, Entry>()
    private var pending: [URL: Task<Value?, Never>] = [:]
    private let lifetime: TimeInterval

    init(count: Int, bytes: Int, lifetime: TimeInterval) {
        cache.countLimit = count
        cache.totalCostLimit = bytes
        self.lifetime = lifetime
    }

    func value(for url: URL, cost: (Value) -> Int, fetch: @escaping @MainActor () async -> Value?) async -> Value? {
        if let entry = cache.object(forKey: url as NSURL), entry.expires > Date() { return entry.value }
        if let task = pending[url] {
            let result = await task.value
            return cachedValue(for: url) ?? result
        }
        let task = Task { await fetch() }
        pending[url] = task
        let result = await task.value
        pending[url] = nil
        if let seeded = cachedValue(for: url) { return seeded }
        store(result, for: url, cost: result.map(cost) ?? 0)
        return result
    }

    func cachedValue(for url: URL) -> Value? {
        guard let entry = cache.object(forKey: url as NSURL), entry.expires > Date() else { return nil }
        return entry.value
    }

    func store(_ value: Value?, for url: URL, cost: Int) {
        let expires = Date().addingTimeInterval(value == nil ? 60 : lifetime)
        cache.setObject(Entry(value, expires: expires), forKey: url as NSURL, cost: cost)
    }
}
