import Foundation
import Testing
@testable import CleanMacOS

struct JiraKpiImportTests {
    @Test func parsesQuotedCommasNewlinesAndCRLF() {
        let csv = "Month,,,Task,Dev,Tester\r\nT9 26,,,\"https://x/browse/FAL-1044, \"\"bulk\"\"\",5,2\r\n\"T10\n26\",a,b,FAL-7,3,\r\n"
        #expect(JiraCSV.parse(csv) == [
            ["Month", "", "", "Task", "Dev", "Tester"],
            ["T9 26", "", "", "https://x/browse/FAL-1044, \"bulk\"", "5", "2"],
            ["T10\n26", "a", "b", "FAL-7", "3", ""],
        ])
    }

    @Test func parsesLastRowWithoutTrailingNewline() {
        #expect(JiraCSV.parse("a,b\nc,d") == [["a", "b"], ["c", "d"]])
    }

    private func service(_ transport: FakeJiraTransport) -> JiraService {
        JiraService(client: transport.client(), projectKey: "FAL", boardId: nil, role: .dev, appFieldName: "", fieldOverrides: [:])
    }

    @Test func importMergesSheetRowsWithCountedElsewhereKeys() async throws {
        let transport = FakeJiraTransport { _ in (200, ["total": 2, "issues": [["key": "FAL-7"], ["key": "FAL-114"]]]) }
        let csv = "Month,,,Task,Dev,Tester\nT9 26,,,FAL-1044,5,2\nT10 26,,,FAL-7,3,\n"
        let now = ISO8601DateFormatter().date(from: "2026-10-09T03:00:00Z")!
        let data = try await service(transport).importKpi(csv: csv, countedElsewhereJQL: "description ~ \"Notion\"",
                                                          countedElsewhereMonth: "2026-06", now: now)
        #expect(data.syncedAt == "2026-10-09")
        #expect(data.issues["FAL-1044"] == JiraKpiEntry(month: "2026-09", devPoint: "5", testerPoint: "2"))
        #expect(data.issues["FAL-7"]?.month == "2026-10")
        #expect(data.issues["FAL-114"]?.source == JiraKpi.countedElsewhereSource)
    }

    @Test func importWithoutJQLDoesNotCallJira() async throws {
        let transport = FakeJiraTransport()
        let data = try await service(transport).importKpi(csv: "h\nT9 26,,,FAL-1,1,\n", countedElsewhereJQL: " ",
                                                          countedElsewhereMonth: "")
        #expect(data.issues.count == 1)
        #expect(transport.requests.isEmpty)
    }

    @Test func importRejectsSheetWithoutKpiRows() async {
        await #expect(throws: JiraError.self) {
            try await service(FakeJiraTransport()).importKpi(csv: "a,b\n1,2\n", countedElsewhereJQL: "", countedElsewhereMonth: "")
        }
    }

    @Test func importRejectsBadCountedElsewhereMonth() async {
        await #expect(throws: JiraError.self) {
            try await service(FakeJiraTransport()).importKpi(csv: "h\nT9 26,,,FAL-1,1,\n", countedElsewhereJQL: "x = 1",
                                                             countedElsewhereMonth: "June")
        }
    }
}
