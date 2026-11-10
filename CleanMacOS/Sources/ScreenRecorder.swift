import AVFoundation
import AppKit
import ScreenCaptureKit
import CoreAudio

enum ScreenRecording {
    static let systemAudioKey = "recorder.systemAudio"
    static let microphoneKey = "recorder.microphone"
    static let framesPerSecondKey = "recorder.framesPerSecond"
    static let resolutionKey = "recorder.resolution"
    static let folderKey = "recorder.folder"
    static let frameRates = [24, 30, 60]
    static let maxSize = Resolution.full.limit
    static let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                               AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
    static let bitsPerPixel = 0.13
    static let bitRateRange = 6_000_000.0...50_000_000.0
    static let keyFrameInterval = 2.0

    static func videoBitRate(size: CGSize, framesPerSecond: Int) -> Int {
        let wanted = Double(size.width * size.height) * Double(max(framesPerSecond, 1)) * bitsPerPixel
        return Int(min(max(wanted, bitRateRange.lowerBound), bitRateRange.upperBound))
    }

    static func videoSettings(size: CGSize, framesPerSecond: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate(size: size, framesPerSecond: framesPerSecond),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: keyFrameInterval,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    static func fileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screen Recording \(formatter.string(from: date)).mp4"
    }

    static func customFileName(_ name: String) -> String? {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !cleaned.isEmpty else { return nil }
        let base = (cleaned as NSString).pathExtension.lowercased() == "mp4" ? (cleaned as NSString).deletingPathExtension : cleaned
        return "\(base).mp4"
    }

    static func fittedSize(_ size: CGSize, within limit: CGSize = maxSize) -> CGSize {
        let scale = min(1, limit.width / size.width, limit.height / size.height)
        let even = { (value: CGFloat) in max(2, (value * scale / 2).rounded(.down) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func moviesFolder() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }

    static func folder(atPath path: String) -> URL {
        path.isEmpty ? moviesFolder() : URL(fileURLWithPath: path, isDirectory: true)
    }

    enum Resolution: String, CaseIterable, Identifiable {
        case full, hd1080, hd720

        var id: Self { self }

        var title: String {
            switch self {
            case .full: "Full"
            case .hd1080: "1080p"
            case .hd720: "720p"
            }
        }

        var limit: CGSize {
            switch self {
            case .full: CGSize(width: 3840, height: 2160)
            case .hd1080: CGSize(width: 1920, height: 1080)
            case .hd720: CGSize(width: 1280, height: 720)
            }
        }
    }
}

struct RecordingOptions: Equatable {
    var systemAudio = true
    var microphone = false
    var framesPerSecond = 30
    var resolution = ScreenRecording.Resolution.full
    var folder = ScreenRecording.moviesFolder()
    var masterURL: URL?
    var audioProcessID: pid_t?
}

enum RecordingMixdown {
    static func mix(_ source: URL, into destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        var pumps: [SamplePump] = []
        for track in videoTracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            input.transform = try await track.load(.preferredTransform)
            pumps.append(SamplePump(output: output, input: input))
        }
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            pumps.append(SamplePump(output: output, input: AVAssetWriterInput(mediaType: .audio, outputSettings: ScreenRecording.audioSettings)))
        }
        for pump in pumps {
            reader.add(pump.output)
            writer.add(pump.input)
        }
        guard reader.startReading() else { throw reader.error ?? RecordingError.failed("Could not read the recording.") }
        guard writer.startWriting() else { throw writer.error ?? RecordingError.failed("Could not write the recording.") }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { group in
            for pump in pumps { group.addTask { await pump.run() } }
        }
        await writer.finishWriting()
        if let error = reader.error ?? writer.error { throw error }
    }
}

final class SamplePump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    var onAppend: ((CMTime) -> Void)?
    private let queue = DispatchQueue(label: "click.ngoctruong.CleanMacOS.mixdown")
    private var isDone = false

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while !isDone && input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        isDone = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onAppend?(CMSampleBufferGetPresentationTimeStamp(buffer))
                }
            }
        }
    }
}

enum RecordingError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

struct RecordingTimeline {
    private(set) var pauses: [(start: CMTime, end: CMTime?)] = []

    var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    mutating func pause(at time: CMTime) {
        guard !isPaused else { return }
        pauses.append((time, nil))
    }

    mutating func resume(at time: CMTime) {
        guard isPaused, let start = pauses.last?.start else { return }
        pauses[pauses.count - 1] = (start, max(time, start))
    }

    func accepts(start: CMTime, duration: CMTime) -> Bool {
        guard adjusted(start) != nil else { return false }
        let end = start + (duration.isValid ? duration : .zero)
        return !pauses.contains { start < $0.start && end > $0.start }
    }

