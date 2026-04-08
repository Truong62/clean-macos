#!/usr/bin/env swift

import AppKit

let sizes: [(CGFloat, String)] = [
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

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.22

    // Background gradient (blue)
    let path = CGPath(roundedRect: rect.insetBy(dx: size * 0.02, dy: size * 0.02),
                      cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.2, green: 0.45, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.35, green: 0.3, blue: 0.95, alpha: 1.0),
    ]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [])
    }

    // Subtle inner glow
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    let glowRect = CGRect(x: size * 0.1, y: size * 0.5, width: size * 0.8, height: size * 0.45)
    let glowPath = CGPath(roundedRect: glowRect, cornerWidth: size * 0.15, cornerHeight: size * 0.15, transform: nil)
    ctx.addPath(glowPath)
    ctx.fillPath()

    // Sparkles symbol
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: size * 0.4, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) {
        let symbolSize = symbol.size
        let x = (size - symbolSize.width) / 2
        let y = (size - symbolSize.height) / 2

        // White symbol
        let tinted = NSImage(size: symbolSize)
        tinted.lockFocus()
        NSColor.white.set()
        symbol.draw(in: NSRect(origin: .zero, size: symbolSize),
                    from: .zero, operation: .sourceOver, fraction: 1.0)
        NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
        tinted.unlockFocus()

        tinted.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height),
                    from: .zero, operation: .sourceOver, fraction: 0.95)
    }

    image.unlockFocus()
    return image
}

// Create output directory
let outputDir = "Sources/Assets.xcassets/AppIcon.appiconset"
let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// Generate icons
for (size, name) in sizes {
    let image = renderIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to generate \(name)")
        continue
    }
    let path = "\(outputDir)/\(name).png"
    try png.write(to: URL(fileURLWithPath: path))
    print("Generated \(name).png (\(Int(size))x\(Int(size)))")
}

// Generate Contents.json
let contents = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contents.write(toFile: "\(outputDir)/Contents.json", atomically: true, encoding: .utf8)
print("Generated Contents.json")
print("Done! AppIcon asset catalog created.")
