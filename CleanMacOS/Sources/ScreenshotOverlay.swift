import AppKit

@MainActor
final class CaptureOverlayView: NSView {
    let shot: CaptureDisplay
    unowned let controller: ScreenshotController
    let windows: [CaptureWindow]
    var anchor: CGPoint?
    var selection: CGRect?
    var pointer = CGPoint.zero
    var magnifier = false
    var zoom = 1.0
    var moving = false
    var lastDrag = CGPoint.zero
    var copiedUntil = Date.distantPast
    var hover: CaptureWindow?
    var selectedWindow: CaptureWindow?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(shot: CaptureDisplay, controller: ScreenshotController, windows: [CaptureWindow]) {
        self.shot = shot
        self.controller = controller
        self.windows = windows
        super.init(frame: CGRect(origin: .zero, size: shot.frame.size))
        magnifier = controller.settings.magnifier || controller.mode == .color
        zoom = controller.settings.zoom
        let mouse = NSEvent.mouseLocation
        pointer = CGPoint(x: mouse.x - shot.frame.minX, y: shot.frame.maxY - mouse.y)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    func modeChanged() {
        anchor = nil
        selection = nil
        magnifier = controller.settings.magnifier || controller.mode == .color
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    var showsModePalette: Bool {
        switch controller.mode {
        case .color: controller.screenTools.settings.showsColorModes
        case .text: controller.screenTools.settings.showsTextModes
        default: controller.settings.showModes
        }
    }

    var modeTiles: [(CaptureMode, CGRect)] {
        let modes = CaptureMode.allCases.filter { $0 != .recording || ScreenRecorder.isSupported }
        let width = CGFloat(modes.count) * 116 + CGFloat(modes.count - 1) * 6
        return modes.enumerated().map { index, mode in
            (mode, CGRect(x: max(8, bounds.midX - width / 2) + CGFloat(index) * 122, y: bounds.height - 116, width: 116, height: 48))
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if showsModePalette { for (_, rect) in modeTiles { addCursorRect(rect, cursor: .arrow) } }
        if controller.mode == .screenshot { addCursorRect(CGRect(x: bounds.midX - 85, y: 42, width: 170, height: 34), cursor: .arrow) }
    }
    override func mouseEntered(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self); mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        let global = CGPoint(x: shot.frame.minX + pointer.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - shot.frame.maxY + pointer.y)
        let excluded = Set(windows.filter { $0.owner == getpid() && (controller.settings.hideOwnWindows || $0.layer != 0) }.map(\.id))
        hover = CaptureWindows.hit(global, windows: windows, excluding: excluded)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseMoved(with: event)
        if showsModePalette, let tile = modeTiles.first(where: { $0.1.contains(pointer) }) { controller.switchMode(tile.0); return }
        if controller.mode == .recording, let studio = controller.recordingStudio {
            if CGRect(x: bounds.midX - 150, y: bounds.height - 62, width: 145, height: 26).contains(pointer) { studio.settings.systemAudio.toggle(); needsDisplay = true; return }
            if CGRect(x: bounds.midX + 5, y: bounds.height - 62, width: 145, height: 26).contains(pointer) { studio.settings.microphone.toggle(); needsDisplay = true; return }
        }
        if controller.mode == .color { copyColor(ends: true); return }
        if controller.mode == .screenshot, CGRect(x: bounds.midX - 85, y: 42, width: 170, height: 34).contains(pointer) {
            controller.select(bounds, shot: shot, remembers: false)
            return
        }
        selectedWindow = nil
        anchor = pointer
        lastDrag = pointer
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        pointer = convert(event.locationInWindow, from: nil)
        if moving, let selection {
            self.selection = CaptureGeometry.move(selection, dx: pointer.x - lastDrag.x, dy: pointer.y - lastDrag.y, bounds: bounds)
            self.anchor = CGPoint(x: anchor.x + pointer.x - lastDrag.x, y: anchor.y + pointer.y - lastDrag.y)
        } else {
            selection = CaptureGeometry.drag(from: anchor, to: pointer, bounds: bounds,
                                             square: event.modifierFlags.contains(.shift), centered: event.modifierFlags.contains(.option))
        }
        lastDrag = pointer
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = anchor else { return }
        anchor = nil
        if abs(pointer.x - start.x) < 4 && abs(pointer.y - start.y) < 4,
           let hover, controller.mode == .screenshot || controller.mode == .scrolling || controller.mode == .recording {
            let globalTop = (NSScreen.screens.first?.frame.maxY ?? 0) - shot.frame.maxY
            let rect = hover.frame.offsetBy(dx: -shot.frame.minX, dy: -globalTop).intersection(bounds)
            if controller.mode == .recording { selection = rect; selectedWindow = hover; needsDisplay = true; return }
            controller.select(rect, shot: shot, window: controller.mode == .screenshot ? hover : nil, remembers: false)
        } else if let selection, selection.width >= 2, selection.height >= 2, controller.mode != .text && controller.mode != .recording {
            controller.select(selection, shot: shot)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { controller.cancel(); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            let rect = controller.mode == .text || controller.mode == .recording ? selection ?? bounds : bounds
            controller.select(rect, shot: shot, window: controller.mode == .recording ? selectedWindow : nil, remembers: selection != nil)
            return
        }
        if event.keyCode == 49 { moving = true; return }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return }
        let physicalDigits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5]
        if let digit = Int(key) ?? physicalDigits[event.keyCode], let mode = CaptureMode(rawValue: digit) { controller.switchMode(mode); return }
        if key == "s" || event.keyCode == 1 { controller.switchMode(controller.mode == .scrolling ? .screenshot : .scrolling) }
        if key == "z" || event.keyCode == 6 { magnifier.toggle() }
        if key == "r" || event.keyCode == 15, let rect = controller.previous(shot) { controller.select(rect, shot: shot, remembers: false) }
        if key == "c" || event.keyCode == 8 { copyColor(ends: false) }
        if magnifier && anchor == nil {
            let directions: [UInt16: (Int, Int)] = [123: (-1, 0), 124: (1, 0), 125: (0, 1), 126: (0, -1)]
            if let (x, y) = directions[event.keyCode] {
                let pixel = CaptureGeometry.pixel(at: pointer, size: bounds.size, imageSize: CGSize(width: shot.image.width, height: shot.image.height))
                let next = CaptureGeometry.nudge(pixel, x: x, y: y, shift: event.modifierFlags.contains(.shift), size: CGSize(width: shot.image.width, height: shot.image.height))
                pointer = CGPoint(x: next.x / shot.scale, y: next.y / shot.scale)
                let point = CGPoint(x: shot.frame.minX + pointer.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - shot.frame.maxY + pointer.y)
                CGWarpMouseCursorPosition(point)
            }
        }
        needsDisplay = true
    }

    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { moving = false } }

