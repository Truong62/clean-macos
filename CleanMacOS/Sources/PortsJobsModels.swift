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
    let logPath: String?
    let isLoaded: Bool
    let pid: pid_t?
    let lastExitStatus: Int?

    var id: String { "\(source.rawValue):\(label)" }
    var isRunning: Bool { pid != nil }

    var statusLabel: String {
        if source == .cron { return "Scheduled" }
        if source == .globalDaemon && !isLoaded { return "—" }
        if let pid { return "Running · PID \(pid)" }
        guard isLoaded else { return "Stopped" }
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
