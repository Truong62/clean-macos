import Foundation

import Testing
import WebKit
@testable import CleanMacOS

@MainActor
struct JiraWebViewLinkTests {
    @Test func externalLinksOpenInBrowserAndPageStays() async throws {
        var opened: [URL] = []
        let original = JiraWebView.urlOpener
        JiraWebView.urlOpener = { opened.append($0) }
        defer { JiraWebView.urlOpener = original }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<a id=blank target=_blank rel=noopener href='https://space.avada.net/browse/FAL-1'>b</a><a id=same href='https://example.com/x'>s</a>".utf8)
            .write(to: dir.appendingPathComponent("index.html"))
        let coordinator = JiraWebView.Coordinator()
        let handler = JiraSchemeHandler(router: JiraRouter(service: { nil }, webRoot: dir))
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: JiraRouter.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        web.uiDelegate = coordinator
        web.navigationDelegate = coordinator
        web.load(URLRequest(url: JiraRouter.startURL))
        for _ in 0..<50 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await web.callAsyncJavaScript("document.getElementById('blank').click(); document.getElementById('same').click(); return 1", contentWorld: .page)
        try await Task.sleep(for: .seconds(1))
        #expect(Set(opened.map(\.absoluteString)) == ["https://space.avada.net/browse/FAL-1", "https://example.com/x"])
        #expect(web.url?.scheme == JiraRouter.scheme)
    }
}
