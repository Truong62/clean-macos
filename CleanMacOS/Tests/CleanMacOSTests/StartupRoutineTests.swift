import Foundation
import Testing
@testable import CleanMacOS

struct StartupRoutineTests {
    private let boot = Date(timeIntervalSince1970: 1_000_000)

    @Test func runsOnceShortlyAfterBoot() {
        #expect(StartupRoutine.shouldRun(bootTime: boot, now: boot.addingTimeInterval(30), lastBoot: 0))
        #expect(!StartupRoutine.shouldRun(bootTime: boot, now: boot.addingTimeInterval(30), lastBoot: 1_000_000))
        #expect(!StartupRoutine.shouldRun(bootTime: boot, now: boot.addingTimeInterval(3_600), lastBoot: 0))
    }

    @Test func readsAutoRestartOnlyWhenTheMacSupportsIt() {
        let settings = "System-wide power settings:\nCurrently in use:\n standby              1\n autorestart          1\n womp                 1\n"
        #expect(SystemPower.parseAutoRestart(settings: settings, capabilities: "Capabilities for AC Power: sleep womp autorestart standby") == true)
        #expect(SystemPower.parseAutoRestart(settings: settings.replacingOccurrences(of: "autorestart          1", with: "autorestart          0"),
                                             capabilities: "Capabilities for AC Power: autorestart") == false)
        #expect(SystemPower.parseAutoRestart(settings: settings, capabilities: "Capabilities for Battery Power: sleep womp") == nil)
    }

    @Test func readsFileVaultAndAutoLogin() {
        #expect(SystemPower.parseFileVault("FileVault is Off.\n") == false)
        #expect(SystemPower.parseFileVault("FileVault is On.\n") == true)
        #expect(SystemPower.parseFileVault("") == nil)
        #expect(SystemPower.parseAutoLoginUser("nguyentruong\n") == "nguyentruong")
        #expect(SystemPower.parseAutoLoginUser("") == nil)
    }

    @Test func savesAppsWithTheirAction() throws {
        let defaults = try #require(UserDefaults(suiteName: "startup-tests-\(UUID())"))
        #expect(StartupSettings.apps(in: defaults) == [])
        let apps = [StartupApp(path: "/Applications/Orca.app", action: .quit, delaySeconds: 8),
                    StartupApp(path: "/Applications/Tailscale.app", action: .keepOpen)]
        StartupSettings.save(apps, in: defaults)
        #expect(StartupSettings.apps(in: defaults) == apps)
        #expect(apps[0].name == "Orca")
    }

    @Test func listsWhatStillBlocksRecovery() {
        #expect(StartupReadiness.missing(autoRestart: true, fileVaultIsOn: false, autoLoginUser: "me", opensAtLogin: true) == [])
        #expect(StartupReadiness.missing(autoRestart: false, fileVaultIsOn: true, autoLoginUser: nil, opensAtLogin: false)
                == [.power, .disk, .login, .app])
        #expect(StartupReadiness.missing(autoRestart: nil, fileVaultIsOn: false, autoLoginUser: "me", opensAtLogin: true) == [.power])
    }
}
