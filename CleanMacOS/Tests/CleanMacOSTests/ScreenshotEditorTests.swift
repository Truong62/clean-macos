import Testing
import Foundation
import AppKit
import ImageIO
@testable import CleanMacOS

struct ScreenshotEditorTests {
    private func document(_ size: CGSize = CGSize(width: 100, height: 80)) -> ScreenshotDocument {
        ScreenshotDocument(base: Data([1]), size: size)
    }
    private func mark(_ tool: AnnotationTool = .rectangle, from: CGPoint = .zero, to: CGPoint = CGPoint(x: 40, y: 30)) -> AnnotationMark {
        AnnotationMark(tool: tool, start: from, end: to)
    }
    private func fixture(width: Int = 100, height: Int = 80, color: EditorColor = .swatches[7]) throws -> ScreenshotDocument {
        let size = CGSize(width: width, height: height)
        let context = try #require(ScreenshotRenderer.context(size))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        return ScreenshotDocument(base: try #require(ScreenshotRenderer.encode(image)), size: size)
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try #require(ScreenshotRenderer.rgba(image))
        return Array(data[((y * image.width + x) * 4)..<((y * image.width + x) * 4 + 4)])
    }
    @Test func optInDefaultsAndRoundTrip() throws {
        let settings = ScreenshotEditorSettings()
        #expect(!settings.toolKeys && !settings.fileShortcut && !settings.clipboardShortcut)
        #expect(!settings.shadows && !settings.export1x && !settings.style.textOnly)
        #expect(settings.background.kind == .none && settings.watermark.kind == .none)
        #expect(settings.style.strength == 3 && settings.style.width == 4 && settings.style.fontSize == 19)
        #expect(try JSONDecoder().decode(ScreenshotEditorSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
    @Test func missingSettingsFieldsKeepSavedPreferences() throws {
        let settings = try JSONDecoder().decode(ScreenshotEditorSettings.self, from: Data("{\"namePrefix\":\"My Image\",\"shadows\":true}".utf8))
        #expect(settings.namePrefix == "My Image" && settings.shadows)
        #expect(!settings.toolKeys && !settings.clipboardShortcut && settings.background.kind == .none)
        #expect(settings.toolOrder == AnnotationTool.allCases)
    }
    @Test func digitAssignmentMovesToolAndDetectsOwners() throws {
        let settings = ScreenshotEditorSettings()
        let updated = try EditorKeyMap.assigning("2", to: .pen, settings: settings).get()
        #expect(updated.toolOrder[1] == .pen && Set(updated.toolOrder).count == 15)
        let custom = try EditorKeyMap.assigning("x", to: .pen, settings: settings).get()
        #expect(try EditorKeyMap.assigning("x", to: .pen, settings: custom).get() == custom)
        #expect(throws: EditorKeyMap.Conflict.self) { try EditorKeyMap.assigning("x", to: .arrow, settings: custom).get() }
        #expect(throws: EditorKeyMap.Conflict.self) { try EditorKeyMap.assigning("x", to: .arrow, settings: settings, external: ["x": "Global shortcut"]).get() }
    }
    @Test func defaultToolOrderAndFallbacks() {
        #expect(AnnotationTool.allCases.count == 15)
        #expect(Array(AnnotationTool.allCases.prefix(9)) == [.select, .arrow, .blur, .crop, .text, .sticker, .rectangle, .highlighter, .pen])
        for tool in [AnnotationTool.select, .crop, .expand] { #expect(tool.openingTool == .arrow) }
        #expect(AnnotationTool.blur.openingTool == .blur)
        #expect(AnnotationStyle.fontSizes.count == 12)
        #expect(AnnotationStyle.stickers.count == 12)
    }
    @Test func historyLimitsAndBranching() {
        var history = EditorHistory(document())
        for i in 1...65 { var next = history.document; next.scale = CGFloat(i + 1); history.commit(next) }
        #expect(history.past.count == 60)
        history.undo()
        #expect(history.document.scale == 65 && history.future.count == 1)
        history.redo()
        #expect(history.document.scale == 66)
        history.undo()
        var next = history.document
        next.marks.append(mark())
        history.commit(next)
        #expect(history.future.isEmpty)
        history.commit(next)
        #expect(history.past.count == 60)
    }
    @Test func baseAndMarksUndoTogether() {
        let original = document()
        var history = EditorHistory(original)
        var next = original
        next.marks.append(mark())
        next.replaceBase(Data([2]), size: CGSize(width: 200, height: 90), offset: CGSize(width: 10, height: 5))
        history.commit(next)
        #expect(history.document.marks[0].start == CGPoint(x: 10, y: 5))
        history.undo()
        #expect(history.document == original)
        history.redo()
        #expect(history.document == next)
    }
    @Test func numbersFollowZOrderAndDelete() {
        var doc = document()
        let a = mark(.number), b = mark(.number), shape = mark()
        doc.marks = [a, shape, b]
        #expect(doc.number(for: a.id) == 1 && doc.number(for: b.id) == 2)
        doc.reorder(b.id, by: -2)
        #expect(doc.number(for: b.id) == 1)
        doc.remove(b.id)
        #expect(doc.number(for: a.id) == 1 && doc.number(for: shape.id) == nil)
    }
    @Test func arrowHeadGeometry() {
        let points = EditorGeometry.arrow(.zero, CGPoint(x: 100, y: 0), width: 4)
        #expect(points.count == 3)
        #expect(points[1] == CGPoint(x: 100, y: 0))
        #expect(abs(hypot(points[0].x - 100, points[0].y) - 13.6) < 0.001)
        #expect(abs(points[0].y + points[2].y) < 0.001)
        #expect(EditorGeometry.arrow(.zero, .zero, width: 0).allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }
    @Test func lineHitTestingAndZeroLength() {
        let line = mark(.line, from: .zero, to: CGPoint(x: 100, y: 0))
        #expect(EditorGeometry.hit(CGPoint(x: 50, y: 5), marks: [line], tolerance: 5) == line.id)
        #expect(EditorGeometry.hit(CGPoint(x: 50, y: 20), marks: [line], tolerance: 5) == nil)
        #expect(EditorGeometry.distance(CGPoint(x: 3, y: 4), to: .zero, .zero) == 5)
    }
    @Test func topmostHitAndEdgeOnly() {
        let a = mark(.block), b = mark(.highlighter)
        #expect(EditorGeometry.hit(CGPoint(x: 20, y: 15), marks: [a, b], tolerance: 2) == b.id)
        #expect(EditorGeometry.hit(CGPoint(x: 20, y: 15), marks: [a], tolerance: 2, edgeOnly: true) == nil)
        #expect(EditorGeometry.hit(CGPoint(x: 1, y: 15), marks: [a], tolerance: 2, edgeOnly: true) == a.id)
    }
    @Test func ellipseAndPenHitTesting() {
        let ellipse = mark(.ellipse)
        #expect(EditorGeometry.hit(CGPoint(x: 20, y: 0), marks: [ellipse], tolerance: 2) == ellipse.id)
        #expect(EditorGeometry.hit(CGPoint(x: 20, y: 15), marks: [ellipse], tolerance: 2) == nil)
        var pen = mark(.pen)
        pen.points = [.zero, CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 5)]
        #expect(EditorGeometry.hit(CGPoint(x: 10, y: 11), marks: [pen], tolerance: 2) == pen.id)
    }
    @Test func resizeHandlesFlipAndAspect() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        #expect(EditorGeometry.handles(rect).count == 8)
        let flipped = EditorGeometry.resized(rect, handle: 0, to: CGPoint(x: 130, y: 90))
        #expect(flipped == CGRect(x: 110, y: 70, width: 20, height: 20))
        let proportional = EditorGeometry.resized(rect, handle: 4, to: CGPoint(x: 210, y: 90), proportional: true)
        #expect(proportional.width / proportional.height == 2)
        let stretched = EditorGeometry.resized(rect, handle: 3, to: CGPoint(x: 210, y: 90), proportional: true)
        #expect(stretched.height == 50)
    }
    @Test func penTranslationAndScaling() {
        var pen = mark(.pen)
        pen.points = [.zero, CGPoint(x: 40, y: 30)]
        pen.translate(CGSize(width: 5, height: 7))
        #expect(pen.points[0] == CGPoint(x: 5, y: 7))
        pen.resize(to: CGRect(x: 0, y: 0, width: 80, height: 60))
        #expect(pen.points == [.zero, CGPoint(x: 80, y: 60)])
    }
    @Test func cropClampingPixelSnapAndAspect() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        #expect(EditorGeometry.crop(CGRect(x: -5, y: 1.2, width: 60, height: 40.7), bounds: bounds) == CGRect(x: 0, y: 2, width: 55, height: 39))
        #expect(EditorGeometry.crop(CGRect(x: 0, y: 0, width: 7, height: 20), bounds: bounds) == nil)
        #expect(EditorGeometry.crop(CGRect(x: 0, y: 0, width: 60, height: 70), bounds: bounds, aspect: 2)?.height == 30)
        #expect(EditorGeometry.moved(CGRect(x: 20, y: 20, width: 40, height: 30), by: CGSize(width: 200, height: -100), within: bounds) == CGRect(x: 60, y: 0, width: 40, height: 30))
    }
    @Test func canvasLimitsAndExpansion() {
        #expect(EditorGeometry.valid(CGSize(width: 10000, height: 6000)))
        #expect(!EditorGeometry.valid(CGSize(width: 10000, height: 6001)))
        #expect(!EditorGeometry.valid(CGSize(width: CGFloat.infinity, height: 1)))
        #expect(!EditorGeometry.valid(.zero))
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        #expect(EditorGeometry.expanded(bounds, to: CGPoint(x: -12.3, y: -5.1)) == CGRect(x: -13, y: -6, width: 113, height: 86))
        #expect(EditorGeometry.expanded(bounds, to: CGPoint(x: 10, y: 10)) == bounds)
    }
    @Test func fitAndDownscale() {
        #expect(EditorGeometry.fit(CGSize(width: 100, height: 100), in: CGSize(width: 1000, height: 1000)) == 1)
        #expect(EditorGeometry.downscaled(CGSize(width: 12000, height: 8000)) == CGSize(width: 6000, height: 4000))
        #expect(EditorGeometry.downscaled(CGSize(width: 400, height: 200)) == CGSize(width: 400, height: 200))
    }
    @Test func stickerAndNumberSizes() {
        #expect(EditorGeometry.stickerSide(CGSize(width: 100, height: 100), scale: 1) == 45)
        #expect(EditorGeometry.stickerSide(CGSize(width: 2000, height: 2000), scale: 1) == 128)
        #expect(EditorGeometry.numberDiameter(CGSize(width: 1200, height: 800)) == CGFloat(800) / 24)
    }
    @Test func backgroundMath() {
        #expect(EditorGeometry.margin(CGSize(width: 100, height: 80), value: 0) == 24)
        #expect(abs(EditorGeometry.margin(CGSize(width: 1000, height: 1000), value: 0.5) - 105) < 0.001)
        #expect(EditorGeometry.corner(CGSize(width: 1000, height: 800), value: 0.5) == 80)
    }
    @Test func watermarkPositionsAndRotatedFit() {
        let canvas = CGSize(width: 100, height: 80)
        let top = EditorGeometry.watermark(CGSize(width: 20, height: 10), canvas: canvas, position: 0, corners: 0, rotation: 0)
        let bottom = EditorGeometry.watermark(CGSize(width: 20, height: 10), canvas: canvas, position: 8, corners: 0, rotation: 0)
        #expect(top.origin == CGPoint(x: 4, y: 4))
        #expect(bottom.maxX == 96 && bottom.maxY == 76)
        let rotated = EditorGeometry.watermark(CGSize(width: 1000, height: 50), canvas: canvas, position: 4, corners: 0, rotation: 90)
        #expect(rotated.width <= 72.001)
        #expect(abs(rotated.midX - 50) < 0.001 && abs(rotated.midY - 40) < 0.001)
    }
    @Test func ocrBandsCoverImageAndStayBounded() {
        let size = CGSize(width: 6000, height: 9000)
        let bands = EditorGeometry.bands(size: size)
        #expect(bands.first?.minY == 0 && bands.last?.maxY == 9000)
        #expect(bands.allSatisfy { $0.width * $0.height <= 12_000_000 && $0.height <= 4096 })
        for (a, b) in zip(bands, bands.dropFirst()) { #expect(a.maxY > b.minY && a.maxY - b.minY <= 256) }
    }
    @Test func exportFormatsAndCollisionNames() {
        #expect(EditorExport.format(source: .heic, transparent: true) == .png)
        #expect(EditorExport.format(source: .jpeg, transparent: false) == .jpeg)
        let date = Date(timeIntervalSince1970: 0)
        let name = EditorExport.filename(prefix: "a/b:c", date: date, format: .png, existing: [])
        #expect(name == "a-b-c 1970-01-01 00.00.00.png")
        #expect(EditorExport.filename(prefix: "a/b:c", date: date, format: .png, existing: [name]) == "a-b-c 1970-01-01 00.00.00 (2).png")
    }
    @Test func keyOwnersAndReservedCommands() {
        #expect(EditorExport.keyConflict("escape", tool: .arrow, assignments: [:], external: [:]) == "Editor command")
        #expect(EditorExport.keyConflict("⌘c", tool: .arrow, assignments: [:], external: [:]) == "Editor command")
        #expect(EditorExport.keyConflict("a", tool: .arrow, assignments: ["pen": "a"], external: [:]) == "Pen")
        #expect(EditorExport.keyConflict("a", tool: .arrow, assignments: [:], external: ["a": "System shortcut"]) == "System shortcut")
        #expect(EditorExport.keyConflict("a", tool: .arrow, assignments: ["arrow": "a"], external: [:]) == nil)
    }
    @Test func renderingNativePixelsAndOpaqueBlock() throws {
        var doc = try fixture()
        doc.marks = [mark(.block, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 30))]
        let image = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings()))
        #expect(image.width == 100 && image.height == 80)
        #expect(try pixel(image, x: 15, y: 15)[0] == 255)
        #expect(try pixel(image, x: 15, y: 15)[1] < 70)
        #expect(try pixel(image, x: 80, y: 60) == [255, 255, 255, 255])
    }
    @Test func highlighterMultipliesAtFortyTwoPercent() throws {
        var doc = try fixture()
        var highlighter = mark(.highlighter)
        highlighter.style.color = EditorColor(red: 1, green: 0, blue: 0)
        doc.marks = [highlighter]
        let image = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings()))
        let sample = try pixel(image, x: 20, y: 15)
        #expect(sample[0] == 255 && abs(Int(sample[1]) - 148) <= 1 && sample[3] == 255)
    }
    @Test func spotlightUnionDimsOnlyOnceAndUpperMarksStayBright() throws {
        var doc = try fixture()
        doc.marks = [mark(.spotlight, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40)), mark(.spotlight, from: CGPoint(x: 30, y: 20), to: CGPoint(x: 70, y: 60)), mark(.block, from: CGPoint(x: 80, y: 60), to: CGPoint(x: 95, y: 75))]
        let image = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings()))
        #expect(try pixel(image, x: 35, y: 25) == [255, 255, 255, 255])
        #expect(try abs(Int(pixel(image, x: 2, y: 2)[0]) - 128) <= 1)
        #expect(try pixel(image, x: 85, y: 65)[0] == 255)
    }
    @Test func roundedCornersAndBackgroundExportSizes() throws {
        let doc = try fixture()
        var settings = ScreenshotEditorSettings()
        settings.background.corners = 1
        let transparent = try #require(ScreenshotRenderer.render(doc, settings: settings))
        #expect(ScreenshotRenderer.transparent(transparent))
        settings.background.kind = .solid
        let background = try #require(ScreenshotRenderer.render(doc, settings: settings))
        #expect(background.width == 148 && background.height == 128)
        #expect(!ScreenshotRenderer.transparent(background))
    }
    @Test func eraseFlatFillAndLowerImageRedaction() throws {
        var doc = try fixture()
        let black = try fixture(width: 20, height: 20, color: .swatches[6])
        let image = AnnotationMark(tool: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 40, y: 40), image: black.base)
        var erase = mark(.blur, from: CGPoint(x: 15, y: 15), to: CGPoint(x: 45, y: 45))
        erase.style.redaction = .erase
        doc.marks = [image, erase]
        let output = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings()))
        #expect(try pixel(output, x: 30, y: 30) == [255, 255, 255, 255])
    }
    @Test func textOnlyRedactionFallsBackUntilOCRFinishes() throws {
        var doc = try fixture(color: EditorColor(red: 0.5, green: 0.5, blue: 0.5))
        var redaction = mark(.blur)
        redaction.style.textOnly = true
        doc.marks = [redaction]
        let noText = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings(), words: []))
        let original = try #require(ScreenshotRenderer.decode(doc.base))
        #expect(ScreenshotRenderer.rgba(noText) == ScreenshotRenderer.rgba(original))
        let pending = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings(), words: nil))
        #expect(ScreenshotRenderer.rgba(pending) != ScreenshotRenderer.rgba(original))
    }
    @Test func expansionPreservesPixelsAndFill() throws {
        let doc = try fixture(width: 20, height: 10, color: .swatches[0])
        let source = try #require(ScreenshotRenderer.decode(doc.base))
        let result = try #require(ScreenshotRenderer.expanded(source, rect: CGRect(x: -5, y: -6, width: 30, height: 22), fill: EditorColor(red: 0, green: 0, blue: 0, alpha: 0)))
        #expect(try pixel(result, x: 1, y: 1)[3] == 0)
        #expect(try pixel(result, x: 6, y: 7)[0] == 255)
        #expect(result.width == 30 && result.height == 22)
    }
    @Test func renderAllToolsOffscreen() throws {
        for tool in AnnotationTool.allCases where ![.select, .crop, .expand].contains(tool) {
            var doc = try fixture(width: 160, height: 120)
            var annotation = mark(tool, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 80))
            annotation.text = "Test"
            annotation.points = [annotation.start, CGPoint(x: 40, y: 60), annotation.end]
            doc.marks = [annotation]
            #expect(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings()) != nil)
        }
    }
    @Test func arrowStylesRenderOffscreen() throws {
        for head in ArrowHead.allCases {
            var doc = try fixture()
            var arrow = mark(.arrow, from: CGPoint(x: 10, y: 60), to: CGPoint(x: 80, y: 10))
            arrow.style.head = head
            doc.marks = [arrow]
            let a = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings()))
            let b = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings()))
            #expect(ScreenshotRenderer.rgba(a) == ScreenshotRenderer.rgba(b))
        }
    }
    @Test func freehandBoundsIncludeEverySample() {
        var pen = mark(.pen, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 20, y: 20))
        pen.points = [pen.start, CGPoint(x: -10, y: 70), CGPoint(x: 90, y: -20), pen.end]
        #expect(pen.rect == CGRect(x: -10, y: -20, width: 100, height: 90))
    }
    @Test func selectedOCRWordsJoinInReadingOrder() {
        let words = [EditorWord(text: "world", rect: CGRect(x: 70, y: 10, width: 40, height: 10)),
                     EditorWord(text: "Next", rect: CGRect(x: 0, y: 40, width: 40, height: 10)),
                     EditorWord(text: "Hello", rect: CGRect(x: 0, y: 11, width: 40, height: 10))]
        #expect(EditorWord.joined(words) == "Hello world\nNext")
        #expect(EditorWord.joined([]).isEmpty)
    }
    @Test func eraseReconstructsLinearGradient() throws {
        let size = CGSize(width: 100, height: 80)
        let ctx = try #require(ScreenshotRenderer.context(size))
        for x in 0..<100 {
            ctx.setFillColor(CGColor(gray: CGFloat(x) / 100, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 80))
        }
        let original = try #require(ctx.makeImage())
        var doc = ScreenshotDocument(base: try #require(ScreenshotRenderer.encode(original)), size: size)
        let black = mark(.block, from: CGPoint(x: 30, y: 20), to: CGPoint(x: 60, y: 50))
        var erase = mark(.blur, from: CGPoint(x: 25, y: 15), to: CGPoint(x: 65, y: 55))
        erase.style.redaction = .erase
        doc.marks = [black, erase]
        let output = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings()))
        for x in 25..<65 { #expect(try abs(Int(pixel(output, x: x, y: 30)[0]) - Int(pixel(original, x: x, y: 30)[0])) <= 1) }
    }
    @Test func watermarkImageIsAboveMarksAndInsideCapture() throws {
        var doc = try fixture(width: 200, height: 160)
        doc.marks = [mark(.block, from: .zero, to: CGPoint(x: 200, y: 160))]
        var settings = ScreenshotEditorSettings()
        settings.watermark.kind = .image
        settings.watermark.opacity = 1
        settings.watermark.position = 4
        settings.watermark.image = try fixture(width: 20, height: 20, color: .swatches[4]).base
        let output = try #require(ScreenshotRenderer.render(doc, settings: settings))
        #expect(try pixel(output, x: 100, y: 80)[2] == 255)
        #expect(try pixel(output, x: 2, y: 2)[0] == 255)
    }
    @Test func pixelationNoiseIsStableAcrossPreviewAndExport() throws {
        var doc = try fixture(color: EditorColor(red: 0.5, green: 0.5, blue: 0.5))
        doc.marks = [mark(.blur)]
        let preview = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings()))
        let export = try #require(ScreenshotRenderer.render(doc, settings: ScreenshotEditorSettings()))
        #expect(ScreenshotRenderer.rgba(preview) == ScreenshotRenderer.rgba(export))
    }
    @Test func refillInterpolationAndAspectLockAtBoundary() {
        #expect(EditorGeometry.refill(left: 10, right: 90, top: 40, bottom: 40, u: 0.3, v: 0.8) == 40)
        #expect(EditorGeometry.refill(left: 30, right: 30, top: 10, bottom: 90, u: 0.3, v: 0.8) == 30)
        #expect(EditorGeometry.refill(left: 0, right: 100, top: 0, bottom: 100, u: 0.5, v: 0.5) == 50)
        let crop = EditorGeometry.crop(CGRect(x: 0, y: 60, width: 100, height: 80), bounds: CGRect(x: 0, y: 0, width: 100, height: 80), aspect: 2)
        #expect(crop == CGRect(x: 0, y: 60, width: 40, height: 20))
    }
    @Test func linkValidationRejectsExpiredAndUnsafeURLs() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(!EditorSharedLink(url: URL(string: "http://example.invalid/image")!, expiresAt: now.addingTimeInterval(3600), deletionToken: "token").usable(at: now))
        #expect(!EditorSharedLink(url: URL(string: "https://example.invalid/image")!, expiresAt: now, deletionToken: "token").usable(at: now))
        #expect(!EditorSharedLink(url: URL(string: "https://example.invalid/image")!, expiresAt: now.addingTimeInterval(3600), deletionToken: "").usable(at: now))
    }
    @Test @MainActor func linkUploadAndDeletionUseInjectedService() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let link = EditorSharedLink(url: URL(string: "https://example.invalid/image")!, expiresAt: now.addingTimeInterval(3600), deletionToken: "token")
        let service = EditorLinkFixture(link: link)
        let controller = EditorLinkController()
        await controller.upload(Data([1]), format: .png, service: service, now: now)
        #expect(controller.state == .ready(link))
        #expect(await service.lifetime == 3600)
        await controller.delete(service: service)
        #expect(controller.state == .idle)
        #expect(await service.deleted)
    }
    @Test @MainActor func invalidLinkAndDeleteFailureAreRecoverable() async {
        let now = Date(timeIntervalSince1970: 100)
        let expired = EditorSharedLink(url: URL(string: "https://example.invalid/image")!, expiresAt: now, deletionToken: "token")
        let controller = EditorLinkController()
        await controller.upload(Data(), format: .png, service: EditorLinkFixture(link: expired), now: now)
        #expect(controller.state.link == nil && !controller.state.isBusy)
        let link = EditorSharedLink(url: expired.url, expiresAt: now.addingTimeInterval(3600), deletionToken: "token")
        let service = EditorLinkFixture(link: link, failsDeletion: true)
        await controller.upload(Data(), format: .png, service: service, now: now)
        await controller.delete(service: service)
        #expect(controller.state == .ready(link) && controller.error != nil)
    }
    @Test func exportRoundTripAndDPIInTempDirectory() throws {
        var doc = try fixture()
        doc.scale = 2
        var settings = ScreenshotEditorSettings()
        settings.export1x = true
        let image = try #require(ScreenshotRenderer.render(doc, settings: settings))
        #expect(image.width == 50 && image.height == 40)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try #require(ScreenshotRenderer.encode(image, scale: 2))
        #expect(ScreenshotRenderer.captureScale(data) == 2)
        let url = directory.appendingPathComponent("fixture.png")
        try data.write(to: url, options: .withoutOverwriting)
        #expect(try Data(contentsOf: url) == data)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(abs((properties[kCGImagePropertyDPIWidth] as? Double ?? 0) - 144) < 0.1)
    }
}

private actor EditorLinkFixture: EditorLinkService {
    let link: EditorSharedLink
    let failsDeletion: Bool
    var lifetime: TimeInterval = 0
    var deleted = false
    init(link: EditorSharedLink, failsDeletion: Bool = false) { self.link = link; self.failsDeletion = failsDeletion }
    func upload(_ data: Data, format: EditorFormat, lifetime: TimeInterval) async throws -> EditorSharedLink {
        self.lifetime = lifetime
        return link
    }
    func delete(_ link: EditorSharedLink) async throws {
        if failsDeletion { throw CocoaError(.fileWriteUnknown) }
        deleted = true
    }
}
