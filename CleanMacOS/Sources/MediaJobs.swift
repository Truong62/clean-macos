import AVFoundation
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaFiles {
    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func scratchFile(near folder: URL, ext: String) throws -> URL {
        let manager = FileManager.default
        let directory = (try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true))
            ?? manager.temporaryDirectory.appendingPathComponent("MacKit-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("output").appendingPathExtension(ext)
    }

    static func discard(_ scratch: URL) {
        try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent())
    }

    static func place(_ scratch: URL, at desired: URL) throws -> URL {
        defer { discard(scratch) }
        try FileManager.default.createDirectory(at: desired.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = OutputNaming.available(desired) { FileManager.default.fileExists(atPath: $0.path) }
        try FileManager.default.moveItem(at: scratch, to: destination)
        return destination
    }
}

final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false
    private let forceAfter: Double?

    init(forceAfter: Double? = nil) { self.forceAfter = forceAfter }

    func launch(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        try process.run()
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if let process, process.isRunning {
            process.terminate()
            if let forceAfter {
                DispatchQueue.global().asyncAfter(deadline: .now() + forceAfter) { [self] in
                    lock.lock()
                    defer { lock.unlock() }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}

extension CommandRunner {
    static func readOutput(_ handle: FileHandle, onOutput: (String) -> Void) -> Data {
        var output = Data()
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return output }
            output.append(chunk)
            onOutput(String(decoding: chunk, as: UTF8.self))
        }
    }

    static func stream(_ tool: String, _ args: [String], terminationGrace: Double? = nil, onOutput: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        let cancellation = ProcessCancellation(forceAfter: terminationGrace)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    let pipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: tool)
                    process.arguments = args
                    process.standardOutput = pipe
                    process.standardError = pipe
                    do {
                        guard try cancellation.launch(process) else { return continuation.resume(throwing: CancellationError()) }
                    } catch {
                        return continuation.resume(throwing: error)
                    }
                    let output = Self.readOutput(pipe.fileHandleForReading, onOutput: onOutput)
                    process.waitUntilExit()
                    continuation.resume(returning: CommandResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), error: ""))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}

struct VideoSource {
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: [AVAssetTrack]
    let duration: Double
    let naturalSize: CGSize
    let transform: CGAffineTransform
    let frameRate: Float
    let bitRate: Float

    var displaySize: CGSize {
        let box = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(box.width), height: abs(box.height))
    }

    static func load(_ url: URL) async throws -> VideoSource {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw MediaToolError.message("This file has no video in it.") }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let assetDuration = try await asset.load(.duration).seconds
        let videoEnd = try await video.load(.timeRange).end.seconds
        let duration = try MediaDuration.video(asset: assetDuration, trackEnd: videoEnd)
        let (size, transform, frameRate, bitRate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
        guard duration > 0, size.width > 0, size.height > 0 else { throw MediaToolError.message("This video is empty.") }
        return VideoSource(asset: asset, video: video, audio: audio, duration: duration, naturalSize: size, transform: transform,
                           frameRate: frameRate, bitRate: bitRate)
    }
}

