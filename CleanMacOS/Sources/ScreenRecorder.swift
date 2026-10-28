import AVFoundation
import AppKit
import ScreenCaptureKit

enum ScreenRecording {
    static let systemAudioKey = "recorder.systemAudio"
    static let microphoneKey = "recorder.microphone"
    static let maxSize = CGSize(width: 3840, height: 2160)
    static let framesPerSecond: Int32 = 30
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
    private var endTime = CMTime.invalid
    private var hasStarted = false

    init(url: URL, size: CGSize, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
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

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(buffer) else { return }
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
        case idle, choosing, recording(since: Date), saving
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastRecording: URL?
    @Published var message: String?

    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var wantsSystemAudio = true
    private var wantsMicrophone = false
    private let folder: URL

    init(folder: URL = ScreenRecording.moviesFolder()) {
        self.folder = folder
    }

    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    func chooseAndRecord(systemAudio: Bool, microphone: Bool) async {
        guard phase == .idle, Self.isSupported else { return }
        message = nil
        if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            message = "Clean macOS can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
            return
        }
        wantsSystemAudio = systemAudio
        wantsMicrophone = microphone
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        phase = .choosing
        picker.present()
    }

    func record(_ filter: SCContentFilter, systemAudio: Bool, microphone: Bool) async {
        guard #available(macOS 15.0, *) else { return }
        let size = ScreenRecording.fittedSize(CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                                                     height: filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: ScreenRecording.framesPerSecond)
        configuration.showsCursor = true
        configuration.capturesAudio = systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = microphone
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        do {
            let writer = try RecordingWriter(url: url, size: size, systemAudio: systemAudio, microphone: microphone)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
            if microphone { try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue) }
            try await stream.startCapture()
            self.writer = writer
            self.stream = stream
            phase = .recording(since: Date())
        } catch {
            endPicker()
            phase = .idle
            message = "Recording could not start: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard isRecording, let stream else { return }
        try? await stream.stopCapture()
        await save()
    }

    private func save() async {
        guard let writer else { return }
        phase = .saving
        stream = nil
        self.writer = nil
        endPicker()
        let destination = folder.appendingPathComponent(ScreenRecording.fileName(at: Date()))
        do {
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
            await self.record(filter, systemAudio: self.wantsSystemAudio, microphone: self.wantsMicrophone)
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
            guard self.isRecording else { return }
            await self.save()
        }
    }
}
