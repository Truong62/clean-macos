import Foundation
import CoreGraphics

enum AnnotationTool: String, Codable, CaseIterable, Identifiable {
    case select, arrow, blur, crop, text, sticker, rectangle, highlighter, pen, line, ellipse, number, block, spotlight, expand
    var id: String { rawValue }
    var title: String { self == .expand ? "Expand canvas" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .blur: "drop.halffull"
        case .crop: "crop"
        case .text: "textformat"
        case .sticker: "face.smiling"
        case .rectangle: "rectangle"
        case .highlighter: "highlighter"
        case .pen: "pencil.tip"
        case .line: "line.diagonal"
        case .ellipse: "oval"
        case .number: "1.circle"
        case .block: "rectangle.fill"
        case .spotlight: "flashlight.on.fill"
        case .expand: "arrow.up.left.and.arrow.down.right"
        }
    }
    var isLine: Bool { self == .line || self == .arrow }
    var hasShadow: Bool { [.arrow, .line, .rectangle, .ellipse, .pen, .number, .text, .sticker].contains(self) }
    var openingTool: Self { [.select, .crop, .expand].contains(self) ? .arrow : self }
}

struct EditorColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1
    static let swatches: [Self] = [
        .init(red: 1, green: 0.23, blue: 0.23), .init(red: 1, green: 0.6, blue: 0),
        .init(red: 1, green: 0.88, blue: 0.1), .init(red: 0.2, green: 0.8, blue: 0.35),
        .init(red: 0.15, green: 0.55, blue: 1), .init(red: 0.7, green: 0.35, blue: 1),
        .init(red: 0.08, green: 0.08, blue: 0.09), .init(red: 1, green: 1, blue: 1)
    ]
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

enum ArrowHead: String, Codable, CaseIterable { case filled, outlined, open, double, wobble }
enum RedactionMode: String, Codable, CaseIterable { case pixelate, blur, erase }
enum EditorFormat: String, Codable, CaseIterable { case png, jpeg, heic }

struct AnnotationStyle: Codable, Equatable {
    var color = EditorColor.swatches[0]
    var width: CGFloat = 4
    var head = ArrowHead.filled
    var fontSize: CGFloat = 19
    var sticker = "✅"
    var redaction = RedactionMode.pixelate
    var strength = 3
    var textOnly = false
    static let fontSizes: [CGFloat] = [10, 12, 14, 16, 19, 24, 28, 32, 40, 48, 64, 96]
    static let stickers = ["✅", "❌", "👍", "👎", "😍", "😂", "🤔", "😮", "⚠️", "🔥", "⭐️", "👀"]
}

struct EditorBackground: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case none, solid, gradient, image }
    var kind = Kind.none
    var first = EditorColor(red: 0.3, green: 0.3, blue: 0.7)
    var second = EditorColor(red: 0.8, green: 0.4, blue: 0.6)
    var image: Data?
    var margin: CGFloat = 0.5
    var corners: CGFloat = 0
    var blur: CGFloat = 0
    static let gradients: [Self] = (0..<5).map { index in
        var look = Self()
        look.kind = .gradient
        look.first = EditorColor.swatches[index + 1]
        look.second = EditorColor.swatches[(index + 3) % 6]
        return look
    }
}

struct EditorWatermark: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case none, text, image }
    var kind = Kind.none
    var text = ""
    var image: Data?
    var color = EditorColor.swatches[7]
    var position = 8
    var size: CGFloat = 0.3
    var opacity: CGFloat = 0.4
    var rotation: CGFloat = 0
}

struct ScreenshotEditorSettings: Codable, Equatable {
    var style = AnnotationStyle()
    var lastTool = AnnotationTool.arrow
    var toolKeys = false
    var fileShortcut = false
    var clipboardShortcut = false
    var toolOrder = AnnotationTool.allCases
    var customKeys: [String: String] = [:]
    var shadows = false
    var dim: CGFloat = 0.5
    var background = EditorBackground()
    var savedBackgrounds: [EditorBackground] = []
    var watermark = EditorWatermark()
    var savedWatermarks: [EditorWatermark] = []
    var expandColor = EditorColor.swatches[7]
    var export1x = false
    var exportFolder = ""
    var namePrefix = "Screenshot"
}

struct AnnotationMark: Identifiable, Equatable {
    var id = UUID()
    var tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text = ""
    var style = AnnotationStyle()
    var image: Data?
    var seed: UInt64 = 1
    var rect: CGRect {
        guard tool == .pen, let first = points.first else { return EditorGeometry.rect(start, end) }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { result, point in
            result.union(CGRect(origin: point, size: .zero))
        }
    }

