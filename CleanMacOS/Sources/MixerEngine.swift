import AppKit
import CoreAudio
import MacKitAudioBridge

struct AudioProcess: Equatable {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool
}

struct AudioApp: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let name: String
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
}

enum AudioProcesses {
    static let parentDepth = 6

    static func list() -> [AudioProcess] {
        AudioProperty.array(AudioProperty.system, kAudioHardwarePropertyProcessObjectList, as: AudioObjectID.self).compactMap { object in
            guard let pid = AudioProperty.get(object, kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
            return AudioProcess(object: object, pid: pid, bundleID: AudioProperty.string(object, kAudioProcessPropertyBundleID),
                                isPlaying: AudioProperty.get(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1)
        }
    }

    @MainActor
    static func apps(from processes: [AudioProcess]) -> [AudioApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        var apps: [String: AudioApp] = [:]
        for process in processes where process.pid != own {
            guard let app = owner(of: process.pid), app.processIdentifier != own, let bundleID = app.bundleIdentifier else { continue }
            var entry = apps[bundleID] ?? AudioApp(id: bundleID, pid: app.processIdentifier, name: app.localizedName ?? bundleID, processObjects: [], isPlaying: false)
            entry.processObjects.append(process.object)
            entry.isPlaying = entry.isPlaying || process.isPlaying
            apps[bundleID] = entry
        }
        return apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor
    static func owner(of pid: pid_t) -> NSRunningApplication? {
        var candidates = [pid]
        if let responsible = ResponsibleProcess.lookup?(pid), responsible > 0 { candidates.append(responsible) }
        var current = pid
        for _ in 0..<parentDepth {
            guard let parent = parentPID(of: current), parent > 1 else { break }
            candidates.append(parent)
            current = parent
        }
        return candidates.lazy.compactMap { NSRunningApplication(processIdentifier: $0) }.first { $0.activationPolicy == .regular }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

enum ResponsibleProcess {
    typealias Lookup = @convention(c) (pid_t) -> pid_t
    static let lookup = PrivateSymbols.load("responsibility_get_pid_responsible_for_pid", from: "/usr/lib/libSystem.B.dylib", as: Lookup.self)
}

final class RenderState: @unchecked Sendable {
    var desired: Float = 1
    var sampleRate: Double = 48000
    var limiter = BoostLimiter()
    var compensation: Float = 1
    var ramp = MixerGainRamp()
    var renders = 0
    var airPlay: AirPlayStream?
}

enum MixerError: Error, Equatable {
    case unavailable, tap(OSStatus), aggregate(OSStatus), start(OSStatus)

    var message: String {
        switch self {
        case .unavailable: "Per-app volume needs macOS 14.4 or later."
        case .tap: "Allow \(AppIdentity.installedName) under System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        case .aggregate(let status), .start(let status): "Couldn't route the app's sound (error \(status))."
        }
    }
}

@available(macOS 14.4, *)
final class AppTapEngine {
    static let namePrefix = SoundHardware.ownAggregatePrefix

    let appID: String
    let outputUID: String
    let processObjects: [AudioObjectID]
    let isAirPlay: Bool
    let state = RenderState()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "mackit.mixer.render", qos: .userInteractive)

    init(appID: String, outputUID: String, processObjects: [AudioObjectID], airPlay: AirPlayStream? = nil) {
        isAirPlay = airPlay != nil
        state.airPlay = airPlay
        self.appID = appID
        self.outputUID = outputUID
        self.processObjects = processObjects
    }

    func start(gain: Float) throws {
        state.desired = gain
        state.ramp = MixerGainRamp(current: gain * state.compensation)
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "\(Self.namePrefix) \(appID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw MixerError.tap(status) }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(Self.namePrefix) \(appID)",
            kAudioAggregateDeviceUIDKey: "\(Self.namePrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw MixerError.aggregate(status)
        }
        state.sampleRate = AudioProperty.get(aggregateID, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? state.sampleRate
        let state = self.state
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inputData, _, outputData, _ in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = output.first.map { Int($0.mDataByteSize) / (MemoryLayout<Float>.size * max(Int($0.mNumberChannels), 1)) } ?? 0
            let ramp = state.ramp.next(target: state.desired * state.compensation, frames: frames, sampleRate: state.sampleRate)
            let limited = state.limiter.next(peak: MixerRender.peak(of: input), desired: max(ramp.start, ramp.end), frames: frames, sampleRate: state.sampleRate)
            let gains = (start: min(ramp.start, limited.start), end: min(ramp.end, limited.end))
            if let stream = state.airPlay {
                let channels = MixerRender.channels(of: input)
                let inputFrames = channels.map(\.frames).min() ?? 0
                for frame in 0..<inputFrames {
                    let gain = gains.start + (gains.end - gains.start) * Float(frame) / Float(max(1, inputFrames))
                    let left = channels.first.map { $0.pointer[frame * $0.stride] } ?? 0
                    let right = channels.count > 1 ? channels[1].pointer[frame * channels[1].stride] : left
                    MKAudioRingWrite(stream.ring, left * gain, right * gain)
                }
                for buffer in output {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
            } else {
                MixerRender.copy(from: input, to: output, start: gains.start, end: gains.end)
            }
            state.renders &+= 1
        }
        guard status == noErr, let procID else {
            stop()
            throw MixerError.start(status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw MixerError.start(status)
        }
    }

    func configure(gain: Float, compensation: Float, sampleRate: Double) {
        let state = state
        queue.async {
            state.desired = gain
            state.compensation = compensation
            state.sampleRate = sampleRate
        }
    }

    var renderCount: Int { queue.sync { state.renders } }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        stop()
    }
}

struct AppMix: Codable, Equatable {
    static let unity = 1.0
    static let tolerance = 0.005

    var volume = unity
    var isMuted = false
    var route: String?

    var needsTap: Bool { isMuted || abs(volume - Self.unity) > Self.tolerance || route != nil }
    var gain: Float { isMuted ? 0 : MixerGain.amplitude(for: volume) }
}

struct MixerSettings: Codable, Equatable {
    var isEnabled = false
    var hidesInactive = false
    var fineVolumeKeys = false
    var airPlayEnabled = false
    var mixes: [String: AppMix] = [:]
}

@MainActor
final class MixerController: ObservableObject {
    static let settingsKey = "mixer.settings"
    static let pollInterval: TimeInterval = 1
    static let stallLimit: TimeInterval = 1.5

    static var isAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    @Published var settings: MixerSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            sound.fineVolumeKeysEnabled = settings.isEnabled && settings.fineVolumeKeys
            airPlay.setRunning(settings.isEnabled && settings.airPlayEnabled)
            fineVolume.setEnabled(settings.isEnabled && settings.fineVolumeKeys, request: !oldValue.fineVolumeKeys && settings.fineVolumeKeys)
            applyEngines()
        }
    }
    let fineVolume = FineVolumeController()
    let airPlay = AirPlayRoutes()
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var problem: MixerError?

    private let sound: SoundController
    private var outputFormats: [String: (rate: Double, compensation: Float)] = [:]
    private var lastFormatRead = Date.distantPast
    private var engines: [String: AnyObject] = [:]
    private var renderMarks: [String: (count: Int, since: Date)] = [:]
    private var failed: Set<String> = []
    private var timer: Timer?

    init(sound: SoundController) {
        self.sound = sound
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(MixerSettings.self, from: $0) } ?? MixerSettings()
        AudioProperty.listen(AudioProperty.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        AudioProperty.listen(AudioProperty.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            MainActor.assumeIsolated { self?.applyEngines() }
        }
        sound.fineVolumeKeysEnabled = settings.isEnabled && settings.fineVolumeKeys
        fineVolume.onStep = { [weak sound] code in sound?.fineMonitorStep(code: code) ?? false }
        airPlay.onChange = { [weak self] in self?.applyEngines() }
        sound.onManualOutputChange = { [weak self] in self?.clearRoutes() }
        airPlay.setRunning(settings.isEnabled && settings.airPlayEnabled)
        refresh()
        fineVolume.setEnabled(settings.isEnabled && settings.fineVolumeKeys, request: false)
        applyEngines()
    }

    var visibleApps: [AudioApp] {
        settings.hidesInactive ? apps.filter { $0.isPlaying || settings.mixes[$0.id] != nil } : apps
    }

    func mix(for app: AudioApp) -> AppMix {
        settings.mixes[app.id] ?? AppMix()
    }

    func setVolume(_ volume: Double, for app: AudioApp) {
        update(app) { $0.volume = min(max(volume, 0), MixerGain.maximum) }
    }

    func toggleMute(_ app: AudioApp) {
        update(app) { $0.isMuted.toggle() }
    }

    func reset(_ app: AudioApp) {
        update(app) { $0 = AppMix(route: $0.route) }
    }

    func setRoute(_ uid: String?, for app: AudioApp) {
        update(app) { $0.route = uid }
        if uid == AirPlayRouteLogic.uid && !airPlay.connected { airPlay.chooseSpeaker() }
    }

    func chooseAirPlay(for app: AudioApp) {
        update(app) { $0.route = AirPlayRouteLogic.uid }
        airPlay.chooseSpeaker()
    }

    private func clearRoutes() {
        var updated = settings
        for id in updated.mixes.keys { updated.mixes[id]?.route = nil }
        settings = updated
    }

    private func update(_ app: AudioApp, _ change: (inout AppMix) -> Void) {
        var mix = settings.mixes[app.id] ?? AppMix()
        change(&mix)
        settings.mixes[app.id] = mix.needsTap ? mix : nil
    }

    private func refresh() {
        apps = AudioProcesses.apps(from: AudioProcesses.list())
        applyEngines()
    }

    private func applyEngines() {
        guard #available(macOS 14.4, *) else { return }
        let defaultUID = sound.outputs.first { $0.id == SoundHardware.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }?.uid
        let available = Set(sound.outputs.map(\.uid))
        if Date().timeIntervalSince(lastFormatRead) >= 1 {
            lastFormatRead = Date()
            outputFormats = Dictionary(uniqueKeysWithValues: sound.outputs.map { device in
                let streams = AudioProperty.array(device.id, kAudioDevicePropertyStreams, SoundHardware.output, as: AudioStreamID.self)
                let channels = streams.reduce(0) { sum, stream in
                    sum + Int(AudioProperty.get(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self)?.mChannelsPerFrame ?? 0)
                }
                let rate = AudioProperty.get(device.id, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
                return (device.uid, (rate, MixerGainRamp.compensation(channels: channels)))
            })
        }
        var wanted: [String: (output: String, objects: [AudioObjectID], gain: Float, airPlay: Bool)] = [:]
        if settings.isEnabled {
            for app in apps where AudioAppPolicy.canTap(app.id) {
                guard let mix = settings.mixes[app.id], mix.needsTap else { continue }
                let remote = mix.route == AirPlayRouteLogic.uid
                if remote && !airPlay.connected { continue }
                let clock = defaultUID ?? sound.outputs.first { $0.kind != .virtual }?.uid
                guard let output = remote ? clock : mix.route.flatMap({ available.contains($0) ? $0 : nil }) ?? defaultUID else { continue }
                wanted[app.id] = (output, app.processObjects.sorted(), mix.gain, remote)
            }
        }
        for (id, value) in engines {
            guard let engine = value as? AppTapEngine else { continue }
            if let target = wanted[id], target.output == engine.outputUID, target.objects == engine.processObjects, target.airPlay == engine.isAirPlay {
                let format = outputFormats[target.output] ?? (rate: 48000, compensation: 1)
                engine.configure(gain: target.gain, compensation: format.compensation, sampleRate: format.rate)
            } else if wanted[id] == nil || failed.contains(key(id, wanted[id]!.output)) {
                engine.stop()
                engines[id] = nil
            }
        }
        for (id, target) in wanted where !failed.contains(key(id, target.output)) {
            if let engine = engines[id] as? AppTapEngine, engine.outputUID == target.output, engine.processObjects == target.objects, engine.isAirPlay == target.airPlay { continue }
            let stream = target.airPlay ? airPlay.stream(for: id) : nil
            if target.airPlay && stream == nil { continue }
            let replacement = AppTapEngine(appID: id, outputUID: target.output, processObjects: target.objects, airPlay: stream)
            replacement.state.compensation = outputFormats[target.output]?.compensation ?? 1
            do {
                try replacement.start(gain: target.gain)
                if let stream { airPlay.attach(stream, for: id) }
                (engines[id] as? AppTapEngine)?.stop()
                engines[id] = replacement
                renderMarks[id] = nil
                problem = nil
            } catch let error as MixerError {
                failed.insert(key(id, target.output))
                problem = error
            } catch {
                failed.insert(key(id, target.output))
            }
        }
        let routed = Set(engines.compactMap { key, value in (value as? AppTapEngine)?.isAirPlay == true ? key : nil })
        airPlay.retainStreams(routed, playing: apps.contains { routed.contains($0.id) && $0.isPlaying })
        updateTimer()
    }

    private func key(_ app: String, _ output: String) -> String {
        "\(app)>\(output)"
    }

    private func updateTimer() {
        let needsTimer = settings.isEnabled
        guard needsTimer != (timer != nil) else { return }
        if needsTimer {
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let fresh = AudioProcesses.apps(from: AudioProcesses.list())
        if fresh != apps { apps = fresh }
        guard #available(macOS 14.4, *) else { return }
        let now = Date()
        for (id, value) in engines {
            guard let engine = value as? AppTapEngine else { continue }
            if let stream = engine.state.airPlay {
                stream.sampleRate = outputFormats[engine.outputUID]?.rate ?? stream.sampleRate
            }
            let isPlaying = apps.first { $0.id == id }?.isPlaying ?? false
            let mark = renderMarks[id]
            let rendered = engine.renderCount
            if !isPlaying || mark == nil || mark?.count != rendered {
                renderMarks[id] = (rendered, now)
            } else if let mark, now.timeIntervalSince(mark.since) > Self.stallLimit {
                engine.stop()
                engines[id] = nil
                failed.insert(key(id, engine.outputUID))
            }
        }
        applyEngines()
    }
}

extension MixerSettings {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        hidesInactive = try values.decodeIfPresent(Bool.self, forKey: .hidesInactive) ?? false
        airPlayEnabled = try values.decodeIfPresent(Bool.self, forKey: .airPlayEnabled) ?? false
        fineVolumeKeys = try values.decodeIfPresent(Bool.self, forKey: .fineVolumeKeys) ?? false
        mixes = try values.decodeIfPresent([String: AppMix].self, forKey: .mixes) ?? [:]
    }
}
