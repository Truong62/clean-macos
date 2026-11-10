import AppKit
import ApplicationServices
import KeyboardShortcuts

struct DisplayBrightness: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let identity: MonitorIdentity
    let name: String
    let isBuiltIn: Bool
    var route: BrightnessRoute
    var level: Double
    var isOn = true

    var key: String { identity.key }
}

struct BrightnessSettings: Codable, Equatable {
    var isEnabled = false
    var handlesKeys = true
    var keysFollowPointer = false
    var step = LevelStep.standard
    var showsPercentage = false
    var shortcutsEnabled = false
    var keyboardShortcutsEnabled = false
    var picturePreferred: Set<String> = []
    var extraDimming: Set<String> = []
    var xdrEnabled = false
    var xdrLevel = 1.0
}

@MainActor
final class BrightnessController: ObservableObject {
    static let settingsKey = "brightness.settings"
    static let levelsKey = "brightness.levels"
    static let wakeSettle: TimeInterval = 3
    static let reconfigureDelay: TimeInterval = 0.5
    static let minimumPicture = 0.1
    nonisolated static let returningLevel = 0.25
    static let systemDefinedEvent: UInt32 = 14
    static let keyboardStep: Float = 1.0 / 16
    static let displayShortcuts: [KeyboardShortcuts.Name] = [.displayBrightnessUp, .displayBrightnessDown]
    static let keyboardShortcuts: [KeyboardShortcuts.Name] = [.keyboardLightUp, .keyboardLightDown]

