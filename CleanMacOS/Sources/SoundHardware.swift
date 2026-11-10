import AudioToolbox
import CoreAudio
import Foundation

enum AudioProperty {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var target = address(selector, scope, element)
        return AudioObjectHasProperty(object, &target)
    }

    static func isSettable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                           _ element: AudioObjectPropertyElement) -> Bool {
        var target = address(selector, scope, element)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(object, &target) && AudioObjectIsPropertySettable(object, &target, &settable) == noErr && settable.boolValue
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, as type: T.Type) -> T? {
        var target = address(selector, scope, element)
        guard AudioObjectHasProperty(object, &target) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &target, 0, nil, &size, buffer) == noErr else { return nil }
        return buffer.load(as: T.self)
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: T.Type) -> [T] {
        var target = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &target, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &target, 0, nil, &size, buffer) == noErr else { return [] }
        return (0..<count).map { buffer.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var target = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &target, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, _ value: T) -> Bool {
        var target = address(selector, scope, element)
        var copy = value
        return withUnsafeMutablePointer(to: &copy) { AudioObjectSetPropertyData(object, &target, 0, nil, UInt32(MemoryLayout<T>.size), $0) } == noErr
    }

    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       queue: DispatchQueue = .main, _ handler: @escaping () -> Void) {
        var target = address(selector, scope, kAudioObjectPropertyElementWildcard)
        AudioObjectAddPropertyListenerBlock(object, &target, queue) { _, _ in handler() }
    }
}

enum SoundHardware {
    static let output = kAudioDevicePropertyScopeOutput
    static let input = kAudioDevicePropertyScopeInput
    static let muteThreshold = 0.005
    static let channelElements: [AudioObjectPropertyElement] = [0, 1, 2]
    static let ownAggregatePrefix = "MacKit Mixer"
    static let verifyAttempts = 3
    static let verifyDelay: useconds_t = 20_000
    static let tolerance: Float32 = 0.02

    static func devices() -> [SoundDevice] {
        AudioProperty.array(AudioProperty.system, kAudioHardwarePropertyDevices, as: AudioDeviceID.self).compactMap(device)
    }

    static func device(_ id: AudioDeviceID) -> SoundDevice? {
        guard AudioProperty.get(id, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) != 0,
              AudioProperty.get(id, kAudioDevicePropertyIsHidden, as: UInt32.self) != 1 else { return nil }
        let name = AudioProperty.string(id, kAudioObjectPropertyName) ?? "Device \(id)"
        guard !name.hasPrefix(ownAggregatePrefix) else { return nil }
        let outputStreams = AudioProperty.array(id, kAudioDevicePropertyStreams, output, as: AudioStreamID.self)
        let inputStreams = AudioProperty.array(id, kAudioDevicePropertyStreams, input, as: AudioStreamID.self)
        let hasOutput = !outputStreams.isEmpty && canBeDefault(id, output)
        let hasInput = !inputStreams.isEmpty && canBeDefault(id, input)
        guard hasOutput || hasInput else { return nil }
        return SoundDevice(id: id, uid: AudioProperty.string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)", name: name,
                           transport: AudioProperty.get(id, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0,
                           hasOutput: hasOutput, hasInput: hasInput,
                           terminal: outputStreams.first.flatMap { AudioProperty.get($0, kAudioStreamPropertyTerminalType, as: UInt32.self) } ?? 0)
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        AudioProperty.get(AudioProperty.system, selector, as: AudioDeviceID.self)
    }

    @discardableResult
    static func setDefault(_ selector: AudioObjectPropertySelector, to id: AudioDeviceID) -> Bool {
        AudioProperty.set(AudioProperty.system, selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, id)
    }

    static func volume(of id: AudioDeviceID, scope: AudioObjectPropertyScope = output) -> Double? {
        if let main = AudioProperty.get(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, as: Float32.self) { return Double(main) }
        let channels = channelElements.compactMap { AudioProperty.get(id, kAudioDevicePropertyVolumeScalar, scope, $0, as: Float32.self) }
        return channels.isEmpty ? nil : Double(channels.reduce(0, +)) / Double(channels.count)
    }

