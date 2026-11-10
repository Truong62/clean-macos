import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CleanMacOS

struct MediaNamingTests {
    @Test func namesOutputsNextToTheSource() {
        let source = URL(fileURLWithPath: "/Users/me/Movies/Trip.mov")
        #expect(OutputNaming.sibling(of: source, suffix: "-compressed", ext: "mp4").path == "/Users/me/Movies/Trip-compressed.mp4")
        #expect(OutputNaming.sibling(of: source, suffix: "", ext: "gif").path == "/Users/me/Movies/Trip.gif")
        #expect(OutputNaming.sibling(of: URL(fileURLWithPath: "/a/scan.final.png"), suffix: "-text", ext: "txt").path == "/a/scan.final-text.txt")
    }

    @Test func addsANumberWhenTheNameIsTaken() {
        let taken: Set<String> = ["/a/Trip.gif", "/a/Trip 2.gif", "/a/README"]
        let exists = { (url: URL) in taken.contains(url.path) }
        #expect(OutputNaming.available(URL(fileURLWithPath: "/a/Trip.gif"), exists: exists).path == "/a/Trip 3.gif")
        #expect(OutputNaming.available(URL(fileURLWithPath: "/a/Free.gif"), exists: exists).path == "/a/Free.gif")
        #expect(OutputNaming.available(URL(fileURLWithPath: "/a/README"), exists: exists).path == "/a/README 2")
    }

    @Test func acceptsTheRightKindOfFileForEachTab() {
        #expect(MediaTab.video.accepts(URL(fileURLWithPath: "/a/clip.mov")))
        #expect(MediaTab.gif.accepts(URL(fileURLWithPath: "/a/clip.MP4")))
        #expect(!MediaTab.video.accepts(URL(fileURLWithPath: "/a/photo.png")))
        #expect(MediaTab.images.accepts(URL(fileURLWithPath: "/a/photo.heic")))
        #expect(MediaTab.text.accepts(URL(fileURLWithPath: "/a/scan.jpg")))
        #expect(!MediaTab.images.accepts(URL(fileURLWithPath: "/a/notes.txt")))
        #expect(!MediaTab.images.accepts(URL(string: "https://example.com/a.png")!))
        #expect(MediaTab.allCases.filter(\.allowsMany) == [.images])
    }
}

struct VideoPresetTests {
    @Test func picksTheAvconvertPresetFromTheQuality() {
        #expect(VideoPresets.preset(quality: 0.28, maxSize: 1280) == ConvertPreset(name: "PresetLowQuality", isMultiPass: false))
        #expect(VideoPresets.preset(quality: 0.88, maxSize: 1280) == ConvertPreset(name: "PresetHighestQuality", isMultiPass: true))
        #expect(VideoPresets.preset(quality: 0.82, maxSize: 640) == ConvertPreset(name: "PresetHighestQuality", isMultiPass: true))
        #expect(VideoPresets.preset(quality: 0.5, maxSize: 1920) == ConvertPreset(name: "PresetMediumQuality", isMultiPass: false))
        #expect(VideoPresets.preset(quality: 0.4, maxSize: 1920).name == "PresetMediumQuality")
        #expect(VideoPresets.preset(quality: 0.58, maxSize: 1280) == ConvertPreset(name: "Preset1280x720", isMultiPass: false))
    }

    @Test func matchesTheResolutionPresetToTheMaxSize() {
        let names = [640, 900, 960, 1500, 1920, 2560, 3840, 100, 9000].map { VideoPresets.preset(quality: 0.68, maxSize: $0).name }
        #expect(names == ["Preset640x480", "Preset640x480", "Preset960x540", "Preset1280x720", "Preset1920x1080", "Preset1920x1080",
                          "Preset3840x2160", "Preset640x480", "Preset3840x2160"])
    }

    @Test func levelsCarryTheirQualityFactors() {
        #expect(CompressionLevel.allCases.map(\.quality) == [0.88, 0.68, 0.28])
        let settings = VideoCompressSettings()
        #expect(settings.mode == .resolution && settings.level == .medium && settings.maxSize == 1280 && settings.targetMB == 20)
    }

    @Test func buildsAvconvertArguments() {
        let source = URL(fileURLWithPath: "/v/in.mov")
        let output = URL(fileURLWithPath: "/t/out.mp4")
        #expect(VideoPresets.arguments(source: source, output: output, preset: ConvertPreset(name: "Preset1280x720", isMultiPass: false), range: nil)
            == ["--source", "/v/in.mov", "--preset", "Preset1280x720", "--output", "/t/out.mp4", "--progress"])
        #expect(VideoPresets.arguments(source: source, output: output, preset: ConvertPreset(name: "PresetHighestQuality", isMultiPass: true),
                                       range: ClipRange(start: 1.5, end: 4))
            == ["--source", "/v/in.mov", "--preset", "PresetHighestQuality", "--output", "/t/out.mp4", "--progress", "--multiPass",
                "--start", "1.500", "--duration", "2.500"])
    }

    @Test func readsAvconvertProgressAndErrors() {
        #expect(abs((AVConvertOutput.progress(in: "\ravconvert progress:  11.63% complete") ?? 0) - 0.1163) < 1e-9)
        #expect(abs((AVConvertOutput.progress(in: "\ravconvert progress:  1.80% complete\ravconvert progress:  54.37% complete") ?? 0) - 0.5437) < 1e-9)
        #expect(AVConvertOutput.progress(in: "avconvert completed with error:0.") == nil)
        #expect(AVConvertOutput.failure("avconvert:  failed with error:Cannot Open.  This media format is not supported.\navconvert completed with error:1.\n",
                                        status: 205) == "Cannot Open.  This media format is not supported.")
        #expect(AVConvertOutput.failure("", status: 3) == "avconvert stopped with code 3.")
    }
}

