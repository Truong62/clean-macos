import AVFoundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct VideoRenderPlan: @unchecked Sendable {
    let document: VideoEditDocument
    let tracks: VideoTracks
    let sourceSize: CGSize
    let canvas: CGSize
    let images: [UUID: CIImage]
    let camera: [VideoCameraSample]
    let backgroundImage: CIImage?
    let cursorImages: [String: CIImage]
    let pointerOpacities: [Double]

    static func canvas(source: CGSize, document: VideoEditDocument) -> CGSize {
        let ratio: CGFloat
        switch document.shape {
        case .original: ratio = source.width / max(1, source.height)
        case .wide: ratio = 16 / 9
        case .square: ratio = 1
        case .portrait: ratio = 9 / 16
        }
        let longest = min(3840, max(source.width, source.height)) * (document.quality == .small ? 0.5 : 1)
        return CGSize(width: max(2, floor((ratio >= 1 ? longest : longest * ratio) / 2) * 2),
                      height: max(2, floor((ratio >= 1 ? longest / ratio : longest) / 2) * 2))
    }

    func render(_ original: CIImage, at outputTime: Double) -> CIImage {
        let time = VideoTimeline.sourceTime(outputTime, pieces: document.pieces)
        let bounds = CGRect(origin: .zero, size: sourceSize)
        var source = original.transformed(by: CGAffineTransform(translationX: -original.extent.minX, y: -original.extent.minY))
        for overlay in document.overlays where overlay.kind == .blur && overlay.span.contains(time) {
            let rect = CGRect(x: overlay.rect.minX * bounds.width, y: (1 - overlay.rect.maxY) * bounds.height,
                              width: overlay.rect.width * bounds.width, height: overlay.rect.height * bounds.height)
            let block = min(48, max(8, min(rect.width, rect.height) / 3)) * min(5, max(1, overlay.strength))
            let blurred = source.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1]).cropped(to: rect)
            source = blurred.composited(over: source)
        }
        let pointerIndex = VideoMotion.index(at: time, in: tracks.pointer)
        let pointer = pointerIndex.map { tracks.pointer[$0] }
        if document.pointer, let pointer, pointer.visible {
            let point = CGPoint(x: pointer.point.x * bounds.width, y: (1 - pointer.point.y) * bounds.height)
            let pressedScale = pointer.pressed ? 0.8 : 1.0
            let size = 22 * document.pointerSize * pressedScale
            let opacity = pointerIndex.map { pointerOpacities[$0] } ?? 0
            let arrow: CIImage
            if let id = pointer.shape, let shape = tracks.cursors[id], let bitmap = cursorImages[id] {
                let factor = shape.pointSize.width * tracks.displayScale * pointer.scale * document.pointerSize * pressedScale / bitmap.extent.width
                let hotSpot = shape.hotSpot.applying(CGAffineTransform(scaleX: tracks.displayScale * pointer.scale * document.pointerSize * pressedScale, y: tracks.displayScale * pointer.scale * document.pointerSize * pressedScale))
                let scaled = bitmap.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                arrow = scaled.transformed(by: CGAffineTransform(translationX: point.x - hotSpot.x, y: point.y - scaled.extent.height + hotSpot.y))
            } else { arrow = Self.arrow(size: size).transformed(by: CGAffineTransform(translationX: point.x, y: point.y - size)) }
            source = arrow.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)]).composited(over: source)
            if document.clickRings, let click = tracks.clicks.last(where: { $0 <= time }), time - click < 0.4 {
                let age = (time - click) / 0.4
                let radius = 8 + 28 * (1 - pow(1 - age, 3))
                let ring = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(cgPoint: point), "inputRadius0": radius - 2,
                    "inputRadius1": radius, "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.35 * (1 - age)), "inputColor1": CIColor.clear])?.outputImage
                if let ring { source = ring.cropped(to: bounds).composited(over: source) }
            }
        }
        if !camera.isEmpty {
            let motion = camera[min(camera.count - 1, max(0, Int(time * 60)))]
            source = source.transformed(by: CGAffineTransform(translationX: -motion.origin.x * bounds.width, y: -motion.origin.y * bounds.height))
                .transformed(by: CGAffineTransform(scaleX: motion.scale, y: motion.scale)).cropped(to: bounds)
        }
        let margin = min(0.45, max(0, document.margin)) / 2
        let fit = min(canvas.width * (1 - margin * 2) / sourceSize.width, canvas.height * (1 - margin * 2) / sourceSize.height)
        let inset = CGRect(x: (canvas.width - sourceSize.width * fit) / 2, y: (canvas.height - sourceSize.height * fit) / 2,
                           width: sourceSize.width * fit, height: sourceSize.height * fit)
        source = source.transformed(by: CGAffineTransform(scaleX: fit, y: fit)).transformed(by: CGAffineTransform(translationX: inset.minX, y: inset.minY))
        if document.corners > 0 {
            let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: inset),
                "inputRadius": min(inset.width, inset.height) * document.corners / 2, "inputColor": CIColor.white])!.outputImage!
            source = source.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        }
        let canvasRect = CGRect(origin: .zero, size: canvas)
        var background = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: canvas.width, y: canvas.height),
            "inputColor0": CIColor(red: 0.07, green: 0.08, blue: 0.10), "inputColor1": CIColor(red: 0.25, green: 0.27, blue: 0.30)])!.outputImage!.cropped(to: canvasRect)
        if document.background == .none { background = CIImage(color: .black).cropped(to: canvasRect) }
        if document.background == .color {
            let colors: [String: CIColor] = ["graphite": CIColor(red: 0.12, green: 0.13, blue: 0.15), "white": .white, "black": .black,
                "blue": CIColor(red: 0.15, green: 0.3, blue: 0.6), "green": CIColor(red: 0.1, green: 0.4, blue: 0.3), "purple": CIColor(red: 0.3, green: 0.15, blue: 0.45)]
            background = CIImage(color: colors[document.backgroundColor] ?? .black).cropped(to: canvasRect)
        }
        if let image = backgroundImage, document.background == .image || document.background == .wallpaper {
            let factor = max(canvas.width / image.extent.width, canvas.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            background = scaled.transformed(by: CGAffineTransform(translationX: (canvas.width - scaled.extent.width) / 2 - scaled.extent.minX, y: (canvas.height - scaled.extent.height) / 2 - scaled.extent.minY))
                .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: document.backgroundBlur * 80]).cropped(to: canvasRect)
        }
        if margin > 0 {
            let shadow = source.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45)])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18]).transformed(by: CGAffineTransform(translationX: 0, y: -8))
            background = shadow.composited(over: background)
        }
        var result = source.composited(over: background)
        for overlay in document.overlays where overlay.kind != .blur && overlay.span.contains(time) {
            guard var image = images[overlay.id], image.extent.width > 0 else { continue }
            let width = canvas.width * min(0.6, max(0.04, overlay.size))
            let scale = overlay.kind == .text ? canvas.height * min(0.16, max(0.03, overlay.size)) / image.extent.height : width / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let position = min(8, max(0, overlay.position))
            let x = (canvas.width - image.extent.width) * CGFloat(position % 3) / 2
            let y = (canvas.height - image.extent.height) * CGFloat(2 - position / 3) / 2
            let fade = min(1, max(0, min(time - overlay.span.start, overlay.span.end - time) / 0.25)) * overlay.opacity
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: fade)])
            result = image.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: result)
        }
        return result.cropped(to: canvasRect)
    }

    private static func arrow(size: Double) -> CIImage {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1, y: size - 1))
        path.addLine(to: CGPoint(x: 1, y: 1))
        path.addLine(to: CGPoint(x: size * 0.3, y: size * 0.3))
        path.addLine(to: CGPoint(x: size * 0.6, y: 0))
        path.addLine(to: CGPoint(x: size * 0.75, y: size * 0.12))
        path.addLine(to: CGPoint(x: size * 0.45, y: size * 0.42))
        path.addLine(to: CGPoint(x: size * 0.9, y: size * 0.42))
        path.closeSubpath()
        let context = CGContext(data: nil, width: max(2, Int(ceil(size))), height: max(2, Int(ceil(size))), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1)
        context.drawPath(using: .fillStroke)
        return CIImage(cgImage: context.makeImage()!)
    }
}

