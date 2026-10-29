import AppKit
import SwiftUI

struct Annotation: Identifiable, Equatable {
    static let wideRatio: CGFloat = 4

    enum Kind: String, CaseIterable {
        case arrow, circle, box, text, step, spotlight, title, blur
    }

    let id: String
    let kind: Kind
    let rect: CGRect
    let text: String?
    let number: Int?
    let color: NSColor
}

struct ClickRipple: Identifiable, Equatable {
    let id = UUID()
    let point: CGPoint
}

enum DemoColor {
    static let accent = NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let named: [String: NSColor] = [
        "red": accent, "orange": .systemOrange, "yellow": .systemYellow, "green": .systemGreen,
        "blue": .systemBlue, "purple": .systemPurple, "pink": .systemPink, "white": .white, "black": .black,
    ]

    static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? accent
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
    }

    static func parse(_ text: String?) -> NSColor? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return accent }
        if let color = named[raw] { return color }
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return NSColor(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

enum ArrowGeometry {
    static let length: CGFloat = 170
    static let gap: CGFloat = 12
    static let margin: CGFloat = 24

    static func points(target: CGRect, canvas: CGSize) -> (start: CGPoint, end: CGPoint) {
        let center = CGPoint(x: target.midX, y: target.midY)
        let toCanvasCenter = CGVector(dx: canvas.width / 2 - center.x, dy: canvas.height / 2 - center.y)
        let distance = hypot(toCanvasCenter.dx, toCanvasCenter.dy)
        let direction = distance < 1 ? CGVector(dx: 0.6, dy: 0.8)
            : CGVector(dx: toCanvasCenter.dx / distance, dy: toCanvasCenter.dy / distance)
        let reach = min(target.width, target.height) / 2 + gap
        let end = CGPoint(x: center.x + direction.dx * reach, y: center.y + direction.dy * reach)
        let start = CGPoint(x: min(max(end.x + direction.dx * length, margin), canvas.width - margin),
                            y: min(max(end.y + direction.dy * length, margin), canvas.height - margin))
        return (start, end)
    }
}

enum ScreenGeometry {
    static func primaryHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func displayBounds(of screen: NSScreen) -> CGRect {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return screen.frame
        }
        return CGDisplayBounds(id)
    }

    static func globalPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

@MainActor
final class DemoOverlayModel: ObservableObject {
    static let rippleLifetime: Duration = .milliseconds(700)

    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var caption: String?
    @Published private(set) var captionArea: CGRect = .zero
    @Published private(set) var captionScale: CGFloat = 1
    @Published private(set) var isCaptionAtTop = false
    @Published private(set) var ripples: [ClickRipple] = []
    @Published private(set) var cursor: CGPoint?

    func add(_ annotation: Annotation) {
        withAnimation(.spring(duration: 0.35)) {
            annotations.removeAll { $0.id == annotation.id }
            annotations.append(annotation)
        }
    }

    func remove(id: String) {
        withAnimation(.easeOut(duration: 0.25)) { annotations.removeAll { $0.id == id } }
    }

    func clearAnnotations() {
        withAnimation(.easeOut(duration: 0.2)) { annotations.removeAll { $0.kind != .blur } }
    }

    func clear() {
        withAnimation(.easeOut(duration: 0.25)) {
            annotations.removeAll()
            caption = nil
        }
    }

    func setCaption(_ text: String?, in area: CGRect, scale: CGFloat, atTop: Bool) {
        moveCaption(to: area, scale: scale)
        isCaptionAtTop = atTop
        withAnimation(.spring(duration: 0.35)) { caption = text }
    }

    func moveCaption(to area: CGRect, scale: CGFloat) {
        captionArea = area
        captionScale = scale
    }

    func moveCursor(to point: CGPoint, duration: TimeInterval) {
        guard cursor != nil, duration > 0 else {
            cursor = point
            return
        }
        withAnimation(.easeInOut(duration: duration)) { cursor = point }
    }

    func hideCursor() {
        cursor = nil
    }

    func ripple(at point: CGPoint) {
        let ripple = ClickRipple(point: point)
        ripples.append(ripple)
        Task { [weak self] in
            try? await Task.sleep(for: Self.rippleLifetime)
            self?.ripples.removeAll { $0.id == ripple.id }
        }
    }
}

@MainActor
final class DemoOverlay {
    let model = DemoOverlayModel()
    private var panels: [NSPanel] = []
    private var clickMonitor: Any?
    private var lastToolClick: (point: CGPoint, time: Date)?

    var isShown: Bool { !panels.isEmpty }

    func show(showsClicks: Bool, only display: CGRect? = nil) {
        if panels.isEmpty {
            panels = NSScreen.screens.filter { display == nil || ScreenGeometry.displayBounds(of: $0) == display }.map(makePanel)
        }
        if showsClicks, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                let point = ScreenGeometry.globalPoint(fromAppKit: NSEvent.mouseLocation, primaryHeight: ScreenGeometry.primaryHeight())
                MainActor.assumeIsolated { self?.userClicked(at: point) }
            }
        }
    }

    func hide() {
        model.clear()
        model.hideCursor()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    func toolClicked(at point: CGPoint) {
        lastToolClick = (point, Date())
        model.ripple(at: point)
    }

    private func userClicked(at point: CGPoint) {
        if let last = lastToolClick, Date().timeIntervalSince(last.time) < 0.5,
           hypot(last.point.x - point.x, last.point.y - point.y) < 6 { return }
        model.ripple(at: point)
    }

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DemoOverlayView(model: model, bounds: ScreenGeometry.displayBounds(of: screen)))
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }
}

