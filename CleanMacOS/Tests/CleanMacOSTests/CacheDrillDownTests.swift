import Foundation
import Testing
@testable import CleanMacOS

struct CacheDrillDownTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("caches-\(UUID().uuidString)")

    private func write(_ relative: String, megabytes: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: megabytes * 1_048_576).write(to: url)
    }

    private func artifact(_ category: ArtifactCategory) -> Artifact {
        Artifact(path: root.path, name: "Caches", size: 0, category: category, description: "test", needsSudo: false)
    }

    @Test func cachesDrillDownSeveralLevelsBelowTheOldThreshold() throws {
        try write("com.google.Chrome/Default/Cache/data_1", megabytes: 60)
        try write("com.tiny.App/blob", megabytes: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        let measured = try #require(ScannerService().remeasure(artifact(.caches)))
        let chrome = try #require(measured.children?.first { $0.name == "com.google.Chrome" })
        let tiny = try #require(measured.children?.first { $0.name == "com.tiny.App" })
        let profile = try #require(chrome.children?.first)
        #expect(profile.name == "Default")
        #expect(profile.children?.first?.name == "Cache")
        #expect(tiny.children == nil)
    }

    @Test func nonCacheArtifactsKeepTheOneLevelHundredMegabyteRule() throws {
        try write("project/build/out.bin", megabytes: 60)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ScannerService().remeasure(artifact(.developer))?.children == nil)
    }
    @Test func retainedSizesPreserveTotalsAndLowerBounds() {
        let leaf = RustCore.SizedTree(name: "leaf", bytes: 60_000_000, timed_out: true, children: nil)
        let branch = RustCore.SizedTree(name: "branch", bytes: leaf.bytes, timed_out: true, children: [leaf])
        let tree = RustCore.SizedTree(name: "Caches", bytes: branch.bytes, timed_out: true, children: [branch])
        let measured = ScannerService.applyingSize(tree, to: artifact(.caches))
        #expect(measured.size == 60_000_000)
        #expect(measured.sizeIsLowerBound)
        #expect(measured.children?.reduce(0) { $0 + $1.size } == measured.size)
        #expect(measured.children?.first?.children?.first?.size == leaf.bytes)
        #expect(measured.children?.first?.children?.first?.sizeIsLowerBound == true)
    }

    @Test func measuredParentMatchesOriginalWalkerAndChildSum() throws {
        try write("large/data", megabytes: 12)
        try write("small/data", megabytes: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let measured = try #require(ScannerService().remeasure(artifact(.caches)))
        #expect(measured.size == ScannerService.calculateDirSize(path: root.path))
        #expect(measured.children?.reduce(0) { $0 + $1.size } == measured.size)
        for child in try #require(measured.children) {
            #expect(child.size == ScannerService.calculateDirSize(path: child.path))
        }
    }

}
