import AppKit
import IOKit.ps
import IOKit.pwr_mgt

protocol PowerAssertionProviding {
    func hold(displayOn: Bool, reason: String) -> UInt32?
    func release(_ id: UInt32)
}

struct SystemPowerAssertion: PowerAssertionProviding {
    func hold(displayOn: Bool, reason: String) -> UInt32? {
        var id: IOPMAssertionID = 0
        let type = displayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    func release(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }
}

enum KeepAwakeDuration: Hashable {
    case minutes(Int)
    case indefinitely
    case until(Date)

    static let presets: [KeepAwakeDuration] = [.minutes(15), .minutes(30), .minutes(60), .minutes(120), .minutes(240), .minutes(480), .indefinitely]

    func end(from now: Date) -> Date? {
        switch self {
        case .minutes(let minutes): now.addingTimeInterval(TimeInterval(minutes * 60))
        case .indefinitely: nil
        case .until(let date): date > now ? date : nil
        }
    }

    var title: String {
        switch self {
        case .minutes(let minutes): minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
        case .indefinitely: "Until I stop"
        case .until(let date): "Until \(date.formatted(date: .omitted, time: .shortened))"
        }
    }
}

struct PowerState: Equatable {
    var onBattery: Bool
    var batteryPercent: Int?
    var externalDisplay: Bool
    var screenLocked: Bool

    static func current() -> PowerState {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let battery = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        let percent = battery.flatMap { description -> Int? in
            guard let current = description[kIOPSCurrentCapacityKey] as? Int, let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
            return current * 100 / maximum
        }
        let onBattery = (battery?[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let external = NSScreen.screens.contains { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) == 0 } ?? false
        }
        return PowerState(onBattery: onBattery, batteryPercent: percent, externalDisplay: external, screenLocked: locked)
    }

    static var hasBattery: Bool { current().batteryPercent != nil }
}

enum KeepAwakeStop: Equatable {
    case timeUp, lowBattery
}

struct KeepAwakeSession: Equatable {
    let started: Date
    var ends: Date?
    let isAutomatic: Bool

    func stopReason(now: Date, power: PowerState, minimumBattery: Int?) -> KeepAwakeStop? {
        if let ends, now >= ends { return .timeUp }
        if let minimumBattery, power.onBattery, let percent = power.batteryPercent, percent < minimumBattery { return .lowBattery }
        return nil
    }

