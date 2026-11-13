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
    public struct Identity: Hashable, Sendable {
        fileprivate let volume: Data
        fileprivate let file: Data

        public func matches(_ values: URLResourceValues) -> Bool {
            volume == values.volumeIdentifier as? Data && file == values.fileResourceIdentifier as? Data
        }
    }

    public internal(set) var identity: Identity? = nil
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
                                        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                        .fileResourceIdentifierKey, .volumeIdentifierKey]
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
                let cloud = needsCloudAccess(url, values: values)
                let identity: ScreenshotMedia.Identity?
                if let volume = values.volumeIdentifier as? Data, let file = values.fileResourceIdentifier as? Data {
                    identity = .init(volume: volume, file: file)
                } else {
                    identity = nil
                }
                items.append(.init(url: url, date: values.creationDate ?? modified, modified: modified,
                                   size: values.fileSize ?? 0, kind: kind, needsCloudAccess: cloud, identity: identity))
            }
        }
        return ScreenshotScan(items: items.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }, inaccessibleFolders: unreadable.count)
    }

    public static func needsCloudAccess(_ url: URL, values: URLResourceValues) -> Bool {
        (values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
         && values.ubiquitousItemDownloadingStatus != .downloaded)
            || (url.path.contains("/Library/CloudStorage/") && (values.fileAllocatedSize ?? 0) == 0)
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
        if ["screenshot", "screen shot", "screen recording", "截屏", "截图", "录屏", "螢幕快照", "螢幕錄製",
            "bildschirmfoto", "bildschirmaufnahme", "capture d’écran", "capture d'écran",
            "enregistrement de l’écran", "enregistrement de l'écran"]
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
    private let dateRange: DateInterval?
    private let nameDateRange: DateInterval?
    private let dateComponents: [Int]
    private let nameDateComponents: [Int]

    public init(_ query: String, calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
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
        dateRange = Self.relativeRange(self.date, calendar: calendar, now: now)
        nameDateRange = Self.relativeRange(self.name.lowercased(), calendar: calendar, now: now)
        dateComponents = Self.parseAbsoluteDate(self.date)
        nameDateComponents = Self.parseAbsoluteDate(self.name)
    }

    public func matchesMetadata(_ item: ScreenshotMedia) -> Bool {
        guard date.isEmpty || matches(dateComponents, range: dateRange, captureDate: item.date) else { return false }
        return name.isEmpty || item.name.localizedStandardContains(name)
            || matches(nameDateComponents, range: nameDateRange, captureDate: item.date)
    }

    private static func relativeRange(_ input: String, calendar: Calendar, now: Date) -> DateInterval? {
        let component: Calendar.Component
        let offset: Int
        switch input.split(whereSeparator: \.isWhitespace).joined(separator: " ") {
        case "today", "今天", "今日": (component, offset) = (.day, 0)
        case "yesterday", "昨天", "昨日": (component, offset) = (.day, -1)
        case "this week", "本周", "这周", "本週", "這週": (component, offset) = (.weekOfYear, 0)
        case "last week", "上周", "上週": (component, offset) = (.weekOfYear, -1)
        case "this month", "本月", "这个月", "這個月": (component, offset) = (.month, 0)
        case "last month", "上月", "上个月", "上個月": (component, offset) = (.month, -1)
        case "this year", "今年", "本年": (component, offset) = (.year, 0)
        case "last year", "去年", "上年": (component, offset) = (.year, -1)
        default: return nil
        }
        guard let date = calendar.date(byAdding: component, value: offset, to: now) else { return nil }
        return calendar.dateInterval(of: component, for: date)
    }

    private static func parseAbsoluteDate(_ input: String) -> [Int] {
        let pieces = input.replacingOccurrences(of: "/", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count), pieces.first?.count == 4 else { return [] }
        let numbers = pieces.compactMap { Int($0) }
        return numbers.count == pieces.count ? numbers : []
    }

    private func matches(_ numbers: [Int], range: DateInterval?, captureDate: Date) -> Bool {
        if let range { return captureDate >= range.start && captureDate < range.end }
        guard !numbers.isEmpty else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: captureDate)
        return components.year == numbers[0]
            && (numbers.count < 2 || components.month == numbers[1])
            && (numbers.count < 3 || components.day == numbers[2])
    }
}