struct VideoCompositionResult {
    let composition: AVMutableComposition
    let video: AVVideoComposition
    let audio: AVAudioMix
    let size: CGSize
    let fps: Float
}

enum VideoCompositionBuilder {
    static func build(master: URL, document: VideoEditDocument, tracks: VideoTracks, exporting: Bool) async throws -> VideoCompositionResult {
        let asset = AVURLAsset(url: master)
        guard let original = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingError.failed("This file has no video track.") }
        let natural = try await original.load(.naturalSize)
        let transform = try await original.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: natural).applying(transform)
        let sourceSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let rawFPS = try await original.load(.nominalFrameRate)
        let fps: Float = rawFPS.isFinite && rawFPS > 0 ? rawFPS : 30
        guard sourceSize.width > 0, sourceSize.height > 0 else { throw RecordingError.failed("The video dimensions are invalid.") }
        let composition = AVMutableComposition()
        let sources = [original] + (try await asset.loadTracks(withMediaType: .audio))
        var audioParameters: [AVAudioMixInputParameters] = []
        for (index, source) in sources.enumerated() {
            guard let target = composition.addMutableTrack(withMediaType: source.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            if index == 0 { target.preferredTransform = transform }
            let available = try await source.load(.timeRange)
            var offset = CMTime.zero
            for span in document.pieces {
                let range = CMTimeRange(start: CMTime(seconds: span.start, preferredTimescale: 60000), duration: CMTime(seconds: span.duration, preferredTimescale: 60000))
                let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
                if intersection.duration > .zero { try target.insertTimeRange(intersection, of: source, at: offset + intersection.start - range.start) }
                offset = offset + range.duration
            }
            if index > 0 {
                let parameter = AVMutableAudioMixInputParameters(track: target)
                parameter.setVolume(document.volumes.indices.contains(index - 1) ? document.volumes[index - 1] : 1, at: .zero)
                parameter.audioTimePitchAlgorithm = .spectral
                audioParameters.append(parameter)
            }
        }
        let speed = exporting ? min(4, max(0.25, document.speed)) : 1
        if speed != 1 {
            let range = CMTimeRange(start: .zero, duration: composition.duration)
            composition.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / speed))
        }
        var images: [UUID: CIImage] = [:]
        for overlay in document.overlays {
            if overlay.kind == .image, !overlay.image.contains("/"), !overlay.image.isEmpty {
                images[overlay.id] = CIImage(contentsOf: master.deletingLastPathComponent().appendingPathComponent(overlay.image))
            } else if overlay.kind == .text {
                let text = String(overlay.text.prefix(200)).components(separatedBy: "\n").prefix(3).joined(separator: "\n")
                let colors: [String: NSColor] = ["white": .white, "black": .black, "red": .systemRed, "blue": .systemBlue, "yellow": .systemYellow, "green": .systemGreen]
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: colors[overlay.color] ?? .white]
                let size = (text as NSString).size(withAttributes: attributes)
                if size.width > 0, size.height > 0 {
                    let image = NSImage(size: size)
                    image.lockFocus()
                    (text as NSString).draw(at: .zero, withAttributes: attributes)
                    image.unlockFocus()
                    if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { images[overlay.id] = CIImage(cgImage: cg) }
                }
            }
        }
        let size = VideoRenderPlan.canvas(source: sourceSize, document: document)
        var renderedTracks = tracks
        renderedTracks.pointer = VideoMotion.smoothed(tracks.pointer, clicks: tracks.clicks, mode: document.smoothing)
        let plan = VideoRenderPlan(document: document, tracks: renderedTracks, sourceSize: sourceSize, canvas: size, images: images,
                                   camera: VideoCamera.build(zooms: document.zooms, pointer: renderedTracks.pointer, duration: document.trim.end),
                                   backgroundImage: document.backgroundImage.isEmpty || document.backgroundImage.contains("/") ? nil : CIImage(contentsOf: master.deletingLastPathComponent().appendingPathComponent(document.backgroundImage)),
                                   cursorImages: tracks.cursors.compactMapValues { CIImage(data: $0.png) },
                                   pointerOpacities: VideoMotion.opacities(renderedTracks.pointer))
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = VideoCompositor.self
        guard let target = composition.tracks(withMediaType: .video).first else { throw RecordingError.failed("The edited movie has no video.") }
        video.instructions = [VideoInstruction(range: CMTimeRange(start: .zero, duration: composition.duration), sourceID: target.trackID,
                                               plan: plan, transform: transform, speed: speed)]
        video.renderSize = size
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
        let audio = AVMutableAudioMix()
        audio.inputParameters = audioParameters
        return VideoCompositionResult(composition: composition, video: video, audio: audio, size: size, fps: max(1, fps))
    }
}

