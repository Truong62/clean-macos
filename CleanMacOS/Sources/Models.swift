import SwiftUI

// MARK: - Category

/// Consolidated, intentionally small taxonomy. Safety (whether an item is risky to delete) is
/// tracked separately via `Artifact.isPersonalData`, not by category.
enum ArtifactCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case developer   // deps, build, coverage, infra, Xcode, Docker, VMs
    case caches      // app + package-manager caches
    case system      // system caches, logs, crashes, temp, misc
    case media       // re-downloadable media caches (Podcasts, Spotify, Apple Music)
    case personal    // user data — backups, mail, photos, browser profiles (flagged risky)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .developer: "Developer"
        case .caches: "Caches"
        case .system: "System"
        case .media: "Media"
        case .personal: "Personal"
        }
    }

    var icon: String {
        switch self {
        case .developer: "hammer"
        case .caches: "internaldrive"
        case .system: "gearshape"
        case .media: "play.circle"
        case .personal: "person.crop.circle"
        }
    }

    var color: Color {
        switch self {
        case .developer: .blue
        case .caches: .purple
        case .system: .gray
        case .media: .mint
        case .personal: .pink
        }
    }
}

// MARK: - ReclaimStrategy

/// How an artifact's space is actually reclaimed.
enum ReclaimStrategy: Hashable, Sendable {
    /// Delete the item at `Artifact.path` via FileManager (default, original behavior).
    case deletePath
    /// Run a command instead of deleting a path, e.g. `docker system prune -af`.
    case command(tool: String, args: [String])

    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }

    /// Human-readable command line for display, e.g. "docker system prune -af".
    var commandString: String? {
        guard case let .command(tool, args) = self else { return nil }
        let name = (tool as NSString).lastPathComponent
        return ([name] + args).joined(separator: " ")
    }
}

// MARK: - Artifact

struct Artifact: Identifiable, Hashable, Sendable {
    let id = UUID()
    let path: String
    let name: String
    let size: Int64
    let category: ArtifactCategory
    let description: String
    let needsSudo: Bool
    /// How this item is reclaimed. Defaults to deleting `path`.
    var reclaim: ReclaimStrategy = .deletePath
    /// Optional destructive-action warning shown before cleaning (e.g. "deletes ALL Docker data").
    var warning: String? = nil
    /// User data (photos, mail, browser profiles…). Excluded from "Select All" and warned before delete.
    var isPersonalData: Bool = false
    var children: [Artifact]? = nil
    var sizeIsLowerBound: Bool = false

    var sizeHuman: String { (sizeIsLowerBound ? "≥ " : "") + formatBytes(size) }

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
    var isPersonalData: Bool = false
}

// MARK: - CleanResult

struct DeleteResult: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let size: Int64
    let freedBytes: Int64
    let success: Bool
    let error: String?
    let retryableAsAdmin: Bool
    let failures: [DeleteResult]

    init(
        path: String,
        name: String,
        size: Int64,
        freedBytes: Int64? = nil,
        success: Bool,
        error: String?,
        retryableAsAdmin: Bool = false,
        failures: [DeleteResult] = []
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.freedBytes = freedBytes ?? (success ? size : 0)
        self.success = success
        self.error = error
        self.retryableAsAdmin = retryableAsAdmin
        self.failures = failures
    }
}

struct CleanResult {
    let deleted: [DeleteResult]
    let totalFreed: Int64
    let failCount: Int
    let okCount: Int
    var realFreed: Int64 = 0
    var retryArtifacts: [Artifact] = []

    var freedStr: String { formatBytes(totalFreed) }
    var realFreedStr: String { formatBytes(realFreed) }
    var detailedFailureCount: Int {
        deleted.reduce(0) { $0 + ($1.success ? 0 : max(1, $1.failures.count)) }
    }

    var plainTextReport: String {
        var lines = [
            "CleanMacOS clean report",
            "Items cleaned: \(okCount)",
            "Real space freed: \(realFreedStr)",
            "Estimated freed: \(freedStr)",
            "Failures: \(detailedFailureCount)",
            "",
        ]
        for result in deleted.sorted(by: { lhs, rhs in
            if lhs.success != rhs.success { return !lhs.success }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }) {
            lines.append("\(result.success ? "✅" : "❌") \(result.name) — \(formatBytes(result.size))")
            lines.append(result.path)
            if let error = result.error, !error.isEmpty { lines.append(error) }
            for failure in result.failures {
                lines.append("  ❌ \(failure.name) — \(formatBytes(failure.size))")
                lines.append("  \(failure.path)")
                if let error = failure.error, !error.isEmpty { lines.append("  \(error)") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
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
