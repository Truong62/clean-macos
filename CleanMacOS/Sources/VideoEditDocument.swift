import Foundation
import CoreGraphics

struct RecorderSettings: Codable, Equatable {
    var menuTile = false
    var shortcut = false
    var systemAudio = false
    var microphone = false
    var opensEditor = false
    var automaticZooms = false
    var pointer = false
    var typing = false
    var countdown = 3
    var framesPerSecond = 60
    var gifFPS = 12
    var folder = ""
    var quality = VideoQuality.balanced
}

extension RecorderSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menuTile = try c.decodeIfPresent(Bool.self, forKey: .menuTile) ?? false
        shortcut = try c.decodeIfPresent(Bool.self, forKey: .shortcut) ?? false
        systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? false
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
        opensEditor = try c.decodeIfPresent(Bool.self, forKey: .opensEditor) ?? false
        automaticZooms = try c.decodeIfPresent(Bool.self, forKey: .automaticZooms) ?? false
        pointer = try c.decodeIfPresent(Bool.self, forKey: .pointer) ?? false
        typing = try c.decodeIfPresent(Bool.self, forKey: .typing) ?? false
        countdown = try c.decodeIfPresent(Int.self, forKey: .countdown) ?? 3
        framesPerSecond = try c.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? 60
        gifFPS = try c.decodeIfPresent(Int.self, forKey: .gifFPS) ?? 12
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        quality = try c.decodeIfPresent(VideoQuality.self, forKey: .quality) ?? .balanced
    }
}

enum VideoQuality: String, Codable, CaseIterable {
    case small, balanced, high
    var bits: Double { self == .small ? 0.05 : self == .balanced ? 0.06 : 0.09 }
    var keyframes: Double { self == .high ? 2 : 10 }
}

enum RecordingRegion {
    static func fit(_ rect: CGRect, in bounds: CGRect, scale: CGFloat) -> CGRect? {
        guard scale.isFinite, scale > 0, !rect.isNull, !rect.isInfinite else { return nil }
        let clipped = rect.standardized.intersection(bounds)
        guard !clipped.isNull else { return nil }
        let x = ceil(clipped.minX * scale), y = ceil(clipped.minY * scale)
        let width = floor((clipped.maxX * scale - x) / 2) * 2
        let height = floor((clipped.maxY * scale - y) / 2) * 2
        guard width >= 32, height >= 32 else { return nil }
        return CGRect(x: x / scale, y: y / scale, width: width / scale, height: height / scale)
    }
}

struct VideoSpan: Codable, Equatable {
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
    func contains(_ time: Double) -> Bool { start <= time && time < end }
}

struct VideoZoom: Codable, Equatable, Identifiable {
    var id = UUID()
    var span: VideoSpan
    var strength = 1.8
    var focus: CGPoint?
}

struct VideoPointerSample: Codable, Equatable {
    var time: Double
    var point: CGPoint
    var visible = true
    var pressed = false
    var shape: String?
    var scale = 1.0
}

struct VideoTracks: Codable, Equatable {
    var cursors: [String: VideoCursorShape] = [:]
    var displayScale = 1.0
    var pointer: [VideoPointerSample] = []
    var clicks: [Double] = []
    var typing: [Double] = []
}

