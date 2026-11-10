import AppKit
import CoreAudio
import SwiftUI

struct IslandSpectrum {
    private(set) var levels = [Double](repeating: 0, count: 7)

    static func bands(_ samples: [Float], sampleRate: Double) -> [Double] {
        guard samples.count >= 1024, sampleRate.isFinite, sampleRate >= 24000 else { return Array(repeating: 0, count: 7) }
        let count = 1024
        var real = samples.suffix(count).enumerated().map { index, value in
            (value.isFinite ? Double(value) : 0) * (0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count - 1)))
        }
        var imaginary = [Double](repeating: 0, count: count)
        var reversed = 0
        for index in 1..<count {
            var bit = count >> 1
            while reversed & bit != 0 { reversed ^= bit; bit >>= 1 }
            reversed ^= bit
            if index < reversed { real.swapAt(index, reversed) }
        }
        var length = 2
        while length <= count {
            let angle = -2 * Double.pi / Double(length)
            for start in stride(from: 0, to: count, by: length) {
                for offset in 0..<(length / 2) {
                    let c = cos(angle * Double(offset))
                    let s = sin(angle * Double(offset))
                    let a = start + offset
                    let b = a + length / 2
                    let r = real[b] * c - imaginary[b] * s
                    let i = real[b] * s + imaginary[b] * c
                    real[b] = real[a] - r
                    imaginary[b] = imaginary[a] - i
                    real[a] += r
                    imaginary[a] += i
                }
            }
            length *= 2
        }
        return (0..<7).map { band in
            let low = 50 * pow(240, Double(band) / 7)
            let high = 50 * pow(240, Double(band + 1) / 7)
            let start = max(1, Int(ceil(low * Double(count) / sampleRate)))
            let end = min(count / 2, max(start + 1, Int(ceil(high * Double(count) / sampleRate))))
            let peak = (start..<end).map { hypot(real[$0], imaginary[$0]) * 4 / Double(count) }.max() ?? 0
            return min(1, max(0, (20 * log10(max(0.000001, peak)) + 60) / 60))
        }
    }

    mutating func update(_ bands: [Double]) {
        guard bands.count == 7 else { return }
        let peak = bands.filter(\.isFinite).max() ?? 0
        let gain = peak > 0 ? min(4, 0.92 / peak) : 1
        for index in 0..<7 {
            let value = bands[index].isFinite ? min(1, max(0, bands[index] * gain)) : 0
            levels[index] += (value - levels[index]) * (value > levels[index] ? 0.55 : 0.12)
        }
    }

    static func synthetic(time: Double, playing: Bool) -> [Double] {
        guard playing, time.isFinite else { return Array(repeating: 0, count: 7) }
        return (0..<7).map { index in
            let swing = 0.36 + Double(index % 4) * 0.08
            let wave = (1 - cos(time * .pi / swing + Double(index))) / 2
            let center = 1 - Double(abs(index - 3)) * 0.14
            return center * (0.15 + 0.85 * wave)
        }
    }

    static func height(_ level: Double, maximum: Double) -> Double { maximum * (0.1 + 0.9 * min(1, max(0, level.isFinite ? level : 0))) }
}

final class IslandSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = [Float](repeating: 0, count: 1024)
    private var cursor = 0
    func append(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard let first = buffers.first, let pointer = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        lock.lock()
        defer { lock.unlock() }
        for frame in max(0, frames - 1024)..<frames {
            var value: Float = 0
            if channels > 1 { for channel in 0..<channels { value += pointer[frame * channels + channel] / Float(channels) } }
            else {
                value = pointer[frame]
                if buffers.count > 1, let second = buffers[1].mData?.assumingMemoryBound(to: Float.self), Int(buffers[1].mDataByteSize) >= (frame + 1) * MemoryLayout<Float>.size { value = (value + second[frame]) / 2 }
            }
            samples[cursor] = value
            cursor = (cursor + 1) % 1024
        }
    }
    func latest() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return Array(samples[cursor...] + samples[..<cursor])
    }
}

