import Foundation

struct OutputQuality: Equatable {
    enum Level: Equatable {
        case bitPerfect, altered, degraded
    }

    static let pcmFloatPrecision = 24

    let level: Level
    let title: String
    let detail: String

    static func evaluate(track: TrackFormat, status: OutputStatus, volume: Double) -> OutputQuality {
        let device = status.deviceName
        let deviceRate = TrackFormat.kilohertz(status.device.sampleRate)
        if status.isBluetooth {
            return OutputQuality(level: .degraded, title: "Bluetooth",
                                 detail: "Bluetooth compresses audio, so hi-res is lost. Use a wired DAC or speakers.")
        }
        switch status.kind {
        case .dop:
            return OutputQuality(level: .bitPerfect, title: "Native DSD (DoP)",
                                 detail: "\(track.resolution) goes to \(device) as DoP at \(deviceRate) kHz. Set the volume on the DAC.")
        case .dsdToPCM:
            return OutputQuality(level: .altered, title: "DSD → PCM \(TrackFormat.kilohertz(status.streamRate)) kHz",
                                 detail: "\(device) has no DoP turned on, so DSD is converted to PCM before it plays.")
        case .pcm:
            break
        }
        if status.device.sampleRate != track.sampleRate {
            return OutputQuality(level: .degraded, title: "Resampled to \(deviceRate) kHz",
                                 detail: "\(device) cannot play \(TrackFormat.kilohertz(track.sampleRate)) kHz, so the audio is converted to \(deviceRate) kHz.")
        }
        let depth = status.device.isFloat ? pcmFloatPrecision : status.device.bitDepth
        if depth < track.bitDepth {
            return OutputQuality(level: .degraded, title: "Reduced to \(depth)-bit",
                                 detail: "\(device) plays at most \(depth)-bit, below the \(track.bitDepth)-bit of this file.")
        }
        if volume < 1 {
            return OutputQuality(level: .altered, title: "Volume \(Int((volume * 100).rounded()))%",
                                 detail: "Keep the app volume at 100% and use the DAC or amp volume for bit-perfect playback.")
        }
        return OutputQuality(level: .bitPerfect, title: "Bit-perfect", detail: "\(track.resolution) goes to \(device) untouched.")
    }
}
