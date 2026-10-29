import AVFoundation
import AppKit
import ScreenCaptureKit

enum AgentRecordingSignal {
    static let name = Notification.Name("click.ngoctruong.CleanMacOS.agentRecording")
    static let started = "started"
    static let stopped = "stopped"

    static func post(_ state: String) {
        DistributedNotificationCenter.default().postNotificationName(name, object: state, deliverImmediately: true)
    }
}

@MainActor
final class AgentRecordingIndicator: ObservableObject {
    @Published private(set) var isRecording = false
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(forName: AgentRecordingSignal.name, object: nil,
                                                                       queue: .main) { [weak self] note in
            let state = note.object as? String
            MainActor.assumeIsolated { self?.isRecording = state == AgentRecordingSignal.started }
        }
    }
}

struct StartRecordingArguments: Decodable {
    var windowID: Int?
    var window: String?
    var app: String?
    var displayID: Int?
    var fps: Int?
    var resolution: String?
    var systemAudio: Bool?
    var microphone: Bool?
    var maxSeconds: Int?
    var folder: String?
    var showClicks: Bool?
    var skipIdle: Bool?
    var background: Bool?
    var url: String?
    var browser: String?
    var name: String?
    var fresh: Bool?

    enum CodingKeys: String, CodingKey {
        case windowID = "window_id", window, app, displayID = "display_id", fps, resolution
        case systemAudio = "system_audio", microphone, maxSeconds = "max_seconds", folder, showClicks = "show_clicks"
        case skipIdle = "skip_idle", background, url, browser, name, fresh
    }
}

struct SourceWindow: Equatable {
    let id: Int
    let app: String
    let bundleID: String
    let title: String
    var area: Double = 0
}

enum RecordingSources {
    static func bestWindow(matching query: String, in windows: [SourceWindow]) -> SourceWindow? {
        let needle = query.lowercased()
        let tiers: [(SourceWindow) -> Bool] = [
            { $0.title.lowercased() == needle },
            { $0.title.lowercased().contains(needle) },
            { $0.app.lowercased() == needle || $0.bundleID.lowercased() == needle },
            { $0.app.lowercased().contains(needle) },
        ]
        return tiers.lazy.compactMap { tier in windows.filter(tier).max { $0.area < $1.area } }.first
    }

    static func matchesApp(_ query: String, name: String, bundleID: String) -> Bool {
        let needle = query.lowercased()
        return name.lowercased() == needle || bundleID.lowercased() == needle || name.lowercased().contains(needle)
    }

    static func region(of window: CGRect, on display: CGRect) -> CGRect {
        window.intersection(display).offsetBy(dx: -display.minX, dy: -display.minY)
    }
}

enum ZoomMath {
    static let maxZoom: CGFloat = 4
    static let minZoom: CGFloat = 1.25
    static let minPadding: CGFloat = 40

    static func rect(focus: CGRect, base: CGRect, aspect: CGFloat, scale: CGFloat?) -> CGRect {
        var size: CGSize
        if let scale, scale > 1 {
            let width = base.width / min(scale, maxZoom)
            size = CGSize(width: width, height: width / aspect)
        } else {
            let padded = focus.insetBy(dx: -max(focus.width * 0.15, minPadding), dy: -max(focus.height * 0.15, minPadding))
            size = padded.width / padded.height > aspect ? CGSize(width: padded.width, height: padded.width / aspect)
                : CGSize(width: padded.height * aspect, height: padded.height)
            let minWidth = base.width / maxZoom
            if size.width < minWidth { size = CGSize(width: minWidth, height: minWidth / aspect) }
        }
        if focus.width >= base.width * 0.9, focus.height >= base.height * 0.9, scale == nil { return base }
        if size.width > base.width / minZoom {
            size = CGSize(width: base.width / minZoom, height: base.width / minZoom / aspect)
        }
        guard size.width < base.width, size.height < base.height else { return base }
        let origin = CGPoint(x: min(max(focus.midX - size.width / 2, base.minX), base.maxX - size.width),
                             y: min(max(focus.midY - size.height / 2, base.minY), base.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }

    static func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        let t = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
        return CGRect(x: start.minX + (end.minX - start.minX) * t, y: start.minY + (end.minY - start.minY) * t,
                      width: start.width + (end.width - start.width) * t, height: start.height + (end.height - start.height) * t)
    }
}

enum MCPToolError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

struct RecordingTarget {
    let filter: SCContentFilter
    let sourceRect: CGRect?
    let display: CGRect
    let description: String
    let processID: pid_t?
}

@MainActor
final class AgentRecordingSession {
    static let defaultMaxSeconds = 600
    static let maxSecondsLimit = 3600

