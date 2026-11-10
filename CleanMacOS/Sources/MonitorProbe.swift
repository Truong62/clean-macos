import Darwin
import Foundation
import IOKit

enum MonitorProbe {
    struct Request: Sendable {
        var processes: Bool
        var volumes: Bool
        var sensors: Bool
    }

    private static let host = mach_host_self()
    private static let perfLevels: [PerfLevel] = {
        guard let count = sysctlInt("hw.nperflevels"), count > 0 else { return [] }
        return (0..<count).compactMap { level in
            sysctlInt("hw.perflevel\(level).logicalcpu").map { PerfLevel(name: sysctlString("hw.perflevel\(level).name") ?? "Level \(level)", cores: $0) }
        }
    }()
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()
    private static let volumeKeys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeIsReadOnlyKey,
                                                          .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
    private static let interfaceSlack = 1024

    static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    static func read(_ request: Request) -> MonitorRaw {
        MonitorRaw(time: uptime(), cpu: cpuTicks(), cores: coreTicks(), levels: perfLevels, coreCount: ProcessInfo.processInfo.activeProcessorCount,
                   processes: request.processes ? processes() : nil, gpu: gpuUtilization(), memory: memory(), interfaces: interfaces(),
                   volumes: request.volumes ? volumes() : nil, disks: diskCounters(), battery: battery(), sensors: request.sensors ? SMCReader.values() : nil)
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    static func coreTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { core in
            let tick = { (state: Int32) in UInt32(bitPattern: info[core * states + Int(state)]) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    static func processes() -> [ProcessSample]? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return nil }
        return pids.prefix(min(count, pids.count)).compactMap { pid in
            guard pid > 0, let time = cpuNanoseconds(pid) else { return nil }
            return ProcessSample(pid: pid, name: processName(pid), cpuNanoseconds: time)
        }
    }

    static func gpuUtilization() -> Double? {
        services("IOAccelerator") { service in
            ((property(service, "PerformanceStatistics") as? [String: Any])?["Device Utilization %"] as? NSNumber)?.doubleValue
        }.max()
    }

    static func memory() -> MemoryRaw? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        return MemoryRaw(pageSize: UInt64(vm_kernel_page_size), physical: ProcessInfo.processInfo.physicalMemory,
                         internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
                         wiredPages: UInt64(stats.wire_count), compressorPages: UInt64(stats.compressor_page_count),
                         externalPages: UInt64(stats.external_page_count), swapUsed: hasSwap ? swap.xsu_used : 0, swapTotal: hasSwap ? swap.xsu_total : 0,
                         pressureLevel: sysctlInt("kern.memorystatus_vm_pressure_level"))
    }

    static func interfaces() -> [String: ByteCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        length += interfaceSlack
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        var counters: [String: ByteCounters] = [:]
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self) }
            guard header.ifm_msglen > 0 else { break }
            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                let message = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
                if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                    counters[String(cString: name)] = ByteCounters(incoming: message.ifm_data.ifi_ibytes, outgoing: message.ifm_data.ifi_obytes)
                }
            }
            offset += Int(header.ifm_msglen)
        }
        return counters
    }

    static func volumes() -> [VolumeReading] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var mounts = Array(repeating: statfs(), count: Int(count))
        let filled = Int(getfsstat(&mounts, Int32(mounts.count * MemoryLayout<statfs>.stride), MNT_NOWAIT))
        return mounts.prefix(max(filled, 0)).compactMap { mount in
            guard mount.f_flags & UInt32(MNT_LOCAL) != 0, mount.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { return nil }
            let path = withUnsafeBytes(of: mount.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return volume(at: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private static func volume(at url: URL) -> VolumeReading? {
        guard let values = try? url.resourceValues(forKeys: volumeKeys), let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let free = values.volumeIsReadOnly == true ? values.volumeAvailableCapacity.map(Int64.init) : values.volumeAvailableCapacityForImportantUsage
        guard let free else { return nil }
        return VolumeReading(name: values.volumeLocalizedName ?? url.lastPathComponent, path: url.path, total: Int64(total), free: free)
    }

    static func diskCounters() -> [UInt64: ByteCounters]? {
        let entries = services("IOBlockStorageDriver") { service -> (UInt64, ByteCounters)? in
            guard let statistics = property(service, "Statistics") as? [String: Any],
                  let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
                  let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value else { return nil }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            return (id, ByteCounters(incoming: read, outgoing: written))
        }
        return entries.isEmpty ? nil : Dictionary(entries, uniquingKeysWith: { first, _ in first })
    }

    static func battery() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return BatteryReading(dictionary)
    }

    private static func cpuNanoseconds(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        return (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom
    }

    private static func processName(_ pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN + 1))
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return "PID \(pid)" }
        return String(cString: name)
    }

    private static func services<T>(_ className: String, _ transform: (io_registry_entry_t) -> T?) -> [T] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var results: [T] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let value = transform(service) { results.append(value) }
            IOObjectRelease(service)
        }
        return results
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

