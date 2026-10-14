import Foundation
import Testing
@testable import CleanMacOS

struct TokenFileStoreTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("token-\(UUID())", isDirectory: true)
    private var store: TokenFileStore { TokenFileStore(fileURL: dir.appendingPathComponent("jira-token")) }

    @Test func saveReadDeleteRoundTripWithOwnerOnlyPermissions() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.read() == nil)
        try store.save("first")
        try store.save("second")
        #expect(store.read() == "second")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        store.delete()
        #expect(store.read() == nil)
    }

    @Test func movesLegacyKeychainTokenOnceThenIgnoresKeychain() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = KeychainStore(service: "com.truong62.cleanmacos.tests.\(UUID().uuidString)")
        defer { legacy.delete() }
        let defaults = try #require(UserDefaults(suiteName: "token-tests-\(UUID())"))
        try legacy.save("from-keychain")

        #expect(JiraViewModel.loadToken(store: store, legacy: legacy, defaults: defaults) == "from-keychain")
        #expect(store.read() == "from-keychain")

        store.delete()
        #expect(JiraViewModel.loadToken(store: store, legacy: legacy, defaults: defaults) == nil)
    }
}
