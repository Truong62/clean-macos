import SwiftUI

// MARK: - Category

enum ArtifactCategory: String, CaseIterable, Identifiable, Hashable {
    case dependencies, build, cache, coverage, infrastructure, logs, misc
    case system, xcode, docker, backup, mail, media, vm, downloads, crash

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dependencies: "Dependencies"
        case .build: "Build"
        case .cache: "Cache"
        case .coverage: "Coverage"
        case .infrastructure: "Infrastructure"
        case .logs: "Logs"
        case .misc: "Misc"
        case .system: "System"
        case .xcode: "Xcode"
        case .docker: "Docker"
        case .backup: "Backup"
        case .mail: "Mail"
        case .media: "Media"
        case .vm: "VMs"
        case .downloads: "Downloads"
        case .crash: "Crash Reports"
        }
    }

    var icon: String {
        switch self {
        case .dependencies: "shippingbox"
        case .build: "hammer"
        case .cache: "internaldrive"
        case .coverage: "chart.bar"
        case .infrastructure: "server.rack"
        case .logs: "doc.text"
        case .misc: "ellipsis.circle"
        case .system: "gearshape"
        case .xcode: "wrench.and.screwdriver"
        case .docker: "cube"
        case .backup: "externaldrive"
        case .mail: "envelope"
        case .media: "play.circle"
        case .vm: "desktopcomputer"
        case .downloads: "arrow.down.circle"
        case .crash: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .dependencies: .blue
        case .build: .orange
        case .cache: .purple
        case .coverage: .green
        case .infrastructure: .gray
        case .logs: .yellow
        case .misc: .secondary
        case .system: .red
        case .xcode: .cyan
        case .docker: .blue
        case .backup: .indigo
        case .mail: .pink
        case .media: .mint
        case .vm: .brown
        case .downloads: .teal
        case .crash: .red
        }
    }
}

// MARK: - Artifact

struct Artifact: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let name: String
    let size: Int64
    let category: ArtifactCategory
    let description: String
    let needsSudo: Bool

    var sizeHuman: String { formatBytes(size) }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Artifact, rhs: Artifact) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - DiskInfo

struct DiskInfo {
    let total: UInt64
    let used: UInt64
    let free: UInt64
    let usedPercent: Double
    let hostname: String
    let osVersion: String
    let arch: String

    var totalStr: String { formatBytes(Int64(total)) }
    var usedStr: String { formatBytes(Int64(used)) }
    var freeStr: String { formatBytes(Int64(free)) }
}

// MARK: - Snapshot

struct Snapshot: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let date: String
    var size: String
}

// MARK: - Pattern & FixedPath

struct ArtifactPattern {
    let name: String
    let category: ArtifactCategory
    let description: String
}

struct FixedPath {
    let path: String
    let name: String
    let category: ArtifactCategory
    let description: String
    let needsSudo: Bool
}

// MARK: - CleanResult

struct DeleteResult: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let size: Int64
    let success: Bool
    let error: String?
}

struct CleanResult {
    let deleted: [DeleteResult]
    let totalFreed: Int64
    let failCount: Int
    let okCount: Int

    var freedStr: String { formatBytes(totalFreed) }
}

// MARK: - Helpers

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1024 && unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }
    if unitIndex == 0 {
        return "\(bytes) B"
    }
    return String(format: "%.1f %@", value, units[unitIndex])
}
