import Foundation
import Testing
@testable import CleanMacOS

struct JiraRouterTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jira-router-\(UUID().uuidString)")

    private func router(_ transport: FakeJiraTransport? = FakeJiraTransport()) throws -> JiraRouter {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("<h1>hi</h1>".utf8).write(to: folder.appendingPathComponent("index.html"))
        let service = transport.map { JiraService(client: $0.client(), projectKey: "FAL", boardId: 7, role: .dev,
                                                  appFieldName: "", fieldOverrides: [:]) }
        return JiraRouter(service: { service }, kpiStore: JiraKpiStore(fileURL: folder.appendingPathComponent("kpi.json")),
                          webRoot: folder)
    }

    private func json(_ response: JiraHTTPResponse) throws -> JiraJSON {
        try #require(try JSONSerialization.jsonObject(with: response.data) as? JiraJSON)
    }

    @Test func servesStaticFilesWithMimeType() async throws {
        let response = try await router().handle(method: "GET", path: "/index.html", query: nil, body: nil)
        #expect(response.status == 200)
        #expect(response.contentType == "text/html")
        #expect(String(decoding: response.data, as: UTF8.self) == "<h1>hi</h1>")
    }

    @Test func rejectsPathTraversal() async throws {
        let response = try await router().handle(method: "GET", path: "/../secret", query: nil, body: nil)
        #expect(response.status == 404)
    }

    @Test func unconfiguredApiReturns401() async throws {
        let response = try await router(nil).handle(method: "GET", path: "/api/issues", query: nil, body: nil)
        #expect(response.status == 401)
        #expect(try json(response)["error"] as? String == "Jira is not configured — open Settings")
    }

    @Test func kpiWorksWithoutJiraAndReports404WhenMissing() async throws {
        let router = try router(nil)
        #expect(await router.handle(method: "GET", path: "/api/kpi", query: nil, body: nil).status == 404)
        try Data(#"{"syncedAt":"2026-10-08","issues":{}}"#.utf8).write(to: folder.appendingPathComponent("kpi.json"))
        let response = await router.handle(method: "GET", path: "/api/kpi", query: nil, body: nil)
        #expect(try json(response)["syncedAt"] as? String == "2026-10-08")
    }

    @Test func unknownRouteIs404() async throws {
        let response = try await router().handle(method: "DELETE", path: "/api/issues/FAL-1", query: nil, body: nil)
        #expect(response.status == 404)
    }

    @Test func commentPostsBodyToJira() async throws {
        let transport = FakeJiraTransport { request -> (Int, Any?) in
            if request.url!.path == "/rest/api/2/field" { return (200, [JiraJSON]()) }
            return (200, JiraFixtures.makeIssue())
        }
        let body = Data(#"{"body":"hello"}"#.utf8)
        let response = try await router(transport).handle(method: "POST", path: "/api/issues/FAL-1/comment", query: nil, body: body)
        #expect(response.status == 200)
        let post = try #require(transport.requests.first { $0.httpMethod == "POST" })
        #expect(post.url!.path == "/rest/api/2/issue/FAL-1/comment")
        #expect(try JSONSerialization.jsonObject(with: post.httpBody!) as? [String: String] == ["body": "hello"])
    }

    @Test func missingBodyFieldIs400() async throws {
        let response = try await router().handle(method: "POST", path: "/api/issues/FAL-1/move", query: nil, body: Data("{}".utf8))
        #expect(response.status == 400)
        #expect(try json(response)["error"] as? String == "'column' is required")
    }

    @Test func userSearchQueriesJiraAndMapsUsers() async throws {
        let transport = FakeJiraTransport { request -> (Int, Any?) in
            if request.url!.path == "/rest/api/2/field" { return (200, [JiraJSON]()) }
            return (200, [["name": "tony", "displayName": "Tony Nguyen", "avatarUrls": ["48x48": "https://x/secure/useravatar?avatarId=7"]]])
        }
        let response = try await router(transport).handle(method: "GET", path: "/api/users", query: "q=to%20ny", body: nil)
        #expect(response.status == 200)
        let users = try #require(try JSONSerialization.jsonObject(with: response.data) as? [JiraJSON])
        #expect(users.first?["name"] as? String == "tony")
        #expect(users.first?["displayName"] as? String == "Tony Nguyen")
        let search = try #require(transport.requests.first { $0.url!.path == "/rest/api/2/user/search" })
        #expect(URLComponents(url: search.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "username" }?.value == "to ny")
    }

    @Test func jiraErrorStatusIsForwarded() async throws {
        let transport = FakeJiraTransport { _ in (401, ["errorMessages": ["Bad token"]]) }
        let response = try await router(transport).handle(method: "GET", path: "/api/issues/FAL-1", query: nil, body: nil)
        #expect(response.status == 401)
        #expect(try json(response)["error"] as? String == "Bad token")
    }
}
