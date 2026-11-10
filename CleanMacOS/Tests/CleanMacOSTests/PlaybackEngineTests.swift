import AVFoundation
import Foundation
import Testing
@testable import CleanMacOS

struct PlaybackGraphTests {
    private let frames: AVAudioFrameCount = 4096

    private func render(volume: Float) throws -> (input: [Float], output: [Float]) {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 96000, channels: 2))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frames)
        let player = PlaybackEngine.attachPlayer(to: engine, format: format)
        engine.mainMixerNode.outputVolume = volume
        try engine.start()
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        input.frameLength = frames
        var generator = SystemRandomNumberGenerator()
        for channel in 0..<2 {
            for frame in 0..<Int(frames) {
                input.floatChannelData![channel][frame] = Float(Int32.random(in: -8_388_608...8_388_607, using: &generator)) / 8_388_608
            }
        }
        player.scheduleBuffer(input)
        player.play()
        let output = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames))
        #expect(try engine.renderOffline(frames, to: output) == .success)
        let read = { (buffer: AVAudioPCMBuffer) in (0..<2).flatMap { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) } }
        return (read(input), read(output))
    }

    @Test func theOutputGraphKeepsEvery24BitSampleAtFullVolume() throws {
        let result = try render(volume: 1)
        #expect(result.output == result.input)
    }

    @Test func lowerVolumeChangesTheSamples() throws {
        let result = try render(volume: 0.5)
        #expect(result.output != result.input)
    }
}

struct DSDSourceTests {
    @Test func streamsDSDAsPCMOrDoPFramesAndSeeks() throws {
        let block = [UInt8](repeating: 0x69, count: DSDBuilder.blockSize)
        let url = try DSDBuilder.write(DSDBuilder.dsf(channelBlocks: [block + block, block + block], sampleCount: 8 * 8192), ext: "dsf")
        defer { try? FileManager.default.removeItem(at: url) }

        let pcm = try DSDSource(url: url, output: .pcm(rate: 88200))
        #expect(pcm.format.sampleRate == 88200 && pcm.length == 2048)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: 1500))
        try pcm.read(into: buffer)
        #expect(buffer.frameLength == 1500)
        try pcm.seek(to: 2000)
        try pcm.read(into: buffer)
        #expect(buffer.frameLength == 48)

        let dop = try DSDSource(url: url, output: .dop(rate: 176_400))
        #expect(dop.length == 4096)
        let dopBuffer = try #require(AVAudioPCMBuffer(pcmFormat: dop.format, frameCapacity: 2))
        try dop.read(into: dopBuffer)
        #expect(Int32(dopBuffer.floatChannelData![0][0] * 8_388_608) == 0x05_9696)
    }
}
