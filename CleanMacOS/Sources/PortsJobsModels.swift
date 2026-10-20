import Foundation

struct ListeningPort: Identifiable, Hashable, Sendable {
    let port: Int
    let pid: pid_t
    let command: String
    let user: String
    let addresses: [String]

    var id: String { "\(pid):\(port)" }
    var isLocalOnly: Bool { addresses.allSatisfy { $0.hasPrefix("127.") || $0 == "[::1]" } }
    var scopeLabel: String { isLocalOnly ? "Localhost" : "Network" }
    var url: URL? { URL(string: "http://localhost:\(port)") }

    var process: RunningProcess {
        RunningProcess(pid: pid, ppid: 0, cpuPercent: 0, rssKilobytes: 0, user: user, path: command,
                       kind: .daemon, isSystem: user != NSUserName())
    }
}

enum ScheduledJobSource: String, CaseIterable, Sendable {
    case userAgent
    case globalAgent
    case globalDaemon
    case cron

    var label: String {
        switch self {
        case .userAgent: "Your Agent"
        case .globalAgent: "All Users Agent"
        case .globalDaemon: "System Daemon"
        case .cron: "Crontab"
        }
    }

    var isManageable: Bool { self == .userAgent }
    var isDeletable: Bool { self == .userAgent || self == .cron }
}

struct ProcessDetails: Equatable, Sendable {
    let elapsed: String
    let arguments: String
    var cpuPercent: Double = 0
    var rssKilobytes: UInt64 = 0
    var parentPID: pid_t = 0
    var parentName = ""
    var directory: String?

    var readableElapsed: String { Self.readableElapsed(elapsed) }

    static func readableElapsed(_ etime: String) -> String {
        let dayParts = etime.split(separator: "-")
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        let days = dayParts.count == 2 ? Int(dayParts[0]) : 0
        guard let days, (2...3).contains(clock.count) else { return etime }
        let (hours, minutes, seconds) = clock.count == 3 ? (clock[0], clock[1], clock[2]) : (0, clock[0], clock[1])
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return minutes > 0 ? "\(minutes)m" : "\(seconds)s"
    }
}

struct LaunchctlStatus: Equatable, Sendable {
    let pid: pid_t?
    let lastExitStatus: Int?
}

struct ScheduledJob: Identifiable, Hashable, Sendable {
    let label: String
    let source: ScheduledJobSource
    let command: String
    let schedule: String
    let plistPath: String?
    let logPaths: [String]
    let isLoaded: Bool
    let pid: pid_t?
    let lastExitStatus: Int?
    var cronLine: String? = nil
    var startsAtLogin = false

    var id: String { "\(source.rawValue):\(label)" }
    var isRunning: Bool { pid != nil }

    var statusLabel: String {
        if source == .cron { return "Scheduled" }
        if source == .globalDaemon && !isLoaded { return "—" }
        if let pid { return "Running · PID \(pid)" }
        guard isLoaded else { return "Stopped" }
        if let lastExitStatus, lastExitStatus < 0 { return "Killed (signal \(-lastExitStatus))" }
        if let lastExitStatus, lastExitStatus != 0 { return "Failed (exit \(lastExitStatus))" }
        return "Idle"
    }
}

enum PortsJobsError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        }
    }
}

struct LoginItem: Identifiable, Hashable, Sendable {
    let name: String
    let path: String?
    let isEnabled: Bool
    let isMissing: Bool

    var id: String { path ?? name }

    var statusLabel: String {
        if isMissing { return "App not found" }
        return isEnabled ? "Opens at login" : "Off"
    }
}
