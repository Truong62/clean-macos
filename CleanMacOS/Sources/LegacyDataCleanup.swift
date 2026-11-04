import Foundation

enum LegacyDataCleanup {
    static let jiraDefaultsPrefix = "jira."

    static func removeJiraData(library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0],
                               bundleID: String = Bundle.main.bundleIdentifier ?? "", defaults: UserDefaults = .standard) {
        var leftovers = ["Application Support/CleanMacOS/jira-token", "Application Support/CleanMacOS/jira-kpi.json"]
        if !bundleID.isEmpty { leftovers += ["WebKit/\(bundleID)", "Caches/\(bundleID)/WebKit"] }
        for path in leftovers {
            try? FileManager.default.removeItem(at: library.appendingPathComponent(path))
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(jiraDefaultsPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
