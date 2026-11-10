import Foundation
import Testing
@testable import CleanMacOS

struct IslandExtensionsTests {
    @Test func watchChangesNeedThreeSecondsAndResetWhenBaselineReturns() {
        var watch = IslandWatchLogic()
        let outcome1 = !watch.read("Waiting", now: 0)
        #expect(outcome1)
        let outcome2 = !watch.read("Done", now: 1)
        #expect(outcome2)
        let outcome3 = !watch.read("Waiting", now: 3)
        #expect(outcome3)
        let outcome4 = !watch.read("Done", now: 4)
        #expect(outcome4)
        let outcome5 = !watch.read("Done", now: 6.9)
        #expect(outcome5)
        let outcome6 = watch.read("Done", now: 7)
        #expect(outcome6)
        let outcome7 = !watch.read("Done", now: 8)
        #expect(outcome7)
    }

    @Test func watchSettlesOnlyAfterChangeAndThirtySeconds() {
        var watch = IslandWatchLogic(rule: .settles)
        let outcome8 = !watch.read("A", now: 0)
        #expect(outcome8)
        let outcome9 = !watch.read("A", now: 90)
        #expect(outcome9)
        let outcome10 = !watch.read("B", now: 91)
        #expect(outcome10)
        let outcome11 = !watch.read("C", now: 110)
        #expect(outcome11)
        let outcome12 = !watch.read("C", now: 139)
        #expect(outcome12)
        let outcome13 = watch.read("C", now: 140)
        #expect(outcome13)
    }

    @Test func watchContainsAndNumericDirection() {
        var contains = IslandWatchLogic(rule: .contains, query: "finished")
        let outcome14 = contains.read("FINISHED", now: 0)
        #expect(outcome14)
        var up = IslandWatchLogic(rule: .reaches, target: 80)
        let outcome15 = !up.read("12 files · 20%", now: 0, locale: Locale(identifier: "en_US"))
        #expect(outcome15)
        let outcome16 = up.read("13 files · 80%", now: 1, locale: Locale(identifier: "en_US"))
        #expect(outcome16)
        var down = IslandWatchLogic(rule: .reaches, target: 10)
        let outcome17 = !down.read("Remaining 50", now: 0)
        #expect(outcome17)
        let outcome18 = down.read("Remaining 9", now: 1)
        #expect(outcome18)
    }

    @Test func watchParsesLocaleAndPrefersPercentage() {
        #expect(IslandWatchLogic.number("5 files 12,5%", locale: Locale(identifier: "de_DE")) == 12.5)
        #expect(IslandWatchLogic.number("Total 1,234.5", locale: Locale(identifier: "en_US")) == 1234.5)
        #expect(IslandWatchLogic.number("No numbers", locale: Locale(identifier: "en_US")) == nil)
        #expect(IslandWatchLogic.headline("A\nProgress 75% complete", line: 1) == "75%")
        #expect(IslandWatchLogic.headline(String(repeating: "a", count: 40), line: 100).count == 22)
    }

    @Test func watchFingerprintRequiresFewSmallChanges() {
        let baseline = [UInt8](repeating: 100, count: 256)
        var next = baseline
        next[0] = 115
        next[1] = 99
        next[2] = 101
        #expect(IslandWatchLogic.unchanged(baseline, next))
        next[3] = 101
        #expect(!IslandWatchLogic.unchanged(baseline, next))
        next = baseline
        next[0] = 116
        #expect(!IslandWatchLogic.unchanged(baseline, next))
        #expect(!IslandWatchLogic.unchanged([], []))
    }

    @Test func watchPriorityFollowsTimer() {
        var state = IslandState()
        state.activities = [.agents, .downloads, .watch, .timer]
        #expect(state.currentActivity == .timer)
        state.activities.removeAll { $0 == .timer }
        #expect(state.currentActivity == .watch)
    }