@available(macOS 14.4, *)
final class IslandAudioTap {
    let buffer = IslandSampleBuffer()
    let objects: [AudioObjectID]
    let output: String
    private(set) var sampleRate = 48000.0
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    init(objects: [AudioObjectID], output: String) { self.objects = objects; self.output = output }
    func start() throws {
        guard !objects.isEmpty else { throw MixerError.unavailable }
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.uuid = UUID()
        description.name = "MacKit Island Bars"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw MixerError.tap(tapStatus) }
        guard let format = AudioProperty.get(tap, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self),
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { stop(); throw MixerError.unavailable }
        sampleRate = format.mSampleRate
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacKit Island Bars",
            kAudioAggregateDeviceUIDKey: "MacKit.Island.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]]
        ]
        let status = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregate)
        guard status == noErr else { stop(); throw MixerError.aggregate(status) }
        let buffer = buffer
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, DispatchQueue(label: "mackit.island.audio")) { _, input, _, output, _ in
            buffer.append(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
            for item in UnsafeMutableAudioBufferListPointer(output) { if let data = item.mData { memset(data, 0, Int(item.mDataByteSize)) } }
        }
        guard created == noErr, let proc else { stop(); throw MixerError.start(created) }
        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else { stop(); throw MixerError.start(started) }
    }
    func stop() {
        if let proc { AudioDeviceStop(aggregate, proc); AudioDeviceDestroyIOProcID(aggregate, proc) }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = kAudioObjectUnknown
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = kAudioObjectUnknown
    }
    deinit { stop() }
}

@MainActor
final class IslandBarsController: ObservableObject {
    @Published private(set) var levels = [Double](repeating: 0, count: 7)
    private var engine: AnyObject?
    private var timer: Timer?
    private var spectrum = IslandSpectrum()
    private var playerPID: pid_t?
    private var song: IslandSong?
    private var started = Date.distantPast
    private var paused: Date?
    private var lastProcessCheck = Date.distantPast
    private var failed = false
    private var receivedSignal = false
    private var playing = false
    var mayRequestAccess = false

    func update(enabled: Bool, playing: Bool, song: IslandSong?, pid: pid_t?) {
        guard #available(macOS 14.4, *), enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { stop(); return }
        if song != self.song || pid != playerPID {
            stop()
            self.song = song
            playerPID = pid
            failed = false
            receivedSignal = false
            started = Date()
        }
        self.playing = playing
        if !playing {
            if paused == nil { paused = Date() }
            if Date().timeIntervalSince(paused!) >= 1.5 { stop() }
            levels = Array(repeating: 0, count: 7)
            return
        }
        paused = nil
        let outputID = SoundHardware.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let output = outputID.flatMap { AudioProperty.string($0, kAudioDevicePropertyDeviceUID) }
        if let current = engine as? IslandAudioTap, current.output != output { current.stop(); engine = nil; failed = false; started = Date(); receivedSignal = false }
        if !failed, mayRequestAccess, let pid, let output, engine == nil || Date().timeIntervalSince(lastProcessCheck) >= 1 {
            lastProcessCheck = Date()
            let processes = AudioProcesses.list().filter { $0.pid == pid || AudioProcesses.owner(of: $0.pid)?.processIdentifier == pid }.map(\.object).sorted()
            if let current = engine as? IslandAudioTap, current.objects != processes { current.stop(); engine = nil }
            if engine == nil && !processes.isEmpty {
                let tap = IslandAudioTap(objects: processes, output: output)
                do { try tap.start(); engine = tap; started = Date() }
                catch { failed = true }
            }
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.frame() } }
    }

    private func frame() {
        guard playing else { return }
        if #available(macOS 14.4, *), let tap = engine as? IslandAudioTap {
            let samples = tap.buffer.latest()
            if samples.contains(where: { abs($0) > 0.001 }) { receivedSignal = true }
            if receivedSignal {
                spectrum.update(IslandSpectrum.bands(samples, sampleRate: tap.sampleRate))
                levels = spectrum.levels
                return
            }
            if Date().timeIntervalSince(started) >= 8 { tap.stop(); engine = nil; failed = true }
        }
        levels = IslandSpectrum.synthetic(time: ProcessInfo.processInfo.systemUptime, playing: playing)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if #available(macOS 14.4, *) { (engine as? IslandAudioTap)?.stop() }
        engine = nil
        playing = false
        levels = Array(repeating: 0, count: 7)
    }
}

struct IslandBarsView: View {
    @ObservedObject var bars: IslandBarsController
    var count = 7
    var height = 18.0
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(.white).frame(width: 3, height: IslandSpectrum.height(bars.levels[index * 7 / count], maximum: height))
            }
        }.frame(height: height).accessibilityLabel("Music activity")
    }
}