    override func scrollWheel(with event: NSEvent) {
        guard magnifier else { return }
        let stepped = controller.settings.stepZoom != event.modifierFlags.contains(.option)
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY * 3
        zoom = CaptureGeometry.zoom(zoom, delta: Double(delta), stepped: stepped)
        if controller.settings.rememberZoom { controller.settings.zoom = zoom }
        needsDisplay = true
    }

    func copyColor(ends: Bool) {
        let pixel = CaptureGeometry.pixel(at: pointer, size: bounds.size, imageSize: CGSize(width: shot.image.width, height: shot.image.height))
        if let color = CaptureGeometry.sample(shot.image, at: pixel) { controller.copyColor(color, ends: ends); copiedUntil = Date().addingTimeInterval(1.4) }
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let frozen = controller.mode == .recording || controller.mode == .color || controller.mode == .text || (controller.mode == .screenshot && controller.settings.freeze)
        if frozen { drawImage(shot.image, in: bounds) }
        let dim = NSBezierPath(rect: bounds)
        var highlight = selection
        if highlight == nil, controller.settings.highlightWindows, controller.mode == .screenshot, let hover {
            highlight = hover.frame.offsetBy(dx: -shot.frame.minX, dy: -((NSScreen.screens.first?.frame.maxY ?? 0) - shot.frame.maxY)).intersection(bounds)
        }
        if let highlight { dim.append(NSBezierPath(roundedRect: highlight, xRadius: 8, yRadius: 8)); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(frozen ? 0.22 : 0.18).setFill()
        dim.fill()
        if let rect = highlight {
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            border.lineWidth = 3
            border.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
            inner.lineWidth = 1
            inner.stroke()
            let pixels = CaptureGeometry.pixels(rect, scale: shot.scale)
            label("\(Int(pixels.width)) × \(Int(pixels.height))", at: CGPoint(x: max(6, min(bounds.width - 130, rect.midX - 60)), y: min(bounds.height - 28, rect.maxY + 10)))
        } else if controller.settings.showPreviousArea, let previous = controller.previous(shot) {
            let path = NSBezierPath(rect: previous)
            path.setLineDash([4, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            path.stroke()
        }
        guard anchor == nil else { return }
        let mouse = NSEvent.mouseLocation
        if shot.frame.contains(mouse) {
            if controller.mode == .screenshot { label("Capture full display ↵", at: CGPoint(x: bounds.midX - 85, y: 42)) }
            if showsModePalette {
                for (mode, rect) in modeTiles {
                    (mode == controller.mode ? NSColor.systemBlue : NSColor.black.withAlphaComponent(0.8)).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
                    ("\(mode.rawValue)  \(mode.title)" as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.midY - 7), withAttributes: attributes)
                }
            } else { label(controller.mode.title + "    Esc Cancel", at: CGPoint(x: max(8, bounds.midX - 230), y: bounds.height - 84)) }
            if controller.mode == .recording, let studio = controller.recordingStudio {
                label("Mac sound: " + (studio.settings.systemAudio ? "On" : "Off"), at: CGPoint(x: bounds.midX - 150, y: bounds.height - 62))
                label("Microphone: " + (studio.settings.microphone ? "On" : "Off"), at: CGPoint(x: bounds.midX + 5, y: bounds.height - 62))
                label("Drag area · Click window · Return confirm · R repeat · Esc cancel", at: CGPoint(x: max(8, bounds.midX - 240), y: bounds.height - 30))
            } else {
                label(controller.mode == .text ? "Drag a region · Return to copy · R repeat" : "Drag area · Click window · R repeat · Z zoom · C copy color",
                      at: CGPoint(x: max(8, bounds.midX - 230), y: bounds.height - 52))
            }
        }
        if magnifier && shot.frame.contains(mouse) { drawMagnifier() }
    }

    func drawImage(_ image: CGImage, in rect: CGRect) {
        NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
    }

    func label(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: CGRect(origin: point, size: CGSize(width: size.width + 16, height: 26)), xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: point.x + 8, y: point.y + 6), withAttributes: attributes)
    }

