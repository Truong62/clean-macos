import Foundation
import Testing
@testable import CleanMacOS

struct PortsJobsTests {
    @Test func parsesLsofFieldsAndMergesAddressesPerProcessPort() {
        let output = "p394\ncrapportd\nLalice\nf10\nn*:49190\nf11\nn*:49190\np900\ncnode\nLalice\nf20\nn127.0.0.1:3000\nf21\nn[::1]:3000\n"
        let ports = PortsService.parse(output)
        #expect(ports.map(\.port) == [3000, 49190])
        #expect(ports[0] == ListeningPort(port: 3000, pid: 900, command: "node", user: "alice", addresses: ["127.0.0.1", "[::1]"]))
        #expect(ports[0].isLocalOnly)
        #expect(ports[1].addresses == ["*"])
        #expect(!ports[1].isLocalOnly)
    }

    @Test func parsesLaunchctlList() {
        let statuses = ScheduledJobsService.parseLaunchctlList("PID\tStatus\tLabel\n1398\t0\tlocal.caffeinate\n-\t-9\tcom.apple.progressd\n")
        #expect(statuses["local.caffeinate"] == LaunchctlStatus(pid: 1398, lastExitStatus: 0))
        #expect(statuses["com.apple.progressd"] == LaunchctlStatus(pid: nil, lastExitStatus: -9))
    }

    @Test func describesLaunchdSchedules() {
        #expect(ScheduledJobsService.describeSchedule(["StartInterval": 60]) == "Every 1 min")
        #expect(ScheduledJobsService.describeSchedule(["StartInterval": 7_200, "RunAtLoad": true]) == "Every 2 h")
        #expect(ScheduledJobsService.describeSchedule(["StartCalendarInterval": ["Hour": 9, "Minute": 5]]) == "Daily 09:05")
        #expect(ScheduledJobsService.describeSchedule(["StartCalendarInterval": [["Weekday": 1, "Hour": 8], ["Minute": 30]]]) == "Mon 08:00, Hourly at :30")
        #expect(ScheduledJobsService.describeSchedule(["KeepAlive": true]) == "Always running")
        #expect(ScheduledJobsService.describeSchedule(["KeepAlive": false, "RunAtLoad": true]) == "At login")
        #expect(ScheduledJobsService.describeSchedule([:]) == "On demand")
    }

    @Test func parsesCrontabSkippingCommentsAndVariables() {
        let jobs = ScheduledJobsService.parseCrontab("SHELL=/bin/bash\n# backup\n*/5 *\t* * * /usr/local/bin/backup.sh --quiet\n@reboot /bin/echo hi\n\n")
        #expect(jobs.map(\.schedule) == ["*/5 * * * *", "@reboot"])
        #expect(jobs.map(\.command) == ["/usr/local/bin/backup.sh --quiet", "/bin/echo hi"])
        #expect(jobs.allSatisfy { $0.source == .cron })
    }

    @Test func crontabJobKeepsRawLineAndDeleteRemovesOnlyThatLine() {
        let crontab = "MAILTO=\"\"\n0 9 * * * /bin/a\n0 9 * * * /bin/b\n"
        let jobs = ScheduledJobsService.parseCrontab(crontab)
        #expect(jobs.map(\.cronLine) == ["0 9 * * * /bin/a", "0 9 * * * /bin/b"])
        #expect(ScheduledJobsService.removingLine("0 9 * * * /bin/a", from: crontab) == "MAILTO=\"\"\n0 9 * * * /bin/b\n")
    }

    @Test func parsesPsDetails() {
        #expect(PortsService.parseDetails("   01:02:03 /usr/local/bin/node server.js --port 3000\n")
                == ProcessDetails(elapsed: "01:02:03", arguments: "/usr/local/bin/node server.js --port 3000"))
        #expect(PortsService.parseDetails("") == nil)
    }

    @Test func logTailReturnsWholeLinesFromTheEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try String(repeating: "0123456789\n", count: 3_000).appending("last line\n").write(to: url, atomically: true, encoding: .utf8)
        let tail = try #require(ScheduledJobsService.logTail(url.path))
        #expect(tail.hasPrefix("0123456789\n"))
        #expect(tail.hasSuffix("last line\n"))
        #expect(tail.utf8.count <= 16_384)
        #expect(ScheduledJobsService.logTail("/nonexistent/x.log") == nil)
    }

    @Test func statusLabelReflectsLaunchdState() {
        func job(loaded: Bool, pid: pid_t?, exit: Int?) -> ScheduledJob {
            ScheduledJob(label: "x", source: .userAgent, command: "", schedule: "", plistPath: nil, logPaths: [],
                         isLoaded: loaded, pid: pid, lastExitStatus: exit)
        }
        #expect(job(loaded: true, pid: 12, exit: 0).statusLabel == "Running · PID 12")
        #expect(job(loaded: true, pid: nil, exit: 78).statusLabel == "Failed (exit 78)")
        #expect(job(loaded: true, pid: nil, exit: 0).statusLabel == "Idle")
        #expect(job(loaded: true, pid: nil, exit: -15).statusLabel == "Killed (signal 15)")
        #expect(job(loaded: false, pid: nil, exit: nil).statusLabel == "Stopped")
    }

    @Test func listsAPortThisTestOpens() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        server.arguments = ["-l", "127.0.0.1", "47613"]
        try server.run()
        defer { server.terminate() }
        var found: ListeningPort?
        for _ in 0..<20 where found == nil {
            try await Task.sleep(for: .milliseconds(100))
            found = await PortsService().list().first { $0.pid == server.processIdentifier }
        }
        #expect(found?.port == 47613)
        #expect(found?.command == "nc")
    }
}
