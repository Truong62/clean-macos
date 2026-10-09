import Foundation

@MainActor
final class JiraViewModel: ObservableObject {
    static let menuRefreshInterval: Duration = .seconds(60)

    @Published private(set) var service: JiraService?
    @Published private(set) var webURL = JiraRouter.startURL
    @Published private(set) var openRequestCount = 0
    @Published private(set) var menu = JiraMenuSnapshot()
    @Published private(set) var menuError: String?
    @Published private(set) var menuUpdatedAt: Date?

    private let keychain: KeychainStore
    private var token: String?
    private let kpiStore: JiraKpiStore
    private var menuLoop: Task<Void, Never>?
    private lazy var notifier = JiraNotifier { [weak self] key in self?.openFromOutside(issueKey: key) }

    init(keychain: KeychainStore = KeychainStore(), kpiStore: JiraKpiStore = JiraKpiStore()) {
        self.keychain = keychain
        self.kpiStore = kpiStore
        token = keychain.read()
        service = Self.makeService(token: token)
    }

    var isConfigured: Bool { service != nil }

    var hasToken: Bool { !(token ?? "").isEmpty }

    func reload() {
        service = Self.makeService(token: token)
        webURL = JiraRouter.startURL
        menu = JiraMenuSnapshot()
        menuError = nil
        menuUpdatedAt = nil
        restartBackgroundWork()
    }

    func restartBackgroundWork() {
        menuLoop?.cancel()
        notifier.stop()
        guard let service else { return }
        if JiraSettings.notificationsEnabled { notifier.start(service: service) }
        if JiraSettings.menuBarEnabled {
            menuLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshMenu()
                    try? await Task.sleep(for: Self.menuRefreshInterval)
                }
            }
        }
    }

    func refreshMenu() async {
        guard let service else { return }
        do {
            async let issues = service.listIssues()
            async let meta = service.getMeta()
            menu = JiraMenuSnapshot.make(issues: try await issues, meta: try await meta,
                                         kpi: kpiStore.read()?.issues ?? [:])
            menuUpdatedAt = Date()
            menuError = nil
        } catch let error as JiraError where error.status == 401 {
            menuError = "Token invalid — open Settings"
        } catch {
            menuError = "Offline — \(error.localizedDescription)"
        }
    }

    func open(issueKey: String) {
        openRequestCount += 1
        let fragment = issueKey.isEmpty ? "" : "#\(issueKey)"
        webURL = URL(string: "\(JiraRouter.startURL.absoluteString)?open=\(openRequestCount)\(fragment)") ?? JiraRouter.startURL
    }

    func openFromOutside(issueKey: String) {
        MainWindowController.show()
        open(issueKey: issueKey)
    }

    func sendTestNotification() async -> String {
        await notifier.sendTest()
    }

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { keychain.delete() } else { try keychain.save(trimmed) }
        self.token = trimmed.isEmpty ? nil : trimmed
    }

    func testConnection() async -> String {
        guard let client = JiraClient.fromSettings(token: token) else { return "Fill in domain and token first" }
        do {
            let me = try await client.json(path: "/rest/api/2/myself") as? JiraJSON
            return "Connected as \(me?["displayName"] as? String ?? "unknown user")"
        } catch {
            return error.localizedDescription
        }
    }

    private static func makeService(token: String?) -> JiraService? {
        JiraClient.fromSettings(token: token).map { JiraService(client: $0) }
    }
}