    func adjusted(_ time: CMTime) -> CMTime? {
        var offset = CMTime.zero
        for pause in pauses where time >= pause.start {
            guard let end = pause.end, time >= end else { return nil }
            offset = offset + (end - pause.start)
        }
        return time - offset
    }

    func outputTime(at now: CMTime) -> CMTime {
        let time = isPaused ? pauses[pauses.count - 1].start : now
        let offset = pauses.reduce(CMTime.zero) { total, pause in
            guard let end = pause.end, end <= time else { return total }
            return total + (end - pause.start)
        }
        return time - offset
    }
}

final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "click.ngoctruong.CleanMacOS.recording")
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let onFrame: (IOSurfaceRef) -> Void
    private var endTime = CMTime.invalid
    private var hasStarted = false
    private var isArmed = false
    private var timeline = RecordingTimeline()
    private var lastFrame: CMSampleBuffer?
    private var origin: CMTime?
    private var stopTime: CMTime?
    private var audioChoice = RecordingAudioChoice()
    private var usesTap = false
    private var appAudio = false
    private var lastSystemAudio = CMTime.invalid

    init(url: URL, size: CGSize, framesPerSecond: Int, systemAudio: Bool, microphone: Bool, onFrame: @escaping (IOSurfaceRef) -> Void) throws {
        self.url = url
        self.onFrame = onFrame
        writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mov" ? .mov : .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: url.pathExtension == "mov" ? RecordingCodec.settings(size: size, fps: framesPerSecond) : ScreenRecording.videoSettings(size: size, framesPerSecond: framesPerSecond))
        var audioSettings = ScreenRecording.audioSettings
        if url.pathExtension == "mov" { audioSettings[AVEncoderBitRateKey] = 160_000 }
        let audioInput = { (isOn: Bool) in isOn ? AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) : nil }
        self.systemAudio = audioInput(systemAudio)
        self.microphone = audioInput(microphone)
        super.init()
        audioChoice.trusted = UserDefaults.standard.bool(forKey: "recording.tap.hasHeardSound")
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        for (input, name) in [(self.systemAudio, "mackit.system-audio"), (self.microphone, "mackit.microphone")] {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataContentIdentifier
            item.value = name as NSString
            input?.metadata = [item]
        }
        for input in [video, self.systemAudio, self.microphone].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            writer.add(input)
        }
    }

    var hasTwoAudioTracks: Bool { systemAudio != nil && microphone != nil }

    func arm() {
        queue.async { [self] in isArmed = true }
    }

    func pause() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in timeline.pause(at: now) }
    }

    func resume() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in timeline.resume(at: now) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(buffer) else { return }
            if let pixels = CMSampleBufferGetImageBuffer(buffer), let surface = CVPixelBufferGetIOSurface(pixels) {
                onFrame(surface.takeUnretainedValue())
            }
            guard isArmed, let buffer = retimed(buffer) else { return }
            if !hasStarted {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: buffer.presentationTimeStamp)
                hasStarted = true
                origin = buffer.presentationTimeStamp
            }
            append(buffer, to: video)
            lastFrame = buffer
        case .audio:
            usesTap = audioChoice.stream(time: buffer.presentationTimeStamp.seconds, audible: Self.audible(buffer), appOnly: appAudio)
            guard !usesTap, let buffer = retimed(buffer) else { return }
            appendSystem(buffer)
        default:
            guard #available(macOS 15.0, *), type == .microphone, let buffer = retimed(buffer) else { return }
            append(buffer, to: microphone)
        }
    }

    func seal() {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in stopTime = time }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard hasStarted else { return continuation.resume(throwing: RecordingError.failed("Nothing was recorded.")) }
                let now = timeline.outputTime(at: stopTime ?? CMClockGetTime(CMClockGetHostTimeClock()))
                holdLastFrame(until: now)
                writer.endSession(atSourceTime: now)
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

    private func holdLastFrame(until end: CMTime) {
        guard let lastFrame, video.isReadyForMoreMediaData else { return }
        let step = CMTime(value: 1, timescale: 60)
        let time = end - step
        guard time > lastFrame.presentationTimeStamp + step else { return }
        var timing = CMSampleTimingInfo(duration: step, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: lastFrame, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        if let copy, video.append(copy) { endTime = endTime.isValid ? max(endTime, end) : end }
    }

    func elapsed(at time: CMTime) -> Double? {
        queue.sync {
            guard stopTime.map({ time <= $0 }) ?? true, let origin, let adjusted = timeline.adjusted(time) else { return nil }
            return max(0, (adjusted - origin).seconds)
        }
    }

    func receiveTap(_ buffer: CMSampleBuffer, appOnly: Bool) {
        queue.async { [self] in
            appAudio = appOnly
            let heard = Self.audible(buffer)
            if heard, !audioChoice.trusted { UserDefaults.standard.set(true, forKey: "recording.tap.hasHeardSound") }
            audioChoice.tap(time: buffer.presentationTimeStamp.seconds, audible: heard)
            guard usesTap, let adjusted = retimed(buffer) else { return }
            appendSystem(adjusted)
        }
    }

    private func appendSystem(_ buffer: CMSampleBuffer) {
        guard !lastSystemAudio.isValid || buffer.presentationTimeStamp >= lastSystemAudio else { return }
        append(buffer, to: systemAudio)
        lastSystemAudio = buffer.presentationTimeStamp + (buffer.duration.isValid ? buffer.duration : .zero)
    }

    private static func audible(_ sample: CMSampleBuffer) -> Bool {
        guard let block = sample.dataBuffer else { return false }
        var length = 0
        var bytes: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &bytes) == noErr, let bytes else { return false }
        return bytes.withMemoryRebound(to: Float.self, capacity: length / 4) { values in
            stride(from: 0, to: length / 4, by: 8).contains { values[$0].isFinite && abs(values[$0]) > 0.0001 }
        }
    }

    func appendMicrophone(_ buffer: CMSampleBuffer) {
        queue.async { [self] in
            guard let buffer = retimed(buffer) else { return }
            append(buffer, to: microphone)
        }
    }

    private func retimed(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        if let stopTime, buffer.presentationTimeStamp + (buffer.duration.isValid ? buffer.duration : .zero) > stopTime { return nil }
        guard timeline.accepts(start: buffer.presentationTimeStamp, duration: buffer.duration) else { return nil }
        guard !timeline.pauses.isEmpty else { return buffer }
        guard let presentation = timeline.adjusted(buffer.presentationTimeStamp) else { return nil }
        let offset = buffer.presentationTimeStamp - presentation
        guard offset != .zero else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp - offset
            if timings[index].decodeTimeStamp.isValid { timings[index].decodeTimeStamp = timings[index].decodeTimeStamp - offset }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timings, sampleBufferOut: &copy)
        return copy
    }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard hasStarted, let input, input.isReadyForMoreMediaData, input.append(buffer) else { return }
        let end = buffer.presentationTimeStamp + (buffer.duration.isValid ? buffer.duration : .zero)
        endTime = endTime.isValid ? max(endTime, end) : end
    }

    static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }
}

