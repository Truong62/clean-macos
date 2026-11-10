import AppKit
import ApplicationServices

struct WheelPacket {
    var continuous: Bool
    var phase: Int64
    var momentum: Int64
    var y: Double
    var x: Double
    var flags: CGEventFlags
    var point: CGPoint

    init(continuous: Bool, phase: Int64 = 0, momentum: Int64 = 0, y: Double, x: Double = 0, flags: CGEventFlags = [], point: CGPoint = .zero) {
        self.continuous = continuous
        self.phase = phase
        self.momentum = momentum
        self.y = y
        self.x = x
        self.flags = flags
        self.point = point
    }

    init(_ event: CGEvent) {
        func delta(_ point: CGEventField, _ fixed: CGEventField, _ whole: CGEventField) -> Double {
            let pixels = event.getDoubleValueField(point)
            let lines = event.getDoubleValueField(fixed)
            return pixels != 0 ? pixels : lines != 0 ? lines : event.getDoubleValueField(whole)
        }
        self.init(continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                  phase: event.getIntegerValueField(.scrollWheelEventScrollPhase), momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                  y: delta(.scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventDeltaAxis1),
                  x: delta(.scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis2), flags: event.flags, point: event.location)
    }
}

struct WheelClassifier {
    private var lastPhased: TimeInterval?

    mutating func isWheel(_ packet: WheelPacket, at time: TimeInterval) -> Bool {
        if packet.phase != 0 || packet.momentum != 0 {
            lastPhased = time
            return !packet.continuous
        }
        return !packet.continuous || lastPhased.map { time - $0 >= 1 } ?? true
    }
}

struct PinchEmission: Equatable {
    var phase: Int64
    var amount: Double
    var point: CGPoint
}

struct WheelPinchState {
    static let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
    private var point: CGPoint?
    private var modifier: ModifierChoice?

    static func matches(_ flags: CGEventFlags, modifier: ModifierChoice) -> Bool {
        guard modifier != .shift, let flag = modifier.flag else { return false }
        return flags.intersection(modifiers) == flag
    }

    mutating func tick(_ packet: WheelPacket, modifier: ModifierChoice, invertY: Bool, invertX: Bool) -> [PinchEmission] {
        guard Self.matches(packet.flags, modifier: modifier), packet.y != 0 || packet.x != 0 else { return [] }
        var result: [PinchEmission] = []
        if point != packet.point || self.modifier != modifier {
            result += end()
            point = packet.point
            self.modifier = modifier
            result.append(PinchEmission(phase: 1, amount: 0, point: packet.point))
        }
        let delta = packet.y != 0 ? packet.y * (invertY ? -1 : 1) : packet.x * (invertX ? -1 : 1)
        result.append(PinchEmission(phase: 2, amount: delta * 0.005, point: packet.point))
        return result
    }

    mutating func end() -> [PinchEmission] {
        defer { point = nil; modifier = nil }
        return point.map { [PinchEmission(phase: 4, amount: 0, point: $0)] } ?? []
    }
}

@MainActor
final class WheelPinchController {
    var settings = InputSettings() { didSet { emit(state.end()); apply() } }
    var cancelGlide: (() -> Void)?
    private var classifier = WheelClassifier()
    private var state = WheelPinchState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activeSession = true

    init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSession = false; self?.stop() }
        }
        center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSession = true; self?.apply() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func apply() {
        guard settings.wheelPinch, activeSession, AXIsProcessTrusted() else { stop(); return }
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.scrollWheel.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<WheelPinchController>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        emit(state.end())
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            emit(state.end())
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard AXIsProcessTrusted(), activeSession, InputEventGuard.consoleActive else { stop(); return pass }
        let packet = WheelPacket(event)
        let wheel = type == .scrollWheel ? classifier.isWheel(packet, at: ProcessInfo.processInfo.systemUptime) : false
        if !WheelPinchState.matches(event.flags, modifier: settings.pinchModifier) { emit(state.end()); return pass }
        guard type == .scrollWheel else { return pass }
        guard wheel, !InputEventGuard.excluded(event, apps: settings.excludedApps),
              event.getIntegerValueField(.eventSourceUserData) != InputController.marker else { return pass }
        let emissions = state.tick(packet, modifier: settings.pinchModifier, invertY: settings.invertVertical, invertX: settings.invertHorizontal)
        guard !emissions.isEmpty else { return pass }
        cancelGlide?()
        emit(emissions)
        return nil
    }

    private func emit(_ emissions: [PinchEmission]) {
        for emission in emissions {
            guard let event = CGEvent(source: nil), let type = CGEventType(rawValue: 29),
                  let kind = CGEventField(rawValue: 110), let phase = CGEventField(rawValue: 132), let amount = CGEventField(rawValue: 113) else { continue }
            event.type = type
            event.location = emission.point
            event.setIntegerValueField(kind, value: 8)
            event.setIntegerValueField(phase, value: emission.phase)
            event.setDoubleValueField(amount, value: emission.amount)
            event.setIntegerValueField(.eventSourceUserData, value: InputController.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

@MainActor
enum InputEventGuard {
    static var consoleActive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["kCGSessionOnConsoleKey"] as? Bool == true
    }

    static func excluded(_ event: CGEvent, apps: [String], checkPosting: Bool = true) -> Bool {
        let posting = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        if checkPosting && posting == getpid() { return true }
        if event.getIntegerValueField(.eventTargetUnixProcessID) == getpid() { return true }
        let postingID = NSRunningApplication(processIdentifier: posting)?.bundleIdentifier ?? ""
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let remote: Set<String> = ["com.teamviewer.TeamViewer", "com.philandro.anydesk", "com.carriez.rustdesk", "com.apple.ScreenContinuity", "com.apple.ScreenSharing"]
        if remote.contains(postingID) || remote.contains(frontID) { return true }
        if checkPosting && apps.contains(postingID) { return true }
        if apps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") { return true }
        if let window = AXWindow.at(event.location) {
            var pid: pid_t = 0
            AXUIElementGetPid(window, &pid)
            if pid == getpid() || apps.contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "") { return true }
        }
        return false
    }
}
