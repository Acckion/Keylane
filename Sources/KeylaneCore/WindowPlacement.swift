import CoreGraphics

public enum WindowEdge: String, CaseIterable, Codable, Hashable {
    case left, right, top, bottom
}

public enum WindowPlacement: Equatable {
    case left, right, top, bottom, maximize, center, nextDisplay, restore
    case region(CGRect)
    case proportional(CGFloat, maximum: CGSize? = nil)
    case maximizeWidth, maximizeHeight
    case moveEdge(WindowEdge, centered: Bool)
    case move(CGPoint), resize(CGSize), grow(CGFloat)
    case displayStep(Int, wrap: Bool, keepAspectRatio: Bool)
    case custom(WindowGeometry)

    /// Display frames and window frames use the same top-left coordinate space.
    public func frame(for window: CGRect, displays: [CGRect], previous: CGRect? = nil,
                      windowGap: CGFloat = 0, screenGap: CGFloat = 0) -> CGRect? {
        guard let index = Self.displayIndex(for: window, displays: displays) else { return nil }
        let screen = displays[index]
        let gap = min(max(0, screenGap), max(0, (min(screen.width, screen.height) - 1) / 2))
        let area = screen.insetBy(dx: gap, dy: gap)
        switch self {
        case .left, .right, .top, .bottom, .maximize, .region:
            guard let region = fixedRegion else { return nil }
            return Self.tile(region, in: area, gap: windowGap)
        case .center:
            return CGRect(x: (area.midX - window.width / 2).rounded(),
                          y: (area.midY - window.height / 2).rounded(), width: window.width, height: window.height)
                .fitted(in: area)
        case let .proportional(fraction, maximum):
            let width = min(area.width * fraction, maximum?.width ?? area.width)
            let height = min(area.height * fraction, maximum?.height ?? area.height)
            return CGRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(),
                          width: width.rounded(), height: height.rounded()).fitted(in: area)
        case .maximizeWidth:
            return CGRect(x: area.minX, y: window.minY, width: area.width, height: window.height).fitted(in: area)
        case .maximizeHeight:
            return CGRect(x: window.minX, y: area.minY, width: window.width, height: area.height).fitted(in: area)
        case let .moveEdge(edge, centered):
            var target = window.fitted(in: area)
            switch edge {
            case .left, .right:
                target.origin.x = edge == .left ? area.minX : area.maxX - target.width
                if centered { target.origin.y = (area.midY - target.height / 2).rounded() }
            case .top, .bottom:
                target.origin.y = edge == .top ? area.minY : area.maxY - target.height
                if centered { target.origin.x = (area.midX - target.width / 2).rounded() }
            }
            return target
        case let .move(offset):
            guard offset.x.isFinite, offset.y.isFinite else { return nil }
            return CGRect(origin: CGPoint(x: screen.minX + offset.x, y: screen.minY + offset.y), size: window.size)
        case let .resize(size):
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
            return CGRect(origin: window.origin, size: size)
        case let .grow(step):
            let width = min(area.width, max(1, window.width + step))
            let height = min(area.height, max(1, window.height + step))
            return CGRect(x: (window.midX - width / 2).rounded(), y: (window.midY - height / 2).rounded(),
                          width: width, height: height).fitted(in: area)
        case .nextDisplay:
            return Self.transfer(window, displays: displays, index: index, step: 1, wrap: true, keepAspectRatio: nil, screenGap: screenGap)
        case let .displayStep(step, wrap, keepAspectRatio):
            return Self.transfer(window, displays: displays, index: index, step: step, wrap: wrap,
                                 keepAspectRatio: keepAspectRatio, screenGap: screenGap)
        case .restore:
            guard let previous else { return nil }
            if previous.isCovered(by: displays) { return previous }
            let best = displays.max { previous.overlapArea(with: $0) < previous.overlapArea(with: $1) }
            if let best, previous.overlapArea(with: best) > 0 { return previous.fitted(in: best) }
            return previous.fitted(in: screen)
        case let .custom(geometry):
            return geometry.frame(in: screen)
        }
    }

    public var fixedRegion: CGRect? {
        switch self {
        case .left: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .maximize: CGRect(x: 0, y: 0, width: 1, height: 1)
        case let .region(region): region
        default: nil
        }
    }

    public static func displayIndex(for window: CGRect, displays: [CGRect]) -> Int? {
        displays.indices.max { lhs, rhs in
            let a = window.overlapArea(with: displays[lhs])
            let b = window.overlapArea(with: displays[rhs])
            if a != b { return a < b }
            return displays[rhs].distanceSquared(to: window.origin) < displays[lhs].distanceSquared(to: window.origin)
        }
    }

    private static func tile(_ region: CGRect, in area: CGRect, gap: CGFloat) -> CGRect? {
        guard region.minX >= 0, region.minY >= 0, region.maxX <= 1.000001, region.maxY <= 1.000001,
              region.width > 0, region.height > 0, !region.isInfinite else { return nil }
        let halfGap = max(0, gap) / 2
        let left = floor(area.width * region.minX) + (region.minX > 0 ? halfGap : 0)
        let right = floor(area.width * min(1, region.maxX)) - (region.maxX < 0.999999 ? halfGap : 0)
        let top = floor(area.height * region.minY) + (region.minY > 0 ? halfGap : 0)
        let bottom = floor(area.height * min(1, region.maxY)) - (region.maxY < 0.999999 ? halfGap : 0)
        guard right > left, bottom > top else { return nil }
        return CGRect(x: area.minX + left, y: area.minY + top, width: right - left, height: bottom - top)
    }

    private static func transfer(_ window: CGRect, displays: [CGRect], index: Int, step: Int,
                                 wrap: Bool, keepAspectRatio: Bool?, screenGap: CGFloat) -> CGRect? {
        guard displays.count > 1 else { return nil }
        let source = displays[index]
        var destination = index + step
        if wrap { destination = (destination % displays.count + displays.count) % displays.count }
        guard displays.indices.contains(destination), destination != index, source.width > 0, source.height > 0 else { return nil }
        let frame = displays[destination]
        let gap = min(max(0, screenGap), max(0, (min(frame.width, frame.height) - 1) / 2))
        let next = frame.insetBy(dx: gap, dy: gap)
        let x = (window.midX - source.minX) / source.width
        let y = (window.midY - source.minY) / source.height
        var size = window.size
        if let keepAspectRatio {
            let scaleX = next.width / source.width
            let scaleY = next.height / source.height
            let scale = min(scaleX, scaleY, next.width / max(1, size.width), next.height / max(1, size.height))
            size = CGSize(width: max(1, (size.width * (keepAspectRatio ? scale : scaleX)).rounded()),
                          height: max(1, (size.height * (keepAspectRatio ? scale : scaleY)).rounded()))
        }
        return CGRect(x: (next.minX + x * next.width - size.width / 2).rounded(),
                      y: (next.minY + y * next.height - size.height / 2).rounded(),
                      width: size.width, height: size.height).fitted(in: next)
    }
}

