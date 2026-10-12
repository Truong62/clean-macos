import Foundation
import Testing
import WebKit
@testable import CleanMacOS

struct JiraNavTests {
    @Test func parsesWebMessageWithMissingCounts() {
        let body: [String: Any] = [
            "list": "doing", "view": "board",
            "lists": [["id": "sprint", "label": "Sprint 7", "count": 11], ["id": "all", "label": "All tasks", "count": NSNull()]],
            "views": [["id": "table", "label": "Table", "count": NSNull()], ["label": "no id"]],
        ]
        let nav = JiraNav(message: body)
        #expect(nav?.list == "doing")
        #expect(nav?.view == "board")
        #expect(nav?.lists == [JiraNavItem(id: "sprint", label: "Sprint 7", count: 11), JiraNavItem(id: "all", label: "All tasks", count: nil)])
        #expect(nav?.views == [JiraNavItem(id: "table", label: "Table", count: nil)])
        #expect(JiraNav(message: "not a dictionary") == nil)
    }

    @Test func navRequestScriptSendsOnlyTheChangedSide() {
        #expect(JiraNavRequest(id: 1, list: "done", view: nil).script == #"void window.jiraSetNav?.({"list":"done"})"#)
        #expect(JiraNavRequest(id: 2, list: nil, view: "board").script == #"void window.jiraSetNav?.({"view":"board"})"#)
    }

    @MainActor @Test func selectingUpdatesNavAndIssuesNewRequest() {
        let jira = JiraViewModel(keychain: KeychainStore(service: "test.jira.nav.\(UUID())"))
        jira.selectNav(list: "done")
        jira.selectNav(view: "board")
        #expect(jira.nav.list == "done")
        #expect(jira.nav.view == "board")
        #expect(jira.navRequest == JiraNavRequest(id: 2, list: nil, view: "board"))
    }

    @MainActor @Test func webViewMessageReachesCoordinator() async throws {
        var received: [JiraNav] = []
        let coordinator = JiraWebView.Coordinator()
        coordinator.onNav = { received.append($0) }
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: JiraWebView.navMessageName)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
        web.loadHTMLString("<p>nav</p>", baseURL: nil)
        for _ in 0..<50 where web.isLoading { try await Task.sleep(for: .milliseconds(100)) }
        _ = try await web.callAsyncJavaScript(
            "window.webkit.messageHandlers.jiraNav.postMessage({list: 'doing', view: 'table', lists: [{id: 'doing', label: 'Doing', count: 2}], views: []}); return 1",
            contentWorld: .page)
        for _ in 0..<20 where received.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(received.first?.list == "doing")
        #expect(received.first?.lists == [JiraNavItem(id: "doing", label: "Doing", count: 2)])
    }
}