final class VideoReencoder: @unchecked Sendable {
    static let colorProperties = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]
    static let keyFrameInterval = 2.0
    static let fallbackFrameRate: Float = 30
    static let sampleRate = 48_000
    static let channels = 2

    private let cancellation = MediaCancellation()

    static func encode(_ source: VideoSource, plan: TargetSizePlan, range: ClipRange, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let encoder = VideoReencoder()
        try await withTaskCancellationHandler {
            try await encoder.run(source, plan: plan, range: range, to: url, progress: progress)
        } onCancel: {
            encoder.cancel()
        }
    }

    static func decodeSettings(_ size: CGSize) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            AVVideoColorPropertiesKey: colorProperties,
        ]
    }

    static func encodeSettings(_ plan: TargetSizePlan, frameRate: Float) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(plan.size.width), AVVideoHeightKey: Int(plan.size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: keyFrameInterval,
                AVVideoExpectedSourceFrameRateKey: frameRate > 0 ? frameRate : fallbackFrameRate,
            ],
            AVVideoColorPropertiesKey: colorProperties,
        ]
    }

    static func audioSettings(bitRate: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: bitRate]
    }

    private func cancel() {
        cancellation.cancel()
    }

    private func run(_ source: VideoSource, plan: TargetSizePlan, range: ClipRange, to url: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600), end: CMTime(seconds: range.end, preferredTimescale: 600))
        let reader = try AVAssetReader(asset: source.asset)
        reader.timeRange = timeRange
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoOutput = AVAssetReaderTrackOutput(track: source.video, outputSettings: Self.decodeSettings(plan.size))
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.encodeSettings(plan, frameRate: source.frameRate))
        videoInput.transform = source.transform
        let videoPump = SamplePump(output: videoOutput, input: videoInput)
        videoPump.onAppend = { time in progress(min(max((time - timeRange.start).seconds / range.length, 0), 1)) }
        var pumps = [videoPump]
        if plan.audioBitRate > 0, !source.audio.isEmpty {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: source.audio, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: Self.channels,
            ])
            pumps.append(SamplePump(output: audioOutput, input: AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(bitRate: plan.audioBitRate))))
        }
        for pump in pumps {
            reader.add(pump.output)
            writer.add(pump.input)
        }
        guard let started = cancellation.start({ reader.startReading() }) else { throw CancellationError() }
        guard started else { throw reader.error ?? MediaToolError.message("The video could not be read.") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? MediaToolError.message("The compressed video could not be written.")
        }
        writer.startSession(atSourceTime: timeRange.start)
        await withTaskGroup(of: Void.self) { group in
            for pump in pumps {
                group.addTask {
                    await pump.run { self.cancellation.isCancelled || writer.status == .failed || reader.status == .failed }
                }
            }
        }
        switch MediaEncodingCompletion.resolve(writerFailed: writer.status == .failed,
                                               readerFailed: reader.status == .failed, cancelled: cancellation.isCancelled) {
        case .writerFailed:
            reader.cancelReading()
            throw writer.error ?? MediaToolError.message("The compressed video could not be written.")
        case .cancelled:
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        case .readerFailed:
            reader.cancelReading()
            writer.cancelWriting()
            throw reader.error ?? MediaToolError.message("The video could not be read.")
        case .finish:
            break
        }
        writer.endSession(atSourceTime: timeRange.end)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaToolError.message("The compressed video could not be written.") }
    }
}

enum GIFMaker {
    static let timescale: CMTimeScale = 600

    static func write(_ source: VideoSource, times: [Double], size: CGSize, fps: Int, to url: URL, progress: (Double) -> Void) async throws {
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        let tolerance = CMTime(seconds: 0.5 / Double(fps), preferredTimescale: timescale)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw MediaToolError.message("The GIF could not be created.")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: false],
        ] as CFDictionary)
        let delay = 1 / Double(fps)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for (index, time) in times.enumerated() {
            try Task.checkCancellation()
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: timescale)).image
            CGImageDestinationAddImage(destination, image, frame)
            progress(Double(index + 1) / Double(times.count))
        }
        guard CGImageDestinationFinalize(destination) else { throw MediaToolError.message("The GIF could not be saved.") }
    }
}

struct SourceImage {
    let source: CGImageSource
    let size: CGSize
    let metadata: [CFString: Any]

    init(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw MediaToolError.message("This isn't an image MacKit can read.") }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        size = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        try ImageLimits.check(size)
        self.source = source
        metadata = properties.filter { ImageConverter.metadataKeys.contains($0.key) }
    }

    func upright(maxPixelSize: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, Int(max(size.width, size.height)))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MediaToolError.message("This image could not be decoded.")
        }
        return image
    }
}