    let recorder: ScreenRecorder = {
        let recorder = ScreenRecorder()
        recorder.showsPreview = false
        return recorder
    }()
    let overlay = DemoOverlay()
    private let defaults: UserDefaults
    private var isActive = false
    private var autoStop: Task<Void, Never>?
    private var skipsIdle = true
    private var outputFolder = ScreenRecording.moviesFolder()
    private var lastResult: Result<URL, Error>?
    private var outputName: String?
    var lastSavedRecording: URL?
    var recordingDisplay: CGRect?
    var targetProcessID: pid_t?
    var isBackground = false
    var web: WebDemo?
    var annotationCount = 0
    var stepCount = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isRecording: Bool { isActive && (web != nil || recorder.isRecording) }

    func listSources() async throws -> [String: Any] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return [
            "displays": content.displays.map { display in
                ["id": Int(display.displayID), "x": Int(display.frame.minX), "y": Int(display.frame.minY),
                 "width": display.width, "height": display.height, "main": display.displayID == CGMainDisplayID()]
            },
            "windows": Self.recordableWindows(content).map { window in
                ["id": Int(window.windowID), "app": window.owningApplication?.applicationName ?? "",
                 "bundle_id": window.owningApplication?.bundleIdentifier ?? "", "title": window.title ?? "",
                 "x": Int(window.frame.minX), "y": Int(window.frame.minY),
                 "width": Int(window.frame.width), "height": Int(window.frame.height)]
            },
        ]
    }