@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle, choosing, previewing, recording(since: Date), saving
    }

    let preview: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        return layer
    }()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastRecording: URL?
    @Published var message: String?

    var didFinishMaster: ((URL) -> Void)?
    private var microphoneCapture: RecordingMicrophone?
    private var audioTap: AnyObject?
    private var tapSignature = ""
    private var stopping = false
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var options = RecordingOptions()
    private var configuration: SCStreamConfiguration?
    private(set) var baseSourceRect: CGRect = .zero
    private(set) var currentSourceRect: CGRect = .zero
    private(set) var outputSize: CGSize = .zero
    var showsPreview = true

    static var isSupported: Bool { true }

    func elapsed(at time: CMTime) -> Double? { writer?.elapsed(at: time) }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    func chooseSource(_ options: RecordingOptions) async {
        guard phase == .idle, Self.isSupported else { return }
        message = nil
        if options.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            message = "\(AppIdentity.installedName) can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
            return
        }
        self.options = options
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        phase = .choosing
        picker.present()
    }

    func startPreview(_ filter: SCContentFilter, options: RecordingOptions, sourceRect: CGRect? = nil, showsCursor: Bool = true) async {
        self.options = options
        let (systemAudio, microphone) = (options.systemAudio, options.microphone)
        let region = sourceRect ?? CGRect(origin: .zero, size: filter.contentRect.size)
        let pixels = CGSize(width: region.width * CGFloat(filter.pointPixelScale), height: region.height * CGFloat(filter.pointPixelScale))
        let size = ScreenRecording.fittedSize(pixels, within: options.masterURL == nil ? options.resolution.limit : pixels)
        let configuration = SCStreamConfiguration()
        if let sourceRect { configuration.sourceRect = sourceRect }
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        configuration.showsCursor = showsCursor
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.capturesAudio = systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreShadowsDisplay = true
        configuration.captureResolution = .best
        if #available(macOS 15.0, *) { configuration.captureMicrophone = microphone }
        let url = options.masterURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        do {
            let showsPreview = showsPreview
            let writer = try RecordingWriter(url: url, size: size, framesPerSecond: options.framesPerSecond, systemAudio: systemAudio,
                                             microphone: microphone) { [weak self] surface in
                guard showsPreview else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(surface) } }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
            if microphone {
                if #available(macOS 15.0, *) {
                    try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
                } else {
                    let capture = RecordingMicrophone()
                    do { try capture.start(writer: writer); microphoneCapture = capture }
                    catch { message = "Microphone unavailable. Recording continues without it." }
                }
            }
            try await stream.startCapture()
            self.writer = writer
            self.stream = stream
            self.configuration = configuration
            baseSourceRect = region
            currentSourceRect = region
            outputSize = size
            phase = .previewing
            refreshAudioTap()
        } catch {
            endPicker()
            phase = .idle
            message = "Recording could not start: \(error.localizedDescription)"
        }
    }

    func refreshAudioTap() {
        guard #available(macOS 14.4, *), options.masterURL != nil, options.systemAudio, let writer else { return }
        guard let output = SoundHardware.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return }
        guard let uid = AudioProperty.string(output, kAudioDevicePropertyDeviceUID) else { return }
        let all = AudioProcesses.list()
        let processes: [AudioObjectID]
        if let pid = options.audioProcessID {
            processes = all.filter { AudioProcesses.owner(of: $0.pid)?.processIdentifier == pid }.map(\.object)
        } else { processes = all.filter { $0.pid == getpid() }.map(\.object) }
        let rate = AudioProperty.get(output, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
        let signature = "\(uid):\(rate):\(processes.sorted())"
        guard signature != tapSignature else { return }
        (audioTap as? RecordingAudioTap)?.stop()
        audioTap = nil
        tapSignature = signature
        let appOnly = options.audioProcessID != nil
        guard !appOnly || !processes.isEmpty else { return }
        let tap = RecordingAudioTap { [weak writer] buffer in writer?.receiveTap(buffer, appOnly: appOnly) }
        do { try tap.start(processes: processes, excluding: !appOnly, outputUID: uid, outputChannels: RecordingAudioTap.outputChannels(of: output)); audioTap = tap }
        catch { tap.stop() }
    }

    private func stopAudioTap() {
        if #available(macOS 14.4, *) { (audioTap as? RecordingAudioTap)?.stop() }
        audioTap = nil
        tapSignature = ""
    }

    func startRecording() {
        guard phase == .previewing, let writer else { return }
        writer.arm()
        phase = .recording(since: Date())
    }

    func stop() async {
        guard !stopping, phase != .saving, let stream else { return }
        stopping = true
        writer?.seal()
        defer { stopping = false }
        stopAudioTap()
        microphoneCapture?.stop()
        microphoneCapture = nil
        try? await stream.stopCapture()
        if isRecording {
            await save()
        } else {
            discard()
        }
    }

    func pauseCapture() {
        writer?.pause()
    }

    func resumeCapture() {
        writer?.resume()
    }

    func setSourceRect(_ rect: CGRect) async throws {
        guard let stream, let configuration else { return }
        configuration.sourceRect = rect
        currentSourceRect = rect
        try await stream.updateConfiguration(configuration)
    }

    func changeSource() async {
        let options = options
        await stop()
        await chooseSource(options)
    }

    private func show(_ surface: IOSurfaceRef) {
        guard stream != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.contents = surface
        CATransaction.commit()
    }

    private func discard() {
        stream = nil
        writer = nil
        configuration = nil
        preview.contents = nil
        endPicker()
        phase = .idle
    }

    private func save() async {
        guard phase != .saving, let writer else { return }
        stopAudioTap()
        microphoneCapture?.stop()
        microphoneCapture = nil
        phase = .saving
        stream = nil
        self.writer = nil
        configuration = nil
        preview.contents = nil
        endPicker()
        if options.masterURL != nil {
            do {
                try await writer.finish()
                didFinishMaster?(writer.url)
            } catch { message = "The recording could not be finished: \(error.localizedDescription)" }
            phase = .idle
            return
        }
        let folder = options.folder
        let destination = folder.appendingPathComponent(ScreenRecording.fileName(at: Date()))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await writer.finish()
            if writer.hasTwoAudioTracks {
                try await RecordingMixdown.mix(writer.url, into: destination)
                try? FileManager.default.removeItem(at: writer.url)
            } else {
                try FileManager.default.moveItem(at: writer.url, to: destination)
            }
            lastRecording = destination
        } catch {
            message = "The recording is retained at \(writer.url.path). It could not be saved: \(error.localizedDescription)"
        }
        phase = .idle
    }

    private func endPicker() {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
    }
}

extension ScreenRecorder: SCContentSharingPickerObserver, SCStreamDelegate {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            guard self.phase == .choosing else { return }
            self.endPicker()
            self.phase = .idle
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard self.phase == .choosing else { return }
            await self.startPreview(filter, options: self.options)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.endPicker()
            self.phase = .idle
            self.message = "Could not open the screen picker: \(error.localizedDescription)"
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard !self.stopping else { return }
            if self.isRecording {
                await self.save()
            } else if self.phase == .previewing {
                self.discard()
            }
        }
    }
}
