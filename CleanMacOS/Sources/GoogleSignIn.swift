import AppKit
import CryptoKit
import Network

enum GoogleAccountConfig {
    static let firebaseAPIKey = ""
    static let clientID = ""
    static let clientSecret = ""

    static var isConfigured: Bool { !firebaseAPIKey.isEmpty && !clientID.isEmpty && !clientSecret.isEmpty }
}

struct GoogleAccount: Codable, Equatable {
    let uid: String
    let email: String
    let name: String?
    let refreshToken: String
}

enum OAuthPKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum GoogleAuthURL {
    static let endpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let scopes = "openid email profile"

    static func make(clientID: String, redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        return components.url!
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

enum SignInError: LocalizedError, Equatable {
    case notConfigured, cancelled, timedOut, revoked, failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Sign-in is not set up in this build."
        case .cancelled: "Sign-in was cancelled."
        case .timedOut: "Sign-in timed out. Try again."
        case .revoked: "Your Google sign-in has expired. Sign in again."
        case .failed(let message): message
        }
    }
}

typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

struct GoogleIdentityClient {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let firebaseSignInURL = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp"

    var transport: HTTPTransport = { try await URLSession.shared.data(for: $0) }

    func exchange(code: String, verifier: String, redirectURI: String) async throws -> (idToken: String, refreshToken: String?) {
        let reply = try await post(Self.tokenURL, form: [
            "code": code, "code_verifier": verifier, "redirect_uri": redirectURI, "grant_type": "authorization_code",
            "client_id": GoogleAccountConfig.clientID, "client_secret": GoogleAccountConfig.clientSecret,
        ])
        guard let idToken = reply["id_token"] as? String else { throw SignInError.failed("Google did not return an ID token.") }
        return (idToken, reply["refresh_token"] as? String)
    }

    func refresh(_ refreshToken: String) async throws -> String {
        let reply = try await post(Self.tokenURL, form: [
            "refresh_token": refreshToken, "grant_type": "refresh_token",
            "client_id": GoogleAccountConfig.clientID, "client_secret": GoogleAccountConfig.clientSecret,
        ])
        guard let idToken = reply["id_token"] as? String else { throw SignInError.revoked }
        return idToken
    }

    func revoke(_ refreshToken: String) async {
        _ = try? await post(Self.revokeURL, form: ["token": refreshToken])
    }

    func firebaseSignIn(idToken: String) async throws -> (uid: String, email: String, name: String?) {
        var request = URLRequest(url: URL(string: "\(Self.firebaseSignInURL)?key=\(GoogleAccountConfig.firebaseAPIKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "postBody": "id_token=\(idToken)&providerId=google.com", "requestUri": "http://localhost",
            "returnSecureToken": true, "returnIdpCredential": true,
        ])
        let reply = try await send(request)
        guard let uid = reply["localId"] as? String, let email = reply["email"] as? String else {
            throw SignInError.failed("Firebase did not accept the Google sign-in.")
        }
        return (uid, email, reply["displayName"] as? String)
    }

    private func post(_ url: URL, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleAuthURL.form(form)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport(request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            let error = object["error"] as? String ?? (object["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
            throw error == "invalid_grant" ? SignInError.revoked : SignInError.failed("Sign-in failed: \(error)")
        }
        return object
    }
}

final class LoopbackRedirect: @unchecked Sendable {
    static let page = """
    <html><body style="font-family:-apple-system,sans-serif;text-align:center;padding-top:90px">\
    <h2>You're signed in to Clean macOS</h2><p>You can close this tab and go back to the app.</p></body></html>
    """

    private let listener: NWListener
    private let queue = DispatchQueue(label: "click.ngoctruong.CleanMacOS.oauth")
    private var reply: CheckedContinuation<URLComponents, Error>?
    private var started: CheckedContinuation<Int, Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func components(fromRequest text: String) -> URLComponents? {
        let parts = text.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return URLComponents(string: "http://127.0.0.1\(parts[1])")
    }

    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                started = continuation
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                listener.start(queue: queue)
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        guard let started else { return }
        switch state {
        case .ready:
            self.started = nil
            started.resume(returning: Int(listener.port?.rawValue ?? 0))
        case .failed(let error):
            self.started = nil
            started.resume(throwing: error)
        default:
            break
        }
    }

    func waitForReply() async throws -> URLComponents {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in reply = continuation }
        }
    }

    func stop(with error: Error? = nil) {
        queue.async { [self] in
            if let error, let reply {
                self.reply = nil
                reply.resume(throwing: error)
            }
            listener.cancel()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let components = Self.components(fromRequest: request)
            let isRedirect = components?.queryItems?.contains { $0.name == "code" || $0.name == "error" } ?? false
            let body = isRedirect ? Self.page : "Not found"
            let response = "HTTP/1.1 \(isRedirect ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard isRedirect, let components, let reply = self.reply else { return }
            self.reply = nil
            reply.resume(returning: components)
        }
    }
}
