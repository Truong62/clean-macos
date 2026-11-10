import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum MediaToolError: LocalizedError, Equatable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

enum MediaTab: String, CaseIterable, Identifiable {
    case video, gif, images, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Compress Video"
        case .gif: "Make GIF"
        case .images: "Images"
        case .text: "Extract Text"
        }
    }

    var takesVideo: Bool { self == .video || self == .gif }
    var allowsMany: Bool { self == .images }
    var acceptedTypes: [UTType] { takesVideo ? [.movie] : [.image] }

    func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return acceptedTypes.contains { type.conforms(to: $0) }
    }
}

struct MediaResult: Equatable {
    var outputs: [URL] = []
    var bytesBefore: Int64 = 0
    var bytesAfter: Int64 = 0
    var notes: [String] = []
    var failures: [String] = []
    var text: String?

    var isLarger: Bool { bytesAfter > bytesBefore }
}

enum OutputNaming {
    static func sibling(of source: URL, suffix: String, ext: String) -> URL {
        source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + suffix).appendingPathExtension(ext)
    }

    static func available(_ url: URL, exists: (URL) -> Bool) -> URL {
        guard exists(url) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    static func cleaned(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "." }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%g MB", Double(bytes) / TargetSizePlanner.bytesPerMB)
    }
}

enum ClipTime {
    static func parse(_ text: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard parts.count <= 3, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else {
            throw MediaToolError.message("Use times like 1:05 or 65.5 to trim.")
        }
        return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
    }
}

struct ClipRange: Equatable {
    let start: Double
    let end: Double

    var length: Double { end - start }

    func isWhole(of duration: Double) -> Bool {
        start <= 0 && end >= duration
    }
}

struct ClipTrim: Equatable {
    static let minimumLength = 0.1

    var isOn = false
    var start = ""
    var end = ""

    func range(duration: Double) throws -> ClipRange {
        guard isOn else { return ClipRange(start: 0, end: duration) }
        let from = max(0, try ClipTime.parse(start) ?? 0)
        let to = min(duration, try ClipTime.parse(end) ?? duration)
        guard from < duration else { throw MediaToolError.message("The trim starts after the video ends.") }
        guard to - from >= Self.minimumLength else { throw MediaToolError.message("The trim end has to come after its start.") }
        return ClipRange(start: from, end: to)
    }
}

enum CompressionLevel: String, Codable, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var quality: Double {
        switch self {
        case .low: 0.88
        case .medium: 0.68
        case .high: 0.28
        }
    }
}

enum VideoCompressMode: String, Codable, CaseIterable, Identifiable {
    case resolution, targetSize

    var id: String { rawValue }
    var title: String { self == .resolution ? "Resolution" : "Target Size" }
}

struct VideoCompressSettings: Codable, Equatable {
    var mode = VideoCompressMode.resolution
    var level = CompressionLevel.medium
    var maxSize = 1280
    var targetMB = 20.0
}

struct ConvertPreset: Equatable {
    let name: String
    let isMultiPass: Bool
}

enum VideoPresets {
    static let tool = "/usr/bin/avconvert"
    static let sizeRange = 640...3840
    static let lowQualityBelow = 0.4
    static let highestQualityFrom = 0.82
    static let mediumQualityBelow = 0.58
    static let resolutions = [(edge: 640, name: "Preset640x480"), (edge: 960, name: "Preset960x540"), (edge: 1280, name: "Preset1280x720"),
                              (edge: 1920, name: "Preset1920x1080"), (edge: 3840, name: "Preset3840x2160")]

    static func preset(quality: Double, maxSize: Int) -> ConvertPreset {
        if quality < lowQualityBelow { return ConvertPreset(name: "PresetLowQuality", isMultiPass: false) }
        if quality >= highestQualityFrom { return ConvertPreset(name: "PresetHighestQuality", isMultiPass: true) }
        if quality < mediumQualityBelow { return ConvertPreset(name: "PresetMediumQuality", isMultiPass: false) }
        return ConvertPreset(name: (resolutions.last { $0.edge <= maxSize } ?? resolutions[0]).name, isMultiPass: false)
    }

    static func arguments(source: URL, output: URL, preset: ConvertPreset, range: ClipRange?) -> [String] {
        var arguments = ["--source", source.path, "--preset", preset.name, "--output", output.path, "--progress"]
        if preset.isMultiPass { arguments.append("--multiPass") }
        if let range {
            arguments += ["--start", String(format: "%.3f", range.start), "--duration", String(format: "%.3f", range.length)]
        }
        return arguments
    }
}

