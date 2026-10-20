import Foundation
import Testing
@testable import CleanMacOS

struct StartupRoutineTests {
    private let boot = Date(timeIntervalSince1970: 1_000_000)

    private func job(_ label: String, _ command: String, startsAtLogin: Bool = true, source: ScheduledJobSource = .userAgent) -> ScheduledJob {
        ScheduledJob(label: label, source: source, command: command, schedule: "", plistPath: nil, logPaths: [],
                     isLoaded: true, pid: nil, lastExitStatus: nil, startsAtLogin: startsAtLogin)
    }

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

    @Test func listsWhatStillBlocksRecovery() {
        #expect(StartupReadiness.missing(autoRestart: true, fileVaultIsOn: false, autoLoginUser: "me") == [])
        #expect(StartupReadiness.missing(autoRestart: false, fileVaultIsOn: false, autoLoginUser: nil) == [.power, .password])
        #expect(StartupReadiness.missing(autoRestart: nil, fileVaultIsOn: true, autoLoginUser: "me") == [.power, .password])
    }

    @Test func picksBackgroundJobsThatStartAtLogin() {
        let jobs = [job("local.caffeinate", "/usr/bin/caffeinate -d"),
                    job("daily", "/bin/zsh run.sh", startsAtLogin: false),
                    job("global", "/usr/bin/caffeinate -d", source: .globalAgent),
                    job("local.autolock", "/bin/zsh -c sleep 1; /Users/me/.local/bin/lockscreen")]
        #expect(StartupJobs.atLogin(jobs).map(\.label) == ["local.caffeinate", "local.autolock"])
        #expect(StartupJobs.keepsAwake(jobs[0]))
        #expect(!StartupJobs.keepsAwake(jobs[3]))
        #expect(StartupJobs.locksScreen(jobs[3]))
        #expect(!StartupJobs.locksScreen(jobs[0]))
    }

    @Test func readsWhetherAnAgentStartsAtLogin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plists: [String: [String: Any]] = [
            "a": ["Label": "a", "ProgramArguments": ["/usr/bin/caffeinate", "-d"], "KeepAlive": true],
            "b": ["Label": "b", "Program": "/bin/true", "RunAtLoad": true],
            "c": ["Label": "c", "Program": "/bin/true", "StartInterval": 60],
            "d": ["Label": "d", "Program": "/bin/true", "KeepAlive": false],
        ]
        for (name, plist) in plists {
            (plist as NSDictionary).write(to: directory.appendingPathComponent("\(name).plist"), atomically: true)
        }
        let jobs = ScheduledJobsService.readPlists(in: directory.path, source: .userAgent, statuses: [:])
        #expect(jobs.filter(\.startsAtLogin).map(\.label) == ["a", "b"])
    }

    @Test func buildsAKeepAwakeAgent() {
        let plist = ScheduledJobsService.agentPlist(label: StartupJobs.keepAwakeLabel, arguments: StartupJobs.keepAwakeArguments)
        #expect(plist["Label"] as? String == "click.ngoctruong.CleanMacOS.caffeinate")
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/bin/caffeinate", "-d"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["StandardOutPath"] == nil)
    }

    @Test func buildsACustomJobFromNameAndCommand() throws {
        let job = try StartupJobs.custom(name: "  DB Proxy (staging)! ", command: "~/bin/proxy.sh --port 5434", keepsRunning: false)
        #expect(job.label == "local.db-proxy-staging")
        #expect(job.arguments == ["/bin/zsh", "-lc", "~/bin/proxy.sh --port 5434"])
        #expect(job.keepsRunning == false)
        #expect(job.logPath == NSHomeDirectory() + "/Library/Logs/local.db-proxy-staging.log")
        let plist = ScheduledJobsService.agentPlist(label: job.label, arguments: job.arguments,
                                                    keepsRunning: job.keepsRunning, logPath: job.logPath)
        #expect(plist["KeepAlive"] as? Bool == false)
        #expect(plist["StandardErrorPath"] as? String == job.logPath)
        #expect(throws: PortsJobsError.self) { try StartupJobs.custom(name: "!!!", command: "x", keepsRunning: true) }
        #expect(throws: PortsJobsError.self) { try StartupJobs.custom(name: "ok", command: "  ", keepsRunning: true) }
    }
}
