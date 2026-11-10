import Foundation
import Testing
@testable import CleanMacOS

extension Track {
    static func sample(_ id: String, title: String? = nil, artist: String = "Artist", album: String = "Album",
                       track: Int? = nil, disc: Int? = nil,
                       format: TrackFormat = TrackFormat(codec: "FLAC", sampleRate: 96000, bitDepth: 24, channels: 2)) -> Track {
        Track(id: id, title: title ?? id, artist: artist, album: album, albumArtist: artist, trackNumber: track, discNumber: disc,
              duration: 180, format: format, fileSize: 1_000, addedAt: Date(timeIntervalSince1970: 0))
    }
}

struct PlaybackQueueTests {
    private let songs = (0..<5).map { Track.sample("t\($0)") }
    private let reversed: ([Int]) -> [Int] = { $0.reversed() }

    private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.id) }

    @Test func startsAtTheChosenTrackAndStopsAfterTheLast() {
        var queue = PlaybackQueue(tracks: Array(songs.prefix(3)), startAt: 1)
        #expect(queue.current?.id == "t1")
        #expect(queue.advance(automatic: true)?.id == "t2")
        #expect(queue.advance(automatic: true) == nil)
        #expect(queue.current?.id == "t2")
    }

    @Test func repeatAllWrapsAndRepeatOneOnlyRepeatsWhenATrackEnds() {
        var queue = PlaybackQueue(tracks: Array(songs.prefix(2)), startAt: 1)
        queue.repeatMode = .all
        #expect(queue.advance(automatic: true)?.id == "t0")
        queue.repeatMode = .one
        #expect(queue.advance(automatic: true)?.id == "t0")
        #expect(queue.advance(automatic: false)?.id == "t1")
        #expect(queue.peekNext()?.id == "t1")
    }

    @Test func shuffleKeepsTheCurrentTrackAndTurningItOffRestoresTheOrder() {
        var queue = PlaybackQueue(tracks: songs, startAt: 2, shuffled: true, shuffle: reversed)
        #expect(queue.current?.id == "t2")
        #expect(ids(queue.upcoming) == ["t4", "t3", "t1", "t0"])
        queue.setShuffled(false)
        #expect(queue.current?.id == "t2")
        #expect(ids(queue.upcoming) == ["t3", "t4"])
        queue.setShuffled(true, shuffle: reversed)
        #expect(ids(queue.upcoming) == ["t4", "t3", "t1", "t0"])
    }

    @Test func playNextInsertsAfterTheCurrentTrackAndAddGoesLast() {
        var queue = PlaybackQueue(tracks: Array(songs.prefix(3)), startAt: 0)
        queue.playNext([Track.sample("x")])
        queue.append([Track.sample("y")])
        #expect(ids(queue.upcoming) == ["x", "t1", "t2", "y"])
        queue.removeUpcoming(at: 1)
        #expect(ids(queue.upcoming) == ["x", "t2", "y"])
        #expect(queue.jump(toUpcoming: 1)?.id == "t2")
        #expect(ids(queue.upcoming) == ["y"])
    }

    @Test func addingToAnEmptyQueueStartsIt() {
        var queue = PlaybackQueue()
        #expect(queue.current == nil)
        queue.append([Track.sample("a"), Track.sample("b")])
        #expect(queue.current?.id == "a")
        #expect(ids(queue.upcoming) == ["b"])
    }

    @Test func goingBackStopsAtTheFirstTrackUnlessRepeatAll() {
        var queue = PlaybackQueue(tracks: Array(songs.prefix(3)), startAt: 0)
        #expect(queue.retreat()?.id == "t0")
        queue.repeatMode = .all
        #expect(queue.retreat()?.id == "t2")
        #expect(queue.retreat()?.id == "t1")
    }
}