    func remaining(now: Date) -> TimeInterval? {
        ends.map { max(0, $0.timeIntervalSince(now)) }
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, total % 3600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct KeepAwakeRules: Codable, Equatable {
    var whenExternalDisplay = false
    var whenOnPower = false
    var apps: [String] = []
    var requireAll = false

    func matches(power: PowerState, runningApps: Set<String>) -> Bool {
        var conditions: [Bool] = []
        if whenExternalDisplay { conditions.append(power.externalDisplay) }
        if whenOnPower { conditions.append(!power.onBattery) }
        if !apps.isEmpty { conditions.append(apps.contains(where: runningApps.contains)) }
        guard !conditions.isEmpty else { return false }
        return requireAll ? conditions.allSatisfy { $0 } : conditions.contains(true)
    }
}

enum ClosedLidMode {
    static func set(_ isOn: Bool) {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(isOn ? 1 : 0)\" with administrator privileges"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

@MainActor
final class KeepAwake: ObservableObject {
    struct Settings: Codable, Equatable {
        var keepsDisplayOn = true
        var minimumBattery: Int? = 10
        var pausesWhenLocked = true
        var nudgesPointer = false
        var closedLid = false
        var rules = KeepAwakeRules()
    }

    static let settingsKey = "keepAwake.settings"
    static let tick: TimeInterval = 30
    static let nudgeAfter: TimeInterval = 50
    static let reason = "MacKit Keep Awake"

    @Published private(set) var session: KeepAwakeSession?
    @Published private(set) var isPausedForLock = false
    @Published var settings: Settings {
        didSet {
            defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if settings.keepsDisplayOn != oldValue.keepsDisplayOn, session != nil {
                releaseAssertion()
                holdAssertion()
            }
            evaluate()
        }
    }

    private let assertion: PowerAssertionProviding
    private let defaults: UserDefaults
    private let power: () -> PowerState
    private let runningApps: () -> Set<String>
    private var assertionID: UInt32?
    private var timer: Timer?
    private var closedLidActive = false

    init(assertion: PowerAssertionProviding = SystemPowerAssertion(), defaults: UserDefaults = .standard,
         power: @escaping () -> PowerState = PowerState.current,
         runningApps: @escaping () -> Set<String> = { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }) {
        self.assertion = assertion
        self.defaults = defaults
        self.power = power
        self.runningApps = runningApps
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate()
    }

    var isActive: Bool { session != nil }

    func toggle() {
        if isActive { stop() } else { start(.indefinitely) }
    }

    func start(_ duration: KeepAwakeDuration, automatic: Bool = false) {
        let now = Date()
        session = KeepAwakeSession(started: now, ends: duration.end(from: now), isAutomatic: automatic)
        holdAssertion()
        if settings.closedLid, !closedLidActive, PowerState.hasBattery {
            ClosedLidMode.set(true)
            closedLidActive = true
        }
    }

    func extend(by seconds: TimeInterval) {
        guard var current = session else { return }
        current.ends = (current.ends ?? Date()).addingTimeInterval(seconds)
        session = current
    }

    func stop() {
        session = nil
        releaseAssertion()
        if closedLidActive {
            ClosedLidMode.set(false)
            closedLidActive = false
        }
    }

    func evaluate() {
        let state = power()
        if let session {
            if session.stopReason(now: Date(), power: state, minimumBattery: settings.minimumBattery) != nil
                || (session.isAutomatic && !settings.rules.matches(power: state, runningApps: runningApps())) {
                return stop()
            }
            isPausedForLock = settings.pausesWhenLocked && state.screenLocked
            if isPausedForLock { releaseAssertion() } else { holdAssertion() }
            if settings.nudgesPointer, !state.screenLocked { nudgeIfIdle() }
        } else if settings.rules.matches(power: state, runningApps: runningApps()) {
            start(.indefinitely, automatic: true)
        }
    }

    private func holdAssertion() {
        guard assertionID == nil else { return }
        assertionID = assertion.hold(displayOn: settings.keepsDisplayOn, reason: Self.reason)
    }

    private func releaseAssertion() {
        guard let id = assertionID else { return }
        assertion.release(id)
        assertionID = nil
    }

    private func nudgeIfIdle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle > Self.nudgeAfter, let location = CGEvent(source: nil)?.location else { return }
        for point in [CGPoint(x: location.x + 1, y: location.y), location] {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
}

@MainActor
final class BluetoothSleepGuard: ObservableObject {
    static let key = "energy.bluetoothOffOnSleep"
    private typealias GetState = @convention(c) () -> Int32
    private typealias SetState = @convention(c) (Int32) -> Int32

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.key) }
    }

    private var turnedOff = false
    private var observers: [NSObjectProtocol] = []
    private let getState: GetState?
    private let setState: SetState?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
        let library = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
        getState = dlsym(library, "IOBluetoothPreferenceGetControllerPowerState").map { unsafeBitCast($0, to: GetState.self) }
        setState = dlsym(library, "IOBluetoothPreferenceSetControllerPowerState").map { unsafeBitCast($0, to: SetState.self) }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            },
        ]
    }

    var isAvailable: Bool { getState != nil && setState != nil }

    private func willSleep() {
        guard isEnabled, let getState, let setState, getState() == 1 else { return }
        _ = setState(0)
        turnedOff = true
    }

    private func didWake() {
        guard turnedOff, let setState else { return }
        _ = setState(1)
        turnedOff = false
    }
}
