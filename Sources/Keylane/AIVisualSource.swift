import Foundation

/// Capture metadata is independent of resource read authority and wire encoding.
struct AIVisualSource: Codable, Equatable, Sendable {
    let application: String
    let windowTitle: String
    let windowID: UInt32
    let capturedAt: Date
    let usedAccessibility: Bool
    var requiresScreenCapture = true
}
