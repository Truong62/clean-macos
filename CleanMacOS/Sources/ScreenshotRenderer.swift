import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct EditorWord: Equatable, Identifiable {
    var id: String { "\(text):\(rect)" }
    var text: String
    var rect: CGRect
    static func joined(_ words: [Self]) -> String {
        var rows: [[Self]] = []
        for word in words.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let index = rows.firstIndex(where: { row in
                guard let first = row.first else { return false }
                return abs(first.rect.midY - word.rect.midY) < min(first.rect.height, word.rect.height) * 0.5
            }) { rows[index].append(word) }
            else { rows.append([word]) }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }
}

enum ScreenshotRenderer {
    static func captureScale(_ data: Data) -> CGFloat {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? Double else { return 1 }
        return max(1, min(4, (dpi / 72).rounded()))
    }
    static func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
    static func context(_ size: CGSize) -> CGContext? {
        guard EditorGeometry.valid(size) else { return nil }
        return CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
    static func encode(_ image: CGImage, format: EditorFormat = .png, scale: CGFloat = 1) -> Data? {
        let data = NSMutableData()
        let type: CFString = (format == .png ? UTType.png.identifier : format == .jpeg ? UTType.jpeg.identifier : UTType.heic.identifier) as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
                                                       kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    static func resized(_ image: CGImage, size: CGSize) -> CGImage? {
        guard let context = context(size) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
    static func expanded(_ image: CGImage, rect: CGRect, fill: EditorColor) -> CGImage? {
        guard let ctx = context(rect.size) else { return nil }
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(fill.cgColor)
        ctx.fill(CGRect(origin: .zero, size: rect.size))
        drawImage(image, in: CGRect(x: -rect.minX, y: -rect.minY, width: CGFloat(image.width), height: CGFloat(image.height)), context: ctx)
        return ctx.makeImage()
    }
    static func render(_ document: ScreenshotDocument, settings: ScreenshotEditorSettings, words: [EditorWord]? = nil, background: Bool = true) -> CGImage? {
        guard let ctx = context(document.size), let base = decode(document.base) else { return nil }
        ctx.translateBy(x: 0, y: document.size.height)
        ctx.scaleBy(x: 1, y: -1)
        drawImage(base, in: document.bounds, context: ctx)
        let lastSpot = document.marks.lastIndex { $0.tool == .spotlight }
        for (index, mark) in document.marks.enumerated() {
            if mark.tool != .spotlight { draw(mark, document: document, settings: settings, context: ctx, words: words) }
            if index == lastSpot {
                ctx.saveGState()
                let path = CGMutablePath()
                path.addRect(document.bounds)
                ctx.addPath(path)
                ctx.clip()
                let mask = context(document.size)
                mask?.setFillColor(CGColor(gray: 0, alpha: 1))
                mask?.fill(document.bounds)
                mask?.translateBy(x: 0, y: document.size.height)
                mask?.scaleBy(x: 1, y: -1)
                for region in document.marks where region.tool == .spotlight { mask?.clear(region.rect) }
                if let image = mask?.makeImage() {
                    ctx.setAlpha(settings.dim)
                    drawImage(image, in: document.bounds, context: ctx)
                }
                ctx.restoreGState()
            }
        }
        drawWatermark(settings.watermark, document: document, settings: settings, context: ctx)
        guard let foreground = ctx.makeImage() else { return nil }
        let look = settings.background
        let margin = background && look.kind != .none ? EditorGeometry.margin(document.size, value: look.margin) : 0
        let size = CGSize(width: document.size.width + 2 * ceil(margin), height: document.size.height + 2 * ceil(margin))
        guard let output = context(size) else { return nil }
        output.translateBy(x: 0, y: size.height)
        output.scaleBy(x: 1, y: -1)
        let bounds = CGRect(origin: .zero, size: size)
        if background {
            switch look.kind {
            case .none: break
            case .solid:
                output.setFillColor(look.first.cgColor)
                output.fill(bounds)
            case .gradient:
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [look.first.cgColor, look.second.cgColor] as CFArray, locations: [0, 1]) {
                    output.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                }
            case .image:
                if let data = look.image, var image = decode(data) {
                    if look.blur > 0 {
                        let input = CIImage(cgImage: image)
                        let filtered = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: look.blur * 0.035 * min(size.width, size.height)]).cropped(to: input.extent)
                        image = CIContext().createCGImage(filtered, from: input.extent) ?? image
                    }
                    let factor = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
                    drawImage(image, in: CGRect(x: (size.width - CGFloat(image.width) * factor) / 2, y: (size.height - CGFloat(image.height) * factor) / 2,
                                               width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor), context: output)
                }
            }
        }
        let card = CGRect(origin: CGPoint(x: ceil(margin), y: ceil(margin)), size: document.size)
        let radius = EditorGeometry.corner(document.size, value: look.corners)
        let path = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if margin > 0 {
            output.saveGState()
            output.setShadow(offset: CGSize(width: 0, height: 6 * document.scale), blur: 22 * document.scale, color: CGColor(gray: 0, alpha: 0.4))
            output.addPath(path)
            output.setFillColor(CGColor(gray: 0, alpha: 1))
            output.fillPath()
            output.restoreGState()
        }
        output.addPath(path)
        output.clip()
        drawImage(foreground, in: card, context: output)
        guard let result = output.makeImage() else { return nil }
        if settings.export1x && document.scale > 1 {
            return resized(result, size: CGSize(width: floor(size.width / document.scale), height: floor(size.height / document.scale)))
        }
        return result
    }
    static func draw(_ mark: AnnotationMark, document: ScreenshotDocument, settings: ScreenshotEditorSettings, context ctx: CGContext, words: [EditorWord]?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let style = mark.style
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setFillColor(style.color.cgColor)
        ctx.setLineWidth(style.width * document.scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if settings.shadows && mark.tool.hasShadow && mark.image == nil { ctx.setShadow(offset: CGSize(width: 0, height: 2 * document.scale), blur: 4 * document.scale, color: CGColor(gray: 0, alpha: 0.45)) }
        if let data = mark.image, let image = decode(data) { drawImage(image, in: mark.rect, context: ctx); return }
        switch mark.tool {
        case .arrow, .line:
            ctx.move(to: mark.start)
            if style.head == .wobble && mark.tool == .arrow {
                let dx = mark.end.x - mark.start.x, dy = mark.end.y - mark.start.y
                let length = max(1, hypot(dx, dy))
                for i in 1...20 {
                    let t = CGFloat(i) / 20
                    let noise = sin(t * .pi * 6 + CGFloat(mark.seed % 100)) * sin(t * .pi) * style.width
                    ctx.addLine(to: CGPoint(x: mark.start.x + t * dx - dy / length * noise, y: mark.start.y + t * dy + dx / length * noise))
                }
            } else { ctx.addLine(to: mark.end) }
            ctx.strokePath()
            if mark.tool == .arrow {
                drawHead(mark.start, mark.end, style: style, scale: document.scale, context: ctx)
                if style.head == .double { drawHead(mark.end, mark.start, style: style, scale: document.scale, context: ctx) }
            }
        case .rectangle: ctx.stroke(mark.rect)
        case .ellipse: ctx.strokeEllipse(in: mark.rect)
        case .block: ctx.fill(mark.rect)
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(0.42)
            ctx.fill(mark.rect)
        case .pen:
            guard let first = mark.points.first else { return }
            ctx.move(to: first)
            for pair in zip(mark.points, mark.points.dropFirst()) {
                ctx.addQuadCurve(to: CGPoint(x: (pair.0.x + pair.1.x) / 2, y: (pair.0.y + pair.1.y) / 2), control: pair.0)
            }
            if let last = mark.points.last { ctx.addLine(to: last) }
            ctx.strokePath()
        case .text:
            drawText(mark.text, rect: mark.rect, size: style.fontSize * document.scale, color: style.color, context: ctx)
        case .sticker:
            drawText(style.sticker, rect: mark.rect, size: min(mark.rect.width, mark.rect.height) * 0.82, color: style.color, context: ctx, centered: true)
        case .number:
            ctx.fillEllipse(in: mark.rect)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(max(1, mark.rect.width * 0.06))
            ctx.strokeEllipse(in: mark.rect.insetBy(dx: 1, dy: 1))
            drawText(String(document.number(for: mark.id) ?? 1), rect: mark.rect, size: mark.rect.height * 0.56, color: .swatches[7], context: ctx, centered: true)
        case .blur:
            let areas = style.textOnly ? words.map { $0.map(\.rect).map { $0.intersection(mark.rect) }.filter { !$0.isNull } } ?? [mark.rect] : [mark.rect]
            guard let snapshot = ctx.makeImage() else { return }
            for area in areas { redact(snapshot, rect: area.intersection(document.bounds), style: style, seed: mark.seed, context: ctx) }
        default: break
        }
    }
    static func drawHead(_ a: CGPoint, _ b: CGPoint, style: AnnotationStyle, scale: CGFloat, context: CGContext) {
        let points = EditorGeometry.arrow(a, b, width: style.width * scale)
        context.addLines(between: points)
        if style.head == .open || style.head == .wobble { context.strokePath() }
        else {
            context.closePath()
            if style.head == .outlined { context.strokePath() } else { context.fillPath() }
        }
    }
    static func drawText(_ text: String, rect: CGRect, size: CGFloat, color: EditorColor, context: CGContext, centered: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor(cgColor: color.cgColor) ?? .white]
        let string = NSAttributedString(string: text, attributes: attributes)
        let natural = string.size()
        let point = centered ? CGPoint(x: rect.midX - natural.width / 2, y: rect.midY - natural.height / 2) : rect.origin
        string.draw(at: point)
        NSGraphicsContext.restoreGraphicsState()
    }
    static func redact(_ image: CGImage, rect: CGRect, style: AnnotationStyle, seed: UInt64, context ctx: CGContext) {
        let rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width > 0, rect.height > 0, let region = image.cropping(to: rect) else { return }
        let level = CGFloat(max(1, min(5, style.strength)))
        if style.redaction == .erase, let pixels = rgba(image) {
            guard let patch = context(rect.size), let data = patch.data else { return }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            let width = Int(rect.width), height = Int(rect.height)
            func sample(_ x: Int, _ y: Int, _ channel: Int) -> Double {
                Double(pixels[(min(image.height - 1, max(0, y)) * image.width + min(image.width - 1, max(0, x))) * 4 + channel])
            }
            for y in 0..<height {
                for x in 0..<width {
                    let u = Double(x + 1) / Double(width + 1), v = Double(y + 1) / Double(height + 1)
                    for c in 0..<4 {
                        let left = sample(Int(rect.minX) - 1, Int(rect.minY) + y, c), right = sample(Int(rect.maxX), Int(rect.minY) + y, c)
                        let top = sample(Int(rect.minX) + x, Int(rect.minY) - 1, c), bottom = sample(Int(rect.minX) + x, Int(rect.maxY), c)
                        bytes[y * patch.bytesPerRow + x * 4 + c] = UInt8(max(0, min(255, EditorGeometry.refill(left: left, right: right, top: top, bottom: bottom, u: u, v: v).rounded())))
                    }
                }
            }
            if let result = patch.makeImage() { drawImage(result, in: rect, context: ctx) }
        } else if style.redaction == .blur {
            let input = CIImage(cgImage: region)
            let output = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(10, min(rect.width, rect.height) / 55) * level]).cropped(to: input.extent)
            if let result = CIContext().createCGImage(output, from: input.extent) { drawImage(result, in: rect, context: ctx) }
        } else {
            let block = max(10, min(CGFloat(image.width), CGFloat(image.height)) / 55) * (0.5 + level * 0.5)
            let size = CGSize(width: max(1, ceil(rect.width / block)), height: max(1, ceil(rect.height / block)))
            if let small = resized(region, size: size), let noisy = context(size) {
                noisy.draw(small, in: CGRect(origin: .zero, size: size))
                if let data = noisy.data {
                    let bytes = data.assumingMemoryBound(to: UInt8.self)
                    var random = seed
                    for y in 0..<noisy.height {
                        for x in 0..<noisy.width {
                            for c in 0..<3 {
                                let i = y * noisy.bytesPerRow + x * 4 + c
                                random = random &* 6364136223846793005 &+ 1442695040888963407
                                bytes[i] = UInt8(max(0, min(Int(bytes[y * noisy.bytesPerRow + x * 4 + 3]), Int(bytes[i]) + Int((random >> 32) % 7) - 3)))
                            }
                        }
                    }
                }
                if let result = noisy.makeImage() {
                    ctx.interpolationQuality = .none
                    drawImage(result, in: rect, context: ctx)
                }
            }
        }
    }
    static func rgba(_ image: CGImage) -> [UInt8]? {
        guard let ctx = context(CGSize(width: image.width, height: image.height)) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).flatMap { y in Array(UnsafeBufferPointer(start: bytes + y * ctx.bytesPerRow, count: image.width * 4)) }
    }
    static func transparent(_ image: CGImage) -> Bool {
        guard let bytes = rgba(image) else { return true }
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] < 255 }
    }
    static func drawWatermark(_ watermark: EditorWatermark, document: ScreenshotDocument, settings: ScreenshotEditorSettings, context: CGContext) {
        guard watermark.kind != .none else { return }
        let short = min(document.size.width, document.size.height)
        let fontSize = max(8, short * (0.02 + 0.14 * watermark.size))
        let image = watermark.image.flatMap(decode)
        let text = String(watermark.text.prefix(120))
        let natural: CGSize
        if watermark.kind == .image, let image {
            let width = document.size.width * (0.05 + 0.45 * watermark.size)
            natural = CGSize(width: width, height: width * CGFloat(image.height) / CGFloat(image.width))
        } else { natural = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]) }
        let rect = EditorGeometry.watermark(natural, canvas: document.size, position: watermark.position,
                                            corners: EditorGeometry.corner(document.size, value: settings.background.corners), rotation: watermark.rotation)
        context.saveGState()
        context.clip(to: document.bounds)
        context.setAlpha(max(0.05, min(1, watermark.opacity)))
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: watermark.rotation * .pi / 180)
        let target = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        if settings.shadows { context.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: CGColor(gray: 0, alpha: 0.45)) }
        if watermark.kind == .image, let image { drawImage(image, in: target, context: context) }
        else { drawText(text, rect: target, size: fontSize * rect.width / max(1, natural.width), color: watermark.color, context: context) }
        context.restoreGState()
    }
}
