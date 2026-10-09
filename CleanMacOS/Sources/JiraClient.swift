import Foundation

/// Jira failure carrying an HTTP-like status (Jira status, 400 for bad input, 502 when unreachable).
struct JiraError: Error, LocalizedError, Equatable {
    let status: Int
    let message: String

    var errorDescription: String? { message }
}

/// URLSession adapter for the Jira REST API: auth, `User-Agent: curl/8`, JSON in/out.
struct JiraClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let userAgent = "curl/8"
    static let timeoutSeconds: TimeInterval = 30
    static let maxErrorTextLength = 300
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    let baseURL: String
    let authKind: JiraSettings.AuthKind
    private let email: String
    private let token: String
    private let transport: Transport

    init(baseURL: String, authKind: JiraSettings.AuthKind = .server, email: String = "", token: String,
         transport: @escaping Transport = JiraClient.urlSessionTransport) {
        self.baseURL = JiraSettings.normalizedDomain(baseURL)
        self.authKind = authKind
        self.email = email
        self.token = token
        self.transport = transport
    }

    static func fromSettings(token: String?) -> JiraClient? {
        guard !JiraSettings.domain.isEmpty, let token, !token.isEmpty else { return nil }
        if JiraSettings.authKind == .cloud && JiraSettings.email.isEmpty { return nil }
        return JiraClient(baseURL: JiraSettings.domain, authKind: JiraSettings.authKind,
                          email: JiraSettings.email, token: token)
    }

    static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    var authorizationHeader: String {
        switch authKind {
        case .server: return "Bearer \(token)"
        case .cloud: return "Basic \(Data("\(email):\(token)".utf8).base64EncodedString())"
        }
    }

    func requestRaw(method: String = "GET", path: String, query: [String: String] = [:],
                    body: Any? = nil) async throws -> (data: Data, contentType: String) {
        var request = URLRequest(url: try makeURL(path: path, query: query), timeoutInterval: Self.timeoutSeconds)
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw JiraError(status: 502, message: "Cannot reach Jira: \(error.localizedDescription)")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw JiraError(status: response.statusCode, message: Self.parseErrorMessage(data))
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, contentType)
    }

    func request(method: String = "GET", path: String, query: [String: String] = [:],
                 body: Any? = nil) async throws -> Data {
        try await requestRaw(method: method, path: path, query: query, body: body).data
    }

    func json(method: String = "GET", path: String, query: [String: String] = [:],
              body: Any? = nil) async throws -> Any? {
        let data = try await request(method: method, path: path, query: query, body: body)
        return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
    }

    func makeURL(path: String, query: [String: String]) throws -> URL {
        let queryString = query.keys.sorted().map { key in
            "\(Self.encode(key))=\(Self.encode(query[key] ?? ""))"
        }.joined(separator: "&")
        guard let url = URL(string: baseURL + path + (queryString.isEmpty ? "" : "?\(queryString)")) else {
            throw JiraError(status: 400, message: "Invalid Jira URL: \(baseURL)\(path)")
        }
        return url
    }

    static func parseErrorMessage(_ data: Data) -> String {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return String(decoding: data.prefix(maxErrorTextLength), as: UTF8.self)
        }
        var messages = payload["errorMessages"] as? [String] ?? []
        let errors = payload["errors"] as? [String: Any] ?? [:]
        messages += errors.keys.sorted().map { "\($0): \(errors[$0] ?? "")" }
        return messages.isEmpty ? "Unknown Jira error" : messages.joined(separator: "; ")
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
    }
}
