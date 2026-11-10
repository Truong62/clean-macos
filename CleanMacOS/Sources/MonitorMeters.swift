import Foundation

struct CPUTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    func usage(since old: CPUTicks) -> Double? {
        guard user >= old.user, system >= old.system, idle >= old.idle, nice >= old.nice else { return nil }
        let busy = Double(user - old.user) + Double(system - old.system) + Double(nice - old.nice)
        let total = busy + Double(idle - old.idle)
        return total > 0 ? busy / total * 100 : nil
    }
}

struct LoadMeter {
    static let maxGap: TimeInterval = 12.5

    private var last: (ticks: [CPUTicks], time: TimeInterval)?

    mutating func update(_ ticks: [CPUTicks], at time: TimeInterval) -> [Double?]? {
        let previous = last
        last = (ticks, time)
        guard let previous, previous.ticks.count == ticks.count, time - previous.time <= Self.maxGap else { return nil }
        return zip(ticks, previous.ticks).map { $0.usage(since: $1) }
    }
}

struct PerfLevel: Equatable, Sendable {
    let name: String
    let cores: Int
}

struct CoreGroup: Equatable, Identifiable {
    let name: String
    let loads: [Double?]

    var id: String { name }

    static func groups(_ loads: [Double?], levels: [PerfLevel]) -> [CoreGroup] {
        guard !levels.isEmpty, levels.map(\.cores).reduce(0, +) == loads.count else { return [CoreGroup(name: "Cores", loads: loads)] }
        var end = loads.count
        return levels.map { level in
            end -= level.cores
            return CoreGroup(name: level.name, loads: Array(loads[end..<end + level.cores]))
        }
    }
}

struct ProcessSample: Equatable, Sendable {
    let pid: Int32
    let name: String
    let cpuNanoseconds: UInt64
}

struct ProcessLoad: Equatable, Identifiable {
    let pid: Int32
    let name: String
    let percent: Double

    var id: Int32 { pid }
}

struct ProcessMeter {
    static let shown = 5

    private var last: (times: [Int32: UInt64], time: TimeInterval)?

    mutating func update(_ samples: [ProcessSample], at time: TimeInterval, cores: Int, total: Double?) -> [ProcessLoad]? {
        let previous = last
        last = (Dictionary(samples.map { ($0.pid, $0.cpuNanoseconds) }, uniquingKeysWith: { first, _ in first }), time)
        guard let previous, cores > 0, time > previous.time, time - previous.time <= LoadMeter.maxGap else { return nil }
        let capacity = (time - previous.time) * 1_000_000_000 * Double(cores)
        let cap = total ?? 100
        let loads = samples.compactMap { sample -> ProcessLoad? in
            guard let before = previous.times[sample.pid], sample.cpuNanoseconds > before else { return nil }
            return ProcessLoad(pid: sample.pid, name: sample.name, percent: min(Double(sample.cpuNanoseconds - before) / capacity * 100, cap))
        }
        return Array(loads.sorted { $0.percent > $1.percent }.prefix(Self.shown))
    }
}

struct GPUSmoother {
    static let maxRise = 20.0
    static let keptShare = 0.35

    private var value: Double?

    mutating func update(_ raw: Double) -> Double {
        let next = value.map { raw > $0 ? min(raw, $0 + Self.maxRise) : Self.keptShare * $0 + (1 - Self.keptShare) * raw } ?? raw
        value = next
        return next
    }
}

struct Held<Value> {
    static var tolerance: Int { 3 }

    private var value: Value?
    private var failures = 0

    mutating func update(_ new: Value?) -> Value? {
        if let new {
            value = new
            failures = 0
        } else {
            failures += 1
            if failures > Self.tolerance { value = nil }
        }
        return value
    }
}

enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

struct MemoryRaw: Equatable, Sendable {
    var pageSize: UInt64
    var physical: UInt64
    var internalPages: UInt64
    var purgeablePages: UInt64
    var wiredPages: UInt64
    var compressorPages: UInt64
    var externalPages: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressureLevel: Int?
}

struct MemoryReading: Equatable {
    let total: UInt64
    let used: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64
    let pressure: MemoryPressure?

