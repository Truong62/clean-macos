import AppKit
import ApplicationServices
import IOKit

struct TrackpadMiddleSettings: Codable, Equatable {
    var pressEnabled = false
    var tapFingers = 0
    var excludedApps: [String] = []
}

struct TouchGeometry: Equatable {
    var count: Int
    var center: CGPoint
    var spread: Double

    static func read(_ data: Data, count: Int) -> TouchGeometry? {
        guard count > 0, count <= 16, data.count >= count * 96 else { return nil }
        var points: [CGPoint] = []
        for index in 0..<count {
            let x = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 96 + 32, as: Float.self) }
            let y = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 96 + 36, as: Float.self) }
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
            points.append(CGPoint(x: Double(x), y: Double(y)))
        }
        let center = CGPoint(x: points.map(\.x).reduce(0, +) / Double(count), y: points.map(\.y).reduce(0, +) / Double(count))
        let spread = points.map { hypot($0.x - center.x, $0.y - center.y) }.reduce(0, +) / Double(count)
        return TouchGeometry(count: count, center: center, spread: spread)
    }
}

struct TrackpadTouchState {
    private(set) var latest: TouchGeometry?
    private(set) var frameTime = -Double.infinity
    private var countSince = -Double.infinity
    private var candidate: (geometry: TouchGeometry, start: TimeInterval)?
    private var blocked = false
    private var lastKey = -Double.infinity
    private var lastConverted = -Double.infinity

    mutating func key(at time: TimeInterval) { lastKey = time; candidate = nil; blocked = true }
    mutating func physicalClick() { candidate = nil; blocked = true }
    mutating func converted(at time: TimeInterval) { lastConverted = time }
    func isDuplicate(at time: TimeInterval) -> Bool { time - lastConverted < 0.30 }
    func qualifiesPress(at time: TimeInterval, threeFingerDrag: Bool) -> Bool {
        latest?.count == (threeFingerDrag ? 4 : 3) && time - frameTime <= 0.25 && time - countSince >= 0.04
    }

    mutating func frame(_ geometry: TouchGeometry?, count: Int, at time: TimeInterval, tapFingers: Int, threeFingerDrag: Bool) -> Bool {
        if count != latest?.count { countSince = time }
        latest = geometry
        frameTime = time
        guard count > 0 else {
            defer { candidate = nil; blocked = false }
            guard let candidate, !blocked, time - candidate.start <= 0.35, time - lastKey >= 0.5,
                  !isDuplicate(at: time) else { return false }
            lastConverted = time
            return true
        }
        if count < tapFingers, geometry != nil, candidate != nil { return false }
        guard let geometry, count == tapFingers, tapFingers == 3 || tapFingers == 4, !(threeFingerDrag && tapFingers == 3) else {
            if candidate != nil || count > tapFingers || geometry == nil { blocked = true }
            candidate = nil
            return false
        }
        guard !blocked else { return false }
        if let candidate {
            if hypot(geometry.center.x - candidate.geometry.center.x, geometry.center.y - candidate.geometry.center.y) > 0.03
                || abs(geometry.spread - candidate.geometry.spread) > 0.04 || time - candidate.start > 0.35 {
                self.candidate = nil
                blocked = true
            }
        } else { candidate = (geometry, time) }
        return false
    }
}

final class MultitouchFeed {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32
    typealias List = @convention(c) () -> Unmanaged<CFArray>?
    typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void
    static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
    private static let lock = NSLock()
    private static var receiver: ((Data, Int, TimeInterval) -> Void)?
    private var devices: [UnsafeMutableRawPointer] = []
    private var list: CFArray?
    private let register: Register
    private let unregister: Register
    private let startDevice: Start
    private let stopDevice: Stop
    private let createList: List
    private static let callback: Callback = { _, contacts, count, _, _ in
        guard count >= 0, count <= 16 else { return 0 }
        let data = contacts.map { Data(bytes: $0, count: Int(count) * 96) } ?? Data()
        let time = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let receiver = receiver
        lock.unlock()
        receiver?(data, Int(count), time)
        return 0
    }

