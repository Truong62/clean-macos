import CoreAudio
import Foundation
import Testing
@testable import CleanMacOS

struct MixerMathTests {
    @Test func turnsTheSliderIntoAGain() {
        #expect(MixerGain.amplitude(for: 0) == 0)
        #expect(MixerGain.amplitude(for: 0.5) == 0.25)
        #expect(MixerGain.amplitude(for: 1) == 1)
        #expect(MixerGain.amplitude(for: 2) == 2)
        #expect(MixerGain.amplitude(for: 3) == 2)
    }

    @Test func limitsBoostsWithoutClipping() {
        var limiter = BoostLimiter()
        let loud = limiter.next(peak: 2, desired: 2, frames: 512, sampleRate: 48000)
        #expect(loud.start == loud.end)
        #expect(abs(loud.end * 2 - BoostLimiter.ceiling) < 0.0001)
        var quiet = BoostLimiter()
        var gains: [Float] = []
        for _ in 0..<200 { gains.append(quiet.next(peak: 0.1, desired: 2, frames: 512, sampleRate: 48000).end) }
        #expect(gains.first! > 1 && gains.first! < 1.2)
        #expect(gains == gains.sorted())
        #expect(abs(gains.last! - 2) < 0.01)
        let capped = quiet.next(peak: 0.9, desired: 2, frames: 512, sampleRate: 48000)
        #expect(capped.start * 0.9 <= BoostLimiter.ceiling + 0.0001 && capped.end * 0.9 <= BoostLimiter.ceiling + 0.0001)
    }

    private func buffers(_ layout: [Int], frames: Int, fill: (Int, Int) -> Float) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: layout.count)
        for (index, channels) in layout.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
            for frame in 0..<frames {
                for channel in 0..<channels { data[frame * channels + channel] = fill(index, channel) }
            }
            list[index] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4), mData: data)
        }
        return list
    }

    private func samples(_ list: UnsafeMutableAudioBufferListPointer) -> [[Float]] {
        list.map { buffer in
            let pointer = buffer.mData!.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.mDataByteSize) / 4))
        }
    }

    @Test func mapsStereoMonoAndExtraChannels() {
        let stereo = buffers([1, 1], frames: 2) { buffer, _ in buffer == 0 ? 0.5 : -0.5 }
        let out = buffers([1, 1, 1], frames: 2) { _, _ in 9 }
        MixerRender.copy(from: stereo, to: out, start: 1, end: 1)
        #expect(samples(out) == [[0.5, 0.5], [-0.5, -0.5], [0, 0]])

        let mono = buffers([1], frames: 2) { _, _ in 0.25 }
        let interleaved = buffers([2], frames: 2) { _, _ in 9 }
        MixerRender.copy(from: mono, to: interleaved, start: 2, end: 2)
        #expect(samples(interleaved) == [[0.5, 0.5, 0.5, 0.5]])

        let folded = buffers([1], frames: 2) { _, _ in 9 }
        MixerRender.copy(from: stereo, to: folded, start: 1, end: 1)
        #expect(samples(folded) == [[0, 0]])

        let silent = buffers([1, 1], frames: 2) { _, _ in 9 }
        MixerRender.copy(from: buffers([0], frames: 0) { _, _ in 0 }, to: silent, start: 1, end: 1)
        #expect(samples(silent) == [[0, 0], [0, 0]])
    }

    @Test func rampsTheGainAcrossTheBlock() {
        let input = buffers([1], frames: 4) { _, _ in 1 }
        let out = buffers([1], frames: 4) { _, _ in 0 }
        MixerRender.copy(from: input, to: out, start: 0, end: 1)
        #expect(samples(out) == [[0, 0.25, 0.5, 0.75]])
        #expect(MixerRender.peak(of: buffers([1, 1], frames: 2) { buffer, _ in buffer == 0 ? 0.3 : -0.8 }) == 0.8)
    }

    @Test func neverTapsAppsThatBreak() {
        #expect(AudioAppPolicy.canTap("com.apple.Safari"))
        #expect(!AudioAppPolicy.canTap("us.zoom.xos"))
        #expect(!AudioAppPolicy.canTap("com.apple.logic10"))
        #expect(!AudioAppPolicy.canTap(nil))
    }
}
