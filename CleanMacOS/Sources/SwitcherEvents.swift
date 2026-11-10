import AppKit
import ApplicationServices
import Carbon
import KeyboardShortcuts

struct SwitcherTrigger: Equatable {
    let mode: SwitcherMode
    let key: UInt16
    let modifiers: CGEventFlags

    static func allowed(mode: SwitcherMode, key: UInt16, flags: CGEventFlags) -> Bool {
        let expectedKey: UInt16 = mode == .currentApp ? 50 : 48
        let expected: CGEventFlags = mode == .allWindows ? .maskAlternate : .maskCommand
        return key == expectedKey && flags.subtracting(.maskShift) == expected
    }

    func match(key: UInt16, flags: CGEventFlags, character: String) -> Bool? {
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let actual = flags.intersection(relevant)
        if key == self.key {
            if actual == modifiers { return false }
            if !modifiers.contains(.maskShift), actual == modifiers.union(.maskShift) { return true }
        }
        if mode == .currentApp, character == "`" || character == "~",
           actual.subtracting([.maskAlternate, .maskShift]) == modifiers.subtracting([.maskAlternate, .maskShift]) { return false }
        return nil
    }
}

enum SwitcherInput {
    case trigger(SwitcherMode, reverse: Bool, repeating: Bool, required: CGEventFlags)
    case key(UInt16, String, CGEventFlags, repeating: Bool)
    case modifiers(CGEventFlags)
    case pointer(CGPoint, down: Bool, middle: Bool)
    case scroll(Double, Double, continuous: Bool, momentum: Bool)
    case interrupted
    case activity
    case dragEnded
}

final class SwitcherEventTap: @unchecked Sendable {
    struct Configuration {
        var triggers: [SwitcherTrigger] = []
        var recording = false
        var session = false
        var dock = false
    }

    private let lock = NSLock()
    private var configuration = Configuration()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var worker: Thread?
    private var stopping = false
    private let listenOnly: Bool
    private let receive: @Sendable (SwitcherInput) -> Void

    init(listenOnly: Bool = false, receive: @escaping @Sendable (SwitcherInput) -> Void) { self.listenOnly = listenOnly; self.receive = receive }

    func configure(_ config: Configuration) {
        lock.lock()
        configuration = config
        lock.unlock()
    }

    func setSession(_ active: Bool) {
        lock.lock()
        configuration.session = active
        lock.unlock()
    }

    func start() {
        lock.lock()
        guard worker == nil else { lock.unlock(); return }
        stopping = false
        let thread = Thread { [weak self] in self?.run() }
        thread.qualityOfService = .userInteractive
        thread.name = "MacKit switcher events"
        worker = thread
        lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        stopping = true
        configuration = Configuration()
        let loop = runLoop
        let tap = tap
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }

    var isLive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    private func run() {
        let types: [CGEventType] = listenOnly ? [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown] : [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .otherMouseUp, .scrollWheel, .mouseMoved]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<SwitcherEventTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: listenOnly ? .listenOnly : .defaultTap,
                                              eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            lock.lock(); worker = nil; lock.unlock()
            receive(.interrupted)
            return
        }
        let loop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        lock.lock()
        tap = created
        runLoop = loop
        let shouldStop = stopping
        lock.unlock()
        if !shouldStop {
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        CFMachPortInvalidate(created)
        lock.lock()
        tap = nil
        runLoop = nil
        worker = nil
        lock.unlock()
        receive(.interrupted)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        lock.lock()
        let config = configuration
        let currentTap = tap
        let stopping = stopping
        lock.unlock()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            setSession(false)
            if !stopping, let currentTap { CGEvent.tapEnable(tap: currentTap, enable: true) }
            receive(.interrupted)
            return pass
        }
        guard !stopping, !config.recording else { return pass }
        if type == .leftMouseUp, config.dock { receive(.dragEnded); return pass }
        if type == .mouseMoved || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            if config.session || config.dock {
                receive(.pointer(event.location, down: type != .mouseMoved, middle: type == .otherMouseDown))
            }
            if type != .mouseMoved && !config.session { receive(.activity) }
            return pass
        }
        if type == .flagsChanged {
            if config.session { receive(.modifiers(event.flags)) }
            return pass
        }
        if type == .scrollWheel, config.session {
            receive(.scroll(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2), event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                            continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                            momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0))
            return nil
        }
        guard type == .keyDown else { return pass }
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
        let text = String(utf16CodeUnits: characters, count: min(length, characters.count))
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        for trigger in config.triggers {
            if let reverse = trigger.match(key: key, flags: event.flags, character: text) {
                setSession(true)
                receive(.trigger(trigger.mode, reverse: reverse, repeating: repeating, required: trigger.modifiers))
                return nil
            }
        }
        if config.session {
            receive(.key(key, text, event.flags, repeating: repeating))
            return nil
        }
        receive(.activity)
        return pass
    }
}

