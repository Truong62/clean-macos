import AVFoundation
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
    var selector: String?
    var url: String?
    var discard: Bool?
    var path: String?
    var frames: Int?

    enum CodingKeys: String, CodingKey {
        case kind, element, app, role, index, x, y, width, height, text, color, number, id, seconds
        case holdSeconds = "hold_seconds", keys, dx, dy, count, scale, displayID = "display_id", interval, keepAnnotations = "keep_annotations", position
        case selector, url, discard, path, frames
    }
}

extension AgentRecordingSession {
    static let zoomSteps = 24
    static let zoomDuration = 0.7
    static let screenshotMaxWidth: CGFloat = 1600
    static let maxWaitSeconds = 60.0
    static let cursorGlide = 0.5

    func annotate(_ arguments: DemoArguments) async throws -> [String: Any] {
        guard let kindName = arguments.kind, let kind = Annotation.Kind(rawValue: kindName) else {
            throw MCPToolError.message("kind must be one of \(Annotation.Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let color = DemoColor.parse(arguments.color) else { throw MCPToolError.message("color must be a name like red or a hex like #FF3B30.") }
        if let web {
            let result = try await webAnnotate(web, arguments, kind: kind, color: color)
            try await hold(arguments, default: 1.2)
            return result
        }
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
        if let web {
            try await webCaption(web, text: text, onTop: arguments.position == "top")
            try await hold(arguments, default: 1.0)
            return ["caption": text ?? NSNull()]
        }
        overlay.show(showsClicks: false)
        overlay.model.setCaption(text, in: recordedArea, scale: zoomFactor, atTop: arguments.position == "top")
        try await hold(arguments, default: 1.0)
        return ["caption": text ?? NSNull()]
    }

    func clearAnnotations(_ arguments: DemoArguments) async throws -> [String: Any] {
        if let web {
            try await webClear(web, id: arguments.id)
            if arguments.id == nil { stepCount = 0 }
        } else if let id = arguments.id {
            overlay.model.remove(id: id)
        } else {
            overlay.model.clearAnnotations()
            stepCount = 0
        }
        try await hold(arguments, default: 0.3)
        return ["cleared": arguments.id ?? "all"]
    }

    func findElement(_ arguments: DemoArguments) async throws -> [String: Any] {
        if let web { return try await webFind(web, arguments) }
        guard let query = arguments.element else { throw MCPToolError.message("element is required.") }
        let app = try resolveApp(arguments.app)
        let found = try elements(query, in: app, role: arguments.role)
        return ["app": app.localizedName ?? "", "matches": found.prefix(10).enumerated().map { index, element in
            ["index": index, "role": element.role, "label": element.label, "rect": Self.json(element.frame)]
        }]
    }

    func click(_ arguments: DemoArguments) async throws -> [String: Any] {
        if let web {
            let result = try await webClick(web, arguments)
            try await hold(arguments, default: 0.6)
            return result
        }
        try DemoInput.ensureTrusted()
        guard let target = try targetElement(arguments) else { throw MCPToolError.message("Give an element (with app) or x and y.") }
        let point = CGPoint(x: target.rect.midX, y: target.rect.midY)
        if isBackground, let pid = targetProcessID {
            overlay.model.moveCursor(to: point, duration: Self.cursorGlide)
            try await Task.sleep(for: .seconds(Self.cursorGlide))
            overlay.model.ripple(at: point)
            let element = target.element ?? BackgroundInput.element(at: point, pid: pid)
            var method = element.flatMap(BackgroundInput.press)
            if method == nil {
                BackgroundInput.postClick(at: point, to: pid)
                method = "event"
            }
            if arguments.keepAnnotations != true { overlay.model.clearAnnotations() }
            try await hold(arguments, default: 0.6)
            return ["clicked": ["x": Int(point.x), "y": Int(point.y)], "method": method ?? "event"]
        }
        overlay.show(showsClicks: false)
        await DemoInput.glide(to: point, duration: 0.45)
        overlay.toolClicked(at: point)
        await DemoInput.click(at: point, count: arguments.count ?? 1)
        if arguments.keepAnnotations != true { overlay.model.clearAnnotations() }
        try await hold(arguments, default: 0.6)
        return ["clicked": ["x": Int(point.x), "y": Int(point.y)]]
    }

    func typeText(_ arguments: DemoArguments) async throws -> [String: Any] {
        guard let text = arguments.text, !text.isEmpty else { throw MCPToolError.message("text is required.") }
        let interval = min(max(arguments.interval ?? 0.04, 0), 0.5)
        if let web {
            try await webType(web, arguments, text: text, interval: interval)
            try await hold(arguments, default: 0.4)
            return ["typed": text.count]
        }
        try DemoInput.ensureTrusted()
        if isBackground, let pid = targetProcessID {
            let field = try targetElement(arguments)?.element ?? BackgroundInput.focusedElement(pid: pid)
            if let field, await BackgroundInput.type(text, into: field, interval: interval) {
                try await hold(arguments, default: 0.4)
                return ["typed": text.count, "method": "value"]
            }
            await BackgroundInput.postText(text, to: pid, interval: interval)
            try await hold(arguments, default: 0.4)
            return ["typed": text.count, "method": "event"]
        }
        await DemoInput.type(text, interval: interval)
        try await hold(arguments, default: 0.4)
        return ["typed": text.count]
    }

    func pressKey(_ arguments: DemoArguments) async throws -> [String: Any] {
        if let web {
            guard let keys = arguments.keys else { throw MCPToolError.message("keys is required.") }
            try await webPress(web, keys: keys)
            try await hold(arguments, default: 0.4)
            return ["pressed": keys]
        }
        try DemoInput.ensureTrusted()
        guard let keys = arguments.keys, let combo = KeyCombo.parse(keys) else {
            throw MCPToolError.message("keys must look like return, esc, tab, cmd+k or cmd+shift+n.")
        }
        if isBackground, let pid = targetProcessID {
            BackgroundInput.postKey(combo, to: pid)
        } else {
            DemoInput.press(combo)
        }
        try await hold(arguments, default: 0.4)
        return ["pressed": keys]
    }

    func scroll(_ arguments: DemoArguments) async throws -> [String: Any] {
        if let web {
            let result = try await webScroll(web, arguments)
            try await hold(arguments, default: 0.5)
            return result
        }
        try DemoInput.ensureTrusted()
        if arguments.keepAnnotations != true { overlay.model.clearAnnotations() }
        if isBackground, let pid = targetProcessID {
            let display = recordedArea
            let target = try targetElement(arguments)
            let point = target.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) } ?? CGPoint(x: display.midX, y: display.midY)
            overlay.model.moveCursor(to: point, duration: Self.cursorGlide)
            try await Task.sleep(for: .seconds(Self.cursorGlide))
            if arguments.dy == nil, let element = target?.element, BackgroundInput.reveal(element) {
                try await hold(arguments, default: 0.5)
                return ["scrolled_to": arguments.element ?? "element", "method": "reveal"]
            }
            guard let element = target?.element ?? BackgroundInput.element(at: point, pid: pid),
                  await BackgroundInput.scroll(near: element, by: CGFloat(arguments.dy ?? 400)) else {
                throw MCPToolError.message("Nothing scrollable was found there in the background. Point at a scrolling area, or use background: false.")
            }
            try await hold(arguments, default: 0.5)
            return ["scrolled": ["dy": arguments.dy ?? 400], "method": "scrollbar"]
        }
        if let rect = try targetRect(arguments) {
            await DemoInput.glide(to: CGPoint(x: rect.midX, y: rect.midY), duration: 0.35)
        }
        await DemoInput.scroll(by: CGVector(dx: arguments.dx ?? 0, dy: arguments.dy ?? 400), steps: 24)
        try await hold(arguments, default: 0.5)
        return ["scrolled": ["dx": arguments.dx ?? 0, "dy": arguments.dy ?? 400]]
    }

