import AppKit
import ImageIO

enum JSValue {
    static func encode(_ value: Any?) -> String {
        guard let value, !(value is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class WebDemo {
    let browser: HeadlessBrowser
    let writer: FrameWriter
    var annotations: [[String: Any]] = []
    var caption: String?
    var isCaptionOnTop = false
    var cursor: CGPoint
    var view: [String: Double]?

    init(browser: HeadlessBrowser, writer: FrameWriter) {
        self.browser = browser
        self.writer = writer
        cursor = CGPoint(x: browser.viewport.width / 2, y: browser.viewport.height / 2)
    }

    var overlayState: [String: Any] {
        ["annotations": annotations, "caption": caption ?? NSNull(), "captionTop": isCaptionOnTop,
         "cursor": ["x": cursor.x, "y": cursor.y], "view": view ?? NSNull()]
    }

    func call(_ function: String, _ arguments: Any?...) async throws {
        try await browser.evaluate("window.__cmDemo && window.__cmDemo.\(function)(\(arguments.map(JSValue.encode).joined(separator: ",")))")
    }
}

extension AgentRecordingSession {
    static let webScale: CGFloat = 1.25
    static let wheelSteps = 20

    func startWeb(_ url: String, browserName: String?, fresh: Bool, options: RecordingOptions) async throws -> [String: Any] {
        guard BrowserURL.isAllowed(url) else { throw MCPToolError.message("url must start with http://, https:// or file://.") }
        let output = options.resolution == .hd720 ? CGSize(width: 1280, height: 720) : CGSize(width: 1920, height: 1080)
        let scale = options.resolution == .hd720 ? 1 : Self.webScale
        let viewport = CGSize(width: (output.width / scale).rounded(), height: (output.height / scale).rounded())
        let browser = try await HeadlessBrowser.launch(browser: browserName, viewport: viewport, scale: scale,
                                                        overlayScript: BrowserOverlayScript.source, fresh: fresh)
        do {
            try await browser.navigate(to: url)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            let writer = try FrameWriter(url: temporary, size: output, framesPerSecond: options.framesPerSecond)
            let connection = browser.connection
            connection.on("Page.screencastFrame") { params in
                if let session = params["sessionId"] { connection.post("Page.screencastFrameAck", ["sessionId": session]) }
                guard let base64 = params["data"] as? String, let data = Data(base64Encoded: base64),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
                writer.update(image)
            }
            try await connection.send("Page.startScreencast", [
                "format": "jpeg", "quality": 100, "maxWidth": Int(output.width), "maxHeight": Int(output.height), "everyNthFrame": 1,
            ])
            let demo = WebDemo(browser: browser, writer: writer)
            web = demo
            browser.onContentLoaded { [weak self] in
                Task { @MainActor in try? await self?.web?.call("sync", self?.web?.overlayState) }
            }
            try await demo.call("cursor", demo.cursor.x, demo.cursor.y, 0)
            writer.start()
            return ["target": "\(url) in a hidden browser", "profile": fresh ? "fresh (signed out)" : "saved (keeps sign-ins)", "viewport": ["width": Int(viewport.width), "height": Int(viewport.height)],
                    "video": ["width": Int(output.width), "height": Int(output.height)], "folder": options.folder.path]
        } catch {
            browser.close()
            web = nil
            throw error
        }
    }

    func finishWeb(into folder: URL) async -> Result<URL, Error> {
        guard let web else { return .failure(MCPToolError.message("No recording is running.")) }
        self.web = nil
        try? await web.browser.connection.send("Page.stopScreencast")
        defer { web.browser.close() }
        do {
            try await web.writer.finish()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(ScreenRecording.fileName(at: Date()))
            try FileManager.default.moveItem(at: web.writer.url, to: destination)
            return .success(destination)
        } catch {
            try? FileManager.default.removeItem(at: web.writer.url)
            return .failure(error)
        }
    }

    func webAnnotate(_ web: WebDemo, _ arguments: DemoArguments, kind: Annotation.Kind, color: NSColor) async throws -> [String: Any] {
        if kind == .blur, arguments.element != nil || arguments.selector != nil {
            let matches = try await webMatches(web, arguments)
            let index = arguments.index ?? 0
            guard matches.indices.contains(index) else { throw MCPToolError.message("Only \(matches.count) match(es). Use find_element to see them.") }
            annotationCount += 1
            let id = arguments.id ?? "a\(annotationCount)"
            guard let rect = try await web.browser.evaluate("window.__cmBlurElement(\(index), \(JSValue.encode(id)))") as? [String: Any] else {
                throw MCPToolError.message("That element disappeared from the page.")
            }
            return ["id": id, "kind": kind.rawValue, "blurs": "the element itself, so it stays hidden while it moves; remove with clear_annotations and this id",
                    "rect": ["x": rect["x"] ?? 0, "y": rect["y"] ?? 0, "width": rect["width"] ?? 0, "height": rect["height"] ?? 0]]
        }
        let rect: CGRect
        if kind == .title {
            rect = try await webTarget(web, arguments) ?? CGRect(origin: .zero, size: web.browser.viewport)
        } else {
            guard let target = try await webTarget(web, arguments) else {
                throw MCPToolError.message("Give an element or selector, or x and y (page CSS pixels).")
            }
            rect = target
        }
        annotationCount += 1
        let id = arguments.id ?? "a\(annotationCount)"
        let number = kind == .step ? (arguments.number ?? stepCount + 1) : arguments.number
        if kind == .step, let number { stepCount = number }
        var annotation: [String: Any] = ["id": id, "kind": kind.rawValue, "x": rect.minX, "y": rect.minY, "width": rect.width,
                                         "height": rect.height, "color": DemoColor.hex(color)]
        if let text = arguments.text { annotation["text"] = text }
        if let number { annotation["number"] = number }
        web.annotations.removeAll { $0["id"] as? String == id }
        web.annotations.append(annotation)
        try await web.call("annotate", annotation)
        if let seconds = arguments.seconds, seconds > 0 {
            Task { @MainActor [weak web] in
                try? await Task.sleep(for: .seconds(seconds))
                web?.annotations.removeAll { $0["id"] as? String == id }
                try? await web?.call("remove", id)
            }
        }
        return ["id": id, "kind": kind.rawValue, "rect": Self.json(rect)]
    }

    func webCaption(_ web: WebDemo, text: String?, onTop: Bool) async throws {
        web.caption = text
        web.isCaptionOnTop = onTop
        try await web.call("caption", text, onTop)
    }

    func webClear(_ web: WebDemo, id: String?) async throws {
        if let id {
            web.annotations.removeAll { $0["id"] as? String == id }
            try await web.call("remove", id)
            try await web.browser.evaluate("window.__cmUnblur && window.__cmUnblur(\(JSValue.encode(id)))")
        } else {
            web.annotations.removeAll { $0["kind"] as? String != Annotation.Kind.blur.rawValue }
            try await web.call("clear")
        }
    }

    func webFind(_ web: WebDemo, _ arguments: DemoArguments) async throws -> [String: Any] {
        guard arguments.element != nil || arguments.selector != nil else { throw MCPToolError.message("element or selector is required.") }
        let matches = try await webMatches(web, arguments)
        return ["matches": matches]
    }

    func webClick(_ web: WebDemo, _ arguments: DemoArguments) async throws -> [String: Any] {
        guard let rect = try await webTarget(web, arguments) else { throw MCPToolError.message("Give an element or selector, or x and y.") }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        try await glide(web, to: point)
        try await web.call("ripple", point.x, point.y)
        let connection = web.browser.connection
        try await connection.send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": point.x, "y": point.y])
        for count in 1...max(arguments.count ?? 1, 1) {
            for type in ["mousePressed", "mouseReleased"] {
                try await connection.send("Input.dispatchMouseEvent", ["type": type, "x": point.x, "y": point.y, "button": "left", "clickCount": count])
            }
        }
        if arguments.keepAnnotations != true { try await webClear(web, id: nil) }
        return ["clicked": ["x": Int(point.x), "y": Int(point.y)]]
    }

    func webType(_ web: WebDemo, _ arguments: DemoArguments, text: String, interval: Double) async throws {
        if arguments.element != nil || arguments.selector != nil || arguments.x != nil {
            var focus = arguments
            focus.keepAnnotations = true
            _ = try await webClick(web, focus)
        }
        for character in text {
            try await web.browser.connection.send("Input.insertText", ["text": String(character)])
            try await Task.sleep(for: .seconds(interval))
        }
    }

    func webPress(_ web: WebDemo, keys: String) async throws {
        guard let key = WebKey.parse(keys) else { throw MCPToolError.message("keys must look like return, esc, tab, down, cmd+a or shift+tab.") }
        var down: [String: Any] = ["type": key.text == nil ? "rawKeyDown" : "keyDown", "key": key.key, "code": key.code,
                                   "windowsVirtualKeyCode": key.keyCode, "nativeVirtualKeyCode": key.keyCode, "modifiers": key.modifiers]
        if let text = key.text { down["text"] = text }
        try await web.browser.connection.send("Input.dispatchKeyEvent", down)
        try await web.browser.connection.send("Input.dispatchKeyEvent", ["type": "keyUp", "key": key.key, "code": key.code,
                                                                          "windowsVirtualKeyCode": key.keyCode, "modifiers": key.modifiers])
    }

    func webScroll(_ web: WebDemo, _ arguments: DemoArguments) async throws -> [String: Any] {
        if arguments.dy == nil, arguments.dx == nil, arguments.element != nil || arguments.selector != nil {
            if arguments.keepAnnotations != true { try await webClear(web, id: nil) }
            guard let rect = try await webTarget(web, arguments, centered: true) else { throw MCPToolError.message("Nothing to scroll to.") }
            try await glide(web, to: CGPoint(x: rect.midX, y: rect.midY))
            return ["scrolled_to": Self.json(rect)]
        }
        let viewport = web.browser.viewport
        let point = try await webTarget(web, arguments).map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        try await glide(web, to: point)
        let (dx, dy) = (arguments.dx ?? 0, arguments.dy ?? 400)
        if arguments.keepAnnotations != true { try await webClear(web, id: nil) }
        for _ in 0..<Self.wheelSteps {
            try await web.browser.connection.send("Input.dispatchMouseEvent", [
                "type": "mouseWheel", "x": point.x, "y": point.y, "deltaX": dx / Double(Self.wheelSteps), "deltaY": dy / Double(Self.wheelSteps),
            ])
            try await Task.sleep(for: .milliseconds(18))
        }
        return ["scrolled": ["dx": dx, "dy": dy]]
    }

    func webZoom(_ web: WebDemo, to focus: CGRect?, scale: Double?, duration: Double) async throws -> [String: Any] {
        let size = web.writer.size
        let base = CGRect(origin: .zero, size: size)
        let pixels = web.browser.scale
        let target = focus.map {
            ZoomMath.rect(focus: CGRect(x: $0.minX * pixels, y: $0.minY * pixels, width: $0.width * pixels, height: $0.height * pixels),
                          base: base, aspect: size.width / size.height, scale: scale.map { CGFloat($0) })
        } ?? base
        let start = web.writer.currentZoom()
        web.writer.zoom(to: target, duration: duration)
        let steps = 8
        for step in 1...steps {
            let frame = ZoomMath.interpolate(from: start, to: target, progress: CGFloat(step) / CGFloat(steps))
            web.view = target == base && step == steps ? nil
                : ["x": frame.minX / pixels, "y": frame.minY / pixels, "w": frame.width / pixels, "h": frame.height / pixels, "s": size.width / frame.width]
            try await web.call("view", web.view)
            try await Task.sleep(for: .seconds(max(duration, 0) / Double(steps)))
        }
        let css = CGRect(x: target.minX / pixels, y: target.minY / pixels, width: target.width / pixels, height: target.height / pixels)
        return focus == nil ? ["zoomed_out": true] : ["zoomed_to": Self.json(css)]
    }

    func webScreenshot(_ web: WebDemo) async throws -> ToolOutput {
        let result = try await web.browser.connection.send("Page.captureScreenshot", ["format": "jpeg", "quality": 80])
        guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let page = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MCPToolError.message("The page screenshot failed.")
        }
        let scale = web.browser.scale
        let crop = web.writer.currentZoom()
        let pixelsPerOutput = CGFloat(page.width) / web.writer.size.width
        let cropInPage = CGRect(x: crop.minX * pixelsPerOutput, y: crop.minY * pixelsPerOutput,
                                width: crop.width * pixelsPerOutput, height: crop.height * pixelsPerOutput).integral
        guard let visible = page.cropping(to: cropInPage),
              let jpeg = NSBitmapImageRep(cgImage: visible).representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            throw MCPToolError.message("The page screenshot failed.")
        }
        let pageX = cropInPage.minX / pixelsPerOutput / scale
        let pageY = cropInPage.minY / pixelsPerOutput / scale
        let pointsPerPixel = 1 / pixelsPerOutput / scale
        let viewport = web.browser.viewport
        return .image(jpeg, mimeType: "image/jpeg", [
            "viewport": ["width": Int(viewport.width), "height": Int(viewport.height)],
            "shows": crop.size == web.writer.size ? "the whole page view, as in the video" : "the zoomed part of the page, as in the video",
            "to_page_points": "x = \(Self.decimal(pageX)) + pixel_x * \(Self.decimal(pointsPerPixel)), y = \(Self.decimal(pageY)) + pixel_y * \(Self.decimal(pointsPerPixel)). Page points are what annotate, click and find_element use.",
        ])
    }

    static func decimal(_ value: CGFloat) -> String {
        String(format: "%.4g", value)
    }

    func webNavigate(_ web: WebDemo, to url: String) async throws {
        guard BrowserURL.isAllowed(url) else { throw MCPToolError.message("url must start with http://, https:// or file://.") }
        try await webClear(web, id: nil)
        try await web.browser.navigate(to: url)
    }

    private func glide(_ web: WebDemo, to point: CGPoint) async throws {
        web.cursor = point
        try await web.call("cursor", point.x, point.y, Int(Self.cursorGlide * 1000))
        try await Task.sleep(for: .seconds(Self.cursorGlide))
    }

    private func webMatches(_ web: WebDemo, _ arguments: DemoArguments) async throws -> [[String: Any]] {
        let matches = try await web.browser.evaluate(
            "window.__cmFind(\(JSValue.encode(arguments.element ?? "")), \(JSValue.encode(arguments.selector)), \(JSValue.encode(arguments.role)))"
        ) as? [[String: Any]] ?? []
        guard !matches.isEmpty else {
            let label = arguments.selector ?? arguments.element ?? ""
            throw MCPToolError.message("Nothing on the page matches \"\(label)\". Take a screenshot, or use a CSS selector.")
        }
        return matches
    }

    func webTargetRect(_ web: WebDemo, _ arguments: DemoArguments) async throws -> CGRect? {
        try await webTarget(web, arguments)
    }

    private func webTarget(_ web: WebDemo, _ arguments: DemoArguments, centered: Bool = false) async throws -> CGRect? {
        if arguments.element != nil || arguments.selector != nil {
            let matches = try await webMatches(web, arguments)
            let index = arguments.index ?? 0
            guard matches.indices.contains(index) else {
                throw MCPToolError.message("Only \(matches.count) match(es). Use find_element to see them.")
            }
            guard let rect = try await web.browser.evaluate("window.__cmReveal(\(index), \(centered))") as? [String: Any],
                  let x = rect["x"] as? Double, let y = rect["y"] as? Double,
                  let width = rect["width"] as? Double, let height = rect["height"] as? Double else {
                throw MCPToolError.message("That element disappeared from the page.")
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        guard let x = arguments.x, let y = arguments.y else { return nil }
        return CGRect(x: x, y: y, width: arguments.width ?? 0, height: arguments.height ?? 0)
    }
}

enum BrowserURL {
    static func isAllowed(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "file" || (["http", "https"].contains(scheme) && url.host() != nil)
    }
}
