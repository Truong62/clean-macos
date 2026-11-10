import CoreGraphics
import Foundation
import Testing
@testable import CleanMacOS

struct ScreenToolsTests {
    private let orange = ClipboardColor(red: 1, green: 0.5333, blue: 0, alpha: 1)

    @Test func formatsPickedColors() {
        #expect(PickedColorFormat.hex.text(orange, dropsHash: false) == "#FF8800")
        #expect(PickedColorFormat.hex.text(orange, dropsHash: true) == "FF8800")
        #expect(PickedColorFormat.rgb.text(orange, dropsHash: false) == "rgb(255, 136, 0)")
        #expect(PickedColorFormat.hsl.text(orange, dropsHash: false) == "hsl(32, 100%, 50%)")
        #expect(PickedColorFormat.swiftUI.text(orange, dropsHash: false) == "Color(red: 1.000, green: 0.533, blue: 0.000)")
    }

    @Test func ordersRecognisedLinesTopToBottomThenLeftToRight() {
        let lines = [
            TextLine(text: "right", box: CGRect(x: 0.6, y: 0.8, width: 0.3, height: 0.05)),
            TextLine(text: "second line", box: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.05)),
            TextLine(text: "left", box: CGRect(x: 0.1, y: 0.805, width: 0.3, height: 0.05)),
        ]
        #expect(TextLayout.join(lines, removesLineBreaks: false) == "left\nright\nsecond line")
        #expect(TextLayout.join(lines, removesLineBreaks: true) == "left right second line")
        let cjk = [TextLine(text: "你好", box: CGRect(x: 0, y: 0.9, width: 0.2, height: 0.05)), TextLine(text: "世界", box: CGRect(x: 0, y: 0.5, width: 0.2, height: 0.05))]
        #expect(TextLayout.join(cjk, removesLineBreaks: true) == "你好世界")
        #expect(TextLayout.join([], removesLineBreaks: false) == "")
    }

    @Test func recognisesASingleWebLink() {
        #expect(CodeResult(payload: "https://example.com/a").link?.absoluteString == "https://example.com/a")
        #expect(CodeResult(payload: "WIFI:S:home;T:WPA;P:secret;;").link == nil)
        #expect(CodeResult(payload: "see https://a.com and https://b.com").link == nil)
    }
}

import AppKit
import CoreImage

struct VisionRecognitionTests {
    private func render(_ text: String) -> CGImage {
        let size = NSSize(width: 900, height: 220)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(at: NSPoint(x: 40, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 56, weight: .medium), .foregroundColor: NSColor.black])
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    @Test func readsRenderedText() {
        let result = TextRecognizer.recognize(render("Hello MacKit 2026"), detectsCodes: true, removesLineBreaks: false)
        guard case .text(let text) = result else { return #expect(Bool(false), "got \(result)") }
        #expect(text.contains("Hello MacKit 2026"))
    }

    @Test func decodesQRCodesFirst() throws {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://example.com/qr".utf8), forKey: "inputMessage")
        let output = try #require(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)))
        let padded = output.composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -60, dy: -60)))
        let image = try #require(CIContext().createCGImage(padded, from: padded.extent))
        #expect(TextRecognizer.recognize(image, detectsCodes: true, removesLineBreaks: false) == .code(CodeResult(payload: "https://example.com/qr")))
    }
}