struct TrackFormatTests {
    @Test func hiResMeansMoreThanCDQuality() {
        #expect(TrackFormat(codec: "FLAC", sampleRate: 44100, bitDepth: 24, channels: 2).isHiRes)
        #expect(TrackFormat(codec: "WAV", sampleRate: 96000, bitDepth: 16, channels: 2).isHiRes)
        #expect(TrackFormat(codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2).isHiRes)
        #expect(!TrackFormat(codec: "FLAC", sampleRate: 44100, bitDepth: 16, channels: 2).isHiRes)
        #expect(!TrackFormat(codec: "ALAC", sampleRate: 48000, bitDepth: 16, channels: 2).isHiRes)
    }

    @Test func describesTheResolution() {
        #expect(TrackFormat(codec: "FLAC", sampleRate: 192000, bitDepth: 24, channels: 2).resolution == "24-bit / 192 kHz")
        #expect(TrackFormat(codec: "FLAC", sampleRate: 44100, bitDepth: 16, channels: 2).resolution == "16-bit / 44.1 kHz")
        #expect(TrackFormat(codec: "WAV", sampleRate: 352800, bitDepth: 32, channels: 2).resolution == "32-bit / 352.8 kHz")
        #expect(TrackFormat(codec: "DSF", sampleRate: 5_644_800, bitDepth: 1, channels: 2).resolution == "DSD128 / 5.6 MHz")
    }
}

struct EmptyQueueTests {
    @Test func anEmptyQueueRemembersShuffleForTheNextTracks() {
        var queue = PlaybackQueue(tracks: [], startAt: 0, shuffled: true)
        #expect(queue.isShuffled)
        queue.append([Track.sample("a")])
        #expect(queue.current?.id == "a")
    }
}

struct OutputQualityTests {
    private let hiRes = TrackFormat(codec: "FLAC", sampleRate: 192_000, bitDepth: 24, channels: 2)

    private func status(rate: Double, bits: Int = 24, float: Bool = false, bluetooth: Bool = false, stream: Double,
                        kind: StreamKind = .pcm) -> OutputStatus {
        OutputStatus(deviceName: "DAC", deviceUID: "dac", device: DeviceFormat(sampleRate: rate, bitDepth: bits, isFloat: float),
                     isBluetooth: bluetooth, streamRate: stream, kind: kind)
    }

    @Test func isBitPerfectWhenRateAndDepthMatchAtFullVolume() {
        #expect(OutputQuality.evaluate(track: hiRes, status: status(rate: 192_000, stream: 192_000), volume: 1).level == .bitPerfect)
        #expect(OutputQuality.evaluate(track: hiRes, status: status(rate: 192_000, bits: 32, float: true, stream: 192_000), volume: 1).title == "Bit-perfect")
    }

    @Test func namesWhatBreaksBitPerfectPlayback() {
        let resampled = OutputQuality.evaluate(track: hiRes, status: status(rate: 96000, stream: 192_000), volume: 1)
        #expect(resampled.level == .degraded && resampled.title == "Resampled to 96 kHz")
        #expect(OutputQuality.evaluate(track: hiRes, status: status(rate: 192_000, bits: 16, stream: 192_000), volume: 1).title == "Reduced to 16-bit")
        #expect(OutputQuality.evaluate(track: hiRes, status: status(rate: 192_000, stream: 192_000), volume: 0.5).title == "Volume 50%")
        #expect(OutputQuality.evaluate(track: hiRes, status: status(rate: 44100, bluetooth: true, stream: 192_000), volume: 1).title == "Bluetooth")
    }

    @Test func describesDSDOutput() {
        let dsd = TrackFormat(codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)
        let native = OutputQuality.evaluate(track: dsd, status: status(rate: 176_400, stream: 176_400, kind: .dop), volume: 0.4)
        #expect(native.level == .bitPerfect && native.title == "Native DSD (DoP)")
        let converted = OutputQuality.evaluate(track: dsd, status: status(rate: 88200, stream: 88200, kind: .dsdToPCM), volume: 1)
        #expect(converted.level == .altered && converted.title == "DSD → PCM 88.2 kHz")
    }
}
