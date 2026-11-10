import AVFoundation
import CoreAudio

struct RecordingAudioChoice {
    var trusted = false
    var lastTapSound: Double?
    var lastTapBuffer: Double?
    var missedSince: Double?
    var failed = false

    mutating func tap(time: Double, audible: Bool) {
        lastTapBuffer = time
        if audible { trusted = true; failed = false; lastTapSound = time; missedSince = nil }
    }

    mutating func stream(time: Double, audible: Bool, appOnly: Bool) -> Bool {
        guard trusted, !failed, let lastTapBuffer, time - lastTapBuffer < 0.5 else { return false }
        if audible, time - (lastTapSound ?? -.infinity) > 0.1 {
            if missedSince == nil { missedSince = time }
            if time - (missedSince ?? time) >= (appOnly ? 0.5 : 0.1) { failed = true; return false }
        } else { missedSince = nil }
        return true
    }
}

@available(macOS 14.4, *)
final class RecordingAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "mackit.recording.tap", qos: .userInteractive)
    private let consume: @Sendable (CMSampleBuffer) -> Void
    private var format: CMAudioFormatDescription?
    private let gain = RenderState()

    init(consume: @escaping @Sendable (CMSampleBuffer) -> Void) { self.consume = consume }

    func start(processes: [AudioObjectID], excluding: Bool, outputUID: String, outputChannels: Int) throws {
        let description = excluding ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes) : CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "MacKit Recording"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        let result = AudioHardwareCreateProcessTap(description, &tapID)
        guard result == noErr else { throw MixerError.tap(result) }
        guard var asbd = AudioProperty.get(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self),
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else { stop(); throw MixerError.unavailable }
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacKit Recording",
            kAudioAggregateDeviceUIDKey: "mackit.recording.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        let status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
        guard status == noErr else { stop(); throw MixerError.aggregate(status) }
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let rate = asbd.mSampleRate
        let consume = consume
        let format = format
        gain.desired = Self.mixdownGain(channels: outputChannels)
        gain.sampleRate = rate
        let gain = gain
        let creation = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue) { _, input, timestamp, _, _ in
            guard let format, bytesPerFrame > 0 else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = buffers.first, let bytes = buffer.mData, buffer.mDataByteSize > 0 else { return }
            let count = Int(buffer.mDataByteSize) / bytesPerFrame
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: Int(buffer.mDataByteSize), blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: Int(buffer.mDataByteSize), flags: 0, blockBufferOut: &block) == noErr, let block else { return }
            guard CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: Int(buffer.mDataByteSize)) == noErr else { return }
            var copied: UnsafeMutablePointer<CChar>?
            var length = 0
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &copied) == noErr, let copied {
                let levels = gain.limiter.next(peak: MixerRender.peak(of: buffers), desired: gain.desired, frames: count, sampleRate: rate)
                copied.withMemoryRebound(to: Float.self, capacity: length / 4) { values in
                    let channels = max(1, bytesPerFrame / 4)
                    for index in 0..<(length / 4) {
                        let fraction = Float(index / channels) / Float(max(1, count))
                        values[index] *= levels.start + (levels.end - levels.start) * fraction
                    }
                }
            }
            let time = CMClockMakeHostTimeFromSystemUnits(timestamp.pointee.mHostTime)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else { return }
            consume(sample)
        }
        guard creation == noErr, let proc else { stop(); throw MixerError.start(creation) }
        let started = AudioDeviceStart(deviceID, proc)
        guard started == noErr else { stop(); throw MixerError.start(started) }
    }

    static func mixdownGain(channels: Int) -> Float { channels > 2 ? Float(channels) / 2 : 1 }

    static func outputChannels(of device: AudioDeviceID) -> Int {
        var property = AudioProperty.address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return 2 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, memory) == noErr else { return 2 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func stop() {
        if let proc { AudioDeviceStop(deviceID, proc); AudioDeviceDestroyIOProcID(deviceID, proc) }
        proc = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
    deinit { stop() }
}
