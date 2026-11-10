import AppKit
import IOKit.hid
import Darwin

struct PointerIdentity: Codable, Equatable {
    var vendor: String
    var product: String
    var location: String
    var transport: String
    var uniqueID: String
    var serial: String

    func matches(_ other: PointerIdentity) -> Bool {
        if !uniqueID.isEmpty { return uniqueID == other.uniqueID }
        if !serial.isEmpty { return serial == other.serial }
        return vendor == other.vendor && product == other.product && location == other.location && transport == other.transport
    }
}

struct PointerValue: Codable, Equatable {
    var number: Double
    var boolean: Bool

    init?(_ value: CFTypeRef?) {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        guard type == CFBooleanGetTypeID() || type == CFNumberGetTypeID(), let number = value as? NSNumber else { return nil }
        self.number = number.doubleValue
        boolean = type == CFBooleanGetTypeID()
    }

    init(number: Double, boolean: Bool = false) { self.number = number; self.boolean = boolean }
    var object: CFTypeRef { boolean ? NSNumber(value: number != 0) : NSNumber(value: number) }
}

struct PointerJournalEntry: Codable, Equatable {
    var registryID: UInt64
    var identity: PointerIdentity
    var key: String
    var original: PointerValue
}

struct PointerJournal: Codable, Equatable {
    var boot: Int64
    var entries: [PointerJournalEntry] = []

    static func uniqueMatch(_ entry: PointerJournalEntry, devices: [(UInt64, PointerIdentity)]) -> UInt64? {
        let matches = devices.filter { entry.identity.matches($0.1) }
        return matches.count == 1 ? matches[0].0 : nil
    }
}

struct PointerJournalStore {
    var url: URL
    var boot: Int64

    func read() throws -> PointerJournal {
        guard FileManager.default.fileExists(atPath: url.path) else { return PointerJournal(boot: boot) }
        let journal = try JSONDecoder().decode(PointerJournal.self, from: Data(contentsOf: url))
        guard journal.boot == boot else { try FileManager.default.removeItem(at: url); return PointerJournal(boot: boot) }
        return journal
    }

    func save(_ journal: PointerJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum PointerAccelerationPlan {
    static func target(type: String, properties: [String: PointerValue]) -> (key: String, original: PointerValue, target: PointerValue)? {
        guard type != "HIDTrackpadAcceleration" else { return nil }
        if let original = properties["HIDUseLinearScalingMouseAcceleration"] {
            return ("HIDUseLinearScalingMouseAcceleration", original, PointerValue(number: 1, boolean: original.boolean))
        }
        for key in [type, "HIDPointerAcceleration", "HIDMouseAcceleration"] where !key.isEmpty {
            if let original = properties[key] { return (key, original, PointerValue(number: -1)) }
        }
        return nil
    }
}

final class PointerHID {
    typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    typealias Copy = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    typealias SetValue = @convention(c) (CFTypeRef, CFString, CFTypeRef) -> Bool
    typealias Registry = @convention(c) (CFTypeRef) -> UInt64
    static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    let client: CFTypeRef
    let copy: Copy
    let set: SetValue
    let registry: Registry
    let services: [CFTypeRef]

    init?() {
        guard let handle = Self.handle, let create = dlsym(handle, "IOHIDEventSystemClientCreateSimpleClient"),
              let services = dlsym(handle, "IOHIDEventSystemClientCopyServices"), let copy = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let set = dlsym(handle, "IOHIDServiceClientSetProperty"), let registry = dlsym(handle, "IOHIDServiceClientGetRegistryID"),
              let client = unsafeBitCast(create, to: Create.self)(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        self.client = client
        self.copy = unsafeBitCast(copy, to: Copy.self)
        self.set = unsafeBitCast(set, to: SetValue.self)
        self.registry = unsafeBitCast(registry, to: Registry.self)
        self.services = (unsafeBitCast(services, to: Services.self)(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []
    }

    func property(_ service: CFTypeRef, _ key: String) -> CFTypeRef? { copy(service, key as CFString)?.takeRetainedValue() }
    func text(_ service: CFTypeRef, _ key: String) -> String { property(service, key).map { String(describing: $0) } ?? "" }
    func identity(_ service: CFTypeRef) -> PointerIdentity {
        PointerIdentity(vendor: text(service, "VendorID"), product: text(service, "ProductID"), location: text(service, "LocationID"),
                        transport: text(service, "Transport"), uniqueID: text(service, "UniqueID"), serial: text(service, "SerialNumber"))
    }
    var mice: [CFTypeRef] {
        services.filter { service in
            (property(service, "PrimaryUsagePage") as? NSNumber)?.intValue == 1 && (property(service, "PrimaryUsage") as? NSNumber)?.intValue == 2
                && text(service, "HIDPointerAccelerationType") != "HIDTrackpadAcceleration"
        }
    }
    func target(_ service: CFTypeRef) -> (String, PointerValue, PointerValue)? {
        let type = text(service, "HIDPointerAccelerationType")
        let keys = Set([type, "HIDUseLinearScalingMouseAcceleration", "HIDPointerAcceleration", "HIDMouseAcceleration"])
        let values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in PointerValue(property(service, key)).map { (key, $0) } })
        return PointerAccelerationPlan.target(type: type, properties: values)
    }

    func write(_ service: CFTypeRef, key: String, value: PointerValue) -> Bool {
        set(service, key as CFString, value.object) && PointerValue(property(service, key)) == value
    }
}

final class PointerRecovery {
    static let flag = "--mackit-restore-pointer"
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacKit", isDirectory: true).appendingPathComponent("pointer-journal.json")
    }
    static var boot: Int64 {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return 0 }
        return Int64(value.tv_sec)
    }
    static func read() throws -> PointerJournal {
        let stamp = boot
        guard stamp != 0 else { throw CocoaError(.fileReadUnknown) }
        return try PointerJournalStore(url: url, boot: stamp).read()
    }
    static func save(_ journal: PointerJournal) throws { try PointerJournalStore(url: url, boot: boot).save(journal) }
    static func restore() -> Bool {
        do {
            var journal = try read()
            guard !journal.entries.isEmpty else { return true }
            guard let hid = PointerHID() else { return false }
            let mice = hid.mice
            let devices = mice.map { (hid.registry($0), hid.identity($0)) }
            journal.entries.removeAll { entry in
                guard let id = PointerJournal.uniqueMatch(entry, devices: devices), let service = mice.first(where: { hid.registry($0) == id }) else { return false }
                return hid.write(service, key: entry.key, value: entry.original)
            }
            try save(journal)
            return journal.entries.isEmpty
        } catch { return false }
    }
}

final class PointerWatchdog {
    private var process: Process?
    private var pipe: Pipe?

