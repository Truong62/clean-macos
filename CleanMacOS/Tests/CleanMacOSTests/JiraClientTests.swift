import XCTest
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

final class JiraClientTests: XCTestCase {
    func testServerUsesBearerAndCurlUserAgent() async throws {
        let transport = FakeJiraTransport { _ in (200, ["ok": true]) }
        let json = try await transport.client().json(path: "/rest/api/2/myself") as? JiraJSON
        XCTAssertEqual(json?["ok"] as? Bool, true)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://jira.example.com/rest/api/2/myself")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "curl/8")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testCloudUsesBasicEmailToken() async throws {
        let transport = FakeJiraTransport()
        _ = try await transport.client(authKind: .cloud, email: "me@x.io").request(path: "/rest/api/2/myself")
        let expected = "Basic " + Data("me@x.io:secret".utf8).base64EncodedString()
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), expected)
    }

    func testEncodesQueryAndBody() async throws {
        let transport = FakeJiraTransport()
        _ = try await transport.client().request(method: "PUT", path: "/rest/api/2/search",
                                                 query: ["jql": "a = \"b+c\" & d", "maxResults": "5"],
                                                 body: ["fields": ["summary": "x"]])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.query, "jql=a%20%3D%20%22b%2Bc%22%20%26%20d&maxResults=5")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? JiraJSON
        XCTAssertEqual((body?["fields"] as? JiraJSON)?["summary"] as? String, "x")
    }

    func testMergesErrorMessagesAndFieldErrors() async {
        let transport = FakeJiraTransport { _ in
            (400, ["errorMessages": ["Bad request"], "errors": ["summary": "required", "duedate": "invalid"]])
        }
        do {
            _ = try await transport.client().request(path: "/x")
            XCTFail("expected JiraError")
        } catch {
            XCTAssertEqual(error as? JiraError,
                           JiraError(status: 400, message: "Bad request; duedate: invalid; summary: required"))
        }
    }

    func testNonJSONErrorKeepsText() {
        XCTAssertEqual(JiraClient.parseErrorMessage(Data("error code: 1010".utf8)), "error code: 1010")
        XCTAssertEqual(JiraClient.parseErrorMessage(Data("{}".utf8)), "Unknown Jira error")
    }

    func testNetworkFailureIs502() async {
        let transport = FakeJiraTransport { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await transport.client().request(path: "/x")
            XCTFail("expected JiraError")
        } catch {
            XCTAssertEqual((error as? JiraError)?.status, 502)
        }
    }

    func testEmptyBodyIsNilJSON() async throws {
        let value = try await FakeJiraTransport().client().json(method: "PUT", path: "/x")
        XCTAssertNil(value)
    }
}

final class JiraFieldDiscoveryTests: XCTestCase {
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

    func testMapsFieldsByName() {
        let map = JiraFieldDiscovery.discover(fields: fields, appFieldName: "Falcon App")
        XCTAssertEqual(map.ids, JiraFixtures.avadaFields.ids)
        XCTAssertEqual(map.names[.app], "Falcon App")
    }

    func testNoAppFieldWhenNameEmpty() {
        XCTAssertNil(JiraFieldDiscovery.discover(fields: fields)[.app])
    }

    func testFallsBackToStandardAssignee() {
        let map = JiraFieldDiscovery.discover(fields: fields.filter { $0["name"] as? String != "Assignees" })
        XCTAssertEqual(map[.assignees], "assignee")
        XCTAssertNil(JiraFieldDiscovery.discover(fields: [])[.sprint])
    }

    func testOverridesWin() {
        let map = JiraFieldDiscovery.discover(fields: fields, overrides: [.devPoint: "customfield_10702", .app: "customfield_99"])
        XCTAssertEqual(map[.devPoint], "customfield_10702")
        XCTAssertEqual(map.names[.devPoint], "Designer Point")
        XCTAssertEqual(map[.app], "customfield_99")
    }
}

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore(service: "com.truong62.cleanmacos.tests.\(UUID().uuidString)")

    override func tearDown() {
        store.delete()
        super.tearDown()
    }

    func testSaveReadDeleteRoundTrip() throws {
        XCTAssertNil(store.read())
        try store.save("first")
        try store.save("second")
        XCTAssertEqual(store.read(), "second")
        store.delete()
        XCTAssertNil(store.read())
    }
}