struct ClipTrimTests {
    @Test func parsesClipTimes() throws {
        #expect(try ClipTime.parse("65.5") == 65.5)
        #expect(try ClipTime.parse("1:05") == 65)
        #expect(try ClipTime.parse(" 1:02:03 ") == 3723)
        #expect(try ClipTime.parse("") == nil)
        #expect(throws: MediaToolError.self) { try ClipTime.parse("1:xx") }
        #expect(throws: MediaToolError.self) { try ClipTime.parse("-3") }
        #expect(throws: MediaToolError.self) { try ClipTime.parse("1::2") }
    }

    @Test func resolvesTheTrimRange() throws {
        #expect(try ClipTrim().range(duration: 30) == ClipRange(start: 0, end: 30))
        #expect(try ClipTrim(isOn: false, start: "5", end: "6").range(duration: 30) == ClipRange(start: 0, end: 30))
        #expect(try ClipTrim(isOn: true, start: "0:05", end: "").range(duration: 30) == ClipRange(start: 5, end: 30))
        #expect(try ClipTrim(isOn: true, start: "", end: "99").range(duration: 30) == ClipRange(start: 0, end: 30))
        #expect(try ClipTrim(isOn: true, start: "2", end: "4.5").range(duration: 30) == ClipRange(start: 2, end: 4.5))
        #expect(throws: MediaToolError.self) { try ClipTrim(isOn: true, start: "10", end: "5").range(duration: 30) }
        #expect(throws: MediaToolError.self) { try ClipTrim(isOn: true, start: "40", end: "").range(duration: 30) }
        #expect(ClipRange(start: 0, end: 30).isWhole(of: 30))
        #expect(!ClipRange(start: 1, end: 30).isWhole(of: 30))
        #expect(!ClipRange(start: 0, end: 29).isWhole(of: 30))
    }
}

struct TargetSizePlanTests {
    private let hd = CGSize(width: 1920, height: 1080)

    @Test func spends94PercentOfTheBudgetOnVideoPlusAudio() throws {
        let plan = try TargetSizePlanner.plan(targetBytes: 20_000_000, seconds: 60, hasAudio: true, source: hd, sourceBitRate: 0)
        #expect(plan.audioBitRate == 128_000)
        #expect(plan.videoBitRate == 2_378_666)
        #expect(plan.size == CGSize(width: 1280, height: 720))
    }

    @Test func usesTheLowAudioRateOnTightBudgetsAndNoneWithoutAudio() throws {
        let tight = try TargetSizePlanner.plan(targetBytes: 5_000_000, seconds: 60, hasAudio: true, source: hd, sourceBitRate: 0)
        #expect(tight.audioBitRate == 64_000)
        #expect(tight.videoBitRate == 562_666)
        #expect(tight.size == CGSize(width: 720, height: 404))
        let silent = try TargetSizePlanner.plan(targetBytes: 5_000_000, seconds: 60, hasAudio: false, source: hd, sourceBitRate: 0)
        #expect(silent.audioBitRate == 0)
        #expect(silent.videoBitRate == 626_666)
    }

    @Test func picksTheResolutionFromTheBitrateWithAtLeast480Pixels() {
        #expect(TargetSizePlanner.plan(videoBitRate: 250_000, audioBitRate: 64_000, source: hd).size == CGSize(width: 480, height: 270))
        #expect(TargetSizePlanner.plan(videoBitRate: 20_000_000, audioBitRate: 128_000, source: hd).size == hd)
        #expect(TargetSizePlanner.plan(videoBitRate: 20_000_000, audioBitRate: 0, source: CGSize(width: 3840, height: 2160)).size == CGSize(width: 3840, height: 2160))
        #expect(TargetSizePlanner.plan(videoBitRate: 3_000_000, audioBitRate: 0, source: CGSize(width: 1080, height: 1920)).size == CGSize(width: 1080, height: 1920))
        #expect(TargetSizePlanner.plan(videoBitRate: 1_000_000, audioBitRate: 0, source: CGSize(width: 1080, height: 1920)).size == CGSize(width: 540, height: 960))
        #expect(TargetSizePlanner.plan(videoBitRate: 300_000, audioBitRate: 0, source: CGSize(width: 321, height: 181)).size == CGSize(width: 320, height: 180))
    }

