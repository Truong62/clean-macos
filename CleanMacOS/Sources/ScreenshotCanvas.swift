import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScreenshotCanvas: NSViewRepresentable {
    @ObservedObject var session: ScreenshotEditorSession
    @EnvironmentObject var owner: ScreenshotEditorController
    func makeNSView(context: Context) -> EditorCanvasView { EditorCanvasView(session: session) }
    func updateNSView(_ view: EditorCanvasView, context: Context) { view.refresh() }
}

@MainActor
final class EditorCanvasView: NSView {
    let session: ScreenshotEditorSession
    var rendered: CGImage?
    var renderedDocument: ScreenshotDocument?
    var renderedSettings: ScreenshotEditorSettings?
    var revision = -1
    var origin = CGPoint.zero
    var factor: CGFloat = 1
    var frozenFactor: CGFloat?
    var start: CGPoint?
    var loupePoint: CGPoint?
    var initial: ScreenshotDocument?
    var handle: Int?
    var initialRect: CGRect?
    var moving: UUID?
    var wordDrag = false
    var expansion: CGRect?
    var textField: NSTextField?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(session: ScreenshotEditorSession) {
        self.session = session
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        if renderedDocument != session.document || renderedSettings != session.settings || revision != session.renderRevision {
            var settings = session.settings
            settings.export1x = false
            rendered = ScreenshotRenderer.render(session.document, settings: settings, words: session.words)
            renderedDocument = session.document
            renderedSettings = session.settings
            revision = session.renderRevision
        }
        needsDisplay = true
        updateTextField()
    }
    var margin: CGFloat {
        session.settings.background.kind == .none ? 0 : ceil(EditorGeometry.margin(session.document.size, value: session.settings.background.margin))
    }
    func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (p.x - origin.x) / factor - margin, y: (p.y - origin.y) / factor - margin)
    }
    func screenRect(_ rect: CGRect) -> CGRect {
        CGRect(x: origin.x + (rect.minX + margin) * factor, y: origin.y + (rect.minY + margin) * factor, width: rect.width * factor, height: rect.height * factor)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(gray: 0.095, alpha: 1))
        ctx.fill(bounds)
        guard let rendered else { return }
        let size = CGSize(width: rendered.width, height: rendered.height)
        factor = frozenFactor ?? (session.fits ? EditorGeometry.fit(size, in: CGSize(width: max(1, bounds.width - 28), height: max(1, bounds.height - 28))) : session.zoom)
        if abs(session.effectiveZoom - factor) > 0.0001 {
            let currentFactor = factor
            DispatchQueue.main.async { [weak self] in self?.session.effectiveZoom = currentFactor }
        }
        origin = CGPoint(x: (bounds.width - size.width * factor) / 2 + session.pan.width, y: (bounds.height - size.height * factor) / 2 + session.pan.height)
        let card = CGRect(origin: origin, size: CGSize(width: size.width * factor, height: size.height * factor))
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.clip()
        for y in stride(from: card.minY, to: card.maxY, by: 8) {
            for x in stride(from: card.minX, to: card.maxX, by: 8) {
                let alternate = (Int((x - card.minX) / 8) + Int((y - card.minY) / 8)) % 2 == 0
                ctx.setFillColor(CGColor(gray: alternate ? 0.22 : 0.3, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        ScreenshotRenderer.drawImage(rendered, in: card, context: ctx)
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
        ctx.setLineWidth(0.5)
        ctx.stroke(card)
        for word in session.words ?? [] where session.selectedWords.contains(word.id) {
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.35).cgColor)
            ctx.fill(screenRect(word.rect))
        }
        if let crop = session.crop {
            let r = screenRect(crop)
            ctx.saveGState()
            ctx.addRect(screenRect(session.document.bounds))
            ctx.addRect(r)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
            ctx.drawPath(using: .eoFill)
            ctx.restoreGState()
            outline(r, color: .white, handles: EditorGeometry.handles(r), context: ctx)
            if handle != nil, let image = ScreenshotRenderer.decode(session.document.base), let point = loupePoint {
                let sample = CGRect(x: max(0, min(CGFloat(image.width) - 14, point.x - 7)), y: max(0, min(CGFloat(image.height) - 14, point.y - 7)), width: CGFloat(min(14, image.width)), height: CGFloat(min(14, image.height)))
                if let patch = image.cropping(to: sample) {
                    ctx.interpolationQuality = .none
                    let p = screenRect(CGRect(origin: point, size: .zero)).origin
                    ScreenshotRenderer.drawImage(patch, in: CGRect(x: min(bounds.maxX - 76, p.x + 20), y: max(4, p.y - 92), width: 72, height: 72), context: ctx)
                }
            }
        } else if session.tool == .expand {
            let rect = screenRect(expansion ?? session.document.bounds)
            outline(rect, color: .white, handles: EditorGeometry.handles(rect), context: ctx)
        } else if let mark = session.selected {
            let handles = mark.tool.isLine ? [screenRect(CGRect(origin: mark.start, size: .zero)).origin, screenRect(CGRect(origin: mark.end, size: .zero)).origin] : EditorGeometry.handles(screenRect(mark.rect))
            outline(screenRect(mark.rect), color: .systemBlue, handles: handles, context: ctx)
        }
        updateTextField()
    }
    func outline(_ rect: CGRect, color: NSColor, handles: [CGPoint], context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: color == .white ? [] : [5, 3])
        context.stroke(rect)
        context.setLineDash(phase: 0, lengths: [])
        for point in handles {
            let grip = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: grip)
            context.strokeEllipse(in: grip)
        }
    }
    override func mouseDown(with event: NSEvent) {
        session.lastPointer = ProcessInfo.processInfo.systemUptime
        if session.fits { session.zoom = factor }
        session.commitText()
        window?.makeFirstResponder(self)
        let p = point(event)
        start = p
        loupePoint = p
        frozenFactor = factor
        initial = session.history.document
        moving = nil
        handle = nil
        initialRect = nil
        wordDrag = false
        if session.tool == .expand {
            guard let index = EditorGeometry.handles(session.document.bounds).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) * factor <= 10 }) else { start = nil; frozenFactor = nil; return }
            handle = index
            initialRect = session.document.bounds
            return
        }
        if let crop = session.crop {
            initialRect = crop
            handle = EditorGeometry.handles(crop).firstIndex { hypot($0.x - p.x, $0.y - p.y) * factor <= 14 }
            if handle == nil && !crop.contains(p) { initialRect = nil }
            return
        }
        if let mark = session.selected {
            let handles = mark.tool.isLine ? [mark.start, mark.end] : EditorGeometry.handles(mark.rect)
            handle = handles.firstIndex { hypot($0.x - p.x, $0.y - p.y) * factor <= 12 }
            if handle != nil { moving = mark.id; initialRect = mark.rect; return }
        }
        let edgeOnly = [.text, .sticker, .number].contains(session.tool)
        if let id = EditorGeometry.hit(p, marks: session.document.marks, tolerance: 10 * session.document.scale, edgeOnly: edgeOnly), let mark = session.document.marks.first(where: { $0.id == id }) {
            session.selection = id
            if mark.tool == .text && (session.tool == .text || event.clickCount == 2) { session.beginText(at: p, existing: mark); return }
            session.choose(.select)
            moving = id
            initialRect = mark.rect
            return
        }
        session.selection = nil
        guard session.document.bounds.contains(p) else { start = nil; frozenFactor = nil; return }
        if session.tool == .select {
            wordDrag = true
            session.selectedWords = Set((session.words ?? []).filter { $0.rect.contains(p) }.map(\.id))
        } else if session.tool == .text { session.beginText(at: p) }
        else {
            var mark = AnnotationMark(tool: session.tool, start: p, end: p, points: [p], style: session.settings.style, seed: UInt64.random(in: 1...UInt64.max))
            if session.tool == .sticker || session.tool == .number {
                let side = session.tool == .sticker ? EditorGeometry.stickerSide(session.document.size, scale: session.document.scale) : EditorGeometry.numberDiameter(session.document.size)
                mark.start = CGPoint(x: p.x - side / 2, y: p.y - side / 2)
                mark.end = CGPoint(x: p.x + side / 2, y: p.y + side / 2)
            }
            var next = session.document
            next.marks.append(mark)
            session.draft = next
            session.selection = mark.id
        }
        refresh()
    }
    override func mouseDragged(with event: NSEvent) {
        session.lastPointer = ProcessInfo.processInfo.systemUptime
        guard let start, let initial else { return }
        let p = point(event)
        loupePoint = p
        let delta = CGSize(width: p.x - start.x, height: p.y - start.y)
        if session.tool == .expand {
            if let initialRect, let handle {
                let proposed = EditorGeometry.resized(initialRect, handle: handle, to: p).union(initialRect).integral
                if EditorGeometry.valid(proposed.size) { expansion = proposed; session.status = "\(Int(proposed.width)) × \(Int(proposed.height)) px" }
                else { session.status = "Canvas cannot exceed 60 megapixels" }
            }
        } else if session.crop != nil {
            if let initialRect {
                if let handle { session.crop = EditorGeometry.resized(initialRect, handle: handle, to: p).intersection(initial.bounds) }
                else { session.crop = EditorGeometry.moved(initialRect, by: delta, within: initial.bounds) }
            } else { session.crop = EditorGeometry.rect(start, p).intersection(initial.bounds) }
        } else if wordDrag {
            let rect = EditorGeometry.rect(start, p)
            session.selectedWords = Set((session.words ?? []).filter { $0.rect.intersects(rect) }.map(\.id))
        } else if let moving, let index = initial.marks.firstIndex(where: { $0.id == moving }) {
            var next = initial
            if let handle {
                if next.marks[index].tool.isLine {
                    if handle == 0 { next.marks[index].start = p } else { next.marks[index].end = p }
                } else if let initialRect {
                    next.marks[index].resize(to: EditorGeometry.resized(initialRect, handle: handle, to: p, proportional: next.marks[index].image != nil))
                }
            } else { next.marks[index].translate(delta) }
            session.draft = next
        } else if session.editingText == nil, var next = session.draft, let index = next.marks.indices.last {
            if ![.number, .sticker].contains(next.marks[index].tool) {
                next.marks[index].end = p
                if next.marks[index].tool == .pen { next.marks[index].points.append(p) }
                session.draft = next
            }
        }
        refresh()
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; initial = nil; handle = nil; moving = nil; frozenFactor = nil; expansion = nil; refresh() }
        guard let start else { return }
        if session.tool == .expand {
            if let expansion { session.expand(to: expansion) }
        } else if session.crop != nil {
            if let crop = session.crop { session.crop = EditorGeometry.crop(crop, bounds: session.document.bounds) ?? session.document.bounds }
        } else if session.editingText == nil, var next = session.draft {
            let p = point(event)
            if moving != nil && hypot(p.x - start.x, p.y - start.y) * factor < 7 { session.draft = nil; return }
            if moving == nil && hypot(p.x - start.x, p.y - start.y) * factor < 7, let last = next.marks.last, ![.sticker, .number].contains(last.tool) {
                next.remove(last.id)
                session.selection = nil
            }
            session.commit(next)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            session.zoom = max(0.05, min(3, factor * exp(event.scrollingDeltaY * 0.01)))
            session.fits = false
        } else {
            session.pan.width += event.scrollingDeltaX
            session.pan.height += event.scrollingDeltaY
        }
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        session.zoom = max(0.05, min(3, factor * (1 + event.magnification)))
        session.fits = false
        needsDisplay = true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
            session.owner.open(url)
            return true
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type), let image = ScreenshotRenderer.decode(data) { session.insert(image); return true }
        }
        return false
    }
    func updateTextField() {
        guard let id = session.editingText, let mark = session.document.marks.first(where: { $0.id == id }) else {
            textField?.removeFromSuperview()
            textField = nil
            return
        }
        if textField == nil {
            let field = NSTextField(string: session.text)
            field.delegate = self
            field.isBordered = false
            field.backgroundColor = .windowBackgroundColor
            field.focusRingType = .none
            addSubview(field)
            textField = field
            window?.makeFirstResponder(field)
        }
        let rect = screenRect(mark.rect)
        textField?.frame = CGRect(x: rect.minX, y: rect.minY, width: max(180, rect.width + 40), height: max(26, rect.height))
        textField?.font = .systemFont(ofSize: max(10, mark.style.fontSize * session.document.scale * factor), weight: .semibold)
        textField?.textColor = NSColor(cgColor: mark.style.color.cgColor)
    }
}

extension EditorCanvasView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { session.text = textField?.stringValue ?? "" }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            session.commitText()
            window?.makeFirstResponder(self)
            refresh()
            return true
        }
        return false
    }
}
