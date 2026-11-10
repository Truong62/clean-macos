import AVFoundation
import Foundation
import Testing
@testable import CleanMacOS

struct VideoEditorTests {
    @Test func settingsDecodeOlderDocumentsWithoutResettingChoices() throws {
        let settings = try JSONDecoder().decode(RecorderSettings.self, from: Data(#"{"folder":"/chosen","framesPerSecond":30,"systemAudio":true}"#.utf8))
        #expect(settings.folder == "/chosen")
        #expect(settings.framesPerSecond == 30)
        #expect(settings.systemAudio)
        #expect(!settings.shortcut && !settings.microphone && !settings.pointer && !settings.typing)
        #expect(!settings.opensEditor && !settings.automaticZooms && !settings.menuTile)
        #expect(settings.quality == .balanced && settings.gifFPS == 12)
    }

    @Test func regionShrinksInsideOneDisplayAndNeverRoundsOutward() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let region = RecordingRegion.fit(CGRect(x: 10.25, y: 12.25, width: 100, height: 100), in: bounds, scale: 2)!
        #expect(bounds.contains(region))
        #expect(region.minX >= 10.25 && region.minY >= 12.25)
        #expect(Int(region.width * 2) % 2 == 0 && Int(region.height * 2) % 2 == 0)
        #expect(RecordingRegion.fit(CGRect(x: 90, y: 0, width: 100, height: 100), in: bounds, scale: 2) == nil)
        #expect(RecordingRegion.fit(bounds, in: bounds, scale: 0) == nil)
    }

    @Test func audioAcrossPauseEdgesIsRejectedWhole() {
        var timeline = RecordingTimeline()
        let time = { CMTime(seconds: $0, preferredTimescale: 48000) }
        timeline.pause(at: time(3))
        timeline.resume(at: time(5))
        #expect(!timeline.accepts(start: time(2.9), duration: time(0.2)))
        #expect(timeline.accepts(start: time(2.8), duration: time(0.2)))
        #expect(!timeline.accepts(start: time(4.9), duration: time(0.2)))
        #expect(timeline.accepts(start: time(5), duration: time(0.2)))
        #expect(timeline.adjusted(time(6)) == time(4))
    }

    @Test func cutsMergeAndPreserveMinimumTakeLength() {
        var edit = VideoEditDocument(trim: VideoSpan(start: 1, end: 10))
        let result1 = edit.cut(VideoSpan(start: 2, end: 4))
        #expect(result1)
        let result2 = edit.cut(VideoSpan(start: 3, end: 6))
        #expect(result2)
        #expect(edit.cuts == [VideoSpan(start: 2, end: 6)])
        #expect(edit.pieces == [VideoSpan(start: 1, end: 2), VideoSpan(start: 6, end: 10)])
        let result3 = !edit.cut(VideoSpan(start: 0, end: 10))
        #expect(result3)
        let result4 = !edit.cut(VideoSpan(start: 8, end: 8.01))
        #expect(result4)
        #expect(VideoTimeline.sourceTime(1.5, pieces: edit.pieces) == 6.5)
        #expect(VideoTimeline.sourceTime(100, pieces: edit.pieces) == 10)
    }

    @Test func automaticZoomsMergeNearbyClicksAndClampEnds() {
        let zooms = VideoTimeline.automatic(clicks: [2, 6, 15, 19.5], typing: [], duration: 20, holdsTyping: false)
        #expect(zooms.count == 2)
        #expect(zooms[0].span == VideoSpan(start: 1.7, end: 8.5))
        #expect(zooms[1].span == VideoSpan(start: 14.7, end: 17.5))
        #expect(VideoTimeline.automatic(clicks: [0.1], typing: [], duration: 1.1, holdsTyping: false).isEmpty)
    }

    @Test func typingExtendsOnlyAnExistingZoom() {
        #expect(VideoTimeline.automatic(clicks: [], typing: [1, 2, 3], duration: 20, holdsTyping: true).isEmpty)
        let held = VideoTimeline.automatic(clicks: [2], typing: [9, 15], duration: 20, holdsTyping: true)
        #expect(held.first?.span.end == 16.4)
        let notHeld = VideoTimeline.automatic(clicks: [2], typing: [9, 15], duration: 20, holdsTyping: false)
        #expect(notHeld.first?.span.end == 4.5)
    }

    @Test func manualZoomsDoNotOverlapAndRampsReachUnity() {
        var edit = VideoEditDocument(trim: VideoSpan(start: 0, end: 10))
        let result5 = edit.addZoom(at: 2)
        #expect(result5)
        let result6 = !edit.addZoom(at: 3)
        #expect(result6)
        let result7 = edit.addZoom(at: 1)
        #expect(result7)
        #expect(edit.zooms[0].span.end == 2)
        let zoom = edit.zooms[1]
        #expect(VideoTimeline.zoomScale(zoom, at: 2) == 1)
        #expect(abs(VideoTimeline.zoomScale(zoom, at: 3) - 1.8) < 0.0001)
        #expect(abs(VideoTimeline.zoomScale(zoom, at: 4.65) - 1) < 0.0001)
    }

    @Test func gifCentisecondsDoNotAccumulateRoundingDrift() {
        for fps in [8.0, 12, 15, 24, 30, 50] {
            let delays = VideoTimeline.gifDelays(frames: Int(fps * 60), fps: fps)
            #expect(abs(delays.reduce(0, +) - 60) < 0.00001)
            #expect(delays.allSatisfy { $0 >= 0.02 })
        }
        #expect(VideoTimeline.gifDelays(frames: 10, fps: 0).isEmpty)
    }

    @Test func damagedFieldsFallBackIndependently() throws {
        let edit = try JSONDecoder().decode(VideoEditDocument.self, from: Data(#"{"look":"studio","speed":100,"pointer":"bad","cuts":{},"gifFPS":0}"#.utf8))
        #expect(edit.look == .studio)
        #expect(edit.speed == 4 && edit.gifFPS == 1)
        #expect(!edit.pointer && edit.cuts.isEmpty)
        #expect(edit.quality == .balanced)
    }

    @Test func damagedNestedFieldsKeepUnrelatedEdits() throws {
        let edit = try JSONDecoder().decode(VideoEditDocument.self, from: Data(#"{"overlays":[{"kind":"text","text":"Keep this","opacity":"bad"}],"zooms":[{"span":{"start":2,"end":4},"strength":"bad"}]}"#.utf8))
        #expect(edit.overlays.first?.text == "Keep this")
        #expect(edit.overlays.first?.opacity == 1)
        #expect(edit.zooms.first?.strength == 1.8)
        #expect(edit.zooms.first?.span == VideoSpan(start: 2, end: 4))
        let tracks = try JSONDecoder().decode(VideoTracks.self, from: Data(#"{"clicks":[2,1],"typing":[3]}"#.utf8))
        #expect(tracks.clicks == [1, 2] && tracks.cursors.isEmpty)
    }

    @Test func undoRedoAndBranchingPreserveDocuments() {
        var history = VideoEditHistory()
        let first = VideoEditDocument()
        var second = first
        second.look = .studio
        history.record(first)
        let result8 = history.undo(second) == first
        #expect(result8)
        let result9 = history.redo(first) == second
        #expect(result9)
        _ = history.undo(second)
        history.record(first)
        #expect(history.redo.isEmpty)
    }

    @Test func canvasHasEvenSidesAndRespectsLongEdge() {
        var edit = VideoEditDocument()
        edit.shape = .portrait
        #expect(VideoRenderPlan.canvas(source: CGSize(width: 6000, height: 4000), document: edit) == CGSize(width: 2160, height: 3840))
        edit.quality = .small
        #expect(VideoRenderPlan.canvas(source: CGSize(width: 6000, height: 4000), document: edit) == CGSize(width: 1080, height: 1920))
    }

    @Test func atomicReplacementAndTakePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let take = try VideoTakeFiles.create(in: root)
        let mode = try FileManager.default.attributesOfItem(atPath: take.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        let destination = take.appendingPathComponent("movie.mp4")
        let staged = take.appendingPathComponent(".stage.mp4")
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: staged)
        #expect(VideoTakeFiles.unique(destination) != destination)
        try VideoTakeFiles.install(staged, at: destination)
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(throws: (any Error).self) { try VideoTakeFiles.install(staged, at: destination) }
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @Test func sweepRemovesOnlyExpiredUnprotectedTakes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 200000)
        let expired = try VideoTakeFiles.create(in: root)
        let protected = try VideoTakeFiles.create(in: root)
        let fresh = try VideoTakeFiles.create(in: root)
        for folder in [expired, protected] {
            let master = folder.appendingPathComponent("master.mov")
            try Data([1]).write(to: master)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90000)], ofItemAtPath: master.path)
        }
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
        VideoTakeFiles.sweep(root, now: now, protecting: [protected])
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(FileManager.default.fileExists(atPath: protected.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func orphansRespectDifferentRetentionForEmptyTakes() {
        let now = Date(timeIntervalSince1970: 100000)
        #expect(VideoTakeFiles.expired(modified: now.addingTimeInterval(-3600), hasMaster: false, now: now))
        #expect(!VideoTakeFiles.expired(modified: now.addingTimeInterval(-3600), hasMaster: true, now: now))
        #expect(VideoTakeFiles.expired(modified: now.addingTimeInterval(-86400), hasMaster: true, now: now))
    }
}
