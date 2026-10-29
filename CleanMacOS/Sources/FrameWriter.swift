import AVFoundation
import CoreImage

struct ZoomTrack {
    private var from: CGRect
    private var to: CGRect
    private var start: Double = 0
    private var duration: Double = 0

    init(base: CGRect) {
        from = base
        to = base
    }

    func rect(at time: Double) -> CGRect {
        guard duration > 0, time < start + duration else { return to }
        let progress = max(0, (time - start) / duration)
        return ZoomMath.interpolate(from: from, to: to, progress: CGFloat(progress))
    }

    mutating func move(to target: CGRect, at time: Double, duration: Double) {
        from = rect(at: time)
        to = target
        start = time
        self.duration = duration
    }
}

enum FrameComposer {
    static func transform(imageSize: CGSize, crop: CGRect, output: CGSize) -> CGAffineTransform {
        let zoom = output.width / crop.width
        return CGAffineTransform(scaleX: output.width / imageSize.width * zoom, y: output.height / imageSize.height * zoom)
            .concatenating(CGAffineTransform(translationX: -crop.minX * zoom, y: -(output.height - crop.maxY) * zoom))
    }
}

final class FrameWriter: @unchecked Sendable {
    let url: URL
    let size: CGSize
    private let queue = DispatchQueue(label: "click.ngoctruong.CleanMacOS.frames")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext()
    private let interval: Double
    private var timer: DispatchSourceTimer?
    private var latest: CIImage?
    private var timeline = RecordingTimeline()
    private var zoom: ZoomTrack
    private var hasStarted = false
    private var lastTime = CMTime.invalid

    init(url: URL, size: CGSize, framesPerSecond: Int) throws {
        self.url = url
        self.size = size
        interval = 1 / Double(max(framesPerSecond, 1))
        zoom = ZoomTrack(base: CGRect(origin: .zero, size: size))
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(input)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func update(_ image: CGImage) {
        let frame = CIImage(cgImage: image)
        queue.async { [self] in latest = frame }
    }

    func pause() {
        let now = Self.now
        queue.async { [self] in timeline.pause(at: now) }
    }

    func resume() {
        let now = Self.now
        queue.async { [self] in timeline.resume(at: now) }
    }

    func zoom(to rect: CGRect, duration: Double) {
        let now = Self.now.seconds
        queue.async { [self] in zoom.move(to: rect, at: now, duration: duration) }
    }

    func currentZoom() -> CGRect {
        let now = Self.now.seconds
        return queue.sync { zoom.rect(at: now) }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                guard hasStarted else { return continuation.resume(throwing: RecordingError.failed("Nothing was recorded.")) }
                let end = timeline.outputTime(at: Self.now)
                input.markAsFinished()
                writer.endSession(atSourceTime: lastTime.isValid ? max(end, lastTime) : end)
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: writer.error ?? RecordingError.failed("The recording could not be saved."))
                    }
                }
            }
        }
    }

    private static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    private func tick() {
        let now = Self.now
        guard let image = latest, let time = timeline.adjusted(now) else { return }
        if lastTime.isValid, time <= lastTime { return }
        if !hasStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            hasStarted = true
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        let crop = zoom.rect(at: now.seconds)
        let transform = FrameComposer.transform(imageSize: image.extent.size, crop: crop, output: size)
        context.render(image.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: size)), to: buffer)
        if adaptor.append(buffer, withPresentationTime: time) { lastTime = time }
    }
}

struct WebKey: Equatable {
    let key: String
    let code: String
    let keyCode: Int
    let text: String?
    let modifiers: Int

    static let named: [String: (key: String, code: String, keyCode: Int, text: String?)] = [
        "return": ("Enter", "Enter", 13, "\r"), "enter": ("Enter", "Enter", 13, "\r"), "tab": ("Tab", "Tab", 9, nil),
        "escape": ("Escape", "Escape", 27, nil), "esc": ("Escape", "Escape", 27, nil), "space": (" ", "Space", 32, " "),
        "delete": ("Backspace", "Backspace", 8, nil), "backspace": ("Backspace", "Backspace", 8, nil),
        "forwarddelete": ("Delete", "Delete", 46, nil), "up": ("ArrowUp", "ArrowUp", 38, nil), "down": ("ArrowDown", "ArrowDown", 40, nil),
        "left": ("ArrowLeft", "ArrowLeft", 37, nil), "right": ("ArrowRight", "ArrowRight", 39, nil), "home": ("Home", "Home", 36, nil),
        "end": ("End", "End", 35, nil), "pageup": ("PageUp", "PageUp", 33, nil), "pagedown": ("PageDown", "PageDown", 34, nil),
    ]
    static let modifierBits = ["alt": 1, "opt": 1, "option": 1, "ctrl": 2, "control": 2, "cmd": 4, "command": 4, "meta": 4, "shift": 8]

    static func parse(_ text: String) -> WebKey? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var modifiers = 0
        for part in parts.dropLast() {
            guard let bit = modifierBits[part] else { return nil }
            modifiers |= bit
        }
        let printable = modifiers & ~8 == 0
        if let named = named[last] {
            return WebKey(key: named.key, code: named.code, keyCode: named.keyCode, text: printable ? named.text : nil, modifiers: modifiers)
        }
        guard last.count == 1, let scalar = last.unicodeScalars.first, scalar.isASCII,
              CharacterSet.alphanumerics.contains(scalar) else { return nil }
        let isLetter = CharacterSet.letters.contains(scalar)
        let character = modifiers & 8 != 0 ? last.uppercased() : last
        return WebKey(key: character, code: isLetter ? "Key\(last.uppercased())" : "Digit\(last)",
                      keyCode: Int(last.uppercased().unicodeScalars.first!.value), text: printable ? character : nil, modifiers: modifiers)
    }
}
