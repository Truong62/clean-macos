import Foundation
import UniformTypeIdentifiers
import WebKit

struct JiraHTTPResponse {
    let status: Int
    let contentType: String
    let data: Data

    static func json(_ object: Any, status: Int = 200) -> JiraHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return JiraHTTPResponse(status: status, contentType: "application/json", data: data)
    }

    static func error(_ message: String, status: Int) -> JiraHTTPResponse {
        json(["error": message], status: status)
    }
}

struct JiraRouter {
    static let scheme = "jiradesk"
    static let startURL = URL(string: "jiradesk://app/index.html")!

    let service: () -> JiraService?
    let kpiStore: JiraKpiStore
    let webRoot: URL?

    init(service: @escaping () -> JiraService?, kpiStore: JiraKpiStore = JiraKpiStore(),
         webRoot: URL? = JiraWebBundle.root) {
        self.service = service
        self.kpiStore = kpiStore
        self.webRoot = webRoot
    }

    func handle(method: String, path: String, query: String?, body: Data?) async -> JiraHTTPResponse {
        guard path.hasPrefix("/api/") else { return staticFile(path) }
        do {
            if method == "GET", path == "/api/avatar" { return try await avatar(query: query ?? "") }
            if method == "GET", path == "/api/file" {
                let file = try await configuredService().file(path: Self.queryValue(query, "path"))
                return JiraHTTPResponse(status: 200, contentType: file.contentType, data: file.data)
            }
            if method == "GET", path == "/api/users" { return .json(try await configuredService().searchUsers(Self.queryValue(query, "q"))) }
            return .json(try await api(method: method, parts: path.split(separator: "/").dropFirst().map(String.init),
                                       query: query, body: body))
        } catch let error as JiraError {
            return .error(error.message, status: error.status)
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    private func avatar(query: String) async throws -> JiraHTTPResponse {
        let avatar = try await configuredService().avatar(query: query)
        return JiraHTTPResponse(status: 200, contentType: avatar.contentType, data: avatar.data)
    }

    private func configuredService() throws -> JiraService {
        guard let service = service() else { throw JiraError(status: 401, message: "Jira is not configured — open Settings") }
        return service
    }

    private func api(method: String, parts: [String], query: String?, body: Data?) async throws -> Any {
        if method == "GET", parts == ["kpi"] { return try kpi() }
        let service = try configuredService()
        let input = { (key: String) in try Self.bodyField(body, key) }
        switch (method, parts.count, parts.first, parts.last) {
        case ("GET", 1, "issues", _): return try await service.listIssues()
        case ("GET", 1, "meta", _): return try await service.getMeta()
        case ("GET", 2, "issues", let key?): return try await service.getIssue(key)
        case ("PATCH", 2, "issues", let key?): return try await service.updateIssue(key, changes: try Self.bodyObject(body))
        case ("POST", 3, "issues", "transition"): return try await service.transitionIssue(parts[1], transitionId: try input("id"))
        case ("POST", 3, "issues", "move"): return try await service.moveIssue(parts[1], column: try input("column"))
        case ("POST", 3, "issues", "attachments"):
            return try await service.addAttachment(parts[1], filename: Self.queryValue(query, "name"), data: body ?? Data())
        case ("POST", 3, "issues", "comment"): return try await service.addComment(parts[1], body: try input("body"))
        default: throw JiraError(status: 404, message: "No route for \(method) /api/\(parts.joined(separator: "/"))")
        }
    }

    private func kpi() throws -> Any {
        guard let data = try? Data(contentsOf: kpiStore.fileURL) else {
            throw JiraError(status: 404, message: "KPI data not imported")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func staticFile(_ path: String) -> JiraHTTPResponse {
        let relative = path == "/" ? "index.html" : String(path.dropFirst())
        guard let webRoot, !relative.contains(".."),
              let data = try? Data(contentsOf: webRoot.appendingPathComponent(relative)) else {
            return .error("Not found: \(path)", status: 404)
        }
        let type = UTType(filenameExtension: (relative as NSString).pathExtension)?.preferredMIMEType
        return JiraHTTPResponse(status: 200, contentType: type ?? "application/octet-stream", data: data)
    }

    static func queryValue(_ query: String?, _ name: String) -> String {
        URLComponents(string: "?\(query ?? "")")?.queryItems?.first { $0.name == name }?.value ?? ""
    }

    static func bodyObject(_ body: Data?) throws -> JiraJSON {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? JiraJSON else {
            throw JiraError(status: 400, message: "Request body must be a JSON object")
        }
        return object
    }

    static func bodyField(_ body: Data?, _ key: String) throws -> String {
        guard let value = try bodyObject(body)[key] else { throw JiraError(status: 400, message: "'\(key)' is required") }
        return "\(value)"
    }
}

enum JiraWebBundle {
    static let folder = "JiraWeb"

    static var root: URL? {
        Bundle.main.url(forResource: folder, withExtension: nil)
            ?? Bundle.main.url(forResource: "CleanMacOS_CleanMacOS", withExtension: "bundle")
                .flatMap(Bundle.init(url:))?.url(forResource: folder, withExtension: nil)
    }
}

@MainActor
final class JiraSchemeHandler: NSObject, WKURLSchemeHandler {
    private let router: JiraRouter
    private var stopped: Set<ObjectIdentifier> = []

    init(router: JiraRouter) {
        self.router = router
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let request = task.request
        let id = ObjectIdentifier(task)
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let url = request.url ?? JiraRouter.startURL
        Task {
            let response = await router.handle(method: request.httpMethod ?? "GET", path: url.path.isEmpty ? "/" : url.path,
                                                query: url.query, body: body)
            guard !stopped.contains(id) else { return }
            let headers = ["Content-Type": response.contentType, "Cache-Control": "no-store"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                            headerFields: headers)!)
            task.didReceive(response.data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private static func readAll(_ stream: InputStream) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        stream.open()
        defer { stream.close() }
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
