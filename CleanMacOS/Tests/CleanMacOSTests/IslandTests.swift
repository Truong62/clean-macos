import Foundation
import Testing
@testable import CleanMacOS

struct IslandTests {
    func screen(id: UInt32 = 1, notch: Bool = false, origin: CGPoint = .zero, scale: Double = 2) -> IslandDisplay {
        IslandDisplay(id: id, frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                      visibleFrame: CGRect(x: origin.x, y: origin.y, width: 1440, height: 876), scale: scale, safeTop: notch ? 32 : 0,
                      leftArea: notch ? CGRect(x: 0, y: 868, width: 620, height: 32) : nil,
                      rightArea: notch ? CGRect(x: 820, y: 868, width: 620, height: 32) : nil, builtIn: notch)
    }

    @Test func settingsAreOffAndDecodeMissingFields() throws {
        let settings = try JSONDecoder().decode(IslandSettings.self, from: Data("{}".utf8))
        #expect(settings == IslandSettings())
        #expect(!settings.isEnabled && !settings.shortcut && settings.sections.isEmpty)
        #expect(!settings.levelNotices && !settings.batteryNotices && !settings.bluetoothNotices)
        #expect(!settings.gestures && !settings.haptics && !settings.timerSound)
        #expect(!settings.includeInCaptures && !settings.calendarCountdown)
        let old = try JSONDecoder().decode(IslandSettings.self, from: Data("{\"isEnabled\":true,\"sections\":[\"timer\",\"timer\"],\"customWidth\":2000}".utf8))
        #expect(old.isEnabled)
        #expect(old.sections == [.timer])
        #expect(old.customWidth == 600)
        #expect(!old.bluetoothNotices)
        #expect(try JSONDecoder().decode(IslandSettings.self, from: JSONEncoder().encode(old)) == old)
    }

    @Test func notchNeedsBothMeasurementsAndCapsExtremeValues() {
        var display = screen(notch: true)
        #expect(display.camera == CGSize(width: 200, height: 32))
        display.safeTop = 0
        #expect(display.camera == nil)
        display.safeTop = 100
        display.rightArea = CGRect(x: 2000, y: 0, width: 200, height: 32)
        #expect(abs((display.camera?.width ?? 0) - 1008) < 0.001)
        #expect(display.camera?.height == 64)
    }

    @Test func capsuleAndNotchFit() {
        var settings = IslandSettings()
        #expect(IslandGeometry.closed(screen(), settings: settings) == CGSize(width: 100, height: 20))
        settings.simulatedNotch = true
        #expect(IslandGeometry.closed(screen(), settings: settings) == CGSize(width: 135, height: 24))
        settings.notchWidth = 10
        settings.notchHeight = -2
        settings.outline = true
        #expect(IslandGeometry.closed(screen(notch: true), settings: settings) == CGSize(width: 214, height: 32))
    }

    @Test func placementUsesDisplayOriginAndDevicePixels() {
        let display = screen(origin: CGPoint(x: -1440, y: 113), scale: 2)
        let frame = IslandGeometry.frame(display, settings: IslandSettings(), state: .closed)
        #expect(frame.midX == -720)
        #expect(frame.maxY == 1011)
        #expect((frame.minX * 2).rounded() == frame.minX * 2)
    }

    @Test func openPeekDropAndBounds() {
        let display = screen(notch: true)
        var settings = IslandSettings()
        #expect(IslandGeometry.frame(display, settings: settings, state: .open).width == 560)
        #expect(IslandGeometry.frame(display, settings: settings, state: .peek).height == 94)
        #expect(IslandGeometry.frame(display, settings: settings, state: .drop).height == 108)
        settings.size = .custom
        settings.customWidth = 600
        settings.customHeight = 640
        #expect(IslandGeometry.frame(display, settings: settings, state: .open).height == 640)
        #expect(IslandGeometry.frame(display, settings: settings, state: .compact).width == 200)
        #expect(IslandGeometry.frame(display, settings: settings, state: .compact, hasRoom: true).width == 288)
    }