    mutating func translate(_ delta: CGSize) {
        start.x += delta.width
        start.y += delta.height
        end.x += delta.width
        end.y += delta.height
        points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
    }

    mutating func resize(to newRect: CGRect) {
        let old = rect
        func transform(_ p: CGPoint) -> CGPoint {
            CGPoint(x: newRect.minX + (p.x - old.minX) / max(1, old.width) * newRect.width,
                    y: newRect.minY + (p.y - old.minY) / max(1, old.height) * newRect.height)
        }
        start = transform(start)
        end = transform(end)
        points = points.map(transform)
    }
}

struct ScreenshotDocument: Equatable {
    var base: Data
    var size: CGSize
    var scale: CGFloat = 1
    var sourceFormat = EditorFormat.png
    var marks: [AnnotationMark] = []
    var bounds: CGRect { CGRect(origin: .zero, size: size) }
    func number(for id: UUID) -> Int? {
        marks.filter { $0.tool == .number }.firstIndex { $0.id == id }.map { $0 + 1 }
    }
    mutating func remove(_ id: UUID) { marks.removeAll { $0.id == id } }
    mutating func reorder(_ id: UUID, by offset: Int) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(marks.count - 1, max(0, index + offset))
        let mark = marks.remove(at: index)
        marks.insert(mark, at: destination)
    }
    mutating func replaceBase(_ data: Data, size: CGSize, offset: CGSize) {
        base = data
        self.size = size
        for index in marks.indices { marks[index].translate(offset) }
    }
}

struct EditorHistory {
    private(set) var past: [ScreenshotDocument] = []
    private(set) var future: [ScreenshotDocument] = []
    private(set) var document: ScreenshotDocument
    init(_ document: ScreenshotDocument) { self.document = document }
    mutating func commit(_ next: ScreenshotDocument) {
        guard next != document else { return }
        past.append(document)
        if past.count > 60 { past.removeFirst(past.count - 60) }
        document = next
        future.removeAll()
    }
    mutating func undo() {
        guard let previous = past.popLast() else { return }
        future.append(document)
        document = previous
    }
    mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(document)
        document = next
    }
}

