import CoreAudio
import Foundation

enum MixerGain {
    static let maximum = 2.0

    static func amplitude(for level: Double) -> Float {
        let clamped = min(max(level, 0), maximum)
        return Float(clamped <= 1 ? clamped * clamped : clamped)
    }
}

struct BoostLimiter {
    static let ceiling: Float = 0.944
    static let release: Double = 0.16

    private(set) var gain: Float = 1

    mutating func next(peak: Float, desired: Float, frames: Int, sampleRate: Double) -> (start: Float, end: Float) {
        let safe = peak > 0 ? min(desired, Self.ceiling / peak) : desired
        let start = gain
        guard safe > gain else {
            gain = safe
            return (safe, safe)
        }
        gain += (safe - gain) * Float(1 - exp(-Double(frames) / sampleRate / Self.release))
        return (start, gain)
    }
}

enum MixerRender {
    struct Channel {
        let pointer: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    static func channels(of list: UnsafeMutableAudioBufferListPointer) -> [Channel] {
        list.flatMap { buffer -> [Channel] in
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { return [] }
            let count = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count)
            return (0..<count).map { Channel(pointer: data + $0, stride: count, frames: frames) }
        }
    }

    static func peak(of list: UnsafeMutableAudioBufferListPointer) -> Float {
        channels(of: list).reduce(Float(0)) { loudest, channel in
            (0..<channel.frames).reduce(loudest) { max($0, abs(channel.pointer[$1 * channel.stride])) }
        }
    }

    static func copy(from input: UnsafeMutableAudioBufferListPointer, to output: UnsafeMutableAudioBufferListPointer, start: Float, end: Float) {
        let sources = channels(of: input)
        let targets = channels(of: output)
        for (index, target) in targets.enumerated() {
            let step = target.frames > 0 ? (end - start) / Float(target.frames) : 0
            for frame in 0..<target.frames {
                target.pointer[frame * target.stride] = sample(sources, channel: index, outputs: targets.count, frame: frame) * (start + step * Float(frame))
            }
        }
    }

    private static func sample(_ sources: [Channel], channel: Int, outputs: Int, frame: Int) -> Float {
        func value(_ source: Channel) -> Float { frame < source.frames ? source.pointer[frame * source.stride] : 0 }
        switch sources.count {
        case 0:
            return 0
        case 1:
            return channel < 2 ? value(sources[0]) : 0
        default:
            if outputs == 1 { return (value(sources[0]) + value(sources[1])) / 2 }
            return channel < 2 ? value(sources[channel]) : 0
        }
    }
}

enum AudioAppPolicy {
    static let neverTapped: Set<String> = [
        "us.zoom.xos", "com.apple.logic10", "com.apple.mainstage3", "com.apple.GarageBand10", "com.ableton.live", "com.bitwig.BitwigStudio",
        "com.image-line.flstudio", "com.avid.ProTools", "com.presonus.studioone6", "com.cockos.reaper", "com.hnc.Discord", "com.microsoft.teams2",
        "com.microsoft.teams",
    ]

    static func canTap(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return !neverTapped.contains(bundleID)
    }
}