    func zoomIn(_ arguments: DemoArguments) async throws -> [String: Any] {
        if let web, isRecording {
            guard let focus = try await webTargetRect(web, arguments) else {
                throw MCPToolError.message("Give an element or selector, or x, y, width and height to zoom into.")
            }
            let result = try await webZoom(web, to: focus, scale: arguments.scale, duration: arguments.seconds ?? Self.zoomDuration)
            try await hold(arguments, default: 0.4)
            return result
        }
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
        if let web, isRecording {
            let result = try await webZoom(web, to: nil, scale: nil, duration: arguments.seconds ?? Self.zoomDuration)
            try await hold(arguments, default: 0.4)
            return result
        }
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

    func navigate(_ arguments: DemoArguments) async throws -> [String: Any] {
        guard let web else { throw MCPToolError.message("navigate works in a hidden browser recording. Start one with start_recording and a url.") }
        guard let url = arguments.url else { throw MCPToolError.message("url is required.") }
        try await webNavigate(web, to: url)
        try await hold(arguments, default: 0.5)
        return ["navigated": url]
    }

    func screenshot(_ arguments: DemoArguments) async throws -> ToolOutput {
        if let web { return try await webScreenshot(web) }
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
        try targetElement(arguments)?.rect
    }

    private func targetElement(_ arguments: DemoArguments) throws -> (rect: CGRect, element: AXUIElement?)? {
        if let query = arguments.element {
            let app = try resolveApp(arguments.app)
            let found = try elements(query, in: app, role: arguments.role)
            let index = arguments.index ?? 0
            guard found.indices.contains(index) else {
                throw MCPToolError.message("Only \(found.count) element(s) labelled \"\(query)\" in \(app.localizedName ?? "the app"). Use find_element to see them.")
            }
            return (found[index].frame, found[index].element)
        }
        guard let x = arguments.x, let y = arguments.y else { return nil }
        return (CGRect(x: x, y: y, width: arguments.width ?? 0, height: arguments.height ?? 0), nil)
    }

    private func elements(_ query: String, in app: NSRunningApplication, role: String?) throws -> [FoundElement] {
        try DemoInput.ensureTrusted()
        let area = isBackground ? recordingDisplay : nil
        let found = AccessibilityFinder.find(query, pid: app.processIdentifier, role: role).filter { area?.intersects($0.frame) ?? true }
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

extension AgentRecordingSession {
    static let reviewColumns = 4
    static let reviewTile = CGSize(width: 480, height: 270)
    static let reviewLabelHeight: CGFloat = 26

    func reviewRecording(_ arguments: DemoArguments) async throws -> ToolOutput {
        guard let url = arguments.path.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? lastSavedRecording else {
            throw MCPToolError.message("Give a path, or stop a recording first.")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw MCPToolError.message("That video is empty.") }
        let count = min(max(arguments.frames ?? 12, 4), 24)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = Self.reviewTile
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var frames: [(image: CGImage, seconds: Double)] = []
        for index in 0..<count {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            let (image, actual) = try await generator.image(at: time)
            frames.append((image, actual.seconds))
        }
        let sheet = Self.contactSheet(frames)
        guard let tiff = sheet.tiffRepresentation, let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw MCPToolError.message("The review image could not be made.")
        }
        return .image(jpeg, mimeType: "image/jpeg", [
            "path": url.path, "duration_seconds": NSDecimalNumber(string: String(format: "%.1f", duration)),
            "layout": "\(Self.reviewColumns) per row, left to right, top to bottom", "times": frames.map { ScreenRecording.elapsed($0.seconds) },
        ])
    }

    private static func contactSheet(_ frames: [(image: CGImage, seconds: Double)]) -> NSImage {
        let rows = (frames.count + reviewColumns - 1) / reviewColumns
        let cell = CGSize(width: reviewTile.width, height: reviewTile.height + reviewLabelHeight)
        let size = CGSize(width: cell.width * CGFloat(reviewColumns), height: cell.height * CGFloat(rows))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                                                         .foregroundColor: NSColor.white]
        return NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            CGRect(origin: .zero, size: size).fill()
            for (index, frame) in frames.enumerated() {
                let origin = CGPoint(x: CGFloat(index % reviewColumns) * cell.width, y: CGFloat(index / reviewColumns) * cell.height)
                let fitted = AVMakeRect(aspectRatio: CGSize(width: frame.image.width, height: frame.image.height),
                                        insideRect: CGRect(origin: origin, size: reviewTile))
                NSImage(cgImage: frame.image, size: fitted.size).draw(in: fitted)
                (ScreenRecording.elapsed(frame.seconds) as NSString)
                    .draw(at: CGPoint(x: origin.x + 8, y: origin.y + reviewTile.height + 4), withAttributes: attributes)
            }
            return true
        }
    }
}
