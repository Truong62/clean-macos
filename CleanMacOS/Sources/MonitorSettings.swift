import Foundation

enum MonitorReadout: String, Codable, CaseIterable, Identifiable {
    case cpu, cpuTemperature, gpu, memory, battery, network, disk, power, fan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .cpuTemperature: "CPU temperature"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .battery: "Battery"
        case .network: "Network"
        case .disk: "Disk"
        case .power: "Power"
        case .fan: "Fan speed"
        }
    }
}

enum ReadoutStyle: String, Codable, CaseIterable, Identifiable {
    case values, bars

    var id: String { rawValue }
    var title: String { self == .values ? "Values" : "Bars" }
}

enum MemoryReadoutStyle: String, Codable, CaseIterable, Identifiable {
    case dot, percent, both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dot: "Pressure dot"
        case .percent: "Percent"
        case .both: "Both"
        }
    }
}

enum MemoryMetric: String, Codable, CaseIterable, Identifiable {
    case used, app

    var id: String { rawValue }
    var title: String { self == .used ? "Used" : "App" }
}

enum NetworkUnit: String, Codable, CaseIterable, Identifiable {
    case bytes, bits

    var id: String { rawValue }
    var title: String { self == .bytes ? "Bytes" : "Bits" }
}

struct MonitorAlertSettings: Codable, Equatable {
    static let cpuRange = 50...100
    static let cpuTemperatureRange = 70...105
    static let batteryTemperatureRange = 30...50
    static let lowDiskRange = 5...30
    static let lowBatteryRange = 5...50
    static let cooldowns = [2, 5, 15, 30, 60]

    var cpu = false
    var cpuPercent = 90
    var cpuTemperature = false
    var cpuTemperatureLimit = 90
    var batteryTemperature = false
    var batteryTemperatureLimit = 40
    var memoryPressure = false
    var lowDisk = false
    var lowDiskPercent = 10
    var lowBattery = false
    var lowBatteryPercent = 15
    var cooldownMinutes = 15

    var isAnyOn: Bool { cpu || cpuTemperature || batteryTemperature || memoryPressure || lowDisk || lowBattery }
}

struct MonitorSettings: Codable, Equatable {
    static let intervals = [1, 2, 5]

    var interval = 2
    var memoryMetric = MemoryMetric.used
    var networkUnit = NetworkUnit.bytes
    var readoutOrder = MonitorReadout.allCases
    var readouts: Set<MonitorReadout> = []
    var readoutStyle = ReadoutStyle.values
    var memoryReadout = MemoryReadoutStyle.percent
    var alerts = MonitorAlertSettings()

    var shownReadouts: [MonitorReadout] { readoutOrder.filter(readouts.contains) }
    var needsSampling: Bool { !readouts.isEmpty || alerts.isAnyOn }
    var needsSensors: Bool { !readouts.isDisjoint(with: [.cpuTemperature, .fan, .power]) || alerts.cpuTemperature || alerts.batteryTemperature }
    var sampleInterval: TimeInterval { TimeInterval(Self.intervals.contains(interval) ? interval : 2) }

    mutating func move(_ readout: MonitorReadout, by offset: Int) {
        guard let index = readoutOrder.firstIndex(of: readout), readoutOrder.indices.contains(index + offset) else { return }
        readoutOrder.swapAt(index, index + offset)
    }
}

