import Foundation
import CoreGraphics

enum CaptureMode: Int, CaseIterable, Identifiable {
    case screenshot = 1, recording = 2, text = 3, color = 4, scrolling = 5
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .screenshot: "Screenshot"
        case .recording: "Recording"
        case .text: "Text grab"
        case .color: "Color picker"
        case .scrolling: "Scrolling"
        }
    }
}

enum CaptureAction: String, Codable, CaseIterable { case ask, save, saveAndCopy, copy, edit }
enum CaptureCorner: String, Codable, CaseIterable { case auto, topLeft, topRight, bottomLeft, bottomRight }

struct ScreenshotSettings: Codable, Equatable {
    var areaShortcut = false
    var scrollingShortcut = false
    var displayShortcut = false
    var latestShortcut = false
    var clipboardShortcut = false
    var uploadShortcut = false
    var historyShortcut = false
    var menuTile = false
    var freeze = false
    var includePointer = false
    var saveAt1x = false
    var hideOwnWindows = false
    var autoCopy = false
    var imageOnly = false
    var autoShelf = false
    var automaticScroll = false
    var showModes = false
    var showPreviousArea = false
    var highlightWindows = false
    var magnifier = false
    var rememberZoom = false
    var stepZoom = false
    var confirmationPreview = false
    var previewTakesFocus = false
    var allowLinks = false
    var delay = 0
    var zoom = 1.0
    var confirmationSeconds = 3
    var action = CaptureAction.ask
    var corner = CaptureCorner.auto
    var folder = ""
    var subfolder = ""
    var pattern = ""
    var counter = 1
    var linkHours = 1
    var backend = ""
}

extension ScreenshotSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        areaShortcut = try c.decodeIfPresent(Bool.self, forKey: .areaShortcut) ?? false
        scrollingShortcut = try c.decodeIfPresent(Bool.self, forKey: .scrollingShortcut) ?? false
        displayShortcut = try c.decodeIfPresent(Bool.self, forKey: .displayShortcut) ?? false
        latestShortcut = try c.decodeIfPresent(Bool.self, forKey: .latestShortcut) ?? false
        clipboardShortcut = try c.decodeIfPresent(Bool.self, forKey: .clipboardShortcut) ?? false
        uploadShortcut = try c.decodeIfPresent(Bool.self, forKey: .uploadShortcut) ?? false
        historyShortcut = try c.decodeIfPresent(Bool.self, forKey: .historyShortcut) ?? false
        menuTile = try c.decodeIfPresent(Bool.self, forKey: .menuTile) ?? false
        freeze = try c.decodeIfPresent(Bool.self, forKey: .freeze) ?? false
        includePointer = try c.decodeIfPresent(Bool.self, forKey: .includePointer) ?? false
        saveAt1x = try c.decodeIfPresent(Bool.self, forKey: .saveAt1x) ?? false
        hideOwnWindows = try c.decodeIfPresent(Bool.self, forKey: .hideOwnWindows) ?? false
        autoCopy = try c.decodeIfPresent(Bool.self, forKey: .autoCopy) ?? false
        imageOnly = try c.decodeIfPresent(Bool.self, forKey: .imageOnly) ?? false
        autoShelf = try c.decodeIfPresent(Bool.self, forKey: .autoShelf) ?? false
        automaticScroll = try c.decodeIfPresent(Bool.self, forKey: .automaticScroll) ?? false
        showModes = try c.decodeIfPresent(Bool.self, forKey: .showModes) ?? false
        showPreviousArea = try c.decodeIfPresent(Bool.self, forKey: .showPreviousArea) ?? false
        highlightWindows = try c.decodeIfPresent(Bool.self, forKey: .highlightWindows) ?? false
        magnifier = try c.decodeIfPresent(Bool.self, forKey: .magnifier) ?? false
        rememberZoom = try c.decodeIfPresent(Bool.self, forKey: .rememberZoom) ?? false
        stepZoom = try c.decodeIfPresent(Bool.self, forKey: .stepZoom) ?? false
        confirmationPreview = try c.decodeIfPresent(Bool.self, forKey: .confirmationPreview) ?? false
        previewTakesFocus = try c.decodeIfPresent(Bool.self, forKey: .previewTakesFocus) ?? false
        allowLinks = try c.decodeIfPresent(Bool.self, forKey: .allowLinks) ?? false
        delay = try c.decodeIfPresent(Int.self, forKey: .delay) ?? 0
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1.0
        confirmationSeconds = try c.decodeIfPresent(Int.self, forKey: .confirmationSeconds) ?? 3
        action = try c.decodeIfPresent(CaptureAction.self, forKey: .action) ?? CaptureAction.ask
        corner = try c.decodeIfPresent(CaptureCorner.self, forKey: .corner) ?? CaptureCorner.auto
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        subfolder = try c.decodeIfPresent(String.self, forKey: .subfolder) ?? ""
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        counter = try c.decodeIfPresent(Int.self, forKey: .counter) ?? 1
        linkHours = try c.decodeIfPresent(Int.self, forKey: .linkHours) ?? 1
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? ""
        delay = [0, 3, 5, 10].contains(delay) ? delay : 0
        zoom = min(4.3, max(0.5, zoom.isFinite ? zoom : 1))
        counter = min(999_999, max(0, counter))
    }
}

