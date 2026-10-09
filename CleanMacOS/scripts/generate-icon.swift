#!/usr/bin/env swift

import AppKit
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185
let outputDir = "Sources/Assets.xcassets/AppIcon.appiconset"

let sizes: [(Int, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    let extent = radius * 1.528
    let exponent: CGFloat = 3.3
    let steps = 48
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
        (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
    ]
    let path = CGMutablePath()
    for (index, (corner, sx, sy)) in corners.enumerated() {
        let center = CGPoint(x: corner.x + sx * extent, y: corner.y + sy * extent)
        let startAngle = CGFloat(index) * .pi / 2
        for step in 0...steps {
            let t = startAngle + CGFloat(step) / CGFloat(steps) * .pi / 2
            let c = cos(t), s = sin(t)
            let x = center.x + extent * copysign(pow(abs(c), 2 / exponent), c)
            let y = center.y + extent * copysign(pow(abs(s), 2 / exponent), s)
            if index == 0 && step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
    }
    path.closeSubpath()
    return path
}

func sparklePath(center: CGPoint, radius: CGFloat, pinch: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let tips = (0..<4).map { i -> CGPoint in
        let a = CGFloat(i) * .pi / 2 + .pi / 2
        return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    }
    path.move(to: tips[0])
    for i in 0..<4 {
        let next = tips[(i + 1) % 4]
        let control = CGPoint(x: center.x + (tips[i].x - center.x + next.x - center.x) * pinch,
                              y: center.y + (tips[i].y - center.y + next.y - center.y) * pinch)
        path.addQuadCurve(to: next, control: control)
    }
    path.closeSubpath()
    return path
}

func drawBody(_ ctx: CGContext) {
    let shape = squirclePath(in: body, radius: cornerRadius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x2A2A2D), rgb(0x161618), rgb(0x050505)], [0, 0.55, 1]),
                           start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squirclePath(in: body.insetBy(dx: 2, dy: 2), radius: cornerRadius - 2))
    ctx.setLineWidth(4)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.strokePath()
    ctx.restoreGState()
}

func drawSwoosh(_ ctx: CGContext) {
    let center = CGPoint(x: 488, y: 500)
    let radius: CGFloat = 216
    let arc = CGMutablePath()
    arc.addArc(center: center, radius: radius, startAngle: .pi * 0.40, endAngle: -.pi * 0.27, clockwise: false)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: rgb(0x000000, 0.5))
    ctx.addPath(arc)
    ctx.setLineWidth(112)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.strokePath()
    ctx.restoreGState()
}

func drawSparkles(_ ctx: CGContext) {
    let big = sparklePath(center: CGPoint(x: 740, y: 720), radius: 124, pinch: 0.16)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: rgb(0xFF6A00, 0.45))
    ctx.addPath(big)
    ctx.setFillColor(rgb(0xFF7A00))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(big)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFA21A), rgb(0xFF5E00)], [0, 1]),
                           start: CGPoint(x: 676, y: 844), end: CGPoint(x: 804, y: 596), options: [])
    ctx.restoreGState()

    ctx.addPath(sparklePath(center: CGPoint(x: 800, y: 500), radius: 52, pinch: 0.16))
    ctx.setFillColor(rgb(0xFF8A00))
    ctx.fillPath()
}

func renderIcon(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawBody(ctx)
    drawSwoosh(ctx)
    drawSparkles(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "generate-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create \(path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "generate-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(path)"])
    }
}

try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
for (pixels, name) in sizes {
    try writePNG(renderIcon(pixels: pixels), to: "\(outputDir)/\(name).png")
    print("Generated \(name).png (\(pixels)x\(pixels))")
}
