import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class InputController: ObservableObject {
    static let settingsKey = "input.settings"
    static let marker: Int64 = 0x4D4B_494E
    static let pixelsPerStep: Double = 40
    static let pointsPerLine: Double = 10
    static let smoothResponse = 0.25
    static let frame: TimeInterval = 1.0 / 60
    static let guardTick: TimeInterval = 0.05
    static let protectedKeys: [Int: String] = [kVK_ANSI_Q: "Q", kVK_ANSI_W: "W"]
    static let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    nonisolated static let focusableSubroles: Set<String> = [kAXStandardWindowSubrole, kAXDialogSubrole]

    @Published var settings: InputSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            resetState()
            applyTap()
        }
    }
    @Published private(set) var isCleaning = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activeTypes: [CGEventType] = []
    private var isHyperMapped = false
    private var clicks = Debouncer(threshold: 0)
    private var keys = Debouncer(threshold: 0)
    private var guards: [Int: QuitGuard] = [:]
    private var guardTimer: Timer?
    private var smooth = SmoothScroll(response: InputController.smoothResponse)
    private var smoothTimer: Timer?
    private var hyperDown = false
    private var hyperUsed = false
    private var swallowedButtons: Set<Int64> = []
    private var focusWork: DispatchWorkItem?
    private let focusQueue = DispatchQueue(label: "mackit.input.focus", qos: .userInteractive)
    private let hud = InputHUD()
    private let cleaning = CleaningMode()

    init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(InputSettings.self, from: $0) } ?? InputSettings()
        cleaning.onFinish = { [weak self] in self?.isCleaning = false }
        HyperKeyMapping.restoreIfNeeded()
        resetState()
        applyTap()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTap() }
        }
    }

    func startCleaning() {
        isCleaning = true
        cleaning.start()
    }

    private func resetState() {
        clicks = Debouncer(threshold: TimeInterval(settings.clickDebounceMs) / 1000)
        keys = Debouncer(threshold: TimeInterval(settings.keyDebounceMs) / 1000)
        guards = [kVK_ANSI_Q: QuitGuard(mode: settings.quitProtection), kVK_ANSI_W: QuitGuard(mode: settings.closeProtection)]
    }

    private func applyTap() {
        let types = AXIsProcessTrusted() ? settings.eventTypes : []
        if types != activeTypes {
            stopTap()
            if !types.isEmpty { startTap(types) }
            activeTypes = tap == nil ? [] : types
        }
        let wantsHyper = settings.hyperKey && tap != nil
        guard wantsHyper != isHyperMapped else { return }
        HyperKeyMapping.set(wantsHyper)
        isHyperMapped = wantsHyper
    }

    private func startTap(_ types: [CGEventType]) {
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<InputController>.fromOpaque(refcon).takeUnretainedValue()
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
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker, !isExcludedAppActive else { return pass }
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .scrollWheel:
            return scroll(event) ? nil : pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return press(event, now: now) ? nil : pass
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            clicks.record(key: Int(number), isDown: false, at: now)
            return swallowedButtons.remove(number) == nil ? pass : nil
        case .keyDown, .keyUp:
            return key(event, isDown: type == .keyDown, now: now) ? nil : pass
        case .mouseMoved:
            scheduleFocus(at: event.location)
            return pass
        default:
            return pass
        }
    }

    private var isExcludedAppActive: Bool {
        !settings.excludedApps.isEmpty && settings.excludedApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }

    private func scroll(_ event: CGEvent) -> Bool {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let lineY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let lineX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        switch ScrollTransform.apply(ScrollInput(deltaY: lineY, deltaX: lineX, isContinuous: continuous, flags: event.flags), settings: settings) {
        case .zoom(let zoomIn):
            post(KeyStroke(keyCode: CGKeyCode(zoomIn ? kVK_ANSI_Equal : kVK_ANSI_Minus), flags: .maskCommand))
            return true
        case .scroll(let deltaY, let deltaX):
            if glide(deltaY: deltaY, deltaX: deltaX) { return true }
            rewrite(event, deltaY: deltaY, deltaX: deltaX, lineY: lineY, lineX: lineX)
            return false
        case .pass:
            return !continuous && glide(deltaY: lineY, deltaX: lineX)
        }
    }

    private func rewrite(_ event: CGEvent, deltaY: Double, deltaX: Double, lineY: Double, lineX: Double) {
        let line = lineY != 0 ? lineY : lineX
        let point = Double(event.getIntegerValueField(lineY != 0 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2))
        let pointsPerLine = line == 0 || point == 0 ? Self.pointsPerLine : abs(point / line)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltaX)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(deltaY.rounded()))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(deltaX.rounded()))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64((deltaY * pointsPerLine).rounded()))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64((deltaX * pointsPerLine).rounded()))
    }

    private func glide(deltaY: Double, deltaX: Double) -> Bool {
        guard settings.smoothScroll, deltaY != 0, deltaX == 0 else { return false }
        smooth.add(deltaY * Self.pixelsPerStep)
        startSmoothTimer()
        return true
    }

    private func startSmoothTimer() {
        guard smoothTimer == nil else { return }
        smoothTimer = Timer.scheduledTimer(withTimeInterval: Self.frame, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.smooth.isActive else {
                    timer.invalidate()
                    self?.smoothTimer = nil
                    return
                }
                let pixels = Int32(self.smooth.step().rounded())
                guard pixels != 0 else { return }
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)
                event?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                event?.post(tap: .cgSessionEventTap)
            }
        }
    }

    private func press(_ event: CGEvent, now: TimeInterval) -> Bool {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        if clicks.shouldDrop(key: Int(number), isDown: true, at: now) {
            swallowedButtons.insert(number)
            return true
        }
        guard let action = settings.action(forButton: Int(number)) else { return false }
        post(action.keystroke)
        swallowedButtons.insert(number)
        return true
    }

    private func key(_ event: CGEvent, isDown: Bool, now: TimeInterval) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if settings.hyperKey, keyCode == HyperKeyMapping.f18KeyCode {
            hyper(isDown: isDown, repeating: repeating)
            return true
        }
        if hyperDown {
            event.flags.formUnion(Self.hyperFlags)
            hyperUsed = true
            return false
        }
        if !repeating {
            if keys.shouldDrop(key: keyCode, isDown: isDown, at: now) { return true }
            keys.record(key: keyCode, isDown: isDown, at: now)
        }
        return protect(event, keyCode: keyCode, isDown: isDown, repeating: repeating, now: now)
    }

    private func hyper(isDown: Bool, repeating: Bool) {
        if !isDown {
            hyperDown = false
            if !hyperUsed && settings.hyperTapsEscape { post(KeyStroke(keyCode: CGKeyCode(kVK_Escape), flags: [])) }
        } else if !repeating {
            hyperDown = true
            hyperUsed = false
        }
    }

    private func protect(_ event: CGEvent, keyCode: Int, isDown: Bool, repeating: Bool, now: TimeInterval) -> Bool {
        guard let letter = Self.protectedKeys[keyCode], var guardState = guards[keyCode], guardState.mode != .off else { return false }
        defer { guards[keyCode] = guardState }
        if !isDown { return guardState.isWaiting }
        let flags = event.flags
        guard flags.contains(.maskCommand), flags.isDisjoint(with: [.maskControl, .maskAlternate]) else { return false }
        if repeating { return true }
        let verb = letter == "Q" ? "quit" : "close"
        if guardState.mode == .shift {
            if flags.contains(.maskShift) {
                post(KeyStroke(keyCode: CGKeyCode(keyCode), flags: .maskCommand))
            } else {
                hud.show("Press ⌘⇧\(letter) to \(verb)")
            }
            return true
        }
        switch guardState.keyDown(at: now) {
        case .allow:
            return false
        case .wait:
            hud.show("Keep holding ⌘\(letter) to \(verb)…", for: guardState.hold)
            startGuardTimer(keyCode, letter: letter)
            return true
        case .remind, .cancel:
            hud.show("Press ⌘\(letter) again to \(verb)")
            return true
        }
    }

    private func startGuardTimer(_ keyCode: Int, letter: String) {
        guardTimer?.invalidate()
        guardTimer = Timer.scheduledTimer(withTimeInterval: Self.guardTick, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, var guardState = self.guards[keyCode], guardState.isWaiting else { return timer.invalidate() }
                let now = ProcessInfo.processInfo.systemUptime
                let isHeld = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
                    && CGEventSource.flagsState(.hidSystemState).contains(.maskCommand)
                let decision = isHeld ? guardState.tick(at: now) : guardState.keyUp(at: now)
                self.guards[keyCode] = guardState
                if decision == .allow { self.post(KeyStroke(keyCode: CGKeyCode(keyCode), flags: .maskCommand)) }
                if decision == .cancel { self.hud.show("Hold ⌘\(letter) a little longer", for: 0.8) }
                if !guardState.isWaiting { timer.invalidate() }
            }
        }
    }

    private func scheduleFocus(at point: CGPoint) {
        focusWork?.cancel()
        let raises = settings.raisesOnFocus
        let work = DispatchWorkItem { Self.focusWindow(at: point, raises: raises) }
        focusWork = work
        focusQueue.asyncAfter(deadline: .now() + .milliseconds(settings.focusDelayMs), execute: work)
    }

    nonisolated private static func focusWindow(at point: CGPoint, raises: Bool) {
        guard NSEvent.pressedMouseButtons == 0, let window = AXWindow.at(point),
              let subrole: String = AXWindow.value(window, kAXSubroleAttribute), focusableSubroles.contains(subrole) else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid) else { return }
        if raises {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if !app.isActive { app.activate() }
    }

    private func post(_ stroke: KeyStroke) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: stroke.keyCode, keyDown: isDown)
            event?.flags = stroke.flags
            event?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event?.post(tap: .cghidEventTap)
        }
    }
}