public struct WindowGeometry: Codable, Equatable {
    public struct Measurement: Codable, Equatable {
        public var value: Double
        public var percentage: Bool

        public init(_ value: Double, percentage: Bool = true) {
            self.value = value
            self.percentage = percentage
        }

        func points(in length: CGFloat) -> CGFloat {
            percentage ? length * value / 100 : value
        }
    }

    public enum Anchor: String, Codable, CaseIterable {
        case topLeft, topCenter, topRight, left, center, right, bottomLeft, bottomCenter, bottomRight

        var factors: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0, y: 0)
            case .topCenter: CGPoint(x: 0.5, y: 0)
            case .topRight: CGPoint(x: 1, y: 0)
            case .left: CGPoint(x: 0, y: 0.5)
            case .center: CGPoint(x: 0.5, y: 0.5)
            case .right: CGPoint(x: 1, y: 0.5)
            case .bottomLeft: CGPoint(x: 0, y: 1)
            case .bottomCenter: CGPoint(x: 0.5, y: 1)
            case .bottomRight: CGPoint(x: 1, y: 1)
            }
        }
    }

    public var anchor: Anchor = .topLeft
    public var width = Measurement(50)
    public var height = Measurement(100)
    public var x = Measurement(0)
    public var y = Measurement(0)

    public init() {}

    public init(region: CGRect) {
        width = Measurement(region.width * 100)
        height = Measurement(region.height * 100)
        x = Measurement(region.minX * 100)
        y = Measurement(region.minY * 100)
    }

    public var isValid: Bool {
        [width, height].allSatisfy { $0.value.isFinite && $0.value > 0 && (!$0.percentage || $0.value <= 100) }
            && [x, y].allSatisfy { $0.value.isFinite && (!$0.percentage || abs($0.value) <= 100) }
    }

    public func frame(in screen: CGRect) -> CGRect? {
        guard isValid else { return nil }
        let w = width.points(in: screen.width).rounded()
        let h = height.points(in: screen.height).rounded()
        guard w > 0, h > 0 else { return nil }
        let position = anchor.factors
        return CGRect(x: (screen.minX + (screen.width - w) * position.x + x.points(in: screen.width)).rounded(),
                      y: (screen.minY + (screen.height - h) * position.y + y.points(in: screen.height)).rounded(),
                      width: w, height: h)
    }
}

private extension CGRect {
    func overlapArea(with rect: CGRect) -> CGFloat {
        let overlap = intersection(rect)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    func distanceSquared(to point: CGPoint) -> CGFloat {
        let x = point.x - max(minX, min(point.x, maxX))
        let y = point.y - max(minY, min(point.y, maxY))
        return x * x + y * y
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