    func start(_ arguments: StartRecordingArguments) async throws -> [String: Any] {
        guard ScreenRecorder.isSupported else { throw MCPToolError.message("Screen recording needs macOS 15 or later.") }
        guard !isActive else { throw MCPToolError.message("A recording is already running. Call stop_recording first.") }
        let options = try options(from: arguments)
        isBackground = arguments.background ?? true
        skipsIdle = arguments.skipIdle ?? true
        outputFolder = options.folder
        outputName = arguments.name
        lastResult = nil
        annotationCount = 0
        stepCount = 0
        var result: [String: Any]
        if let url = arguments.url {
            guard isBackground else { throw MCPToolError.message("url opens a hidden browser, so it needs background: true (the default).") }
            result = try await startWeb(url, browserName: arguments.browser, fresh: arguments.fresh ?? false, options: options)
            if skipsIdle { web?.writer.pause() }
        } else {
            result = try await startScreen(arguments, options: options)
        }
        isActive = true
        AgentRecordingSignal.post(AgentRecordingSignal.started)
        let maxSeconds = min(max(arguments.maxSeconds ?? Self.defaultMaxSeconds, 1), Self.maxSecondsLimit)
        autoStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxSeconds))
            guard !Task.isCancelled else { return }
            await self?.finishCapture()
        }
        result.merge(["recording": true, "skip_idle": skipsIdle, "background": isBackground, "fps": options.framesPerSecond,
                      "resolution": options.resolution.title.lowercased(), "max_seconds": maxSeconds]) { first, _ in first }
        return result
    }

    func stop(discard: Bool = false) async throws -> [String: Any] {
        guard isActive else { throw MCPToolError.message("No recording is running. Call start_recording first.") }
        isActive = false
        autoStop?.cancel()
        await finishCapture()
        let result = lastResult
        lastResult = nil
        if discard {
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            return ["discarded": true]
        }
        guard let result else { throw MCPToolError.message("The recording could not be saved.") }
        let url = try result.get()
        lastSavedRecording = url
        return try await Self.describe(url)
    }

    func beginAction() {
        guard isRecording else { return }
        if let web {
            if skipsIdle { web.writer.resume() }
            return
        }
        if !isBackground, let pid = targetProcessID, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        if skipsIdle { recorder.resumeCapture() }
    }

    func endAction() {
        guard isRecording, skipsIdle else { return }
        if let web {
            web.writer.pause()
        } else {
            recorder.pauseCapture()
        }
    }

    func shutdown() async {
        autoStop?.cancel()
        await finishCapture()
        overlay.hide()
    }

    private func startScreen(_ arguments: StartRecordingArguments, options: RecordingOptions) async throws -> [String: Any] {
        let target: RecordingTarget
        do {
            if isBackground {
                target = try await inPlaceTarget(arguments)
                let area = target.sourceRect.map { $0.offsetBy(dx: target.display.minX, dy: target.display.minY) } ?? target.display
                overlay.model.moveCursor(to: CGPoint(x: area.midX, y: area.midY), duration: 0)
            } else {
                overlay.show(showsClicks: arguments.showClicks ?? true)
                target = try await resolveTarget(arguments)
            }
        } catch {
            overlay.hide()
            throw error
        }
        recorder.message = nil
        await recorder.startPreview(target.filter, options: options, sourceRect: target.sourceRect, showsCursor: !isBackground)
        guard recorder.phase == .previewing else {
            overlay.hide()
            throw MCPToolError.message(recorder.message ?? "Recording could not start.")
        }
        recorder.startRecording()
        if skipsIdle { recorder.pauseCapture() }
        recordingDisplay = target.display
        targetProcessID = target.processID
        return ["target": target.description, "folder": options.folder.path,
                "recorded_area": ["x": Int(target.display.minX + (target.sourceRect?.minX ?? 0)),
                                  "y": Int(target.display.minY + (target.sourceRect?.minY ?? 0)),
                                  "width": Int(target.sourceRect?.width ?? target.display.width),
                                  "height": Int(target.sourceRect?.height ?? target.display.height)]]
    }

    private func finishCapture() async {
        if web != nil {
            lastResult = await finishWeb(into: outputFolder)
        } else if recorder.isRecording {
            overlay.hide()
            await recorder.stop()
            if let message = recorder.message {
                lastResult = .failure(MCPToolError.message(message))
            } else if let url = recorder.lastRecording {
                lastResult = .success(url)
            }
        } else {
            return
        }
        if case .success(let url) = lastResult, let name = outputName {
            lastResult = Result { try Self.rename(url, to: name) }
        }
        recordingDisplay = nil
        AgentRecordingSignal.post(AgentRecordingSignal.stopped)
    }

    static func rename(_ url: URL, to name: String) throws -> URL {
        guard let file = ScreenRecording.customFileName(name) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = (file as NSString).deletingPathExtension
        var destination = folder.appendingPathComponent(file)
        var copy = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) \(copy).mp4")
            copy += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    private func options(from arguments: StartRecordingArguments) throws -> RecordingOptions {
        let resolutionName = arguments.resolution ?? defaults.string(forKey: ScreenRecording.resolutionKey) ?? "full"
        let aliases = ["1080p": ScreenRecording.Resolution.hd1080, "720p": .hd720]
        guard let resolution = aliases[resolutionName] ?? ScreenRecording.Resolution(rawValue: resolutionName) else {
            throw MCPToolError.message("resolution must be full, 1080p or 720p.")
        }
        let savedFPS = defaults.integer(forKey: ScreenRecording.framesPerSecondKey)
        let fps = arguments.fps ?? (savedFPS > 0 ? savedFPS : 30)
        guard (1...120).contains(fps) else { throw MCPToolError.message("fps must be between 1 and 120.") }
        let folderPath = arguments.folder ?? defaults.string(forKey: ScreenRecording.folderKey) ?? ""
        return RecordingOptions(systemAudio: arguments.systemAudio ?? false, microphone: arguments.microphone ?? false,
                                framesPerSecond: fps, resolution: resolution,
                                folder: ScreenRecording.folder(atPath: (folderPath as NSString).expandingTildeInPath))
    }

    private func resolveTarget(_ arguments: StartRecordingArguments) async throws -> RecordingTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = Self.recordableWindows(content)
        if let id = arguments.windowID {
            guard let window = windows.first(where: { Int($0.windowID) == id }) else {
                throw MCPToolError.message("No on-screen window has id \(id). Call list_sources.")
            }
            return try await windowTarget(window)
        }
        if let query = arguments.window {
            guard let match = RecordingSources.bestWindow(matching: query, in: windows.map(Self.source)),
                  let window = windows.first(where: { Int($0.windowID) == match.id }) else {
                throw MCPToolError.message("No on-screen window matches \"\(query)\". Call list_sources.")
            }
            return try await windowTarget(window)
        }
        if let query = arguments.app {
            guard let app = content.applications.first(where: {
                RecordingSources.matchesApp(query, name: $0.applicationName, bundleID: $0.bundleIdentifier)
            }) else { throw MCPToolError.message("No running app matches \"\(query)\". Call list_sources.") }
            NSRunningApplication(processIdentifier: app.processID)?.activate()
            let appWindow = windows.first { $0.owningApplication?.processID == app.processID }
            let display = content.displays.first { display in appWindow.map { display.frame.intersects($0.frame) } ?? false }
                ?? Self.mainDisplay(content)
            guard let display else { throw MCPToolError.message("No display found.") }
            let overlayApp = content.applications.first { $0.processID == getpid() }
            return RecordingTarget(filter: SCContentFilter(display: display, including: [app] + [overlayApp].compactMap { $0 }, exceptingWindows: []),
                                   sourceRect: nil, display: display.frame, description: "app \(app.applicationName)",
                                   processID: app.processID)
        }
        let display = arguments.displayID.map { id in content.displays.first { Int($0.displayID) == id } } ?? Self.mainDisplay(content)
        guard let display else { throw MCPToolError.message("No display matches. Call list_sources.") }
        return RecordingTarget(filter: SCContentFilter(display: display, excludingWindows: []), sourceRect: nil,
                               display: display.frame, description: "display \(display.displayID)", processID: nil)
    }

    private func windowTarget(_ window: SCWindow) async throws -> RecordingTarget {
        let front = try await Self.bringToFront(window)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.max(by: {
            $0.frame.intersection(front.frame).width * $0.frame.intersection(front.frame).height
                < $1.frame.intersection(front.frame).width * $1.frame.intersection(front.frame).height
        }) else { throw MCPToolError.message("No display found.") }
        return RecordingTarget(filter: SCContentFilter(display: display, excludingWindows: []),
                               sourceRect: RecordingSources.region(of: front.frame, on: display.frame), display: display.frame,
                               description: Self.describe(front), processID: front.owningApplication?.processID)
    }

    private static func bringToFront(_ window: SCWindow) async throws -> SCWindow {
        guard let pid = window.owningApplication?.processID, let app = NSRunningApplication(processIdentifier: pid),
              !app.isActive else { return window }
        app.activate()
        try await Task.sleep(for: .milliseconds(600))
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.first { $0.windowID == window.windowID } ?? window
    }

    static func mainDisplay(_ content: SCShareableContent) -> SCDisplay? {
        content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
    }

    static func recordableWindows(_ content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { window in
            guard let app = window.owningApplication, app.bundleIdentifier != "com.apple.WindowManager",
                  app.processID != getpid() else { return false }
            return window.windowLayer == 0 && window.frame.width > 50 && window.frame.height > 50
        }
    }

    private static func source(_ window: SCWindow) -> SourceWindow {
        SourceWindow(id: Int(window.windowID), app: window.owningApplication?.applicationName ?? "",
                     bundleID: window.owningApplication?.bundleIdentifier ?? "", title: window.title ?? "",
                     area: window.frame.width * window.frame.height)
    }

    private static func describe(_ window: SCWindow) -> String {
        "window \"\(window.title ?? "")\" of \(window.owningApplication?.applicationName ?? "unknown app")"
    }

    private static func describe(_ url: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ["path": url.path, "duration_seconds": NSDecimalNumber(string: String(format: "%.1f", duration)),
                "width": Int(size.width), "height": Int(size.height), "size_bytes": bytes]
    }
}

