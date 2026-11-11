import AppKit
import Foundation
import Darwin

@MainActor
final class SystemMonitor: ObservableObject {
    static let settingsKey = "monitor.settings"
    static let volumeRefresh: TimeInterval = 10

    @Published var cpuUsage: Double = 0
    @Published var memUsed: UInt64 = 0
    @Published var memTotal: UInt64 = 0
    @Published var memPercent: Double = 0
    @Published var diskUsed: UInt64 = 0
    @Published var diskTotal: UInt64 = 0
    @Published var diskPercent: Double = 0
    @Published var diskFree: UInt64 = 0
    @Published var uptime: String = ""
    @Published private(set) var latestCPU: Double = 0
    @Published var settings: MonitorSettings {
        didSet {
            guard settings != oldValue else { return }
            store?.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if settings.alerts.isAnyOn && !oldValue.alerts.isAnyOn { MonitorNotifier.shared.requestPermission() }
            reschedule()
        }
    }
    @Published private(set) var snapshot = MonitorSnapshot()
    @Published private(set) var history = MonitorHistory()

    let cpuName: String
    let osVersion: String

    private let store: UserDefaults?
    private var engine = MonitorEngine()
    private var alerts = MonitorAlertTracker()
    private var sampleTimer: Timer?
    private var activeInterval: TimeInterval?
    private var labelInterval: TimeInterval?
    private var popoverOpen = false
    private var isPageVisible = false
    private var isMonitoring = false
    private var isReading = false
    private var volumesReadAt: TimeInterval?

    init(store: UserDefaults? = nil) {
        self.store = store
        cpuName = Self.readCPUName()
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        settings = store?.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(MonitorSettings.self, from: $0) } ?? MonitorSettings()
        memTotal = ProcessInfo.processInfo.physicalMemory
        refreshPublishedValues(cpu: engine.updateCPU(MonitorProbe.cpuTicks(), at: MonitorProbe.uptime()) ?? 0)
        reschedule()
    }

    var showsReadouts: Bool { !settings.readouts.isEmpty }
    var showsCPUReadout: Bool { settings.readouts.contains(.cpu) }
    var readoutImage: NSImage {
        let cells = MonitorReadouts.cells(snapshot, settings: settings)
        return ReadoutImage.make(cells)
    }

    func startSampling(interval: TimeInterval = 3) {
        guard labelInterval == nil else { return }
        labelInterval = interval
        reschedule()
    }

    func stopSampling() {
        labelInterval = nil
        reschedule()
    }

    func startPublishing(interval: TimeInterval) {
        popoverOpen = true
        startSampling(interval: interval)
        refreshPublishedValues(cpu: latestCPU)
    }

    func popoverDidOpen() {
        popoverOpen = true
        refreshPublishedValues(cpu: latestCPU)
    }

    func popoverDidClose() {
        popoverOpen = false
    }

    func setPageVisible(_ isVisible: Bool) {
        isPageVisible = isVisible
        reschedule()
    }

    private func reschedule() {
        let monitoring = isPageVisible || settings.needsSampling
        if monitoring && !isMonitoring {
            engine = MonitorEngine()
            snapshot = MonitorSnapshot()
            history = MonitorHistory()
            volumesReadAt = nil
        }
        isMonitoring = monitoring
        let interval = monitoring ? settings.sampleInterval : labelInterval
        guard interval != activeInterval else { return }
        sampleTimer?.invalidate()
        sampleTimer = nil
        activeInterval = interval
        guard let interval else { return }
        sample()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sample()
            }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    private func sample() {
        if isMonitoring {
            readEverything()
            return
        }
        if let cpu = engine.updateCPU(MonitorProbe.cpuTicks(), at: MonitorProbe.uptime()) { latestCPU = cpu }
        if popoverOpen {
            refreshPublishedValues(cpu: latestCPU)
        }
    }

    private func readEverything() {
        guard !isReading else { return }
        isReading = true
        let now = MonitorProbe.uptime()
        let readsVolumes = volumesReadAt.map { now - $0 >= Self.volumeRefresh } ?? true
        if readsVolumes { volumesReadAt = now }
        let request = MonitorProbe.Request(processes: isPageVisible, volumes: readsVolumes, sensors: isPageVisible || settings.needsSensors)
        Task {
            let raw = await Task.detached(priority: .utility) { MonitorProbe.read(request) }.value
            isReading = false
            apply(raw)
        }
    }

    private func apply(_ raw: MonitorRaw) {
        let next = engine.update(raw)
        snapshot = next
        history.append(next, memory: settings.memoryMetric)
        if let cpu = next.cpu { latestCPU = cpu }
        if popoverOpen {
            refreshPublishedValues(cpu: latestCPU)
        }
        alerts.check(next, settings: settings.alerts, at: raw.time).forEach(MonitorNotifier.shared.post)
    }

    private func refreshPublishedValues(cpu: Double) {
        let mem = Self.readMemory()
        let disk = Self.readDisk()
        cpuUsage = cpu
        memUsed = mem.used
        memTotal = ProcessInfo.processInfo.physicalMemory
        memPercent = mem.percent
        diskUsed = disk.used
        diskTotal = disk.total
        diskFree = disk.free
        diskPercent = disk.percent
        uptime = Self.readUptime()
    }

    private static func readCPUName() -> String {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        return String(cString: name)
    }

    private static func readMemory() -> (used: UInt64, percent: Double) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (0, 0) }

        let pageSize = UInt64(vm_kernel_page_size)
        let used = UInt64(stats.active_count) * pageSize
            + UInt64(stats.wire_count) * pageSize
            + UInt64(stats.compressor_page_count) * pageSize

        return (used, Double(used) / Double(total) * 100)
    }

    private static func readDisk() -> (used: UInt64, total: UInt64, free: UInt64, percent: Double) {
        var stat = statfs()
        guard statfs("/", &stat) == 0 else { return (0, 0, 0, 0) }

        let blockSize = UInt64(stat.f_bsize)
        let total = stat.f_blocks * blockSize
        let free = UInt64(stat.f_bavail) * blockSize
        let used = total - free
        return (used, total, free, Double(used) / Double(total) * 100)
    }

    private static func readUptime() -> String {
        let time = Int(ProcessInfo.processInfo.systemUptime)
        let hours = time / 3600
        let minutes = (time % 3600) / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h \(minutes)m" }
        return "\(hours)h \(minutes)m"
    }

    var memUsedStr: String { Self.fmtSize(memUsed) }
    var memTotalStr: String { Self.fmtSize(memTotal) }
    var diskUsedStr: String { Self.fmtSize(diskUsed) }
    var diskTotalStr: String { Self.fmtSize(diskTotal) }
    var diskFreeStr: String { Self.fmtSize(diskFree) }

    private static func fmtSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 100 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }
}
