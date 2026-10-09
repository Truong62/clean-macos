import Foundation
import Testing
@testable import CleanMacOS

struct JiraServiceTests {
    private let fieldList: [JiraJSON] = [
        ["id": "customfield_10700", "name": "Assignees"],
        ["id": "customfield_11203", "name": "Falcon App"],
        ["id": "customfield_11204", "name": "Dev Point"],
        ["id": "customfield_11202", "name": "Tester Point"],
    ]
    private let board: JiraJSON = ["columnConfig": ["columns": [
        ["name": "To Do", "statuses": [["id": "1"]]],
        ["name": "Done", "statuses": [["id": "10001"], ["id": "10407"]]],
    ]]]
    private let me: JiraJSON = ["name": "truongnn", "displayName": "Trường",
                                "avatarUrls": ["48x48": "https://x/secure/useravatar?avatarId=5"]]

    private func service(_ transport: FakeJiraTransport, role: JiraSettings.Role = .dev, boardId: Int? = 7) -> JiraService {
        JiraService(client: transport.client(), projectKey: "FAL", boardId: boardId, role: role,
                    appFieldName: "Falcon App", fieldOverrides: [:])
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    @Test func listIssuesPagesServerSearch() async throws {
        let transport = FakeJiraTransport()
        transport.responder = { [fieldList] request in
            if request.url!.path == "/rest/api/2/field" { return (200, fieldList) }
            let startAt = Int(self.query(request, "startAt") ?? "0")!
            let issue = JiraFixtures.makeIssue()
            return (200, ["total": 3, "issues": startAt < 2 ? [issue, issue] : [issue]])
        }
        let issues = try await service(transport).listIssues()
        #expect(issues.count == 3)
        let searches = transport.requests.filter { $0.url!.path == "/rest/api/2/search" }
        #expect(searches.compactMap { query($0, "startAt") } == ["0", "2"])
        #expect(query(searches[0], "jql") == "project = FAL ORDER BY updated DESC")
        #expect(query(searches[0], "maxResults") == "1000")
        #expect(query(searches[0], "fields")!.hasSuffix("customfield_11203,customfield_10700,customfield_11204,customfield_11202"))
        #expect(transport.requests.filter { $0.url!.path == "/rest/api/2/field" }.count == 1)
    }

    @Test func metaIncludesLabelsForRole() async throws {
        let transport = FakeJiraTransport()
        transport.responder = { [fieldList, board, me] request in
            switch request.url!.path {
            case "/rest/api/2/field": return (200, fieldList)
            case "/rest/api/2/myself": return (200, me)
            case "/rest/agile/1.0/board/7/configuration": return (200, board)
            case "/rest/agile/1.0/board/7/sprint":
                return (200, ["values": [["id": 71, "name": "S7", "state": "active", "startDate": "2026-10-05"]]])
            default: return (404, ["errorMessages": ["nope"]])
            }
        }
        let meta = try await service(transport, role: .tester).getMeta()
        #expect(meta["role"] as? String == "tester")
        #expect((meta["me"] as? JiraJSON)?["avatar"] as? String == "/api/avatar?avatarId=5")
        #expect((meta["columns"] as? [JiraJSON])?.last?["statusIds"] as? [String] == ["10001", "10407"])
        let sprint = (meta["sprints"] as? [JiraJSON])?.first ?? [:]
        #expect(sprint["id"] as? Int == 71)
        #expect(sprint["endDate"] is NSNull)
        let labels = meta["labels"] as? JiraJSON ?? [:]
        #expect(labels["app"] as? String == "Falcon App")
        #expect(labels["points"] as? String == "Tester Point")

        let designer = try await service(transport, role: .designer).getMeta()
        #expect((designer["labels"] as? JiraJSON)?["points"] is NSNull)
        #expect(throws: Never.self) { try JSONSerialization.data(withJSONObject: designer) }
    }

    @Test func moveIssuePicksTransitionThenRefetches() async throws {
        let transport = FakeJiraTransport()
        transport.responder = { [fieldList, board] request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/rest/api/2/field"): return (200, fieldList)
            case ("GET", "/rest/agile/1.0/board/7/configuration"): return (200, board)
            case ("GET", "/rest/api/2/issue/FAL-1/transitions"):
                return (200, ["transitions": [["id": "251", "name": "done", "to": ["id": "10001"]]]])
            case ("POST", "/rest/api/2/issue/FAL-1/transitions"): return (204, nil)
            case ("GET", "/rest/api/2/issue/FAL-1"): return (200, JiraFixtures.makeIssue())
            default: return (404, nil)
            }
        }
        let detail = try await service(transport).moveIssue("FAL-1", column: "Done")
        #expect(detail["key"] as? String == "FAL-1120")
        let post = try #require(transport.requests.first { $0.httpMethod == "POST" })
        let body = try JSONSerialization.jsonObject(with: post.httpBody!) as? JiraJSON
        #expect((body?["transition"] as? JiraJSON)?["id"] as? String == "251")
        let refetch = try #require(transport.requests.last { $0.url!.path == "/rest/api/2/issue/FAL-1" })
        #expect(query(refetch, "expand") == "renderedFields,transitions,editmeta")
    }

    @Test func rejectsInvalidKeyAndUnknownColumn() async {
        let transport = FakeJiraTransport { [board] request -> (Int, Any?) in
            (200, request.url!.path.hasSuffix("/configuration") ? board : [JiraJSON]())
        }
        let service = service(transport)
        await expectJiraError(400) { _ = try await service.getIssue("../etc") }
        await expectJiraError(400) { _ = try await service.moveIssue("FAL-1", column: "Nope") }
        await expectJiraError(400) { _ = try await service.addComment("FAL-1", body: "  ") }
    }
}

func expectJiraError(_ status: Int, _ body: () async throws -> Void,
                     sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        try await body()
        Issue.record("expected JiraError \(status)", sourceLocation: sourceLocation)
    } catch {
        #expect((error as? JiraError)?.status == status, sourceLocation: sourceLocation)
    }
}
