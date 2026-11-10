import AVFoundation
import Foundation
import Testing
@testable import CleanMacOS

enum AudioFixture {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("music-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ url: URL, format: AudioFormatID, rate: Double, bits: Int = 24, seconds: Double = 0.1) throws {
        var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        if format == kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = bits
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = url.pathExtension.hasPrefix("aif")
        } else if format != kAudioFormatMPEG4AAC {
            settings[AVEncoderBitDepthHintKey] = bits
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.05) * 0.25) }
        }
        try file.write(from: buffer)
    }
}

struct TrackInspectorTests {
    @Test func mapsVorbisAndITunesMetadata() {
        let flac = TrackTags(metadata: [
            .init(commonKey: "title", identifier: "vorb/TITLE", value: "Sine"),
            .init(commonKey: "artist", identifier: "vorb/ARTIST", value: "Band"),
            .init(commonKey: "albumName", identifier: "vorb/ALBUM", value: "Live"),
            .init(commonKey: nil, identifier: "vorb/ALBUMARTIST", value: "Various"),
            .init(commonKey: nil, identifier: "vorb/TRACKNUMBER", value: "3/12"),
            .init(commonKey: nil, identifier: "vorb/DISCNUMBER", value: "2"),
            .init(commonKey: "creationDate", identifier: "vorb/DATE", value: "2019-01-02"),
            .init(commonKey: nil, identifier: "vorb/GENRE", value: "Jazz"),
            .init(commonKey: "artwork", identifier: "vorb/METADATA_BLOCK_PICTURE", value: Data([1, 2])),
        ])
        #expect(flac == TrackTags(title: "Sine", artist: "Band", album: "Live", albumArtist: "Various", trackNumber: 3,
                                  discNumber: 2, year: "2019", genre: "Jazz", artwork: Data([1, 2])))
        let alac = TrackTags(metadata: [
            .init(commonKey: nil, identifier: "itsk/%A9nam", value: "Song"),
            .init(commonKey: nil, identifier: "itsk/trkn", value: Data([0, 0, 0, 7, 0, 9, 0, 0])),
            .init(commonKey: nil, identifier: "itsk/disk", value: Data([0, 0, 0, 1, 0, 2])),
            .init(commonKey: nil, identifier: "itsk/aART", value: "Orchestra"),
            .init(commonKey: nil, identifier: "itsk/%A9day", value: "2001"),
        ])
        #expect(alac == TrackTags(title: "Song", albumArtist: "Orchestra", trackNumber: 7, discNumber: 1, year: "2001"))
    }

    @Test func readsTheNativeResolutionOfLosslessFiles() async throws {
        let folder = try AudioFixture.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flac = folder.appendingPathComponent("a.flac")
        let wav = folder.appendingPathComponent("b.wav")
        let aiff = folder.appendingPathComponent("c.aiff")
        try AudioFixture.write(flac, format: kAudioFormatFLAC, rate: 96000)
        try AudioFixture.write(wav, format: kAudioFormatLinearPCM, rate: 192_000)
        try AudioFixture.write(aiff, format: kAudioFormatLinearPCM, rate: 44100, bits: 16)

        let first = try await TrackInspector.inspect(flac)
        #expect(first.format == TrackFormat(codec: "FLAC", sampleRate: 96000, bitDepth: 24, channels: 2))
        #expect(abs(first.duration - 0.1) < 0.01)
        #expect(try await TrackInspector.inspect(wav).format == TrackFormat(codec: "WAV", sampleRate: 192_000, bitDepth: 24, channels: 2))
        #expect(try await TrackInspector.inspect(aiff).format == TrackFormat(codec: "AIFF", sampleRate: 44100, bitDepth: 16, channels: 2))
    }

    @Test func refusesLossyAudio() async throws {
        let folder = try AudioFixture.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let aac = folder.appendingPathComponent("lossy.m4a")
        try AudioFixture.write(aac, format: kAudioFormatMPEG4AAC, rate: 44100)
        await #expect(throws: TrackInspectionError.lossy("AAC")) { try await TrackInspector.inspect(aac) }
        let mp3 = folder.appendingPathComponent("song.mp3")
        try Data("ID3".utf8).write(to: mp3)
        await #expect(throws: TrackInspectionError.lossy("MP3")) { try await TrackInspector.inspect(mp3) }
        #expect(TrackInspector.isAudioFile(mp3))
        #expect(!TrackInspector.isAudioFile(folder.appendingPathComponent("cover.jpg")))
    }

    @Test func readsDSDFormatAndTags() async throws {
        let tag = ID3Builder.tag(frames: [ID3Builder.frame("TIT2", ID3Builder.text("Night")), ID3Builder.frame("TRCK", ID3Builder.text("4"))])
        let block = [UInt8](repeating: 0x69, count: DSDBuilder.blockSize)
        let url = try DSDBuilder.write(DSDBuilder.dsf(channelBlocks: [block, block], sampleCount: 8 * 4096, rate: 5_644_800, tag: tag), ext: "dsf")
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try await TrackInspector.inspect(url)
        #expect(track.format == TrackFormat(codec: "DSF", sampleRate: 5_644_800, bitDepth: 1, channels: 2))
        #expect(track.tags.title == "Night" && track.tags.trackNumber == 4)
        #expect(abs(track.duration - 4096.0 * 8 / 5_644_800) < 0.0001)
    }
}