    @Published var settings: BrightnessSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            apply(previous: oldValue)
        }
    }
    @Published private(set) var displays: [DisplayBrightness] = []
    @Published private(set) var isScanning = false

    let keyboard = KeyboardBacklight()
    let xdr = XDRBooster()
    private var levels: [String: Double]
    private var channels: [CGDirectDisplayID: DDCChannel] = [:]
    private var maxima: [CGDirectDisplayID: UInt16] = [:]
    private var originals: [String: GammaTable] = [:]
    private var pending: [CGDirectDisplayID: Double] = [:]
    private var busy: Set<CGDirectDisplayID> = []
    private var disabled: [CGDirectDisplayID: DisplayBrightness] = [:]
    private var consumedKeys: Set<Int> = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var reconfigureWork: DispatchWorkItem?
    private var scanToken = 0
    private let queue = DispatchQueue(label: "mackit.brightness", qos: .userInitiated)
    private let hud = LevelHUD()

    init() {
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(BrightnessSettings.self, from: $0) } ?? BrightnessSettings()
        levels = defaults.dictionary(forKey: Self.levelsKey) as? [String: Double] ?? [:]
        KeyboardShortcuts.onKeyUp(for: .displayBrightnessUp) { [weak self] in MainActor.assumeIsolated { self?.stepDisplay(up: true) } }
        KeyboardShortcuts.onKeyUp(for: .displayBrightnessDown) { [weak self] in MainActor.assumeIsolated { self?.stepDisplay(up: false) } }
        KeyboardShortcuts.onKeyUp(for: .keyboardLightUp) { [weak self] in MainActor.assumeIsolated { self?.stepKeyboard(up: true) } }
        KeyboardShortcuts.onKeyUp(for: .keyboardLightDown) { [weak self] in MainActor.assumeIsolated { self?.stepKeyboard(up: false) } }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh(after: Self.reconfigureDelay) }
            }),
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh(after: Self.wakeSettle) }
            }),
            (NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTap() }
            }),
        ]
        apply(previous: nil)
    }

    func setLevel(_ level: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(level, 0), 1)
        displays[index].level = clamped
        let display = displays[index]
        levels[display.key] = clamped
        UserDefaults.standard.set(levels, forKey: Self.levelsKey)
        switch display.route {
        case .system:
            DisplayServicesBridge.setBrightness(clamped, of: id)
        case .ddc:
            let split = BrightnessSplit(level: clamped, extraDimming: settings.extraDimming.contains(display.key))
            queueHardware(split.hardware, for: id)
            dimPicture(split.picture, display)
        case .picture:
            dimPicture(clamped, display)
        }
    }

    func setPower(_ isOn: Bool, for id: CGDirectDisplayID) {
        if !isOn {
            guard displays.filter(\.isOn).count > 1 else {
                hud.show(symbol: "exclamationmark.triangle.fill", level: 0, showsPercent: false, on: nil)
                return NSSound.beep()
            }
        }
        guard DisplayPower.set(id, enabled: isOn) else { return NSSound.beep() }
        if isOn {
            disabled.removeValue(forKey: id)
        } else if var display = displays.first(where: { $0.id == id }) {
            display.isOn = false
            disabled[id] = display
        }
        scheduleRefresh(after: Self.reconfigureDelay)
    }

    func togglePicturePreferred(_ display: DisplayBrightness) {
        settings.picturePreferred.formSymmetricDifference([display.key])
    }

    func toggleExtraDimming(_ display: DisplayBrightness) {
        settings.extraDimming.formSymmetricDifference([display.key])
    }

    private func apply(previous: BrightnessSettings?) {
        Self.toggle(Self.displayShortcuts, on: settings.isEnabled && settings.shortcutsEnabled, was: previous.map { $0.isEnabled && $0.shortcutsEnabled })
        Self.toggle(Self.keyboardShortcuts, on: settings.keyboardShortcutsEnabled, was: previous?.keyboardShortcutsEnabled)
        xdr.level = settings.xdrLevel
        if settings.isEnabled && settings.xdrEnabled { xdr.start() } else { xdr.stop() }
        let needsScan = previous?.isEnabled != settings.isEnabled || previous?.picturePreferred != settings.picturePreferred
        if !settings.isEnabled {
            PictureDimmer.restoreAll()
            originals.removeAll()
            displays = []
        } else if needsScan {
            refresh()
        } else if previous?.extraDimming != settings.extraDimming {
            displays.forEach { setLevel($0.level, for: $0.id) }
        }
        applyTap()
    }

    private static func toggle(_ names: [KeyboardShortcuts.Name], on: Bool, was: Bool?) {
        guard on != was else { return }
        if on { KeyboardShortcuts.enable(names) } else { KeyboardShortcuts.disable(names) }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        reconfigureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        reconfigureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func refresh() {
        guard settings.isEnabled else { return }
        scanToken += 1
        let token = scanToken
        let screens = NSScreen.screens.compactMap { screen in screen.displayID.map { (id: $0, name: screen.localizedName) } }
        let preferred = settings.picturePreferred
        let extra = settings.extraDimming
        let saved = levels
        isScanning = true
        queue.async {
            let found = DDCDiscovery.channels()
            let identities = screens.map { DDCDiscovery.identity(of: $0.id, name: $0.name) }
            let systemLevels = screens.map { CGDisplayIsAsleep($0.id) != 0 ? nil : DisplayServicesBridge.brightness(of: $0.id) }
            let externals = screens.indices.filter { systemLevels[$0] == nil }
            let pairs = MonitorMatcher.pair(externals.map { identities[$0] }, with: found.map(\.identity))
            var rows: [DisplayBrightness] = []
            var routed: [CGDirectDisplayID: DDCChannel] = [:]
            var maxima: [CGDirectDisplayID: UInt16] = [:]
            for (index, screen) in screens.enumerated() {
                let key = identities[index].key
                var probe = DDCProbe.none
                if let position = externals.firstIndex(of: index), let channelIndex = pairs[position], !preferred.contains(key) {
                    let channel = found[channelIndex].channel
                    probe = channel.probe()
                    routed[screen.id] = channel
                }
                let route = BrightnessRoute.choose(systemLevel: systemLevels[index], probe: probe, forcesPicture: preferred.contains(key))
                let level: Double
                switch (route, probe) {
                case (.system, _):
                    level = systemLevels[index] ?? 1
                case (.ddc, .live(let reading)):
                    level = BrightnessSplit.level(hardware: reading.level, extraDimming: extra.contains(key))
                    maxima[screen.id] = reading.maximum
                default:
                    level = max(saved[key] ?? 1, route == .picture ? Self.returningLevel : 0)
                }
                rows.append(DisplayBrightness(id: screen.id, identity: identities[index], name: screen.name, isBuiltIn: CGDisplayIsBuiltin(screen.id) != 0,
                                              route: route, level: level))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishRefresh(rows, channels: routed.filter { id, _ in rows.contains { $0.id == id && $0.route == .ddc } },
                                                              maxima: maxima, token: token) }
            }
        }
    }

    private func finishRefresh(_ rows: [DisplayBrightness], channels: [CGDirectDisplayID: DDCChannel], maxima: [CGDirectDisplayID: UInt16], token: Int) {
        guard token == scanToken, settings.isEnabled else { return }
        self.channels = channels
        self.maxima = maxima
        disabled = disabled.filter { id, _ in !rows.contains { $0.id == id } }
        displays = rows + disabled.values.sorted { $0.name < $1.name }
        isScanning = false
        for display in rows where display.route != .system {
            let split = display.route == .picture ? BrightnessSplit(hardware: 0, picture: display.level)
                : BrightnessSplit(level: display.level, extraDimming: settings.extraDimming.contains(display.key))
            if split.picture < GammaTable.fullThreshold || originals[display.key] != nil { dimPicture(split.picture, display) }
        }
    }

    private func queueHardware(_ hardware: Double, for id: CGDirectDisplayID) {
        pending[id] = hardware
        guard !busy.contains(id), let channel = channels[id] else { return }
        busy.insert(id)
        sendHardware(id, channel)
    }

    private func sendHardware(_ id: CGDirectDisplayID, _ channel: DDCChannel) {
        guard let hardware = pending.removeValue(forKey: id) else {
            busy.remove(id)
            return
        }
        let value = DDC.value(for: hardware, maximum: maxima[id] ?? DDC.defaultMaximum)
        queue.async {
            _ = channel.write(DDC.brightness, value: value)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.sendHardware(id, channel) }
            }
        }
    }

    private func dimPicture(_ factor: Double, _ display: DisplayBrightness) {
        if originals[display.key] == nil {
            guard factor < GammaTable.fullThreshold, let table = PictureDimmer.currentTable(for: display.id) else { return }
            originals[display.key] = table
        }
        guard let original = originals[display.key] else { return }
        let gain = factor < GammaTable.fullThreshold ? max(factor, Self.minimumPicture) : 1
        PictureDimmer.apply(original.scaled(by: gain), to: display.id)
    }

    private func applyTap() {
        let needsTap = settings.isEnabled && settings.handlesKeys && AXIsProcessTrusted()
        guard needsTap != (tap != nil) else { return }
        if needsTap { startTap() } else { stopTap() }
    }

    private func startTap() {
        let mask = CGEventMask(1) << Self.systemDefinedEvent
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<BrightnessController>.fromOpaque(refcon).takeUnretainedValue()
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
              let key = MediaKey(data1: system.data1), key.code == MediaKey.brightnessUp || key.code == MediaKey.brightnessDown else { return pass }
        guard key.isDown else { return consumedKeys.remove(key.code) == nil ? pass : nil }
        guard let step = BrightnessKeys.step(for: event.flags, default: settings.step), let target = keyTarget(),
              BrightnessKeys.handles(route: target.route, isBuiltIn: target.isBuiltIn) else { return pass }
        consumedKeys.insert(key.code)
        adjust(target, step: step, up: key.code == MediaKey.brightnessUp)
        return nil
    }

    private func keyTarget() -> DisplayBrightness? {
        let pointer = NSEvent.mouseLocation
        let screen = settings.keysFollowPointer ? NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } : NSScreen.main
        guard let id = screen?.displayID else { return nil }
        return displays.first { $0.id == id && $0.isOn }
    }

    private func adjust(_ display: DisplayBrightness, step: LevelStep, up: Bool) {
        let next = step.next(from: display.level, up: up)
        setLevel(next, for: display.id)
        hud.show(symbol: "sun.max.fill", level: next, showsPercent: settings.showsPercentage, on: NSScreen.screens.first { $0.displayID == display.id })
    }

    private func stepDisplay(up: Bool) {
        guard settings.isEnabled, let target = keyTarget() else { return NSSound.beep() }
        adjust(target, step: settings.step, up: up)
    }

    private func stepKeyboard(up: Bool) {
        guard let current = keyboard.brightness else { return NSSound.beep() }
        let next = min(max(current + (up ? Self.keyboardStep : -Self.keyboardStep), 0), 1)
        keyboard.set(next)
        hud.show(symbol: "light.max", level: Double(next), showsPercent: settings.showsPercentage, on: nil)
    }
}
