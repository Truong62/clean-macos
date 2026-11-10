import AppKit
import CoreGraphics
import IOKit

enum PrivateSymbols {
    static let searchAll = UnsafeMutableRawPointer(bitPattern: -2)

    static func load<T>(_ name: String, from path: String, as type: T.Type) -> T? {
        _ = dlopen(path, RTLD_LAZY)
        guard let symbol = dlsym(searchAll, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

enum DisplayServicesBridge {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let getter = PrivateSymbols.load("DisplayServicesGetBrightness", from: path, as: Getter.self)
    private static let setter = PrivateSymbols.load("DisplayServicesSetBrightness", from: path, as: Setter.self)

    static func brightness(of display: CGDirectDisplayID) -> Double? {
        guard let getter else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? Double(value) : nil
    }

    @discardableResult
    static func setBrightness(_ level: Double, of display: CGDirectDisplayID) -> Bool {
        setter?(display, Float(min(max(level, 0), 1))) == 0
    }
}

final class DDCChannel: @unchecked Sendable {
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private static let path = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
    private static let writeI2C = PrivateSymbols.load("IOAVServiceWriteI2C", from: path, as: Transfer.self)
    private static let readI2C = PrivateSymbols.load("IOAVServiceReadI2C", from: path, as: Transfer.self)
    static let attempts = 5
    static let settleDelay: useconds_t = 10_000
    static let retryDelay: useconds_t = 20_000
    static let replyDelay: useconds_t = 50_000
    static let minimumGap: TimeInterval = 0.05
    private static let transaction = NSLock()

    let service: CFTypeRef
    private var lastCommand = Date.distantPast

    init(service: CFTypeRef) {
        self.service = service
    }

    func write(_ code: UInt8, value: UInt16) -> Bool {
        Self.transaction.lock()
        defer { Self.transaction.unlock() }
        pace()
        var packet = DDC.setPacket(code: code, value: value)
        for _ in 0..<Self.attempts {
            usleep(Self.settleDelay)
            let first = send(&packet)
            let second = send(&packet)
            if first || second { return true }
            usleep(Self.retryDelay)
        }
        return false
    }

    func read(_ code: UInt8) -> (reading: DDCReading?, isAccepted: Bool) {
        Self.transaction.lock()
        defer { Self.transaction.unlock() }
        pace()
        var request = DDC.getPacket(code: code)
        var isAccepted = false
        for _ in 0..<Self.attempts {
            usleep(Self.settleDelay)
            if send(&request) {
                isAccepted = true
                usleep(Self.replyDelay)
                var reply = [UInt8](repeating: 0, count: DDC.replyLength)
                if Self.readI2C?(service, DDC.chipAddress, DDC.dataAddress, &reply, UInt32(reply.count)) == kIOReturnSuccess,
                   let reading = DDC.parseReply(reply, code: code) {
                    return (reading, true)
                }
            }
            usleep(Self.retryDelay)
        }
        return (nil, isAccepted)
    }

    func probe() -> DDCProbe {
        let result = read(DDC.brightness)
        if let reading = result.reading { return .live(reading) }
        return result.isAccepted ? .writeOnly : .none
    }

    private func send(_ packet: inout [UInt8]) -> Bool {
        Self.writeI2C?(service, DDC.chipAddress, DDC.dataAddress, &packet, UInt32(packet.count)) == kIOReturnSuccess
    }

    private func pace() {
        let wait = Self.minimumGap - Date().timeIntervalSince(lastCommand)
        if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        lastCommand = Date()
    }
}

enum DDCDiscovery {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias InfoDictionary = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let path = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
    private static let create = PrivateSymbols.load("IOAVServiceCreateWithService", from: path, as: Create.self)
    private static let info = PrivateSymbols.load("CoreDisplay_DisplayCreateInfoDictionary", from: path, as: InfoDictionary.self)
    static let framebufferNames = ["AppleCLCD2", "IOMobileFramebufferShim"]
    static let serviceName = "DCPAVServiceProxy"
    static let nameLength = 128
    static let pathLength = 512

    static func channels() -> [(identity: MonitorIdentity, channel: DDCChannel)] {
        guard let create else { return [] }
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [(identity: MonitorIdentity, channel: DDCChannel)] = []
        var pending: MonitorIdentity?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let name = registryName(entry)
            if framebufferNames.contains(where: { name.contains($0) }) {
                pending = identity(of: entry)
            } else if name == serviceName, property(entry, "Location") as? String == "External", let identity = pending,
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                found.append((identity, DDCChannel(service: service)))
                pending = nil
            }
        }
        return found
    }

    static func identity(of display: CGDirectDisplayID, name: String) -> MonitorIdentity {
        let details = info?(display)?.takeRetainedValue() as? [String: Any]
        return MonitorIdentity(vendor: Int(CGDisplayVendorNumber(display)), product: Int(CGDisplayModelNumber(display)),
                               serial: Int(CGDisplaySerialNumber(display)), name: name, location: details?["IODisplayLocation"] as? String ?? "")
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: nameLength)
        IORegistryEntryGetName(entry, &name)
        return String(cString: name)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func identity(of entry: io_registry_entry_t) -> MonitorIdentity {
        let attributes = (property(entry, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any] ?? [:]
        var location = [CChar](repeating: 0, count: pathLength)
        IORegistryEntryGetPath(entry, kIOServicePlane, &location)
        return MonitorIdentity(vendor: attributes["LegacyManufacturerID"] as? Int ?? 0, product: attributes["ProductID"] as? Int ?? 0,
                               serial: attributes["SerialNumber"] as? Int ?? 0, name: attributes["ProductName"] as? String ?? "",
                               location: String(cString: location))
    }
}

enum PictureDimmer {
    static let tableSize = 256
    nonisolated(unsafe) private(set) static var hasChanges = false

    static func currentTable(for display: CGDirectDisplayID) -> GammaTable? {
        var red = [CGGammaValue](repeating: 0, count: tableSize)
        var green = [CGGammaValue](repeating: 0, count: tableSize)
        var blue = [CGGammaValue](repeating: 0, count: tableSize)
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, UInt32(tableSize), &red, &green, &blue, &count) == .success, count > 0 else { return nil }
        let size = Int(count)
        return GammaTable(red: Array(red.prefix(size)), green: Array(green.prefix(size)), blue: Array(blue.prefix(size)))
    }

    @discardableResult
    static func apply(_ table: GammaTable, to display: CGDirectDisplayID) -> Bool {
        let isApplied = CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue) == .success
        if isApplied { hasChanges = true }
        return isApplied
    }

    static func restoreAll() {
        guard hasChanges else { return }
        CGDisplayRestoreColorSyncSettings()
        hasChanges = false
    }
}

enum DisplayPower {
    private typealias Configure = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let configure = PrivateSymbols.load("CGSConfigureDisplayEnabled",
                                                                           from: "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                                                                           as: Configure.self)

    static var isAvailable: Bool { configure != nil }

    static func set(_ display: CGDirectDisplayID, enabled: Bool) -> Bool {
        guard let configure else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard configure(config, display, enabled) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }
}
