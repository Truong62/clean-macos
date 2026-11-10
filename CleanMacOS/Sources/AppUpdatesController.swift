import AppKit
import UserNotifications

extension AppScanner {
    static let spotlightQuery = "kMDItemContentType == 'com.apple.application-bundle'"

    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser, ownBundleID: String?) -> [AppBundle] {
        let folders = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var seen = Set<String>()
        let urls = (folders.flatMap(bundles(in:)) + spotlight(home: home)).filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
        return unique(urls.compactMap(AppBundle.read(at:)), ownBundleID: ownBundleID)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func bundles(in folder: URL) -> [URL] {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return entries.flatMap { url -> [URL] in
            guard url.pathExtension != "app" else { return [url] }
            return ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .filter { $0.pathExtension == "app" }
        }
    }

    static func spotlight(home: URL) -> [URL] {
        CommandRunner.run("/usr/bin/mdfind", ["-onlyin", home.path, spotlightQuery]).output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { isSpotlightCandidate($0, home: home.path) }
            .map { URL(fileURLWithPath: $0) }
    }
}

struct FeedFetcher: Sendable {
    static let requestTimeout: TimeInterval = 20
    static let tooLarge = "The answer is larger than 2 MB"

    func fetchAll(_ requests: [String: URL]) async -> [String: FeedOutcome] {
        guard !requests.isEmpty else { return [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = FeedPolicy.budget
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var queue = Array(requests)
        var results: [String: FeedOutcome] = [:]
        await withTaskGroup(of: (String, FeedOutcome)?.self) { group in
            group.addTask {
                try? await Task.sleep(for: .seconds(FeedPolicy.budget))
                return nil
            }
            for _ in 0..<FeedPolicy.concurrency {
                guard let (key, url) = queue.popLast() else { break }
                group.addTask { (key, await Self.fetch(url, session: session)) }
            }
            while let next = await group.next() {
                guard let (key, outcome) = next else {
                    group.cancelAll()
                    break
                }
                results[key] = outcome
                if let (key, url) = queue.popLast() {
                    group.addTask { (key, await Self.fetch(url, session: session)) }
                } else if results.count == requests.count {
                    group.cancelAll()
                }
            }
        }
        for key in requests.keys where results[key] == nil { results[key] = .failed(AppUpdatePlanner.timedOut) }
        return results
    }

    private static func fetch(_ url: URL, session: URLSession) async -> FeedOutcome {
        guard FeedPolicy.isAllowed(url) else { return .failed("The update feed is not HTTPS") }
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url), delegate: SecureRedirects())
            guard let http = response as? HTTPURLResponse else { return .failed("The server did not answer over HTTP") }
            guard (200..<300).contains(http.statusCode) else { return .failed("The server answered \(http.statusCode)") }
            guard http.expectedContentLength <= Int64(FeedPolicy.maxBytes) else { return .failed(tooLarge) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > FeedPolicy.maxBytes { return .failed(tooLarge) }
            }
            return .data(data)
        } catch {
            return .failed(Task.isCancelled ? AppUpdatePlanner.timedOut : error.localizedDescription)
        }
    }

    private final class SecureRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url.map(FeedPolicy.isAllowed) == true ? request : nil
        }
    }
}

struct AppUpdateService: Sendable {
    static let catalogURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    static let catalogLife: TimeInterval = 3600

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var country: String { Locale.current.region?.identifier ?? "US" }

    func check(settings: AppUpdateSettings, brew: BrewClient?, ownBundleID: String?) async -> AppUpdateReport {
        let apps = await Task.detached { AppScanner.scan(ownBundleID: ownBundleID) }.value.filter { !settings.rules.isExcluded($0.bundleID) }
        let casks = settings.checksHomebrew ? await installedCasks(brew) : nil
        let index = casks.map(CaskIndex.init)
        let routed = apps.compactMap { app in
            AppUpdatePlanner.route(app, settings: settings, installedCasks: index).map { RoutedApp(app: app, route: $0) }
        }
        let plan = UpdateFetchPlan(routed, country: Self.country)
        async let fetched = FeedFetcher().fetchAll(plan.requests)
        async let outdated = outdatedCasks(routed.contains(where: \.route.isHomebrew) ? brew : nil)
        async let catalog = loadCatalog(routed.contains { $0.route == .catalog })
        var evidence = plan.evidence(from: await fetched, systemVersion: Self.systemVersion)
        evidence.outdatedCasks = await outdated
        evidence.catalog = await catalog
        var report = AppUpdatePlanner.report(routed, evidence: evidence)
        if settings.checksHomebrew, brew != nil, casks == nil {
            report.failures.append(AppCheckFailure(name: "Homebrew", reason: "brew info did not answer"))
        }
        return report
    }

    private func installedCasks(_ brew: BrewClient?) async -> [BrewPackage]? {
        guard let brew else { return nil }
        return await Task.detached { brew.installed()?.filter { $0.kind == .cask } }.value
    }