enum AVConvertOutput {
    static func progress(in chunk: String) -> Double? {
        let values = chunk.components(separatedBy: "progress:").dropFirst().compactMap { part in
            Double(part.drop { $0 == " " }.prefix { $0.isNumber || $0 == "." })
        }
        return values.last.map { min(max($0 / 100, 0), 1) }
    }

    static func failure(_ output: String, status: Int32) -> String {
        if let marker = output.range(of: "failed with error:") {
            let message = output[marker.upperBound...].prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
            if !message.isEmpty { return message }
        }
        return "avconvert stopped with code \(status)."
    }
}

struct TargetSizePlan: Equatable {
    let videoBitRate: Int
    let audioBitRate: Int
    let size: CGSize
}

enum TargetSizePlanner {
    static let sizeRange = 1.0...512.0
    static let bytesPerMB = 1_000_000.0
    static let videoShare = 0.94
    static let minVideoBitRate = 240_000
    static let lowAudioBitRate = 64_000
    static let highAudioBitRate = 128_000
    static let highAudioFrom = 1_000_000.0
    static let minLongEdge: CGFloat = 480
    static let maxAttempts = 3
    static let retryMargin = 0.95
    static let retryStep = 0.9
    static let ladder: [(bitRate: Int, edge: CGFloat)] = [(10_000_000, 3840), (5_000_000, 2560), (2_500_000, 1920), (1_200_000, 1280), (700_000, 960),
                                                         (400_000, 720)]

    static func bytes(megabytes: Double) -> Int64 {
        Int64(megabytes * bytesPerMB)
    }

    static func plan(targetBytes: Int64, seconds: Double, hasAudio: Bool, source: CGSize, sourceBitRate: Double) throws -> TargetSizePlan {
        guard seconds > 0 else { throw MediaToolError.message("This video has no length.") }
        let total = Double(targetBytes) * 8 / seconds
        let audio = hasAudio ? (total >= highAudioFrom ? highAudioBitRate : lowAudioBitRate) : 0
        let video = Int(total * videoShare - Double(audio))
        guard video >= minVideoBitRate else { throw tooSmall(targetBytes: targetBytes, seconds: seconds, hasAudio: hasAudio) }
        let capped = sourceBitRate > 0 ? min(video, max(Int(sourceBitRate), minVideoBitRate)) : video
        return plan(videoBitRate: capped, audioBitRate: audio, source: source)
    }

    static func plan(videoBitRate: Int, audioBitRate: Int, source: CGSize) -> TargetSizePlan {
        let edge = ladder.first { videoBitRate >= $0.bitRate }?.edge ?? minLongEdge
        return TargetSizePlan(videoBitRate: videoBitRate, audioBitRate: audioBitRate, size: evenSize(source, longEdge: edge))
    }

    static func retry(_ plan: TargetSizePlan, actualBytes: Int64, targetBytes: Int64, source: CGSize) throws -> TargetSizePlan {
        let factor = min(retryStep, Double(targetBytes) / Double(max(actualBytes, 1)) * retryMargin)
        let video = Int(Double(plan.videoBitRate) * factor)
        guard video >= minVideoBitRate else {
            throw MediaToolError.message("This video doesn't fit in \(OutputNaming.megabytes(targetBytes)) without dropping under 240 kbps. Use a bigger size, or trim it.")
        }
        return self.plan(videoBitRate: video, audioBitRate: plan.audioBitRate, source: source)
    }

    static func evenSize(_ source: CGSize, longEdge: CGFloat) -> CGSize {
        let long = max(source.width, source.height, 1)
        let target = min(long, longEdge)
        let side = { (value: CGFloat) in max(2, (value * target / long / 2).rounded(.down) * 2) }
        return CGSize(width: side(source.width), height: side(source.height))
    }

    private static func tooSmall(targetBytes: Int64, seconds: Double, hasAudio: Bool) -> MediaToolError {
        let bitRate = Double(minVideoBitRate + (hasAudio ? lowAudioBitRate : 0)) / videoShare
        let minimum = Int((bitRate * seconds / 8 / bytesPerMB).rounded(.up))
        return .message("\(OutputNaming.megabytes(targetBytes)) is too small for \(ScreenRecording.elapsed(seconds)) of video. Use at least \(minimum) MB, or trim it.")
    }
}

struct GIFSettings: Codable, Equatable {
    var fps = 12
    var width = 720
    var limitsSize = false
    var targetMB = 10.0
}

