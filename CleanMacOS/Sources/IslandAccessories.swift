import Foundation
import IOKit

struct IslandAccessoryQueue {
    struct Entry: Equatable {
        var id: String
        var title: String
        var inserted: Double
        var warning: Bool
    }
    private(set) var entries: [Entry] = []
    mutating func enqueue(id: String, title: String, now: Double, warning: Bool = false) {
        entries.removeAll { $0.id == id || now - $0.inserted >= 30 }
        if entries.count == 8 { entries.removeFirst() }
        entries.append(Entry(id: id, title: title, inserted: now, warning: warning))
    }
    mutating func recover(_ id: String) { entries.removeAll { $0.id == id && $0.warning } }
    mutating func next(now: Double, closed: Bool) -> Entry? {
        entries.removeAll { now - $0.inserted >= 30 }
        guard closed, !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }
}

struct IslandAccessoryBattery {
    private var seen = Set<String>()
    private var armed = Set<String>()
    mutating func update(id: String, percent: Int, sampled: Date, now: Date, hid: Bool) -> Bool {
        guard (0...100).contains(percent), now >= sampled, now.timeIntervalSince(sampled) <= (hid ? 15 : 300) else { return false }
        guard !seen.insert(id).inserted else {
            if percent > 20 { armed.insert(id) }
            return false
        }
        if percent >= 25 { armed.insert(id) }
        guard percent <= 20, armed.remove(id) != nil else { return false }
        return true
    }
}

enum IslandAccessoryPolicy {
    static func accepts(major: UInt32, paired: Bool) -> Bool { paired && ![1, 2, 3].contains(major) }
    static func icon(name: String, major: UInt32) -> String {
        let name = name.lowercased()
        if name.contains("airpod") || name.contains("headphone") || major == 4 { return "headphones" }
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("mouse") { return "computermouse" }
        if name.contains("trackpad") { return "magicmouse" }
        if name.contains("controller") { return "gamecontroller" }
        return "antenna.radiowaves.left.and.right"
    }
}

struct IslandAccessoryReading: Equatable {
    var id: String
    var name: String
    var percent: Int
    var sampled: Date
}

enum IslandAccessoryProbe {
    static func read(now: Date) -> [IslandAccessoryReading] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [IslandAccessoryReading] = []
        while true {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { break }
            defer { IOObjectRelease(device) }
            guard let number = IORegistryEntryCreateCFProperty(device, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
                  let name = IORegistryEntryCreateCFProperty(device, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(device, &id) == KERN_SUCCESS else { continue }
            result.append(IslandAccessoryReading(id: String(id), name: name, percent: number.intValue, sampled: now))
        }
        return result
    }
}

struct IslandBatteryColors: Codable, Equatable {
    var enabled = false
    var amber = false
    var redThreshold = 10
    var amberThreshold = 20

    init(enabled: Bool = false, amber: Bool = false, redThreshold: Int = 10, amberThreshold: Int = 20) {
        self.enabled = enabled
        self.amber = amber
        self.redThreshold = min(99, max(1, redThreshold))
        self.amberThreshold = min(100, max(self.redThreshold + 1, amberThreshold))
    }

    func level(percent: Double?, plugged: Bool) -> ReadoutCell.Level {
        guard enabled, !plugged, let percent, percent.isFinite else { return .normal }
        let red = min(99, max(1, redThreshold))
        if percent <= Double(red) { return .critical }
        if amber && percent <= Double(min(100, max(red + 1, amberThreshold))) { return .elevated }
        return .normal
    }
}

extension IslandBatteryColors {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  amber: try container.decodeIfPresent(Bool.self, forKey: .amber) ?? false,
                  redThreshold: try container.decodeIfPresent(Int.self, forKey: .redThreshold) ?? 10,
                  amberThreshold: try container.decodeIfPresent(Int.self, forKey: .amberThreshold) ?? 20)
    }
}
