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

    enum CodingKeys: String, CodingKey {
        case windowID = "window_id", window, app, displayID = "display_id", fps, resolution
        case systemAudio = "system_audio", microphone, maxSeconds = "max_seconds", folder
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
}

enum MCPToolError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

@MainActor
final class AgentRecordingSession {
    static let defaultMaxSeconds = 600
    static let maxSecondsLimit = 3600

    private let recorder = ScreenRecorder()
    private let defaults: UserDefaults
    private var isActive = false
    private var autoStop: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func listSources() async throws -> [String: Any] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return [
            "displays": content.displays.map { ["id": Int($0.displayID), "width": $0.width, "height": $0.height] },
            "windows": Self.recordableWindows(content).map { window in
                ["id": Int(window.windowID), "app": window.owningApplication?.applicationName ?? "",
                 "bundle_id": window.owningApplication?.bundleIdentifier ?? "", "title": window.title ?? "",
                 "width": Int(window.frame.width), "height": Int(window.frame.height)]
            },
        ]
    }

    func start(_ arguments: StartRecordingArguments) async throws -> [String: Any] {
        guard ScreenRecorder.isSupported else { throw MCPToolError.message("Screen recording needs macOS 15 or later.") }
        guard !isActive else { throw MCPToolError.message("A recording is already running. Call stop_recording first.") }
        let (filter, target) = try await resolveFilter(arguments)
        let options = try options(from: arguments)
        recorder.message = nil
        await recorder.startPreview(filter, options: options)
        guard recorder.phase == .previewing else {
            throw MCPToolError.message(recorder.message ?? "Recording could not start.")
        }
        recorder.startRecording()
        isActive = true
        AgentRecordingSignal.post(AgentRecordingSignal.started)
        let maxSeconds = min(max(arguments.maxSeconds ?? Self.defaultMaxSeconds, 1), Self.maxSecondsLimit)
        autoStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxSeconds))
            guard !Task.isCancelled else { return }
            await self?.finishCapture()
        }
        return ["recording": true, "target": target, "fps": options.framesPerSecond, "resolution": options.resolution.title.lowercased(),
                "max_seconds": maxSeconds, "folder": options.folder.path]
    }

    func stop() async throws -> [String: Any] {
        guard isActive else { throw MCPToolError.message("No recording is running. Call start_recording first.") }
        isActive = false
        autoStop?.cancel()
        await finishCapture()
        if let message = recorder.message { throw MCPToolError.message(message) }
        guard let url = recorder.lastRecording else { throw MCPToolError.message("The recording could not be saved.") }
        return try await Self.describe(url)
    }

    func shutdown() async {
        autoStop?.cancel()
        await finishCapture()
    }

    private func finishCapture() async {
        guard recorder.isRecording else { return }
        await recorder.stop()
        AgentRecordingSignal.post(AgentRecordingSignal.stopped)
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

    private func resolveFilter(_ arguments: StartRecordingArguments) async throws -> (SCContentFilter, String) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = Self.recordableWindows(content)
        if let id = arguments.windowID {
            guard let window = windows.first(where: { Int($0.windowID) == id }) else {
                throw MCPToolError.message("No on-screen window has id \(id). Call list_sources.")
            }
            let front = try await Self.bringToFront(window)
            return (SCContentFilter(desktopIndependentWindow: front), Self.describe(front))
        }
        if let query = arguments.window {
            let sources = windows.map(Self.source)
            guard let match = RecordingSources.bestWindow(matching: query, in: sources),
                  let window = windows.first(where: { Int($0.windowID) == match.id }) else {
                throw MCPToolError.message("No on-screen window matches \"\(query)\". Call list_sources.")
            }
            let front = try await Self.bringToFront(window)
            return (SCContentFilter(desktopIndependentWindow: front), Self.describe(front))
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
            return (SCContentFilter(display: display, including: [app], exceptingWindows: []), "app \(app.applicationName)")
        }
        let display = arguments.displayID.map { id in content.displays.first { Int($0.displayID) == id } } ?? Self.mainDisplay(content)
        guard let display else { throw MCPToolError.message("No display matches. Call list_sources.") }
        return (SCContentFilter(display: display, excludingWindows: []), "display \(display.displayID)")
    }

    private static func bringToFront(_ window: SCWindow) async throws -> SCWindow {
        guard let pid = window.owningApplication?.processID, let app = NSRunningApplication(processIdentifier: pid),
              !app.isActive else { return window }
        app.activate()
        try await Task.sleep(for: .milliseconds(600))
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.first { $0.windowID == window.windowID } ?? window
    }

    private static func mainDisplay(_ content: SCShareableContent) -> SCDisplay? {
        content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
    }

    private static func recordableWindows(_ content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { window in
            guard let app = window.owningApplication, app.bundleIdentifier != "com.apple.WindowManager" else { return false }
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
        return ["path": url.path, "duration_seconds": NSDecimalNumber(string: String(format: "%.1f", duration)), "width": Int(size.width),
                "height": Int(size.height), "size_bytes": bytes]
    }
}

@MainActor
final class RecordingMCPServer {
    static let flag = "--mcp"
    static let defaultProtocolVersion = "2025-06-18"

    private let session: AgentRecordingSession

    init(session: AgentRecordingSession) {
        self.session = session
    }

    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let server = RecordingMCPServer(session: AgentRecordingSession())
            await server.serve()
            exit(0)
        }
        dispatchMain()
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
                    "instructions": "Record real MP4 screen videos. Call list_sources, start_recording, do the demo, then stop_recording."]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            return await callTool(params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            throw MCPToolError.message("Method not found: \(method)")
        }
    }

    private func callTool(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            let result: [String: Any]
            switch name {
            case "list_sources":
                result = try await session.listSources()
            case "start_recording":
                let data = try JSONSerialization.data(withJSONObject: arguments)
                result = try await session.start(JSONDecoder().decode(StartRecordingArguments.self, from: data))
            case "stop_recording":
                result = try await session.stop()
            default:
                throw MCPToolError.message("Unknown tool: \(name)")
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                              as: UTF8.self)
            return ["content": [["type": "text", "text": text]]]
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static let tools: [[String: Any]] = [
        [
            "name": "list_sources",
            "description": "List the displays and on-screen windows that can be recorded.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "start_recording",
            "description": "Start recording a real MP4 video of a window, an app or a display. Pick at most one of window_id, window, app or display_id; with none, the main display is recorded. A window or app target is brought to the front first. Defaults come from the Clean macOS Screen Record settings. Then perform the demo and call stop_recording.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "window_id": ["type": "integer", "description": "Window id from list_sources."],
                    "window": ["type": "string", "description": "Window title or app name to match, for example \"Google Chrome\"."],
                    "app": ["type": "string", "description": "App name or bundle id; records every window of that app."],
                    "display_id": ["type": "integer", "description": "Display id from list_sources."],
                    "fps": ["type": "integer", "enum": [24, 30, 60]],
                    "resolution": ["type": "string", "enum": ["full", "1080p", "720p"]],
                    "system_audio": ["type": "boolean", "description": "Record sound from apps. Default false."],
                    "microphone": ["type": "boolean", "description": "Record the microphone. Default false."],
                    "max_seconds": ["type": "integer", "description": "Stop automatically after this many seconds. Default 600, max 3600."],
                    "folder": ["type": "string", "description": "Folder to save into. Default is the folder set in the app, else Movies."],
                ],
            ],
        ],
        [
            "name": "stop_recording",
            "description": "Stop the recording and return the MP4 path, duration, size and dimensions.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
    ]
}
