import Foundation
import Testing
@testable import CleanMacOS

struct IslandMusicSourcesTests {
    let now = Date(timeIntervalSince1970: 1000)

    @Test func enablingPopulatesOnlyEmptySections() throws {
        var settings = IslandSettings()
        #expect(!settings.isEnabled)
        #expect(settings.sections.isEmpty)
        settings.isEnabled = true
        #expect(settings.sections == [.music, .timer, .files, .clipboard])
        settings.sections = [.calendar, .music]
        settings.isEnabled = false
        settings.isEnabled = true
        #expect(settings.sections == [.calendar, .music])
        for json in ["{\"isEnabled\":true}", "{\"isEnabled\":true,\"sections\":[]}"] {
            let migrated = try JSONDecoder().decode(IslandSettings.self, from: Data(json.utf8))
            #expect(migrated.sections == [.music, .timer, .files, .clipboard])
            #expect(!migrated.liveBars && !migrated.shortcut && !migrated.onlineLyrics)
            #expect(try JSONDecoder().decode(IslandSettings.self, from: JSONEncoder().encode(migrated)) == migrated)
        }
        let disabled = try JSONDecoder().decode(IslandSettings.self, from: Data("{\"sections\":[]}".utf8))
        #expect(disabled.sections.isEmpty)
    }

    @Test func appleScriptPreservesTextAndConvertsSpotifyMilliseconds() throws {
        let fields = ["Bài hát\nwith, commas", "Artist\tTwo", "Album", "240000", "42.5", "playing", "https://example.test/art.jpg"]
        let sample = try #require(IslandMusicParsing.appleScript(fields, source: .spotify, now: now))
        #expect(sample.title == fields[0])
        #expect(sample.artist == fields[1])
        #expect(sample.album == "Album")
        #expect(sample.duration == 240)
        #expect(sample.position(at: now.addingTimeInterval(2)) == 44.5)
        #expect(sample.artworkURL?.host == "example.test")
        let music = try #require(IslandMusicParsing.appleScript(["Song", "", "", "240", "42,0", "paused", "file:///etc/passwd"], source: .music, now: now))
        #expect(music.duration == 240 && !music.playing)
        #expect(music.position(at: now.addingTimeInterval(20)) == 42)
        #expect(music.artworkURL == nil)
    }

    @Test func malformedAppleScriptRepliesAreRejected() {
        #expect(IslandMusicParsing.appleScript([], source: .music, now: now) == nil)
        for fields in [
            ["", "", "", "10", "0", "playing", ""],
            ["Song", "", "", "nan", "0", "playing", ""],
            ["Song", "", "", "10", "inf", "playing", ""],
            ["Song", "", "", "10", "0", "stopped", ""],
            ["Song", "", "", "10", "0", "unknown", ""]
        ] { #expect(IslandMusicParsing.appleScript(fields, source: .music, now: now) == nil) }
    }

    @Test func helperDecodesMetadataArtworkAndTime() throws {
        let fixture = Data(#"{"title":"Browser song","artist":"Artist","album":"Album","duration":100,"elapsed":20,"rate":1,"timestamp":990,"playing":true,"pid":42,"artwork":"AQID"}"#.utf8)
        let reading = try #require(IslandMusicParsing.helper(fixture, now: now))
        #expect(reading.source == .helper && reading.pid == 42)
        #expect(reading.sample.title == "Browser song")
        #expect(reading.sample.album == "Album")
        #expect(reading.sample.position(at: now) == 30)
        #expect(reading.sample.artwork == Data([1, 2, 3]))
        let minimal = try #require(IslandMusicParsing.helper(Data(#"{"title":"Live","pid":-1}"#.utf8), now: now))
        #expect(minimal.pid == nil && !minimal.sample.playing)
        #expect(minimal.sample.sampled == now)
        for fixture in ["{}", "[]", "garbage", #"{"title":4}"#, #"{"title":" "}"#] {
            #expect(IslandMusicParsing.helper(Data(fixture.utf8), now: now) == nil)
        }
    }

    @Test func streamHandlesSplitUnicodeAndMultipleLines() {
        var stream = IslandMusicLines()
        let fixture = Data("{\"title\":\"Nhạc\"}\n{}\n".utf8)
        let split = fixture.count - 5
        #expect(stream.append(fixture.prefix(split)).isEmpty)
        let lines = stream.append(fixture.suffix(from: split))
        #expect(lines.count == 2)
        #expect(IslandMusicParsing.helper(lines[0], now: now)?.sample.title == "Nhạc")
        #expect(IslandMusicParsing.helper(lines[1], now: now) == nil)
        #expect(stream.append(Data(repeating: 65, count: 4 * 1024 * 1024 + 1)).isEmpty)
        #expect(stream.append(Data("{}\n".utf8)) == [Data("{}".utf8)])
    }

    @Test func playingSourcesWinAndTiesKeepPriority() {
        let sample = IslandMediaSample(title: "Song", artist: "", duration: 100, elapsed: 0, sampled: now, rate: 0, playing: false)
        let local = IslandMusicReading(source: .local, sample: sample)
        var remote = IslandMusicReading(source: .spotify, sample: sample)
        #expect(IslandMusicParsing.select([local, remote])?.source == .local)
        remote.sample.playing = true
        #expect(IslandMusicParsing.select([local, remote])?.source == .spotify)
        var playingLocal = local
        playingLocal.sample.playing = true
        #expect(IslandMusicParsing.select([playingLocal, remote])?.source == .local)
        #expect(IslandMusicParsing.select([]) == nil)
        remote.sample.title = ""
        #expect(IslandMusicParsing.select([remote]) == nil)
    }

    @Test func scriptsGuardRunningPlayersAndUseOnlyKnownTargets() throws {
        let script = try #require(IslandAppleScript.script(source: .spotify))
        #expect(script.hasPrefix("if application id \"com.spotify.client\" is not running then return {}"))
        #expect(script.contains("with timeout of 3 seconds"))
        #expect(IslandAppleScript.script(source: .helper) == nil)
        #expect(IslandAppleScript.script(source: .music, command: "playpause")?.contains("playpause") == true)
    }
}
