import Foundation

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

    public init(geometry: WindowGeometry = .init()) { self.geometry = geometry }
    public init(windows: [WindowLayoutEntry]) { self.windows = windows }

    public var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else { return false }
        switch (geometry, windows) {
        case (let geometry?, nil): return geometry.isValid
        case (nil, let windows?):
            return !windows.isEmpty && windows.count <= 64 && Set(windows.map(\.id)).count == windows.count
                && windows.allSatisfy(\.isValid)
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
