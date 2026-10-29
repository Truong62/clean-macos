import AppKit

enum SignInBrowser {
    static let defaultTimeout = 300.0
    static let maxTimeout = 900.0
    static let shutdownTimeout: Duration = .seconds(10)

    static func pageCount(fromTargets data: Data) -> Int? {
        guard let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return targets.filter { $0["type"] as? String == "page" }.count
    }

    @MainActor
    static func run(url: String, browser: String?, timeout: Double) async throws -> [String: Any] {
        guard BrowserURL.isAllowed(url) else { throw MCPToolError.message("url must start with http://, https:// or file://.") }
        let executable = try HeadlessBrowser.executableURL(for: browser)
        let profile = try HeadlessBrowser.profileFolder()
        HeadlessBrowser.stopLeftover(in: profile)
        try? FileManager.default.removeItem(at: profile.appendingPathComponent("DevToolsActivePort"))
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--user-data-dir=\(profile.path)", "--use-mock-keychain", "--password-store=basic", "--no-first-run",
            "--no-default-browser-check", "--remote-debugging-port=0", "--new-window", url,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let port = try await HeadlessBrowser.waitForPort(in: profile, process: process)
        NSRunningApplication(processIdentifier: process.processIdentifier)?.activate()
        let deadline = ContinuousClock.now + .seconds(min(max(timeout, 10), maxTimeout))
        var hasSeenPage = false
        var isClosed = false
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            guard process.isRunning else {
                isClosed = true
                break
            }
            let list = URL(string: "http://127.0.0.1:\(port)/json/list")!
            guard let (data, _) = try? await URLSession.shared.data(from: list), let pages = pageCount(fromTargets: data) else { continue }
            if pages > 0 { hasSeenPage = true }
            if hasSeenPage, pages == 0 {
                isClosed = true
                break
            }
        }
        if process.isRunning { process.terminate() }
        let stopBy = ContinuousClock.now + shutdownTimeout
        while process.isRunning, ContinuousClock.now < stopBy {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard isClosed else {
            return ["closed_by": "timeout", "note": "The sign-in window was closed after the wait. Anything the person signed in to is kept; check with a recording, or call sign_in again."]
        }
        return ["closed_by": "person", "note": "The sign-in window was closed. Hidden browser recordings now reuse whatever the person signed in to."]
    }
}
