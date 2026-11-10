import AVFoundation
import Foundation

protocol PCMSource: AnyObject {
    var format: AVAudioFormat { get }
    var length: AVAudioFramePosition { get }
    func read(into buffer: AVAudioPCMBuffer) throws
    func seek(to frame: AVAudioFramePosition) throws
}

enum AudioSourceError: LocalizedError {
    case unsupportedLayout

    var errorDescription: String? { "This file uses a channel layout the player cannot open." }
}

final class PCMFileSource: PCMSource {
    private let file: AVAudioFile

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
    }

    var format: AVAudioFormat { file.processingFormat }
    var length: AVAudioFramePosition { file.length }

    func read(into buffer: AVAudioPCMBuffer) throws {
        buffer.frameLength = 0
        let remaining = file.length - file.framePosition
        guard remaining > 0 else { return }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining)))
    }

    func seek(to frame: AVAudioFramePosition) throws {
        file.framePosition = min(max(0, frame), file.length)
    }
}

final class DSDSource: PCMSource {
    let format: AVAudioFormat
    let length: AVAudioFramePosition
    private let reader: DSDReader
    private let bytesPerFrame: Int
    private let decimator: DSDDecimator?
    private var encoder: DoPEncoder?

    init(url: URL, output: DSDOutput) throws {
        reader = try DSDReader(url: url)
        let channels = reader.info.channels
        let rate: Double
        switch output {
        case .dop(let dopRate):
            rate = dopRate
            decimator = nil
            encoder = DoPEncoder()
            bytesPerFrame = 2
        case .pcm(let pcmRate):
            rate = pcmRate
            let decimator = DSDDecimator(dsdRate: reader.info.sampleRate, outputRate: Int(pcmRate), channels: channels)
            self.decimator = decimator
            encoder = nil
            bytesPerFrame = decimator.bytesPerOutput
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) else {
            throw AudioSourceError.unsupportedLayout
        }
        self.format = format
        length = reader.info.bytesPerChannel / Int64(bytesPerFrame)
    }

    func read(into buffer: AVAudioPCMBuffer) throws {
        buffer.frameLength = 0
        let bytes = try reader.read(maxBytes: Int(buffer.frameCapacity) * bytesPerFrame)
        guard let count = bytes.first?.count, count > 0, let channels = buffer.floatChannelData else { return }
        let padding = (bytesPerFrame - count % bytesPerFrame) % bytesPerFrame
        let aligned = padding == 0 ? bytes : bytes.map { $0 + [UInt8](repeating: DSDFile.silence, count: padding) }
        let samples = encoder?.encode(aligned) ?? decimator?.process(aligned) ?? []
        let frames = min(samples.first?.count ?? 0, Int(buffer.frameCapacity))
        for (channel, values) in samples.enumerated() where channel < Int(format.channelCount) {
            values.withUnsafeBufferPointer { channels[channel].update(from: $0.baseAddress!, count: frames) }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
    }

    func seek(to frame: AVAudioFramePosition) throws {
        try reader.seek(toByte: frame * Int64(bytesPerFrame))
        decimator?.reset()
    }
}
