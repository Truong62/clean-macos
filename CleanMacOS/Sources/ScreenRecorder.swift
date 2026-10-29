import AVFoundation
import AppKit
import ScreenCaptureKit

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

    static func fileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screen Recording \(formatter.string(from: date)).mp4"
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

    init(url: URL, size: CGSize, systemAudio: Bool, microphone: Bool, onFrame: @escaping (IOSurfaceRef) -> Void) throws {
        self.url = url
        self.onFrame = onFrame
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let audioInput = { (isOn: Bool) in isOn ? AVAssetWriterInput(mediaType: .audio, outputSettings: ScreenRecording.audioSettings) : nil }
        self.systemAudio = audioInput(systemAudio)
        self.microphone = audioInput(microphone)
        super.init()
        for input in [video, self.systemAudio, self.microphone].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            writer.add(input)
        }
    }

    var hasTwoAudioTracks: Bool { systemAudio != nil && microphone != nil }

    func arm() {
        queue.async { [self] in isArmed = true }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(buffer) else { return }
            if let pixels = CMSampleBufferGetImageBuffer(buffer), let surface = CVPixelBufferGetIOSurface(pixels) {
                onFrame(surface.takeUnretainedValue())
            }
            guard isArmed else { return }
            if !hasStarted {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: buffer.presentationTimeStamp)
                hasStarted = true
            }
            append(buffer, to: video)
        case .audio:
            append(buffer, to: systemAudio)
        default:
            guard #available(macOS 15.0, *), type == .microphone else { return }
            append(buffer, to: microphone)
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard hasStarted else { return continuation.resume(throwing: RecordingError.failed("Nothing was recorded.")) }
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                writer.endSession(atSourceTime: endTime.isValid ? max(endTime, now) : now)
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

    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var options = RecordingOptions()

    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    func chooseSource(_ options: RecordingOptions) async {
        guard phase == .idle, Self.isSupported else { return }
        message = nil
        if options.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            message = "Clean macOS can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
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

    func startPreview(_ filter: SCContentFilter, options: RecordingOptions) async {
        guard #available(macOS 15.0, *) else { return }
        self.options = options
        let (systemAudio, microphone) = (options.systemAudio, options.microphone)
        let size = ScreenRecording.fittedSize(CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                                                     height: filter.contentRect.height * CGFloat(filter.pointPixelScale)),
                                              within: options.resolution.limit)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        configuration.showsCursor = true
        configuration.capturesAudio = systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = microphone
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        do {
            let writer = try RecordingWriter(url: url, size: size, systemAudio: systemAudio, microphone: microphone) { [weak self] surface in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(surface) } }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
            if microphone { try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue) }
            try await stream.startCapture()
            self.writer = writer
            self.stream = stream
            phase = .previewing
        } catch {
            endPicker()
            phase = .idle
            message = "Recording could not start: \(error.localizedDescription)"
        }
    }

    func startRecording() {
        guard phase == .previewing, let writer else { return }
        writer.arm()
        phase = .recording(since: Date())
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        if isRecording {
            await save()
        } else {
            discard()
        }
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
        preview.contents = nil
        endPicker()
        phase = .idle
    }

    private func save() async {
        guard let writer else { return }
        phase = .saving
        stream = nil
        self.writer = nil
        preview.contents = nil
        endPicker()
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
            try? FileManager.default.removeItem(at: writer.url)
            message = "The recording could not be saved: \(error.localizedDescription)"
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
            if self.isRecording {
                await self.save()
            } else if self.phase == .previewing {
                self.discard()
            }
        }
    }
}
