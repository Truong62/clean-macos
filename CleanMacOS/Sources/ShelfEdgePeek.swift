import Foundation

struct ShelfEdge: Equatable {
    enum Side: Equatable { case left, right }
    let screen: CGRect
    let visible: CGRect
    let side: Side

    var x: CGFloat { side == .left ? screen.minX : screen.maxX }

    func frame(at point: CGPoint, size: CGSize, peeking: Bool) -> CGRect {
        let inset: CGFloat = peeking ? -size.width * 2 / 3 : 8
        let left = side == .left ? visible.minX + inset : visible.maxX - size.width - inset
        let bottom = min(max(point.y - size.height / 2, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        return CGRect(origin: CGPoint(x: left, y: bottom), size: size)
    }

    func isTooFar(_ point: CGPoint) -> Bool {
        abs(point.x - x) > 330 || point.y < screen.minY - 330 || point.y > screen.maxY + 330
    }

    static func candidate(at point: CGPoint, screens: [(frame: CGRect, visible: CGRect)]) -> ShelfEdge? {
        for display in screens where display.frame.contains(point) {
            for side in [Side.left, .right] {
                let edge = ShelfEdge(screen: display.frame, visible: display.visible, side: side)
                guard abs(point.x - edge.x) <= 200 else { continue }
                let dock = side == .left ? point.x < display.visible.minX : point.x > display.visible.maxX
                guard !dock else { continue }
                let shared = screens.contains { other in
                    guard other.frame != display.frame else { return false }
                    let opposite = side == .left ? other.frame.maxX : other.frame.minX
                    return abs(opposite - edge.x) < 1 && min(other.frame.maxY, display.frame.maxY) > max(other.frame.minY, display.frame.minY)
                }
                if !shared { return edge }
            }
        }
        return nil
    }
}

struct ShelfEdgeDwell {
    private var edge: ShelfEdge?
    private var started: TimeInterval = 0

    mutating func update(_ candidate: ShelfEdge?, at time: TimeInterval) -> ShelfEdge? {
        guard let candidate else { edge = nil; return nil }
        if edge != candidate { edge = candidate; started = time; return nil }
        return time - started >= 0.15 ? candidate : nil
    }

    mutating func reset() { edge = nil }
}