enum MonitorFormat {
    static let missing = "—"
    static let percentTemplate = "100%"
    static let temperatureTemplate = "125°C"
    static let wattsTemplate = "-99.9W"
    static let rpmTemplate = "9999 rpm"
    static let downArrow = "↓"
    static let upArrow = "↑"

    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", min(max($0, 0), 100)) } ?? missing
    }

    static func temperature(_ value: Double?) -> String {
        value.map { String(format: "%.0f°C", $0) } ?? missing
    }

    static func watts(_ value: Double?) -> String {
        value.map { String(format: abs($0) >= 100 ? "%.0fW" : "%.1fW", $0) } ?? missing
    }

    static func rpm(_ value: Double?) -> String {
        value.map { String(format: "%.0f rpm", $0) } ?? missing
    }

    static func rateUnits(_ unit: NetworkUnit) -> [String] {
        unit == .bits ? ["b/s", "Kb/s", "Mb/s", "Gb/s"] : ["B/s", "KB/s", "MB/s", "GB/s"]
    }

    static func rate(_ bytesPerSecond: Double?, unit: NetworkUnit) -> String {
        guard let bytesPerSecond else { return missing }
        let units = rateUnits(unit)
        let base = unit == .bits ? 1000.0 : 1024.0
        var value = max(bytesPerSecond, 0) * (unit == .bits ? 8 : 1)
        var index = 0
        while value >= 999.5 && index < units.count - 1 {
            value /= base
            index += 1
        }
        return String(format: index > 0 && value < 9.95 ? "%.1f" : "%.0f", value) + " " + units[index]
    }

    static func rateTemplates(_ unit: NetworkUnit, prefix: String = "") -> [String] {
        rateUnits(unit).map { prefix + "999 " + $0 }
    }

    static func minutes(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

struct ReadoutCell: Equatable {
    enum Level: Equatable {
        case normal, elevated, critical
    }

    var label: String?
    var lines: [String] = []
    var templates: [String] = []
    var bar: Double?
    var level = Level.normal
    var pressure: MemoryPressure?

    var needsColor: Bool { pressure != nil || (bar != nil && level != .normal) }
}

enum MonitorReadouts {
    static let elevated = 70.0
    static let critical = 90.0

    static func level(_ percent: Double) -> ReadoutCell.Level {
        percent >= critical ? .critical : percent >= elevated ? .elevated : .normal
    }

    static func cells(_ snapshot: MonitorSnapshot, settings: MonitorSettings) -> [ReadoutCell] {
        settings.shownReadouts.map { cell($0, snapshot: snapshot, settings: settings) }
    }

    static func cell(_ readout: MonitorReadout, snapshot: MonitorSnapshot, settings: MonitorSettings) -> ReadoutCell {
        let style = settings.readoutStyle
        switch readout {
        case .cpu:
            return percentCell("CPU", snapshot.cpu, style: style)
        case .gpu:
            return percentCell("GPU", snapshot.gpu, style: style)
        case .disk:
            return percentCell("DSK", snapshot.startupVolume?.usedPercent, style: style)
        case .battery:
            return percentCell("BAT", snapshot.battery?.charge, style: style, warns: false)
        case .memory:
            return memoryCell(snapshot.memory, settings: settings)
        case .cpuTemperature:
            return ReadoutCell(lines: [MonitorFormat.temperature(snapshot.sensors?.cpu)], templates: [MonitorFormat.temperatureTemplate])
        case .network:
            let unit = settings.networkUnit
            return ReadoutCell(lines: [MonitorFormat.downArrow + " " + MonitorFormat.rate(snapshot.network?.incoming, unit: unit),
                                       MonitorFormat.upArrow + " " + MonitorFormat.rate(snapshot.network?.outgoing, unit: unit)],
                               templates: MonitorFormat.rateTemplates(unit, prefix: MonitorFormat.downArrow + " "))
        case .power:
            return ReadoutCell(label: "PWR", lines: [MonitorFormat.watts(snapshot.power)], templates: [MonitorFormat.wattsTemplate])
        case .fan:
            return ReadoutCell(lines: [MonitorFormat.rpm(snapshot.sensors?.fans.max())], templates: [MonitorFormat.rpmTemplate])
        }
    }

    private static func percentCell(_ label: String, _ value: Double?, style: ReadoutStyle, warns: Bool = true) -> ReadoutCell {
        if style == .bars, let value {
            return ReadoutCell(label: label, bar: min(max(value / 100, 0), 1), level: warns ? level(value) : .normal)
        }
        return ReadoutCell(label: label, lines: [MonitorFormat.percent(value)], templates: [MonitorFormat.percentTemplate])
    }

    private static func memoryCell(_ memory: MemoryReading?, settings: MonitorSettings) -> ReadoutCell {
        var cell = settings.memoryReadout == .dot ? ReadoutCell(label: "RAM")
            : percentCell("RAM", memory?.percent(settings.memoryMetric), style: settings.readoutStyle)
        if settings.memoryReadout != .percent { cell.pressure = memory?.pressure }
        if cell.lines.isEmpty && cell.bar == nil && cell.pressure == nil {
            cell.lines = [MonitorFormat.missing]
            cell.templates = [MonitorFormat.missing]
        }
        return cell
    }
}

enum MonitorSummary {
    static func lines(_ snapshot: MonitorSnapshot, settings: MonitorSettings) -> [String] {
        let unit = settings.networkUnit
        var lines = ["CPU \(MonitorFormat.percent(snapshot.cpu))", "GPU \(MonitorFormat.percent(snapshot.gpu))"]
        if let memory = snapshot.memory {
            let metric = settings.memoryMetric
            lines.append("Memory \(MonitorFormat.percent(memory.percent(metric))) · \(formatBytes(Int64(clamping: memory.bytes(metric)))) of \(formatBytes(Int64(clamping: memory.total)))")
        }
        lines.append("Network \(MonitorFormat.downArrow) \(MonitorFormat.rate(snapshot.network?.incoming, unit: unit)) \(MonitorFormat.upArrow) \(MonitorFormat.rate(snapshot.network?.outgoing, unit: unit))")
        if let volume = snapshot.startupVolume {
            lines.append("\(volume.name) · \(formatBytes(volume.free)) free")
        }
        if let battery = snapshot.battery {
            lines.append("Battery \(MonitorFormat.percent(battery.charge))\(battery.isCharging ? ", charging" : "")")
        } else {
            lines.append("No battery")
        }
        if let sensors = snapshot.sensors {
            lines.append("CPU \(MonitorFormat.temperature(sensors.cpu)) · GPU \(MonitorFormat.temperature(sensors.gpu))")
            if let fan = sensors.fans.max() { lines.append("Fan \(MonitorFormat.rpm(fan))") }
        } else {
            lines.append("Sensors unavailable")
        }
        if let power = snapshot.power { lines.append("Power \(MonitorFormat.watts(power))") }
        return lines
    }
}

enum MonitorAlertKind: String, CaseIterable {
    case cpu, cpuTemperature, batteryTemperature, memoryPressure, lowDisk, lowBattery

    static let sustained: TimeInterval = 12
    static let bigVolume: Int64 = 10_000_000_000

    var hold: TimeInterval { self == .cpu || self == .cpuTemperature ? Self.sustained : 0 }

    func alert(for snapshot: MonitorSnapshot, settings: MonitorAlertSettings) -> MonitorAlert? {
        switch self {
        case .cpu:
            guard settings.cpu, let cpu = snapshot.cpu, cpu >= Double(settings.cpuPercent) else { return nil }
            return MonitorAlert(kind: self, title: "CPU is busy", body: "CPU at \(MonitorFormat.percent(cpu)), at or above \(settings.cpuPercent)% for 12 seconds.")
        case .cpuTemperature:
            guard settings.cpuTemperature, let heat = snapshot.sensors?.cpu, heat >= Double(settings.cpuTemperatureLimit) else { return nil }
            return MonitorAlert(kind: self, title: "CPU is hot",
                                body: "CPU at \(MonitorFormat.temperature(heat)), at or above \(settings.cpuTemperatureLimit)°C for 12 seconds.")
        case .batteryTemperature:
            guard settings.batteryTemperature, let heat = snapshot.sensors?.battery ?? snapshot.battery?.temperature,
                  heat >= Double(settings.batteryTemperatureLimit) else { return nil }
            return MonitorAlert(kind: self, title: "Battery is hot", body: "Battery at \(MonitorFormat.temperature(heat)).")
        case .memoryPressure:
            guard settings.memoryPressure, snapshot.memory?.pressure == .critical else { return nil }
            return MonitorAlert(kind: self, title: "Memory pressure is critical", body: "Quit apps you are not using to free up memory.")
        case .lowDisk:
            let full = snapshot.volumes.filter { $0.total >= Self.bigVolume && $0.freePercent < Double(settings.lowDiskPercent) }
            guard settings.lowDisk, !full.isEmpty else { return nil }
            let names = full.map { "\($0.name) has \(MonitorFormat.percent($0.freePercent)) free (\(formatBytes($0.free)))" }
            return MonitorAlert(kind: self, title: "Disk almost full", body: names.joined(separator: ", ") + ".")
        case .lowBattery:
            guard settings.lowBattery, let battery = snapshot.battery, !battery.isCharging,
                  battery.charge <= Double(settings.lowBatteryPercent) else { return nil }
            return MonitorAlert(kind: self, title: "Battery low", body: "Battery at \(MonitorFormat.percent(battery.charge)) and not charging.")
        }
    }
}

struct MonitorAlert: Equatable {
    let kind: MonitorAlertKind
    let title: String
    let body: String
}

struct MonitorAlertTracker {
    private var since: [MonitorAlertKind: TimeInterval] = [:]
    private var firedAt: [MonitorAlertKind: TimeInterval] = [:]

    mutating func check(_ snapshot: MonitorSnapshot, settings: MonitorAlertSettings, at time: TimeInterval) -> [MonitorAlert] {
        let cooldown = TimeInterval(settings.cooldownMinutes * 60)
        return MonitorAlertKind.allCases.compactMap { kind in
            guard let alert = kind.alert(for: snapshot, settings: settings) else {
                since[kind] = nil
                return nil
            }
            let start = since[kind] ?? time
            since[kind] = start
            guard time - start >= kind.hold, firedAt[kind].map({ time - $0 >= cooldown }) ?? true else { return nil }
            firedAt[kind] = time
            return alert
        }
    }
}
