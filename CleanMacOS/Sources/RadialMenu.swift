import CoreGraphics
import Foundation

enum RadialGeometry {
    static let deadZone: CGFloat = 40

    static func slice(at point: CGPoint, center: CGPoint, count: Int, deadZone: CGFloat = deadZone) -> Int? {
        guard count > 0 else { return nil }
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        guard hypot(dx, dy) >= Double(deadZone) else { return nil }
        var angle = atan2(dx, dy) * 180 / .pi
        if angle < 0 { angle += 360 }
        let width = 360 / Double(count)
        return Int(((angle + width / 2) / width).rounded(.down)) % count
    }

    static func chipOffset(index: Int, count: Int, radius: CGFloat) -> CGPoint {
        let angle = Double(index) * 2 * .pi / Double(max(count, 1))
        return CGPoint(x: radius * CGFloat(sin(angle)), y: radius * CGFloat(cos(angle)))
    }
}

struct RadialTracker {
    static let movement: CGFloat = 8

    let origin: CGPoint
    private(set) var hasMoved = false

    mutating func highlight(at point: CGPoint, center: CGPoint, count: Int) -> Int? {
        if !hasMoved && hypot(point.x - origin.x, point.y - origin.y) >= Self.movement { hasMoved = true }
        guard hasMoved else { return nil }
        return RadialGeometry.slice(at: point, center: center, count: count)
    }
}

enum GridMove {
    enum Key {
        case left, right, up, down
    }

    static func next(from index: Int, key: Key, count: Int, columns: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let target = switch key {
        case .left: index - 1
        case .right: index + 1
        case .up: index - columns
        case .down: index + columns
        }
        if (0..<count).contains(target) { return target }
        if key == .down, index / columns < (count - 1) / columns { return count - 1 }
        return index
    }
}

struct RadialSlice: Codable, Identifiable, Equatable {
    enum Action: Codable, Equatable {
        case command(String)
        case app(String)
        case folder(String)
        case link(String)
        case media(Int)
    }

    var id = UUID()
    var title: String
    var symbol: String
    var action: Action
}

struct RadialSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case pressOrHold, press, hold

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pressOrHold: "Press or hold"
            case .press: "Press"
            case .hold: "Hold"
            }
        }
    }

    static let maxSlices = 12
    static let mediaPlay = 16
    static let mediaNext = 17
    static let mediaPrevious = 18
    static let general = [
        RadialSlice(title: "Play/Pause", symbol: "playpause.fill", action: .media(mediaPlay)),
        RadialSlice(title: "Next", symbol: "forward.fill", action: .media(mediaNext)),
        RadialSlice(title: "Clipboard", symbol: "doc.on.clipboard", action: .command("clipboardHistory")),
        RadialSlice(title: "Downloads", symbol: "arrow.down.circle", action: .folder("~/Downloads")),
        RadialSlice(title: "Keep Awake", symbol: "cup.and.saucer.fill", action: .command("keepAwake")),
        RadialSlice(title: "Previous", symbol: "backward.fill", action: .media(mediaPrevious)),
    ]
    static let media = [
        RadialSlice(title: "Play/Pause", symbol: "playpause.fill", action: .media(mediaPlay)),
        RadialSlice(title: "Next", symbol: "forward.fill", action: .media(mediaNext)),
        RadialSlice(title: "Switch Output", symbol: "hifispeaker.2.fill", action: .command("cycleOutput")),
        RadialSlice(title: "Mute Mics", symbol: "mic.slash.fill", action: .command("micMute")),
        RadialSlice(title: "Previous", symbol: "backward.fill", action: .media(mediaPrevious)),
    ]

    var isEnabled = false
    var mode = Mode.pressOrHold
    var opensAtPointer = true
    var mouseButton: Int?
    var slices = RadialSettings.general
}