struct SwitcherHotKey: Equatable {
    let id: Int32
    let key: UInt32
    let modifiers: UInt32
    let enabled: Bool
}

enum SwitcherTakeoverPlan {
    static func desired(_ keys: [SwitcherHotKey], triggers: [SwitcherTrigger], permitted: Bool) -> Set<Int32> {
        guard permitted else { return [] }
        return Set(keys.filter { hotkey in
            [1, 2, 27, 220].contains(hotkey.id) && hotkey.enabled && triggers.contains { trigger in
                hotkey.key == UInt32(trigger.key) && (hotkey.modifiers == UInt32(trigger.modifiers.rawValue)
                    || hotkey.modifiers == UInt32(trigger.modifiers.union(.maskShift).rawValue))
            }
        }.map(\.id))
    }
}

@MainActor
final class SwitcherTakeover {
    private typealias GetValue = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private let get: GetValue?
    private let enabled: IsEnabled?
    private let set: SetEnabled?
    private var held = Set<Int32>()
    private var watchdog: Process?
    private var watchdogInput: FileHandle?
    private let key = "switcher.disabledSymbolicHotkeys"
    var available: Bool { self.get != nil && enabled != nil && self.set != nil }

    init() {
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let value = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(value, to: type)
        }
        get = symbol("CGSGetSymbolicHotKeyValue", GetValue.self)
        enabled = symbol("CGSIsSymbolicHotKeyEnabled", IsEnabled.self)
        set = symbol("CGSSetSymbolicHotKeyEnabled", SetEnabled.self)
        held = Set((UserDefaults.standard.array(forKey: key) as? [Int] ?? []).map(Int32.init))
        restore()
    }

    func reconcile(triggers: [SwitcherTrigger], permitted: Bool) {
        guard available, permitted, ensureWatchdog() else { restore(); return }
        let values: [SwitcherHotKey] = [Int32(1), 2, 27, 220].compactMap { id in
            var equivalent: UInt16 = 0
            var code: UInt32 = 0
            var modifiers: UInt32 = 0
            guard get?(id, &equivalent, &code, &modifiers) == 0 else { return nil }
            return SwitcherHotKey(id: id, key: code, modifiers: modifiers, enabled: held.contains(id) || enabled?(id) == true)
        }
        let desired = SwitcherTakeoverPlan.desired(values, triggers: triggers, permitted: permitted)
        for id in held.subtracting(desired) where set?(id, true) == 0 { held.remove(id) }
        for id in desired.subtracting(held) {
            held.insert(id)
            save()
            guard sendWatchdog() else { held.remove(id); restore(); return }
            if set?(id, false) != 0 { held.remove(id) }
        }
        save()
        _ = sendWatchdog()
    }

    func restore() {
        for id in held where set?(id, true) == 0 { held.remove(id) }
        save()
        _ = sendWatchdog()
        if held.isEmpty {
            try? watchdogInput?.close()
            watchdogInput = nil
            watchdog = nil
        }
    }

    private func ensureWatchdog() -> Bool {
        if watchdog?.isRunning == true { return true }
        guard let executable = Bundle.main.executableURL else { return false }
        let process = Process()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = [SwitcherCrashRecovery.flag]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async {
                if self?.watchdog?.processIdentifier == terminated.processIdentifier { self?.restore() }
            }
        }
        do {
            try process.run()
            watchdog = process
            watchdogInput = input.fileHandleForWriting
            return true
        } catch { return false }
    }

    private func sendWatchdog() -> Bool {
        guard let input = watchdogInput else { return held.isEmpty }
        let line = held.sorted().map(String.init).joined(separator: ",") + "\n"
        do { try input.write(contentsOf: Data(line.utf8)); return true }
        catch { return false }
    }

    private func save() {
        if held.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(held.map(Int.init).sorted(), forKey: key) }
    }
}


enum SwitcherCrashRecovery {
    static let flag = "--switcher-shortcut-watchdog"

    static func run() -> Never {
        typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetSymbolicHotKeyEnabled") else { exit(1) }
        let enable = unsafeBitCast(symbol, to: SetEnabled.self)
        var held: [Int32] = []
        while let line = readLine() {
            held = line.split(separator: ",").compactMap { Int32($0) }.filter { [1, 2, 27, 220].contains($0) }
        }
        for id in held { _ = enable(id, true) }
        exit(0)
    }
}
