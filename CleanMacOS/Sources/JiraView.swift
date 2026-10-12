import SwiftUI
import WebKit

struct JiraView: View {
    @EnvironmentObject var jira: JiraViewModel
    let openSettings: () -> Void

    var body: some View {
        if jira.isConfigured {
            JiraWebView(url: jira.webURL, router: JiraRouter(service: { [weak jira] in jira?.service }),
                        remoteChange: jira.remoteChange, navRequest: jira.navRequest,
                        onNav: { [weak jira] nav in jira?.updateNav(nav) })
                .id(jira.service.map(ObjectIdentifier.init))
        } else {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .font(.system(size: 40))
                            .foregroundStyle(.blue.gradient)
                        Text("Connect Jira").font(.title2).fontWeight(.bold)
                        Text("Server: Jira profile → Personal Access Tokens. Cloud: id.atlassian.com → API tokens.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        JiraSettingsForm(showsAdvanced: false)
                    }
                    .padding(18)
                    .frame(maxWidth: 560)
                    .glassCard(cornerRadius: 20)
                    Button("More options in Settings", action: openSettings)
                        .buttonStyle(.link)
                        .pointerCursor()
                }
                .padding(32)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct JiraWebView: NSViewRepresentable {
    let url: URL
    let router: JiraRouter
    let remoteChange: JiraRemoteChange
    var navRequest = JiraNavRequest(id: 0, list: nil, view: nil)
    var onNav: (JiraNav) -> Void = { _ in }

    static let navMessageName = "jiraNav"

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        var handler: JiraSchemeHandler?
        var loadedURL: URL?
        var lastChangeId = 0
        var lastNavRequestId = 0
        var onNav: (JiraNav) -> Void = { _ in }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let nav = JiraNav(message: message.body) { onNav(nav) }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { JiraWebView.openExternally(url) }
            return nil
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.begin { response in completionHandler(response == .OK ? panel.urls : nil) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, url.scheme != JiraRouter.scheme else {
                return decisionHandler(.allow)
            }
            JiraWebView.openExternally(url)
            decisionHandler(.cancel)
        }
    }

    @MainActor static var urlOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @MainActor static func openExternally(_ url: URL) {
        guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        urlOpener(url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: navMessageName)
    }

    func makeNSView(context: Context) -> WKWebView {
        let handler = JiraSchemeHandler(router: router)
        context.coordinator.handler = handler
        context.coordinator.lastChangeId = remoteChange.id
        context.coordinator.lastNavRequestId = navRequest.id
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: JiraRouter.scheme)
        configuration.userContentController.add(context.coordinator, name: Self.navMessageName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onNav = onNav
        if context.coordinator.lastNavRequestId != navRequest.id {
            context.coordinator.lastNavRequestId = navRequest.id
            webView.evaluateJavaScript(navRequest.script)
        }
        if context.coordinator.lastChangeId != remoteChange.id {
            context.coordinator.lastChangeId = remoteChange.id
            webView.evaluateJavaScript(Self.remoteUpdateScript(remoteChange.keys))
        }
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    static func remoteUpdateScript(_ keys: [String]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: keys)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return "void window.jiraRemoteUpdate?.(\(json))"
    }
}
