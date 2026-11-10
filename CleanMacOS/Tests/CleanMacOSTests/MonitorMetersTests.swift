import Foundation
import Testing
@testable import CleanMacOS

struct MonitorMetersTests {
    private func near(_ value: Double?, _ expected: Double) -> Bool {
        value.map { abs($0 - expected) < 1e-9 } ?? false
    }

    private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32) -> CPUTicks {
        CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    @Test func cpuUsageIsBusyTicksOverAllTicks() {
        #expect(ticks(130, 60, 850, 60).usage(since: ticks(100, 50, 800, 50)) == 50)
        #expect(ticks(100, 50, 800, 50).usage(since: ticks(100, 50, 800, 50)) == nil)
        #expect(ticks(90, 50, 900, 50).usage(since: ticks(100, 50, 800, 50)) == nil)
    }

    @Test func loadMeterStartsWithABaselineAndRestartsAfterAGap() {
        var meter = LoadMeter()
        #expect(meter.update([ticks(100, 50, 800, 50)], at: 0) == nil)
        #expect(meter.update([ticks(130, 60, 850, 60)], at: 2) == [50])
        #expect(meter.update([ticks(230, 60, 850, 60)], at: 14.5) == [100])
        #expect(meter.update([ticks(240, 60, 940, 60)], at: 30) == nil)
        #expect(meter.update([ticks(250, 60, 1030, 60)], at: 32) == [10])
        #expect(meter.update([ticks(250, 60, 1030, 60), ticks(1, 1, 1, 1)], at: 34) == nil)
        #expect(meter.update([ticks(260, 70, 1110, 60), ticks(0, 1, 1, 1)], at: 36) == [20, nil])
    }

    @Test func groupsCoresByPerformanceLevelWithTheSlowestCoresFirst() {
        let loads: [Double?] = (0..<10).map(Double.init)
        let groups = CoreGroup.groups(loads, levels: [PerfLevel(name: "Performance", cores: 4), PerfLevel(name: "Efficiency", cores: 6)])
        #expect(groups == [CoreGroup(name: "Performance", loads: [6, 7, 8, 9]), CoreGroup(name: "Efficiency", loads: [0, 1, 2, 3, 4, 5])])
        #expect(CoreGroup.groups(loads, levels: [PerfLevel(name: "Performance", cores: 4)]) == [CoreGroup(name: "Cores", loads: loads)])
        #expect(CoreGroup.groups([nil, 5], levels: []) == [CoreGroup(name: "Cores", loads: [nil, 5])])
    }

    @Test func processLoadIsAShareOfEveryCoreCappedAtTheTotal() {
        var meter = ProcessMeter()
        let first = [ProcessSample(pid: 1, name: "busy", cpuNanoseconds: 0), ProcessSample(pid: 2, name: "calm", cpuNanoseconds: 3_000_000_000),
                     ProcessSample(pid: 3, name: "idle", cpuNanoseconds: 50)]
        #expect(meter.update(first, at: 10, cores: 4, total: 50) == nil)
        let second = [ProcessSample(pid: 1, name: "busy", cpuNanoseconds: 2_000_000_000), ProcessSample(pid: 2, name: "calm", cpuNanoseconds: 4_000_000_000),
                      ProcessSample(pid: 3, name: "idle", cpuNanoseconds: 50), ProcessSample(pid: 4, name: "new", cpuNanoseconds: 9_000_000_000)]
        #expect(meter.update(second, at: 12, cores: 4, total: 20) == [ProcessLoad(pid: 1, name: "busy", percent: 20), ProcessLoad(pid: 2, name: "calm", percent: 12.5)])
        #expect(meter.update(second, at: 30, cores: 4, total: 20) == nil)
        var fresh = ProcessMeter()
        let many = (1...8).map { ProcessSample(pid: Int32($0), name: "p\($0)", cpuNanoseconds: UInt64($0) * 100_000_000) }
        _ = fresh.update(many.map { ProcessSample(pid: $0.pid, name: $0.name, cpuNanoseconds: 0) }, at: 0, cores: 4, total: nil)
        let top = fresh.update(many, at: 1, cores: 4, total: nil)
        #expect(top?.count == ProcessMeter.shown)
        #expect(top?.first == ProcessLoad(pid: 8, name: "p8", percent: 20))
    }

    @Test func gpuRisesAtMostTwentyPointsAndFallsSmoothly() {
        var gpu = GPUSmoother()
        #expect(near(gpu.update(10), 10))
        #expect(near(gpu.update(80), 30))
        #expect(near(gpu.update(40), 40))
        #expect(near(gpu.update(0), 14))
        #expect(near(gpu.update(100), 34))
    }

    @Test func holdsTheLastGoodValueThroughThreeFailures() {
        var held = Held<Int>()
        #expect(held.update(nil) == nil)
        #expect(held.update(5) == 5)
        #expect(held.update(nil) == 5)
        #expect(held.update(nil) == 5)
        #expect(held.update(nil) == 5)
        #expect(held.update(nil) == nil)
        #expect(held.update(7) == 7)
        #expect(held.update(nil) == 7)
    }

    @Test func memoryCountsAppWiredAndCompressedPages() {
        let page: UInt64 = 16_384
        let memory = MemoryReading(MemoryRaw(pageSize: page, physical: 16 * 1_073_741_824, internalPages: 1000, purgeablePages: 200, wiredPages: 300,
                                             compressorPages: 100, externalPages: 50, swapUsed: 1, swapTotal: 2, pressureLevel: 4))
        #expect(memory.app == 800 * page)
        #expect(memory.wired == 300 * page)
        #expect(memory.compressed == 100 * page)
        #expect(memory.used == 1200 * page)
        #expect(memory.cached == 50 * page)
        #expect(memory.swapUsed == 1 && memory.swapTotal == 2)
        #expect(memory.pressure == .critical)
        let tight = MemoryReading(MemoryRaw(pageSize: 1, physical: 100, internalPages: 90, purgeablePages: 0, wiredPages: 30, compressorPages: 10,
                                            externalPages: 0, swapUsed: 0, swapTotal: 0, pressureLevel: 2))
        #expect(tight.used == 100)
        #expect(tight.percent(.used) == 100)
        #expect(tight.percent(.app) == 90)
        #expect(tight.pressure == .warning)
        let odd = MemoryReading(MemoryRaw(pageSize: 1, physical: 100, internalPages: 5, purgeablePages: 9, wiredPages: 0, compressorPages: 0,
                                          externalPages: 0, swapUsed: 0, swapTotal: 0, pressureLevel: 3))
        #expect(odd.app == 0)
        #expect(odd.pressure == nil)
        #expect(MemoryPressure(rawValue: 1) == .normal)
    }

    @Test func networkRatesSkipBackwardCountersAndRestartOnGapsOrNewInterfaces() {
        var meter = RateMeter<String>(maxGap: NetworkInterfaces.maxGap, needsSameKeys: true)
        #expect(meter.update(["en0": ByteCounters(incoming: 1000, outgoing: 100)], at: 0) == nil)
        #expect(meter.update(["en0": ByteCounters(incoming: 3000, outgoing: 500)], at: 2) == Throughput(incoming: 1000, outgoing: 200))
        #expect(meter.update(["en0": ByteCounters(incoming: 10, outgoing: 900)], at: 4) == Throughput(incoming: 0, outgoing: 200))
        #expect(meter.update(["en0": ByteCounters(incoming: 20, outgoing: 900), "en1": ByteCounters(incoming: 5, outgoing: 5)], at: 6) == nil)
        #expect(meter.update(["en0": ByteCounters(incoming: 40, outgoing: 900), "en1": ByteCounters(incoming: 5, outgoing: 5)], at: 17) == nil)
        #expect(meter.update(["en0": ByteCounters(incoming: 60, outgoing: 1000), "en1": ByteCounters(incoming: 25, outgoing: 5)], at: 21) == Throughput(incoming: 10, outgoing: 25))
        #expect(meter.total == ByteCounters(incoming: 2040, outgoing: 900))
    }

    @Test func skipsLoopbackTunnelsAndPeerToPeerInterfaces() {
        for name in ["en0", "en1", "en7", "pdp_ip0"] { #expect(NetworkInterfaces.isCounted(name)) }
        for name in ["lo0", "utun3", "awdl0", "llw0", "bridge0", "feth1", "gif0", "stf0", "ap1", "anpi0"] { #expect(!NetworkInterfaces.isCounted(name)) }
    }

    @Test func diskActivityIgnoresNewDrivesAndLongGaps() {
        var meter = RateMeter<UInt64>(maxGap: DiskActivity.maxGap, needsSameKeys: false)
        #expect(meter.update([1: ByteCounters(incoming: 100, outgoing: 0)], at: 0) == nil)
        let attached: [UInt64: ByteCounters] = [1: ByteCounters(incoming: 1100, outgoing: 50), 2: ByteCounters(incoming: 999_999, outgoing: 999_999)]
        #expect(meter.update(attached, at: 1) == Throughput(incoming: 1000, outgoing: 50))
        #expect(meter.update([1: ByteCounters(incoming: 1200, outgoing: 50)], at: 2) == Throughput(incoming: 100, outgoing: 0))
        #expect(meter.update([1: ByteCounters(incoming: 1300, outgoing: 50)], at: 17.5) == nil)
    }

    @Test func readsADischargingLaptopBattery() throws {
        let battery = try #require(BatteryReading([
            "BatteryInstalled": true, "CurrentCapacity": 80, "MaxCapacity": 100, "Voltage": 12000, "Amperage": NSNumber(value: Int64(-1500)),
            "AppleRawMaxCapacity": 4500, "DesignCapacity": 5000, "CycleCount": 120, "IsCharging": false, "ExternalConnected": false,
            "TimeRemaining": 300, "Temperature": 3050, "AdapterDetails": ["FamilyCode": 0],
        ]))
        #expect(battery.charge == 80)
        #expect(near(battery.watts, -18))
        #expect(near(battery.health, 90))
        #expect(battery.cycleCount == 120)
        #expect(battery.minutesRemaining == 300)
        #expect(battery.chargerWatts == nil)
        #expect(near(battery.temperature, 30.5))
        #expect(!battery.isCharging && !battery.isPluggedIn)
    }

    @Test func readsAChargingBatteryAndItsCharger() throws {
        let battery = try #require(BatteryReading([
            "CurrentCapacity": 2500, "MaxCapacity": 5000, "DesignCapacity": 6000, "Voltage": 12000, "Amperage": 2000, "IsCharging": true,
            "ExternalConnected": true, "TimeRemaining": 90, "AdapterDetails": ["Watts": 67],
        ]))
        #expect(battery.charge == 50)
        #expect(near(battery.watts, 24))
        #expect(near(battery.health, 250.0 / 3))
        #expect(battery.chargerWatts == 67)
        #expect(battery.minutesRemaining == nil)
        #expect(battery.temperature == nil)
    }

    @Test func keepsTimeRemainingBetweenOneMinuteAndSevenDays() {
        func minutes(_ value: Int) -> Int? {
            BatteryReading(["CurrentCapacity": 50, "MaxCapacity": 100, "ExternalConnected": false, "TimeRemaining": value])?.minutesRemaining
        }
        #expect(minutes(0) == nil)
        #expect(minutes(1) == 1)
        #expect(minutes(BatteryReading.maxMinutes) == BatteryReading.maxMinutes)
        #expect(minutes(65_535) == nil)
    }

    @Test func aDesktopReportsNoBattery() {
        #expect(BatteryReading([
            "Amperage": 0, "CurrentCapacity": 0, "MaxCapacity": 0, "IsCharging": false, "AdapterDetails": ["FamilyCode": 0], "BatteryInstalled": false,
            "Voltage": 0, "CycleCount": 0, "ExternalConnected": true, "TimeRemaining": 0, "built-in": true,
        ]) == nil)
        #expect(BatteryReading(["CurrentCapacity": 0, "MaxCapacity": 0]) == nil)
        #expect(BatteryReading([:]) == nil)
    }

    @Test func decodesSMCValues() {
        #expect(SMCDecoder.value(type: "flt ", bytes: [0x00, 0xa0, 0x81, 0x44]) == 1037)
        #expect(SMCDecoder.value(type: "sp78", bytes: [0x2d, 0x80]) == 45.5)
        #expect(SMCDecoder.value(type: "sp78", bytes: [0xff, 0x00]) == -1)
        #expect(SMCDecoder.value(type: "fpe2", bytes: [0x1b, 0x58]) == 1750)
        #expect(SMCDecoder.value(type: "ui8 ", bytes: [0x01]) == 1)
        #expect(SMCDecoder.value(type: "ui16", bytes: [0x01, 0x00]) == 256)
        #expect(SMCDecoder.value(type: "ui32", bytes: [0, 0, 5, 72]) == 1352)
        #expect(SMCDecoder.value(type: "flt ", bytes: [0, 0]) == nil)
        #expect(SMCDecoder.value(type: "hex_", bytes: [0, 0]) == nil)
        #expect(SMCDecoder.code("TC0P") == 0x5443_3050)
        #expect(SMCDecoder.text(SMCDecoder.code("F0Ac")) == "F0Ac")
    }

    @Test func averagesPlausibleTemperaturesAndListsFans() {
        let sensors = SensorReading(["Tp01": 60, "Te05": 50, "Tp09": 200, "Tg0D": 45, "Tg0L": .nan, "TB0T": 31, "TB1T": 33, "TA0P": 90,
                                     "FNum": 2, "F0Ac": 1200, "F1Ac": 1300, "F2Ac": 999, "PSTR": 15.5])
        #expect(sensors.cpu == 55)
        #expect(sensors.gpu == 45)
        #expect(sensors.battery == 32)
        #expect(sensors.fans == [1200, 1300])
        #expect(sensors.systemPower == 15.5)
        let empty = SensorReading(["Tp01": 5, "FNum": 0, "F0Ac": 1000, "PSTR": 0])
        #expect(empty.cpu == nil && empty.gpu == nil && empty.battery == nil)
        #expect(empty.fans.isEmpty)
        #expect(empty.systemPower == nil)
    }

    @Test func wantsOnlyTemperatureFanAndPowerKeys() {
        for key in ["Tp0f", "Te04", "Tg0D", "TB0T", "TB9T", "FNum", "F0Ac", "F3Ac", "PSTR"] { #expect(SensorReading.isWanted(key)) }
        for key in ["TBXT", "TA0P", "TC0P", "F0Mx", "FOff", "#KEY", "Tp1", "PDTR"] { #expect(!SensorReading.isWanted(key)) }
        #expect(SensorReading.kind(of: "TB2T") == .battery)
        #expect(SensorReading.kind(of: "Te0S") == .cpu)
    }

    @Test func engineCombinesEverySeries() {
        let volume = VolumeReading(name: "Macintosh HD", path: "/", total: 500_000_000_000, free: 100_000_000_000)
        let levels = [PerfLevel(name: "Performance", cores: 1), PerfLevel(name: "Efficiency", cores: 1)]
        let memory = MemoryRaw(pageSize: 1, physical: 100, internalPages: 40, purgeablePages: 0, wiredPages: 10, compressorPages: 0, externalPages: 5,
                               swapUsed: 0, swapTotal: 0, pressureLevel: 1)
        var raw = MonitorRaw(time: 0, cpu: ticks(100, 50, 800, 50), cores: [ticks(0, 0, 0, 0), ticks(0, 0, 0, 0)], levels: levels, coreCount: 2,
                             processes: [ProcessSample(pid: 9, name: "app", cpuNanoseconds: 0)], gpu: 50, memory: memory,
                             interfaces: ["en0": ByteCounters(), "utun0": ByteCounters()], volumes: [volume], disks: [1: ByteCounters()], battery: nil,
                             sensors: ["Tp01": 50])
        var engine = MonitorEngine()
        let first = engine.update(raw)
        #expect(first.cpu == nil)
        #expect(first.network == nil)
        #expect(first.gpu == 50)
        #expect(first.volumes == [volume])
        #expect(first.sensors?.cpu == 50)
        #expect(first.memory?.used == 50)
        #expect(first.battery == nil)
        raw.time = 2
        raw.cpu = ticks(130, 60, 850, 60)
        raw.cores = [ticks(10, 0, 10, 0), ticks(0, 0, 20, 0)]
        raw.processes = [ProcessSample(pid: 9, name: "app", cpuNanoseconds: 1_000_000_000)]
        raw.gpu = nil
        raw.interfaces = ["en0": ByteCounters(incoming: 2000, outgoing: 200), "utun0": ByteCounters(incoming: 1_000_000, outgoing: 1_000_000)]
        raw.volumes = nil
        raw.disks = [1: ByteCounters(incoming: 4096, outgoing: 0)]
        let second = engine.update(raw)
        #expect(second.cpu == 50)
        #expect(second.cores == [CoreGroup(name: "Performance", loads: [0]), CoreGroup(name: "Efficiency", loads: [50])])
        #expect(second.processes == [ProcessLoad(pid: 9, name: "app", percent: 25)])
        #expect(second.gpu == 50)
        #expect(second.network == Throughput(incoming: 1000, outgoing: 100))
        #expect(second.networkTotal == ByteCounters(incoming: 2000, outgoing: 200))
        #expect(second.volumes == [volume])
        #expect(second.diskIO == Throughput(incoming: 2048, outgoing: 0))
        #expect(engine.updateCPU(ticks(160, 70, 900, 70), at: 4) == 50)
    }

    @Test func snapshotPrefersBatteryPowerAndTheStartupVolume() {
        var snapshot = MonitorSnapshot()
        #expect(snapshot.power == nil)
        snapshot.sensors = SensorReading(["PSTR": 18])
        #expect(snapshot.power == 18)
        snapshot.battery = BatteryReading(["CurrentCapacity": 50, "MaxCapacity": 100, "Voltage": 10000, "Amperage": -500])
        #expect(near(snapshot.power, -5))
        let external = VolumeReading(name: "Backup", path: "/Volumes/Backup", total: 100, free: 50)
        let startup = VolumeReading(name: "Macintosh HD", path: "/", total: 100, free: 10)
        snapshot.volumes = [external, startup]
        #expect(snapshot.startupVolume == startup)
        #expect(startup.usedPercent == 90)
        #expect(startup.freePercent == 10)
    }

    @Test func ringKeepsTheLatestSamples() {
        var ring = SampleRing()
        ring.append(nil)
        #expect(ring.values.isEmpty)
        for value in 0..<(SampleRing.capacity + 5) { ring.append(Double(value)) }
        #expect(ring.values.count == SampleRing.capacity)
        #expect(ring.values.first == 5)
        #expect(ring.values.last == Double(SampleRing.capacity + 4))
        var small = SampleRing()
        [0.0, 5, 10].forEach { small.append($0) }
        #expect(small.scaled == [0, 50, 100])
        var history = MonitorHistory()
        var snapshot = MonitorSnapshot()
        snapshot.cpu = 12
        snapshot.network = Throughput(incoming: 3, outgoing: 4)
        history.append(snapshot, memory: .used)
        #expect(history.cpu.values == [12])
        #expect(history.download.values == [3] && history.upload.values == [4])
        #expect(history.gpu.values.isEmpty && history.memory.values.isEmpty)
    }
}
