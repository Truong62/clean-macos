import AppKit

final class DevToolsConnection: NSObject, @unchecked Sendable {
    static let maxMessageSize = 64 * 1024 * 1024

    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var handlers: [String: ([String: Any]) -> Void] = [:]

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = Self.maxMessageSize
        super.init()
        task.resume()
        receive()
    }

    func on(_ method: String, _ handler: @escaping ([String: Any]) -> Void) {
        lock.withLock { handlers[method] = handler }
    }

    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                guard let error else { return }
                self?.resume(id, with: .failure(error))
            }
        }
    }

    func post(_ method: String, _ params: [String: Any] = [:]) {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        let waiting = lock.withLock { () -> [CheckedContinuation<[String: Any], Error>] in
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        waiting.forEach { $0.resume(throwing: MCPToolError.message("The browser connection closed.")) }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            guard case .success(let message) = result else {
                self.close()
                return
            }
            self.handle(message)
            self.receive()
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = object["id"] as? Int {
            if let error = object["error"] as? [String: Any] {
                resume(id, with: .failure(MCPToolError.message("Browser: \(error["message"] as? String ?? "unknown error")")))
            } else {
                resume(id, with: .success(object["result"] as? [String: Any] ?? [:]))
            }
        } else if let method = object["method"] as? String {
            let handler = lock.withLock { handlers[method] }
            handler?(object["params"] as? [String: Any] ?? [:])
        }
    }

    private func resume(_ id: Int, with result: Result<[String: Any], Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }
}

enum HeadlessBrowserFiles {
    static func port(fromActivePortFile text: String) -> Int? {
        text.split(separator: "\n").first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func processID(fromSingletonLock target: String) -> pid_t? {
        target.split(separator: "-").last.flatMap { pid_t($0) }
    }

    static func arguments(of pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        return arguments(fromProcessArgs: Array(bytes.prefix(size)))
    }

    static func arguments(fromProcessArgs bytes: [UInt8]) -> [String] {
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count > countSize else { return [] }
        let count = bytes.prefix(countSize).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var index = countSize
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < count, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}

@MainActor
final class HeadlessBrowser {
    static let bundleIDs = [
        "chrome": "com.google.Chrome", "edge": "com.microsoft.edgemac", "brave": "com.brave.Browser", "chromium": "org.chromium.Chromium",
    ]
    static let startTimeout: Duration = .seconds(15)
    static let loadTimeout: Duration = .seconds(20)

    let connection: DevToolsConnection
    let viewport: CGSize
    let scale: CGFloat
    private let process: Process
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var contentHandler: (() -> Void)?

    private init(process: Process, connection: DevToolsConnection, viewport: CGSize, scale: CGFloat) {
        self.process = process
        self.connection = connection
        self.viewport = viewport
        self.scale = scale
    }

    static func launch(browser: String?, viewport: CGSize, scale: CGFloat, overlayScript: String) async throws -> HeadlessBrowser {
        let executable = try executableURL(for: browser)
        let profile = try profileFolder()
        stopLeftover(in: profile)
        try? FileManager.default.removeItem(at: profile.appendingPathComponent("DevToolsActivePort"))
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--headless=new", "--remote-debugging-port=0", "--user-data-dir=\(profile.path)", "--use-mock-keychain",
            "--password-store=basic", "--no-first-run", "--no-default-browser-check", "--mute-audio",
            "--disable-features=Translate,MediaRouter,OptimizationHints", "--window-size=\(Int(viewport.width)),\(Int(viewport.height))",
            "--force-device-scale-factor=\(scale)", "about:blank",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let port = try await waitForPort(in: profile, process: process)
            let pageURL = try await pageSocketURL(port: port)
            let browser = HeadlessBrowser(process: process, connection: DevToolsConnection(url: pageURL), viewport: viewport, scale: scale)
            try await browser.prepare(overlayScript: overlayScript)
            return browser
        } catch {
            process.terminate()
            throw error
        }
    }

    var processID: pid_t { process.processIdentifier }

    func navigate(to url: String) async throws {
        async let loaded: Void = waitForLoad()
        try await connection.send("Page.navigate", ["url": url])
        await loaded
    }

    func onContentLoaded(_ handler: @escaping () -> Void) {
        contentHandler = handler
    }

    @discardableResult
    func evaluate(_ expression: String) async throws -> Any? {
        let result = try await connection.send("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": true])
        if let details = result["exceptionDetails"] as? [String: Any] {
            let text = (details["exception"] as? [String: Any])?["description"] as? String ?? details["text"] as? String ?? "script error"
            throw MCPToolError.message("Page script failed: \(text)")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    func close() {
        connection.close()
        if process.isRunning { process.terminate() }
    }

    private func prepare(overlayScript: String) async throws {
        connection.on("Page.loadEventFired") { _ in
            Task { @MainActor [weak self] in self?.finishLoad() }
        }
        connection.on("Page.domContentEventFired") { _ in
            Task { @MainActor [weak self] in self?.contentHandler?() }
        }
        try await connection.send("Page.enable")
        try await connection.send("Emulation.setDeviceMetricsOverride", [
            "width": Int(viewport.width), "height": Int(viewport.height), "deviceScaleFactor": scale, "mobile": false,
        ])
        if let agent = try await evaluate("navigator.userAgent") as? String {
            try await connection.send("Network.setUserAgentOverride", ["userAgent": agent.replacingOccurrences(of: "HeadlessChrome", with: "Chrome")])
        }
        try await connection.send("Page.addScriptToEvaluateOnNewDocument", ["source": overlayScript])
    }

    private func waitForLoad() async {
        await withCheckedContinuation { continuation in
            loadWaiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.loadTimeout)
                self?.finishLoad()
            }
        }
    }

    private func finishLoad() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private static func executableURL(for name: String?) throws -> URL {
        let wanted = name.map { [bundleIDs[$0.lowercased()]].compactMap { $0 } } ?? ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium"]
        for bundleID in wanted {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let executable = Bundle(url: app)?.executableURL {
                return executable
            }
        }
        throw MCPToolError.message("Background web recording needs Google Chrome, Microsoft Edge, Brave or Chromium installed.")
    }

    private static func profileFolder() throws -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanMacOS/DemoBrowser", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func stopLeftover(in profile: URL) {
        let lock = profile.appendingPathComponent("SingletonLock").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
              let pid = HeadlessBrowserFiles.processID(fromSingletonLock: target), pid > 0 else { return }
        let arguments = HeadlessBrowserFiles.arguments(of: pid)
        guard arguments.contains("--headless=new"), arguments.contains("--user-data-dir=\(profile.path)") else { return }
        kill(pid, SIGTERM)
    }

    private static func waitForPort(in profile: URL, process: Process) async throws -> Int {
        let file = profile.appendingPathComponent("DevToolsActivePort")
        let deadline = ContinuousClock.now + startTimeout
        while ContinuousClock.now < deadline {
            guard process.isRunning else { throw MCPToolError.message("The hidden browser quit while starting.") }
            if let text = try? String(contentsOf: file, encoding: .utf8), let port = HeadlessBrowserFiles.port(fromActivePortFile: text) {
                return port
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MCPToolError.message("The hidden browser did not start in time.")
    }

    private static func pageSocketURL(port: Int) async throws -> URL {
        let deadline = ContinuousClock.now + startTimeout
        while ContinuousClock.now < deadline {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/list")!)
            let targets = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            if let page = targets.first(where: { $0["type"] as? String == "page" }),
               let socket = page["webSocketDebuggerUrl"] as? String, let url = URL(string: socket) {
                return url
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MCPToolError.message("The hidden browser has no page.")
    }
}