    @Test func failsClearlyWhenTheVideoWouldDropUnder240Kbps() {
        #expect(throws: MediaToolError.self) {
            try TargetSizePlanner.plan(targetBytes: 1_000_000, seconds: 600, hasAudio: true, source: hd, sourceBitRate: 0)
        }
        #expect(throws: MediaToolError.message("10 MB is too small for 5:00 of video. Use at least 13 MB, or trim it.")) {
            try TargetSizePlanner.plan(targetBytes: 10_000_000, seconds: 300, hasAudio: true, source: hd, sourceBitRate: 0)
        }
    }

    @Test func lowersTheBitrateWhenAnAttemptComesOutTooBig() throws {
        let first = try TargetSizePlanner.plan(targetBytes: 20_000_000, seconds: 60, hasAudio: true, source: hd, sourceBitRate: 0)
        let second = try TargetSizePlanner.retry(first, actualBytes: 25_000_000, targetBytes: 20_000_000, source: hd)
        #expect(abs(second.videoBitRate - 1_807_786) <= 1)
        #expect(second.audioBitRate == first.audioBitRate)
        let nudged = try TargetSizePlanner.retry(first, actualBytes: 20_100_000, targetBytes: 20_000_000, source: hd)
        #expect(abs(nudged.videoBitRate - 2_140_799) <= 1)
        #expect(throws: MediaToolError.self) {
            try TargetSizePlanner.retry(TargetSizePlan(videoBitRate: 250_000, audioBitRate: 64_000, size: hd), actualBytes: 30, targetBytes: 20, source: hd)
        }
    }

    @Test func neverAsksForMoreThanTheSourceBitrate() throws {
        let plan = try TargetSizePlanner.plan(targetBytes: 500_000_000, seconds: 10, hasAudio: false, source: hd, sourceBitRate: 3_000_000)
        #expect(plan.videoBitRate == 3_000_000)
        #expect(plan.size == hd)
    }
}

struct GIFPlanTests {
    @Test func spacesFramesByTheFrameRate() throws {
        #expect(try GIFPlanner.frameTimes(length: 1, fps: 5) == [0, 0.2, 0.4, 0.6, 0.8])
        #expect(try GIFPlanner.frameTimes(length: 2.05, fps: 2).count == 5)
        #expect(try GIFPlanner.frameTimes(length: 25, fps: 12).count == 300)
        #expect(try GIFPlanner.frameTimes(length: 0.01, fps: 30) == [0])
    }

    @Test func refusesMoreThan300FramesAndSaysHowLongTheClipCanBe() {
        #expect(throws: MediaToolError.message("A GIF can have up to 300 frames, so at 12 fps it can be at most 25 seconds long. Trim the clip or lower the frame rate.")) {
            try GIFPlanner.frameTimes(length: 26, fps: 12)
        }
        #expect(throws: MediaToolError.message("A GIF can have up to 300 frames, so at 7 fps it can be at most 42.8 seconds long. Trim the clip or lower the frame rate.")) {
            try GIFPlanner.frameTimes(length: 60, fps: 7)
        }
    }

    @Test func scalesToTheWidthWithoutUpscaling() {
        #expect(GIFPlanner.size(width: 720, source: CGSize(width: 1920, height: 1080)) == CGSize(width: 720, height: 405))
        #expect(GIFPlanner.size(width: 720, source: CGSize(width: 480, height: 270)) == CGSize(width: 480, height: 270))
        #expect(GIFPlanner.size(width: 160, source: CGSize(width: 1080, height: 1920)) == CGSize(width: 160, height: 284))
    }

    @Test func lowersTheFrameRateBeforeTheWidth() {
        let start = GIFAttempt(fps: 12, width: 720)
        let second = GIFPlanner.next(after: start, bytes: 15_000_000, target: 10_000_000)
        #expect(second == GIFAttempt(fps: 8, width: 720))
        #expect(second.flatMap { GIFPlanner.next(after: $0, bytes: 12_000_000, target: 10_000_000) } == GIFAttempt(fps: 8, width: 623))
        #expect(GIFPlanner.next(after: GIFAttempt(fps: 30, width: 720), bytes: 11_000_000, target: 10_000_000) == GIFAttempt(fps: 24, width: 720))
        #expect(GIFPlanner.next(after: GIFAttempt(fps: 5, width: 160), bytes: 20_000_000, target: 10_000_000) == nil)
        #expect(GIFPlanner.next(after: start, bytes: 9_000_000, target: 10_000_000) == nil)
    }

    @Test func defaultsMatchTheSpec() {
        let settings = GIFSettings()
        #expect(settings.fps == 12 && settings.width == 720 && !settings.limitsSize && settings.targetMB == 10)
        #expect(GIFPlanner.maxAttempts == 4 && GIFPlanner.fpsRange == 1...30 && GIFPlanner.widthRange == 160...1600)
    }
}

