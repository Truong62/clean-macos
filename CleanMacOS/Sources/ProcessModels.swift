import Foundation

enum RunningProcessKind: String, CaseIterable, Sendable {
    case app
    case backgroundApp
    case daemon

    var label: String {
        switch self {
        case .app: "App"
        case .backgroundApp: "Background App"
        case .daemon: "Daemon"
        }
    }

    var systemImage: String {
        switch self {
        case .app: "macwindow"
        case .backgroundApp: "menubar.rectangle"
        case .daemon: "gearshape.2.fill"
        }
    }
}

struct RunningProcess: Identifiable, Hashable, Sendable {
    let pid: pid_t
    let ppid: pid_t
    let cpuPercent: Double
    let rssKilobytes: UInt64
    let user: String
    let path: String
    let kind: RunningProcessKind
    let isSystem: Bool

    var id: pid_t { pid }
    var name: String {
        let component = URL(fileURLWithPath: path).lastPathComponent
        return component.isEmpty ? path : component
    }
    var memoryBytes: UInt64 { rssKilobytes * 1_024 }
    var kindLabel: String { kind.label }
}

enum RAMProcessFilter: String, CaseIterable, Identifiable {
    case all
    case apps
    case background

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .apps: "Apps"
        case .background: "Background"
        }
    }
}

enum RAMPressure: String, Sendable {
    case low = "Low"
    case moderate = "Moderate"
    case high = "High"
}

struct RAMUsage: Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64
    let pressurePercent: Double
    let pressure: RAMPressure

    static let empty = RAMUsage(usedBytes: 0, totalBytes: 0, pressurePercent: 0, pressure: .low)
}

enum ProcessTerminationMode: Sendable {
    case graceful
    case force

    var label: String {
        switch self {
        case .graceful: "Quit"
        case .force: "Force Quit"
        }
    }
}

struct ProcessTerminationOutcome: Sendable {
    let processName: String
    let pid: pid_t
    let mode: ProcessTerminationMode

    var message: String { "\(mode.label) succeeded for \(processName) (PID \(pid))." }
}

enum ProcessServiceError: LocalizedError {
    case protectedProcess(String)
    case needsAdministrator(String)
    case signalFailed(pid_t, Int32)
    case requestRejected(String)
    case didNotExit(String, pid_t)

    var errorDescription: String? {
        switch self {
        case .protectedProcess(let name):
            "\(name) is protected and cannot be terminated."
        case .needsAdministrator(let user):
            "This process is owned by \(user) and needs administrator privileges."
        case .signalFailed(let pid, let code):
            "Could not terminate PID \(pid): \(String(cString: strerror(code))) (errno \(code))."
        case .requestRejected(let name):
            "macOS rejected the termination request for \(name)."
        case .didNotExit(let name, let pid):
            "\(name) (PID \(pid)) is still running. Try Force Quit."
        }
    }
}