enum EditorGeometry {
    static let pixelLimit: CGFloat = 60_000_000
    static func refill(left: Double, right: Double, top: Double, bottom: Double, u: Double, v: Double) -> Double {
        if top == bottom { return top }
        if left == right { return left }
        return (left * (1 - u) + right * u + top * (1 - v) + bottom * v) / 2
    }
    static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1 && size.width * size.height <= pixelLimit
    }
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    static func fit(_ size: CGSize, in available: CGSize, cap: CGFloat = 1) -> CGFloat {
        max(0.05, min(cap, min(available.width / max(1, size.width), available.height / max(1, size.height))))
    }
    static func downscaled(_ size: CGSize, limit: CGFloat = 6000) -> CGSize {
        let factor = min(1, limit / max(size.width, size.height))
        return CGSize(width: max(1, floor(size.width * factor)), height: max(1, floor(size.height * factor)))
    }
    static func arrow(_ start: CGPoint, _ end: CGPoint, width: CGFloat) -> [CGPoint] {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(10, 3.4 * width)
        return [CGPoint(x: end.x - length * cos(angle - .pi * 26 / 180), y: end.y - length * sin(angle - .pi * 26 / 180)), end,
                CGPoint(x: end.x - length * cos(angle + .pi * 26 / 180), y: end.y - length * sin(angle + .pi * 26 / 180))]
    }
    static func distance(_ point: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / max(0.0001, dx * dx + dy * dy)))
        return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
    }
    static func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }
    static func resized(_ rect: CGRect, handle: Int, to point: CGPoint, proportional: Bool = false) -> CGRect {
        var a = rect.origin, b = CGPoint(x: rect.maxX, y: rect.maxY)
        if [0, 6, 7].contains(handle) { a.x = point.x }
        if [0, 1, 2].contains(handle) { a.y = point.y }
        if [2, 3, 4].contains(handle) { b.x = point.x }
        if [4, 5, 6].contains(handle) { b.y = point.y }
        if proportional && handle % 2 == 0 {
            let ratio = rect.width / max(1, rect.height)
            let h = abs(b.x - a.x) / ratio
            if [0, 2].contains(handle) { a.y = b.y - h * (a.y > b.y ? -1 : 1) }
            else { b.y = a.y + h * (b.y < a.y ? -1 : 1) }
        }
        return Self.rect(a, b)
    }
    static func hit(_ point: CGPoint, marks: [AnnotationMark], tolerance: CGFloat, edgeOnly: Bool = false) -> UUID? {
        for mark in marks.reversed() {
            if mark.tool.isLine {
                if distance(point, to: mark.start, mark.end) <= tolerance + mark.style.width / 2 { return mark.id }
            } else if mark.tool == .pen {
                if zip(mark.points, mark.points.dropFirst()).contains(where: { distance(point, to: $0, $1) <= tolerance + mark.style.width / 2 }) { return mark.id }
            } else {
                let r = mark.rect
                if mark.tool == .ellipse || mark.tool == .number {
                    let d = hypot((point.x - r.midX) / max(1, r.width / 2), (point.y - r.midY) / max(1, r.height / 2))
                    let t = tolerance / max(1, min(r.width, r.height) / 2)
                    if d <= 1 + t && (!(edgeOnly || mark.tool == .ellipse) || d >= 1 - t) { return mark.id }
                } else if r.insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                    if !edgeOnly && (mark.tool != .rectangle || mark.image != nil) || !r.insetBy(dx: tolerance, dy: tolerance).contains(point) { return mark.id }
                }
            }
        }
        return nil
    }
    static func crop(_ rect: CGRect, bounds: CGRect, aspect: CGFloat? = nil) -> CGRect? {
        var r = rect.standardized
        if let aspect, aspect.isFinite, aspect > 0 { r.size.height = r.width / aspect }
        r = r.intersection(bounds)
        guard !r.isNull else { return nil }
        if let aspect, aspect.isFinite, aspect > 0 {
            if r.width / max(1, r.height) > aspect { r.size.width = r.height * aspect }
            else { r.size.height = r.width / aspect }
        }
        r = CGRect(x: ceil(r.minX), y: ceil(r.minY), width: floor(r.maxX) - ceil(r.minX), height: floor(r.maxY) - ceil(r.minY))
        return r.width >= 8 && r.height >= 8 ? r : nil
    }
    static func moved(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        CGRect(x: min(max(bounds.minX, rect.minX + delta.width), bounds.maxX - rect.width),
               y: min(max(bounds.minY, rect.minY + delta.height), bounds.maxY - rect.height), width: rect.width, height: rect.height)
    }
    static func expanded(_ bounds: CGRect, to point: CGPoint) -> CGRect? {
        let r = bounds.union(CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)).integral
        return valid(r.size) ? r : nil
    }
    static func stickerSide(_ size: CGSize, scale: CGFloat) -> CGFloat {
        let side = min(size.width, size.height)
        return max(min(52 * scale, 0.45 * side), min(0.16 * side, 128 * scale))
    }
    static func numberDiameter(_ size: CGSize) -> CGFloat { max(22, min(size.width, size.height) / 24) }
    static func margin(_ size: CGSize, value: CGFloat) -> CGFloat { max(24, min(size.width, size.height) * (0.035 + 0.14 * max(0, min(1, value)))) }
    static func corner(_ size: CGSize, value: CGFloat) -> CGFloat { max(0, min(1, value)) * 0.2 * min(size.width, size.height) }
    static func watermark(_ natural: CGSize, canvas: CGSize, position: Int, corners: CGFloat, rotation: CGFloat) -> CGRect {
        let margin = max(min(canvas.width, canvas.height) * 0.05, corners * 0.3)
        let angle = rotation * .pi / 180
        let rotated = CGSize(width: abs(natural.width * cos(angle)) + abs(natural.height * sin(angle)), height: abs(natural.width * sin(angle)) + abs(natural.height * cos(angle)))
        let factor = min(1, min(max(1, canvas.width - 2 * margin) / max(1, rotated.width), max(1, canvas.height - 2 * margin) / max(1, rotated.height)))
        let size = CGSize(width: natural.width * factor, height: natural.height * factor)
        let box = CGSize(width: rotated.width * factor, height: rotated.height * factor)
        let p = max(0, min(8, position))
        return CGRect(x: margin + (canvas.width - 2 * margin - box.width) * CGFloat(p % 3) / 2 + (box.width - size.width) / 2,
                      y: margin + (canvas.height - 2 * margin - box.height) * CGFloat(p / 3) / 2 + (box.height - size.height) / 2, width: size.width, height: size.height)
    }
    static func bands(size: CGSize) -> [CGRect] {
        guard valid(size) else { return [] }
        let height = max(1, min(4096, Int(12_000_000 / size.width)))
        let overlap = min(256, height / 4)
        var result: [CGRect] = [], y = 0
        while y < Int(size.height) {
            let rows = min(height, Int(size.height) - y)
            result.append(CGRect(x: 0, y: y, width: Int(size.width), height: rows))
            if y + rows == Int(size.height) { break }
            y += max(1, rows - overlap)
        }
        return result
    }
}

