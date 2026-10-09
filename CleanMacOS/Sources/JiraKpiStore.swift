import Foundation

/// Imported KPI data: issue key → KPI month/points, plus the import date.
struct JiraKpiData: Codable, Equatable {
    var syncedAt: String
    var issues: [String: JiraKpiEntry]
}

/// Loads and saves imported KPI data as JSON; file URL injectable, default in Application Support.
struct JiraKpiStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CleanMacOS", isDirectory: true)
            self.fileURL = base.appendingPathComponent("jira-kpi.json")
        }
    }

    func read() -> JiraKpiData? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(JiraKpiData.self, from: data)
    }

    func write(_ kpi: JiraKpiData) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(kpi).write(to: fileURL, options: .atomic)
    }
}
