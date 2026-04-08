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

    private let scanner = ScannerService()
    private let cleaner = CleanerService()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        scanPath = (home as NSString).deletingLastPathComponent
        refreshDiskInfo()
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
        artifacts.filter { selectedArtifacts.contains($0.id) }.reduce(0) { $0 + $1.size }
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

    // MARK: - Actions

    func scan() async {
        isScanning = true
        statusMessage = "Scanning..."
        selectedArtifacts.removeAll()

        do {
            let (found, info, snaps) = try await scanner.scan(rootPath: scanPath)
            artifacts = found
            diskInfo = info
            snapshots = snaps
            statusMessage = "Found \(artifacts.count) items (\(formatBytes(totalCleanableSize)) cleanable)"
        } catch {
            statusMessage = "Scan failed: \(error.localizedDescription)"
        }

        isScanning = false
    }

    func clean() async {
        let pathsToClean = artifacts
            .filter { selectedArtifacts.contains($0.id) && !$0.needsSudo }
            .map(\.path)

        guard !pathsToClean.isEmpty else {
            statusMessage = "No items selected (sudo items excluded)"
            return
        }

        isCleaning = true
        statusMessage = "Cleaning \(pathsToClean.count) items..."

        let result = await Task.detached { [cleaner] in
            cleaner.deletePaths(pathsToClean)
        }.value

        // Remove cleaned artifacts
        let cleanedPaths = Set(result.deleted.filter(\.success).map(\.path))
        artifacts.removeAll { cleanedPaths.contains($0.path) }
        selectedArtifacts.removeAll()

        refreshDiskInfo()

        if result.failCount > 0 {
            statusMessage = "Cleaned \(result.okCount) items (\(result.freedStr) freed), \(result.failCount) failed"
        } else {
            statusMessage = "Cleaned \(result.okCount) items — \(result.freedStr) freed!"
        }

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
        let ids = filteredArtifacts.filter { !$0.needsSudo }.map(\.id)
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
}
