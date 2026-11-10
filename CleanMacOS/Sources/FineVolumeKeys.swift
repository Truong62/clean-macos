import AppKit
import ApplicationServices

struct VolumeBurstGate {
    private var lastAccepted = -TimeInterval.infinity
    private var direction: Int?
    private var oppositeCount = 0

    mutating func accepts(_ next: Int, at time: TimeInterval) -> Bool {
        guard time - lastAccepted >= 0.03 else { return false }
        if let direction, direction != next, time - lastAccepted < 0.3 {
            oppositeCount += 1
            guard oppositeCount >= 3 else { return false }
        } else { oppositeCount = 0 }
        direction = next
        oppositeCount = 0
        lastAccepted = time
        return true
    }
}

struct FineVolumePress {
    enum Decision: Equatable { case pass, swallow, step }
    private var presses: [Int: Bool] = [:]
    private var gate = VolumeBurstGate()

    mutating func handle(code: Int, down: Bool, repeated: Bool, modified: Bool, at time: TimeInterval) -> Decision {
        guard code == SoundKey.volumeUp || code == SoundKey.volumeDown else { return .pass }
        if !down { return presses.removeValue(forKey: code) == true ? .swallow : .pass }
        if presses[code] == nil {
            guard !repeated else { return .pass }
            presses[code] = !modified
        }
        guard presses[code] == true else { return .pass }
        return gate.accepts(code, at: time) ? .step : .swallow
    }
}

@MainActor
final class FineVolumeController: ObservableObject {
    static let eventTag: Int64 = 0x4D4B4656
    @Published private(set) var unavailable = false
    var onStep: ((Int) -> Bool)?
    private var enabled = false
    private var onConsole = true
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var press = FineVolumePress()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] { onConsole = session[kCGSessionOnConsoleKey as String] as? Bool ?? false }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, active) in [(NSWorkspace.sessionDidResignActiveNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onConsole = active; self?.refresh() }
            }
            observers.append((workspace, token))
        }
        let token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append((NotificationCenter.default, token))
    }

    func setEnabled(_ value: Bool, request: Bool) {
        enabled = value
        if value && request && !AXIsProcessTrusted() { PasteService.requestAccessibility() }
        refresh()
    }

    private func refresh() {
        stop()
        guard enabled, onConsole, AXIsProcessTrusted() else { unavailable = enabled; return }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<FineVolumeController>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { owner.handle(type, event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: CGEventMask(1) << 14, callback: callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else { unavailable = true; return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        unavailable = false
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        press = FineVolumePress()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.eventTag,
              let keyEvent = NSEvent(cgEvent: event), keyEvent.subtype.rawValue == MediaKey.subtype,
              let key = MediaKey(data1: keyEvent.data1) else { return pass }
        let decision = press.handle(code: key.code, down: key.isDown, repeated: keyEvent.data1 & 1 != 0,
                                    modified: !event.flags.intersection([.maskAlternate, .maskCommand, .maskControl]).isEmpty,
                                    at: ProcessInfo.processInfo.systemUptime)
        switch decision {
        case .pass: return pass
        case .swallow: return nil
        case .step:
            if onStep?(key.code) == true { return nil }
            for down in [true, false] {
                let data = (key.code << 16) | ((down ? 0xA : 0xB) << 8)
                let synthetic = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [.option, .shift], timestamp: 0,
                                                  windowNumber: 0, context: nil, subtype: MediaKey.subtype, data1: data, data2: -1)?.cgEvent
                synthetic?.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
                synthetic?.post(tap: .cghidEventTap)
            }
            return nil
        }
    }
}
