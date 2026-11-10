import Foundation
import CoreGraphics
import Testing
@testable import CleanMacOS

struct ScreenshotTests {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)

    @Test func reversedAndClampedDrag() {
        #expect(CaptureGeometry.drag(from: CGPoint(x: 150, y: 80), to: CGPoint(x: -10, y: -20), bounds: bounds) == CGRect(x: 0, y: 0, width: 150, height: 80))
    }

    @Test func squareCenteredAndMove() {
        let rect = CaptureGeometry.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 80, y: 70), bounds: bounds, square: true, centered: true)
        #expect(rect == CGRect(x: 30, y: 30, width: 40, height: 40))
        #expect(CaptureGeometry.move(rect, dx: 300, dy: -300, bounds: bounds) == CGRect(x: 160, y: 0, width: 40, height: 40))
    }

    @Test func resizeAspectAndEvenPixelSnap() {
        let resized = CaptureGeometry.resize(CGRect(x: 10, y: 10, width: 20, height: 20), handle: CGPoint(x: 1, y: 1), to: CGPoint(x: 70, y: 80), bounds: bounds, aspect: 2)
        #expect(resized == CGRect(x: 10, y: 10, width: 60, height: 30))
        let pixels = CaptureGeometry.pixels(CGRect(x: 1.8, y: 3.2, width: 41.7, height: 30.8), scale: 2, even: true)
        #expect(pixels == CGRect(x: 2, y: 6, width: 82, height: 60))
    }

    @Test func mappingAndNudging() {
        let pixel = CaptureGeometry.pixel(at: CGPoint(x: 50, y: 25), size: CGSize(width: 100, height: 50), imageSize: CGSize(width: 200, height: 100))
        #expect(pixel == CGPoint(x: 100, y: 50))
        #expect(CaptureGeometry.nudge(pixel, x: 1, y: -1, shift: true, size: CGSize(width: 105, height: 100)) == CGPoint(x: 104, y: 40))
        #expect(CaptureGeometry.pixel(at: CGPoint(x: -5, y: 500), size: bounds.size, imageSize: bounds.size) == CGPoint(x: 0, y: 99))
    }

    @Test func zoomBoundsAndSteps() {
        #expect(CaptureGeometry.zoom(1, delta: 1, stepped: true) == 2)
        #expect(CaptureGeometry.zoom(1, delta: -1, stepped: true) == 0.5)
        #expect(CaptureGeometry.zoom(4, delta: 100, stepped: false) == 4.3)
        #expect(CaptureGeometry.zoom(1, delta: -100, stepped: false) == 0.5)
        #expect(CaptureGeometry.zoom(2, delta: 0, stepped: true) == 2)
    }

    @Test func sampleSyntheticImage() throws {
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let color = try #require(CaptureGeometry.sample(image, at: CGPoint(x: 1, y: 0)))
        #expect(color.green == 1)
        #expect(color.red == 0)
        #expect(color.blue == 0)
        #expect(CaptureGeometry.sample(image, at: CGPoint(x: 2, y: 0)) == nil)
    }

    @Test func ocrRepeatOnlyOnConnectedDisplay() {
        var regions = CaptureRegions()
        let area = CGRect(x: 10, y: 10, width: 40, height: 30)
        regions.remember(area, display: 42)
        regions.remember(.zero, display: 42)
        #expect(regions.repeatArea(display: 42, bounds: bounds, connected: [42]) == area)
        #expect(regions.repeatArea(display: 42, bounds: bounds, connected: [7]) == nil)
        #expect(regions.repeatArea(display: 42, bounds: CGRect(x: 0, y: 0, width: 20, height: 20), connected: [42]) == nil)
    }

    @Test func hitTestSkipsDecorationAndLayers() {
        let decoration = CaptureWindow(id: 1, owner: 10, title: "", frame: bounds)
        let inner = CaptureWindow(id: 2, owner: 10, title: "Document", frame: bounds.insetBy(dx: 10, dy: 10))
        let menu = CaptureWindow(id: 3, owner: 11, title: "Menu", frame: bounds, layer: 10)
        let transparent = CaptureWindow(id: 4, owner: 12, title: "Hidden", frame: bounds, alpha: 0.01)
        #expect(CaptureWindows.hit(CGPoint(x: 30, y: 30), windows: [menu, transparent, decoration, inner], excluding: [])?.id == 2)
        #expect(CaptureWindows.hit(CGPoint(x: 30, y: 30), windows: [inner], excluding: [2]) == nil)
    }

    @Test func sheetsOnlyComeFromSameAppAndFrontOfParent() {
        let parent = CaptureWindow(id: 1, owner: 10, title: "Parent", frame: bounds)
        let sheet = CaptureWindow(id: 2, owner: 10, title: "Sheet", frame: bounds.insetBy(dx: 20, dy: 20))
        let other = CaptureWindow(id: 3, owner: 11, title: "Other", frame: sheet.frame)
        #expect(CaptureWindows.sheets(for: parent, windows: [other, sheet, parent]).map(\.id) == [2])
        #expect(CaptureWindows.sheets(for: parent, windows: [parent, sheet]).isEmpty)
        #expect(CaptureWindows.sheets(for: parent, windows: [sheet, parent], standardIDs: [2]).isEmpty)
    }

    @Test func defaultsAndLegacySettings() throws {
        let decoded = try JSONDecoder().decode(ScreenshotSettings.self, from: Data("{}".utf8))
        #expect(decoded == ScreenshotSettings())
        let fields = Mirror(reflecting: decoded).children.compactMap { $0.value as? Bool }
        #expect(fields.allSatisfy { !$0 })
        let legacy = try JSONDecoder().decode(ScreenshotSettings.self, from: Data(#"{"areaShortcut":true,"counter":12}"#.utf8))
        #expect(legacy.areaShortcut)
        #expect(legacy.counter == 12)
        #expect(!legacy.menuTile)
        #expect(try JSONDecoder().decode(ScreenshotSettings.self, from: JSONEncoder().encode(legacy)) == legacy)
    }

    @Test func legacyScreenToolSettingsPreservePreferences() throws {
        let data = Data(#"{"colorFormat":"rgb","dropsHash":true,"colorShortcut":true,"textShortcut":false,"removesLineBreaks":true,"detectsCodes":false}"#.utf8)
        let settings = try JSONDecoder().decode(ScreenToolSettings.self, from: data)
        #expect(settings.colorFormat == .rgb)
        #expect(settings.dropsHash)
        #expect(settings.colorShortcut)
        #expect(settings.removesLineBreaks)
        #expect(!settings.detectsCodes)
        #expect(!settings.showsColorModes)
        #expect(!settings.showsTextModes)
        #expect(try JSONDecoder().decode(ScreenToolSettings.self, from: Data("{}".utf8)) == ScreenToolSettings())
    }

    @Test func invalidPersistedOptionsAreClamped() throws {
        let decoded = try JSONDecoder().decode(ScreenshotSettings.self, from: Data(#"{"delay":99,"zoom":100,"counter":-1}"#.utf8))
        #expect(decoded.delay == 0)
        #expect(decoded.zoom == 4.3)
        #expect(decoded.counter == 0)
    }

    @Test func namingAndSubfolderTraversal() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(CaptureNames.filename(pattern: "", date: date, counter: 1, timeZone: TimeZone(secondsFromGMT: 0)!) == "Screenshot 1970-01-01 at 00.00.00.png")
        #expect(CaptureNames.filename(pattern: "Shot/{nnn}:test", date: date, counter: 7) == "Shot-007-test.png")
        #expect(CaptureNames.subfolders("/.././folder//child", date: date) == ["folder", "child"])
        #expect(CaptureNames.usesCounter("capture {nnn}"))
        #expect(!CaptureNames.usesCounter("capture {yyyy}"))
    }

    @Test func collisionsUseTemporaryDirectory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let proposed = folder.appendingPathComponent("Screenshot.png")
        try Data().write(to: proposed)
        let next = CaptureNames.available(proposed) { FileManager.default.fileExists(atPath: $0.path) }
        #expect(next?.lastPathComponent == "Screenshot 2.png")
    }

    @Test func legacyHistoryAndSharedRetention() throws {
        let entry = try JSONDecoder().decode(CaptureHistoryEntry.self, from: Data(#"{"filename":"old.png","bytes":123,"scale":2}"#.utf8))
        #expect(entry.kind == .screenshot)
        #expect(entry.scale == 2)
        let movie = CaptureHistoryEntry(id: UUID(), date: Date(timeIntervalSince1970: 2), filename: "recording.mp4", bytes: 900_000_000, scale: 1, kind: .recording)
        let screenshot = CaptureHistoryEntry(id: UUID(), date: Date(timeIntervalSince1970: 1), filename: "image.png", bytes: 100, scale: 1)
        #expect(CaptureRetention.keep([movie, screenshot], bytes: 200).count == 2)
    }

    @Test func retentionAlwaysKeepsNewest() {
        let entries = (0..<20).map { CaptureHistoryEntry(id: UUID(), date: Date(timeIntervalSince1970: Double($0)), filename: "\($0).png", bytes: 100, scale: 2) }
        #expect(CaptureRetention.keep(entries).count == 12)
        #expect(CaptureRetention.keep(entries, bytes: 50).map(\.filename) == ["19.png"])
        #expect(CaptureRetention.keep(entries, bytes: 250).count == 2)
    }

    func frame(offset: Int, footer: Int = 0) -> GrayFrame {
        let width = 40
        let height = 100
        let pixels: [UInt8] = (0..<(width * height)).map { index in
            let y = index / width
            let x = index % width
            if y >= height - footer { return 200 }
            let value = (y + offset) * 7919 + x * 104729
            return UInt8(truncatingIfNeeded: (value ^ (value >> 7) ^ (value >> 13)))
        }
        return GrayFrame(width: width, height: height, pixels: pixels)
    }

    @Test func overlapDetectsMotionAndRejectsUpwardAndBlank() {
        #expect(ScrollOverlap.shift(previous: frame(offset: 0), next: frame(offset: 20)) == 20)
        #expect(ScrollOverlap.shift(previous: frame(offset: 20), next: frame(offset: 0)) == nil)
        let blank = GrayFrame(width: 40, height: 100, pixels: Array(repeating: 42, count: 4000))
        #expect(ScrollOverlap.shift(previous: blank, next: blank) == nil)
        #expect(ScrollOverlap.shift(previous: frame(offset: 0), next: frame(offset: 0)) == nil)
    }

    @Test func footerDetection() {
        #expect(ScrollOverlap.fixedFooter(previous: frame(offset: 0, footer: 6), next: frame(offset: 20, footer: 6)) == 6)
        #expect(ScrollOverlap.shift(previous: frame(offset: 0, footer: 6), next: frame(offset: 20, footer: 6)) == 20)
    }

    @Test func budgetsEnforceTimeFramesAndPixels() {
        let start = Date(timeIntervalSince1970: 0)
        var budget = ScrollBudget(width: 1000, started: start)
        let result1 = budget.accept(rows: 1000, now: start)
        #expect(result1)
        let result2 = !budget.accept(rows: 60_000, now: start)
        #expect(result2)
        let result3 = !budget.accept(rows: 10, now: start.addingTimeInterval(120))
        #expect(result3)
        budget.frames = 512
        let result4 = !budget.accept(rows: 0, now: start)
        #expect(result4)
    }
}

struct ScreenshotPolicyTests {
    @Test func scrollingBackNeverDuplicates() {
        let fixture = ScreenshotTests()
        var tracker = ScrollTracker()
        let result5 = tracker.ingest(fixture.frame(offset: 0)) == .append(100, 0)
        #expect(result5)
        let result6 = tracker.ingest(fixture.frame(offset: 20)) == .append(20, 0)
        #expect(result6)
        let result7 = tracker.ingest(fixture.frame(offset: 0)) == .repositioned
        #expect(result7)
        let result8 = tracker.ingest(fixture.frame(offset: 20)) == .repositioned
        #expect(result8)
        let result9 = tracker.ingest(fixture.frame(offset: 40)) == .append(20, 0)
        #expect(result9)
        let result10 = tracker.ingest(fixture.frame(offset: 40)) == .unchanged
        #expect(result10)
        #expect(tracker.furthest == 40)
    }

    @Test func placementStaysInsideScreen() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let size = CGSize(width: 350, height: 210)
        for corner in CaptureCorner.allCases {
            let point = CapturePlacement.preview(size: size, screen: screen, area: CGRect(x: -100, y: 1000, width: 100, height: 80),
                                                 pointer: CGPoint(x: -1, y: 1070), corner: corner)
            #expect(screen.contains(CGRect(origin: point, size: size)))
        }
        let point = CapturePlacement.preview(size: size, screen: screen, area: CGRect(x: -1600, y: 300, width: 100, height: 100), pointer: .zero, corner: .auto)
        #expect(point.x == -1486)
    }

    @Test func linkValidation() throws {
        let now = Date(timeIntervalSince1970: 100)
        #expect(CaptureLinkPolicy.endpoint("http://example.com") == nil)
        #expect(CaptureLinkPolicy.endpoint("https://user:secret@example.com") == nil)
        #expect(CaptureLinkPolicy.endpoint("https://example.com/api") != nil)
        let link = CaptureLink(id: "id", url: try #require(URL(string: "https://example.com/share/id")), expiresAt: now.addingTimeInterval(3600), deleteToken: "token")
        #expect(CaptureLinkPolicy.validate(link, now: now))
        #expect(!CaptureLinkPolicy.validate(link, now: now.addingTimeInterval(3601)))
        #expect(CaptureLinkPolicy.live([link], now: now.addingTimeInterval(3601)).isEmpty)
        #expect(CaptureLinkPolicy.maxBytes == 26_214_400)
    }

    @Test func transparentBordersAreTrimmed() throws {
        let context = try #require(CGContext(data: nil, width: 10, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 2, y: 1, width: 6, height: 5))
        let image = try #require(context.makeImage())
        let trimmed = CaptureImages.trimTransparent(image)
        #expect(trimmed.width == 6)
        #expect(trimmed.height == 5)
    }

    @Test func pngRoundtripAndRows() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        #expect(CaptureImages.resized(image, factor: 0.5).width == 4)
        #expect(CaptureImages.png(image, scale: 2)?.isEmpty == false)
        let appended = try #require(CaptureImages.append(image, frame: image, rows: 2, footer: 0))
        #expect(appended.width == 8)
        #expect(appended.height == 10)
        #expect(CaptureGeometry.sample(appended, at: CGPoint(x: 2, y: 9))?.red == 1)
    }
}
