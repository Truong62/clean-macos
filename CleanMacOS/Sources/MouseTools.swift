import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct MouseShortcut: Codable, Equatable, Identifiable {
    var button: Int
    var key: UInt16
    var flags: UInt64
    var id: Int { button }

    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    static let navigationKeys: Set<UInt16> = [115, 119, 116, 121, 117, 123, 124, 125, 126]
    static let keypadKeys: Set<UInt16> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    static func valid(key: UInt16, flags: CGEventFlags) -> Bool {
        guard key <= 127 else { return false }
        let modifiers = flags.intersection(WheelPinchState.modifiers)
        return !modifiers.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty || (modifiers.isEmpty && functionKeys.contains(key))
    }

    var postingFlags: CGEventFlags {
        var result = CGEventFlags(rawValue: flags)
        if Self.functionKeys.contains(key) || Self.navigationKeys.contains(key) { result.insert(.maskSecondaryFn) }
        if Self.keypadKeys.contains(key) || (123...126).contains(key) { result.insert(.maskNumericPad) }
        return result
    }

    static func title(_ button: Int) -> String {
        switch button {
        case -1: "Wheel left"
        case -2: "Wheel right"
        case 2: "Middle button"
        case 3: "Back"
        case 4: "Forward"
        default: "Button \(button + 1)"
        }
    }
}

struct MouseToolsSettings: Codable, Equatable {
    var shortcutsEnabled = false
    var shortcuts: [MouseShortcut] = []
    var spacesEnabled = false
    var spacesButton: Int?
    var naturalSpaces = false
}

struct SideWheelBurst {
    private var lastTime: TimeInterval?
    private var direction: Int?

    mutating func packet(x: Double, y: Double, at time: TimeInterval) -> (button: Int, fire: Bool)? {
        guard x != 0, abs(x) > abs(y) else { return nil }
        let button = x > 0 ? -1 : -2
        let fire = direction != button || lastTime.map { time - $0 >= 0.25 } ?? true
        lastTime = time
        direction = button
        return (button, fire)
    }
}

enum SpacesAction: Int, Equatable, CaseIterable {
    case left = 79, right = 81, missionControl = 32, appExpose = 33
}

struct SpacesDragState {
    enum Axis { case horizontal, vertical }
    private(set) var axis: Axis?
    private(set) var fired = false
    private var origin: CGPoint
    private var last: CGPoint
    private var bank: Double = 0
    private var lastSwitch: TimeInterval?

    init(point: CGPoint) { origin = point; last = point }

    mutating func restoreFired(_ value: Bool) { fired = value }

    mutating func move(to point: CGPoint, at time: TimeInterval, natural: Bool) -> SpacesAction? {
        defer { last = point }
        if axis == nil {
            let x = point.x - origin.x
            let y = point.y - origin.y
            guard abs(x) >= 220 || abs(y) >= 150 else { return nil }
            axis = abs(x) / 220 >= abs(y) / 150 ? .horizontal : .vertical
            if axis == .vertical {
                fired = true
                return y < 0 ? .missionControl : .appExpose
            }
            bank = x
        } else if axis == .horizontal {
            bank += point.x - last.x
        }
        guard axis == .horizontal else { return nil }
        if let lastSwitch, time - lastSwitch < 0.35 {
            bank = min(220, max(-220, bank))
            return nil
        }
        guard abs(bank) >= 220 else { return nil }
        let right = bank > 0
        bank -= right ? 220 : -220
        bank = min(220, max(-220, bank))
        lastSwitch = time
        fired = true
        return right != natural ? .right : .left
    }
}

