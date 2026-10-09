import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var artifacts: [Artifact] = []
    @Published var selectedArtifacts: Set<Artifact.ID> = []
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var scanPath: String
    @Published var diskInfo: DiskInfo?
    @Published var snapshots: [Snapshot] = []
    @Published var selectedCategory: ArtifactCategory? = nil
    @Published var statusMessage = "Ready"
    @Published var searchText = ""
    @Published var sortBySize = true
    @Published var showCleanConfirmation = false
    @Published var lastCleanResult: CleanResult?
    @Published var showResults = false

    @AppStorage("minFileSize") var minFileSizeMB = 1
    @AppStorage("skipHidden") var skipHidden = true
    @AppStorage("confirmBeforeClean") var confirmBeforeClean = true
    @AppStorage("showMenuBar") var showMenuBar = true
    @AppStorage("menuBarShowCPU") var menuBarShowCPU = true
    @Published var hasFullDiskAccess = false
    @Published var skipPermissionCheck = false

    private let scanner = ScannerService()
    private let cleaner = CleanerService()

    var needsPermission: Bool {
        !hasFullDiskAccess && !skipPermissionCheck
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        scanPath = (home as NSString).deletingLastPathComponent
        refreshDiskInfo()
        checkPermission()
    }

    func checkPermission() {
        // Test Full Disk Access by trying to list a protected directory
        let fm = FileManager.default
        let testPaths = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari").path,
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Cookies").path,
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages").path,
        ]

        for path in testPaths {
            if fm.fileExists(atPath: path) {
                // Path exists, try to read contents — if we can, we have FDA
                if (try? fm.contentsOfDirectory(atPath: path)) != nil {
                    hasFullDiskAccess = true
                    return
                } else {
                    hasFullDiskAccess = false
                    return
                }
            }
        }

        // None of the test paths exist — can't determine, assume OK
        hasFullDiskAccess = true
    }

    // MARK: - Computed

    var filteredArtifacts: [Artifact] {
        var list = artifacts
        if let cat = selectedCategory {
            list = list.filter { $0.category == cat }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.path.lowercased().contains(q) ||
                $0.description.lowercased().contains(q)
            }
        }
        return list
    }

    var totalCleanableSize: Int64 {
        artifacts.reduce(0) { $0 + $1.size }
    }

    var selectedSize: Int64 {
        let selected = allArtifacts.filter { selectedArtifacts.contains($0.id) }
        return Self.removingDescendants(from: selected).reduce(0) { $0 + $1.size }
    }

    var categoryCounts: [(ArtifactCategory, Int, Int64)] {
        var counts: [ArtifactCategory: (Int, Int64)] = [:]
        for a in artifacts {
            let existing = counts[a.category] ?? (0, 0)
            counts[a.category] = (existing.0 + 1, existing.1 + a.size)
        }
        return ArtifactCategory.allCases.compactMap { cat in
            guard let (count, size) = counts[cat] else { return nil }
            return (cat, count, size)
        }.sorted { $0.2 > $1.2 }
    }

    var canClean: Bool {
        !selectedArtifacts.isEmpty && !isCleaning && !isScanning
    }

    /// Detailed confirmation text that calls out any commands to be run and destructive warnings.
    var cleanConfirmationMessage: String {
        let selected = Self.removingDescendants(from: allArtifacts.filter { selectedArtifacts.contains($0.id) })
        var lines = ["Reclaim \(selected.count) item(s) — about \(formatBytes(selectedSize))."]

        let commands = selected.compactMap { $0.reclaim.commandString }
        if !commands.isEmpty {
            lines.append("Will run: " + commands.joined(separator: ", "))
        }

        let personal = selected.filter(\.isPersonalData)
        if !personal.isEmpty {
            lines.append("⚠️ Includes PERSONAL DATA: \(personal.map(\.name).joined(separator: ", ")). This is your own data, not junk.")
        }

        if selected.contains(where: \.needsSudo) {
            lines.append("🔑 System items selected — macOS will ask for your administrator password.")
        }

        let warnings = selected.compactMap(\.warning)
        for warning in warnings {
            lines.append("⚠️ " + warning)
        }

        lines.append("This cannot be undone.")
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Actions

    func scan() async {
        isScanning = true
        statusMessage = "Scanning..."
        selectedArtifacts.removeAll()

        do {
            let (found, info, snaps) = try await scanner.scan(rootPath: scanPath, skipHidden: skipHidden)
            let minBytes = Int64(minFileSizeMB) * 1_048_576
            artifacts = found.filter { $0.size >= minBytes }
            diskInfo = info
            snapshots = snaps
            statusMessage = "Found \(artifacts.count) items (\(formatBytes(totalCleanableSize)) cleanable)"
        } catch {
            statusMessage = "Scan failed: \(error.localizedDescription)"
        }

        isScanning = false
    }

    func requestClean() {
        if confirmBeforeClean {
            showCleanConfirmation = true
        } else {
            Task { await clean() }
        }
    }

    func clean() async {
        let selected = Self.removingDescendants(
            from: allArtifacts.filter { selectedArtifacts.contains($0.id) }
        )
        let nonSudo = selected.filter { !$0.needsSudo }
        let sudo = selected.filter { $0.needsSudo }

        guard !nonSudo.isEmpty || !sudo.isEmpty else {
            statusMessage = "No items selected"
            return
        }

        isCleaning = true
        statusMessage = "Cleaning \(selected.count) items..."
        let freeBefore = scanner.getDiskInfo()?.free

        var allDeleted: [DeleteResult] = []
        var totalFreed: Int64 = 0
        var okCount = 0
        var failCount = 0
        var retryArtifacts: [Artifact] = []

        if !nonSudo.isEmpty {
            let r = await Task.detached { [cleaner] in cleaner.reclaim(nonSudo) }.value
            allDeleted += r.deleted; totalFreed += r.totalFreed; okCount += r.okCount; failCount += r.failCount
            retryArtifacts += r.retryArtifacts
        }
        if !sudo.isEmpty {
            statusMessage = "Authorizing system cleanup..."
            let r = await Task.detached { [cleaner] in cleaner.deletePrivileged(sudo) }.value
            allDeleted += r.deleted; totalFreed += r.totalFreed; okCount += r.okCount; failCount += r.failCount
        }

        let freeAfter = scanner.getDiskInfo()?.free
        artifacts = await refreshedArtifacts(after: allDeleted)
        selectedArtifacts.removeAll()

        refreshDiskInfo()
        let realFreed = Self.freeSpaceDelta(before: freeBefore, after: freeAfter)
        let result = CleanResult(
            deleted: allDeleted,
            totalFreed: totalFreed,
            failCount: failCount,
            okCount: okCount,
            realFreed: realFreed,
            retryArtifacts: retryArtifacts
        )
        lastCleanResult = result
        showResults = true

        let freedStr = formatBytes(totalFreed)
        if failCount > 0 {
            statusMessage = "Cleaned \(okCount) items (\(freedStr) freed), \(failCount) failed"
        } else {
            statusMessage = "Cleaned \(okCount) items — \(freedStr) freed!"
        }

        isCleaning = false
    }

    func retryFailedAsAdministrator() async {
        guard let retryArtifacts = lastCleanResult?.retryArtifacts, !retryArtifacts.isEmpty else { return }
        isCleaning = true
        statusMessage = "Authorizing failed items..."
        let freeBefore = scanner.getDiskInfo()?.free
        let result = await Task.detached { [cleaner] in
            cleaner.deletePrivileged(retryArtifacts)
        }.value
        let freeAfter = scanner.getDiskInfo()?.free
        artifacts = await refreshedArtifacts(after: result.deleted)
        refreshDiskInfo()
        let finalResult = CleanResult(
            deleted: result.deleted,
            totalFreed: result.totalFreed,
            failCount: result.failCount,
            okCount: result.okCount,
            realFreed: Self.freeSpaceDelta(before: freeBefore, after: freeAfter)
        )
        lastCleanResult = finalResult
        statusMessage = result.failCount == 0
            ? "Administrator retry cleaned \(result.okCount) items"
            : "Administrator retry: \(result.okCount) cleaned, \(result.failCount) failed"
        isCleaning = false
    }

    func deleteSnapshot(_ snapshot: Snapshot) async {
        statusMessage = "Deleting snapshot \(snapshot.date)..."
        do {
            try scanner.deleteSnapshot(date: snapshot.date)
            snapshots.removeAll { $0.date == snapshot.date }
            refreshDiskInfo()
            statusMessage = "Snapshot deleted"
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
        }
    }

    func selectAll() {
        // Skip sudo items (can't delete) and personal data (must be opted in deliberately).
        let ids = filteredArtifacts.filter { !$0.needsSudo && !$0.isPersonalData }.map(\.id)
        selectedArtifacts.formUnion(ids)
    }

    func deselectAll() {
        selectedArtifacts.removeAll()
    }

    func toggleSelection(_ artifact: Artifact) {
        if selectedArtifacts.contains(artifact.id) {
            selectedArtifacts.remove(artifact.id)
        } else {
            selectedArtifacts.insert(artifact.id)
        }
    }

    func refreshDiskInfo() {
        diskInfo = scanner.getDiskInfo()
    }

    nonisolated static func removingDescendants(from artifacts: [Artifact]) -> [Artifact] {
        let sorted = artifacts.sorted { $0.path.count < $1.path.count }
        var result: [Artifact] = []
        for artifact in sorted {
            let path = (artifact.path as NSString).standardizingPath
            let isDescendant = result.contains { parent in
                let parentPath = (parent.path as NSString).standardizingPath
                return path.hasPrefix(parentPath + "/")
            }
            if !isDescendant { result.append(artifact) }
        }
        return result
    }

    private var allArtifacts: [Artifact] {
        Self.flattened(artifacts)
    }

    nonisolated static func flattened(_ artifacts: [Artifact]) -> [Artifact] {
        artifacts.flatMap { [$0] + flattened($0.children ?? []) }
    }

    private func refreshedArtifacts(after results: [DeleteResult]) async -> [Artifact] {
        let current = artifacts
        return await Task.detached { [scanner] in
            current.compactMap { artifact in
                guard artifact.reclaim == .deletePath else {
                    if results.contains(where: { $0.path == artifact.path && $0.success }) { return nil }
                    return artifact
                }
                let affected = results.contains { result in
                    result.path == artifact.path || result.path.hasPrefix(artifact.path + "/")
                }
                guard affected else { return artifact }
                if results.contains(where: { $0.path == artifact.path && $0.success }) { return nil }
                return scanner.remeasure(artifact) ?? artifact
            }
        }.value
    }

    nonisolated private static func freeSpaceDelta(before: UInt64?, after: UInt64?) -> Int64 {
        guard let before, let after, after > before else { return 0 }
        return Int64(min(after - before, UInt64(Int64.max)))
    }
}
