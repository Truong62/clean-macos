import AppKit
import ScreenCaptureKit

struct DemoArguments: Decodable {
    var kind: String?
    var element: String?
    var app: String?
    var role: String?
    var index: Int?
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    var text: String?
    var color: String?
    var number: Int?
    var id: String?
    var seconds: Double?
    var holdSeconds: Double?
    var keys: String?
    var dx: Double?
    var dy: Double?
    var count: Int?
    var scale: Double?
    var displayID: Int?
    var interval: Double?
    var keepAnnotations: Bool?
    var position: String?

    enum CodingKeys: String, CodingKey {
        case kind, element, app, role, index, x, y, width, height, text, color, number, id, seconds
        case holdSeconds = "hold_seconds", keys, dx, dy, count, scale, displayID = "display_id", interval, keepAnnotations = "keep_annotations", position
    }
}

extension AgentRecordingSession {
    static let zoomSteps = 24
    static let zoomDuration = 0.7
    static let screenshotMaxWidth: CGFloat = 1600
    static let maxWaitSeconds = 60.0

    func annotate(_ arguments: DemoArguments) async throws -> [String: Any] {
        guard let kindName = arguments.kind, let kind = Annotation.Kind(rawValue: kindName) else {
            throw MCPToolError.message("kind must be one of \(Annotation.Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let color = DemoColor.parse(arguments.color) else { throw MCPToolError.message("color must be a name like red or a hex like #FF3B30.") }
        let rect: CGRect
        if kind == .title {
            rect = try targetRect(arguments) ?? recordedArea
        } else {
            guard let target = try targetRect(arguments) else {
                throw MCPToolError.message("Give an element (with app) or x and y, plus width and height for an area.")
            }
            rect = target
        }
        annotationCount += 1
        let id = arguments.id ?? "a\(annotationCount)"
        let number = kind == .step ? (arguments.number ?? stepCount + 1) : arguments.number
        if kind == .step, let number { stepCount = number }
        overlay.show(showsClicks: false)
        overlay.model.add(Annotation(id: id, kind: kind, rect: rect, text: arguments.text, number: number, color: color))
        if let seconds = arguments.seconds, seconds > 0 {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.overlay.model.remove(id: id)
            }
        }
        try await hold(arguments, default: 1.2)
        return ["id": id, "kind": kind.rawValue, "rect": Self.json(rect)]
    }

    func caption(_ arguments: DemoArguments) async throws -> [String: Any] {
        let text = arguments.text.flatMap { $0.isEmpty ? nil : $0 }
        overlay.show(showsClicks: false)
        overlay.model.setCaption(text, in: recordedArea, scale: zoomFactor, atTop: arguments.position == "top")
        try await hold(arguments, default: 1.0)
        return ["caption": text ?? NSNull()]
    }

    func clearAnnotations(_ arguments: DemoArguments) async throws -> [String: Any] {
        if let id = arguments.id {
            overlay.model.remove(id: id)
        } else {
            overlay.model.clearAnnotations()
            stepCount = 0
        }
        try await hold(arguments, default: 0.3)
        return ["cleared": arguments.id ?? "all"]
    }

    func findElement(_ arguments: DemoArguments) throws -> [String: Any] {
        guard let query = arguments.element else { throw MCPToolError.message("element is required.") }
        let app = try resolveApp(arguments.app)
        let found = try elements(query, in: app, role: arguments.role)
        return ["app": app.localizedName ?? "", "matches": found.prefix(10).enumerated().map { index, element in
            ["index": index, "role": element.role, "label": element.label, "rect": Self.json(element.frame)]
        }]
    }

    func click(_ arguments: DemoArguments) async throws -> [String: Any] {
        try DemoInput.ensureTrusted()
        guard let rect = try targetRect(arguments) else { throw MCPToolError.message("Give an element (with app) or x and y.") }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        overlay.show(showsClicks: false)
        await DemoInput.glide(to: point, duration: 0.45)
        overlay.toolClicked(at: point)
        await DemoInput.click(at: point, count: arguments.count ?? 1)
        if arguments.keepAnnotations != true { overlay.model.clearAnnotations() }
        try await hold(arguments, default: 0.6)
        return ["clicked": ["x": Int(point.x), "y": Int(point.y)]]
    }

    func typeText(_ arguments: DemoArguments) async throws -> [String: Any] {
        try DemoInput.ensureTrusted()
        guard let text = arguments.text, !text.isEmpty else { throw MCPToolError.message("text is required.") }
        await DemoInput.type(text, interval: min(max(arguments.interval ?? 0.04, 0), 0.5))
        try await hold(arguments, default: 0.4)
        return ["typed": text.count]
    }

    func pressKey(_ arguments: DemoArguments) async throws -> [String: Any] {
        try DemoInput.ensureTrusted()
        guard let keys = arguments.keys, let combo = KeyCombo.parse(keys) else {
            throw MCPToolError.message("keys must look like return, esc, tab, cmd+k or cmd+shift+n.")
        }
        DemoInput.press(combo)
        try await hold(arguments, default: 0.4)
        return ["pressed": keys]
    }

    func scroll(_ arguments: DemoArguments) async throws -> [String: Any] {
        try DemoInput.ensureTrusted()
        if let rect = try targetRect(arguments) {
            await DemoInput.glide(to: CGPoint(x: rect.midX, y: rect.midY), duration: 0.35)
        }
        await DemoInput.scroll(by: CGVector(dx: arguments.dx ?? 0, dy: arguments.dy ?? 400), steps: 24)
        try await hold(arguments, default: 0.5)
        return ["scrolled": ["dx": arguments.dx ?? 0, "dy": arguments.dy ?? 400]]
    }

    func zoomIn(_ arguments: DemoArguments) async throws -> [String: Any] {
        guard isRecording, let display = recordingDisplay else { throw MCPToolError.message("Zoom works while recording. Call start_recording first.") }
        guard let rect = try targetRect(arguments) else { throw MCPToolError.message("Give an element (with app) or x, y, width and height to zoom into.") }
        let size = recorder.outputSize
        let focus = rect.offsetBy(dx: -display.minX, dy: -display.minY)
        let target = ZoomMath.rect(focus: focus, base: recorder.baseSourceRect, aspect: size.width / max(size.height, 1),
                                   scale: arguments.scale.map { CGFloat($0) })
        try await animateZoom(to: target, duration: arguments.seconds ?? Self.zoomDuration)
        try await hold(arguments, default: 0.4)
        return ["zoomed_to": Self.json(target.offsetBy(dx: display.minX, dy: display.minY))]
    }

    func zoomOut(_ arguments: DemoArguments) async throws -> [String: Any] {
        guard isRecording else { throw MCPToolError.message("Zoom works while recording. Call start_recording first.") }
        try await animateZoom(to: recorder.baseSourceRect, duration: arguments.seconds ?? Self.zoomDuration)
        try await hold(arguments, default: 0.4)
        return ["zoomed_out": true]
    }

    func wait(_ arguments: DemoArguments) async throws -> [String: Any] {
        let seconds = min(max(arguments.seconds ?? 1, 0), Self.maxWaitSeconds)
        try await Task.sleep(for: .seconds(seconds))
        return ["waited": seconds]
    }

    func screenshot(_ arguments: DemoArguments) async throws -> ToolOutput {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let display = arguments.displayID.flatMap { id in content.displays.first { Int($0.displayID) == id } }
            ?? recordingDisplay.flatMap { frame in content.displays.first { $0.frame == frame } }
            ?? Self.mainDisplay(content)
        guard let display else { throw MCPToolError.message("No display found.") }
        let scale = min(1, Self.screenshotMaxWidth / display.frame.width)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.frame.width * scale)
        configuration.height = Int(display.frame.height * scale)
        configuration.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                               configuration: configuration)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw MCPToolError.message("The screenshot could not be encoded.")
        }
        return .image(jpeg, mimeType: "image/jpeg", [
            "display_id": Int(display.displayID), "image_width": image.width, "image_height": image.height,
            "screen_rect": Self.json(display.frame),
            "to_screen_points": "x = \(Int(display.frame.minX)) + pixel_x * \(String(format: "%.4f", 1 / scale)), y = \(Int(display.frame.minY)) + pixel_y * \(String(format: "%.4f", 1 / scale))",
        ])
    }

    var recordedArea: CGRect {
        guard let display = recordingDisplay else { return CGDisplayBounds(CGMainDisplayID()) }
        return recorder.currentSourceRect.offsetBy(dx: display.minX, dy: display.minY)
    }

    var zoomFactor: CGFloat {
        guard recordingDisplay != nil, recorder.baseSourceRect.width > 0 else { return 1 }
        return recorder.currentSourceRect.width / recorder.baseSourceRect.width
    }

    private func animateZoom(to target: CGRect, duration: Double) async throws {
        let start = recorder.currentSourceRect
        for step in 1...Self.zoomSteps {
            let frame = ZoomMath.interpolate(from: start, to: target, progress: CGFloat(step) / CGFloat(Self.zoomSteps))
            try await recorder.setSourceRect(frame)
            overlay.model.moveCaption(to: recordedArea, scale: zoomFactor)
            try await Task.sleep(for: .seconds(max(duration, 0) / Double(Self.zoomSteps)))
        }
    }

    private func hold(_ arguments: DemoArguments, default seconds: Double) async throws {
        let value = min(max(arguments.holdSeconds ?? seconds, 0), Self.maxWaitSeconds)
        guard value > 0 else { return }
        try await Task.sleep(for: .seconds(value))
    }

    private func targetRect(_ arguments: DemoArguments) throws -> CGRect? {
        if let query = arguments.element {
            let app = try resolveApp(arguments.app)
            let found = try elements(query, in: app, role: arguments.role)
            let index = arguments.index ?? 0
            guard found.indices.contains(index) else {
                throw MCPToolError.message("Only \(found.count) element(s) labelled \"\(query)\" in \(app.localizedName ?? "the app"). Use find_element to see them.")
            }
            return found[index].frame
        }
        guard let x = arguments.x, let y = arguments.y else { return nil }
        return CGRect(x: x, y: y, width: arguments.width ?? 0, height: arguments.height ?? 0)
    }

    private func elements(_ query: String, in app: NSRunningApplication, role: String?) throws -> [FoundElement] {
        try DemoInput.ensureTrusted()
        let found = AccessibilityFinder.find(query, pid: app.processIdentifier, role: role)
        guard !found.isEmpty else {
            throw MCPToolError.message("No element labelled \"\(query)\" in \(app.localizedName ?? "the app"). Try another label, or take a screenshot and use x and y.")
        }
        return found
    }

    private func resolveApp(_ name: String?) throws -> NSRunningApplication {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let name {
            guard let app = apps.first(where: { RecordingSources.matchesApp(name, name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier ?? "") }) else {
                throw MCPToolError.message("No running app matches \"\(name)\".")
            }
            return app
        }
        if let pid = targetProcessID, let app = NSRunningApplication(processIdentifier: pid) { return app }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw MCPToolError.message("Give the app name.") }
        return app
    }

    static func json(_ rect: CGRect) -> [String: Int] {
        ["x": Int(rect.minX), "y": Int(rect.minY), "width": Int(rect.width), "height": Int(rect.height)]
    }
}