enum EditorExport {
    static func format(source: EditorFormat, transparent: Bool) -> EditorFormat { transparent ? .png : source }
    static func filename(prefix: String, date: Date, format: EditorFormat, existing: Set<String>) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let clean = prefix.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let base = "\(clean.isEmpty ? "Screenshot" : String(clean.prefix(100))) \(formatter.string(from: date))"
        var name = "\(base).\(format.rawValue)", suffix = 2
        while existing.contains(name) { name = "\(base) (\(suffix)).\(format.rawValue)"; suffix += 1 }
        return name
    }
    static func keyConflict(_ key: String, tool: AnnotationTool, assignments: [String: String], external: [String: String]) -> String? {
        let key = key.lowercased()
        if ["escape", "return", "enter", "delete", "forwarddelete", "⌘c", "⌘v", "⌘s", "⌘z", "⌘p", "⌘0", "⌘1", "⌘=", "⌘+", "⌘-", "⌘w", "⌘q"].contains(key) { return "Editor command" }
        if let owner = external[key] { return owner }
        return assignments.first { $0.key != tool.rawValue && $0.value.lowercased() == key }?.key.capitalized
    }
}

extension ScreenshotEditorSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = try values.decodeIfPresent(AnnotationStyle.self, forKey: .style) ?? style
        lastTool = try values.decodeIfPresent(AnnotationTool.self, forKey: .lastTool) ?? lastTool
        toolKeys = try values.decodeIfPresent(Bool.self, forKey: .toolKeys) ?? toolKeys
        fileShortcut = try values.decodeIfPresent(Bool.self, forKey: .fileShortcut) ?? fileShortcut
        clipboardShortcut = try values.decodeIfPresent(Bool.self, forKey: .clipboardShortcut) ?? clipboardShortcut
        let order = try values.decodeIfPresent([AnnotationTool].self, forKey: .toolOrder) ?? toolOrder
        toolOrder = order.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        toolOrder += AnnotationTool.allCases.filter { !toolOrder.contains($0) }
        customKeys = try values.decodeIfPresent([String: String].self, forKey: .customKeys) ?? customKeys
        shadows = try values.decodeIfPresent(Bool.self, forKey: .shadows) ?? shadows
        dim = max(0, min(1, try values.decodeIfPresent(CGFloat.self, forKey: .dim) ?? dim))
        background = try values.decodeIfPresent(EditorBackground.self, forKey: .background) ?? background
        savedBackgrounds = Array((try values.decodeIfPresent([EditorBackground].self, forKey: .savedBackgrounds) ?? savedBackgrounds).prefix(12))
        watermark = try values.decodeIfPresent(EditorWatermark.self, forKey: .watermark) ?? watermark
        savedWatermarks = Array((try values.decodeIfPresent([EditorWatermark].self, forKey: .savedWatermarks) ?? savedWatermarks).prefix(12))
        expandColor = try values.decodeIfPresent(EditorColor.self, forKey: .expandColor) ?? expandColor
        export1x = try values.decodeIfPresent(Bool.self, forKey: .export1x) ?? export1x
        exportFolder = try values.decodeIfPresent(String.self, forKey: .exportFolder) ?? exportFolder
        namePrefix = try values.decodeIfPresent(String.self, forKey: .namePrefix) ?? namePrefix
    }
}

enum EditorKeyMap {
    static func assigning(_ key: String, to tool: AnnotationTool, settings: ScreenshotEditorSettings, external: [String: String] = [:]) -> Result<ScreenshotEditorSettings, Conflict> {
        var result = settings
        let key = key.lowercased()
        if key.isEmpty { result.customKeys.removeValue(forKey: tool.rawValue); return .success(result) }
        if let owner = EditorExport.keyConflict(key, tool: tool, assignments: settings.customKeys, external: external) { return .failure(Conflict(owner: owner)) }
        if let digit = Int(key), (1...9).contains(digit), let index = result.toolOrder.firstIndex(of: tool) {
            result.toolOrder.swapAt(index, digit - 1)
            result.customKeys.removeValue(forKey: tool.rawValue)
        } else { result.customKeys[tool.rawValue] = key }
        return .success(result)
    }
    struct Conflict: Error, Equatable { let owner: String }
}
