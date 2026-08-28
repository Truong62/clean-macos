import AppKit
import Darwin
import Foundation

final class ProcessService: Sendable {
    func list() async -> [RunningProcess] {
        let output = await Task.detached(priority: .utility) {
            Self.readProcessOutput()
        }.value
        guard let output else { return [] }

        let applicationKinds = await MainActor.run {
            Dictionary(
                NSWorkspace.shared.runningApplications
                    .filter { $0.processIdentifier > 0 }
                    .map { application -> (pid_t, RunningProcessKind) in
                        (application.processIdentifier, application.activationPolicy == .regular ? .app : .backgroundApp)
                    },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return Self.parse(output, currentUser: NSUserName(), applicationKinds: applicationKinds)
    }

    func memoryUsage() -> RAMUsage {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS, total > 0 else { return .empty }

        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        let percent = min(Double(used) / Double(total) * 100, 100)
        let pressure: RAMPressure
        if percent >= 85 {
            pressure = .high
        } else if percent >= 70 {
            pressure = .moderate
        } else {
            pressure = .low
        }
        return RAMUsage(usedBytes: used, totalBytes: total, pressurePercent: percent, pressure: pressure)
    }

    func terminate(_ process: RunningProcess, mode: ProcessTerminationMode) async throws -> ProcessTerminationOutcome {
        try Self.validateTermination(process)

        let applicationAccepted: Bool? = await MainActor.run {
            guard process.kind == .app,
                  let application = NSWorkspace.shared.runningApplications.first(where: {
                      $0.processIdentifier == process.pid
                  }) else { return nil }
            return mode == .force ? application.forceTerminate() : application.terminate()
        }

        if let applicationAccepted {
            guard applicationAccepted else { throw ProcessServiceError.requestRejected(process.name) }
        } else {
            let signal = mode == .force ? SIGKILL : SIGTERM
            guard Darwin.kill(process.pid, signal) == 0 else {
                let code = errno
                throw code == EPERM
                    ? ProcessServiceError.needsAdministrator(process.user)
                    : ProcessServiceError.signalFailed(process.pid, code)
            }
        }

        for _ in 0..<15 {
            if Self.processIsGone(process.pid) {
                return ProcessTerminationOutcome(processName: process.name, pid: process.pid, mode: mode)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ProcessServiceError.didNotExit(process.name, process.pid)
    }

    func refusalReason(for process: RunningProcess) -> String? {
        do {
            try Self.validateTermination(process)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func parse(
        _ output: String,
        currentUser: String,
        applicationKinds: [pid_t: RunningProcessKind] = [:]
    ) -> [RunningProcess] {
        output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                  let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]),
                  let cpu = Double(fields[2]),
                  let rss = UInt64(fields[3]) else { return nil }

            let user = String(fields[4])
            let path = String(fields[5]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return RunningProcess(
                pid: pid,
                ppid: ppid,
                cpuPercent: cpu,
                rssKilobytes: rss,
                user: user,
                path: path,
                kind: applicationKinds[pid] ?? .daemon,
                isSystem: user != currentUser
            )
        }
    }

    static func validateTermination(_ process: RunningProcess) throws {
        if process.pid == 0 || process.pid == 1 || process.name == "kernel_task" {
            throw ProcessServiceError.protectedProcess("\(process.name) (PID \(process.pid))")
        }
        if process.isSystem {
            throw ProcessServiceError.needsAdministrator(process.user)
        }
    }

    private static func readProcessOutput() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,ppid=,%cpu=,rss=,user=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func processIsGone(_ pid: pid_t) -> Bool {
        guard Darwin.kill(pid, 0) == -1 else { return false }
        return errno == ESRCH
    }
}