struct ImageGeometryTests {
    private let photo = CGSize(width: 4000, height: 3000)

    private func layout(_ source: CGSize? = nil, _ change: (inout ImageConvertSettings) -> Void) -> ImageLayout {
        var settings = ImageConvertSettings()
        change(&settings)
        return ImageGeometry.layout(source: source ?? photo, settings: settings)
    }

    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        [a.minX - b.minX, a.minY - b.minY, a.width - b.width, a.height - b.height].allSatisfy { abs($0) < 0.01 }
    }

    @Test func keepsTheOriginalSize() {
        #expect(layout { $0.resize = .original } == ImageLayout(canvas: photo, drawRect: CGRect(origin: .zero, size: photo)))
    }

    @Test func fitsTheLongestSideWidthOrHeightWithoutEnlarging() {
        #expect(layout { $0.resize = .longestSide; $0.length = 1600 }.canvas == CGSize(width: 1600, height: 1200))
        #expect(layout(CGSize(width: 3000, height: 4000)) { $0.resize = .longestSide; $0.length = 1600 }.canvas == CGSize(width: 1200, height: 1600))
        #expect(layout { $0.resize = .width; $0.length = 1000 }.canvas == CGSize(width: 1000, height: 750))
        #expect(layout { $0.resize = .height; $0.length = 600 }.canvas == CGSize(width: 800, height: 600))
        #expect(layout { $0.resize = .longestSide; $0.length = 8000 }.canvas == photo)
        #expect(layout { $0.resize = .width; $0.length = 1 }.canvas == CGSize(width: 1, height: 1))
        let scaled = layout { $0.resize = .width; $0.length = 1000 }
        #expect(scaled.drawRect == CGRect(origin: .zero, size: scaled.canvas))
    }

    @Test func stretchesFitsOrFillsAnExactSize() {
        let square: (inout ImageConvertSettings, ExactFit) -> Void = { settings, fit in
            settings.resize = .exact
            settings.exactWidth = 1000
            settings.exactHeight = 1000
            settings.fit = fit
        }
        #expect(layout { square(&$0, .stretch) } == ImageLayout(canvas: CGSize(width: 1000, height: 1000), drawRect: CGRect(x: 0, y: 0, width: 1000, height: 1000)))
        let fit = layout { square(&$0, .fit) }
        #expect(fit.canvas == CGSize(width: 1000, height: 1000))
        #expect(isClose(fit.drawRect, CGRect(x: 0, y: 125, width: 1000, height: 750)))
        let fill = layout { square(&$0, .fill) }
        #expect(fill.canvas == CGSize(width: 1000, height: 1000))
        #expect(isClose(fill.drawRect, CGRect(x: -166.667, y: 0, width: 1333.333, height: 1000)))
        let enlarged = layout(CGSize(width: 50, height: 50)) {
            $0.resize = .exact
            $0.exactWidth = 200
            $0.exactHeight = 100
            $0.fit = .fit
        }
        #expect(isClose(enlarged.drawRect, CGRect(x: 50, y: 0, width: 100, height: 100)))
    }

    @Test func decodesJustBigEnoughForTheDrawnSize() {
        let stretched = layout {
            $0.resize = .exact
            $0.exactWidth = 1000
            $0.exactHeight = 1000
            $0.fit = .stretch
        }
        #expect(ImageGeometry.decodeLongSide(source: photo, layout: stretched) == 1334)
        #expect(ImageGeometry.decodeLongSide(source: photo, layout: layout { $0.resize = .longestSide; $0.length = 1600 }) == 1600)
        let enlarged = layout(CGSize(width: 50, height: 40)) {
            $0.resize = .exact
            $0.exactWidth = 500
            $0.exactHeight = 500
        }
        #expect(ImageGeometry.decodeLongSide(source: CGSize(width: 50, height: 40), layout: enlarged) == 50)
    }

    @Test func rejectsImagesOver20000PixelsASideOr64Megapixels() {
        #expect(throws: Never.self) { try ImageLimits.check(CGSize(width: 20_000, height: 3_200)) }
        #expect(throws: Never.self) { try ImageLimits.check(CGSize(width: 8_000, height: 8_000)) }
        #expect(throws: MediaToolError.self) { try ImageLimits.check(CGSize(width: 20_001, height: 10)) }
        #expect(throws: MediaToolError.self) { try ImageLimits.check(CGSize(width: 10, height: 20_001)) }
        #expect(throws: MediaToolError.self) { try ImageLimits.check(CGSize(width: 8_001, height: 8_000)) }
    }

    @Test func placesTheWatermarkBottomRight() {
        #expect(Watermark.fontSize(canvas: CGSize(width: 1600, height: 1200)) == 48)
        #expect(Watermark.fontSize(canvas: CGSize(width: 100, height: 80)) == 12)
        #expect(Watermark.origin(textWidth: 200, canvas: CGSize(width: 1600, height: 1200)) == CGPoint(x: 1368, y: 32))
        #expect(Watermark.fittedFontSize(48, textWidth: 1000, canvasWidth: 564) == 24)
        #expect(Watermark.fittedFontSize(48, textWidth: 100, canvasWidth: 564) == 48)
        #expect(Watermark.opacity == 0.45 && Watermark.margin == 32)
    }

    @Test func presetsSetTheFormatAndSize() {
        var settings = ImageConvertSettings()
        settings.nameTemplate = "{name}-web"
        settings.stripsMetadata = false
        let web = ImagePreset.web.applied(to: settings)
        #expect(web.format == .jpeg && web.resize == .longestSide && web.length == 1600 && web.quality == 0.72 && web.stripsMetadata)
        #expect(web.nameTemplate == "{name}-web")
        #expect(ImagePreset.social.applied(to: settings).length == 2048)
        #expect(ImagePreset.docs.applied(to: settings).format == .pdf)
    }

    @Test func defaultsMatchTheSpec() {
        let settings = ImageConvertSettings()
        #expect(settings.format == .jpeg && settings.quality == 0.72 && settings.resize == .original && settings.length == 1600)
        #expect(settings.stripsMetadata && !settings.keepsModificationDate && !settings.usesSubfolder && !settings.addsWatermark)
        #expect(settings.background == "#FFFFFF")
        #expect(ImageFormat.allCases.filter(\.hasAlpha) == [.png, .heic])
    }
}