    @Test func displaySelectionPrioritizesBuiltInNotch() {
        let external = screen(id: 2, origin: CGPoint(x: 1440, y: 0))
        let builtIn = screen(notch: true)
        #expect(IslandGeometry.display(.automatic, screens: [external, builtIn], main: 2, pointer: .zero)?.id == 1)
        #expect(IslandGeometry.display(.pointer, screens: [external, builtIn], main: 1, pointer: CGPoint(x: 1600, y: 30))?.id == 2)
        #expect(IslandGeometry.display(.builtIn, screens: [external], main: 2, pointer: .zero)?.id == 2)
        #expect(IslandGeometry.display(.automatic, screens: [], main: nil, pointer: .zero) == nil)
    }

    @Test func noticePriorityReplacementAndExpiry() {
        var state = IslandState()
        state.activities = [.music, .timer]
        state.refresh(now: 0)
        #expect(state.currentActivity == .timer)
        #expect(state.phase == .compact)
        let result85 = state.show(.level, title: "20%", section: .home, now: 0)
        #expect(result85)
        let result86 = !state.show(.track, title: "Track", section: .music, now: 1)
        #expect(result86)
        let result87 = state.show(.level, title: "30%", section: .home, now: 1)
        #expect(result87)
        #expect(state.notice?.expires == 2.6)
        state.refresh(now: 2.61)
        #expect(state.notice == nil)
        #expect(state.phase == .compact)
    }

    @Test func heldNoticeRejectsLowerAndOpenRetainsMeter() {
        var state = IslandState()
        state.show(.timer, title: "Done", section: .timer, now: 0)
        state.notice?.held = true
        state.refresh(now: 20)
        #expect(state.notice != nil)
        let result100 = !state.show(.download, title: "File", section: .downloads, now: 20)
        #expect(result100)
        let result101 = state.show(.level, title: "50%", section: .home, now: 21)
        #expect(result101)
        state.open(hover: false)
        state.show(.level, title: "60%", section: .home, now: 22)
        #expect(state.phase == .open)
    }

    @Test func explicitAndHoverCloseRules() {
        var state = IslandState()
        state.open(hover: false)
        state.leave(now: 0)
        #expect(state.phase == .open)
        state.pinned = true
        state.close(explicit: false, now: 0)
        #expect(state.phase == .open)
        state.close(explicit: true, now: 0)
        state.open(hover: true)
        #expect(state.phase == .closed)
        state.leave(now: 0)
        state.open(hover: true)
        #expect(state.phase == .open)
        state.leave(now: 0)
        #expect(state.phase == .closed)
    }

    @Test func suspensionAndProtectedTasks() {
        var state = IslandState()
        state.suspended = true
        state.open(hover: false)
        #expect(state.phase == .closed)
        let result130 = !state.show(.timer, title: "Done", section: .timer, now: 0)
        #expect(result130)
        state.suspended = false
        state.open(hover: false)
        state.protected = true
        state.close(explicit: true, now: 0)
        #expect(state.phase == .open)
    }

    @Test func timerPauseResumeAndSleepCompletionOnce() {
        var timer = IslandTimer()
        timer.start(now: 10, minutes: 1, mode: .countdown)
        #expect(timer.value(at: 20) == 50)
        timer.pause(now: 20)
        #expect(timer.value(at: 100) == 50)
        timer.resume(now: 100)
        let result145 = !timer.tick(now: 200, suspended: true)
        #expect(result145)
        let result146 = timer.tick(now: 200, suspended: false)
        #expect(result146)
        let result147 = !timer.tick(now: 201, suspended: false)
        #expect(result147)
        #expect(timer.finished)
    }

