import AppKit
import CoreAudio

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
    var renders = 0
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
    let state = RenderState()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "mackit.mixer.render", qos: .userInteractive)

    init(appID: String, outputUID: String, processObjects: [AudioObjectID]) {
        self.appID = appID
        self.outputUID = outputUID
        self.processObjects = processObjects
    }

    func start(gain: Float) throws {
        state.desired = gain
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
            let gains = state.limiter.next(peak: MixerRender.peak(of: input), desired: state.desired, frames: frames, sampleRate: state.sampleRate)
            MixerRender.copy(from: input, to: output, start: gains.start, end: gains.end)
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
            applyEngines()
        }
    }
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var problem: MixerError?

    private let sound: SoundController
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
        refresh()
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
        var wanted: [String: (output: String, objects: [AudioObjectID], gain: Float)] = [:]
        if settings.isEnabled {
            for app in apps where AudioAppPolicy.canTap(app.id) {
                guard let mix = settings.mixes[app.id], mix.needsTap,
                      let output = mix.route.flatMap({ available.contains($0) ? $0 : nil }) ?? defaultUID else { continue }
                wanted[app.id] = (output, app.processObjects.sorted(), mix.gain)
            }
        }
        for (id, value) in engines {
            guard let engine = value as? AppTapEngine else { continue }
            if let target = wanted[id], target.output == engine.outputUID, target.objects == engine.processObjects {
                engine.state.desired = target.gain
            } else if wanted[id] == nil || failed.contains(key(id, wanted[id]!.output)) {
                engine.stop()
                engines[id] = nil
            }
        }
        for (id, target) in wanted where !failed.contains(key(id, target.output)) {
            if let engine = engines[id] as? AppTapEngine, engine.outputUID == target.output, engine.processObjects == target.objects { continue }
            let replacement = AppTapEngine(appID: id, outputUID: target.output, processObjects: target.objects)
            do {
                try replacement.start(gain: target.gain)
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
            let isPlaying = apps.first { $0.id == id }?.isPlaying ?? false
            let mark = renderMarks[id]
            if !isPlaying || mark == nil || mark?.count != engine.state.renders {
                renderMarks[id] = (engine.state.renders, now)
            } else if let mark, now.timeIntervalSince(mark.since) > Self.stallLimit {
                engine.stop()
                engines[id] = nil
                failed.insert(key(id, engine.outputUID))
            }
        }
        applyEngines()
    }
}