enum CaptureGeometry {
    static func drag(from start: CGPoint, to end: CGPoint, bounds: CGRect, square: Bool = false, centered: Bool = false) -> CGRect {
        var dx = end.x - start.x
        var dy = end.y - start.y
        if square {
            let edge = min(abs(dx), abs(dy))
            dx = dx < 0 ? -edge : edge
            dy = dy < 0 ? -edge : edge
        }
        let rect = centered ? CGRect(x: start.x - abs(dx), y: start.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
            : CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy))
        return rect.intersection(bounds)
    }

    static func move(_ rect: CGRect, dx: CGFloat, dy: CGFloat, bounds: CGRect) -> CGRect {
        CGRect(x: min(max(bounds.minX, rect.minX + dx), bounds.maxX - rect.width),
               y: min(max(bounds.minY, rect.minY + dy), bounds.maxY - rect.height), width: rect.width, height: rect.height)
    }

    static func resize(_ rect: CGRect, handle: CGPoint, to point: CGPoint, bounds: CGRect, aspect: CGFloat? = nil) -> CGRect {
        let anchor = CGPoint(x: handle.x == 0 ? rect.maxX : rect.minX, y: handle.y == 0 ? rect.maxY : rect.minY)
        var end = point
        if let aspect, aspect > 0 {
            end.y = anchor.y + (point.y < anchor.y ? -1 : 1) * abs(point.x - anchor.x) / aspect
        }
        return drag(from: anchor, to: end, bounds: bounds)
    }

    static func pixels(_ rect: CGRect, scale: CGFloat, even: Bool = false) -> CGRect {
        let unit: CGFloat = even ? 2 : 1
        return CGRect(x: (rect.minX * scale / unit).rounded(.down) * unit,
                      y: (rect.minY * scale / unit).rounded(.down) * unit,
                      width: max(unit, (rect.width * scale / unit).rounded(.down) * unit),
                      height: max(unit, (rect.height * scale / unit).rounded(.down) * unit))
    }

    static func pixel(at point: CGPoint, size: CGSize, imageSize: CGSize) -> CGPoint {
        CGPoint(x: min(imageSize.width - 1, max(0, floor(point.x * imageSize.width / max(1, size.width)))),
                y: min(imageSize.height - 1, max(0, floor(point.y * imageSize.height / max(1, size.height)))))
    }

    static func nudge(_ point: CGPoint, x: Int, y: Int, shift: Bool, size: CGSize) -> CGPoint {
        let step = shift ? 10 : 1
        return CGPoint(x: min(size.width - 1, max(0, point.x + CGFloat(x * step))),
                       y: min(size.height - 1, max(0, point.y + CGFloat(y * step))))
    }

    static func zoom(_ current: Double, delta: Double, stepped: Bool) -> Double {
        guard delta != 0 else { return current }
        if stepped {
            let levels = [0.5, 1, 2, 4, 4.3]
            return delta > 0 ? levels.first(where: { $0 > current + 0.001 }) ?? 4.3 : levels.last(where: { $0 < current - 0.001 }) ?? 0.5
        }
        return min(4.3, max(0.5, current * pow(1.15, delta)))
    }

    static func sample(_ image: CGImage, at point: CGPoint) -> ClipboardColor? {
        guard point.x >= 0, point.y >= 0, point.x < CGFloat(image.width), point.y < CGFloat(image.height),
              let pixel = image.cropping(to: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        let ok = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        let alpha = Double(data[3])
        return ClipboardColor(red: alpha == 0 ? 0 : Double(data[0]) / alpha, green: alpha == 0 ? 0 : Double(data[1]) / alpha,
                              blue: alpha == 0 ? 0 : Double(data[2]) / alpha, alpha: alpha / 255)
    }
}

struct CaptureRegions {
    private(set) var areas: [UInt32: CGRect] = [:]
    mutating func remember(_ area: CGRect, display: UInt32) {
        if area.width >= 2, area.height >= 2 { areas[display] = area }
    }
    func repeatArea(display: UInt32, bounds: CGRect, connected: Set<UInt32>) -> CGRect? {
        guard connected.contains(display), let area = areas[display], bounds.contains(area) else { return nil }
        return area
    }
}