struct NameTemplateTests {
    private let date = Date(timeIntervalSince1970: 1_794_301_500)
    private let utc = TimeZone(identifier: "UTC")!

    @Test func fillsEveryToken() {
        let name = NameTemplate.render("{name}-{index}_{width}x{height}.{ext} {date} {time}", name: "IMG_1", ext: "HEIC",
                                       size: CGSize(width: 1600, height: 1200), index: 3, date: date, timeZone: utc)
        #expect(name == "IMG_1-3_1600x1200.HEIC 2026-11-10 09.05.00")
    }

    @Test func keepsUnknownBracesAndCleansUnsafeCharacters() {
        let render = { (template: String, name: String) in
            NameTemplate.render(template, name: name, ext: "png", size: .zero, index: 7, date: date, timeZone: utc)
        }
        #expect(render("{name} {nope} {", "a") == "a {nope} {")
        #expect(render("{name}/{date}:x", "a") == "a-2026-11-10-x")
        #expect(render("  ", "a") == "a")
        #expect(render("..hidden {name}", "a") == "hidden a")
        #expect(render("{name}", "{index}") == "{index}")
    }
}

@MainActor
struct MediaToolsControllerTests {
    private let image = URL(fileURLWithPath: "/nowhere/scan.png")

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func takesOneVideoOrManyImagesAndIgnoresOtherFiles() {
        let controller = MediaToolsController { _, _, _, _, _ in MediaResult() }
        let clip = URL(fileURLWithPath: "/nowhere/clip.mov")
        #expect(!controller.choose([image], for: .video))
        #expect(controller.files[.video] == nil)
        #expect(controller.choose([clip, URL(fileURLWithPath: "/nowhere/other.mov")], for: .video))
        #expect(controller.files[.video] == [clip])
        #expect(controller.choose([image, URL(fileURLWithPath: "/nowhere/notes.txt"), URL(fileURLWithPath: "/nowhere/b.heic")], for: .images))
        #expect(controller.files[.images]?.map(\.lastPathComponent) == ["scan.png", "b.heic"])
    }

    @Test func runsAJobAndKeepsItsResultOverLateProgress() async {
        let controller = MediaToolsController { _, files, _, _, report in
            report(0.5, "Halfway")
            return MediaResult(outputs: files, bytesBefore: 10, bytesAfter: 4)
        }
        controller.choose([image], for: .text)
        controller.run(.text)
        #expect(controller.isRunning(.text))
        await waitUntil { !controller.isRunning(.text) }
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.runs[.text] == .finished(MediaResult(outputs: [image], bytesBefore: 10, bytesAfter: 4)))
    }

    @Test func showsFailuresAndGoesBackToIdleWhenCancelled() async {
        let failing = MediaToolsController { _, _, _, _, _ in throw MediaToolError.message("Nope") }
        failing.choose([image], for: .text)
        failing.run(.text)
        await waitUntil { !failing.isRunning(.text) }
        #expect(failing.runs[.text] == .failed("Nope"))

        let slow = MediaToolsController { _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return MediaResult()
        }
        slow.choose([image], for: .text)
        slow.run(.text)
        #expect(!slow.choose([URL(fileURLWithPath: "/nowhere/other.png")], for: .text))
        slow.cancel(.text)
        await waitUntil { !slow.isRunning(.text) }
        #expect(slow.runs[.text] == nil)
        #expect(slow.files[.text] == [image])
    }

    @Test func choosingAnotherFileClearsTheLastResult() async {
        let controller = MediaToolsController { _, _, _, _, _ in MediaResult() }
        controller.choose([image], for: .images)
        controller.run(.images)
        await waitUntil { !controller.isRunning(.images) }
        #expect(controller.runs[.images] == .finished(MediaResult()))
        controller.choose([URL(fileURLWithPath: "/nowhere/next.jpg")], for: .images)
        #expect(controller.runs[.images] == nil)
    }
}

