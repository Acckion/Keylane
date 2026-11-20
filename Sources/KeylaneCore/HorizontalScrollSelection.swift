/// Tracks a continuous swipe until the fingers lift, separately from wheel ticks.
public struct HorizontalScrollSelection {
    private var distance: Double = 0

    public init() {}

    public mutating func reset() { distance = 0 }

    public static func isHorizontal(_ horizontal: Double, _ vertical: Double) -> Bool {
        horizontal != 0 && abs(horizontal) >= abs(vertical) * 0.85
    }

    public mutating func drag(horizontal: Double, vertical: Double) -> Double? {
        guard Self.isHorizontal(horizontal, vertical) else { return nil }
        distance += horizontal
        return distance
    }

    public mutating func finish(threshold: Double) -> Int? {
        defer { reset() }
        guard abs(distance) >= threshold else { return nil }
        return distance < 0 ? 1 : -1
    }
}