enum SMCReader {
    struct Key: Sendable {
        let name: String
        let code: UInt32
        let size: UInt32
        let type: String
    }

    private static let structSize = 80
    private static let selector: UInt32 = 2
    private static let keyOffset = 0
    private static let sizeOffset = 28
    private static let typeOffset = 32
    private static let resultOffset = 40
    private static let commandOffset = 42
    private static let indexOffset = 44
    private static let bytesOffset = 48
    private static let maxBytes = 32
    private static let readCommand: UInt8 = 5
    private static let indexCommand: UInt8 = 8
    private static let infoCommand: UInt8 = 9
    private static let maxKeys = 20_000

    static let keys: [Key] = {
        guard let connection = open() else { return [] }
        defer { IOServiceClose(connection) }
        let countKey = SMCDecoder.code("#KEY")
        guard let countInfo = info(connection, countKey), let countBytes = bytes(connection, countKey, size: countInfo.size),
              let count = SMCDecoder.value(type: SMCDecoder.text(countInfo.type), bytes: countBytes), count > 0, count < Double(maxKeys) else { return [] }
        return (0..<UInt32(count)).compactMap { index in
            guard let output = call(connection, command: indexCommand, index: index) else { return nil }
            let code = load(output, at: keyOffset)
            let name = SMCDecoder.text(code)
            guard SensorReading.isWanted(name), let keyInfo = info(connection, code) else { return nil }
            return Key(name: name, code: code, size: keyInfo.size, type: SMCDecoder.text(keyInfo.type))
        }
    }()

    static func values() -> [String: Double]? {
        guard !keys.isEmpty, let connection = open() else { return nil }
        defer { IOServiceClose(connection) }
        var readings: [String: Double] = [:]
        for key in keys {
            if let raw = bytes(connection, key.code, size: key.size), let value = SMCDecoder.value(type: key.type, bytes: raw) { readings[key.name] = value }
        }
        return readings.isEmpty ? nil : readings
    }

    private static func open() -> io_connect_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS ? connection : nil
    }

    private static func info(_ connection: io_connect_t, _ code: UInt32) -> (size: UInt32, type: UInt32)? {
        call(connection, command: infoCommand, key: code).map { (load($0, at: sizeOffset), load($0, at: typeOffset)) }
    }

    private static func bytes(_ connection: io_connect_t, _ code: UInt32, size: UInt32) -> [UInt8]? {
        let count = min(Int(size), maxBytes)
        return call(connection, command: readCommand, key: code, size: size).map { Array($0[bytesOffset..<bytesOffset + count]) }
    }

    private static func call(_ connection: io_connect_t, command: UInt8, key: UInt32 = 0, size: UInt32 = 0, index: UInt32 = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: structSize)
        store(key, in: &input, at: keyOffset)
        store(size, in: &input, at: sizeOffset)
        store(index, in: &input, at: indexOffset)
        input[commandOffset] = command
        var output = [UInt8](repeating: 0, count: structSize)
        var outputSize = structSize
        guard IOConnectCallStructMethod(connection, selector, input, structSize, &output, &outputSize) == KERN_SUCCESS,
              output[resultOffset] == 0 else { return nil }
        return output
    }

    private static func store(_ value: UInt32, in buffer: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value) { buffer.replaceSubrange(offset..<offset + 4, with: $0) }
    }

    private static func load(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}