final class MediaJobTests {
    let folder: URL
    let noReport: MediaJobs.Report = { _, _ in }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("media-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func compressesWithAvconvertNextToTheSourceWithoutTouchingIt() async throws {
        let source = folder.appendingPathComponent("clip.mov")
        try await SyntheticMedia.writeVideo(to: source)
        let original = try Data(contentsOf: source)
        let result = try await MediaJobs.compressVideo(source, settings: VideoCompressSettings(), trim: ClipTrim(), report: noReport)
        #expect(result.outputs == [folder.appendingPathComponent("clip-compressed.mp4")])
        #expect(result.bytesBefore == Int64(original.count))
        #expect(result.bytesAfter == MediaFiles.size(result.outputs[0]))
        #expect(try await SyntheticMedia.videoCodec(of: result.outputs[0]) == kCMVideoCodecType_H264)
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["clip-compressed.mp4", "clip.mov"])
    }

    @Test func trimsWithAvconvertAndNeverOverwritesAnEarlierResult() async throws {
        let source = folder.appendingPathComponent("clip.mov")
        try await SyntheticMedia.writeVideo(to: source, frames: 20)
        let earlier = folder.appendingPathComponent("clip-compressed.mp4")
        try Data("keep".utf8).write(to: earlier)
        var settings = VideoCompressSettings()
        settings.level = .low
        let result = try await MediaJobs.compressVideo(source, settings: settings, trim: ClipTrim(isOn: true, start: "0.5", end: "1.5"), report: noReport)
        #expect(result.outputs == [folder.appendingPathComponent("clip-compressed 2.mp4")])
        #expect(try Data(contentsOf: earlier) == Data("keep".utf8))
        let duration = try await AVURLAsset(url: result.outputs[0]).load(.duration).seconds
        #expect(abs(duration - 1) < 0.25)
    }

    @Test func encodesToATargetSizeWithH264AndAAC() async throws {
        let source = folder.appendingPathComponent("talk.mov")
        try await SyntheticMedia.writeVideoWithTone(to: source, scratch: folder)
        var settings = VideoCompressSettings()
        settings.mode = .targetSize
        settings.targetMB = 1
        let result = try await MediaJobs.compressVideo(source, settings: settings, trim: ClipTrim(isOn: true, start: "0.2", end: "0.8"), report: noReport)
        let output = try #require(result.outputs.first)
        #expect(output.lastPathComponent == "talk-compressed.mp4")
        #expect(MediaFiles.size(output) <= 1_000_000)
        let asset = AVURLAsset(url: output)
        #expect(try await SyntheticMedia.videoCodec(of: output) == kCMVideoCodecType_H264)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == 1)
        let audioTrack = try #require(audio.first)
        let audioFormat = try #require(try await audioTrack.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 0.6) < 0.2)
    }

    @Test func makesALoopingGIF() async throws {
        let source = folder.appendingPathComponent("wave.mov")
        try await SyntheticMedia.writeVideo(to: source)
        var settings = GIFSettings()
        settings.fps = 5
        settings.width = 160
        let result = try await MediaJobs.makeGIF(source, settings: settings, trim: ClipTrim(), report: noReport)
        let output = try #require(result.outputs.first)
        #expect(output.lastPathComponent == "wave.gif")
        let gif = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(gif) as String? == UTType.gif.identifier)
        #expect(CGImageSourceGetCount(gif) == 5)
        let file = CGImageSourceCopyProperties(gif, nil) as? [CFString: Any]
        #expect((file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int == 0)
        let frame = CGImageSourceCopyPropertiesAtIndex(gif, 0, nil) as? [CFString: Any]
        #expect(frame?[kCGImagePropertyPixelWidth] as? Int == 160)
        #expect(frame?[kCGImagePropertyPixelHeight] as? Int == 90)
        let delay = (frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double
        #expect(abs((delay ?? 0) - 0.2) < 0.011)
        #expect(result.notes.isEmpty)
    }

    @Test func shrinksAGIFUntilItFitsOrRunsOutOfTries() async throws {
        let source = folder.appendingPathComponent("wave.mov")
        try await SyntheticMedia.writeVideo(to: source)
        var settings = GIFSettings()
        settings.fps = 10
        settings.width = 320
        settings.limitsSize = true
        settings.targetMB = 0.0001
        let result = try await MediaJobs.makeGIF(source, settings: settings, trim: ClipTrim(), report: noReport)
        let output = try #require(result.outputs.first)
        let gif = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(gif) == 8)
        let frame = CGImageSourceCopyPropertiesAtIndex(gif, 0, nil) as? [CFString: Any]
        #expect(frame?[kCGImagePropertyPixelWidth] as? Int == 160)
        #expect(result.notes.count == 2)
    }

    @Test func convertsImagesOverAWhiteBackgroundAndResizes() async throws {
        let source = folder.appendingPathComponent("logo.png")
        try SyntheticMedia.writeImage(CGSize(width: 400, height: 200), to: source) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        var settings = ImageConvertSettings()
        settings.resize = .longestSide
        settings.length = 200
        let result = try await MediaJobs.convertImages([source], settings: settings, date: Date(), report: noReport)
        #expect(result.failures.isEmpty)
        let output = try #require(result.outputs.first)
        #expect(output.lastPathComponent == "logo.jpg")
        let image = Bitmap(try #require(SyntheticMedia.image(at: output)))
        #expect(image.width == 200 && image.height == 100)
        let red = image.pixel(x: 50, y: 50)
        #expect(red.red > 200 && red.green < 60 && red.blue < 60)
        let background = image.pixel(x: 150, y: 50)
        #expect(background.red > 240 && background.green > 240 && background.blue > 240)
    }

    @Test func drawsTheWatermarkInTheBottomRightCorner() async throws {
        let source = folder.appendingPathComponent("dark.png")
        try SyntheticMedia.writeImage(CGSize(width: 600, height: 400), to: source) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        var settings = ImageConvertSettings()
        settings.format = .png
        settings.addsWatermark = true
        settings.watermark = "MACKIT WATERMARK"
        let result = try await MediaJobs.convertImages([source], settings: settings, date: Date(), report: noReport)
        let output = try #require(result.outputs.first)
        let image = Bitmap(try #require(SyntheticMedia.image(at: output)))
        let brightest = { (xs: Range<Int>, ys: Range<Int>) in
            xs.flatMap { x in ys.map { y in image.pixel(x: x, y: y).red } }.max() ?? 0
        }
        #expect(brightest(380..<568, 340..<372) > 60)
        #expect(brightest(380..<568, 340..<372) < 200)
        #expect(brightest(0..<300, 340..<372) < 10)
        #expect(brightest(380..<600, 0..<300) < 10)
    }

    @Test func stripsOrKeepsMetadataAndTurnsPhotosUpright() async throws {
        let source = folder.appendingPathComponent("photo.jpg")
        try SyntheticMedia.writeImage(CGSize(width: 200, height: 100), to: source, type: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.5, kCGImagePropertyGPSLatitudeRef: "N"],
        ]) { context in
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        var settings = ImageConvertSettings()
        settings.format = .png
        let stripped = try await MediaJobs.convertImages([source], settings: settings, date: Date(), report: noReport)
        settings.stripsMetadata = false
        settings.format = .jpeg
        let kept = try await MediaJobs.convertImages([source], settings: settings, date: Date(), report: noReport)
        #expect(kept.outputs.first?.lastPathComponent == "photo 2.jpg")
        let strippedOutput = try #require(stripped.outputs.first)
        let strippedInfo = try #require(SyntheticMedia.properties(of: strippedOutput))
        #expect(strippedInfo[kCGImagePropertyPixelWidth] as? Int == 100)
        #expect(strippedInfo[kCGImagePropertyPixelHeight] as? Int == 200)
        #expect(strippedInfo[kCGImagePropertyGPSDictionary] == nil)
        #expect((strippedInfo[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        let keptOutput = try #require(kept.outputs.first)
        let keptInfo = try #require(SyntheticMedia.properties(of: keptOutput))
        #expect(keptInfo[kCGImagePropertyPixelWidth] as? Int == 100)
        #expect((keptInfo[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] as? Double == 10.5)
        #expect((keptInfo[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func namesFromTheTemplateInAConvertedFolderAndKeepsTheDate() async throws {
        let source = folder.appendingPathComponent("logo.png")
        try SyntheticMedia.writeImage(CGSize(width: 400, height: 200), to: source) { _ in }
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: source.path)
        var settings = ImageConvertSettings()
        settings.nameTemplate = "{name}-{index}-{width}x{height}-{ext}"
        settings.usesSubfolder = true
        settings.keepsModificationDate = true
        let result = try await MediaJobs.convertImages([source], settings: settings, date: Date(), report: noReport)
        let output = try #require(result.outputs.first)
        #expect(output == folder.appendingPathComponent("Converted").appendingPathComponent("logo-1-400x200-png.jpg"))
        let modified = try FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate] as? Date
        #expect(modified == stamp)
    }

    @Test func keepsGoingPastImagesThatFail() async throws {
        let good = folder.appendingPathComponent("good.png")
        try SyntheticMedia.writeImage(CGSize(width: 40, height: 40), to: good) { _ in }
        let broken = folder.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        let wide = folder.appendingPathComponent("wide.png")
        try SyntheticMedia.writeImage(CGSize(width: 20_001, height: 1), to: wide) { _ in }
        let result = try await MediaJobs.convertImages([good, broken, wide], settings: ImageConvertSettings(), date: Date(), report: noReport)
        #expect(result.outputs.map(\.lastPathComponent) == ["good.jpg"])
        #expect(result.failures.count == 2)
        #expect(result.failures[0].hasPrefix("broken.png: "))
        #expect(result.failures[1].hasPrefix("wide.png: 20001 × 1 px is too big"))
        #expect(result.bytesBefore == MediaFiles.size(good))
    }

    @Test func writesOnePDFPagePerImage() async throws {
        let source = folder.appendingPathComponent("scan.png")
        try SyntheticMedia.writeImage(CGSize(width: 400, height: 200), to: source) { _ in }
        var settings = ImageConvertSettings()
        settings.format = .pdf
        let result = try await MediaJobs.convertImages([source], settings: settings, date: Date(), report: noReport)
        let output = try #require(result.outputs.first)
        #expect(output.lastPathComponent == "scan.pdf")
        let document = try #require(CGPDFDocument(output as CFURL))
        #expect(document.numberOfPages == 1)
        #expect(document.page(at: 1)?.getBoxRect(.mediaBox).size == CGSize(width: 400, height: 200))
    }

    @Test func extractsTextIntoAFileNextToTheImage() async throws {
        let source = folder.appendingPathComponent("sign.png")
        try SyntheticMedia.writeText("Hello MacKit 2026", to: source)
        let result = try await MediaJobs.extractText(source, report: noReport)
        let output = try #require(result.outputs.first)
        #expect(output.lastPathComponent == "sign-text.txt")
        #expect(try String(contentsOf: output, encoding: .utf8).contains("Hello MacKit 2026"))
        #expect(result.text?.contains("Hello MacKit 2026") == true)
    }

    @Test func saysSoWhenAnImageHasNoText() async throws {
        let source = folder.appendingPathComponent("blank.png")
        try SyntheticMedia.writeImage(CGSize(width: 300, height: 200), to: source) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        await #expect(throws: MediaToolError.message("No text found in this image.")) {
            try await MediaJobs.extractText(source) { _, _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["blank.png"])
    }

    @Test func stopsARunningToolWhenCancelled() async throws {
        let started = Date()
        let task = Task { try await CommandRunner.stream("/bin/sleep", ["5"]) { _ in } }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 3)
    }
}