    func drawMagnifier() {
        let pixel = CaptureGeometry.pixel(at: pointer, size: bounds.size, imageSize: CGSize(width: shot.image.width, height: shot.image.height))
        let count = max(3, Int(13 / zoom) | 1)
        let sample = CGRect(x: pixel.x - CGFloat(count / 2), y: pixel.y - CGFloat(count / 2), width: CGFloat(count), height: CGFloat(count))
            .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        guard let crop = shot.image.cropping(to: sample) else { return }
        let x = pointer.x + 16 + 132 < bounds.maxX - 8 ? pointer.x + 16 : pointer.x - 148
        let y = pointer.y - 148 >= 8 ? pointer.y - 148 : pointer.y + 16
        let rect = CGRect(x: max(8, x), y: min(bounds.height - 170, max(8, y)), width: 132, height: 132)
        drawImage(crop, in: rect)
        NSColor.white.setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).stroke()
        let cell = 132 / CGFloat(count)
        if cell >= 6 {
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let grid = NSBezierPath()
            for index in 1..<count {
                let offset = CGFloat(index) * cell
                grid.move(to: CGPoint(x: rect.minX + offset, y: rect.minY)); grid.line(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
                grid.move(to: CGPoint(x: rect.minX, y: rect.minY + offset)); grid.line(to: CGPoint(x: rect.maxX, y: rect.minY + offset))
            }
            grid.stroke()
        }
        NSColor.systemBlue.setStroke()
        let target = NSBezierPath(rect: CGRect(x: rect.midX - cell / 2, y: rect.midY - cell / 2, width: cell, height: cell))
        target.lineWidth = 2
        target.stroke()
        if let color = CaptureGeometry.sample(shot.image, at: pixel) {
            let text = controller.screenTools.settings.colorFormat.text(color, dropsHash: controller.screenTools.settings.dropsHash)
            label(Date() < copiedUntil ? "✓ Copied" : "\(text)  \(Int(pixel.x)),\(Int(pixel.y))", at: CGPoint(x: rect.minX, y: rect.maxY + 6))
        }
    }
}

@MainActor
final class CaptureScrollOutline: NSView {
    let area: CGRect
    override var isFlipped: Bool { true }
    init(frame: CGRect, area: CGRect) { self.area = area; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: area))
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.3).setFill()
        path.fill()
        let border = NSBezierPath(rect: area)
        border.lineWidth = 2
        NSColor.systemBlue.setStroke()
        border.stroke()
    }
}
