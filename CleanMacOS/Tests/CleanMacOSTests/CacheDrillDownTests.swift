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
}
