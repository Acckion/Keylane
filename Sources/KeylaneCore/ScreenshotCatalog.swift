import CoreServices
import Foundation
import UniformTypeIdentifiers

public struct ScreenshotMedia: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case image, movie }
    public let url: URL
    public let date: Date
    public let modified: Date
    public let size: Int
    public let kind: Kind
    public let needsCloudAccess: Bool
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

public struct ScreenshotScan: Sendable {
    public let items: [ScreenshotMedia]
    public let inaccessibleFolders: Int
}

public enum ScreenshotCatalog {
    public static func scan(folders: [URL], includeAllMedia: Bool) -> ScreenshotScan {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey,
                                        .contentModificationDateKey, .fileSizeKey, .fileAllocatedSizeKey,
                                        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let manager = FileManager.default
        var items: [ScreenshotMedia] = []
        var seen: Set<String> = []
        var unreadable: Set<String> = []
        for folder in folders {
            guard !Task.isCancelled else { break }
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            guard let children = manager.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in
                    unreadable.insert(url.path)
                    return true
                }) else { unreadable.insert(folder.path); continue }
            for case let url as URL in children {
                guard !Task.isCancelled else { break }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                guard let kind = mediaKind(url) else { continue }
                guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                if !includeAllMedia && !isSystemCapture(url) { continue }
                let modified = values.contentModificationDate ?? .distantPast
                let cloud = (values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
                              && values.ubiquitousItemDownloadingStatus != .downloaded)
                    || (url.path.contains("/Library/CloudStorage/") && (values.fileAllocatedSize ?? 0) == 0)
                items.append(.init(url: url, date: values.creationDate ?? modified, modified: modified,
                                   size: values.fileSize ?? 0, kind: kind, needsCloudAccess: cloud))
            }
        }
        return ScreenshotScan(items: items.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }, inaccessibleFolders: unreadable.count)
    }

    private static func mediaKind(_ url: URL) -> ScreenshotMedia.Kind? {
        switch url.pathExtension.lowercased() {
        case "png", "jpeg", "jpg", "heif", "heic", "gif", "tiff", "tif", "webp", "bmp", "avif":
            return .image
        case "mov", "mp4", "m4v", "avi", "webm":
            return .movie
        default:
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true { return .image }
            if type?.conforms(to: .movie) == true { return .movie }
            return nil
        }
    }

    private static func isSystemCapture(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        if ["screenshot", "screen shot", "screen recording", "截屏", "截图", "录屏", "螢幕快照", "螢幕錄製"]
            .contains(where: { filename.hasPrefix($0) }) { return true }
        guard let metadata = MDItemCreateWithURL(nil, url as CFURL) else { return false }
        return (MDItemCopyAttribute(metadata, "kMDItemIsScreenCapture" as CFString) as? Bool) == true
    }
}

public struct ScreenshotQuery: Sendable {
    public let name: String
    public let text: String
    public let date: String
    private let calendar: Calendar
    private let now: Date

    public init(_ query: String, calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.now = now
        let expression = try! NSRegularExpression(pattern: #"(?i)(?:^|\s)(name|text|date|名称|文字|日期)[:：]\s*"#)
        let input = query as NSString
        let fields = expression.matches(in: query, range: NSRange(location: 0, length: input.length))
        var names = [input.substring(to: fields.first?.range.location ?? input.length)]
        var text = ""
        var date = ""
        for (index, field) in fields.enumerated() {
            let start = NSMaxRange(field.range)
            let end = index + 1 < fields.count ? fields[index + 1].range.location : input.length
            let value = input.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            switch input.substring(with: field.range(at: 1)).lowercased() {
            case "text", "文字": text = value
            case "date", "日期": date = value
            default: names.append(value)
            }
        }
        self.name = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        self.text = text
        self.date = date.lowercased()
    }

    public func matchesMetadata(_ item: ScreenshotMedia) -> Bool {
        let dateMatch = date.isEmpty || matches(date, captureDate: item.date)
        let nameMatch = name.isEmpty || item.name.localizedStandardContains(name)
            || matches(name.lowercased(), captureDate: item.date)
        return dateMatch && nameMatch
    }

    private func matches(_ input: String, captureDate: Date) -> Bool {
        if ["today", "今天", "今日"].contains(input) { return calendar.isDate(captureDate, inSameDayAs: now) }
        if ["yesterday", "昨天", "昨日"].contains(input),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            return calendar.isDate(captureDate, inSameDayAs: yesterday)
        }
        let pieces = input.replacingOccurrences(of: "/", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count), pieces.first?.count == 4 else { return false }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == pieces.count else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: captureDate)
        return zip(numbers, [components.year, components.month, components.day]).allSatisfy { $0 == $1 }
    }
}