enum VideoTimeline {
    static func merged(_ spans: [VideoSpan], within bounds: VideoSpan) -> [VideoSpan] {
        let sorted = spans.filter { $0.start.isFinite && $0.end.isFinite }.map {
            VideoSpan(start: max(bounds.start, $0.start), end: min(bounds.end, $0.end))
        }.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var result: [VideoSpan] = []
        for span in sorted {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1].end = max(last.end, span.end)
            } else { result.append(span) }
        }
        return result
    }

    static func kept(trim: VideoSpan, cuts: [VideoSpan]) -> [VideoSpan] {
        var result: [VideoSpan] = []
        var start = trim.start
        for cut in merged(cuts, within: trim) {
            if cut.start > start { result.append(VideoSpan(start: start, end: cut.start)) }
            start = cut.end
        }
        if start < trim.end { result.append(VideoSpan(start: start, end: trim.end)) }
        return result
    }

    static func sourceTime(_ time: Double, pieces: [VideoSpan]) -> Double {
        var remaining = max(0, time)
        for piece in pieces {
            if remaining < piece.duration { return piece.start + remaining }
            remaining -= piece.duration
        }
        return pieces.last?.end ?? 0
    }

    static func automatic(clicks: [Double], typing: [Double], duration: Double, holdsTyping: Bool) -> [VideoZoom] {
        var spans: [VideoSpan] = []
        for time in clicks.filter({ $0.isFinite && $0 >= 0 && $0 < duration - 1 }).sorted() {
            let next = VideoSpan(start: max(0, time - 0.3), end: min(duration - 0.8, time + 2.5))
            if let last = spans.last, next.start <= last.end + 2.5 {
                spans[spans.count - 1].end = max(last.end, next.end)
            } else { spans.append(next) }
        }
        if holdsTyping {
            for time in typing.filter({ $0.isFinite }).sorted() {
                if let index = spans.lastIndex(where: { time >= $0.start && time <= $0.end + 8 }) {
                    spans[index].end = min(duration - 0.8, max(spans[index].end, time + 1.4))
                }
            }
        }
        return merged(spans, within: VideoSpan(start: 0, end: max(0, duration - 0.8)))
            .filter { $0.duration >= 0.9 }.map { VideoZoom(span: $0) }
    }

    static func snap(_ time: Double, to candidates: [Double], tolerance: Double = 0.08) -> Double {
        guard let nearest = candidates.filter({ $0.isFinite }).min(by: { abs($0 - time) < abs($1 - time) }), abs(nearest - time) <= tolerance else { return time }
        return nearest
    }

    static func moved(_ span: VideoSpan, by delta: Double, bounds: VideoSpan, neighbours: [VideoSpan], anchors: [Double]) -> VideoSpan {
        let lower = max(bounds.start, neighbours.filter { $0.end <= span.start }.map(\.end).max() ?? bounds.start)
        let upper = min(bounds.end, neighbours.filter { $0.start >= span.end }.map(\.start).min() ?? bounds.end)
        let start = min(upper - span.duration, max(lower, snap(span.start + delta, to: anchors + [lower, upper - span.duration])))
        return VideoSpan(start: start, end: start + span.duration)
    }

    static func smootherstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func zoomScale(_ zoom: VideoZoom, at time: Double) -> Double {
        let ramp = min(0.42, zoom.span.duration / 2)
        guard ramp > 0, time >= zoom.span.start, time <= zoom.span.end + 0.65 else { return 1 }
        let weight = time <= zoom.span.end ? smootherstep((time - zoom.span.start) / ramp)
            : 1 - smootherstep((time - zoom.span.end) / 0.65)
        return 1 + (min(3, max(1.2, zoom.strength)) - 1) * weight
    }

    static func gifDelays(frames: Int, fps: Double) -> [Double] {
        guard frames > 0, fps.isFinite, fps >= 1, fps <= 50 else { return [] }
        return (0..<frames).map { index -> Double in
            let next = (Double(index + 1) * 100.0 / fps).rounded()
            let current = (Double(index) * 100.0 / fps).rounded()
            return (next - current) / 100.0
        }
    }
}

enum VideoBackground: String, Codable, CaseIterable { case none, gradient, color, wallpaper, image }

enum VideoLook: String, Codable, CaseIterable { case original, smooth, studio }
enum VideoShape: String, Codable, CaseIterable { case original, wide, square, portrait }
enum VideoFormat: String, Codable, CaseIterable { case mp4, gif }
enum VideoOverlayKind: String, Codable { case text, image, blur }

struct VideoOverlay: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: VideoOverlayKind
    var span: VideoSpan
    var text = "Text"
    var image = ""
    var position = 4
    var size = 0.1
    var opacity = 1.0
    var color = "white"
    var rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25)
    var strength = 1.0
}

struct VideoEditDocument: Codable, Equatable {
    var trim = VideoSpan(start: 0, end: 0)
    var cuts: [VideoSpan] = []
    var zooms: [VideoZoom] = []
    var overlays: [VideoOverlay] = []
    var look = VideoLook.original
    var background = VideoBackground.none
    var backgroundColor = "graphite"
    var backgroundImage = ""
    var margin = 0.0
    var corners = 0.0
    var backgroundBlur = 0.0
    var shape = VideoShape.original
    var format = VideoFormat.mp4
    var speed = 1.0
    var pointer = false
    var clickRings = false
    var smoothing = VideoPointerSmoothing.smooth
    var pointerSize = 1.0
    var typingHold = false
    var volumes: [Float] = []
    var gifScale = 0.75
    var gifFPS = 12.0
    var quality = VideoQuality.balanced

    var pieces: [VideoSpan] { VideoTimeline.kept(trim: trim, cuts: cuts) }
    var duration: Double { pieces.reduce(0) { $0 + $1.duration } }

    mutating func cut(_ span: VideoSpan) -> Bool {
        guard span.duration >= 0.1 else { return false }
        let next = VideoTimeline.merged(cuts + [span], within: trim)
        guard VideoTimeline.kept(trim: trim, cuts: next).reduce(0, { $0 + $1.duration }) >= 0.4 else { return false }
        cuts = next
        return true
    }