struct CaptureWindow: Equatable {
    let id: UInt32
    let owner: Int32
    let title: String
    let frame: CGRect
    var layer = 0
    var alpha = 1.0
    var onScreen = true
}

enum CaptureWindows {
    static func sheets(for parent: CaptureWindow, windows: [CaptureWindow], standardIDs: Set<UInt32> = []) -> [CaptureWindow] {
        guard let index = windows.firstIndex(where: { $0.id == parent.id }) else { return [] }
        return windows.prefix(index).filter {
            $0.owner == parent.owner && $0.layer == 0 && $0.alpha > 0.05 && $0.onScreen && parent.frame.contains($0.frame) &&
                $0.frame != parent.frame && !standardIDs.contains($0.id)
        }.reversed()
    }

    static func hit(_ point: CGPoint, windows: [CaptureWindow], excluding: Set<UInt32>) -> CaptureWindow? {
        let eligible = windows.filter { $0.onScreen && $0.layer == 0 && $0.alpha > 0.05 && $0.frame.width >= 40 && $0.frame.height >= 40 && !excluding.contains($0.id) }
        return eligible.first { window in
            guard window.frame.contains(point) else { return false }
            guard window.title.isEmpty else { return true }
            return !eligible.contains { inner in
                guard inner.id != window.id, inner.owner == window.owner, inner.frame.contains(point) else { return false }
                let margins = [inner.frame.minX - window.frame.minX, inner.frame.minY - window.frame.minY,
                               window.frame.maxX - inner.frame.maxX, window.frame.maxY - inner.frame.maxY]
                return margins.allSatisfy { $0 >= 1 && $0 <= 32 } && (margins.max()! - margins.min()!) <= 1
            }
        }
    }
}

enum CaptureNames {
    static func expand(_ pattern: String, date: Date, counter: Int, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var result = pattern
        for token in ["yyyy", "MMMM", "MMM", "yy", "MM", "dd", "HH", "mm", "ss"] {
            formatter.dateFormat = token
            result = result.replacingOccurrences(of: "{\(token)}", with: formatter.string(from: date))
        }
        if let expression = try? NSRegularExpression(pattern: #"\{n+\}"#) {
            let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: String(format: "%0*d", min(12, match.range.length - 2), counter))
            }
        }
        return result
    }

    static func filename(pattern: String, date: Date, counter: Int, timeZone: TimeZone = .current) -> String {
        let pattern = pattern.isEmpty ? "Screenshot {yyyy}-{MM}-{dd} at {HH}.{mm}.{ss}" : pattern
        let name = expand(pattern, date: date, counter: counter, timeZone: timeZone)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty || name == "." || name == ".." ? "Screenshot" : String(name.prefix(220))) + ".png"
    }

    static func subfolders(_ pattern: String, date: Date) -> [String] {
        expand(pattern, date: date, counter: 0).split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func usesCounter(_ pattern: String) -> Bool { pattern.range(of: #"\{n+\}"#, options: .regularExpression) != nil }

    static func available(_ proposed: URL, exists: (URL) -> Bool) -> URL? {
        if !exists(proposed) { return proposed }
        for index in 2...9999 {
            let url = proposed.deletingPathExtension().appendingPathExtension("png")
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(index).png")
            if !exists(candidate) { return candidate }
        }
        return nil
    }
}

enum CaptureMediaKind: String, Codable { case screenshot, recording }

struct CaptureHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let filename: String
    let bytes: Int
    let scale: Double
    var kind = CaptureMediaKind.screenshot
}

extension CaptureHistoryEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        kind = try c.decodeIfPresent(CaptureMediaKind.self, forKey: .kind) ?? .screenshot
    }
}

enum CaptureRetention {
    static func keep(_ entries: [CaptureHistoryEntry], count: Int = 12, bytes: Int = 256 * 1024 * 1024) -> [CaptureHistoryEntry] {
        var total = 0
        return entries.sorted { $0.date > $1.date }.prefix(max(1, count)).enumerated().compactMap { index, entry in
            let cost = entry.kind == .screenshot ? max(1, entry.bytes) : 0
            guard index == 0 || total + cost <= bytes else { return nil }
            total += cost
            return entry
        }
    }
}

struct GrayFrame: Equatable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    var valid: Bool { width > 0 && height > 0 && pixels.count == width * height }
}

