import Foundation

struct CaptureLink: Codable, Equatable, Identifiable {
    let id: String
    let url: URL
    let expiresAt: Date
    let deleteToken: String
    var backend: URL?
}

enum CaptureLinkPolicy {
    static let maxBytes = 25 * 1024 * 1024
    static func endpoint(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }
    static func validate(_ link: CaptureLink, now: Date) -> Bool {
        !link.id.isEmpty && link.id.count <= 128 && link.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } && !link.deleteToken.isEmpty && !link.deleteToken.contains(where: \.isNewline) && link.url.scheme?.lowercased() == "https" && link.url.host != nil &&
            link.expiresAt > now && link.expiresAt.timeIntervalSince(now) <= 24 * 3600 + 300
    }
    static func live(_ links: [CaptureLink], now: Date) -> [CaptureLink] { links.filter { $0.expiresAt > now } }
}

struct CaptureLinkClient {
    enum Failure: Error { case invalidBackend, tooLarge, invalidReply, rejected }
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func upload(_ data: Data, backend: URL, hours: Int) async throws -> CaptureLink {
        guard CaptureLinkPolicy.endpoint(backend.absoluteString) != nil else { throw Failure.invalidBackend }
        guard data.count <= CaptureLinkPolicy.maxBytes else { throw Failure.tooLarge }
        var request = URLRequest(url: backend.appendingPathComponent("captures"))
        request.httpMethod = "POST"
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue(String([1, 6, 24].contains(hours) ? hours : 1), forHTTPHeaderField: "X-Expiry-Hours")
        request.timeoutInterval = 60
        let (body, response) = try await session.upload(for: request, from: data)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw Failure.rejected }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var link = try decoder.decode(CaptureLink.self, from: body)
        guard CaptureLinkPolicy.validate(link, now: Date()) else { throw Failure.invalidReply }
        link.backend = backend
        return link
    }

    func delete(_ link: CaptureLink) async throws {
        guard let backend = link.backend, CaptureLinkPolicy.endpoint(backend.absoluteString) != nil else { throw Failure.invalidBackend }
        var request = URLRequest(url: backend.appendingPathComponent("captures").appendingPathComponent(link.id))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(link.deleteToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) || response.statusCode == 404 else { throw Failure.rejected }
    }
}