struct GIFAttempt: Equatable {
    var fps: Int
    var width: Int
}

enum GIFPlanner {
    static let fpsRange = 1...30
    static let widthRange = 160...1600
    static let maxFrames = 300
    static let maxAttempts = 4
    static let lowestFPS = 8
    static let shrinkMargin = 0.9

    static func frameTimes(length: Double, fps: Int) throws -> [Double] {
        let count = max(1, Int((length * Double(fps) - 1e-6).rounded(.up)))
        guard count <= maxFrames else {
            throw MediaToolError.message("A GIF can have up to \(maxFrames) frames, so at \(fps) fps it can be at most \(maxSeconds(fps: fps)) seconds long. Trim the clip or lower the frame rate.")
        }
        return (0..<count).map { Double($0) / Double(fps) }
    }

    static func maxSeconds(fps: Int) -> String {
        String(format: "%g", (Double(maxFrames) / Double(max(fps, 1)) * 10).rounded(.down) / 10)
    }

    static func size(width: Int, source: CGSize) -> CGSize {
        let target = min(CGFloat(width), source.width)
        return CGSize(width: target.rounded(), height: max(1, (source.height * target / max(source.width, 1)).rounded()))
    }

    static func next(after attempt: GIFAttempt, bytes: Int64, target: Int64) -> GIFAttempt? {
        guard bytes > target else { return nil }
        let ratio = Double(target) / Double(bytes) * shrinkMargin
        let fps = max(min(attempt.fps, lowestFPS), Int(Double(attempt.fps) * ratio))
        if fps < attempt.fps { return GIFAttempt(fps: fps, width: attempt.width) }
        let width = max(widthRange.lowerBound, Int(Double(attempt.width) * ratio.squareRoot()))
        return width < attempt.width ? GIFAttempt(fps: attempt.fps, width: width) : nil
    }
}

enum ImageFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg, png, heic, pdf

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var hasAlpha: Bool { self == .png || self == .heic }
    var usesQuality: Bool { self != .png }

    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .pdf: .pdf
        }
    }
}

enum ResizeMode: String, Codable, CaseIterable, Identifiable {
    case original, longestSide, width, height, exact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original Size"
        case .longestSide: "Longest Side"
        case .width: "Width"
        case .height: "Height"
        case .exact: "Exact Size"
        }
    }
}

enum ExactFit: String, Codable, CaseIterable, Identifiable {
    case stretch, fit, fill

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ImageConvertSettings: Codable, Equatable {
    var format = ImageFormat.jpeg
    var quality = 0.72
    var resize = ResizeMode.original
    var length = 1600
    var exactWidth = 1080
    var exactHeight = 1080
    var fit = ExactFit.fit
    var stripsMetadata = true
    var background = "#FFFFFF"
    var addsWatermark = false
    var watermark = ""
    var nameTemplate = NameTemplate.standard
    var keepsModificationDate = false
    var usesSubfolder = false
}

enum ImagePreset: String, CaseIterable, Identifiable {
    case web, social, docs

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var summary: String {
        switch self {
        case .web: "JPEG, longest side 1600 px"
        case .social: "JPEG, longest side 2048 px"
        case .docs: "PDF, longest side 2480 px"
        }
    }

    func applied(to settings: ImageConvertSettings) -> ImageConvertSettings {
        var result = settings
        result.resize = .longestSide
        result.quality = 0.72
        result.stripsMetadata = true
        switch self {
        case .web:
            result.format = .jpeg
            result.length = 1600
        case .social:
            result.format = .jpeg
            result.length = 2048
        case .docs:
            result.format = .pdf
            result.length = 2480
        }
        return result
    }
}

struct ImageLayout: Equatable {
    let canvas: CGSize
    let drawRect: CGRect
}

enum ImageGeometry {
    static func layout(source: CGSize, settings: ImageConvertSettings) -> ImageLayout {
        let length = CGFloat(max(settings.length, 1))
        switch settings.resize {
        case .original: return scaled(source, by: 1)
        case .longestSide: return scaled(source, by: min(1, length / max(source.width, source.height)))
        case .width: return scaled(source, by: min(1, length / source.width))
        case .height: return scaled(source, by: min(1, length / source.height))
        case .exact: return exact(source, canvas: CGSize(width: max(settings.exactWidth, 1), height: max(settings.exactHeight, 1)), fit: settings.fit)
        }
    }

