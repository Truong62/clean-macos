import SwiftUI
import WebKit

struct JiraView: View {
    @EnvironmentObject var jira: JiraViewModel
    let openSettings: () -> Void

    var body: some View {
        if jira.isConfigured {
            JiraWebView(url: jira.webURL, router: JiraRouter(service: { [weak jira] in jira?.service }))
                .id(jira.service.map(ObjectIdentifier.init))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue.gradient)
                Text("Set up Jira").font(.title2).fontWeight(.bold)
                Text("Enter your Jira domain and API token in Settings.")
                    .foregroundStyle(.secondary)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct JiraWebView: NSViewRepresentable {
    let url: URL
    let router: JiraRouter

    final class Coordinator {
        var handler: JiraSchemeHandler?
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let handler = JiraSchemeHandler(router: router)
        context.coordinator.handler = handler
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: JiraRouter.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }
}