    init(_ raw: MemoryRaw) {
        let app = (raw.internalPages > raw.purgeablePages ? raw.internalPages - raw.purgeablePages : 0) * raw.pageSize
        let wired = raw.wiredPages * raw.pageSize
        let compressed = raw.compressorPages * raw.pageSize
        total = raw.physical
        used = min(app + wired + compressed, raw.physical)
        self.app = app
        self.wired = wired
        self.compressed = compressed
        cached = raw.externalPages * raw.pageSize
        swapUsed = raw.swapUsed
        swapTotal = raw.swapTotal
        pressure = raw.pressureLevel.flatMap(MemoryPressure.init(rawValue:))
    }

    func bytes(_ metric: MemoryMetric) -> UInt64 {
        metric == .app ? app : used
    }

    func percent(_ metric: MemoryMetric) -> Double {
        guard total > 0 else { return 0 }
        return min(Double(bytes(metric)) / Double(total) * 100, 100)
    }
}

struct ByteCounters: Equatable, Sendable {
    var incoming: UInt64 = 0
    var outgoing: UInt64 = 0

    static func delta<Key: Hashable>(from old: [Key: ByteCounters], to new: [Key: ByteCounters]) -> ByteCounters {
        new.reduce(into: ByteCounters()) { sum, entry in
            guard let before = old[entry.key] else { return }
            sum.incoming += entry.value.incoming >= before.incoming ? entry.value.incoming - before.incoming : 0
            sum.outgoing += entry.value.outgoing >= before.outgoing ? entry.value.outgoing - before.outgoing : 0
        }
    }
}

struct Throughput: Equatable {
    let incoming: Double
    let outgoing: Double
}

struct RateMeter<Key: Hashable> {
    let maxGap: TimeInterval
    let needsSameKeys: Bool
    private(set) var total = ByteCounters()
    private var last: (counters: [Key: ByteCounters], time: TimeInterval)?

    init(maxGap: TimeInterval, needsSameKeys: Bool) {
        self.maxGap = maxGap
        self.needsSameKeys = needsSameKeys
    }

    mutating func update(_ counters: [Key: ByteCounters], at time: TimeInterval) -> Throughput? {
        let previous = last
        last = (counters, time)
        guard let previous, time > previous.time, time - previous.time <= maxGap,
              !needsSameKeys || Set(previous.counters.keys) == Set(counters.keys) else { return nil }
        let delta = ByteCounters.delta(from: previous.counters, to: counters)
        total.incoming += delta.incoming
        total.outgoing += delta.outgoing
        let elapsed = time - previous.time
        return Throughput(incoming: Double(delta.incoming) / elapsed, outgoing: Double(delta.outgoing) / elapsed)
    }
}

enum NetworkInterfaces {
    static let skippedPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "feth", "gif", "stf", "ap", "anpi"]
    static let maxGap: TimeInterval = 10

    static func isCounted(_ name: String) -> Bool {
        !skippedPrefixes.contains { name.hasPrefix($0) }
    }
}

enum DiskActivity {
    static let maxGap: TimeInterval = 15
}

struct VolumeReading: Equatable, Identifiable, Sendable {
    let name: String
    let path: String
    let total: Int64
    let free: Int64

    var id: String { path }
    var freePercent: Double { total > 0 ? Double(free) / Double(total) * 100 : 0 }
    var usedPercent: Double { total > 0 ? 100 - freePercent : 0 }
}

struct BatteryReading: Equatable, Sendable {
    static let maxMinutes = 7 * 24 * 60

    let charge: Double
    let watts: Double?
    let isCharging: Bool
    let isPluggedIn: Bool
    let cycleCount: Int?
    let health: Double?
    let chargerWatts: Double?
    let minutesRemaining: Int?
    let temperature: Double?