    static func decodeLongSide(source: CGSize, layout: ImageLayout) -> Int {
        let scale = max(layout.drawRect.width / source.width, layout.drawRect.height / source.height)
        return Int((max(source.width, source.height) * min(scale, 1)).rounded(.up))
    }

    private static func scaled(_ source: CGSize, by scale: CGFloat) -> ImageLayout {
        let canvas = CGSize(width: max(1, (source.width * scale).rounded()), height: max(1, (source.height * scale).rounded()))
        return ImageLayout(canvas: canvas, drawRect: CGRect(origin: .zero, size: canvas))
    }

    private static func exact(_ source: CGSize, canvas: CGSize, fit: ExactFit) -> ImageLayout {
        guard fit != .stretch else { return ImageLayout(canvas: canvas, drawRect: CGRect(origin: .zero, size: canvas)) }
        let ratios = (canvas.width / source.width, canvas.height / source.height)
        let scale = fit == .fit ? min(ratios.0, ratios.1) : max(ratios.0, ratios.1)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return ImageLayout(canvas: canvas, drawRect: CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                                                            width: size.width, height: size.height))
    }
}

enum ImageLimits {
    static let maxSide = 20_000
    static let maxPixels = 64_000_000

    static func check(_ size: CGSize) throws {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width <= maxSide, height <= maxSide, width * height <= maxPixels else {
            throw MediaToolError.message("\(width) × \(height) px is too big. The limit is 20,000 px per side and 64 megapixels.")
        }
    }
}

enum NameTemplate {
    static let standard = "{name}"
    static let tokens = ["{name}", "{date}", "{time}", "{width}", "{height}", "{ext}", "{index}"]

    static func render(_ template: String, name: String, ext: String, size: CGSize, index: Int, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"
        let values = ["{name}": name, "{date}": day, "{time}": formatter.string(from: date), "{width}": "\(Int(size.width))",
                      "{height}": "\(Int(size.height))", "{ext}": ext, "{index}": "\(index)"]
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            if let close = rest[open...].firstIndex(of: "}"), let value = values[String(rest[open...close])] {
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                result += "{"
                rest = rest[rest.index(after: open)...]
            }
        }
        let cleaned = OutputNaming.cleaned(result + rest)
        return cleaned.isEmpty ? name : cleaned
    }
}

enum Watermark {
    static let opacity = 0.45
    static let margin: CGFloat = 32
    static let sizeShare: CGFloat = 0.04
    static let minFontSize: CGFloat = 12

    static func fontSize(canvas: CGSize) -> CGFloat {
        max(minFontSize, (min(canvas.width, canvas.height) * sizeShare).rounded())
    }

    static func fittedFontSize(_ size: CGFloat, textWidth: CGFloat, canvasWidth: CGFloat) -> CGFloat {
        let room = canvasWidth - 2 * margin
        return textWidth > room && room > 0 ? max(1, size * room / textWidth) : size
    }

    static func origin(textWidth: CGFloat, canvas: CGSize) -> CGPoint {
        CGPoint(x: canvas.width - margin - textWidth, y: margin)
    }
}

struct MediaToolSettings: Codable, Equatable {
    var video = VideoCompressSettings()
    var gif = GIFSettings()
    var images = ImageConvertSettings()
}

final class MediaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    func start<T>(_ operation: () throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return nil }
        return try operation()
    }
}

enum MediaDuration {
    static func finite(_ seconds: Double?) -> Double? {
        seconds.flatMap { $0.isFinite ? $0 : nil }
    }

    static func video(asset: Double, trackEnd: Double) throws -> Double {
        guard asset.isFinite, trackEnd.isFinite, asset > 0, trackEnd > 0 else {
            throw MediaToolError.message("This video has no usable duration.")
        }
        return min(asset, trackEnd)
    }
}

final class MediaProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent: Int?
    private var lastStatus: String?

    func accepts(_ progress: Double?, status: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let percent = MediaDuration.finite(progress).map { Int((min(max($0, 0), 1) * 100).rounded()) }
        guard percent != lastPercent || (percent == nil && status != lastStatus) else { return false }
        lastPercent = percent
        lastStatus = status
        return true
    }
}

enum MediaEncodingCompletion {
    case writerFailed, readerFailed, cancelled, finish

    static func resolve(writerFailed: Bool, readerFailed: Bool, cancelled: Bool) -> Self {
        if writerFailed { return .writerFailed }
        if cancelled { return .cancelled }
        if readerFailed { return .readerFailed }
        return .finish
    }
}
