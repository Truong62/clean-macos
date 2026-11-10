import SwiftUI

struct IslandHotZone {
    var frame: CGRect
    private var path: Path

    init(frame: CGRect, capsule: Bool, neckWidth: CGFloat = 0, neckHeight: CGFloat = 0) {
        self.frame = frame
        path = IslandSilhouette(capsule: capsule, neckWidth: neckWidth, neckHeight: neckHeight).path(in: CGRect(origin: .zero, size: frame.size))
    }

    func contains(_ point: CGPoint) -> Bool {
        guard frame.contains(point) else { return false }
        return path.contains(CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y))
    }
}

struct IslandPointerTracking {
    private(set) var inside = false
    private(set) var hiddenTrigger = false

    mutating func update(inside: Bool, hiddenTrigger: Bool) -> Bool {
        let changed = self.inside != inside || self.hiddenTrigger != hiddenTrigger
        self.inside = inside
        self.hiddenTrigger = hiddenTrigger
        return changed
    }
}

struct IslandLayoutCoalescer {
    let interval: Double
    private(set) var pending = false
    private var last = -Double.infinity

    init(interval: Double = 1 / 60) { self.interval = interval }

    mutating func request(at time: Double) -> Double? {
        guard !pending, time.isFinite else { return nil }
        pending = true
        return max(0, last + interval - time)
    }

    mutating func finish(at time: Double) {
        pending = false
        last = time
    }

    mutating func cancel() { pending = false }
}

struct IslandPanelLayout: Equatable {
    var frame: CGRect
    var keyboard: Bool
    var ignoresMouse: Bool
    var alpha: Double
    var level: Int
    var captures: Bool
}

enum IslandDismissal {
    static func shouldClose(open: Bool, insidePanel: Bool, insideCopy: Bool, belowMenu: Bool) -> Bool {
        open && !insidePanel && !insideCopy && belowMenu
    }
}
