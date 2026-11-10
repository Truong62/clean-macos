import Foundation
import Testing
@testable import CleanMacOS

struct MonitorSettingsTests {
    private func memory(percent: UInt64, pressure: Int) -> MemoryReading {
        MemoryReading(MemoryRaw(pageSize: 1, physical: 100, internalPages: percent, purgeablePages: 0, wiredPages: 0, compressorPages: 0, externalPages: 0,
                                swapUsed: 0, swapTotal: 0, pressureLevel: pressure))
    }

    private func battery(charge: Int, charging: Bool) -> BatteryReading? {
        BatteryReading(["CurrentCapacity": charge, "MaxCapacity": 100, "IsCharging": charging, "ExternalConnected": charging])
    }

    @Test func everythingIsOffByDefault() throws {
        let settings = MonitorSettings()
        #expect(settings.readouts.isEmpty)
        #expect(!settings.alerts.isAnyOn)
        #expect(!settings.needsSampling)
        #expect(!settings.needsSensors)
        #expect(settings.interval == 2)
        #expect(settings.readoutStyle == .values)
        #expect(settings.memoryReadout == .percent)
        #expect(settings.memoryMetric == .used)
        #expect(settings.networkUnit == .bytes)
        #expect(settings.readoutOrder == MonitorReadout.allCases)
        #expect(settings.alerts.cooldownMinutes == 15)
        var changed = settings
        changed.readouts = [.cpu, .network]
        changed.alerts.lowDisk = true
        changed.readoutStyle = .bars
        let decoded = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(changed))
        #expect(decoded == changed)
    }

    @Test func readoutsAndAlertsDecideWhatGetsSampled() {
        var settings = MonitorSettings()
        settings.readouts = [.network]
        #expect(settings.needsSampling)
        #expect(!settings.needsSensors)
        settings.readouts = [.fan]
        #expect(settings.needsSensors)
        settings.readouts = []
        settings.alerts.memoryPressure = true
        #expect(settings.needsSampling)
        #expect(!settings.needsSensors)
        settings.alerts.batteryTemperature = true
        #expect(settings.needsSensors)
        #expect(settings.sampleInterval == 2)
        settings.interval = 5
        #expect(settings.sampleInterval == 5)
        settings.interval = 7
        #expect(settings.sampleInterval == 2)
    }

    @Test func movesReadoutsWithinTheirOrder() {
        var settings = MonitorSettings()
        settings.move(.gpu, by: -1)
        #expect(Array(settings.readoutOrder.prefix(3)) == [.cpu, .gpu, .cpuTemperature])
        settings.move(.cpu, by: -1)
        settings.move(.fan, by: 1)
        #expect(settings.readoutOrder.first == .cpu)
        #expect(settings.readoutOrder.last == .fan)
        settings.readouts = [.cpuTemperature, .gpu]
        #expect(settings.shownReadouts == [.gpu, .cpuTemperature])
    }

    @Test func formatsRatesInBytesOrBits() {
        #expect(MonitorFormat.rate(nil, unit: .bytes) == "—")
        #expect(MonitorFormat.rate(0, unit: .bytes) == "0 B/s")
        #expect(MonitorFormat.rate(512, unit: .bytes) == "512 B/s")
        #expect(MonitorFormat.rate(999.4, unit: .bytes) == "999 B/s")
        #expect(MonitorFormat.rate(999.6, unit: .bytes) == "1.0 KB/s")
        #expect(MonitorFormat.rate(1536, unit: .bytes) == "1.5 KB/s")
        #expect(MonitorFormat.rate(10 * 1024, unit: .bytes) == "10 KB/s")
        #expect(MonitorFormat.rate(5 * 1024 * 1024, unit: .bytes) == "5.0 MB/s")
        #expect(MonitorFormat.rate(1000, unit: .bits) == "8.0 Kb/s")
        #expect(MonitorFormat.rate(125_000, unit: .bits) == "1.0 Mb/s")
        #expect(MonitorFormat.rate(-5, unit: .bits) == "0 b/s")
    }

    @Test func ratesNeverOutgrowTheirReservedWidth() {
        for unit in NetworkUnit.allCases {
            for step in 0..<44 {
                let text = MonitorFormat.rate(pow(1.8, Double(step)), unit: unit)
                #expect(text.prefix { $0 != " " }.count <= 3)
                #expect(MonitorFormat.rateUnits(unit).contains(String(text.drop { $0 != " " }.dropFirst())))
            }
        }
    }

    @Test func formatsValuesForReadouts() {
        #expect(MonitorFormat.percent(12.4) == "12%")
        #expect(MonitorFormat.percent(150) == "100%")
        #expect(MonitorFormat.percent(-3) == "0%")
        #expect(MonitorFormat.percent(nil) == "—")
        #expect(MonitorFormat.temperature(52.6) == "53°C")
        #expect(MonitorFormat.watts(12.34) == "12.3W")
        #expect(MonitorFormat.watts(-5) == "-5.0W")
        #expect(MonitorFormat.watts(140) == "140W")
        #expect(MonitorFormat.rpm(1037.4) == "1037 rpm")
        #expect(MonitorFormat.minutes(75) == "1 h 15 min")
        #expect(MonitorFormat.minutes(45) == "45 min")
    }

    @Test func barsTurnElevatedAtSeventyAndCriticalAtNinety() {
        #expect(MonitorReadouts.level(69.9) == .normal)
        #expect(MonitorReadouts.level(70) == .elevated)
        #expect(MonitorReadouts.level(89.9) == .elevated)
        #expect(MonitorReadouts.level(90) == .critical)
    }

    @Test func buildsValueCellsInTheChosenOrder() {
        var snapshot = MonitorSnapshot()
        snapshot.cpu = 42.4
        snapshot.network = Throughput(incoming: 1024, outgoing: 0)
        snapshot.volumes = [VolumeReading(name: "Backup", path: "/Volumes/Backup", total: 100, free: 90), VolumeReading(name: "Macintosh HD", path: "/", total: 100, free: 25)]
        snapshot.sensors = SensorReading(["Tp01": 61, "FNum": 2, "F0Ac": 1200, "F1Ac": 1500, "PSTR": 9.5])
        var settings = MonitorSettings()
        settings.readouts = [.cpu, .network, .disk, .cpuTemperature, .power, .fan, .battery]
        let cells = MonitorReadouts.cells(snapshot, settings: settings)
        #expect(cells.map(\.label) == ["CPU", nil, "BAT", nil, "DSK", "PWR", nil])
        #expect(cells[0] == ReadoutCell(label: "CPU", lines: ["42%"], templates: ["100%"]))
        #expect(cells[1].lines == ["61°C"])
        #expect(cells[2].lines == ["—"])
        #expect(cells[3].lines == ["↓ 1.0 KB/s", "↑ 0 B/s"])
        #expect(cells[3].templates.allSatisfy { $0.hasPrefix("↓ 999 ") })
        #expect(cells[4].lines == ["75%"])
        #expect(cells[5].lines == ["9.5W"])
        #expect(cells[6].lines == ["1500 rpm"])
        let isColored = cells.contains { $0.needsColor }
        #expect(!isColored)
    }

    @Test func buildsBarCellsWithWarningLevels() {
        var snapshot = MonitorSnapshot()
        snapshot.cpu = 95
        snapshot.gpu = 75
        snapshot.battery = battery(charge: 95, charging: false)
        var settings = MonitorSettings()
        settings.readouts = [.cpu, .gpu, .battery, .disk]
        settings.readoutStyle = .bars
        let cells = MonitorReadouts.cells(snapshot, settings: settings)
        #expect(cells[0] == ReadoutCell(label: "CPU", bar: 0.95, level: .critical))
        #expect(cells[1].level == .elevated)
        #expect(cells[2].level == .normal && cells[2].bar == 0.95)
        #expect(cells[3].bar == nil && cells[3].lines == ["—"])
        #expect(cells[0].needsColor && cells[1].needsColor && !cells[2].needsColor)
    }

    @Test func memoryShowsAPressureDotAPercentOrBoth() {
        var snapshot = MonitorSnapshot()
        snapshot.memory = memory(percent: 63, pressure: 2)
        var settings = MonitorSettings()
        settings.readouts = [.memory]
        settings.memoryReadout = .dot
        #expect(MonitorReadouts.cells(snapshot, settings: settings) == [ReadoutCell(label: "RAM", pressure: .warning)])
        settings.memoryReadout = .both
        #expect(MonitorReadouts.cells(snapshot, settings: settings) == [ReadoutCell(label: "RAM", lines: ["63%"], templates: ["100%"], pressure: .warning)])
        settings.memoryReadout = .percent
        #expect(MonitorReadouts.cells(snapshot, settings: settings) == [ReadoutCell(label: "RAM", lines: ["63%"], templates: ["100%"])])
        settings.memoryReadout = .dot
        #expect(MonitorReadouts.cells(MonitorSnapshot(), settings: settings) == [ReadoutCell(label: "RAM", lines: ["—"], templates: ["—"])])
    }

    @Test func summaryNamesMissingHardware() {
        var snapshot = MonitorSnapshot()
        snapshot.cpu = 10
        let lines = MonitorSummary.lines(snapshot, settings: MonitorSettings())
        #expect(lines.first == "CPU 10%")
        #expect(lines.contains("No battery"))
        #expect(lines.contains("Sensors unavailable"))
        snapshot.battery = battery(charge: 80, charging: true)
        snapshot.sensors = SensorReading(["Tp01": 50, "Tg05": 40, "FNum": 1, "F0Ac": 1000])
        let full = MonitorSummary.lines(snapshot, settings: MonitorSettings())
        #expect(full.contains("Battery 80%, charging"))
        #expect(full.contains("CPU 50°C · GPU 40°C"))
        #expect(full.contains("Fan 1000 rpm"))
    }

    @Test func cpuAlertWaitsTwelveSecondsAndThenRespectsTheCooldown() {
        var tracker = MonitorAlertTracker()
        var settings = MonitorAlertSettings()
        settings.cpu = true
        var busy = MonitorSnapshot()
        busy.cpu = 95
        #expect(tracker.check(busy, settings: settings, at: 0).isEmpty)
        #expect(tracker.check(busy, settings: settings, at: 6).isEmpty)
        #expect(tracker.check(busy, settings: settings, at: 12).map(\.kind) == [.cpu])
        #expect(tracker.check(busy, settings: settings, at: 14).isEmpty)
        #expect(tracker.check(busy, settings: settings, at: 12 + 15 * 60 - 1).isEmpty)
        #expect(tracker.check(busy, settings: settings, at: 12 + 15 * 60).map(\.kind) == [.cpu])
    }

    @Test func aDipResetsTheHoldTimer() {
        var tracker = MonitorAlertTracker()
        var settings = MonitorAlertSettings()
        settings.cpu = true
        settings.cpuPercent = 80
        var busy = MonitorSnapshot()
        busy.cpu = 85
        var calm = MonitorSnapshot()
        calm.cpu = 79
        #expect(tracker.check(busy, settings: settings, at: 0).isEmpty)
        #expect(tracker.check(calm, settings: settings, at: 5).isEmpty)
        #expect(tracker.check(busy, settings: settings, at: 10).isEmpty)
        #expect(tracker.check(busy, settings: settings, at: 17).isEmpty)
        #expect(tracker.check(MonitorSnapshot(), settings: settings, at: 19).isEmpty)
        #expect(tracker.check(busy, settings: settings, at: 20).isEmpty)
        let fired = tracker.check(busy, settings: settings, at: 32)
        #expect(fired == [MonitorAlert(kind: .cpu, title: "CPU is busy", body: "CPU at 85%, at or above 80% for 12 seconds.")])
    }

    @Test func alertsStayQuietWhileTurnedOff() {
        var tracker = MonitorAlertTracker()
        var snapshot = MonitorSnapshot()
        snapshot.cpu = 100
        snapshot.memory = memory(percent: 90, pressure: 4)
        snapshot.battery = battery(charge: 3, charging: false)
        for time in stride(from: 0.0, through: 60, by: 2) {
            #expect(tracker.check(snapshot, settings: MonitorAlertSettings(), at: time).isEmpty)
        }
    }

    @Test func memoryPressureAlertsRightAwayWhenCritical() {
        var tracker = MonitorAlertTracker()
        var settings = MonitorAlertSettings()
        settings.memoryPressure = true
        settings.cooldownMinutes = 2
        var snapshot = MonitorSnapshot()
        snapshot.memory = memory(percent: 50, pressure: 2)
        #expect(tracker.check(snapshot, settings: settings, at: 0).isEmpty)
        snapshot.memory = memory(percent: 50, pressure: 4)
        #expect(tracker.check(snapshot, settings: settings, at: 1).map(\.kind) == [.memoryPressure])
        #expect(tracker.check(snapshot, settings: settings, at: 120).isEmpty)
        #expect(tracker.check(snapshot, settings: settings, at: 121).map(\.kind) == [.memoryPressure])
    }

    @Test func lowDiskOnlyCountsVolumesOfTenGigabytesOrMore() {
        var tracker = MonitorAlertTracker()
        var settings = MonitorAlertSettings()
        settings.lowDisk = true
        var snapshot = MonitorSnapshot()
        snapshot.volumes = [VolumeReading(name: "Stick", path: "/Volumes/Stick", total: 8_000_000_000, free: 10_000_000),
                            VolumeReading(name: "Macintosh HD", path: "/", total: 500_000_000_000, free: 60_000_000_000)]
        #expect(tracker.check(snapshot, settings: settings, at: 0).isEmpty)
        snapshot.volumes.append(VolumeReading(name: "Work", path: "/Volumes/Work", total: 1_000_000_000_000, free: 40_000_000_000))
        let fired = tracker.check(snapshot, settings: settings, at: 2)
        #expect(fired.map(\.kind) == [.lowDisk])
        #expect(fired.first?.body.hasPrefix("Work has 4% free") == true)
    }

    @Test func lowBatteryWaitsUntilItIsNotCharging() {
        var settings = MonitorAlertSettings()
        settings.lowBattery = true
        var snapshot = MonitorSnapshot()
        snapshot.battery = battery(charge: 12, charging: true)
        var tracker = MonitorAlertTracker()
        #expect(tracker.check(snapshot, settings: settings, at: 0).isEmpty)
        snapshot.battery = battery(charge: 20, charging: false)
        #expect(tracker.check(snapshot, settings: settings, at: 2).isEmpty)
        snapshot.battery = battery(charge: 15, charging: false)
        #expect(tracker.check(snapshot, settings: settings, at: 4).map(\.kind) == [.lowBattery])
    }

    @Test func temperatureAlertsUseTheSensors() {
        var settings = MonitorAlertSettings()
        settings.cpuTemperature = true
        settings.batteryTemperature = true
        var snapshot = MonitorSnapshot()
        snapshot.sensors = SensorReading(["Tp01": 95, "TB0T": 41])
        var tracker = MonitorAlertTracker()
        #expect(tracker.check(snapshot, settings: settings, at: 0).map(\.kind) == [.batteryTemperature])
        #expect(tracker.check(snapshot, settings: settings, at: 12).map(\.kind) == [.cpuTemperature])
        snapshot.sensors = nil
        snapshot.battery = BatteryReading(["CurrentCapacity": 50, "MaxCapacity": 100, "Temperature": 4200])
        var fallback = MonitorAlertTracker()
        #expect(fallback.check(snapshot, settings: settings, at: 0).map(\.kind) == [.batteryTemperature])
        #expect(MonitorAlertKind.cpu.hold == 12 && MonitorAlertKind.lowDisk.hold == 0)
    }
}