    private func outdatedCasks(_ brew: BrewClient?) async -> [String: BrewOutdated]? {
        guard let brew else { return [:] }
        return await Task.detached { brew.outdated(greedyCasks: true).map(BrewOutdated.byToken) }.value
    }

    private func loadCatalog(_ isNeeded: Bool) async -> CaskIndex? {
        guard isNeeded, let data = await DownloadCache.standard.data(from: Self.catalogURL, name: "cask.json", maxAge: Self.catalogLife),
              let casks = BrewJSON.catalog(from: data) else { return nil }
        return CaskIndex(casks)
    }
}

@MainActor
final class AppUpdatesController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let settingsKey = "appUpdates.settings"
    static let staleAfter: TimeInterval = 600
    static let startDelay: TimeInterval = 180
    static let notificationID = "mackit.appUpdates"

    @Published var settings: AppUpdateSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if settings.schedule != oldValue.schedule { armSchedule(notBefore: Date().addingTimeInterval(Self.startDelay)) }
            if settings.notifies && !oldValue.notifies { requestNotifications() }
        }
    }
    @Published private(set) var report: AppUpdateReport?
    @Published var selection: Set<AppUpdate.ID> = []
    @Published private(set) var isChecking = false
    @Published var message = ""

    private let homebrew: HomebrewController
    private let service = AppUpdateService()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(homebrew: HomebrewController) {
        self.homebrew = homebrew
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(AppUpdateSettings.self, from: $0) }
            ?? AppUpdateSettings()
        super.init()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.armSchedule(notBefore: Date().addingTimeInterval(Self.startDelay)) }
        }
        armSchedule(notBefore: Date().addingTimeInterval(Self.startDelay))
        if settings.notifies { Self.notificationCenter?.delegate = self }
    }

    var updates: [AppUpdate] { (report?.updates ?? []).filter(settings.rules.allows) }
    var failures: [AppCheckFailure] { (report?.failures ?? []).filter { $0.bundleID.map { !settings.rules.isExcluded($0) } ?? true } }
    var selectedUpdates: [AppUpdate] { updates.filter { selection.contains($0.id) } }

    func checkIfStale() {
        let isStale = settings.lastCheck.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
        if report == nil || isStale { check() }
    }

    func check(isScheduled: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        message = ""
        let settings = settings
        Task {
            let found = await service.check(settings: settings, brew: BrewClient.locate(), ownBundleID: Bundle.main.bundleIdentifier)
            finishCheck(found, isScheduled: isScheduled)
        }
    }

    func update(_ chosen: [AppUpdate]) {
        let plan = AppUpdatePlan(chosen)
        if !plan.brewTokens.isEmpty, !homebrew.run(.upgradeApps(plan.brewTokens), then: { [weak self] in self?.check() }) {
            message = homebrew.message
        }
        for link in plan.storeLinks + plan.homepages { _ = NSWorkspace.shared.open(link) }
        for path in plan.appPaths {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func skip(_ update: AppUpdate) {
        settings.rules.skippedVersions[update.app.bundleID] = update.latest
    }

    func unskip(_ bundleID: String) {
        settings.rules.skippedVersions[bundleID] = nil
    }

    func exclude(_ bundleID: String) {
        if !settings.rules.isExcluded(bundleID) { settings.rules.excludedBundleIDs.append(bundleID) }
    }

    func include(_ bundleID: String) {
        settings.rules.excludedBundleIDs.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    private func finishCheck(_ found: AppUpdateReport, isScheduled: Bool) {
        report = found
        selection = Set(updates.map(\.id))
        settings.lastCheck = Date()
        isChecking = false
        armSchedule(notBefore: Date())
        if isScheduled { notify() }
    }

    private func armSchedule(notBefore earliest: Date) {
        timer?.invalidate()
        timer = nil
        guard let date = settings.schedule.nextCheck(after: settings.lastCheck, notBefore: earliest) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(date.timeIntervalSinceNow, 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(isScheduled: true) }
        }
    }

    private static var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    private func requestNotifications() {
        guard let center = Self.notificationCenter else {
            message = "Notifications work only in the installed app."
            DispatchQueue.main.async { MainActor.assumeIsolated { self.settings.notifies = false } }
            return
        }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard !granted else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.settings.notifies = false
                    self?.message = "Allow notifications for \(AppIdentity.installedName) in System Settings → Notifications."
                }
            }
        }
    }

    private func notify() {
        guard settings.notifies, !NSApp.isActive, let center = Self.notificationCenter else { return }
        let fresh = UpdateNotice.fresh(updates, notified: settings.notifiedKeys)
        guard !fresh.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? "An app update is available" : "\(fresh.count) app updates are available"
        content.body = UpdateNotice.body(fresh)
        center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
        settings.notifiedKeys = UpdateNotice.remembering(fresh, in: settings.notifiedKeys)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                MainWindowController.show()
                NotificationCenter.default.post(name: .openSidebarPage, object: SidebarPage.appUpdates)
            }
        }
        completionHandler()
    }
}
