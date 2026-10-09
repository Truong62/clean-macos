import Foundation

@MainActor
final class JiraViewModel: ObservableObject {
    @Published private(set) var service: JiraService?
    @Published private(set) var webURL = JiraRouter.startURL
    @Published var openRequest: String?

    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        reload()
    }

    var isConfigured: Bool { service != nil }

    func reload() {
        service = JiraClient.fromSettings(keychain: keychain).map { JiraService(client: $0) }
        webURL = JiraRouter.startURL
    }

    func open(issueKey: String) {
        webURL = URL(string: "\(JiraRouter.startURL.absoluteString)#\(issueKey)") ?? JiraRouter.startURL
        openRequest = issueKey
    }

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { keychain.delete() } else { try keychain.save(trimmed) }
    }

    var hasToken: Bool { !(keychain.read() ?? "").isEmpty }

    func testConnection() async -> String {
        guard let client = JiraClient.fromSettings(keychain: keychain) else { return "Fill in domain and token first" }
        do {
            let me = try await client.json(path: "/rest/api/2/myself") as? JiraJSON
            return "Connected as \(me?["displayName"] as? String ?? "unknown user")"
        } catch {
            return error.localizedDescription
        }
    }
}