enum ScrollOverlap {
    static func shift(previous: GrayFrame, next: GrayFrame) -> Int? {
        guard previous.valid, next.valid, previous.width == next.width, previous.height == next.height else { return nil }
        let w = previous.width
        let h = previous.height
        let run = max(8, min(28, h / 12))
        let maxShift = min(h - 8, Int(Double(h) * 0.88))
        guard maxShift >= 2, h >= run else { return nil }
        let sampled = stride(from: 0, to: w, by: max(1, w / 256)).map { x -> (Int, Int) in
            var variation = 0
            for y in 1..<h { variation += abs(Int(previous.pixels[y * w + x]) - Int(previous.pixels[(y - 1) * w + x])) }
            return (x, variation)
        }.sorted { $0.1 > $1.1 }.prefix(32).filter { $0.1 > h }
        guard !sampled.isEmpty else { return nil }
        var matches: [(Int, Int)] = []
        for shift in 2...maxShift {
            var consecutive = 0
            var best = 0
            var matching = 0
            for row in 0..<(h - shift) {
                let error = sampled.reduce(0) { $0 + abs(Int(previous.pixels[(row + shift) * w + $1.0]) - Int(next.pixels[row * w + $1.0])) }
                if error <= sampled.count * 3 { consecutive += 1; matching += 1 } else { consecutive = 0 }
                best = max(best, consecutive)
            }
            if best >= run, matching >= (h - shift) * 2 / 3 { matches.append((shift, matching)) }
        }
        guard matches.count == 1 else { return nil }
        return matches[0].0
    }

    static func fixedFooter(previous: GrayFrame, next: GrayFrame) -> Int {
        guard previous.valid, next.valid, previous.width == next.width, previous.height == next.height else { return 0 }
        var rows = 0
        for y in (0..<previous.height).reversed() {
            let range = (y * previous.width)..<((y + 1) * previous.width)
            if previous.pixels[range] != next.pixels[range] { break }
            rows += 1
        }
        return rows >= max(4, min(12, previous.height / 100)) && rows < previous.height / 3 ? rows : 0
    }
}

struct ScrollBudget {
    var frames = 0
    var height = 0
    let width: Int
    let started: Date
    mutating func accept(rows: Int, now: Date) -> Bool {
        guard width > 0, frames < 512, now.timeIntervalSince(started) < 120,
              rows >= 0, height + rows <= 60_000_000 / width else { return false }
        frames += 1
        height += rows
        return true
    }
}

struct ScrollTracker {
    enum Update: Equatable { case unchanged, append(Int, Int), repositioned, mismatch }
    private var previous: GrayFrame?
    private(set) var position = 0
    private(set) var furthest = 0

    mutating func ingest(_ frame: GrayFrame) -> Update {
        guard frame.valid else { return .mismatch }
        guard let previous else { self.previous = frame; return .append(frame.height, 0) }
        guard previous.width == frame.width, previous.height == frame.height else { return .mismatch }
        if previous == frame { return .unchanged }
        if let shift = ScrollOverlap.shift(previous: previous, next: frame) {
            position += shift
            let rows = max(0, position - furthest)
            furthest = max(furthest, position)
            self.previous = frame
            return rows == 0 ? .repositioned : .append(rows, ScrollOverlap.fixedFooter(previous: previous, next: frame))
        }
        if let shift = ScrollOverlap.shift(previous: frame, next: previous) {
            position -= shift
            self.previous = frame
            return .repositioned
        }
        return .mismatch
    }
}

enum CapturePlacement {
    static func preview(size: CGSize, screen: CGRect, area: CGRect?, pointer: CGPoint, corner: CaptureCorner) -> CGPoint {
        let inset = screen.insetBy(dx: corner == .auto ? 10 : 16, dy: corner == .auto ? 10 : 16)
        var point = CGPoint(x: inset.maxX - size.width, y: inset.minY)
        switch corner {
        case .topLeft: point = CGPoint(x: inset.minX, y: inset.maxY - size.height)
        case .topRight: point.y = inset.maxY - size.height
        case .bottomLeft: point.x = inset.minX
        case .bottomRight: break
        case .auto:
            if let area {
                if area.maxX + 14 + size.width <= inset.maxX { point = CGPoint(x: area.maxX + 14, y: area.midY - size.height / 2) }
                else if area.minX - 14 - size.width >= inset.minX { point = CGPoint(x: area.minX - 14 - size.width, y: area.midY - size.height / 2) }
                else { point = CGPoint(x: pointer.x + 14, y: pointer.y - size.height - 14) }
            }
        }
        point.x = min(max(point.x, inset.minX), max(inset.minX, inset.maxX - size.width))
        point.y = min(max(point.y, inset.minY), max(inset.minY, inset.maxY - size.height))
        return point
    }
}
