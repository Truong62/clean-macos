import CoreAudio
import Foundation
import Testing
@testable import CleanMacOS

struct AudioOutputPlanTests {
    private let speakers: [Double] = [44100, 48000, 88200, 96000]
    private let dac: [Double] = [44100, 48000, 88200, 96000, 176_400, 192_000, 352_800, 384_000]

    @Test func playsAtTheFileRateWhenTheDeviceHasIt() {
        #expect(SampleRatePlan.deviceRate(for: 96000, supported: speakers) == 96000)
        #expect(SampleRatePlan.deviceRate(for: 352_800, supported: dac) == 352_800)
    }

    @Test func fallsBackToTheClosestRateOfTheSameFamily() {
        #expect(SampleRatePlan.deviceRate(for: 192_000, supported: speakers) == 96000)
        #expect(SampleRatePlan.deviceRate(for: 352_800, supported: speakers) == 88200)
        #expect(SampleRatePlan.deviceRate(for: 44100, supported: [48000, 88200, 96000]) == 88200)
        #expect(SampleRatePlan.deviceRate(for: 96000, supported: [16000, 44100]) == 44100)
        #expect(SampleRatePlan.deviceRate(for: 44100, supported: [48000]) == 48000)
    }

    @Test func sendsDSDAsDoPOnlyWhenAllowedAndSupported() {
        #expect(SampleRatePlan.dsdOutput(dsdRate: 2_822_400, supported: dac, allowDoP: true) == .dop(rate: 176_400))
        #expect(SampleRatePlan.dsdOutput(dsdRate: 5_644_800, supported: dac, allowDoP: true) == .dop(rate: 352_800))
        #expect(SampleRatePlan.dsdOutput(dsdRate: 11_289_600, supported: dac, allowDoP: true) == .pcm(rate: 176_400))
        #expect(SampleRatePlan.dsdOutput(dsdRate: 2_822_400, supported: dac, allowDoP: false) == .pcm(rate: 176_400))
        #expect(SampleRatePlan.dsdOutput(dsdRate: 2_822_400, supported: speakers, allowDoP: true) == .pcm(rate: 88200))
        #expect(SampleRatePlan.dsdOutput(dsdRate: 2_822_400, supported: [48000], allowDoP: false) == .pcm(rate: 88200))
    }

    @Test func expandsContinuousRateRangesToStandardRates() {
        let ranges = [AudioValueRange(mMinimum: 8000, mMaximum: 96000), AudioValueRange(mMinimum: 192_000, mMaximum: 192_000)]
        #expect(SampleRatePlan.rates(from: ranges) == [44100, 48000, 88200, 96000, 192_000])
    }

    @Test func picksTheDeepestMixablePhysicalFormatAtTheRate() {
        func format(_ bits: UInt32, _ low: Double, _ high: Double, flags: AudioFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                    channels: UInt32 = 2) -> AudioStreamRangedDescription {
            AudioStreamRangedDescription(
                mFormat: AudioStreamBasicDescription(mSampleRate: low, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                                     mBytesPerPacket: bits / 8 * channels, mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * channels,
                                                     mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0),
                mSampleRateRange: AudioValueRange(mMinimum: low, mMaximum: high))
        }
        let available = [
            format(16, 44100, 192_000), format(24, 44100, 192_000), format(32, 44100, 96000),
            format(32, 44100, 192_000, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonMixable),
            format(32, 192_000, 192_000, channels: 8),
        ]
        let chosen = SampleRatePlan.physicalFormat(from: available, sampleRate: 192_000, channels: 2)
        #expect(chosen?.mBitsPerChannel == 24 && chosen?.mSampleRate == 192_000)
        #expect(SampleRatePlan.physicalFormat(from: available, sampleRate: 96000, channels: 2)?.mBitsPerChannel == 32)
        #expect(SampleRatePlan.physicalFormat(from: available, sampleRate: 384_000, channels: 2) == nil)
    }
}
