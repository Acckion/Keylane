import Foundation
import CoreGraphics

public struct WindowLayoutEntry: Codable, Identifiable, Equatable {
    public enum Argument: Codable, Equatable {
        case none, file(String), url(String), quicklink(String), arguments(String)
    }

    public var id = UUID()
    public var bundleID: String
    public var windowTitle = ""
    public var display = 0
    public var geometry = WindowGeometry()
    public var argument: Argument = .none

    public init(bundleID: String) { self.bundleID = bundleID }

    public func frame(in screen: CGRect, windowGap: CGFloat = 0, screenGap: CGFloat = 0) -> CGRect? {
        let area = Self.layoutArea(in: screen, screenGap: screenGap)
        guard let frame = geometry.frame(in: area) else { return nil }
        let half = max(0, windowGap) / 2
        let left = frame.minX > area.minX ? half : 0
        let right = frame.maxX < area.maxX ? half : 0
        let top = frame.minY > area.minY ? half : 0
        let bottom = frame.maxY < area.maxY ? half : 0
        let width = frame.width - left - right
        let height = frame.height - top - bottom
        guard width > 0, height > 0 else { return nil }
        return CGRect(x: frame.minX + left, y: frame.minY + top, width: width, height: height)
    }

    fileprivate static func layoutArea(in screen: CGRect, screenGap: CGFloat) -> CGRect {
        let gap = min(max(0, screenGap), max(0, (min(screen.width, screen.height) - 1) / 2))
        return screen.insetBy(dx: gap, dy: gap)
    }

    public var isValid: Bool {
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, display >= 0, geometry.isValid else { return false }
        switch argument {
        case .none: return true
        case .file(let path): return path.hasPrefix("/") || path.hasPrefix("~/")
        case .url(let url): return URL(string: url)?.scheme?.isEmpty == false
        case .quicklink(let id): return !id.isEmpty
        case .arguments(let value): return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

public struct CustomWindowAction: Codable, Identifiable, Equatable {
    public enum OtherWindows: String, CaseIterable, Codable {
        case keep, minimize, close
    }

    public var id = UUID()
    public var name = ""
    public var geometry: WindowGeometry?
    public var windows: [WindowLayoutEntry]?
    public var otherWindows: OtherWindows = .keep
    public var icon: String?
    public var usesPreferredGaps: Bool?
    public var frontWindowID: UUID?

    public init(geometry: WindowGeometry = .init()) { self.geometry = geometry }
    public init(windows: [WindowLayoutEntry]) {
        self.windows = windows
        usesPreferredGaps = true
    }

    public func displayFrame(for entry: WindowLayoutEntry, in screen: CGRect,
                             windowGap: CGFloat, screenGap: CGFloat) -> CGRect? {
        if usesPreferredGaps == true {
            return entry.frame(in: screen, windowGap: windowGap, screenGap: screenGap)
        }
        return entry.frame(in: screen)
    }

    public func draggedGeometry(for entry: WindowLayoutEntry, in screen: CGRect,
                                windowGap: CGFloat, screenGap: CGFloat, translation: CGSize,
                                resizingFrom handle: WindowGeometry.Anchor? = nil,
                                minimumSize: CGFloat) -> WindowGeometry? {
        let usesGaps = usesPreferredGaps == true
        let area = WindowLayoutEntry.layoutArea(in: screen, screenGap: usesGaps ? screenGap : 0)
        // Edit the underlying region so the preferred gaps still apply when the layout is run.
        let minimum = max(minimumSize, usesGaps ? windowGap + 1 : 1)
        return entry.geometry.dragged(in: area, translation: translation, resizingFrom: handle, minimumSize: minimum)
    }

    public var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else { return false }
        switch (geometry, windows) {
        case (let geometry?, nil): return geometry.isValid
        case (nil, let windows?):
            return !windows.isEmpty && windows.count <= 64 && Set(windows.map(\.id)).count == windows.count
                && windows.allSatisfy(\.isValid)
                && (frontWindowID == nil || windows.contains { $0.id == frontWindowID })
                && Dictionary(grouping: windows, by: \.display).values.allSatisfy { $0.count <= 8 }
        default: return false
        }
    }
}

public struct WindowActionsArchive: Codable {
    public let version: Int
    public let actions: [CustomWindowAction]

    public init(actions: [CustomWindowAction]) {
        version = 1
        self.actions = actions
    }

    public var isValid: Bool {
        version == 1 && actions.count <= 500 && Set(actions.map(\.id)).count == actions.count
            && actions.allSatisfy(\.isValid)
    }
}
