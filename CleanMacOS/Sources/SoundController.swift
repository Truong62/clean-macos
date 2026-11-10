import AppKit
import ApplicationServices
import CoreAudio
import KeyboardShortcuts

struct SoundSettings: Codable, Equatable {
    var cycleEnabled = false
    var cycleOutputs: [String] = []
    var outputPriorityEnabled = false
    var inputPriorityEnabled = false
    var outputPriority: [String] = []
    var inputPriority: [String] = []
    var deviceNames: [String: String] = [:]
    var micShortcutEnabled = false
    var showsMicBadge = true
    var handlesVolumeKeys = false
    var volumeStep = LevelStep.standard
    var guardsHeadphones = false
    var headphoneTarget = 0.25
    var blocksMusic = false
    var musicReplacement: String?
}

struct MicMuteState: Codable, Equatable {
    var isMuted = false
    var claims: [String: InputControlState] = [:]
}

enum SoundKey {
    static let volumeUp = 0
    static let volumeDown = 1
    static let mute = 7
    static let mediaKeys: Set<Int> = [16, 17, 18, 19, 20]
}

@MainActor
final class SoundController: ObservableObject {
    static let settingsKey = "sound.settings"
    static let micKey = "sound.micMute"
    static let debounce: TimeInterval = 0.25
    static let newDeviceWait: TimeInterval = 2
    static let systemDefinedEvent: UInt32 = 14

