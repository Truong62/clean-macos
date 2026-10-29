import AVFoundation
import Foundation
import Testing
@testable import CleanMacOS

struct ScreenRecorderTests {
    @Test func namesRecordingsLikeMacOS() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9, minute: 5, second: 7))!
        #expect(ScreenRecording.fileName(at: date) == "Screen Recording 2026-10-28 at 09.05.07.mp4")
    }

    @Test func fitsLargeScreensIntoTheEncoderLimitWithEvenSides() {
        #expect(ScreenRecording.fittedSize(CGSize(width: 5120, height: 2880)) == CGSize(width: 3840, height: 2160))
        #expect(ScreenRecording.fittedSize(CGSize(width: 2940, height: 1912)) == CGSize(width: 2940, height: 1912))
        #expect(ScreenRecording.fittedSize(CGSize(width: 801, height: 601)) == CGSize(width: 800, height: 600))
        #expect(ScreenRecording.fittedSize(CGSize(width: 3456, height: 2234)) == CGSize(width: 3340, height: 2160))
    }

    @Test func scalesDownToTheChosenResolution() {
        let retina = CGSize(width: 3456, height: 2234)
        #expect(ScreenRecording.fittedSize(retina, within: ScreenRecording.Resolution.hd1080.limit) == CGSize(width: 1670, height: 1080))
        #expect(ScreenRecording.fittedSize(retina, within: ScreenRecording.Resolution.hd720.limit) == CGSize(width: 1112, height: 720))
        #expect(ScreenRecording.fittedSize(CGSize(width: 1000, height: 600), within: ScreenRecording.Resolution.hd1080.limit)
            == CGSize(width: 1000, height: 600))
    }

    @Test func savesToMoviesUntilAFolderIsChosen() {
        #expect(ScreenRecording.folder(atPath: "") == ScreenRecording.moviesFolder())
        #expect(ScreenRecording.folder(atPath: "/Users/me/Videos").path == "/Users/me/Videos")
    }

    @Test func formatsElapsedTime() {
        #expect(ScreenRecording.elapsed(0) == "0:00")
        #expect(ScreenRecording.elapsed(65.9) == "1:05")
        #expect(ScreenRecording.elapsed(3_725) == "1:02:05")
        #expect(ScreenRecording.elapsed(-3) == "0:00")
    }

    @Test func mixesSystemAudioAndMicrophoneIntoOneTrack() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mixdown-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let system = try writeTone(to: folder.appendingPathComponent("system.m4a"), loudFirstHalf: true)
        let microphone = try writeTone(to: folder.appendingPathComponent("mic.m4a"), loudFirstHalf: false)
        let twoTracks = folder.appendingPathComponent("two.mov")
        try await combine([system, microphone], into: twoTracks)
        #expect(try await AVURLAsset(url: twoTracks).loadTracks(withMediaType: .audio).count == 2)

        let mixed = folder.appendingPathComponent("mixed.mp4")
        try await RecordingMixdown.mix(twoTracks, into: mixed)

        let tracks = try await AVURLAsset(url: mixed).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        let levels = try loudness(of: mixed)
        #expect(levels.first! > 1_000)
        #expect(levels.last! > 1_000)
    }

    private func writeTone(to url: URL, loudFirstHalf: Bool) throws -> URL {
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: 1])
        let frames = AVAudioFrameCount(rate * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let isLoud = (frame < Int(frames) / 2) == loudFirstHalf
            buffer.floatChannelData![0][frame] = isLoud ? Float(sin(Double(frame) * 2 * .pi * 440 / rate) * 0.5) : 0
        }
        try file.write(from: buffer)
        return url
    }

    private func combine(_ sources: [URL], into destination: URL) async throws {
        let composition = AVMutableComposition()
        for source in sources {
            let asset = AVURLAsset(url: source)
            let track = try await asset.loadTracks(withMediaType: .audio)[0]
            let range = try await track.load(.timeRange)
            let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try target.insertTimeRange(range, of: track, at: .zero)
        }
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await export.export(to: destination, as: .mov)
    }

    private func loudness(of url: URL) throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: asset.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            pointer!.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples += UnsafeBufferPointer(start: $0, count: length / 2) }
        }
        let half = samples.count / 2
        let rms = { (part: ArraySlice<Int16>) in (part.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(part.count)).squareRoot() }
        return [rms(samples[..<half]), rms(samples[half...])]
    }
}