@MainActor
final class CleaningMode {
    static let presses = 5
    static let escape = Int64(kVK_Escape)
    static let systemDefinedMask: CGEventMask = 1 << 14

    var onFinish: (() -> Void)?
    private var windows: [NSWindow] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let state = CleaningState()

    func start() {
        guard windows.isEmpty else { return }
        state.left = Self.presses
        windows = NSScreen.screens.map(makeWindow)
        NSApp.activate()
        startTap()
    }

    func stop() {
        guard !windows.isEmpty else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        onFinish?()
    }

    private func makeWindow(on screen: NSScreen) -> NSWindow {
        let window = KeyablePanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.hidesOnDeactivate = false
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: CleaningOverlay(state: state) { [weak self] in self?.stop() })
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func startTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(Self.systemDefinedMask) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return nil }
            let mode = Unmanaged<CleaningMode>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { mode.handle(type, event) }
        }
        guard let created = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                              callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let loopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = loopSource
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Self.escape,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            state.left -= 1
            if state.left <= 0 { DispatchQueue.main.async { self.stop() } }
        }
        return nil
    }
}

@MainActor
final class CleaningState: ObservableObject {
    @Published var left = CleaningMode.presses
}

struct CleaningOverlay: View {
    @ObservedObject var state: CleaningState
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles").font(.system(size: 48)).foregroundStyle(.white.opacity(0.8))
            Text("Cleaning Mode").font(.largeTitle.weight(.bold)).foregroundStyle(.white)
            Text("Keys, scrolling and media keys are locked. Press Esc \(state.left) more \(state.left == 1 ? "time" : "times") or click Unlock.")
                .foregroundStyle(.white.opacity(0.7))
            Button("Unlock", action: unlock)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