    @Test func spectrumFindsToneAndSmoothsAsymmetrically() {
        let silence = [Float](repeating: 0, count: 1024)
        #expect(IslandSpectrum.bands(silence, sampleRate: 48000) == Array(repeating: 0, count: 7))
        let tone = (0..<1024).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48000) * 0.5) }
        let levels = IslandSpectrum.bands(tone, sampleRate: 48000)
        #expect(levels[3] == levels.max())
        var spectrum = IslandSpectrum()
        spectrum.update(Array(repeating: 1, count: 7))
        #expect(abs(spectrum.levels[0] - 0.506) < 0.00001)
        spectrum.update(Array(repeating: 0, count: 7))
        #expect(abs(spectrum.levels[0] - 0.44528) < 0.00001)
        #expect(IslandSpectrum.height(0, maximum: 20) == 2)
        #expect(IslandSpectrum.synthetic(time: 1, playing: false) == Array(repeating: 0, count: 7))
        #expect(IslandSpectrum.synthetic(time: 1, playing: true).allSatisfy { (0...1).contains($0) })
    }

    @Test func filePolicyRejectsMixedMediaAndUnsafeArchiveDestinations() throws {
        let root = URL(fileURLWithPath: "/fixture")
        let image = root.appendingPathComponent("image.png")
        let video = root.appendingPathComponent("video.mp4")
        #expect(IslandFilePolicy.media([image]) == .images)
        #expect(IslandFilePolicy.media([video]) == .video)
        #expect(IslandFilePolicy.media([image, video]) == nil)
        #expect(IslandFilePolicy.media([video, video]) == nil)
        #expect(throws: MediaToolError.self) { try IslandFilePolicy.archiveDestination(input: root, folder: root.appendingPathComponent("nested"), exists: { _ in false }) }
        #expect(throws: MediaToolError.self) { try IslandFilePolicy.archiveDestination(input: image, folder: root, exists: { _ in true }) }
        #expect(try IslandFilePolicy.archiveDestination(input: image, folder: root, exists: { _ in false }).lastPathComponent == "image.png.zip")
    }

    @Test func codexTurnsRequireExplicitStartAndEndEvents() {
        let fixture = """
        {"type":"session_meta","timestamp":"2026-11-10T10:00:00Z","payload":{"id":"s"}}
        {"type":"event_msg","timestamp":"2026-11-10T10:00:00Z","payload":{"type":"task_started"}}
        {"type":"event_msg","timestamp":"2026-11-10T10:00:40Z","payload":{"type":"token_count"}}
        {"type":"event_msg","timestamp":"2026-11-10T10:02:00Z","payload":{"type":"task_complete"}}
        """
        let turns = IslandAgentLogs.parse(Data(fixture.utf8), agent: .codex, session: "fallback")
        #expect(turns.count == 1)
        #expect(turns.first?.session == "s")
        #expect(turns.first?.duration(at: .distantFuture) == 120)
        #expect(turns.first?.working(at: .distantFuture) == false)
        let noStart = Data(fixture.components(separatedBy: .newlines).suffix(2).joined(separator: "\n").utf8)
        #expect(IslandAgentLogs.parse(noStart, agent: .codex, session: "s").isEmpty)
    }

    @Test func claudeToolResultsDoNotRestartTheTurn() {
        let fixture = """
        {"type":"user","timestamp":"2026-11-10T10:00:00Z","message":{"content":"Do work"}}
        {"type":"assistant","timestamp":"2026-11-10T10:00:20Z","message":{"stop_reason":"tool_use"}}
        {"type":"user","timestamp":"2026-11-10T10:00:30Z","message":{"content":[{"type":"tool_result"}]}}
        {"type":"assistant","timestamp":"2026-11-10T10:00:50Z","message":{"stop_reason":"end_turn"}}
        """
        let turns = IslandAgentLogs.parse(Data(fixture.utf8), agent: .claude, session: "s")
        #expect(turns.count == 1)
        #expect(turns.first?.duration(at: .distantFuture) == 50)
        let start = Date(timeIntervalSince1970: 1000)
        let active = IslandAgentTurn(agent: .codex, session: "s", start: start, updated: start)
        #expect(active.working(at: start.addingTimeInterval(599)))
        #expect(!active.working(at: start.addingTimeInterval(600)))
    }

    @Test func agentFinishedNoticesAreRecentLongEnoughAndUnique() {
        let now = Date(timeIntervalSince1970: 1000)
        let turn = IslandAgentTurn(agent: .claude, session: "s", start: now.addingTimeInterval(-100), updated: now, end: now)
        var notices = IslandAgentNotices()
        let tooShort = notices.finished([turn], now: now, minimum: 120)
        let eligible = notices.finished([turn], now: now, minimum: 60)
        let duplicate = notices.finished([turn], now: now, minimum: 60)
        #expect(tooShort.isEmpty && eligible == [turn] && duplicate.isEmpty)
        var fresh = IslandAgentNotices()
        let stale = fresh.finished([turn], now: now.addingTimeInterval(301), minimum: 0)
        #expect(stale.isEmpty)
    }

    @Test func accessoryQueueBoundsExpiryAndRecovery() {
        var queue = IslandAccessoryQueue()
        for index in 0..<10 { queue.enqueue(id: String(index), title: "Connected", now: 0) }
        #expect(queue.entries.count == 8)
        let held = queue.next(now: 1, closed: false)
        #expect(held == nil)
        queue.enqueue(id: "battery", title: "Low", now: 1, warning: true)
        queue.recover("battery")
        #expect(queue.entries.count == 7)
        let expired = queue.next(now: 30, closed: true)
        #expect(expired == nil && queue.entries.isEmpty)
        #expect(!IslandAccessoryPolicy.accepts(major: 3, paired: true))
        #expect(!IslandAccessoryPolicy.accepts(major: 4, paired: false))
    }

    @Test func accessoryBatteryBaselineFreshnessAndHysteresis() {
        var battery = IslandAccessoryBattery()
        let now = Date(timeIntervalSince1970: 1000)
        let baseline = battery.update(id: "a", percent: 10, sampled: now, now: now, hid: true)
        let tooLowToRearm = battery.update(id: "a", percent: 24, sampled: now, now: now, hid: true)
        let disarmed = battery.update(id: "a", percent: 20, sampled: now, now: now, hid: true)
        let rearm = battery.update(id: "a", percent: 25, sampled: now, now: now, hid: true)
        let stale = battery.update(id: "a", percent: 20, sampled: now.addingTimeInterval(-16), now: now, hid: true)
        let low = battery.update(id: "a", percent: 20, sampled: now, now: now, hid: true)
        #expect(!baseline && !tooLowToRearm && !disarmed && !rearm && !stale && low)
    }

    @Test func limitsWarnOnceAndAnnounceRenewal() {
        let now = Date(timeIntervalSince1970: 1000)
        let high = CodexLimitWindow(usedPercent: 80, windowMinutes: 10, resetsAt: 1300)
        var notices = IslandAgentNotices()
        let first = notices.limits(CodexLimits(observedAt: 1000, primary: high, secondary: nil), now: now, threshold: 80)
        let repeated = notices.limits(CodexLimits(observedAt: 1000, primary: high, secondary: nil), now: now, threshold: 80)
        let renewed = notices.limits(CodexLimits(observedAt: 1301, primary: CodexLimitWindow(usedPercent: 0, windowMinutes: 10, resetsAt: 1900), secondary: nil), now: Date(timeIntervalSince1970: 1301), threshold: 80)
        #expect(first.count == 1 && repeated.isEmpty && renewed.count == 1)
        #expect(IslandAgentNotices.pace(high, now: now) == 0.5)
    }

    @Test func watchPauseDoesNotCountSuspendedTime() {
        var watch = IslandWatchLogic()
        _ = watch.read("Waiting", now: 0)
        _ = watch.read("Done", now: 1)
        watch.pause()
        let resumed = watch.read("Done", now: 100)
        let complete = watch.read("Done", now: 103)
        #expect(!resumed && complete)
    }

    @Test func lockSceneRequiresOnlyLockSuspensionAndAvailablePrivateAPI() {
        let lock: Set<String> = ["com.apple.screenIsLocked"]
        #expect(IslandLockPolicy.visible(enabled: true, reasons: lock, supported: true))
        #expect(!IslandLockPolicy.visible(enabled: false, reasons: lock, supported: true))
        #expect(!IslandLockPolicy.visible(enabled: true, reasons: lock, supported: false))
        #expect(!IslandLockPolicy.visible(enabled: true, reasons: [], supported: true))
        for reason in ["sleep", "display", "session", "com.apple.screensaver.didstart"] {
            #expect(!IslandLockPolicy.visible(enabled: true, reasons: lock.union([reason]), supported: true))
        }
    }

    @Test func batteryColorsAreSharedAndNeverWarnOnAC() throws {
        let colors = IslandBatteryColors(enabled: true, amber: true)
        #expect(colors.level(percent: 10, plugged: false) == .critical)
        #expect(colors.level(percent: 20, plugged: false) == .elevated)
        #expect(colors.level(percent: 21, plugged: false) == .normal)
        #expect(colors.level(percent: 1, plugged: true) == .normal)
        #expect(colors.level(percent: nil, plugged: false) == .normal)
        #expect(IslandBatteryColors().level(percent: 1, plugged: false) == .normal)
        let migrated = try JSONDecoder().decode(IslandBatteryColors.self, from: Data(#"{"enabled":true,"redThreshold":99}"#.utf8))
        #expect(migrated.amberThreshold == 100 && !migrated.amber)
    }

    @Test func oldSettingsPreserveValuesAndDisableExtensions() throws {
        let data = Data(#"{"isEnabled":true,"sections":["music","camera"],"timerMinutes":37,"gestures":true}"#.utf8)
        let settings = try JSONDecoder().decode(IslandSettings.self, from: data)
        #expect(settings.isEnabled && settings.gestures)
        #expect(settings.sections == [.music, .camera] && settings.timerMinutes == 37)
        #expect(!settings.lyrics && !settings.onlineLyrics && !settings.queue && !settings.musicVolume)
        #expect(!settings.trackNotices && !settings.keepAwakeActivity && !settings.fileDropTarget)
        #expect(!settings.liveBars && !settings.watchSound && !settings.watchShortcut && !settings.lockScreen && !settings.lockSounds)
        #expect(!settings.claudeActivity && !settings.codexActivity && !settings.agentFinishedNotices && !settings.agentLimitNotices)
        #expect(settings.leftButtons.isEmpty && settings.rightButtons.isEmpty)
        #expect(settings.batteryColors == IslandBatteryColors())
        #expect(settings.agentReading == .elapsed && settings.agentMinimumSeconds == 60 && settings.agentLimitThreshold == 80)
        #expect(try JSONDecoder().decode(IslandSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func lrcHandlesMultipleTagsOffsetsAndMalformedSeconds() throws {
        let lyrics = try IslandLyrics(data: Data("[ar:Artist]\n[offset:250]\n[00:02.500][00:01.00]Hello\n[00:70]Bad\n[00:02.500]Again\nUntimed".utf8))
        #expect(lyrics.lines.map(\.time) == [1.25, 2.75, 2.75])
        #expect(lyrics.lines.map(\.text) == ["Hello", "Hello", "Again"])
        #expect(lyrics.plain == "Untimed")
        #expect(lyrics.active(position: 1.24, offset: 0) == nil)
        #expect(lyrics.active(position: 2.75, offset: 0) == 2)
        #expect(lyrics.active(position: 2.75, offset: 0.25) == 0)
        #expect(lyrics.nextDelay(position: 2, offset: 0.25, rate: 2) == 0.5)
        #expect(lyrics.nextDelay(position: 2, offset: 0, rate: 0) == nil)
        #expect(lyrics.nextDelay(position: 10, offset: 0, rate: 1) == nil)
    }

    @Test func lyricsRejectOversizedAndInvalidImports() {
        #expect(throws: IslandLyrics.Failure.self) { try IslandLyrics(data: Data(repeating: 65, count: 128 * 1024 + 1)) }
        #expect(throws: IslandLyrics.Failure.self) { try IslandLyrics(data: Data([0xff, 0xfe])) }
        #expect(IslandLyrics(text: "First\nSecond").plain == "First\nSecond")
        #expect(IslandLyrics.offset(12) == 10)
        #expect(IslandLyrics.offset(-12) == -10)
        #expect(IslandLyrics.offset(0.37) == 0.25)
        #expect(IslandLyrics.offset(.nan) == 0)
    }

    @Test func matchingKeepsVersionsAndRanksAlbumBeforeTimestamps() {
        let song = IslandSong(title: "Écho (feat. Guest)", artist: "Singer", album: "Album", duration: 120)
        let timed = IslandLyricCandidate(trackName: "Echo", artistName: "Singer", albumName: "Other", duration: 122, syncedLyrics: "[00:01]Hi")
        let album = IslandLyricCandidate(trackName: "Echo", artistName: "Singer", albumName: "Album", duration: 118, plainLyrics: "Hi")
        #expect(IslandLyricMatching.best([timed, album], song: song) == album)
        #expect(IslandLyricMatching.title("Echo (Live)") != IslandLyricMatching.title(song.title))
        #expect(IslandLyricMatching.title("Echo - Remix") != IslandLyricMatching.title(song.title))
        var wrong = album
        wrong.duration = 117.99
        #expect(IslandLyricMatching.best([wrong], song: song) == nil)
        wrong.duration = .nan
        #expect(IslandLyricMatching.best([wrong], song: song) == nil)
        #expect(IslandLyricMatching.queries(song).count <= 4)
        #expect(IslandLyricMatching.queries(song).last?.first?.name == "q")
    }

    @Test func exactLookupDoesNotSearchAgain() async throws {
        let log = RequestLog()
        let lookup = IslandLyricsLookup { host, path, _ in
            await log.append(host + path)
            return Data(#"{"trackName":"Song","artistName":"Artist","duration":120,"syncedLyrics":"[00:01]Hi"}"#.utf8)
        }
        let result = try await lookup.lookup(IslandSong(title: "Song", artist: "Artist", album: "", duration: 120))
        #expect(result?.lines.first?.text == "Hi")
        #expect(await log.values == ["lrclib.net/api/get"])
    }

    @Test func aliasesOnlyRunAfterEmptySearches() async throws {
        let log = RequestLog()
        let lookup = IslandLyricsLookup { host, path, _ in
            await log.append(host + path)
            if path == "/api/get" { return nil }
            if host == "musicbrainz.org" { return Data(#"{"artists":[]}"#.utf8) }
            return Data("[]".utf8)
        }
        let result = try await lookup.lookup(IslandSong(title: "Song", artist: "Artist", album: "", duration: 120))
        #expect(result == nil)
        #expect(await log.values == ["lrclib.net/api/get", "lrclib.net/api/search", "lrclib.net/api/search", "musicbrainz.org/ws/2/artist"])
    }

    @Test func unmatchedSearchResultsDoNotTriggerAliases() async throws {
        let log = RequestLog()
        let lookup = IslandLyricsLookup { host, path, _ in
            await log.append(host + path)
            if path == "/api/get" { return nil }
            return Data(#"[{"trackName":"Other","artistName":"Artist","duration":120,"plainLyrics":"Hi"}]"#.utf8)
        }
        #expect(try await lookup.lookup(IslandSong(title: "Song", artist: "Artist", album: "", duration: 120)) == nil)
        #expect(await log.values.allSatisfy { $0.hasPrefix("lrclib.net") })
    }

    @Test @MainActor func offlineAndClosedLyricsNeverRequest() async throws {
        let log = RequestLog()
        let controller = IslandLyricsController(lookup: IslandLyricsLookup { host, _, _ in await log.append(host); return nil })
        let song = IslandSong(title: "Song", artist: "Artist", album: "", duration: 120)
        controller.update(song: song, sample: nil, visible: true, online: false)
        #expect(controller.status == .offline)
        try controller.importLyrics(Data("[00:01]Imported".utf8))
        guard case .ready(let lyrics) = controller.status else { Issue.record("Imported lyrics missing"); return }
        #expect(lyrics.lines.first?.text == "Imported")
        controller.update(song: song, sample: nil, visible: false, online: true)
        #expect(controller.status == .idle)
        #expect(await log.values.isEmpty)
    }

    @Test func gesturesIgnoreDiagonalsAndMomentumSkips() {
        var gesture = IslandGesture()
        let outcome19 = gesture.consume(x: 4, y: 4, now: 0, precise: true, inverted: false, modified: false, open: true, music: true) == nil
        #expect(outcome19)
        let outcome20 = gesture.consume(x: -100, y: 0, now: 0.1, precise: true, inverted: false, modified: false, open: true, music: true) == nil
        #expect(outcome20)
        let outcome21 = gesture.consume(x: -20, y: 0, now: 1, precise: true, inverted: false, modified: false, open: true, music: true) == nil
        #expect(outcome21)
        let outcome22 = gesture.consume(x: -30, y: 0, now: 1.1, precise: true, inverted: false, modified: false, open: true, music: true, momentum: true) == nil
        #expect(outcome22)
        let outcome23 = gesture.consume(x: -40, y: 0, now: 1.2, precise: true, inverted: false, modified: false, open: true, music: true) == nil
        #expect(outcome23)
        let outcome24 = gesture.consume(x: -40, y: 0, now: 1.3, precise: true, inverted: false, modified: false, open: true, music: true, began: true) == .next
        #expect(outcome24)
    }

    @Test func momentumCanFinishVerticalGestureButBlockedInputCannot() {
        var gesture = IslandGesture()
        let outcome25 = gesture.consume(x: 0, y: -8, now: 0, precise: true, inverted: false, modified: false, open: false, music: false) == nil
        #expect(outcome25)
        let outcome26 = gesture.consume(x: 0, y: -8, now: 0.1, precise: true, inverted: false, modified: false, open: false, music: false, momentum: true) == .open
        #expect(outcome26)
        let outcome27 = gesture.consume(x: 0, y: 20, now: 1, precise: true, inverted: false, modified: false, open: true, music: false, blocked: true) == nil
        #expect(outcome27)
        let outcome28 = gesture.consume(x: -2, y: 0, now: 2, precise: false, inverted: false, modified: false, open: true, music: true) == nil
        #expect(outcome28)
    }
}

private actor RequestLog {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