enum VideoExport {
    static func run(master: URL, document: VideoEditDocument, tracks: VideoTracks, destination: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let built = try await VideoCompositionBuilder.build(master: master, document: document, tracks: tracks, exporting: true)
        try Task.checkCancellation()
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(document.format.rawValue)")
        defer { try? FileManager.default.removeItem(at: staged) }
        if document.format == .gif { try await gif(built, document: document, destination: staged, progress: progress) }
        else { try await movie(built, document: document, destination: staged, progress: progress) }
        try Task.checkCancellation()
        try VideoTakeFiles.install(staged, at: destination)
    }

    private static func movie(_ built: VideoCompositionResult, document: VideoEditDocument, destination: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = built.video
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let settings = RecordingCodec.settings(size: built.size, fps: Int(built.fps), bits: document.quality.bits, keyframes: document.quality.keyframes)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writer.add(input)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        let audioTracks = built.composition.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            output.audioMix = built.audio
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: ScreenRecording.audioSettings)
            writer.add(input)
            audioOutput = output
            audioInput = input
        }
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? RecordingError.failed("Export could not start.") }
        writer.startSession(atSourceTime: .zero)
        do {
            var videoDone = false
            var audioDone = audioInput == nil
            while !videoDone || !audioDone {
                try Task.checkCancellation()
                if !videoDone, input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        guard input.append(sample) else { throw writer.error ?? RecordingError.failed("Video encoding failed.") }
                        progress(min(0.99, sample.presentationTimeStamp.seconds / max(0.001, built.composition.duration.seconds)))
                    } else { videoDone = true; input.markAsFinished() }
                }
                if !audioDone, let audioInput, audioInput.isReadyForMoreMediaData {
                    if let sample = audioOutput?.copyNextSampleBuffer() {
                        guard audioInput.append(sample) else { throw writer.error ?? RecordingError.failed("Audio encoding failed.") }
                    } else { audioDone = true; audioInput.markAsFinished() }
                }
                if writer.status == .failed || reader.status == .failed { throw writer.error ?? reader.error ?? RecordingError.failed("Export failed.") }
                try await Task.sleep(for: .milliseconds(1))
            }
            await writer.finishWriting()
            guard writer.status == .completed, reader.status == .completed else { throw writer.error ?? reader.error ?? RecordingError.failed("Export was incomplete.") }
            progress(1)
        } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
    }

    private static func gif(_ built: VideoCompositionResult, document: VideoEditDocument, destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.video
        generator.maximumSize = CGSize(width: built.size.width * document.gifScale, height: built.size.height * document.gifScale)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let count = max(1, Int(ceil(built.composition.duration.seconds * document.gifFPS)))
        let delays = VideoTimeline.gifDelays(frames: count, fps: document.gifFPS)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw RecordingError.failed("Could not create GIF.") }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        for start in stride(from: 0, to: count, by: 300) {
            let end = min(count, start + 300)
            let data = NSMutableData()
            guard let chunk = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, end - start, nil) else { throw RecordingError.failed("Could not create GIF chunk.") }
            CGImageDestinationSetProperties(chunk, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: false]] as CFDictionary)
            for index in start..<end {
                try Task.checkCancellation()
                let image = try await generator.image(at: CMTime(seconds: Double(index) / document.gifFPS, preferredTimescale: 60000)).image
                CGImageDestinationAddImage(chunk, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[index], kCGImagePropertyGIFUnclampedDelayTime: delays[index]]] as CFDictionary)
                progress(Double(index + 1) / Double(count))
            }
            guard CGImageDestinationFinalize(chunk) else { throw RecordingError.failed("GIF encoding failed.") }
            let parsed = try VideoGIFChunk(data: data as Data, includesLoop: start == 0)
            if start == 0 { try file.write(contentsOf: parsed.header) }
            try file.write(contentsOf: parsed.records)
        }
        try file.write(contentsOf: Data([0x3B]))
        try file.synchronize()
    }
}
