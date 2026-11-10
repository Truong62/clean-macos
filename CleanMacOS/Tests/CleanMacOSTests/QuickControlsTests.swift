import Foundation
import Testing
@testable import CleanMacOS

final class RecordingRunner: CommandRunning, @unchecked Sendable {
    var outputs: [String: (Int32, String)] = [:]
    private(set) var commands: [String] = []

    func run(_ path: String, _ arguments: [String]) -> CommandResult {
        let line = ([path] + arguments).joined(separator: " ")
        commands.append(line)
        let (status, output) = outputs[line] ?? (0, "")
        return CommandResult(status: status, output: output, error: "")
    }
}

struct QuickControlsTests {
    @Test func readsFinderFlagsWithTheirDefaults() {
        let runner = RecordingRunner()
        let controls = QuickControls(runner: runner)
        runner.outputs["/usr/bin/defaults read com.apple.finder AppleShowAllFiles"] = (0, "1\n")
        runner.outputs["/usr/bin/defaults read com.apple.finder CreateDesktop"] = (1, "does not exist")
        #expect(controls.isOn(.hiddenFiles))
        #expect(controls.isOn(.desktopIcons))
        runner.outputs["/usr/bin/defaults read com.apple.finder CreateDesktop"] = (0, "0")
        #expect(!controls.isOn(.desktopIcons))
    }

    @Test func writesTheFlagAndRestartsFinder() {
        let runner = RecordingRunner()
        QuickControls(runner: runner).set(.hiddenFiles, true)
        #expect(runner.commands == ["/usr/bin/defaults write com.apple.finder AppleShowAllFiles -bool true", "/usr/bin/killall Finder"])
    }

    @Test func runsTheSystemCommands() {
        let runner = RecordingRunner()
        let controls = QuickControls(runner: runner)
        controls.sleepDisplay()
        controls.setDarkMode(true)
        #expect(runner.commands[0] == "/usr/bin/pmset displaysleepnow")
        #expect(runner.commands[1].hasPrefix("/usr/bin/osascript -e tell application \"System Events\" to tell appearance preferences to set dark mode to true"))
    }

    @Test func picksTheAppsToQuit() {
        let running = [
            RunningAppInfo(bundleID: "com.apple.finder", name: "Finder", isRegular: true),
            RunningAppInfo(bundleID: "click.ngoctruong.CleanMacOS", name: "MacKit", isRegular: true),
            RunningAppInfo(bundleID: "com.apple.Safari", name: "Safari", isRegular: true),
            RunningAppInfo(bundleID: "com.spotify.client", name: "Spotify", isRegular: true),
            RunningAppInfo(bundleID: "com.apple.dock.helper", name: "Helper", isRegular: false),
        ]
        let quit = QuickControls.appsToQuit(running, keep: ["com.spotify.client"], own: "click.ngoctruong.CleanMacOS")
        #expect(quit.map(\.name) == ["Safari"])
    }
}