    mutating func addZoom(at time: Double) -> Bool {
        let start = max(trim.start, time)
        let end = min(trim.end, start + 2, zooms.filter { $0.span.start > start }.map(\.span.start).min() ?? trim.end)
        guard end - start >= 0.4, !zooms.contains(where: { $0.span.contains(start) }) else { return false }
        zooms.append(VideoZoom(span: VideoSpan(start: start, end: end)))
        zooms.sort { $0.span.start < $1.span.start }
        return true
    }
}

extension VideoEditDocument {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trim = (try? c.decode(VideoSpan.self, forKey: .trim)) ?? VideoSpan(start: 0, end: 0)
        cuts = (try? c.decode([VideoSpan].self, forKey: .cuts)) ?? []
        zooms = (try? c.decode([VideoZoom].self, forKey: .zooms)) ?? []
        overlays = (try? c.decode([VideoOverlay].self, forKey: .overlays)) ?? []
        look = (try? c.decode(VideoLook.self, forKey: .look)) ?? .original
        background = (try? c.decode(VideoBackground.self, forKey: .background)) ?? .none
        backgroundColor = (try? c.decode(String.self, forKey: .backgroundColor)) ?? "graphite"
        backgroundImage = (try? c.decode(String.self, forKey: .backgroundImage)) ?? ""
        margin = min(1, max(0, (try? c.decode(Double.self, forKey: .margin)) ?? 0))
        corners = min(1, max(0, (try? c.decode(Double.self, forKey: .corners)) ?? 0))
        backgroundBlur = min(1, max(0, (try? c.decode(Double.self, forKey: .backgroundBlur)) ?? 0))
        shape = (try? c.decode(VideoShape.self, forKey: .shape)) ?? .original
        format = (try? c.decode(VideoFormat.self, forKey: .format)) ?? .mp4
        speed = min(4, max(0.25, (try? c.decode(Double.self, forKey: .speed)) ?? 1))
        pointer = (try? c.decode(Bool.self, forKey: .pointer)) ?? false
        clickRings = (try? c.decode(Bool.self, forKey: .clickRings)) ?? false
        smoothing = (try? c.decode(VideoPointerSmoothing.self, forKey: .smoothing)) ?? .smooth
        pointerSize = min(2, max(0.5, (try? c.decode(Double.self, forKey: .pointerSize)) ?? 1))
        typingHold = (try? c.decode(Bool.self, forKey: .typingHold)) ?? false
        volumes = (try? c.decode([Float].self, forKey: .volumes))?.map { min(1, max(0, $0)) } ?? []
        gifScale = min(1, max(0.01, (try? c.decode(Double.self, forKey: .gifScale)) ?? 0.75))
        gifFPS = min(50, max(1, (try? c.decode(Double.self, forKey: .gifFPS)) ?? 12))
        quality = (try? c.decode(VideoQuality.self, forKey: .quality)) ?? .balanced
    }
}

struct VideoEditHistory {
    private(set) var undo: [VideoEditDocument] = []
    private(set) var redo: [VideoEditDocument] = []
    mutating func record(_ document: VideoEditDocument) { undo.append(document); redo.removeAll() }
    mutating func undo(_ current: VideoEditDocument) -> VideoEditDocument? {
        guard let next = undo.popLast() else { return nil }
        redo.append(current)
        return next
    }
    mutating func redo(_ current: VideoEditDocument) -> VideoEditDocument? {
        guard let next = redo.popLast() else { return nil }
        undo.append(current)
        return next
    }
}

