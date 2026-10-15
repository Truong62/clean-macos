import Foundation
import Testing
@testable import CleanMacOS

struct JiraSetupTests {
    @Test func authKindFollowsDomain() {
        #expect(JiraSettings.AuthKind(domain: "https://acme.atlassian.net") == .cloud)
        #expect(JiraSettings.AuthKind(domain: "https://space.avada.net") == .server)
        #expect(JiraSettings.AuthKind(domain: "") == .server)
    }

    @Test func normalizesPastedLinks() {
        #expect(JiraSettings.normalizedDomain(" acme.atlassian.net/jira/software/projects/ABC/boards/1 ") == "https://acme.atlassian.net")
        #expect(JiraSettings.normalizedDomain("https://space.avada.net/") == "https://space.avada.net")
        #expect(JiraSettings.normalizedDomain("https://host.example/jira") == "https://host.example/jira")
        #expect(JiraSettings.normalizedDomain("") == "")
    }

    @Test func picksCurrentThenScrumThenFirstBoard() {
        let kanban = JiraBoardOption(id: 1, name: "Kanban", isScrum: false)
        let scrum = JiraBoardOption(id: 2, name: "Scrum", isScrum: true)
        #expect(JiraBoardOption.preferred(in: [kanban, scrum], current: 1) == kanban)
        #expect(JiraBoardOption.preferred(in: [kanban, scrum], current: 99) == scrum)
        #expect(JiraBoardOption.preferred(in: [kanban], current: nil) == kanban)
        #expect(JiraBoardOption.preferred(in: [], current: 1) == nil)
    }

    @Test func listsProjectsSortedAndBoardsForProject() async throws {
        let transport = FakeJiraTransport { request in
            switch request.url!.path {
            case "/rest/api/2/project": return (200, [["key": "ZED", "name": "zed"], ["key": "FAL", "name": "Falcon"], ["name": "no key"]])
            case "/rest/agile/1.0/board": return (200, ["values": [["id": 10030, "name": "FAL board", "type": "scrum"]]])
            default: return (404, nil)
            }
        }
        let service = JiraService(client: transport.client(), projectKey: "", boardId: nil, role: .dev,
                                  appFieldName: "", fieldOverrides: [:])
        #expect(try await service.listProjects().map(\.key) == ["FAL", "ZED"])
        #expect(try await service.listBoards(projectKey: "FAL") == [JiraBoardOption(id: 10030, name: "FAL board", isScrum: true)])
        let boardRequest = transport.requests.last!
        #expect(URLComponents(url: boardRequest.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "projectKeyOrId", value: "FAL")])
    }
}
