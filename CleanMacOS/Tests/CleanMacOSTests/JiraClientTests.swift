import Foundation
import Testing
@testable import CleanMacOS

final class FakeJiraTransport {
    var requests: [URLRequest] = []
    var responder: (URLRequest) throws -> (Int, Any?)

    init(responder: @escaping (URLRequest) throws -> (Int, Any?) = { _ in (200, nil) }) {
        self.responder = responder
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = try responder(request)
        let data: Data
        switch body {
        case nil: data = Data()
        case let raw as Data: data = raw
        case let text as String: data = Data(text.utf8)
        case let json?: data = try JSONSerialization.data(withJSONObject: json)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!)
    }

    func client(authKind: JiraSettings.AuthKind = .server, email: String = "") -> JiraClient {
        JiraClient(baseURL: "https://jira.example.com/", authKind: authKind, email: email, token: "secret",
                   transport: send)
    }
}

struct JiraClientTests {
    @Test func serverUsesBearerAndCurlUserAgent() async throws {
        let transport = FakeJiraTransport { _ in (200, ["ok": true]) }
        let json = try await transport.client().json(path: "/rest/api/2/myself") as? JiraJSON
        #expect(json?["ok"] as? Bool == true)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://jira.example.com/rest/api/2/myself")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "curl/8")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func cloudUsesBasicEmailToken() async throws {
        let transport = FakeJiraTransport()
        _ = try await transport.client(authKind: .cloud, email: "me@x.io").request(path: "/rest/api/2/myself")
        let expected = "Basic " + Data("me@x.io:secret".utf8).base64EncodedString()
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == expected)
    }

    @Test func encodesQueryAndBody() async throws {
        let transport = FakeJiraTransport()
        _ = try await transport.client().request(method: "PUT", path: "/rest/api/2/search",
                                                 query: ["jql": "a = \"b+c\" & d", "maxResults": "5"],
                                                 body: ["fields": ["summary": "x"]])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.query == "jql=a%20%3D%20%22b%2Bc%22%20%26%20d&maxResults=5")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? JiraJSON
        #expect((body?["fields"] as? JiraJSON)?["summary"] as? String == "x")
    }

    @Test func mergesErrorMessagesAndFieldErrors() async {
        let transport = FakeJiraTransport { _ in
            (400, ["errorMessages": ["Bad request"], "errors": ["summary": "required", "duedate": "invalid"]])
        }
        do {
            _ = try await transport.client().request(path: "/x")
            Issue.record("expected JiraError")
        } catch {
            #expect(error as? JiraError == JiraError(status: 400, message: "Bad request; duedate: invalid; summary: required"))
        }
    }

    @Test func nonJSONErrorKeepsText() {
        #expect(JiraClient.parseErrorMessage(Data("error code: 1010".utf8)) == "error code: 1010")
        #expect(JiraClient.parseErrorMessage(Data("{}".utf8)) == "Unknown Jira error")
    }

    @Test func networkFailureIs502() async {
        let transport = FakeJiraTransport { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await transport.client().request(path: "/x")
            Issue.record("expected JiraError")
        } catch {
            #expect((error as? JiraError)?.status == 502)
        }
    }

    @Test func emptyBodyIsNilJSON() async throws {
        let value = try await FakeJiraTransport().client().json(method: "PUT", path: "/x")
        #expect(value == nil)
    }
}

struct JiraFieldDiscoveryTests {
    private let fields: [JiraJSON] = [
        ["id": "assignee", "name": "Assignee"],
        ["id": "customfield_10101", "name": "Sprint"],
        ["id": "customfield_10700", "name": "Assignees"],
        ["id": "customfield_11203", "name": "Falcon App"],
        ["id": "customfield_11204", "name": "Dev Point"],
        ["id": "customfield_11202", "name": "Tester Point"],
        ["id": "customfield_10701", "name": "BA Point"],
        ["id": "customfield_10702", "name": "Designer Point"],
        ["id": "customfield_10800", "name": "Merge Request"],
        ["id": "customfield_10900", "name": "Reviewer"],
    ]

    @Test func mapsFieldsByName() {
        let map = JiraFieldDiscovery.discover(fields: fields, appFieldName: "Falcon App")
        #expect(map.ids == JiraFixtures.avadaFields.ids)
        #expect(map.names[.app] == "Falcon App")
    }

    @Test func noAppFieldWhenNameEmpty() {
        #expect(JiraFieldDiscovery.discover(fields: fields)[.app] == nil)
    }

    @Test func fallsBackToStandardAssignee() {
        let map = JiraFieldDiscovery.discover(fields: fields.filter { $0["name"] as? String != "Assignees" })
        #expect(map[.assignees] == "assignee")
        #expect(JiraFieldDiscovery.discover(fields: [])[.sprint] == nil)
    }

    @Test func overridesWin() {
        let map = JiraFieldDiscovery.discover(fields: fields, overrides: [.devPoint: "customfield_10702", .app: "customfield_99"])
        #expect(map[.devPoint] == "customfield_10702")
        #expect(map.names[.devPoint] == "Designer Point")
        #expect(map[.app] == "customfield_99")
    }
}

struct KeychainStoreTests {
    private let store = KeychainStore(service: "com.truong62.cleanmacos.tests.\(UUID().uuidString)")

    @Test func saveReadDeleteRoundTrip() throws {
        defer { store.delete() }
        #expect(store.read() == nil)
        try store.save("first")
        try store.save("second")
        #expect(store.read() == "second")
        store.delete()
        #expect(store.read() == nil)
    }
}
