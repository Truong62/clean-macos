import AVFoundation

final class RecordingMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private weak var writer: RecordingWriter?
    private let queue = DispatchQueue(label: "mackit.recording.microphone")

    func start(writer: RecordingWriter) throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw RecordingError.failed("No microphone is available.") }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { throw RecordingError.failed("The microphone is unavailable.") }
        session.addInput(input)
        session.addOutput(output)
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                                AVNumberOfChannelsKey: 2, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false]
        self.writer = writer
        output.setSampleBufferDelegate(self, queue: queue)
        queue.async { [self] in session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock else { return }
        let host = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: sampleBuffer.duration, presentationTimeStamp: host, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
                                                  sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy else { return }
        writer?.appendMicrophone(copy)
    }

    func stop() { queue.async { [self] in session.stopRunning(); writer = nil } }
}
