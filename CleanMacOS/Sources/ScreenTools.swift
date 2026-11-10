import AppKit
import ImageIO
import KeyboardShortcuts
import SwiftUI
import Vision

enum PickedColorFormat: String, Codable, CaseIterable, Identifiable {
    case hex, rgb, hsl, swiftUI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .swiftUI: "SwiftUI"
        }
    }

    func text(_ color: ClipboardColor, dropsHash: Bool) -> String {
        switch self {
        case .hex:
            let hex = ColorFormats.hex(color)
            return dropsHash ? String(hex.dropFirst()) : hex
        case .rgb:
            return ColorFormats.rgb(color)
        case .hsl:
            return ColorFormats.hsl(color)
        case .swiftUI:
            let base = String(format: "Color(red: %.3f, green: %.3f, blue: %.3f", color.red, color.green, color.blue)
            return color.alpha < 1 ? base + String(format: ", opacity: %.3f)", color.alpha) : base + ")"
        }
    }
}

struct TextLine: Equatable {
    let text: String
    let box: CGRect
}

enum TextLayout {
    static let rowTolerance: CGFloat = 0.5

    static func join(_ lines: [TextLine], removesLineBreaks: Bool) -> String {
        var rows: [[TextLine]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first, abs(first.box.midY - line.box.midY) < min(first.box.height, line.box.height) * rowTolerance {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        let ordered = rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }.map(\.text)
        guard removesLineBreaks else { return ordered.joined(separator: "\n") }
        return ordered.reduce("") { result, next in
            guard let last = result.last, let first = next.first else { return result + next }
            return result + (isCJK(last) && isCJK(first) ? "" : " ") + next
        }
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            [0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF].contains { $0.contains(scalar.value) }
        }
    }
}

struct CodeResult: Equatable {
    let payload: String

    var link: URL? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

enum TextRecognizer {
    enum Result: Equatable {
        case code(CodeResult)
        case text(String)
        case nothing
    }

    static let maxPixels = 24_000_000
    static let symbologies: [VNBarcodeSymbology] = [.qr, .microQR, .aztec, .dataMatrix, .pdf417]

    static func recognize(_ image: CGImage, detectsCodes: Bool, removesLineBreaks: Bool) -> Result {
        let image = downscaled(image)
        let handler = VNImageRequestHandler(cgImage: image)
        if detectsCodes {
            let request = VNDetectBarcodesRequest()
            request.symbologies = symbologies
            try? handler.perform([request])
            if let payload = request.results?.compactMap(\.payloadStringValue).first(where: { !$0.isEmpty }) { return .code(CodeResult(payload: payload)) }
        }
        let text = recognizeText(image, removesLineBreaks: removesLineBreaks)
        return text.isEmpty ? .nothing : .text(text)
    }

    static func recognizeText(_ image: CGImage, removesLineBreaks: Bool, levels: [VNRequestTextRecognitionLevel] = [.accurate, .fast]) -> String {
        let handler = VNImageRequestHandler(cgImage: downscaled(image))
        for level in levels {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
            let wanted = (Locale.preferredLanguages.prefix(1) + ["en-US"]).filter { supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
            try? handler.perform([request])
            let lines = (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { TextLine(text: $0.string, box: observation.boundingBox) }
            }
            let text = TextLayout.join(lines, removesLineBreaks: removesLineBreaks)
            if !text.isEmpty { return text }
        }
        return ""
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func downscaled(_ image: CGImage) -> CGImage {
        let pixels = image.width * image.height
        guard pixels > maxPixels else { return image }
        let scale = (Double(maxPixels) / Double(pixels)).squareRoot()
        let width = Int(Double(image.width) * scale)
        let height = Int(Double(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

struct ScreenToolSettings: Codable, Equatable {
    var colorFormat = PickedColorFormat.hex
    var dropsHash = false
    var colorShortcut = false
    var textShortcut = false
    var removesLineBreaks = false
    var detectsCodes = true
}

@MainActor
final class ScreenTools: ObservableObject {
    static let settingsKey = "screenTools.settings"
    static let messageTime: TimeInterval = 1.5

    @Published var settings: ScreenToolSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            applyShortcuts()
        }
    }
    @Published private(set) var lastColor: String?

    private var captureToken = 0
    private var codePanel: NSPanel?
    private let hud = InputHUD()

    init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(ScreenToolSettings.self, from: $0) }
            ?? ScreenToolSettings()
        KeyboardShortcuts.onKeyUp(for: .pickColor) { [weak self] in MainActor.assumeIsolated { self?.pickColor() } }
        KeyboardShortcuts.onKeyUp(for: .grabText) { [weak self] in MainActor.assumeIsolated { self?.grabText() } }
        applyShortcuts()
    }

    func pickColor() {
        NSColorSampler().show { [weak self] picked in
            MainActor.assumeIsolated {
                guard let self, let picked, let rgb = picked.usingColorSpace(.sRGB) else { return }
                let color = ClipboardColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
                let text = self.settings.colorFormat.text(color, dropsHash: self.settings.dropsHash)
                Self.copy(text)
                self.lastColor = text
                self.hud.show("Copied \(text)", for: Self.messageTime, color: rgb)
            }
        }
    }

    func grabText() {
        captureToken += 1
        let token = captureToken
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mackit-grab-\(UUID().uuidString).png")
        let changeCount = NSPasteboard.general.changeCount
        let detectsCodes = settings.detectsCodes
        let removesLineBreaks = settings.removesLineBreaks
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CommandRunner.run("/usr/sbin/screencapture", ["-i", "-x", "-o", file.path])
            defer { try? FileManager.default.removeItem(at: file) }
            guard let image = TextRecognizer.image(at: file) else { return }
            let result = TextRecognizer.recognize(image, detectsCodes: detectsCodes, removesLineBreaks: removesLineBreaks)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(result, token: token, changeCount: changeCount) }
            }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func finish(_ result: TextRecognizer.Result, token: Int, changeCount: Int) {
        guard token == captureToken, NSPasteboard.general.changeCount == changeCount else { return }
        switch result {
        case .code(let code):
            showCode(code)
        case .text(let text):
            Self.copy(text)
            hud.show("Text copied", for: Self.messageTime)
        case .nothing:
            hud.show("No text found", for: Self.messageTime)
        }
    }

    private func showCode(_ code: CodeResult) {
        codePanel?.orderOut(nil)
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled, .closable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: CodeResultView(code: code) { [weak panel] in panel?.orderOut(nil) })
        panel.center()
        codePanel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func applyShortcuts() {
        if settings.colorShortcut { KeyboardShortcuts.enable([.pickColor]) } else { KeyboardShortcuts.disable([.pickColor]) }
        if settings.textShortcut { KeyboardShortcuts.enable([.grabText]) } else { KeyboardShortcuts.disable([.grabText]) }
    }
}

struct CodeResultView: View {
    let code: CodeResult
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Code found", systemImage: "qrcode").font(.headline)
            ScrollView {
                Text(code.payload).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 70)
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Copy") {
                    ScreenTools.copy(code.payload)
                    close()
                }
                if let link = code.link {
                    Button("Open") {
                        NSWorkspace.shared.open(link)
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}
