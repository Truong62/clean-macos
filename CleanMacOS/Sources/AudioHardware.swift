import CoreAudio
import Foundation

enum DSDOutput: Equatable, Sendable {
    case dop(rate: Double)
    case pcm(rate: Double)
}

enum SampleRatePlan {
    static let standardRates: [Double] = [44100, 48000, 88200, 96000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000]
    static let lowestMusicRate = 44100.0
    static let dopDivisor = 16.0
    static let dsdToPCMRates: [Double] = [176_400, 88200, 352_800, 44100]
    static let dsdToPCMFallback = 88200.0

    static func deviceRate(for source: Double, supported: [Double]) -> Double {
        let music = supported.filter { $0 >= lowestMusicRate }
        let usable = music.isEmpty ? supported : music
        guard !usable.isEmpty else { return source }
        if usable.contains(source) { return source }
        let family = usable.filter { isSameFamily($0, source) }
        if let lower = family.filter({ $0 < source }).max() { return lower }
        if let higher = family.filter({ $0 > source }).min() { return higher }
        return usable.filter { $0 > source }.min() ?? usable.max() ?? source
    }

    static func dsdOutput(dsdRate: Double, supported: [Double], allowDoP: Bool) -> DSDOutput {
        let dopRate = dsdRate / dopDivisor
        if allowDoP, supported.contains(dopRate) { return .dop(rate: dopRate) }
        let rate = dsdToPCMRates.first { supported.contains($0) && $0 <= dsdRate / 8 } ?? dsdToPCMFallback
        return .pcm(rate: rate)
    }

    static func rates(from ranges: [AudioValueRange]) -> [Double] {
        let values = ranges.flatMap { range in
            range.mMinimum == range.mMaximum ? [range.mMinimum] : standardRates.filter { $0 >= range.mMinimum && $0 <= range.mMaximum }
        }
        return Array(Set(values)).sorted()
    }

    static func physicalFormat(from available: [AudioStreamRangedDescription], sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription? {
        let candidates = available.filter { option in
            option.mFormat.mFormatID == kAudioFormatLinearPCM && option.mFormat.mChannelsPerFrame == channels
                && option.mFormat.mFormatFlags & kAudioFormatFlagIsNonMixable == 0
                && option.mSampleRateRange.mMinimum <= sampleRate && sampleRate <= option.mSampleRateRange.mMaximum
        }
        let best = candidates.max { rank($0.mFormat) < rank($1.mFormat) }
        return best.map { option in
            var format = option.mFormat
            format.mSampleRate = sampleRate
            return format
        }
    }

    private static func rank(_ format: AudioStreamBasicDescription) -> (UInt32, Int) {
        (format.mBitsPerChannel, format.mFormatFlags & kAudioFormatFlagIsFloat == 0 ? 1 : 0)
    }

    private static func isSameFamily(_ lhs: Double, _ rhs: Double) -> Bool {
        (Int(lhs) % 11025 == 0) == (Int(rhs) % 11025 == 0)
    }
}

struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let sampleRates: [Double]

    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }

    var canCarryDoP: Bool {
        [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI]
            .contains(transport)
    }
}

struct DeviceFormat: Equatable, Sendable {
    let sampleRate: Double
    let bitDepth: Int
    let isFloat: Bool
}

enum AudioHardware {
    static let settleTimeout: TimeInterval = 2
    static let settlePoll: TimeInterval = 0.02
    private static let lock = NSLock()
    nonisolated(unsafe) private static var originalFormats: [AudioDeviceID: AudioStreamBasicDescription] = [:]

    static func outputDevices() -> [AudioOutputDevice] {
        values(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, as: AudioDeviceID.self)
            .compactMap(device)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        values(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioDeviceID.self).first
    }

    static func device(_ id: AudioDeviceID) -> AudioOutputDevice? {
        guard let stream = outputStream(id), stream != 0 else { return nil }
        let ranges = values(id, kAudioDevicePropertyAvailableNominalSampleRates, as: AudioValueRange.self)
        return AudioOutputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                                 name: string(id, kAudioObjectPropertyName) ?? "Output \(id)",
                                 transport: values(id, kAudioDevicePropertyTransportType, as: UInt32.self).first ?? 0,
                                 sampleRates: SampleRatePlan.rates(from: ranges))
    }

    static func currentFormat(_ id: AudioDeviceID) -> DeviceFormat? {
        guard let rate = values(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self).first else { return nil }
        let physical = outputStream(id).flatMap { values($0, kAudioStreamPropertyPhysicalFormat, as: AudioStreamBasicDescription.self).first }
        return DeviceFormat(sampleRate: rate, bitDepth: Int(physical?.mBitsPerChannel ?? 0),
                            isFloat: (physical?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0)
    }

    @discardableResult
    static func setFormat(_ id: AudioDeviceID, sampleRate: Double) -> DeviceFormat? {
        if let stream = outputStream(id), var physical = values(stream, kAudioStreamPropertyPhysicalFormat, as: AudioStreamBasicDescription.self).first {
            rememberOriginal(id, physical)
            let available = values(stream, kAudioStreamPropertyAvailablePhysicalFormats, as: AudioStreamRangedDescription.self)
            if var best = SampleRatePlan.physicalFormat(from: available, sampleRate: sampleRate, channels: physical.mChannelsPerFrame),
               !sameFormat(best, physical) {
                set(stream, kAudioStreamPropertyPhysicalFormat, &best)
                physical = best
            }
        }
        if currentFormat(id)?.sampleRate != sampleRate {
            var rate = Float64(sampleRate)
            set(id, kAudioDevicePropertyNominalSampleRate, &rate)
        }
        let deadline = Date().addingTimeInterval(settleTimeout)
        while currentFormat(id)?.sampleRate != sampleRate, Date() < deadline { Thread.sleep(forTimeInterval: settlePoll) }
        return currentFormat(id)
    }

    static func restoreChangedDevices() {
        lock.lock()
        let changed = originalFormats
        originalFormats = [:]
        lock.unlock()
        for (id, format) in changed {
            guard let stream = outputStream(id) else { continue }
            var original = format
            set(stream, kAudioStreamPropertyPhysicalFormat, &original)
        }
    }

    static func listen(to selector: AudioObjectPropertySelector, on object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
                       queue: DispatchQueue, _ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(object, &address, queue) { _, _ in handler() }
    }

    private static func rememberOriginal(_ id: AudioDeviceID, _ format: AudioStreamBasicDescription) {
        lock.lock()
        defer { lock.unlock() }
        if originalFormats[id] == nil { originalFormats[id] = format }
    }

    private static func sameFormat(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate && lhs.mBitsPerChannel == rhs.mBitsPerChannel && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
    }

    private static func outputStream(_ id: AudioDeviceID) -> AudioStreamID? {
        values(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, as: AudioStreamID.self).first
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func values<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: T.Type) -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return [] }
        return (0..<count).map { buffer.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) }
    }

    @discardableResult
    private static func set<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return withUnsafeMutablePointer(to: &value) { AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) } == noErr
    }
}