struct DemoOverlayView: View {
    @ObservedObject var model: DemoOverlayModel
    let bounds: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.annotations.filter { $0.rect.intersects(bounds) }) { annotation in
                AnnotationShape(annotation: annotation, rect: local(annotation.rect), canvas: bounds.size, scale: model.captionScale)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            ForEach(model.ripples.filter { bounds.contains($0.point) }) { ripple in
                RippleView(color: Color(nsColor: DemoColor.accent))
                    .position(x: ripple.point.x - bounds.minX, y: ripple.point.y - bounds.minY)
            }
            if let cursor = model.cursor, bounds.contains(cursor) {
                FakeCursor().position(x: cursor.x - bounds.minX, y: cursor.y - bounds.minY)
            }
            if let caption = model.caption, bounds.contains(CGPoint(x: model.captionArea.midX, y: model.captionArea.midY)) {
                let area = local(model.captionArea)
                let atTop = model.isCaptionAtTop
                    || DemoOverlayView.captionBlocks(model.annotations, cursor: model.cursor, area: model.captionArea, scale: model.captionScale)
                CaptionView(text: caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: min(area.width / model.captionScale - 80, 1100))
                    .scaleEffect(model.captionScale, anchor: atTop ? .top : .bottom)
                    .position(x: area.midX, y: atTop ? area.minY + CaptionView.bottomInset * model.captionScale
                                                     : area.maxY - CaptionView.bottomInset * model.captionScale)
                    .transition(.opacity)
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }

    static func captionBlocks(_ annotations: [Annotation], cursor: CGPoint?, area: CGRect, scale: CGFloat) -> Bool {
        let band = CGRect(x: area.minX, y: area.maxY - CaptionView.bandHeight * scale, width: area.width, height: CaptionView.bandHeight * scale)
        if let cursor, band.insetBy(dx: 0, dy: -40 * scale).contains(cursor) { return true }
        return annotations.contains { $0.kind != .title && $0.kind != .spotlight && $0.rect.insetBy(dx: -20, dy: -50).intersects(band) }
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    }
}

private struct AnnotationShape: View {
    let annotation: Annotation
    let rect: CGRect
    let canvas: CGSize
    let scale: CGFloat
    @State private var progress: CGFloat = 0

    private var color: Color { Color(nsColor: annotation.color) }

    var body: some View {
        content
            .onAppear { withAnimation(.easeOut(duration: 0.45)) { progress = 1 } }
    }

