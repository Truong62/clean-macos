import Foundation
import Testing
@testable import CleanMacOS

struct VideoMotionTests {
    @Test func smoothingKeepsClickAndHeldPositionsRaw() {
        let samples = (0..<100).map { index in
            VideoPointerSample(time: Double(index) / 125, point: CGPoint(x: Double(index % 2) * 0.02, y: 0.5), pressed: index == 60)
        }
        let filtered = VideoMotion.smoothed(samples, clicks: [0.2], mode: .smooth)
        #expect(filtered[25].point == samples[25].point)
        #expect(filtered[60].point == samples[60].point)
        #expect(filtered[80].point != samples[80].point)
        #expect(VideoMotion.smoothed(samples, clicks: [], mode: .none) == samples)
        #expect(VideoMotion.index(at: -1, in: samples) == nil)
        #expect(VideoMotion.index(at: 0.2, in: samples) == 25)
    }

    @Test func stillPointerFadesAndReturnsBeforeMovement() {
        var samples = (0..<401).map { VideoPointerSample(time: Double($0) / 100, point: CGPoint(x: 0.5, y: 0.5)) }
        samples.append(VideoPointerSample(time: 4.01, point: CGPoint(x: 0.6, y: 0.5)))
        #expect(VideoMotion.opacity(at: 2, samples: samples) == 1)
        #expect(VideoMotion.opacity(at: 3, samples: samples) == 0)
        #expect(VideoMotion.opacities(samples)[300] == 0)
        #expect(VideoMotion.opacities(samples)[390] > 0)
        #expect(VideoMotion.opacity(at: 3.9, samples: samples) > 0)
    }

    @Test func springConvergesWithoutEscapingTheZoomRange() {
        var spring = VideoSpring(value: 1)
        spring.advance(to: 2, duration: 3)
        #expect(abs(spring.value - 2) < 0.001)
        let zoom = VideoZoom(span: VideoSpan(start: 1, end: 3))
        let camera = VideoCamera.build(zooms: [zoom], pointer: [], duration: 5)
        #expect(camera.first?.scale == 1)
        #expect(camera[120].scale > 1.6)
        #expect(camera.last!.scale < 1.01)
        #expect(camera.allSatisfy { $0.scale >= 1 && $0.scale <= 1.81 })
    }

    @Test func blocksSnapWithoutCrossingNeighbours() {
        let span = VideoSpan(start: 3, end: 5)
        let moved = VideoTimeline.moved(span, by: 20, bounds: VideoSpan(start: 0, end: 10), neighbours: [VideoSpan(start: 7, end: 9)], anchors: [])
        #expect(moved == VideoSpan(start: 5, end: 7))
        #expect(VideoTimeline.snap(2.05, to: [2, 3]) == 2)
        #expect(VideoTimeline.snap(2.5, to: [2, 3]) == 2.5)
    }

    @Test func tapRequiresSoundAndFallsBackWhenStreamHearsMissingAudio() {
        var choice = RecordingAudioChoice()
        choice.tap(time: 1, audible: false)
        let untrusted = choice.stream(time: 1, audible: true, appOnly: true)
        #expect(!untrusted)
        choice.tap(time: 2, audible: true)
        let trusted = choice.stream(time: 2, audible: true, appOnly: true)
        #expect(trusted)
        choice.tap(time: 2.2, audible: false)
        _ = choice.stream(time: 2.2, audible: true, appOnly: true)
        choice.tap(time: 2.8, audible: false)
        let missed = choice.stream(time: 2.8, audible: true, appOnly: true)
        #expect(!missed)
        let lost = choice.stream(time: 4, audible: false, appOnly: true)
        #expect(!lost)
    }

    @Test func presetLimitOverwriteAndScope() {
        var presets: [VideoPreset] = []
        var document = VideoEditDocument()
        document.look = .studio
        document.speed = 4
        for index in 0..<14 { presets = VideoPreset.saving(VideoPreset(name: "Preset \(index)", document: document, pictures: [:]), into: presets) }
        #expect(presets.count == 12)
        #expect(presets.first?.name == "Preset 2")
        presets = VideoPreset.saving(VideoPreset(name: "Preset 10", document: document, pictures: [:]), into: presets)
        #expect(presets.count == 12)
        #expect(presets.last?.name == "Preset 10")
        let current = VideoEditDocument(trim: VideoSpan(start: 0, end: 10))
        let applied = presets[0].applying(to: current)
        #expect(applied.look == .studio)
        #expect(applied.speed == 1 && applied.trim == current.trim)
    }

    @Test func masterBitrateClampsWithoutAResolutionCap() {
        #expect(RecordingCodec.bitRate(size: CGSize(width: 1920, height: 1080), fps: 60, bits: 0.09) == 11_197_440)
        #expect(RecordingCodec.bitRate(size: CGSize(width: 32, height: 32), fps: 30, bits: 0.09) == 800_000)
        #expect(RecordingCodec.bitRate(size: CGSize(width: 7680, height: 4320), fps: 60, bits: 0.09) == 60_000_000)
    }
}