    init?(_ properties: [String: Any]) {
        func number(_ key: String) -> NSNumber? { properties[key] as? NSNumber }
        if properties["BatteryInstalled"] as? Bool == false { return nil }
        guard let current = number("CurrentCapacity")?.doubleValue, let maximum = number("MaxCapacity")?.doubleValue, maximum > 0 else { return nil }
        charge = min(current / maximum * 100, 100)
        isCharging = properties["IsCharging"] as? Bool ?? false
        isPluggedIn = properties["ExternalConnected"] as? Bool ?? false
        if let voltage = number("Voltage")?.doubleValue, let amperage = number("Amperage")?.intValue {
            watts = voltage * Double(amperage) / 1_000_000
        } else {
            watts = nil
        }
        cycleCount = number("CycleCount")?.intValue
        let fullCharge = number("AppleRawMaxCapacity")?.doubleValue ?? (maximum > 100 ? maximum : nil)
        if let fullCharge, let design = number("DesignCapacity")?.doubleValue, design > 0 {
            health = fullCharge / design * 100
        } else {
            health = nil
        }
        let adapter = (properties["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber
        chargerWatts = isPluggedIn ? adapter.map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil } : nil
        let minutes = number("TimeRemaining")?.intValue
        minutesRemaining = !isPluggedIn ? minutes.flatMap { (1...Self.maxMinutes).contains($0) ? $0 : nil } : nil
        temperature = number("Temperature").map { $0.doubleValue / 100 }.flatMap { SensorReading.plausible.contains($0) ? $0 : nil }
    }
}

enum SMCDecoder {
    static func code(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func text(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }

    static func value(type: String, bytes: [UInt8]) -> Double? {
        switch (type, bytes.count) {
        case ("flt ", 4):
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            return Double(Float32(bitPattern: bits))
        case ("sp78", 2):
            return Double(Int16(bitPattern: bigEndian(bytes))) / 256
        case ("fpe2", 2):
            return Double(bigEndian(bytes)) / 4
        case ("ui8 ", 1), ("ui16", 2), ("ui32", 4):
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default:
            return nil
        }
    }

    private static func bigEndian(_ bytes: [UInt8]) -> UInt16 {
        UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }
}

struct SensorReading: Equatable {
    enum Kind {
        case cpu, gpu, battery
    }

    static let plausible = 10.0...125.0
    static let maxFans = 10
    static let fanCountKey = "FNum"
    static let systemPowerKey = "PSTR"

    let cpu: Double?
    let gpu: Double?
    let battery: Double?
    let fans: [Double]
    let systemPower: Double?

    init(_ values: [String: Double]) {
        cpu = Self.average(values, .cpu)
        gpu = Self.average(values, .gpu)
        battery = Self.average(values, .battery)
        let count = min(Int(max(values[Self.fanCountKey] ?? 0, 0)), Self.maxFans)
        fans = (0..<count).compactMap { values["F\($0)Ac"] }.filter { $0 >= 0 }
        systemPower = values[Self.systemPowerKey].flatMap { $0 > 0 && $0 < 1000 ? $0 : nil }
    }

    static func kind(of key: String) -> Kind? {
        let characters = Array(key)
        guard characters.count == 4, characters[0] == "T" else { return nil }
        switch characters[1] {
        case "p", "e": return .cpu
        case "g": return .gpu
        case "B": return characters[2].isNumber && characters[3] == "T" ? .battery : nil
        default: return nil
        }
    }

    static func isWanted(_ key: String) -> Bool {
        if kind(of: key) != nil || key == fanCountKey || key == systemPowerKey { return true }
        let characters = Array(key)
        return characters.count == 4 && characters[0] == "F" && characters[1].isNumber && key.hasSuffix("Ac")
    }

    private static func average(_ values: [String: Double], _ kind: Kind) -> Double? {
        let temperatures = values.filter { Self.kind(of: $0.key) == kind && plausible.contains($0.value) }.map(\.value)
        return temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count)
    }
}

struct MonitorRaw: Sendable {
    var time: TimeInterval
    var cpu: CPUTicks?
    var cores: [CPUTicks]?
    var levels: [PerfLevel] = []
    var coreCount = 1
    var processes: [ProcessSample]?
    var gpu: Double?
    var memory: MemoryRaw?
    var interfaces: [String: ByteCounters]?
    var volumes: [VolumeReading]?
    var disks: [UInt64: ByteCounters]?
    var battery: BatteryReading?
    var sensors: [String: Double]?
}

struct MonitorSnapshot: Equatable {
    var cpu: Double?
    var cores: [CoreGroup] = []
    var processes: [ProcessLoad] = []
    var gpu: Double?
    var memory: MemoryReading?
    var network: Throughput?
    var networkTotal = ByteCounters()
    var volumes: [VolumeReading] = []
    var diskIO: Throughput?
    var battery: BatteryReading?
    var sensors: SensorReading?

