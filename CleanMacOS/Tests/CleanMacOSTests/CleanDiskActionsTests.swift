import Foundation
import Testing
@testable import CleanMacOS

@MainActor
struct CleanDiskActionsTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("clean-disk-\(UUID())", isDirectory: true)

    private func folder(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: url.appendingPathComponent("blob.bin"))
        return url.path
    }

    @Test func selectAllSkipsPersonalAndSystemItemsAndCleanRemovesOnlyTheSelection() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let build = Artifact(path: try folder("dist"), name: "dist", size: 50_000, category: .developer, description: "", needsSudo: false)
        let photos = Artifact(path: try folder("Photos"), name: "Photos", size: 50_000, category: .personal, description: "",
                              needsSudo: false, isPersonalData: true)
        let logs = Artifact(path: try folder("logs"), name: "logs", size: 50_000, category: .system, description: "", needsSudo: true)
        let vm = AppViewModel()
        vm.artifacts = [build, photos, logs]

        vm.selectAll()
        #expect(vm.selectedArtifacts == [build.id])
        #expect(vm.canClean)
        vm.toggleSelection(photos)
        #expect(vm.selectedArtifacts == [build.id, photos.id])
        vm.deselectAll()
        #expect(vm.selectedArtifacts.isEmpty && !vm.canClean)

        vm.toggleSelection(build)
        await vm.clean()
        #expect(!FileManager.default.fileExists(atPath: build.path))
        #expect(FileManager.default.fileExists(atPath: photos.path))
        #expect(vm.showResults)
        #expect(vm.lastCleanResult?.okCount == 1)
        #expect(vm.artifacts.map(\.name) == ["Photos", "logs"])
        #expect(vm.selectedArtifacts.isEmpty)
    }

    @Test func scanningAMissingFolderReportsTheError() async {
        let vm = AppViewModel(probeAccess: { true })
        vm.scanPath = missingFolder
        await vm.scan()
        #expect(vm.statusMessage == missingFolderError)
        #expect(!vm.isScanning)
    }

    @Test func asksForFullDiskAccessOnlyWhenAScanStarts() async {
        var isGranted = false
        let vm = AppViewModel(probeAccess: { isGranted })
        vm.scanPath = missingFolder
        #expect(!vm.isAskingPermission)
        await vm.scan()
        #expect(vm.isAskingPermission && !vm.isScanning && vm.statusMessage == "Ready")
        isGranted = true
        vm.checkPermission()
        #expect(!vm.isAskingPermission)
        await waitForScan(vm)
        #expect(vm.statusMessage == missingFolderError)
    }

    @Test func skippingTheRequestRunsALimitedScan() async {
        let vm = AppViewModel(probeAccess: { false })
        vm.scanPath = missingFolder
        await vm.scan()
        vm.skipPermissionCheck = true
        #expect(!vm.isAskingPermission)
        await waitForScan(vm)
        #expect(vm.statusMessage == missingFolderError)
    }

    @Test func cancellingDropsThePendingScan() async {
        var isGranted = false
        var runs = 0
        let vm = AppViewModel(probeAccess: { isGranted })
        await vm.withFullDiskAccess { runs += 1 }
        #expect(vm.isAskingPermission && runs == 0)
        vm.isAskingPermission = false
        isGranted = true
        vm.checkPermission()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runs == 0)
        await vm.withFullDiskAccess { runs += 1 }
        #expect(runs == 1 && !vm.isAskingPermission)
    }

    private let missingFolder = "/definitely/not/here"
    private var missingFolderError: String { "Scan failed: Path is not a directory: \(missingFolder)" }

    private func waitForScan(_ vm: AppViewModel) async {
        for _ in 0..<200 where vm.statusMessage != missingFolderError {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