    func start() -> Bool {
        if let process { return process.isRunning }
        guard let executable = Bundle.main.executableURL else { return false }
        let pipe = Pipe()
        let process = Process()
        let ready = Pipe()
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf R; while IFS= read -r line; do :; done; exec \"$1\" \"$2\"", "mackit-pointer-guard", executable.path, PointerRecovery.flag]
        process.standardInput = pipe
        process.standardOutput = ready
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        try? pipe.fileHandleForReading.close()
        self.pipe = pipe
        self.process = process
        try? ready.fileHandleForWriting.close()
        var descriptor = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var byte: UInt8 = 0
        let started = poll(&descriptor, 1, 1000) > 0 && Darwin.read(descriptor.fd, &byte, 1) == 1 && byte == 82 && process.isRunning
        try? ready.fileHandleForReading.close()
        if !started { stop() }
        return started
    }

    func stop() {
        try? pipe?.fileHandleForWriting.close()
        pipe = nil
        guard let process else { return }
        let deadline = Date().addingTimeInterval(6)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.5) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); Thread.sleep(forTimeInterval: 0.5) }
        self.process = nil
    }
}

struct PointerSettings: Codable, Equatable { var accelerationOff = false }

@MainActor
final class PointerAccelerationController: ObservableObject {
    @Published var settings: PointerSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "pointer.settings")
            if settings.accelerationOff { schedule() } else { restore() }
        }
    }
    @Published private(set) var status: String?
    private let watchdog = PointerWatchdog()
    private var manager: IOHIDManager?
    private var generation = 0
    private var suspended = false
    private var dropped: Set<UInt64> = []

    init() {
        settings = UserDefaults.standard.data(forKey: "pointer.settings").flatMap { try? JSONDecoder().decode(PointerSettings.self, from: $0) } ?? PointerSettings()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = true; self?.restore() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = false; self?.schedule() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restore() }
        }
        if settings.accelerationOff { schedule() }
    }

    private func watch() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2] as CFDictionary)
        let callback: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            MainActor.assumeIsolated { Unmanaged<PointerAccelerationController>.fromOpaque(context).takeUnretainedValue().schedule() }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, callback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    private func schedule() {
        guard settings.accelerationOff, !suspended, InputEventGuard.consoleActive else { return }
        watch()
        generation += 1
        let token = generation
        for delay in [0.0, 0.25, 1, 2.5, 5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == token, self.settings.accelerationOff, !self.suspended else { return }
                self.apply()
            }
        }
    }

    private func apply() {
        do {
            var journal = try PointerRecovery.read()
            guard PointerRecovery.boot != 0, let hid = PointerHID() else { status = "Mouse acceleration control is unavailable."; return }
            let mice = hid.mice
            guard !mice.isEmpty || !journal.entries.isEmpty else { return }
            guard watchdog.start() else { status = "Recovery guard could not start; no mouse properties changed."; return }
            let devices = mice.map { (hid.registry($0), hid.identity($0)) }
            for entry in journal.entries where !devices.contains(where: { $0.0 == entry.registryID && $0.1 == entry.identity }) {
                guard let id = PointerJournal.uniqueMatch(entry, devices: devices), let service = mice.first(where: { hid.registry($0) == id }),
                      hid.write(service, key: entry.key, value: entry.original) else { continue }
                journal.entries.removeAll { $0 == entry }
                try PointerRecovery.save(journal)
            }
            for service in mice {
                let id = hid.registry(service)
                guard id != 0, !dropped.contains(id), let (key, original, target) = hid.target(service) else { continue }
                let identity = hid.identity(service)
                if journal.entries.contains(where: { $0.registryID != id && $0.identity.matches(identity) }) { continue }
                if !journal.entries.contains(where: { $0.registryID == id }) {
                    journal.entries.append(PointerJournalEntry(registryID: id, identity: identity, key: key, original: original))
                    do { try PointerRecovery.save(journal) } catch { journal.entries.removeLast(); status = "Could not save recovery journal; mouse skipped."; continue }
                }
                guard let entry = journal.entries.first(where: { $0.registryID == id }) else { continue }
                if !hid.write(service, key: entry.key, value: target) {
                    if hid.write(service, key: entry.key, value: entry.original) {
                        journal.entries.removeAll { $0.registryID == id }
                        try PointerRecovery.save(journal)
                    }
                    dropped.insert(id)
                    status = "A mouse rejected acceleration control and was skipped."
                }
            }
            if journal.entries.isEmpty { watchdog.stop() }
        } catch { status = "Recovery journal cannot be read; acceleration changes are blocked." }
    }

    private func restore() {
        generation += 1
        if !PointerRecovery.restore() { status = "Some mouse properties still need recovery when the device returns." }
        watchdog.stop()
        dropped = []
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }
}