    init?() {
        guard let handle = Self.handle, let list = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"), let unregister = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"), let stop = dlsym(handle, "MTDeviceStop") else { return nil }
        createList = unsafeBitCast(list, to: List.self)
        self.register = unsafeBitCast(register, to: Register.self)
        self.unregister = unsafeBitCast(unregister, to: Register.self)
        startDevice = unsafeBitCast(start, to: Start.self)
        stopDevice = unsafeBitCast(stop, to: Stop.self)
    }

    func start(_ receiver: @escaping (Data, Int, TimeInterval) -> Void) -> Bool {
        stop()
        Self.lock.lock()
        Self.receiver = receiver
        Self.lock.unlock()
        guard let list = createList()?.takeRetainedValue() else { return false }
        self.list = list
        for index in 0..<CFArrayGetCount(list) {
            guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: pointer)
            devices.append(device)
            register(device, Self.callback)
            startDevice(device, 0)
        }
        return !devices.isEmpty
    }

    func stop() {
        Self.lock.lock()
        Self.receiver = nil
        Self.lock.unlock()
        for device in devices { unregister(device, Self.callback); stopDevice(device) }
        devices = []
        list = nil
    }
}

@MainActor
final class TrackpadMiddleController: ObservableObject {
    @Published var settings: TrackpadMiddleSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "trackpadMiddle.settings")
            stop()
            apply()
        }
    }
    @Published private(set) var status: String?
    @Published private(set) var threeFingerDrag = false
    var isCleaning: () -> Bool = { false }
    private var feed: MultitouchFeed?
    private var state = TrackpadTouchState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var heldAt: TimeInterval?
    private var heldTarget: pid_t = 0
    private var heldButton: Int64?
    private var suppressed: Set<Int64> = []
    private var active = true
    private var notificationPort: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0

    init() {
        settings = UserDefaults.standard.data(forKey: "trackpadMiddle.settings").flatMap { try? JSONDecoder().decode(TrackpadMiddleSettings.self, from: $0) } ?? TrackpadMiddleSettings()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = false; self?.stop() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = true; self?.apply() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        apply()
    }

    func requestPermission() {
        PasteService.requestAccessibility()
        apply()
    }

    private func apply() {
        guard active, InputEventGuard.consoleActive, settings.pressEnabled || settings.tapFingers != 0, AXIsProcessTrusted(), !isCleaning() else { return }
        guard tap == nil else { return }
        guard let feed = MultitouchFeed() else {
            status = "Touch data is unavailable; middle click is inactive."
            settings = TrackpadMiddleSettings(excludedApps: settings.excludedApps)
            return
        }
        self.feed = feed
        let available = feed.start { [weak self] data, count, time in
            DispatchQueue.main.async { self?.frame(data, count: count, time: time) }
        }
        status = available ? nil : "No touch data. Connect a supported trackpad to use middle click."
        refreshDragSetting()
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated { Unmanaged<TrackpadMiddleController>.fromOpaque(context).takeUnretainedValue().handle(type, event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { feed.stop(); return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshDragSetting()
                if !AXIsProcessTrusted() { self.stop() }
                if self.isCleaning() { self.releaseHeld(); self.state = TrackpadTouchState() }
            }
        }
        watchDevices()
    }

    private func watchDevices() {
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        let callback: IOServiceMatchingCallback = { context, iterator in
            while true { let service = IOIteratorNext(iterator); if service == 0 { break }; IOObjectRelease(service) }
            guard let context else { return }
            DispatchQueue.main.async {
                let controller = Unmanaged<TrackpadMiddleController>.fromOpaque(context).takeUnretainedValue()
                controller.stop()
                controller.apply()
            }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"), callback,
                                         Unmanaged.passUnretained(self).toOpaque(), &added)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("AppleMultitouchDevice"), callback,
                                         Unmanaged.passUnretained(self).toOpaque(), &removed)
        for iterator in [added, removed] {
            while true { let service = IOIteratorNext(iterator); if service == 0 { break }; IOObjectRelease(service) }
        }
    }

    private func refreshDragSetting() {
        DispatchQueue.global(qos: .utility).async {
            let enabled = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"].contains {
                (CFPreferencesCopyAppValue("TrackpadThreeFingerDrag" as CFString, $0 as CFString) as? NSNumber)?.boolValue == true
            }
            DispatchQueue.main.async { [weak self] in self?.threeFingerDrag = enabled }
        }
    }

    private func frame(_ data: Data, count: Int, time: TimeInterval) {
        guard active, !isCleaning(), tap != nil else { state = TrackpadTouchState(); return }
        let geometry = TouchGeometry.read(data, count: count)
        let tapClick = state.frame(geometry, count: count, at: time, tapFingers: settings.tapFingers, threeFingerDrag: threeFingerDrag)
        guard tapClick, heldAt == nil, let event = CGEvent(source: nil), !InputEventGuard.excluded(event, apps: settings.excludedApps, checkPosting: false) else { return }
        postMiddle(down: true, point: event.location)
        postMiddle(down: false, point: event.location)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            releaseHeld()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard AXIsProcessTrusted(), active, InputEventGuard.consoleActive else { stop(); return pass }
        guard event.getIntegerValueField(.eventSourceUserData) != InputController.marker else { return pass }
        let now = ProcessInfo.processInfo.systemUptime
        if type == .keyDown { state.key(at: now); return pass }
        if isCleaning() { releaseHeld(); return pass }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let down = type == .leftMouseDown || type == .rightMouseDown
        let up = type == .leftMouseUp || type == .rightMouseUp
        if !down {
            if suppressed.contains(button) { if up { suppressed.remove(button) }; return nil }
            if heldButton == button {
                event.type = up ? .otherMouseUp : .otherMouseDragged
                event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                if up { heldAt = nil; heldButton = nil }
            }
            return pass
        }
        let qualifies = state.qualifiesPress(at: now, threeFingerDrag: threeFingerDrag)
        state.physicalClick()
        if let heldAt {
            if now - heldAt <= 10 { if button != heldButton { suppressed.insert(button) }; return nil }
            releaseHeld()
        }
        guard settings.pressEnabled, qualifies, !InputEventGuard.excluded(event, apps: settings.excludedApps) else { return pass }
        if state.isDuplicate(at: now) { suppressed.insert(button); return nil }
        state.converted(at: now)
        heldAt = now
        heldButton = button
        heldTarget = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if heldTarget == 0, let window = AXWindow.at(event.location) { AXUIElementGetPid(window, &heldTarget) }
        if heldTarget == 0 { heldTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
        event.type = .otherMouseDown
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        return pass
    }

    private func postMiddle(down: Bool, point: CGPoint, target: pid_t? = nil) {
        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: down ? .otherMouseDown : .otherMouseUp,
                            mouseCursorPosition: point, mouseButton: .center)
        event?.setIntegerValueField(.eventSourceUserData, value: InputController.marker)
        if let target, target > 0 { event?.postToPid(target) } else { event?.post(tap: .cghidEventTap) }
    }

    private func releaseHeld() {
        guard heldAt != nil else { return }
        postMiddle(down: false, point: CGEvent(source: nil)?.location ?? .zero, target: heldTarget)
        heldAt = nil
        heldButton = nil
        Thread.sleep(forTimeInterval: 0.02)
    }

    private func stop() {
        releaseHeld()
        feed?.stop()
        feed = nil
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        timer?.invalidate()
        timer = nil
        state = TrackpadTouchState()
        suppressed = []
    }
}
