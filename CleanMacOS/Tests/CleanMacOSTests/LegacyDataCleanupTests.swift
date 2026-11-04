import Foundation
import Testing
@testable import CleanMacOS

struct LegacyDataCleanupTests {
    private let library = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID())", isDirectory: true)

    private func make(_ path: String) throws {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: library.appendingPathComponent(path).path)
    }

    @Test func removesJiraLeftoversAndNothingElse() throws {
        defer { try? FileManager.default.removeItem(at: library) }
        let suite = "cleanup-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for path in ["Application Support/CleanMacOS/jira-token", "Application Support/CleanMacOS/jira-kpi.json",
                     "Application Support/CleanMacOS/google-account", "Application Support/CleanMacOS/clipboard-history.json",
                     "WebKit/click.test/data", "WebKit/other.app/data", "Caches/click.test/WebKit/data", "Caches/click.test/keep"] {
            try make(path)
        }
        defaults.set("https://example.com", forKey: "jira.domain")
        defaults.set(Data([1]), forKey: "jira.watchState.https://example.com|me")
        defaults.set(true, forKey: "showMenuBar")
        defaults.set("kept", forKey: "notjira.value")

        LegacyDataCleanup.removeJiraData(library: library, bundleID: "click.test", defaults: defaults)

        #expect(!exists("Application Support/CleanMacOS/jira-token"))
        #expect(!exists("Application Support/CleanMacOS/jira-kpi.json"))
        #expect(!exists("WebKit/click.test"))
        #expect(!exists("Caches/click.test/WebKit"))
        #expect(exists("Application Support/CleanMacOS/google-account"))
        #expect(exists("Application Support/CleanMacOS/clipboard-history.json"))
        #expect(exists("WebKit/other.app/data"))
        #expect(exists("Caches/click.test/keep"))
        #expect(defaults.object(forKey: "jira.domain") == nil)
        #expect(defaults.object(forKey: "jira.watchState.https://example.com|me") == nil)
        #expect(defaults.bool(forKey: "showMenuBar"))
        #expect(defaults.string(forKey: "notjira.value") == "kept")
    }

    @Test func neverTouchesSharedFoldersWithoutABundleID() throws {
        defer { try? FileManager.default.removeItem(at: library) }
        let suite = "cleanup-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try make("WebKit/other.app/data")
        try make("Caches/other.app/WebKit/data")

        LegacyDataCleanup.removeJiraData(library: library, bundleID: "", defaults: defaults)

        #expect(exists("WebKit/other.app/data"))
        #expect(exists("Caches/other.app/WebKit/data"))
    }
}
