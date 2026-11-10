import AVFoundation

struct VideoWaveform {
    private(set) var peaks: [Float]
    let duration: Double

    init(duration: Double, bins: Int = 256) {
        self.duration = duration
        peaks = Array(repeating: 0, count: max(1, bins))
    }

    mutating func add(peak: Float, at time: Double) {
        guard duration > 0, time.isFinite, time >= 0, time <= duration, peak.isFinite else { return }
        let index = min(peaks.count - 1, Int(time / duration * Double(peaks.count)))
        peaks[index] = max(peaks[index], min(1, abs(peak)))
    }

    static func read(_ track: AVAssetTrack, asset: AVAsset, duration: Double) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecordingError.failed("Could not read waveform.") }
        var waveform = VideoWaveform(duration: duration)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = sample.dataBuffer else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { continue }
            let peak = pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { values in
                stride(from: 0, to: length / 4, by: 4).reduce(Float(0)) { max($0, abs(values[$1])) }
            }
            waveform.add(peak: peak, at: sample.presentationTimeStamp.seconds)
        }
        guard reader.status == .completed else { throw reader.error ?? RecordingError.failed("Waveform decoding failed.") }
        return waveform.peaks
    }
}