    var power: Double? { battery?.watts ?? sensors?.systemPower }
    var startupVolume: VolumeReading? { volumes.first { $0.path == "/" } ?? volumes.first }
}

struct MonitorEngine {
    private var cpuMeter = LoadMeter()
    private var coreMeter = LoadMeter()
    private var processMeter = ProcessMeter()
    private var gpuSmoother = GPUSmoother()
    private var networkMeter = RateMeter<String>(maxGap: NetworkInterfaces.maxGap, needsSameKeys: true)
    private var diskMeter = RateMeter<UInt64>(maxGap: DiskActivity.maxGap, needsSameKeys: false)
    private var cpu = Held<Double>()
    private var cores = Held<[CoreGroup]>()
    private var processes = Held<[ProcessLoad]>()
    private var gpu = Held<Double>()
    private var memory = Held<MemoryReading>()
    private var network = Held<Throughput>()
    private var disk = Held<Throughput>()
    private var battery = Held<BatteryReading>()
    private var sensors = Held<SensorReading>()
    private var volumes: [VolumeReading] = []

    mutating func updateCPU(_ ticks: CPUTicks?, at time: TimeInterval) -> Double? {
        let usage = ticks.flatMap { cpuMeter.update([$0], at: time)?.first ?? nil }
        return cpu.update(usage)
    }

    mutating func update(_ raw: MonitorRaw) -> MonitorSnapshot {
        var next = MonitorSnapshot()
        next.cpu = updateCPU(raw.cpu, at: raw.time)
        let loads = raw.cores.flatMap { coreMeter.update($0, at: raw.time) }
        next.cores = cores.update(loads.map { CoreGroup.groups($0, levels: raw.levels) }) ?? []
        let top = raw.processes.flatMap { processMeter.update($0, at: raw.time, cores: raw.coreCount, total: next.cpu) }
        next.processes = processes.update(top) ?? []
        let smoothed = raw.gpu.map { gpuSmoother.update($0) }
        next.gpu = gpu.update(smoothed)
        next.memory = memory.update(raw.memory.map(MemoryReading.init))
        let interfaces = raw.interfaces.map { $0.filter { NetworkInterfaces.isCounted($0.key) } }
        let rate = interfaces.flatMap { networkMeter.update($0, at: raw.time) }
        next.network = network.update(rate)
        next.networkTotal = networkMeter.total
        if let read = raw.volumes { volumes = read }
        next.volumes = volumes
        let activity = raw.disks.flatMap { diskMeter.update($0, at: raw.time) }
        next.diskIO = disk.update(activity)
        next.battery = battery.update(raw.battery)
        next.sensors = sensors.update(raw.sensors.map(SensorReading.init))
        return next
    }
}

struct SampleRing: Equatable {
    static let capacity = 120

    private(set) var values: [Double] = []

    mutating func append(_ value: Double?) {
        guard let value else { return }
        values.append(value)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }

    var scaled: [Double] {
        let peak = values.max() ?? 0
        return peak > 0 ? values.map { $0 / peak * 100 } : values
    }
}

struct MonitorHistory: Equatable {
    var cpu = SampleRing()
    var gpu = SampleRing()
    var memory = SampleRing()
    var download = SampleRing()
    var upload = SampleRing()
    var diskRead = SampleRing()
    var diskWrite = SampleRing()

    mutating func append(_ snapshot: MonitorSnapshot, memory metric: MemoryMetric) {
        cpu.append(snapshot.cpu)
        gpu.append(snapshot.gpu)
        memory.append(snapshot.memory?.percent(metric))
        download.append(snapshot.network?.incoming)
        upload.append(snapshot.network?.outgoing)
        diskRead.append(snapshot.diskIO?.incoming)
        diskWrite.append(snapshot.diskIO?.outgoing)
    }
}