enum SyntheticMedia {
    static func writeVideo(to url: URL, size: CGSize = CGSize(width: 320, height: 180), frames: Int = 10, fps: Int32 = 10) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            let shade = Double(index) / Double(frames)
            context.render(CIImage(color: CIColor(red: shade, green: 1 - shade, blue: 0.4)).cropped(to: CGRect(origin: .zero, size: size)), to: pixels)
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    static func writeVideoWithTone(to url: URL, scratch: URL) async throws {
        let video = scratch.appendingPathComponent("picture-\(UUID().uuidString).mov")
        try await writeVideo(to: video)
        let tone = scratch.appendingPathComponent("tone-\(UUID().uuidString).m4a")
        try writeTone(to: tone)
        let composition = AVMutableComposition()
        for (source, type) in [(video, AVMediaType.video), (tone, AVMediaType.audio)] {
            let asset = AVURLAsset(url: source)
            let track = try #require(try await asset.loadTracks(withMediaType: type).first)
            let target = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try target.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
        }
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: url, as: .mov)
        try? FileManager.default.removeItem(at: video)
        try? FileManager.default.removeItem(at: tone)
    }

    static func writeTone(to url: URL) throws {
        let rate = 48_000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
        buffer.frameLength = AVAudioFrameCount(rate)
        for frame in 0..<Int(rate) {
            buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / rate) * 0.3)
        }
        try file.write(from: buffer)
    }

    static func videoCodec(of url: URL) async throws -> FourCharCode? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        return try await track.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
    }

    static func writeImage(_ size: CGSize, to url: URL, type: UTType = .png, properties: [CFString: Any] = [:], draw: (CGContext) -> Void) throws {
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(origin: .zero, size: size))
        draw(context)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func writeText(_ text: String, to url: URL) throws {
        try writeImage(CGSize(width: 900, height: 220), to: url) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 220))
            let font = CTFontCreateUIFontForLanguage(.system, 56, nil)!
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]))
            context.textPosition = CGPoint(x: 40, y: 80)
            CTLineDraw(line, context)
        }
    }

    static func image(at url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    static func properties(of url: URL) -> [CFString: Any]? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
    }
}

struct Bitmap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    func pixel(x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        let index = (y * width + x) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }
}