    @ViewBuilder
    private var content: some View {
        switch annotation.kind {
        case .circle:
            let isWide = rect.width > rect.height * Annotation.wideRatio
            let ring = isWide ? rect.insetBy(dx: -10, dy: -8) : rect.insetBy(dx: -16, dy: -12)
            (isWide ? AnyShape(Capsule()) : AnyShape(Ellipse()))
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round))
                .shadow(color: color.opacity(0.6), radius: 8)
                .frame(width: ring.width, height: ring.height)
                .position(x: ring.midX, y: ring.midY)
            label(near: ring)
        case .box:
            let frame = rect.insetBy(dx: -8, dy: -8)
            RoundedRectangle(cornerRadius: 10).trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round))
                .shadow(color: color.opacity(0.5), radius: 6)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            label(near: frame)
        case .arrow:
            let points = ArrowGeometry.points(target: rect, canvas: canvas)
            ArrowShape(start: points.start, end: points.end).trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 6 * scale, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.35), radius: 4)
            if let text = annotation.text {
                Bubble(text: text, color: color, scale: scale).fixedSize().position(x: points.start.x, y: points.start.y + (points.start.y > points.end.y ? 28 : -28))
            }
        case .text:
            label(near: rect)
        case .step:
            HStack(spacing: 8) {
                Text("\(annotation.number ?? 1)")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(color).shadow(color: .black.opacity(0.35), radius: 4))
                    .scaleEffect(0.6 + 0.4 * progress)
                if let text = annotation.text {
                    Bubble(text: text, color: color).fixedSize()
                }
            }
            .fixedSize()
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: rect.minX - 20 * scale, y: rect.minY - 44 * scale)
        case .spotlight:
            let hole = rect.insetBy(dx: -14, dy: -14)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: canvas))
                path.addRoundedRect(in: hole, cornerSize: CGSize(width: 14, height: 14))
            }
            .fill(Color.black.opacity(0.55 * progress), style: FillStyle(eoFill: true))
            RoundedRectangle(cornerRadius: 14).stroke(color.opacity(progress), lineWidth: 3 * scale)
                .frame(width: hole.width, height: hole.height)
                .position(x: hole.midX, y: hole.midY)
            label(near: hole)
        case .blur:
            let frame = rect.insetBy(dx: -6, dy: -6)
            BlurBox()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        case .title:
            TitleCard(text: annotation.text ?? "")
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .opacity(progress)
        }
    }

    @ViewBuilder
    private func label(near frame: CGRect) -> some View {
        if let text = annotation.text {
            let below = frame.maxY + 70 < canvas.height
            Bubble(text: text, color: color, scale: scale)
                .fixedSize()
                .position(x: min(max(frame.midX, 220), canvas.width - 220), y: below ? frame.maxY + 34 : frame.minY - 34)
        }
    }
}

private struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head: CGFloat = 22
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        path.move(to: CGPoint(x: end.x - head * cos(angle - .pi / 7), y: end.y - head * sin(angle - .pi / 7)))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 7), y: end.y - head * sin(angle + .pi / 7)))
        return path
    }
}

private struct Bubble: View {
    let text: String
    let color: Color
    var scale: CGFloat = 1

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(color).shadow(color: .black.opacity(0.35), radius: 6, y: 2))
            .scaleEffect(scale)
    }
}

private struct TitleCard: View {
    let text: String

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        ZStack {
            Color.black.opacity(0.78)
            VStack(spacing: 14) {
                Text(lines.first ?? "").font(.system(size: 60, weight: .heavy, design: .rounded))
                ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 28, weight: .medium, design: .rounded)).opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(60)
        }
    }
}

private struct CaptionView: View {
    static let bottomInset: CGFloat = 70
    static let bandHeight: CGFloat = 150
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.78)))
    }
}

private struct BlurBox: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct FakeCursor: View {
    private static let image = NSCursor.arrow.image
    private static let hotSpot = NSCursor.arrow.hotSpot

    var body: some View {
        let size = Self.image.size
        Image(nsImage: Self.image)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .offset(x: size.width / 2 - Self.hotSpot.x, y: size.height / 2 - Self.hotSpot.y)
    }
}

private struct RippleView: View {
    let color: Color
    @State private var isExpanded = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(isExpanded ? 0 : 0.35))
            Circle().stroke(color.opacity(isExpanded ? 0 : 0.9), lineWidth: 3)
        }
        .frame(width: 56, height: 56)
        .scaleEffect(isExpanded ? 1.4 : 0.3)
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { isExpanded = true } }
    }
}
