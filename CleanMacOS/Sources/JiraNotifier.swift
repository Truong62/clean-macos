import Foundation
import UserNotifications

@MainActor
final class JiraNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let pollInterval: Duration = .seconds(10)
    nonisolated static let issueKeyInfo = "key"

    private let onOpen: (String) -> Void
    private var loop: Task<Void, Never>?

    init(onOpen: @escaping (String) -> Void) {
        self.onOpen = onOpen
    }

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func start(service: JiraService) {
        stop()
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        loop = Task { [weak self] in await self?.watch(service) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func watch(_ service: JiraService) async {
        var watcher: (me: String, field: String, state: JiraWatchState)?
        while !Task.isCancelled {
            do {
                if let current = watcher {
                    let issues = try await service.recentlyUpdatedForWatch()
                    let result = JiraEvents.detect(issues, me: current.me, assigneesField: current.field, state: current.state)
                    watcher?.state = result.state
                    result.events.forEach(post)
                } else {
                    watcher = (try await service.myIdentity(), try await service.assigneesFieldId(),
                               JiraWatchState(knownAssigned: try await service.myIssueKeys(), seenComments: [], since: Date()))
                }
            } catch {
                NSLog("JiraNotifier.watch failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
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
