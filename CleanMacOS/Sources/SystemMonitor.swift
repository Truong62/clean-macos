import Foundation
import Darwin

final class SystemMonitor: ObservableObject {
    // Published chỉ update khi popover đang mở
    @Published var cpuUsage: Double = 0
    @Published var memUsed: UInt64 = 0
    @Published var memTotal: UInt64 = 0
    @Published var memPercent: Double = 0
    @Published var diskUsed: UInt64 = 0
    @Published var diskTotal: UInt64 = 0
    @Published var diskPercent: Double = 0
    @Published var diskFree: UInt64 = 0
    @Published var uptime: String = ""

    // Static info (chỉ đọc 1 lần)
    let cpuName: String
    let osVersion: String

    // Background state — không trigger UI
    private(set) var latestCPU: Double = 0
    private var prevCPUInfo: host_cpu_load_info?
    private var sampleTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "monitor.sample", qos: .utility)
    private var popoverOpen = false

    init() {
        cpuName = Self.readCPUName()
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        memTotal = ProcessInfo.processInfo.physicalMemory
    }

    // MARK: - Background sampling (luôn chạy nhẹ, không update UI)

    func startSampling(interval: TimeInterval = 3) {
        stopSampling()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            self?.sample()
        }
        t.resume()
        sampleTimer = t
    }

    func stopSampling() {
        sampleTimer?.cancel()
        sampleTimer = nil
    }

    // Sample nhẹ — chỉ đọc CPU, không push UI
    private func sample() {
        latestCPU = readCPUUsage()

        // Chỉ update @Published khi popover đang mở
        if popoverOpen {
            let mem = Self.readMemory()
            let disk = Self.readDisk()
            let up = Self.readUptime()
            let cpu = latestCPU

            DispatchQueue.main.async { [weak self] in
                guard let self, self.popoverOpen else { return }
                self.cpuUsage = cpu
                self.memUsed = mem.used
                self.memPercent = mem.percent
                self.diskUsed = disk.used
                self.diskTotal = disk.total
                self.diskFree = disk.free
                self.diskPercent = disk.percent
                self.uptime = up
            }
        }
    }

    // MARK: - Popover lifecycle

    func popoverDidOpen() {
        popoverOpen = true
        // Đọc 1 lần ngay lập tức khi mở
        queue.async { [weak self] in
            guard let self else { return }
            let cpu = self.latestCPU
            let mem = Self.readMemory()
            let disk = Self.readDisk()
            let up = Self.readUptime()

            DispatchQueue.main.async {
                self.cpuUsage = cpu
                self.memUsed = mem.used
                self.memPercent = mem.percent
                self.diskUsed = disk.used
                self.diskTotal = disk.total
                self.diskFree = disk.free
                self.diskPercent = disk.percent
                self.uptime = up
            }
        }
    }

    func popoverDidClose() {
        popoverOpen = false
    }

    // MARK: - CPU (instance method vì cần prevCPUInfo state)

    private func readCPUUsage() -> Double {
        var loadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &loadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        let user = Double(loadInfo.cpu_ticks.0)
        let system = Double(loadInfo.cpu_ticks.1)
        let idle = Double(loadInfo.cpu_ticks.2)
        let nice = Double(loadInfo.cpu_ticks.3)

        defer { prevCPUInfo = loadInfo }

        if let prev = prevCPUInfo {
            let dUser = user - Double(prev.cpu_ticks.0)
            let dSystem = system - Double(prev.cpu_ticks.1)
            let dIdle = idle - Double(prev.cpu_ticks.2)
            let dNice = nice - Double(prev.cpu_ticks.3)
            let total = dUser + dSystem + dIdle + dNice
            return total > 0 ? ((dUser + dSystem + dNice) / total) * 100 : 0
        }

        let total = user + system + idle + nice
        return total > 0 ? ((user + system + nice) / total) * 100 : 0
    }

    // MARK: - Static reads (pure functions, no state)

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
        let t = Int(ProcessInfo.processInfo.systemUptime)
        let h = t / 3600
        let m = (t % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h \(m)m" }
        return "\(h)h \(m)m"
    }

    // MARK: - Formatted strings

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
