import Foundation

public enum LauncherReturnDelay: Int, CaseIterable {
    case immediately = 0
    case after30Seconds = 30
    case after90Seconds = 90
    case after5Minutes = 300
    case never = -1

    public func shouldReturn(hiddenFor elapsed: TimeInterval) -> Bool {
        self != .never && elapsed >= TimeInterval(rawValue)
    }
}
