import CoreGraphics

/// Pure geometry for arranging displays — no system calls, fully testable.
enum DisplayArrangement {

    /// Snap a dragged display so it sits flush against its nearest neighbor with no gap.
    /// Keeps the move on whichever axis the drag favored (left/right vs. above/below),
    /// and clamps the other axis so the two displays still share an edge.
    static func snap(size: CGSize, proposedOrigin: CGPoint, others: [CGRect]) -> CGPoint {
        guard let neighbor = others.min(by: {
            centerDistance($0, proposedOrigin, size) < centerDistance($1, proposedOrigin, size)
        }) else {
            return proposedOrigin
        }

        let proposed = CGRect(origin: proposedOrigin, size: size)
        let dx = proposed.midX - neighbor.midX
        let dy = proposed.midY - neighbor.midY
        var origin = proposedOrigin

        if abs(dx) >= abs(dy) {
            origin.x = dx >= 0 ? neighbor.maxX : neighbor.minX - size.width
            origin.y = clamp(origin.y, neighbor.minY - size.height + 1, neighbor.maxY - 1)
        } else {
            origin.y = dy >= 0 ? neighbor.maxY : neighbor.minY - size.height
            origin.x = clamp(origin.x, neighbor.minX - size.width + 1, neighbor.maxX - 1)
        }
        return origin
    }

    /// True if `rect` overlaps any of `others` by more than a shared edge.
    static func overlaps(_ rect: CGRect, _ others: [CGRect]) -> Bool {
        others.contains { other in
            let intersection = rect.intersection(other)
            return intersection.width > 1 && intersection.height > 1
        }
    }

    /// New origins that shift every display so `mainID` lands at (0, 0), keeping relative offsets.
    static func origins(makingMain mainID: CGDirectDisplayID, from displays: [DisplayInfo]) -> [CGDirectDisplayID: CGPoint] {
        guard let main = displays.first(where: { $0.id == mainID }) else { return [:] }
        let shift = main.frame.origin
        return displays.reduce(into: [:]) { result, display in
            result[display.id] = CGPoint(x: display.frame.minX - shift.x, y: display.frame.minY - shift.y)
        }
    }

    // MARK: - Private

    private static func centerDistance(_ rect: CGRect, _ origin: CGPoint, _ size: CGSize) -> CGFloat {
        let cx = origin.x + size.width / 2 - rect.midX
        let cy = origin.y + size.height / 2 - rect.midY
        return cx * cx + cy * cy
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        max(lower, min(upper, value))
    }
}