enum ToolOutput {
    case json([String: Any])
    case image(Data, mimeType: String, [String: Any])
}

@MainActor
final class RecordingMCPServer {
    static let flag = "--mcp"
    static let defaultProtocolVersion = "2025-06-18"

    private let session: AgentRecordingSession

    init(session: AgentRecordingSession) {
        self.session = session
    }

    static let stopSignals = [SIGTERM, SIGINT, SIGHUP]
    private static var signalSources: [DispatchSourceSignal] = []

    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        let session = AgentRecordingSession()
        signalSources = stopSignals.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    await session.shutdown()
                    exit(0)
                }
            }
            source.resume()
            return source
        }
        Task { @MainActor in
            let server = RecordingMCPServer(session: session)
            await server.serve()
            exit(0)
        }
        NSApp.run()
        exit(0)
    }

    func serve() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let reply = await reply(to: line) else { continue }
                FileHandle.standardOutput.write(reply + Data("\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("MCP input failed: \(error)\n".utf8))
        }
        await session.shutdown()
    }

    func reply(to line: String) async -> Data? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result = try await handle(method, params: params)
            return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch {
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": error.localizedDescription]])
        }
    }

    private func handle(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "initialize":
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            return ["protocolVersion": params["protocolVersion"] as? String ?? Self.defaultProtocolVersion,
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "clean-macos-screen-record", "version": version],
                    "instructions": RecordingMCPTools.instructions]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": RecordingMCPTools.all]
        case "tools/call":
            return await callTool(params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            throw MCPToolError.message("Method not found: \(method)")
        }
    }

    private func callTool(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            let data = try JSONSerialization.data(withJSONObject: arguments)
            switch try await run(name, data: data) {
            case .json(let result):
                return ["content": [["type": "text", "text": try Self.text(result)]]]
            case .image(let image, let mimeType, let details):
                return ["content": [["type": "image", "data": image.base64EncodedString(), "mimeType": mimeType],
                                    ["type": "text", "text": try Self.text(details)]]]
            }
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    private func run(_ name: String, data: Data) async throws -> ToolOutput {
        let demo = { try JSONDecoder().decode(DemoArguments.self, from: data) }
        let isOnCamera = RecordingMCPTools.onCamera.contains(name)
        if isOnCamera { session.beginAction() }
        defer { if isOnCamera { session.endAction() } }
        switch name {
        case "list_sources": return .json(try await session.listSources())
        case "start_recording": return .json(try await session.start(JSONDecoder().decode(StartRecordingArguments.self, from: data)))
        case "stop_recording": return .json(try await session.stop(discard: (try? demo())?.discard ?? false))
        case "annotate": return .json(try await session.annotate(demo()))
        case "caption": return .json(try await session.caption(demo()))
        case "clear_annotations": return .json(try await session.clearAnnotations(demo()))
        case "find_element": return .json(try await session.findElement(demo()))
        case "click": return .json(try await session.click(demo()))
        case "type_text": return .json(try await session.typeText(demo()))
        case "press_key": return .json(try await session.pressKey(demo()))
        case "scroll": return .json(try await session.scroll(demo()))
        case "zoom_in": return .json(try await session.zoomIn(demo()))
        case "zoom_out": return .json(try await session.zoomOut(demo()))
        case "wait": return .json(try await session.wait(demo()))
        case "navigate": return .json(try await session.navigate(demo()))
        case "screenshot": return try await session.screenshot(demo())
        case "review_recording": return try await session.reviewRecording(demo())
        case "sign_in": return .json(try await session.signIn(demo()))
        default: throw MCPToolError.message("Unknown tool: \(name)")
        }
    }

    private static func text(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               as: UTF8.self)
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