enum VideoTakeFiles {
    static func create(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
    static func unique(_ destination: URL) -> URL {
        var candidate = destination
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = destination.deletingLastPathComponent().appendingPathComponent("\(destination.deletingPathExtension().lastPathComponent) \(number).\(destination.pathExtension)")
            number += 1
        }
        return candidate
    }
    static func expired(modified: Date, hasMaster: Bool, now: Date) -> Bool {
        now.timeIntervalSince(modified) >= (hasMaster ? 86400 : 3600)
    }
    static func purgeCopies(_ root: URL, now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
        for file in files where UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) >= 86400 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func sweep(_ root: URL, now: Date, protecting: Set<URL> = []) {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        let protectedPaths = Set(protecting.map { $0.standardizedFileURL.path })
        for folder in entries where UUID(uuidString: folder.lastPathComponent) != nil && !protectedPaths.contains(folder.standardizedFileURL.path) {
            guard let values = try? folder.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]), values.isDirectory == true else { continue }
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let master = files.first { $0.deletingPathExtension().lastPathComponent == "master" }
            let modified = master.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } ?? values.contentModificationDate ?? now
            if expired(modified: modified, hasMaster: master != nil, now: now) { try? manager.removeItem(at: folder) }
        }
    }

    static func install(_ staged: URL, at destination: URL) throws {
        guard rename(staged.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct VideoPreset: Codable, Equatable, Identifiable {
    var name: String
    var document: VideoEditDocument
    var pictures: [String: Data]
    var id: String { name }

    static func saving(_ preset: VideoPreset, into existing: [VideoPreset]) -> [VideoPreset] {
        var list = existing.filter { $0.name != preset.name }
        list.append(preset)
        return Array(list.suffix(12))
    }

    func applying(to current: VideoEditDocument) -> VideoEditDocument {
        var next = current
        next.look = document.look
        next.background = document.background
        next.backgroundImage = document.backgroundImage
        next.backgroundColor = document.backgroundColor
        next.backgroundBlur = document.backgroundBlur
        next.margin = document.margin
        next.corners = document.corners
        next.shape = document.shape
        next.pointer = document.pointer
        next.pointerSize = document.pointerSize
        next.clickRings = document.clickRings
        next.smoothing = document.smoothing
        next.typingHold = document.typingHold
        next.zooms = document.zooms.compactMap { zoom in
            var copy = zoom
            copy.id = UUID()
            copy.span.start = max(current.trim.start, zoom.span.start)
            copy.span.end = min(current.trim.end, zoom.span.end)
            return copy.span.duration >= 0.4 ? copy : nil
        }
        next.overlays.removeAll { $0.kind == .image }
        next.overlays += document.overlays.filter { $0.kind == .image }.compactMap { overlay in
            var copy = overlay
            copy.id = UUID()
            copy.span.start = max(current.trim.start, overlay.span.start)
            copy.span.end = min(current.trim.end, overlay.span.end)
            return copy.span.duration >= 0.4 ? copy : nil
        }
        return next
    }
}

extension VideoSpan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = max(0, (try? c.decode(Double.self, forKey: .start)) ?? 0)
        end = max(start, (try? c.decode(Double.self, forKey: .end)) ?? start)
    }
}

extension VideoZoom {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        span = (try? c.decode(VideoSpan.self, forKey: .span)) ?? VideoSpan(start: 0, end: 2)
        strength = min(3, max(1.2, (try? c.decode(Double.self, forKey: .strength)) ?? 1.8))
        focus = try? c.decode(CGPoint.self, forKey: .focus)
        if let point = focus { focus = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y))) }
    }
}

extension VideoOverlay {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decode(VideoOverlayKind.self, forKey: .kind)) ?? .text
        span = (try? c.decode(VideoSpan.self, forKey: .span)) ?? VideoSpan(start: 0, end: 2)
        text = String(((try? c.decode(String.self, forKey: .text)) ?? "Text").prefix(200)).components(separatedBy: "\n").prefix(3).joined(separator: "\n")
        image = (try? c.decode(String.self, forKey: .image)) ?? ""
        if image.contains("/") || image == "." || image == ".." { image = "" }
        position = min(8, max(0, (try? c.decode(Int.self, forKey: .position)) ?? 4))
        size = min(kind == .text ? 0.16 : 0.6, max(kind == .text ? 0.03 : 0.04, (try? c.decode(Double.self, forKey: .size)) ?? 0.1))
        opacity = min(1, max(0.05, (try? c.decode(Double.self, forKey: .opacity)) ?? 1))
        color = (try? c.decode(String.self, forKey: .color)) ?? "white"
        rect = (try? c.decode(CGRect.self, forKey: .rect)) ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25)
        rect = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if rect.isNull || rect.isEmpty { rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25) }
        strength = min(5, max(1, (try? c.decode(Double.self, forKey: .strength)) ?? 1))
    }
}

extension VideoPointerSample {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = (try? c.decode(Double.self, forKey: .time)) ?? 0
        point = (try? c.decode(CGPoint.self, forKey: .point)) ?? .zero
        visible = (try? c.decode(Bool.self, forKey: .visible)) ?? true
        pressed = (try? c.decode(Bool.self, forKey: .pressed)) ?? false
        shape = try? c.decode(String.self, forKey: .shape)
        scale = min(10, max(0.1, (try? c.decode(Double.self, forKey: .scale)) ?? 1))
    }
}

extension VideoTracks {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursors = (try? c.decode([String: VideoCursorShape].self, forKey: .cursors)) ?? [:]
        displayScale = (try? c.decode(Double.self, forKey: .displayScale)) ?? 1
        pointer = ((try? c.decode([VideoPointerSample].self, forKey: .pointer)) ?? []).sorted { $0.time < $1.time }
        clicks = ((try? c.decode([Double].self, forKey: .clicks)) ?? []).sorted()
        typing = ((try? c.decode([Double].self, forKey: .typing)) ?? []).sorted()
    }
}
