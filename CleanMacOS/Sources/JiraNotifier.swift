import Foundation
import UserNotifications

@MainActor
final class JiraNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let pollInterval: Duration = .seconds(10)
    static let clockSkew: TimeInterval = 120
    static let maxCatchUp: TimeInterval = 7 * 24 * 3600
    static let stateKeyPrefix = "jira.watchState."
    nonisolated static let issueKeyInfo = "key"
    static let testTitle = "Clean macOS · Jira"
    static let testMessage = "TruongDepZai"

    private let onOpen: (String) -> Void
    private let onChange: ([String]) -> Void
    private var loop: Task<Void, Never>?
    private var postsNotifications = false

    init(onOpen: @escaping (String) -> Void, onChange: @escaping ([String]) -> Void) {
        self.onOpen = onOpen
        self.onChange = onChange
    }

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func start(service: JiraService, postsNotifications: Bool) {
        stop()
        self.postsNotifications = postsNotifications
        if postsNotifications, let center {
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        loop = Task { [weak self] in await self?.watch(service) }
    }

    func sendTest() async -> String {
        guard let center else { return "Notifications only work in the installed app" }
        center.delegate = self
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
            return "Notifications are off — allow Clean macOS in System Settings → Notifications"
        }
        post(JiraEvent(kind: .assigned, key: "", title: Self.testTitle, message: Self.testMessage))
        return "Test notification sent"
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private struct Session {
        let me: String
        let fields: JiraWatchFields
        let storeKey: String
        var state: JiraWatchState
    }

    private func watch(_ service: JiraService) async {
        var session: Session?
        var seen: [String: String]?
        while !Task.isCancelled {
            do {
                if session == nil { session = try await startSession(service) }
                if var current = session {
                    let pollStart = Date()
                    let issues = try await service.issuesUpdated(since: current.state.since, fields: current.fields)
                    let result = JiraEvents.detect(issues, me: current.me, fields: current.fields, state: current.state)
                    current.state = result.state
                    current.state.since = pollStart.addingTimeInterval(-Self.clockSkew)
                    session = current
                    save(current.state, key: current.storeKey)
                    if postsNotifications { result.events.forEach(post) }
                    let changes = JiraChanges.changedKeys(issues, seen: seen ?? [:])
                    if seen != nil, !changes.keys.isEmpty { onChange(changes.keys) }
                    seen = changes.seen
                }
            } catch {
                NSLog("JiraNotifier.watch failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func startSession(_ service: JiraService) async throws -> Session {
        let me = try await service.myIdentity()
        let fields = try await service.watchFields()
        let storeKey = "\(Self.stateKeyPrefix)\(JiraSettings.domain)|\(me)"
        let oldest = Date().addingTimeInterval(-Self.maxCatchUp)
        if var saved = load(key: storeKey) {
            saved.since = max(saved.since, oldest)
            return Session(me: me, fields: fields, storeKey: storeKey, state: saved)
        }
        let reviewing = try? await service.myKeys(inAnyOf: [fields.reviewers].compactMap { $0 })
        let state = JiraWatchState(knownAssigned: try await service.myKeys(inAnyOf: fields.assignees),
                                   knownReviewing: reviewing ?? [],
                                   since: Date().addingTimeInterval(-Self.clockSkew))
        save(state, key: storeKey)
        return Session(me: me, fields: fields, storeKey: storeKey, state: state)
    }

    private func load(key: String) -> JiraWatchState? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(JiraWatchState.self, from: $0) }
    }

    private func save(_ state: JiraWatchState, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: key)
    }

    private func post(_ event: JiraEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.message
        content.sound = .default
        content.userInfo = [Self.issueKeyInfo: event.key]
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo[Self.issueKeyInfo] as? String ?? ""
        await MainActor.run { onOpen(key) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
