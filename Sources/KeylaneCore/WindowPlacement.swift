import CoreGraphics

public enum WindowPlacement {
    case left, right, top, bottom, maximize, center, nextDisplay, restore

    /// Display frames and window frames use the same top-left coordinate space.
    public func frame(for window: CGRect, displays: [CGRect], previous: CGRect? = nil) -> CGRect? {
        guard let index = displays.indices.max(by: {
            window.overlapArea(with: displays[$0]) < window.overlapArea(with: displays[$1])
        }) else { return nil }
        let screen = displays[index]
        switch self {
        case .left, .right:
            let half = floor(screen.width / 2)
            let split = screen.minX + half
            return self == .left
                ? CGRect(x: screen.minX, y: screen.minY, width: half, height: screen.height)
                : CGRect(x: split, y: screen.minY, width: screen.maxX - split, height: screen.height)
        case .top, .bottom:
            let half = floor(screen.height / 2)
            let split = screen.minY + half
            return self == .top
                ? CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: half)
                : CGRect(x: screen.minX, y: split, width: screen.width, height: screen.maxY - split)
        case .maximize:
            return screen
        case .center:
            return CGRect(x: (screen.midX - window.width / 2).rounded(),
                          y: (screen.midY - window.height / 2).rounded(), width: window.width, height: window.height)
                .fitted(in: screen)
        case .nextDisplay:
            guard displays.count > 1 else { return nil }
            let next = displays[(index + 1) % displays.count]
            let x = (window.midX - screen.minX) / screen.width
            let y = (window.midY - screen.minY) / screen.height
            return CGRect(x: (next.minX + x * next.width - window.width / 2).rounded(),
                          y: (next.minY + y * next.height - window.height / 2).rounded(),
                          width: window.width, height: window.height).fitted(in: next)
        case .restore:
            guard let previous else { return nil }
            if previous.isCovered(by: displays) { return previous }
            let best = displays.max { previous.overlapArea(with: $0) < previous.overlapArea(with: $1) }
            if let best, previous.overlapArea(with: best) > 0 { return previous.fitted(in: best) }
            return previous.fitted(in: screen)
        }
    }
}

private extension CGRect {
    func overlapArea(with rect: CGRect) -> CGFloat {
        let overlap = intersection(rect)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    func isCovered(by displays: [CGRect]) -> Bool {
        let overlaps = displays.map { intersection($0) }.filter { !$0.isNull && !$0.isEmpty }
        let boundaries = Set([minY, maxY] + overlaps.flatMap { [$0.minY, $0.maxY] }).sorted()
        let leftToRight = overlaps.sorted { $0.minX < $1.minX }

        // Check each horizontal band separately so gaps and overlapping displays
        // cannot be mistaken for usable space.
        for (top, bottom) in zip(boundaries, boundaries.dropFirst()) {
            var coveredThrough = minX
            for overlap in leftToRight where overlap.minY <= top && overlap.maxY >= bottom {
                if overlap.minX > coveredThrough { break }
                coveredThrough = max(coveredThrough, overlap.maxX)
            }
            if coveredThrough < maxX { return false }
        }
        return !overlaps.isEmpty
    }

    func fitted(in screen: CGRect) -> CGRect {
        let width = min(width, screen.width)
        let height = min(height, screen.height)
        return CGRect(x: max(screen.minX, min(minX, screen.maxX - width)),
                      y: max(screen.minY, min(minY, screen.maxY - height)), width: width, height: height)
    }
}
