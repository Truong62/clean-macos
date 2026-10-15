import Foundation

struct JiraRemoteChange: Equatable {
    let id: Int
    let keys: [String]
}

@MainActor
final class JiraViewModel: ObservableObject {
    static let menuRefreshInterval: Duration = .seconds(60)

    @Published private(set) var service: JiraService?
    @Published private(set) var webURL = JiraRouter.startURL
    @Published private(set) var openRequestCount = 0
    @Published private(set) var menu = JiraMenuSnapshot()
    @Published private(set) var menuError: String?
    @Published private(set) var menuUpdatedAt: Date?

    private let tokenStore: TokenFileStore
    private var token: String?
    private let kpiStore: JiraKpiStore
    private var menuLoop: Task<Void, Never>?
    @Published private(set) var remoteChange = JiraRemoteChange(id: 0, keys: [])
    @Published private(set) var nav = JiraNav()
    @Published private(set) var navRequest = JiraNavRequest(id: 0, list: nil, view: nil)
    private lazy var notifier = JiraNotifier(
        onOpen: { [weak self] key in self?.openFromOutside(issueKey: key) },
        onChange: { [weak self] keys in self?.publishRemoteChange(keys) }
    )

    nonisolated static let tokenMovedKey = "jira.tokenMovedToFile"

    init(tokenStore: TokenFileStore = TokenFileStore(), legacyKeychain: KeychainStore? = KeychainStore(),
         kpiStore: JiraKpiStore = JiraKpiStore()) {
        self.tokenStore = tokenStore
        self.kpiStore = kpiStore
        token = Self.loadToken(store: tokenStore, legacy: legacyKeychain, defaults: .standard)
        service = Self.makeService(token: token)
    }

    nonisolated static func loadToken(store: TokenFileStore, legacy: KeychainStore?, defaults: UserDefaults) -> String? {
        if let token = store.read() { return token }
        guard let legacy, !defaults.bool(forKey: tokenMovedKey) else { return nil }
        defaults.set(true, forKey: tokenMovedKey)
        guard let token = legacy.read() else { return nil }
        try? store.save(token)
        return token
    }

    var isConfigured: Bool { service != nil && !JiraSettings.projectKey.isEmpty }

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
        notifier.start(service: service, postsNotifications: JiraSettings.notificationsEnabled)
        if JiraSettings.menuBarEnabled {
            menuLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshMenu()
                    try? await Task.sleep(for: Self.menuRefreshInterval)
                }
            }
        }
    }

    func updateNav(_ nav: JiraNav) {
        if self.nav != nav { self.nav = nav }
    }

    func selectNav(list: String? = nil, view: String? = nil) {
        if let list { nav.list = list }
        if let view { nav.view = view }
        navRequest = JiraNavRequest(id: navRequest.id + 1, list: list, view: view)
    }

    private func publishRemoteChange(_ keys: [String]) {
        remoteChange = JiraRemoteChange(id: remoteChange.id + 1, keys: keys)
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

    func importKpi(from url: URL) async -> String {
        guard let service else { return "Set up Jira first" }
        do {
            let csv = try String(contentsOf: url, encoding: .utf8)
            let data = try await service.importKpi(csv: csv, countedElsewhereJQL: JiraSettings.kpiCountedElsewhereJQL,
                                                   countedElsewhereMonth: JiraSettings.kpiCountedElsewhereMonth)
            try kpiStore.write(data)
            webURL = URL(string: "\(JiraRouter.startURL.absoluteString)?kpi=\(data.syncedAt)-\(data.issues.count)") ?? webURL
            await refreshMenu()
            let elsewhere = data.issues.values.filter { $0.source == JiraKpi.countedElsewhereSource }.count
            return "Imported KPI for \(data.issues.count) tasks (\(elsewhere) counted elsewhere)"
        } catch {
            return error.localizedDescription
        }
    }

    func sendTestNotification() async -> String {
        await notifier.sendTest()
    }

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { tokenStore.delete() } else { try tokenStore.save(trimmed) }
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