enum ImageConverter {
    static let metadataKeys = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                               kCGImagePropertyTIFFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight]
    static let subfolder = "Converted"
    static let shadowColor = CGColor(gray: 0, alpha: 0.6)

    static func convert(_ url: URL, settings: ImageConvertSettings, index: Int, date: Date) throws -> URL {
        let picture = try SourceImage(url)
        let layout = ImageGeometry.layout(source: picture.size, settings: settings)
        try ImageLimits.check(layout.canvas)
        let image = try picture.upright(maxPixelSize: ImageGeometry.decodeLongSide(source: picture.size, layout: layout))
        let rendered = try render(image, layout: layout, settings: settings)
        let scratch = try MediaFiles.scratchFile(near: url.deletingLastPathComponent(), ext: settings.format.fileExtension)
        defer { MediaFiles.discard(scratch) }
        try write(rendered, to: scratch, settings: settings, metadata: settings.stripsMetadata ? [:] : picture.metadata)
        let folder = settings.usesSubfolder ? url.deletingLastPathComponent().appendingPathComponent(subfolder, isDirectory: true) : url.deletingLastPathComponent()
        let name = NameTemplate.render(settings.nameTemplate, name: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension,
                                       size: layout.canvas, index: index, date: date)
        let output = try MediaFiles.place(scratch, at: folder.appendingPathComponent(name).appendingPathExtension(settings.format.fileExtension))
        if settings.keepsModificationDate, let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: output.path)
        }
        return output
    }

    static func render(_ image: CGImage, layout: ImageLayout, settings: ImageConvertSettings) throws -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha = settings.format.hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: Int(layout.canvas.width), height: Int(layout.canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: alpha.rawValue) else { throw MediaToolError.message("Not enough memory for this image.") }
        let canvas = CGRect(origin: .zero, size: layout.canvas)
        if settings.format.hasAlpha {
            context.clear(canvas)
        } else {
            let color = ColorText.parse(settings.background)
            context.setFillColor(CGColor(srgbRed: color?.red ?? 1, green: color?.green ?? 1, blue: color?.blue ?? 1, alpha: 1))
            context.fill(canvas)
        }
        context.interpolationQuality = .high
        context.draw(image, in: layout.drawRect)
        let mark = settings.watermark.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.addsWatermark && !mark.isEmpty { drawWatermark(mark, in: context, canvas: layout.canvas) }
        guard let rendered = context.makeImage() else { throw MediaToolError.message("Not enough memory for this image.") }
        return rendered
    }

    private static func drawWatermark(_ text: String, in context: CGContext, canvas: CGSize) {
        let base = Watermark.fontSize(canvas: canvas)
        let size = Watermark.fittedFontSize(base, textWidth: CGFloat(CTLineGetTypographicBounds(line(text, size: base), nil, nil, nil)), canvasWidth: canvas.width)
        let fitted = line(text, size: size)
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(fitted, nil, &descent, nil))
        let origin = Watermark.origin(textWidth: width, canvas: canvas)
        context.saveGState()
        context.setAlpha(Watermark.opacity)
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: max(1, size / 10), color: shadowColor)
        context.textPosition = CGPoint(x: origin.x, y: origin.y + descent)
        CTLineDraw(fitted, context)
        context.restoreGState()
    }

    private static func line(_ text: String, size: CGFloat) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]))
    }

    private static func write(_ image: CGImage, to url: URL, settings: ImageConvertSettings, metadata: [CFString: Any]) throws {
        if settings.format == .pdf { return try writePDF(image, to: url, quality: settings.quality) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, settings.format.type.identifier as CFString, 1, nil) else {
            throw MediaToolError.message("This Mac can't save \(settings.format.title) images.")
        }
        var properties = metadata
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality] = settings.quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaToolError.message("The image could not be saved.") }
    }

    private static func writePDF(_ image: CGImage, to url: URL, quality: Double) throws {
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw MediaToolError.message("The PDF could not be created.") }
        context.beginPDFPage(nil)
        context.draw(jpegCopy(image, quality: quality) ?? image, in: box)
        context.endPDFPage()
        context.closePDF()
    }

    private static func jpegCopy(_ image: CGImage, quality: Double) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum MediaJobs {
    typealias Report = @Sendable (Double?, String) -> Void

    static func run(_ tab: MediaTab, files: [URL], settings: MediaToolSettings, trim: ClipTrim, report: @escaping Report) async throws -> MediaResult {
        switch tab {
        case .video: try await compressVideo(files[0], settings: settings.video, trim: trim, report: report)
        case .gif: try await makeGIF(files[0], settings: settings.gif, trim: trim, report: report)
        case .images: try await convertImages(files, settings: settings.images, date: Date(), report: report)
        case .text: try await extractText(files[0], report: report)
        }
    }

    static func compressVideo(_ url: URL, settings: VideoCompressSettings, trim: ClipTrim, report: @escaping Report) async throws -> MediaResult {
        report(nil, "Reading the video…")
        let source = try await VideoSource.load(url)
        let range = try trim.range(duration: source.duration)
        let scratch = try MediaFiles.scratchFile(near: url.deletingLastPathComponent(), ext: "mp4")
        defer { MediaFiles.discard(scratch) }
        var notes: [String] = []
        switch settings.mode {
        case .resolution:
            let preset = VideoPresets.preset(quality: settings.level.quality, maxSize: settings.maxSize)
            report(nil, "Compressing…")
            let arguments = VideoPresets.arguments(source: url, output: scratch, preset: preset, range: range.isWhole(of: source.duration) ? nil : range)
            let result = try await CommandRunner.stream(VideoPresets.tool, arguments) { chunk in
                if let value = AVConvertOutput.progress(in: chunk) { report(value, "Compressing…") }
            }
            guard result.status == 0 else { throw MediaToolError.message(AVConvertOutput.failure(result.output, status: result.status)) }
        case .targetSize:
            notes = try await encodeToTarget(source, megabytes: settings.targetMB, range: range, to: scratch, report: report)
        }
        let output = try MediaFiles.place(scratch, at: OutputNaming.sibling(of: url, suffix: "-compressed", ext: "mp4"))
        return MediaResult(outputs: [output], bytesBefore: MediaFiles.size(url), bytesAfter: MediaFiles.size(output), notes: notes)
    }

    private static func encodeToTarget(_ source: VideoSource, megabytes: Double, range: ClipRange, to scratch: URL, report: @escaping Report) async throws -> [String] {
        let target = TargetSizePlanner.bytes(megabytes: megabytes)
        var plan = try TargetSizePlanner.plan(targetBytes: target, seconds: range.length, hasAudio: !source.audio.isEmpty, source: source.naturalSize,
                                              sourceBitRate: Double(source.bitRate))
        for attempt in 1...TargetSizePlanner.maxAttempts {
            try? FileManager.default.removeItem(at: scratch)
            let status = attempt == 1 ? "Encoding…" : "Still too big, encoding again (try \(attempt) of \(TargetSizePlanner.maxAttempts))…"
            try await VideoReencoder.encode(source, plan: plan, range: range, to: scratch) { report($0, status) }
            let bytes = MediaFiles.size(scratch)
            guard bytes > target else { return [] }
            guard attempt < TargetSizePlanner.maxAttempts else { break }
            plan = try TargetSizePlanner.retry(plan, actualBytes: bytes, targetBytes: target, source: source.naturalSize)
        }
        return ["Still above \(OutputNaming.megabytes(target)) after \(TargetSizePlanner.maxAttempts) tries."]
    }

    static func makeGIF(_ url: URL, settings: GIFSettings, trim: ClipTrim, report: @escaping Report) async throws -> MediaResult {
        report(nil, "Reading the video…")
        let source = try await VideoSource.load(url)
        let range = try trim.range(duration: source.duration)
        let first = GIFAttempt(fps: min(max(settings.fps, GIFPlanner.fpsRange.lowerBound), GIFPlanner.fpsRange.upperBound),
                               width: min(max(settings.width, GIFPlanner.widthRange.lowerBound), GIFPlanner.widthRange.upperBound))
        _ = try GIFPlanner.frameTimes(length: range.length, fps: first.fps)
        let target = settings.limitsSize ? TargetSizePlanner.bytes(megabytes: settings.targetMB) : nil
        let scratch = try MediaFiles.scratchFile(near: url.deletingLastPathComponent(), ext: "gif")
        defer { MediaFiles.discard(scratch) }
        var attempt = first
        var notes: [String] = []
        for number in 1...GIFPlanner.maxAttempts {
            try? FileManager.default.removeItem(at: scratch)
            let times = try GIFPlanner.frameTimes(length: range.length, fps: attempt.fps).map { range.start + $0 }
            let status = number == 1 ? "Making the GIF…" : "Still too big, trying \(attempt.fps) fps at \(attempt.width) px…"
            try await GIFMaker.write(source, times: times, size: GIFPlanner.size(width: attempt.width, source: source.displaySize), fps: attempt.fps,
                                     to: scratch) { report($0, status) }
            let bytes = MediaFiles.size(scratch)
            guard let target, bytes > target else { break }
            guard number < GIFPlanner.maxAttempts, let next = GIFPlanner.next(after: attempt, bytes: bytes, target: target) else {
                notes.append("Still above \(OutputNaming.megabytes(target)) after \(number) tries.")
                break
            }
            attempt = next
        }
        if attempt != first, let target {
            notes.insert("Made at \(attempt.fps) fps and \(attempt.width) px wide to get closer to \(OutputNaming.megabytes(target)).", at: 0)
        }
        let output = try MediaFiles.place(scratch, at: OutputNaming.sibling(of: url, suffix: "", ext: "gif"))
        return MediaResult(outputs: [output], bytesBefore: MediaFiles.size(url), bytesAfter: MediaFiles.size(output), notes: notes)
    }

    static func convertImages(_ urls: [URL], settings: ImageConvertSettings, date: Date, report: @escaping Report,
                              isCancelled: () -> Bool = { Task.isCancelled },
                              convert: (URL, ImageConvertSettings, Int, Date) throws -> URL = ImageConverter.convert) async throws -> MediaResult {
        var result = MediaResult()
        for (offset, url) in urls.enumerated() {
            if isCancelled() { break }
            report(Double(offset) / Double(urls.count), "Image \(offset + 1) of \(urls.count)…")
            do {
                let output = try convert(url, settings, offset + 1, date)
                result.outputs.append(output)
                result.bytesBefore += MediaFiles.size(url)
                result.bytesAfter += MediaFiles.size(output)
            } catch {
                result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if isCancelled() { result.notes.append("Cancelled. Kept \(result.outputs.count) saved images.") }
        return result
    }

    static func extractText(_ url: URL, report: @escaping Report) async throws -> MediaResult {
        report(nil, "Reading the text…")
        let picture = try SourceImage(url)
        let image = try picture.upright(maxPixelSize: Int(max(picture.size.width, picture.size.height)))
        try Task.checkCancellation()
        let text = TextRecognizer.recognizeText(image, removesLineBreaks: false)
        guard !text.isEmpty else { throw MediaToolError.message("No text found in this image.") }
        try Task.checkCancellation()
        let scratch = try MediaFiles.scratchFile(near: url.deletingLastPathComponent(), ext: "txt")
        defer { MediaFiles.discard(scratch) }
        try Data(text.utf8).write(to: scratch)
        let output = try MediaFiles.place(scratch, at: OutputNaming.sibling(of: url, suffix: "-text", ext: "txt"))
        return MediaResult(outputs: [output], bytesBefore: MediaFiles.size(url), bytesAfter: MediaFiles.size(output), text: text)
    }
}
