import Foundation
import Testing
@testable import CleanMacOS

struct GoogleSignInTests {
    private static func reply(_ status: Int, _ json: String) -> HTTPTransport {
        { request in
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func pkceMatchesTheRFCExample() {
        #expect(OAuthPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = OAuthPKCE.verifier()
        #expect(verifier.count == 64)
        #expect(!verifier.contains("+") && !verifier.contains("/") && !verifier.contains("="))
    }

    @Test func buildsTheGoogleAuthURLForADesktopApp() throws {
        let url = GoogleAuthURL.make(clientID: "client.apps.googleusercontent.com", redirectURI: "http://127.0.0.1:5000",
                                     challenge: "abc", state: "xyz")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(url.host() == "accounts.google.com")
        #expect(value("redirect_uri") == "http://127.0.0.1:5000")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("scope") == "openid email profile")
        #expect(value("access_type") == "offline")
        #expect(String(decoding: GoogleAuthURL.form(["b": "1/2 3", "a": "x"]), as: UTF8.self) == "a=x&b=1%2F2%203")
    }

    @Test func readsTheRedirectRequestLine() {
        let components = LoopbackRedirect.components(fromRequest: "GET /?state=s1&code=4%2F0Ab HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(components?.queryItems?.first { $0.name == "code" }?.value == "4/0Ab")
        #expect(LoopbackRedirect.components(fromRequest: "POST / HTTP/1.1\r\n") == nil)
    }

    @Test func receivesTheGoogleRedirectOnLoopback() async throws {
        let redirect = try LoopbackRedirect()
        let port = try await redirect.start()
        #expect(port > 0)
        async let reply = redirect.waitForReply()
        try await Task.sleep(for: .milliseconds(100))
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?state=abc&code=xyz")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("signed in"))
        let components = try await reply
        #expect(components.queryItems?.first { $0.name == "code" }?.value == "xyz")
        redirect.stop()
    }

    @Test func exchangesTheCodeAndSignsIntoFirebase() async throws {
        let tokens = try await GoogleIdentityClient(transport: Self.reply(200, #"{"id_token":"id1","refresh_token":"r1"}"#))
            .exchange(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        #expect(tokens.idToken == "id1" && tokens.refreshToken == "r1")
        let user = try await GoogleIdentityClient(transport: Self.reply(200, #"{"localId":"u1","email":"a@b.com","displayName":"An"}"#))
            .firebaseSignIn(idToken: "id1")
        #expect(user.uid == "u1" && user.email == "a@b.com" && user.name == "An")
        await #expect(throws: SignInError.revoked) {
            try await GoogleIdentityClient(transport: Self.reply(400, #"{"error":"invalid_grant"}"#)).refresh("r1")
        }
    }

    @MainActor
    @Test func keepsTheSessionAndSignsOutWhenGoogleRevokesIt() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("account-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = TokenFileStore(fileURL: file)
        let saved = GoogleAccount(uid: "u1", email: "a@b.com", name: "An", refreshToken: "r1")
        try store.save(String(decoding: try JSONEncoder().encode(saved), as: UTF8.self))

        #expect(AccountViewModel(store: store, isConfigured: false).needsSignIn == false)
        let signedIn = AccountViewModel(store: store, client: GoogleIdentityClient(transport: Self.reply(200,
            #"{"id_token":"id2","localId":"u1","email":"a@b.com","displayName":"An B"}"#)), isConfigured: true)
        #expect(signedIn.needsSignIn == false)
        await signedIn.refreshSession()
        #expect(signedIn.account?.name == "An B")

        let revoked = AccountViewModel(store: store, client: GoogleIdentityClient(transport: Self.reply(400, #"{"error":"invalid_grant"}"#)),
                                       isConfigured: true)
        await revoked.refreshSession()
        #expect(revoked.account == nil)
        #expect(revoked.needsSignIn)
        #expect(store.read() == nil)

        try store.save(String(decoding: try JSONEncoder().encode(saved), as: UTF8.self))
        let offline = AccountViewModel(store: store, client: GoogleIdentityClient(transport: { _ in throw URLError(.notConnectedToInternet) }),
                                       isConfigured: true)
        await offline.refreshSession()
        #expect(offline.account == saved)
        #expect(!offline.needsSignIn)
    }
}
