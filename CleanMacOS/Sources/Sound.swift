import CoreAudio
import Foundation

struct SoundDevice: Identifiable, Equatable, Hashable {
    enum Kind: Int, Codable {
        case builtIn, hardware, virtual
    }

    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let hasOutput: Bool
    let hasInput: Bool
    let terminal: UInt32

    var kind: Kind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeUnknown: .virtual
        default: .hardware
        }
    }

    var isHeadphones: Bool { HeadphoneDetector.isHeadphones(name: name, uid: uid, terminal: terminal) }
}

enum DeviceCycle {
    static func next(after current: String?, in available: [String], ticked: Set<String>) -> String? {
        guard let current, let position = available.firstIndex(of: current) else { return available.first { ticked.contains($0) } }
        let rotated = Array(available[(position + 1)...]) + Array(available[..<position])
        return rotated.first { ticked.contains($0) && $0 != current }
    }
}

enum AudioPriority {
    static let limit = 64

    static func seed(current: String?, devices: [String], kinds: [String: SoundDevice.Kind]) -> [String] {
        let rest = devices.filter { $0 != current }.enumerated().sorted { lhs, rhs in
            let left = kinds[lhs.element]?.rawValue ?? SoundDevice.Kind.hardware.rawValue
            let right = kinds[rhs.element]?.rawValue ?? SoundDevice.Kind.hardware.rawValue
            return left != right ? left < right : lhs.offset < rhs.offset
        }
        return Array(([current].compactMap { $0 } + rest.map(\.element)).prefix(limit))
    }

    static func placing(_ uid: String, in list: [String], kinds: [String: SoundDevice.Kind], becameDefault: Bool) -> [String] {
        guard !list.contains(uid) else { return list }
        var updated = list
        if becameDefault {
            updated.insert(uid, at: 0)
        } else if let index = updated.firstIndex(where: { kinds[$0] == .virtual }) {
            updated.insert(uid, at: index)
        } else {
            updated.append(uid)
        }
        return Array(updated.prefix(limit))
    }

    static func choice(in list: [String], available: Set<String>, current: String?) -> String? {
        if let current, available.contains(current), !list.contains(current) { return nil }
        guard let best = list.first(where: { available.contains($0) }), best != current else { return nil }
        return best
    }
}

struct InputControlState: Codable, Equatable {
    var mutes: [UInt32: UInt32]
    var volumes: [UInt32: Float32]

    var isSilent: Bool {
        mutes.values.contains(1) || (!volumes.isEmpty && volumes.values.allSatisfy { $0 == 0 })
    }

    var silenced: InputControlState {
        InputControlState(mutes: mutes.mapValues { _ in 1 }, volumes: volumes.mapValues { _ in 0 })
    }
}

enum MicMutePlan {
    static let fallbackVolume: Float32 = 0.75

    static func newClaims(from states: [String: InputControlState], existing: [String: InputControlState]) -> [String: InputControlState] {
        states.filter { uid, state in existing[uid] == nil && !state.isSilent }
    }
}

enum HeadphoneDetector {
    static let headphoneTerminal = UInt32(kAudioStreamTerminalTypeHeadphones)
    static let speakerTerminal = UInt32(kAudioStreamTerminalTypeSpeaker)
    static let keywords = [
        "airpods", "headphone", "headset", "earbud", "earphone", "beats", "jabra", "bose qc", "bose nc", "wh-1000", "wf-1000",
        "galaxy buds", "pixel buds", "nothing ear",
    ]

    static func isHeadphones(name: String, uid: String, terminal: UInt32) -> Bool {
        if terminal == speakerTerminal { return false }
        if terminal == headphoneTerminal { return true }
        let text = (name + " " + uid).lowercased()
        return keywords.contains { text.contains($0) }
    }
}

struct SoundLevel: Codable, Equatable {
    let device: String
    let volume: Double
}

struct HeadphoneGuard: Codable, Equatable {
    static let tolerance = 0.01

    var target: Double
    private(set) var lowered: SoundLevel?
    private(set) var previous: Double?

    init(target: Double) {
        self.target = target
    }

    mutating func disconnected(to device: String, volume: Double) -> Double? {
        guard volume > target else { return nil }
        lowered = SoundLevel(device: device, volume: target)
        previous = volume
        return target
    }

    mutating func reconnected(currentVolume: (String) -> Double?) -> SoundLevel? {
        defer {
            lowered = nil
            previous = nil
        }
        guard let lowered, let previous, let now = currentVolume(lowered.device), abs(now - lowered.volume) < Self.tolerance else { return nil }
        return SoundLevel(device: lowered.device, volume: previous)
    }
}

enum MusicBlocker {
    static let window: TimeInterval = 2
    static let musicApps: Set<String> = ["com.apple.Music", "com.apple.iTunes"]

    static func shouldBlock(launchedAt: TimeInterval, lastMediaKey: TimeInterval?) -> Bool {
        guard let lastMediaKey else { return false }
        let elapsed = launchedAt - lastMediaKey
        return elapsed >= 0 && elapsed <= window
    }
}