    @Published var settings: SoundSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            apply(previous: oldValue)
        }
    }
    @Published private(set) var devices: [SoundDevice] = []
    @Published private(set) var defaultOutput: AudioDeviceID?
    @Published private(set) var defaultInput: AudioDeviceID?
    @Published private(set) var systemOutput: AudioDeviceID?
    @Published private(set) var outputVolume: Double?
    @Published private(set) var inputVolume: Double?
    @Published private(set) var mic: MicMuteState {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(mic), forKey: Self.micKey) }
    }

    private var knownOutputs: Set<String> = []
    private var knownInputs: Set<String> = []
    private var listenedInputs: Set<AudioDeviceID> = []
    private var refreshWork: DispatchWorkItem?
    private var headphoneGuard = HeadphoneGuard(target: 0.25)
    private var lastOutputWasHeadphones = false
    private var lastMediaKey: TimeInterval?
    private var consumedKeys: Set<Int> = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var launchObserver: NSObjectProtocol?
    private let hud = LevelHUD()
    private let messages = InputHUD()

    init() {
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(SoundSettings.self, from: $0) } ?? SoundSettings()
        mic = defaults.data(forKey: Self.micKey).flatMap { try? JSONDecoder().decode(MicMuteState.self, from: $0) } ?? MicMuteState()
        KeyboardShortcuts.onKeyUp(for: .cycleOutput) { [weak self] in MainActor.assumeIsolated { self?.cycleOutput() } }
        KeyboardShortcuts.onKeyUp(for: .toggleMicMute) { [weak self] in MainActor.assumeIsolated { self?.toggleMicMute() } }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultSystemOutputDevice] {
            AudioProperty.listen(AudioProperty.system, selector) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTap() }
        }
        refresh(isFirst: true)
        apply(previous: nil)
    }

    var outputs: [SoundDevice] { devices.filter(\.hasOutput) }
    var inputs: [SoundDevice] { devices.filter(\.hasInput) }
    var isMicMuted: Bool { mic.isMuted }

    func setDefaultOutput(_ device: SoundDevice) {
        SoundHardware.setDefault(kAudioHardwarePropertyDefaultOutputDevice, to: device.id)
        scheduleRefresh()
    }

    func setSystemOutput(_ device: SoundDevice) {
        SoundHardware.setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, to: device.id)
        scheduleRefresh()
    }

    func setDefaultInput(_ device: SoundDevice) {
        SoundHardware.setDefault(kAudioHardwarePropertyDefaultInputDevice, to: device.id)
        scheduleRefresh()
    }

    func setOutputVolume(_ level: Double) {
        guard let defaultOutput else { return }
        SoundHardware.setVolume(level, of: defaultOutput)
        outputVolume = level
    }

    func setInputVolume(_ level: Double) {
        guard let defaultInput, !mic.isMuted else { return }
        SoundHardware.setVolume(level, of: defaultInput, scope: SoundHardware.input)
        inputVolume = level
    }

    func cycleOutput() {
        let available = outputs.map(\.uid)
        let current = outputs.first { $0.id == defaultOutput }?.uid
        guard let next = DeviceCycle.next(after: current, in: available, ticked: Set(settings.cycleOutputs)),
              let device = outputs.first(where: { $0.uid == next }) else { return NSSound.beep() }
        setDefaultOutput(device)
        messages.show("Sound output: \(device.name)", for: 1.2)
    }

    func toggleMicMute() {
        setMicMuted(!mic.isMuted)
        messages.show(mic.isMuted ? "Mic Mute on" : "Mic Mute off", for: 1.2)
    }

    func setMicMuted(_ isMuted: Bool) {
        if isMuted {
            mic.isMuted = true
            enforceMicMute()
        } else {
            var away: [String: InputControlState] = [:]
            for (uid, saved) in mic.claims {
                if let device = inputs.first(where: { $0.uid == uid }) { SoundHardware.apply(saved, to: device.id) } else { away[uid] = saved }
            }
            mic = MicMuteState(isMuted: false, claims: away)
        }
        inputVolume = defaultInput.flatMap { SoundHardware.volume(of: $0, scope: SoundHardware.input) }
    }

    func moveInPriority(_ uid: String, by offset: Int, isOutput: Bool) {
        var list = isOutput ? settings.outputPriority : settings.inputPriority
        guard let index = list.firstIndex(of: uid) else { return }
        let target = min(max(index + offset, 0), list.count - 1)
        list.remove(at: index)
        list.insert(uid, at: target)
        if isOutput { settings.outputPriority = list } else { settings.inputPriority = list }
    }

    func name(for uid: String) -> String {
        devices.first { $0.uid == uid }?.name ?? settings.deviceNames[uid] ?? uid
    }

    private func apply(previous: SoundSettings?) {
        if previous?.cycleEnabled != settings.cycleEnabled {
            if settings.cycleEnabled { KeyboardShortcuts.enable([.cycleOutput]) } else { KeyboardShortcuts.disable([.cycleOutput]) }
            if settings.cycleEnabled && settings.cycleOutputs.isEmpty, let current = outputs.first(where: { $0.id == defaultOutput }) {
                settings.cycleOutputs = [current.uid]
            }
        }
        if previous?.micShortcutEnabled != settings.micShortcutEnabled {
            if settings.micShortcutEnabled { KeyboardShortcuts.enable([.toggleMicMute]) } else { KeyboardShortcuts.disable([.toggleMicMute]) }
        }
        headphoneGuard.target = settings.headphoneTarget
        if previous != nil, previous?.outputPriorityEnabled != settings.outputPriorityEnabled || previous?.inputPriorityEnabled != settings.inputPriorityEnabled
            || previous?.outputPriority != settings.outputPriority || previous?.inputPriority != settings.inputPriority {
            seedPriorities()
            applyPriorities()
        }
        applyTap()
        applyMusicBlocker()
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(isFirst: false) }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func refresh(isFirst: Bool) {
        let previousOutput = defaultOutput
        devices = SoundHardware.devices()
        defaultOutput = SoundHardware.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        defaultInput = SoundHardware.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        systemOutput = SoundHardware.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
        outputVolume = defaultOutput.flatMap { SoundHardware.volume(of: $0) }
        inputVolume = defaultInput.flatMap { SoundHardware.volume(of: $0, scope: SoundHardware.input) }
        var names = settings.deviceNames
        devices.forEach { names[$0.uid] = $0.name }
        if names != settings.deviceNames { settings.deviceNames = names }
        listenToInputs()
        if mic.isMuted { enforceMicMute() } else { restoreReturningMicrophones() }
        if !isFirst && previousOutput != defaultOutput { guardHeadphones() }
        lastOutputWasHeadphones = outputs.first { $0.id == defaultOutput }?.isHeadphones ?? false
        let outputUIDs = Set(outputs.map(\.uid))
        let inputUIDs = Set(inputs.map(\.uid))
        let newOutputs = outputUIDs.subtracting(knownOutputs)
        let newInputs = inputUIDs.subtracting(knownInputs)
        let changed = outputUIDs != knownOutputs || inputUIDs != knownInputs
        knownOutputs = outputUIDs
        knownInputs = inputUIDs
        guard changed, !isFirst else { return }
        if newOutputs.isEmpty && newInputs.isEmpty {
            applyPriorities()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.newDeviceWait) { [weak self] in
                self?.placeNewDevices(outputs: newOutputs, inputs: newInputs)
            }
        }
    }

    private func seedPriorities() {
        let kinds = Dictionary(devices.map { ($0.uid, $0.kind) }, uniquingKeysWith: { first, _ in first })
        if settings.outputPriorityEnabled && settings.outputPriority.isEmpty {
            settings.outputPriority = AudioPriority.seed(current: outputs.first { $0.id == defaultOutput }?.uid, devices: outputs.map(\.uid), kinds: kinds)
        }
        if settings.inputPriorityEnabled && settings.inputPriority.isEmpty {
            settings.inputPriority = AudioPriority.seed(current: inputs.first { $0.id == defaultInput }?.uid, devices: inputs.map(\.uid), kinds: kinds)
        }
    }

    private func placeNewDevices(outputs newOutputs: Set<String>, inputs newInputs: Set<String>) {
        let kinds = Dictionary(devices.map { ($0.uid, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let currentOutput = outputs.first { $0.id == SoundHardware.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }?.uid
        let currentInput = inputs.first { $0.id == SoundHardware.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }?.uid
        var updated = settings
        if updated.outputPriorityEnabled {
            for uid in newOutputs where knownOutputs.contains(uid) {
                updated.outputPriority = AudioPriority.placing(uid, in: updated.outputPriority, kinds: kinds, becameDefault: uid == currentOutput)
            }
        }
        if updated.inputPriorityEnabled {
            for uid in newInputs where knownInputs.contains(uid) {
                updated.inputPriority = AudioPriority.placing(uid, in: updated.inputPriority, kinds: kinds, becameDefault: uid == currentInput)
            }
        }
        if updated != settings { settings = updated } else { applyPriorities() }
    }

    private func applyPriorities() {
        if settings.outputPriorityEnabled,
           let choice = AudioPriority.choice(in: settings.outputPriority, available: knownOutputs, current: outputs.first { $0.id == defaultOutput }?.uid),
           let device = outputs.first(where: { $0.uid == choice }) {
            SoundHardware.setDefault(kAudioHardwarePropertyDefaultOutputDevice, to: device.id)
        }
        if settings.inputPriorityEnabled,
           let choice = AudioPriority.choice(in: settings.inputPriority, available: knownInputs, current: inputs.first { $0.id == defaultInput }?.uid),
           let device = inputs.first(where: { $0.uid == choice }) {
            SoundHardware.setDefault(kAudioHardwarePropertyDefaultInputDevice, to: device.id)
        }
    }

    private func listenToInputs() {
        for device in inputs where !listenedInputs.contains(device.id) {
            listenedInputs.insert(device.id)
            for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                AudioProperty.listen(device.id, selector, SoundHardware.input) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.mic.isMuted else { return }
                        self.enforceMicMute()
                    }
                }
            }
        }
    }

    private func enforceMicMute() {
        let present = inputs
        let states = Dictionary(present.map { ($0.uid, SoundHardware.inputState(of: $0.id)) }, uniquingKeysWith: { first, _ in first })
        var claims = mic.claims
        claims.merge(MicMutePlan.newClaims(from: states, existing: claims)) { old, _ in old }
        for device in present {
            guard let saved = claims[device.uid], states[device.uid] != saved.silenced else { continue }
            SoundHardware.apply(saved.silenced, to: device.id)
        }
        if claims != mic.claims { mic.claims = claims }
    }

    private func restoreReturningMicrophones() {
        guard !mic.claims.isEmpty else { return }
        var claims = mic.claims
        for device in inputs {
            guard let saved = claims.removeValue(forKey: device.uid) else { continue }
            SoundHardware.apply(saved, to: device.id)
        }
        if claims != mic.claims { mic.claims = claims }
    }

    private func guardHeadphones() {
        guard settings.guardsHeadphones, let output = outputs.first(where: { $0.id == defaultOutput }) else { return }
        if output.isHeadphones {
            if let restore = headphoneGuard.reconnected(currentVolume: { uid in
                self.outputs.first { $0.uid == uid }.flatMap { SoundHardware.volume(of: $0.id) }
            }), let device = outputs.first(where: { $0.uid == restore.device }) {
                SoundHardware.setVolume(restore.volume, of: device.id)
            }
        } else if lastOutputWasHeadphones, let volume = SoundHardware.volume(of: output.id),
                  let lowered = headphoneGuard.disconnected(to: output.uid, volume: volume) {
            SoundHardware.setVolume(lowered, of: output.id)
            outputVolume = lowered
            messages.show("Headphones disconnected · volume lowered to \(Int(lowered * 100))%", for: 1.8)
        }
    }

    private func applyMusicBlocker() {
        if settings.blocksMusic, launchObserver == nil {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                                                               queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { if let app { self?.blockMusicIfNeeded(app) } }
            }
        } else if !settings.blocksMusic, let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
    }

    private func blockMusicIfNeeded(_ app: NSRunningApplication) {
        guard MusicBlocker.musicApps.contains(app.bundleIdentifier ?? ""),
              MusicBlocker.shouldBlock(launchedAt: ProcessInfo.processInfo.systemUptime, lastMediaKey: lastMediaKey) else { return }
        app.forceTerminate()
        if let replacement = settings.musicReplacement, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: replacement) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func applyTap() {
        let needsTap = (settings.handlesVolumeKeys || settings.blocksMusic) && AXIsProcessTrusted()
        guard needsTap != (tap != nil) else { return }
        if needsTap { startTap() } else { stopTap() }
    }

    private func startTap() {
        let mask = CGEventMask(1) << Self.systemDefinedEvent
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<SoundController>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { controller.handle(type, event) }
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                              callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let loopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = loopSource
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        consumedKeys.removeAll()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type.rawValue == Self.systemDefinedEvent, let system = NSEvent(cgEvent: event), system.subtype.rawValue == MediaKey.subtype,
              let key = MediaKey(data1: system.data1) else { return pass }
        if SoundKey.mediaKeys.contains(key.code) {
            if key.isDown { lastMediaKey = ProcessInfo.processInfo.systemUptime }
            return pass
        }
        guard settings.handlesVolumeKeys, [SoundKey.volumeUp, SoundKey.volumeDown, SoundKey.mute].contains(key.code) else { return pass }
        guard key.isDown else { return consumedKeys.remove(key.code) == nil ? pass : nil }
        guard let step = BrightnessKeys.step(for: event.flags, default: settings.volumeStep), let output = defaultOutput,
              SoundHardware.canSetVolume(of: output) else { return pass }
        consumedKeys.insert(key.code)
        if key.code == SoundKey.mute {
            let isMuted = !SoundHardware.isMuted(output)
            SoundHardware.setMuted(isMuted, of: output)
            showVolume(isMuted ? 0 : outputVolume ?? 0, isMuted: isMuted)
        } else {
            let next = step.next(from: SoundHardware.isMuted(output) ? 0 : outputVolume ?? 0, up: key.code == SoundKey.volumeUp)
            SoundHardware.setVolume(next, of: output)
            outputVolume = next
            showVolume(next, isMuted: next <= SoundHardware.muteThreshold)
        }
        return nil
    }

    private func showVolume(_ level: Double, isMuted: Bool) {
        let symbol = isMuted ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        hud.show(symbol: symbol, level: isMuted ? 0 : level, showsPercent: false, on: nil)
    }
}
