import Foundation
import Testing
@testable import CleanMacOS

struct JiraAttachmentTests {
    private func router(_ transport: FakeJiraTransport) -> JiraRouter {
        let service = JiraService(client: transport.client(), projectKey: "FAL", boardId: nil, role: .dev, appFieldName: "", fieldOverrides: [:])
        return JiraRouter(service: { service }, kpiStore: JiraKpiStore(fileURL: URL(fileURLWithPath: "/nonexistent")), webRoot: nil)
    }

    @Test func multipartBodyWrapsFileWithFilenameAndType() {
        let body = JiraClient.multipartBody(filename: "shot \"1\".png", data: Data("PNG".utf8), mimeType: "image/png", boundary: "B")
        #expect(String(decoding: body, as: UTF8.self) ==
            "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"shot 1.png\"\r\nContent-Type: image/png\r\n\r\nPNG\r\n--B--\r\n")
    }

    @Test func uploadPostsMultipartWithAtlassianTokenHeader() async throws {
        let transport = FakeJiraTransport { _ in (200, [["filename": "shot.png", "id": "55"]]) }
        let response = await router(transport).handle(method: "POST", path: "/api/issues/FAL-1/attachments",
                                                      query: "name=shot.png", body: Data("PNG".utf8))
        #expect(response.status == 200)
        #expect((try JSONSerialization.jsonObject(with: response.data) as? JiraJSON)?["filename"] as? String == "shot.png")
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/rest/api/2/issue/FAL-1/attachments")
        #expect(request.value(forHTTPHeaderField: "X-Atlassian-Token") == "no-check")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("filename=\"shot.png\""))
    }

    @Test func uploadRequiresNameAndBody() async {
        let transport = FakeJiraTransport()
        #expect(await router(transport).handle(method: "POST", path: "/api/issues/FAL-1/attachments", query: nil, body: Data("x".utf8)).status == 400)
        #expect(await router(transport).handle(method: "POST", path: "/api/issues/FAL-1/attachments", query: "name=a.png", body: nil).status == 400)
    }

    @Test func fileProxyServesAttachmentsOnly() async throws {
        let transport = FakeJiraTransport { _ in (200, Data("IMG".utf8)) }
        let ok = await router(transport).handle(method: "GET", path: "/api/file", query: "path=%2Fsecure%2Fattachment%2F1%2Fa.png", body: nil)
        #expect(ok.status == 200)
        #expect(ok.data == Data("IMG".utf8))
        #expect(transport.requests.first?.url?.path == "/secure/attachment/1/a.png")
        let blocked = await router(transport).handle(method: "GET", path: "/api/file", query: "path=%2Frest%2Fapi%2F2%2Fmyself", body: nil)
        #expect(blocked.status == 400)
        let traversal = await router(transport).handle(method: "GET", path: "/api/file", query: "path=%2Fsecure%2Fattachment%2F..%2F..%2Frest", body: nil)
        #expect(traversal.status == 400)
    }
}