enum SymbolicMouseKeys {
    typealias Enabled = @convention(c) (Int32) -> Bool
    typealias Value = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt64>) -> Int32
    static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)

    static func stroke(_ action: SpacesAction) -> MouseShortcut? {
        guard let handle, let enabledSymbol = dlsym(handle, "CGSIsSymbolicHotKeyEnabled"), let valueSymbol = dlsym(handle, "CGSGetSymbolicHotKeyValue") else { return nil }
        let enabled = unsafeBitCast(enabledSymbol, to: Enabled.self)
        let value = unsafeBitCast(valueSymbol, to: Value.self)
        guard enabled(Int32(action.rawValue)) else { return nil }
        var character: UInt32 = 0
        var key: UInt32 = 0
        var flags: UInt64 = 0
        guard value(Int32(action.rawValue), &character, &key, &flags) == 0, key <= 127 else { return nil }
        return MouseShortcut(button: 0, key: UInt16(key), flags: UInt64(flags))
    }

    static func post(_ shortcut: MouseShortcut) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: down)
            event?.flags = shortcut.postingFlags
            event?.setIntegerValueField(.eventSourceUserData, value: InputController.marker)
            event?.post(tap: .cghidEventTap)
        }
    }
}

@MainActor
final class MouseToolsController: ObservableObject {
    static var capturing = false
    static var reservedButtons: Set<Int> = []
    static var assignedButtons: Set<Int> = []
    @Published var settings: MouseToolsSettings {
        didSet {
            if !settings.spacesEnabled { settings.spacesButton = nil }
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "mouseTools.settings")
            apply()
        }
    }
    @Published private(set) var captureMessage: String?
    @Published private(set) var allSpacesHotkeysOff = false
    var inputSettings: () -> InputSettings = { InputSettings() }
    private var captureSpaces = false
    private var capturedButton: Int?
    private var held: Set<Int> = []
    private var keyReleases: Set<Int64> = []
    private var drag: SpacesDragState?
    private var dragButton: Int?
    private var heldDown: CGEvent?
    private var burst = SideWheelBurst()
    private var wheelClassifier = WheelClassifier()
    private var activeTypes: [CGEventType] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var active = true
    private var permissionTimer: Timer?

    init() {
        settings = UserDefaults.standard.data(forKey: "mouseTools.settings").flatMap { try? JSONDecoder().decode(MouseToolsSettings.self, from: $0) } ?? MouseToolsSettings()
        apply()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active = false; self?.stop() }
        }
        center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active = true; self?.apply() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func enablePermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        allSpacesHotkeysOff = SpacesAction.allCases.allSatisfy { SymbolicMouseKeys.stroke($0) == nil }
        apply()
    }

    func capture(spaces: Bool) {
        guard AXIsProcessTrusted() else { captureMessage = "Allow Accessibility to watch this mouse."; enablePermission(); return }
        captureSpaces = spaces
        capturedButton = nil
        Self.capturing = true
        captureMessage = spaces ? "Press a middle or extra mouse button. Escape cancels." : "Press an extra mouse button or tilt the wheel. Escape cancels."
        apply()
        if tap == nil { Self.capturing = false; captureMessage = "This mouse cannot be watched. Check Accessibility access." }
    }

    func cancelCapture() {
        Self.capturing = false
        capturedButton = nil
        captureMessage = nil
        apply()
    }

    private func apply() {
        Self.assignedButtons = Set(settings.shortcutsEnabled ? settings.shortcuts.map(\.button) : [])
        if settings.spacesEnabled, let button = settings.spacesButton { Self.assignedButtons.insert(button) }
        guard active, InputEventGuard.consoleActive, AXIsProcessTrusted() else { stop(); return }
        let needed = settings.shortcutsEnabled || settings.spacesEnabled || Self.capturing || !held.isEmpty || !keyReleases.isEmpty
        guard needed else { stop(); return }
        var types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged]
        if Self.capturing || Self.assignedButtons.contains(-1) || Self.assignedButtons.contains(-2) { types.append(.scrollWheel) }
        if Self.capturing || !keyReleases.isEmpty { types += [.keyDown, .keyUp] }
        guard tap == nil || activeTypes != types else { return }
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        permissionTimer?.invalidate()
        tap = nil
        source = nil
        activeTypes = types
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated { Unmanaged<MouseToolsController>.fromOpaque(context).takeUnretainedValue().handle(type, event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private func stop() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        activeTypes = []
        permissionTimer?.invalidate()
        permissionTimer = nil
        held = []
        heldDown = nil
        drag = nil
        dragButton = nil
        keyReleases = []
        Self.capturing = false
    }

    private func captureButton(_ button: Int) {
        guard !Self.reservedButtons.contains(button), !settings.shortcuts.contains(where: { $0.button == button }),
              settings.spacesButton != button else { captureMessage = "That button is already assigned."; return }
        if captureSpaces {
            guard (2...31).contains(button) else { captureMessage = "Choose a middle or extra mouse button."; return }
            settings.spacesButton = button
            cancelCapture()
        } else {
            guard (3...31).contains(button) || button == -1 || button == -2 else { captureMessage = "Choose an extra button or tilt the wheel."; return }
            capturedButton = button
            captureMessage = "Now press a shortcut with ⌃, ⌥ or ⌘, or a bare F1–F20."
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            held = held.filter { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32($0))!) }
            if let button = dragButton, !held.contains(button) { drag = nil; dragButton = nil; heldDown = nil }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard AXIsProcessTrusted(), InputEventGuard.consoleActive else { stop(); return pass }
        guard event.getIntegerValueField(.eventSourceUserData) != InputController.marker else { return pass }
        let now = ProcessInfo.processInfo.systemUptime
        if type == .keyUp {
            let swallowed = keyReleases.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil
            if swallowed { apply() }
            return swallowed ? nil : pass
        }
        if type == .keyDown {
            guard Self.capturing else { return pass }
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if key == 53 { keyReleases.insert(key); cancelCapture(); return nil }
            guard let button = capturedButton, MouseShortcut.valid(key: UInt16(key), flags: event.flags) else { return pass }
            keyReleases.insert(key)
            settings.shortcuts.append(MouseShortcut(button: button, key: UInt16(key), flags: event.flags.intersection(WheelPinchState.modifiers).rawValue))
            cancelCapture()
            return nil
        }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if type == .otherMouseUp, held.remove(button) != nil {
            let didFire = drag?.fired ?? true
            if button == dragButton {
                if !didFire, let down = heldDown {
                    down.location = event.location
                    down.timestamp = DispatchTime.now().uptimeNanoseconds
                    down.setIntegerValueField(.eventSourceUserData, value: InputController.marker)
                    down.post(tap: .cgSessionEventTap)
                    event.setIntegerValueField(.eventSourceUserData, value: InputController.marker)
                    event.post(tap: .cgSessionEventTap)
                }
                drag = nil; dragButton = nil; heldDown = nil
            }
            apply()
            return nil
        }
        if type == .otherMouseDragged, held.contains(button) {
            let wasFired = drag?.fired ?? false
            if button == dragButton, let action = drag?.move(to: event.location, at: now, natural: settings.naturalSpaces) {
                if let stroke = SymbolicMouseKeys.stroke(action) { SymbolicMouseKeys.post(stroke) }
                else { drag?.restoreFired(wasFired) }
            }
            return nil
        }
        let input = inputSettings()
        guard !InputEventGuard.excluded(event, apps: input.excludedApps) || Self.capturing else { return pass }
        if type == .scrollWheel {
            let packet = WheelPacket(event)
            guard wheelClassifier.isWheel(packet, at: now) else { return pass }
            guard let burst = burst.packet(x: packet.x * (input.invertHorizontal ? -1 : 1), y: packet.y * (input.invertVertical ? -1 : 1), at: now) else { return pass }
            if Self.capturing { if burst.fire { captureButton(burst.button) }; return nil }
            guard settings.shortcutsEnabled, let shortcut = settings.shortcuts.first(where: { $0.button == burst.button }) else { return pass }
            if burst.fire { SymbolicMouseKeys.post(shortcut) }
            return nil
        }
        guard type == .otherMouseDown else { return pass }
        if Self.capturing {
            guard (3...31).contains(button) || (captureSpaces && button == 2) else { return pass }
            held.insert(button)
            captureButton(button)
            return nil
        }
        guard !Self.reservedButtons.contains(button) else { return pass }
        if held.contains(button) { return nil }
        if settings.shortcutsEnabled, let shortcut = settings.shortcuts.first(where: { $0.button == button }) {
            SymbolicMouseKeys.post(shortcut)
            held.insert(button)
            return nil
        }
        if settings.spacesEnabled, settings.spacesButton == button {
            drag = SpacesDragState(point: event.location)
            dragButton = button
            heldDown = event.copy()
            held.insert(button)
            return nil
        }
        return pass
    }
}