    @Test func pomodoroDoesNotSkipPhases() {
        var timer = IslandTimer()
        timer.start(now: 0, minutes: 15, mode: .pomodoro, cycle: .init(focus: 1, shortBreak: 2, longBreak: 3, every: 1, total: 2))
        let result154 = timer.tick(now: 5000, suspended: false)
        #expect(result154)
        #expect(timer.phase == .focus && timer.session == 1)
        timer.next(now: 5000)
        #expect(timer.phase == .longBreak && timer.duration == 180)
        let result158 = timer.tick(now: 6000, suspended: false)
        #expect(result158)
        timer.next(now: 6000)
        #expect(timer.phase == .focus && timer.session == 2)
        let result161 = timer.tick(now: 7000, suspended: false)
        #expect(result161)
        timer.next(now: 7001)
        #expect(timer.finished && timer.started == nil)
    }

    @Test func clockRoundingAndStopwatchCap() {
        #expect(IslandTimer.clock(59.1, countdown: true) == "01:00")
        #expect(IslandTimer.clock(59.9, countdown: false) == "00:59")
        #expect(IslandTimer.clock(3601, countdown: true) == "1:00:01")
        #expect(IslandTimer.clock(.infinity, countdown: true) == "00:00")
        var timer = IslandTimer()
        timer.start(now: 0, minutes: 0, mode: .stopwatch)
        #expect(timer.value(at: 500000) == 359999)
        let result174 = !timer.tick(now: 500000, suspended: false)
        #expect(result174)
    }

    @Test func calendarDeduplicatesAndSpansMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 0)
        let event = IslandEvent(id: "a", title: "Overnight", start: day.addingTimeInterval(80000), end: day.addingTimeInterval(90000), allDay: false, calendar: "Work")
        let allDay = IslandEvent(id: "b", title: "Holiday", start: day, end: day.addingTimeInterval(86400), allDay: true, calendar: "Home")
        var cancelled = event
        cancelled.id = "c"
        cancelled.cancelled = true
        var zero = event
        zero.id = "d"
        zero.end = zero.start
        let groups = IslandCalendarLogic.groups([event, event, allDay, cancelled, zero], from: day, days: 2, calendar: calendar)
        #expect(groups.count == 2)
        #expect(groups[0].1.map(\.id) == ["b", "a"])
        #expect(groups[1].1.map(\.id) == ["a"])
        #expect(IslandCalendarLogic.countdown([event, allDay], now: day.addingTimeInterval(79000))?.id == "a")
    }

    @Test func downloadsRecognizeOnlyPartialFilesAndKnownTotals() {
        #expect(IslandDownloadLogic.finalName("archive.zip.crdownload") == "archive.zip")
        #expect(IslandDownloadLogic.finalName("movie.download") == "movie")
        #expect(IslandDownloadLogic.finalName("archive.part") == "archive")
        #expect(IslandDownloadLogic.finalName("normal.zip") == nil)
        #expect(IslandDownloadLogic.finalName(".part") == nil)
        #expect(IslandDownloadLogic.fraction(completed: 30, total: 40) == 0.75)
        #expect(IslandDownloadLogic.fraction(completed: 30, total: 0) == nil)
        #expect(IslandDownloadLogic.fraction(completed: 50, total: 40) == 1)
        let now = Date(timeIntervalSince1970: 500)
        #expect(!IslandDownloadLogic.live(modified: now.addingTimeInterval(-121), now: now, published: false))
        #expect(IslandDownloadLogic.live(modified: .distantPast, now: now, published: true))
    }

    @Test func batteryBaselineThresholdAndRearm() {
        var edges = IslandBatteryEdges()
        let result212 = edges.update(percent: 50, connected: false) == nil
        #expect(result212)
        let result213 = edges.update(percent: 20, connected: false) == "Battery low · 20%"
        #expect(result213)
        let result214 = edges.update(percent: 19, connected: false) == nil
        #expect(result214)
        let result215 = edges.update(percent: 30, connected: false) == nil
        #expect(result215)
        let result216 = edges.update(percent: 18, connected: false) != nil
        #expect(result216)
        let result217 = edges.update(percent: 18, connected: true) == "Power connected"
        #expect(result217)
        let result218 = edges.update(percent: 100, connected: true) == "Battery full"
        #expect(result218)
        let result219 = edges.update(percent: 100, connected: true) == nil
        #expect(result219)
    }

    @Test func mediaPositionHonorsPausedStateAndBounds() {
        let now = Date(timeIntervalSince1970: 0)
        var sample = IslandMediaSample(title: "Track", artist: "Artist", duration: 100, elapsed: 30, sampled: now, rate: 1, playing: false)
        #expect(sample.position(at: now.addingTimeInterval(60)) == 30)
        sample.playing = true
        #expect(sample.position(at: now.addingTimeInterval(60)) == 90)
        #expect(sample.position(at: now.addingTimeInterval(200)) == 100)
        sample.duration = .infinity
        #expect(sample.position(at: now) == 0)
    }
    @Test func menuRoomUsesFramesAndRejectsOverlap() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let camera = CGRect(x: 620, y: 868, width: 200, height: 32)
        let left = CGRect(x: 0, y: 876, width: 570, height: 24)
        let right = CGRect(x: 900, y: 876, width: 540, height: 24)
        let room = IslandMenuRoom.measure(camera: camera, screen: screen, items: [left, right], known: true)
        #expect(room.left == 42 && room.right == 72 && room.known)
        let overlap = IslandMenuRoom.measure(camera: camera, screen: screen, items: [camera], known: true)
        #expect(overlap.overlaps && !overlap.known)
        #expect(!IslandMenuRoom.measure(camera: camera, screen: screen, items: [], known: false).known)
    }

    @Test func gesturesAccumulateLockAxisAndFireOnce() {
        var gesture = IslandGesture()
        let a = gesture.consume(x: 1, y: -8, now: 0, precise: true, inverted: false, modified: false, open: false, music: false)
        let b = gesture.consume(x: 0, y: -8, now: 0.1, precise: true, inverted: false, modified: false, open: false, music: false)
        let c = gesture.consume(x: 0, y: -30, now: 0.2, precise: true, inverted: false, modified: false, open: false, music: false)
        #expect(a == nil && b == .open && c == nil)
        let d = gesture.consume(x: -40, y: 0, now: 1, precise: true, inverted: false, modified: false, open: true, music: true)
        #expect(d == .next)
        let e = gesture.consume(x: 0, y: 1, now: 2, precise: false, inverted: false, modified: false, open: true, music: false)
        #expect(e == .close)
        let f = gesture.consume(x: 0, y: 10, now: 3, precise: false, inverted: false, modified: true, open: true, music: false)
        #expect(f == nil)
    }

    @Test func pausedAtStartStillHasSession() {
        var timer = IslandTimer()
        timer.start(now: 0, minutes: 15, mode: .countdown)
        timer.pause(now: 0)
        #expect(timer.active && timer.value(at: 100) == 900)
    }

    @Test func completedDownloadsRequireFinalFileEvidence() throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/island-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let partial = folder.appendingPathComponent("fixture.zip.part")
        let final = folder.appendingPathComponent("fixture.zip")
        try Data([1, 2, 3]).write(to: partial)
        let original = try FileManager.default.attributesOfItem(atPath: partial.path)[.systemFileNumber] as? NSNumber
        try FileManager.default.moveItem(at: partial, to: final)
        let renamed = try FileManager.default.attributesOfItem(atPath: final.path)[.systemFileNumber] as? NSNumber
        #expect(IslandDownloadLogic.completed(originalInode: original?.uint64Value ?? 0, finalInode: renamed?.uint64Value, publisherFinished: false))
        #expect(!IslandDownloadLogic.completed(originalInode: 1, finalInode: nil, publisherFinished: true))
        #expect(!IslandDownloadLogic.completed(originalInode: 1, finalInode: 2, publisherFinished: false))
        #expect(IslandDownloadLogic.completed(originalInode: 1, finalInode: 2, publisherFinished: true))
    }

}