    static func canSetVolume(of id: AudioDeviceID, scope: AudioObjectPropertyScope = output) -> Bool {
        AudioProperty.isSettable(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, kAudioObjectPropertyElementMain)
            || channelElements.contains { AudioProperty.isSettable(id, kAudioDevicePropertyVolumeScalar, scope, $0) }
    }

    @discardableResult
    static func setVolume(_ level: Double, of id: AudioDeviceID, scope: AudioObjectPropertyScope = output) -> Bool {
        let value = Float32(min(max(level, 0), 1))
        var isSet = AudioProperty.isSettable(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, kAudioObjectPropertyElementMain)
            && AudioProperty.set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, kAudioObjectPropertyElementMain, value)
        if !isSet {
            isSet = channelElements.filter { AudioProperty.isSettable(id, kAudioDevicePropertyVolumeScalar, scope, $0) }
                .map { AudioProperty.set(id, kAudioDevicePropertyVolumeScalar, scope, $0, value) }
                .contains(true)
        }
        if scope == output { setMuted(level <= muteThreshold, of: id) }
        return isSet && verify(value, of: id, scope: scope)
    }

    static func isMuted(_ id: AudioDeviceID, scope: AudioObjectPropertyScope = output) -> Bool {
        channelElements.contains { AudioProperty.get(id, kAudioDevicePropertyMute, scope, $0, as: UInt32.self) == 1 }
    }

    @discardableResult
    static func setMuted(_ isMuted: Bool, of id: AudioDeviceID, scope: AudioObjectPropertyScope = output) -> Bool {
        channelElements.filter { AudioProperty.isSettable(id, kAudioDevicePropertyMute, scope, $0) }
            .map { AudioProperty.set(id, kAudioDevicePropertyMute, scope, $0, UInt32(isMuted ? 1 : 0)) }
            .contains(true)
    }

    static func inputState(of id: AudioDeviceID) -> InputControlState {
        let elements = inputElements(of: id)
        var mutes: [UInt32: UInt32] = [:]
        var volumes: [UInt32: Float32] = [:]
        for element in elements {
            if AudioProperty.isSettable(id, kAudioDevicePropertyMute, input, element),
               let mute = AudioProperty.get(id, kAudioDevicePropertyMute, input, element, as: UInt32.self) {
                mutes[element] = mute
            }
            if AudioProperty.isSettable(id, kAudioDevicePropertyVolumeScalar, input, element),
               let volume = AudioProperty.get(id, kAudioDevicePropertyVolumeScalar, input, element, as: Float32.self) {
                volumes[element] = volume
            }
        }
        return InputControlState(mutes: mutes, volumes: volumes)
    }

    @discardableResult
    static func apply(_ state: InputControlState, to id: AudioDeviceID) -> Bool {
        let mutes = state.mutes.map { AudioProperty.set(id, kAudioDevicePropertyMute, input, $0.key, $0.value) }
        let volumes = state.volumes.map { AudioProperty.set(id, kAudioDevicePropertyVolumeScalar, input, $0.key, $0.value) }
        return !(mutes + volumes).contains(false)
    }

    private static func inputElements(of id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var target = AudioProperty.address(kAudioDevicePropertyStreamConfiguration, input)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &target, 0, nil, &size) == noErr, size > 0 else { return [0] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &target, 0, nil, &size, buffer) == noErr else { return [0] }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        return Array(0...UInt32(channels))
    }

    private static func canBeDefault(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        AudioProperty.get(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope, as: UInt32.self) != 0
    }

    private static func verify(_ value: Float32, of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        for _ in 0..<verifyAttempts {
            if let current = volume(of: id, scope: scope), abs(Float32(current) - value) <= tolerance { return true }
            usleep(verifyDelay)
        }
        return false
    }
}
