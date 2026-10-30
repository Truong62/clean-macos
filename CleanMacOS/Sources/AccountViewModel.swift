import AppKit
import SwiftUI

@MainActor
final class AccountViewModel: ObservableObject {
    static let signInTimeout: Duration = .seconds(300)
    nonisolated static let fileName = "google-account"

    @Published private(set) var account: GoogleAccount?
    @Published private(set) var isSigningIn = false
    @Published var message: String?

    private let store: TokenFileStore
    private let client: GoogleIdentityClient
    private let isConfigured: Bool
    private var redirect: LoopbackRedirect?

    init(store: TokenFileStore = TokenFileStore(fileURL: AccountViewModel.defaultFile), client: GoogleIdentityClient = GoogleIdentityClient(),
         isConfigured: Bool = GoogleAccountConfig.isConfigured) {
        self.store = store
        self.client = client
        self.isConfigured = isConfigured
        account = store.read().flatMap { try? JSONDecoder().decode(GoogleAccount.self, from: Data($0.utf8)) }
    }

    nonisolated static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanMacOS", isDirectory: true).appendingPathComponent(fileName)
    }

    var needsSignIn: Bool { isConfigured && account == nil }

    func signIn() async {
        guard isConfigured else {
            message = SignInError.notConfigured.localizedDescription
            return
        }
        guard !isSigningIn else { return }
        isSigningIn = true
        message = nil
        defer {
            isSigningIn = false
            redirect = nil
        }
        do {
            let redirect = try LoopbackRedirect()
            self.redirect = redirect
            let port = try await redirect.start()
            let verifier = OAuthPKCE.verifier()
            let state = UUID().uuidString
            let redirectURI = "http://127.0.0.1:\(port)"
            NSWorkspace.shared.open(GoogleAuthURL.make(clientID: GoogleAccountConfig.clientID, redirectURI: redirectURI,
                                                       challenge: OAuthPKCE.challenge(for: verifier), state: state))
            let timeout = Task {
                try? await Task.sleep(for: Self.signInTimeout)
                redirect.stop(with: SignInError.timedOut)
            }
            defer { timeout.cancel() }
            let reply = try await redirect.waitForReply()
            redirect.stop()
            let items = reply.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            if value("error") != nil { throw SignInError.cancelled }
            guard value("state") == state, let code = value("code") else {
                throw SignInError.failed("The sign-in reply did not match. Try again.")
            }
            let tokens = try await client.exchange(code: code, verifier: verifier, redirectURI: redirectURI)
            let user = try await client.firebaseSignIn(idToken: tokens.idToken)
            try save(GoogleAccount(uid: user.uid, email: user.email, name: user.name, refreshToken: tokens.refreshToken ?? ""))
            NSApp.activate()
        } catch {
            message = error.localizedDescription
        }
    }

    func cancelSignIn() {
        redirect?.stop(with: SignInError.cancelled)
    }

    func refreshSession() async {
        guard isConfigured, let account, !account.refreshToken.isEmpty else { return }
        do {
            let idToken = try await client.refresh(account.refreshToken)
            let user = try await client.firebaseSignIn(idToken: idToken)
            try save(GoogleAccount(uid: user.uid, email: user.email, name: user.name, refreshToken: account.refreshToken))
        } catch SignInError.revoked {
            signOutLocally()
            message = SignInError.revoked.localizedDescription
        } catch {
            return
        }
    }

    func signOut() async {
        let token = account?.refreshToken
        signOutLocally()
        if let token, !token.isEmpty { await client.revoke(token) }
    }

    private func signOutLocally() {
        store.delete()
        account = nil
    }

    private func save(_ account: GoogleAccount) throws {
        try store.save(String(decoding: try JSONEncoder().encode(account), as: UTF8.self))
        self.account = account
    }
}

struct SignInView: View {
    @EnvironmentObject var account: AccountViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to Clean macOS").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Sign in with your Google account to continue.").foregroundStyle(.secondary)
            if account.isSigningIn {
                ProgressView().controlSize(.small).padding(.top, 6)
                Text("Finish signing in in your browser…").font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { account.cancelSignIn() }
            } else {
                Button {
                    Task { await account.signIn() }
                } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark").frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
            }
            if let message = account.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
